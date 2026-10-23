"""Meeting notes (summary, decisions, action items) from a transcript, with a local LLM."""

import json
import re
import urllib.request

from .config import Config

SYSTEM = """You are an assistant that writes concise, accurate meeting notes from a transcript.
The transcript is machine-generated: it may contain recognition errors, and speakers are
labelled by name or as "Speaker N". Only state what the transcript supports — never invent
owners, dates or decisions. If something is unclear, say so."""

# How much detail the notes contain (setting `summary_style`).
STYLES = {
    "detailed": """Detailed notes: someone who missed the meeting should understand everything.
- Summary: one bullet per topic discussed, each 1–3 sentences with the context, the
  arguments, who said what, and any numbers, names or dates mentioned.
- Decisions and open questions: include the reasoning in a few words.""",
    "standard": """Balanced notes: the main topics and outcomes, one line each.
- Summary: typically 3–8 bullets.""",
    "brief": """As short as possible: a busy reader skims it in 15 seconds.
- Summary: at most 4 bullets, each under 12 words, outcomes only.
- Decisions, action items and questions: a few words each.""",
}

# Meeting types: extra sections (title, instructions) inserted after the Summary.
KEY_FIGURES = ("Key figures and dates", "Every number, amount, quantity and date that matters, as "
                "\"figure — what it refers to\" (e.g. \"€5,000 — training budget\", \"20 Nov — final decision\").")
RISKS = ("Risks", "Risks, concerns and dependencies raised, with who raised them.")

TEMPLATES = {
    "general": ("General", [KEY_FIGURES, RISKS]),
    "one_on_one": ("1:1", [
        ("Feedback", "Feedback given or received, in either direction, as bullets."),
        ("Growth & wellbeing", "Career goals, workload, morale or support discussed (only if discussed)."),
    ]),
    "standup": ("Stand-up", [
        ("Updates", "One bullet per person: \"Name — done / doing next\"."),
        ("Blockers", "What is blocking someone, and who can help."),
    ]),
    "client": ("Client call", [
        ("Client requests", "What the client asked for or expects."),
        ("Our commitments", "What we promised the client, with dates if stated."),
        ("Risks & concerns", "Concerns, objections or risks raised."),
    ]),
    "interview": ("Interview", [
        ("Candidate background", "Experience and skills the candidate described."),
        ("Strengths", "Strengths shown, with evidence from the conversation."),
        ("Concerns", "Gaps or concerns, with evidence. No judgements beyond what was said."),
    ]),
    "workshop": ("Workshop / brainstorm", [
        ("Options compared", "When options were compared: a Markdown table with columns Option | For | Against | "
                             "Status, one row per option, Status being chosen, still open, fallback or rejected."),
        ("Ideas", "Every idea or proposal raised, one per line, as \"idea — proposed by NAME — kept / parked / "
                  "rejected\" (say which, from what was decided)."),
        KEY_FIGURES,
    ]),
}

NOTES_PROMPT = """Write the meeting notes in {language}, in Markdown (even if parts of the meeting were in
another language — translate those; lines tagged e.g. "(FR)" were spoken in that language).

Level of detail — {style}

Keep facts exact: never add a year, date, number or detail that wasn't said (write "June",
not "June 2025", unless the year was said).

Scale everything to what was actually said: a short or trivial meeting gets 1–2 summary
bullets. Never pad: no bullets about the transcript itself, the meeting's length, or what
did NOT happen.

Start with one line "Title: <a short title for this meeting, max 6 words>", then exactly
these sections (the action items are listed separately — don't write them):

## Summary
{summary_how}
{extra_sections}
## Decisions
What the group agreed or decided, each written as the decision itself ("Unreal stays as a
fallback", "The final choice is made on 20 November"). A decision is never a task: no "X will…"
or "X to…", no owner, no deadline for someone's work — those are action items, listed
separately. Look for agreements, choices, rules and options dropped or kept. Write "None
recorded." only if nothing at all was decided.

## Open questions
Unresolved questions or topics to follow up on (write "None." if none).

Do not add any other section.
{actions}
Transcript:
{transcript}"""

ACTIONS_PROMPT = """List every commitment made in this meeting: each task someone will do. Include tasks
people volunteer for ("I'll…", "I will…", "let me…", "je vais…", "je m'en occupe", "je fais…")
and tasks someone is asked to do and accepts. When someone recaps the tasks at the end, use the
recap to check who does what and by when. Skip what nobody took on: topics discussed, options
evaluated, opinions, risks, wishes ("we should…", "it would be good to…").

Answer with one JSON object per line and nothing else:
{{"owner": "…", "task": "…", "due": "…", "at": "hh:mm:ss", "quote": "…"}}
- owner: who will DO the task (not who asked for it), as written in the transcript: a speaker
  label ("Sarah", "Speaker 2") or the name of someone mentioned.
- task: short, starting with a verb, in {language}.
- due: the deadline exactly as said for THIS task ("Friday the 31st", "le 14 novembre"), or ""
  when no deadline was said for it. Never guess one.
- at: the time of the line where the commitment is made.
- quote: 5 to 8 words copied exactly from that line, in the language spoken.
One line per task, no duplicates.

Transcript:
{transcript}"""

CHUNK_PROMPT = """This is part {part} of {total} of a long meeting transcript. Write detailed
notes in {language} of everything important in this part: topics, facts and numbers,
decisions, and every action item with its owner and due date if stated. Use bullet points.

Transcript part:
{transcript}"""


TEMPERATURE = 0.2  # notes are extraction, not creative writing: low = faithful and repeatable


class LLM:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._model = self._tokenizer = None

    def count_tokens(self, text: str) -> int:
        if self.cfg.llm_backend == "mlx":
            self._load()
            return len(self._tokenizer.encode(text))
        return len(text) // 4  # rough estimate for remote servers

    def _load(self):
        if self._model is None:
            from mlx_lm import load
            self._model, self._tokenizer = load(self.cfg.llm_model)

    def chat(self, prompt: str, max_tokens: int = 2500, on_token=None, prose: bool = False) -> str:
        """`prose`: free text (the notes), where a mild repetition penalty stops the loops small
        models sometimes fall into (one line repeated until the length limit). Not for the JSON
        extraction, whose keys repeat on every line by design."""
        messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}]
        if self.cfg.llm_backend == "mlx":
            from mlx_lm import stream_generate
            from mlx_lm.sample_utils import make_logits_processors, make_sampler

            self._load()
            text = self._tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False,
                enable_thinking=False,  # Qwen3: answer directly (ignored by other models)
            )
            out = ""
            try:
                penalty = make_logits_processors(repetition_penalty=1.08, repetition_context_size=256) if prose else None
                tokens = stream_generate(self._model, self._tokenizer, text, max_tokens=max_tokens,
                                         sampler=make_sampler(temp=TEMPERATURE, top_p=0.8), logits_processors=penalty)
                for r in tokens:
                    out += r.text
                    if on_token:
                        on_token(r.generation_tokens)
            except RuntimeError as e:  # Metal: "Insufficient Memory" on smaller Macs
                if "memory" in str(e).lower():
                    raise MemoryError(str(e)) from e
                raise
            finally:
                import mlx.core as mx

                mx.clear_cache()  # give the GPU memory of this answer back before the next pass
        elif self.cfg.llm_backend == "openai":
            req = urllib.request.Request(
                self.cfg.llm_url.rstrip("/") + "/chat/completions",
                data=json.dumps({"model": self.cfg.llm_model, "messages": messages,
                                 "temperature": TEMPERATURE, "max_tokens": max_tokens}).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=1800) as r:
                out = json.load(r)["choices"][0]["message"]["content"]
        else:
            raise SystemExit(f"Unknown llm_backend '{self.cfg.llm_backend}' (use 'mlx' or 'openai')")
        return re.sub(r"<think>.*?</think>", "", out, flags=re.S).strip()


def _norm_words(text: str) -> list[str]:
    import unicodedata

    t = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return re.findall(r"[a-z0-9]+", t)


def _lines(transcript: str) -> list[tuple[float, str, str]]:
    """The plain transcript as (seconds, speaker, text)."""
    out = []
    for line in transcript.splitlines():
        m = re.match(r"^\[(\d+):(\d+):(\d+)\]\s+([^:]+?)(?:\s+\([A-Z]{2}\))?:\s+(.*)$", line)
        if m:
            out.append((int(m[1]) * 3600 + int(m[2]) * 60 + int(m[3]), m[4], m[5]))
    return out


def _dates_said(texts: list[str], meeting) -> set:
    """Every date the texts mention ("vendredi", "le 14 novembre", "next week"…)."""
    from .dates import parse_due

    found = set()
    for text in texts:
        words = text.split()
        for i in range(len(words)):
            for n in (1, 2, 3, 4):
                d = parse_due(" ".join(words[i:i + n]), meeting)
                if d:
                    found.add(d)
    return found


REQUEST = re.compile(r"\b(can you|could you|would you|will you|please|tu peux|tu pourrais|peux-tu|pourrais-tu|"
                     r"vous pouvez|est-ce que tu)\b", re.I)


def _action_lines(raw: str) -> list[dict]:
    """The extraction answer: "owner | due | hh:mm:ss | task | quote" lines (JSON objects are
    accepted too, from models that prefer them)."""
    out = []
    for line in raw.splitlines():
        line = line.strip().strip("`")
        if line.startswith("{"):
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            out.append(item)
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) >= 5 and re.fullmatch(r"\d+:\d{2}(:\d{2})?", cells[2]):
            out.append({"owner": cells[0], "due": "" if cells[1] in ("-", "—", "") else cells[1],
                        "at": cells[2], "task": cells[3], "quote": " | ".join(cells[4:])})
    return out


def check_actions(raw: str, transcript: str, meeting) -> list[dict]:
    """Keeps the extracted commitments whose quote really is in the transcript (anything else
    was made up), places them at that line, and keeps a deadline only when that date is said
    there, just around it, or in a line naming the owner (a recap)."""
    from .dates import parse_due

    lines = _lines(transcript)
    seen: list = []
    out = []
    for item in _action_lines(raw):
        task, owner = str(item.get("task", "")).strip(), str(item.get("owner", "")).strip()
        quote = set(_norm_words(str(item.get("quote", ""))))
        if not task or len(quote) < 2:
            continue
        best, best_i = 0.0, None
        for i, (_, _, text) in enumerate(lines):
            score = len(quote & set(_norm_words(text))) / len(quote)
            if score > best:
                best, best_i = score, i
        if best_i is None or best < 0.7:
            continue
        # "Guillaume, can you prepare …?" said by Sarah: the task is Guillaume's, not hers.
        t_line, speaker, text = lines[best_i]
        if owner.lower() == speaker.lower():
            asked = [sp for sp in {sp for _, sp, _ in lines} if sp.lower() != speaker.lower()
                     and sp.split()[0].lower() in _norm_words(text)]
            if len(asked) == 1 and REQUEST.search(text):
                owner = asked[0]
        # The same task twice (said at the same moment, or the same words for the same person).
        words = set(_norm_words(task))
        if any(o == owner.lower() and (t == t_line or len(words & w) / max(len(words | w), 1) > 0.6)
               for o, t, w in seen):
            continue
        seen.append((owner.lower(), t_line, words))
        due = str(item.get("due", "")).strip()
        if due and meeting:
            first = owner.split()[0].lower() if owner else ""
            near = [t for _, _, t in lines[max(0, best_i - 1): best_i + 2]]  # the line, the ask, the answer
            near += [t for _, sp, t in lines if first and first in _norm_words(t) and sp.lower() != first]
            d = parse_due(due, meeting)
            if d is None or d not in _dates_said(near, meeting):
                due = ""
        t = lines[best_i][0]
        out.append({"owner": owner, "task": task, "due": due,
                    "at": f"{t // 3600:02d}:{t % 3600 // 60:02d}:{t % 60:02d}"})
    return out


STOP = set("""a an the to of for on in at by with and or is be it this that our we you they he she i
le la les un une des de du d l et ou en au aux pour par avec sur dans ce cette son sa ses leur
the his her their qui que""".split())


def _content(task: str) -> set[str]:
    return {w[:-1] if len(w) > 4 and w.endswith("s") else w for w in _norm_words(task) if len(w) > 2 and w not in STOP}


def _seconds(at: str) -> int:
    h, m, s = (int(x) for x in at.split(":"))
    return h * 3600 + m * 60 + s


def merge_actions(actions: list[dict]) -> list[dict]:
    """One item per task. The same task often comes back (worded differently, or in the recap
    at the end, where one line lists everyone's tasks): for the same owner, items sharing most
    of their words are merged — keeping the first time, the fuller wording and any checked
    deadline."""
    owners_at: dict[str, set] = {}
    for a in actions:
        owners_at.setdefault(a["at"], set()).add(a["owner"].lower())
    out: list[dict] = []
    for a in sorted(actions, key=lambda x: x["at"]):
        words = _content(a["task"])
        recap = len(owners_at[a["at"]]) >= 2  # one line giving several people's tasks: a recap
        same = None
        for b in out:
            if b["owner"].lower() != a["owner"].lower() or not words:
                continue
            common = len(words & _content(b["task"]))
            shared = common / max(1, min(len(words), len(_content(b["task"]))))
            # …or asked and accepted a moment apart ("can you prepare…?" — "yes, I'll do…").
            if shared >= (0.3 if recap else 0.5) or (common and _seconds(a["at"]) - _seconds(b["at"]) <= 60):
                same = b
                break
        if same:
            same["due"] = same["due"] or a["due"]
            if len(words) > len(_content(same["task"])):  # the fuller wording
                same["task"] = a["task"]
        else:
            out.append(dict(a))
    return out


def actions_table(actions: list[dict]) -> str:
    if not actions:
        return "None recorded."
    rows = ["| Owner | Task | Due | At |", "|---|---|---|---|"]
    rows += [f"| {a['owner'] or '—'} | {a['task']} | {a['due'] or '—'} | {a['at']} |" for a in actions]
    return "\n".join(rows)


def summarize(transcript: str, cfg: Config, language: str = "", context: str = "", template: str = "general",
              meeting=None) -> str:
    """Notes as Markdown. Long or memory-hungry meetings are retried in smaller parts."""
    try:
        return _summarize(transcript, cfg, language, context, template, meeting)
    except MemoryError:
        if cfg.max_context_tokens <= 6000:
            raise SystemExit("Not enough memory for the notes model — choose a smaller one in Settings → AI models.")
        import dataclasses

        print("   not enough memory for the whole meeting at once — writing the notes in parts")
        return summarize(transcript, dataclasses.replace(cfg, max_context_tokens=6000), language, context, template,
                         meeting)


def _summarize(transcript: str, cfg: Config, language: str, context: str, template: str, meeting) -> str:
    llm = LLM(cfg)
    lang = language or cfg.summary_language
    extra = "".join(f"\n## {title}\n{how} Write \"None.\" if nothing applies.\n"
                    for title, how in TEMPLATES.get(template, TEMPLATES["general"])[1])
    if context:
        # Calendar details help with names and the topic — but labels stay as they are.
        transcript = (f"{context}\n(Speaker labels in the transcript are not necessarily these people; "
                      f"keep the labels unless the transcript makes a name obvious.)\n\n{transcript}")
    if cfg.summary_style not in STYLES:
        raise SystemExit(f"summary_style must be one of: {', '.join(STYLES)}")
    style = STYLES[cfg.summary_style]
    max_tokens = 4000 if cfg.summary_style == "detailed" else 3000
    from . import progress

    expected = {"brief": 300, "standard": 700, "detailed": 1100}.get(cfg.summary_style, 700)  # measured
    if llm.count_tokens(transcript) <= cfg.max_context_tokens:
        parts = _parts(llm, transcript, EXTRACT_TOKENS)
        raw = ""
        for i, part in enumerate(parts):
            raw += llm.chat(ACTIONS_PROMPT.format(language=lang, transcript=part), max_tokens=900,
                            on_token=lambda n, i=i: progress.update(0.05 + 0.45 * (i + min(n / 300, 0.97)) / len(parts)))
        actions = merge_actions(check_actions(raw, transcript, meeting))
        body = llm.chat(NOTES_PROMPT.format(language=lang, style=style, extra_sections=extra, transcript=transcript,
                                            actions=_actions_context(actions), summary_how=_summary_how(transcript)),
                        max_tokens=max_tokens, prose=True,
                        on_token=lambda n: progress.update(0.5 + 0.5 * min(n / expected, 0.97)))
        return _with_actions(body, actions)

    # Long meeting: summarize chunks, then write the final notes from the chunk notes.
    chunks, current, size = [], [], 0
    budget = cfg.max_context_tokens // 2
    for line in transcript.splitlines():
        n = llm.count_tokens(line)
        if current and size + n > budget:
            chunks.append("\n".join(current))
            current, size = [], 0
        current.append(line)
        size += n
    if current:
        chunks.append("\n".join(current))

    partial = []
    for i, chunk in enumerate(chunks, 1):
        print(f"   summarizing part {i}/{len(chunks)}…")
        partial.append(f"### Part {i}\n" + llm.chat(
            CHUNK_PROMPT.format(part=i, total=len(chunks), language=lang, transcript=chunk), max_tokens=1500, prose=True,
            on_token=lambda n, i=i: progress.update((i - 1 + min(n / 600, 0.97)) / (len(chunks) + 1))))
    actions = []
    for chunk in chunks:  # commitments are checked against the real transcript, part by part
        actions += check_actions(llm.chat(ACTIONS_PROMPT.format(language=lang, transcript=chunk), max_tokens=1500),
                                 chunk, meeting)
    actions = merge_actions(actions)
    body = llm.chat(NOTES_PROMPT.format(language=lang, style=style, extra_sections=extra, transcript="\n\n".join(partial),
                                        actions=_actions_context(actions), summary_how=_summary_how(transcript)),
                    max_tokens=max_tokens, prose=True,
                    on_token=lambda n: progress.update((len(chunks) + min(n / expected, 0.97)) / (len(chunks) + 1)))
    return _with_actions(body, actions)


EXTRACT_TOKENS = 2600  # transcript per commitment-extraction pass (~5 min of meeting): small
                       # models miss far fewer tasks in a short stretch than in a whole meeting


def _parts(llm, transcript: str, budget: int) -> list[str]:
    """The transcript in consecutive parts of about `budget` tokens (whole lines), each
    starting with the end of the previous one so a task said across the cut isn't lost."""
    parts, current, size = [], [], 0
    for line in transcript.splitlines():
        n = llm.count_tokens(line)
        if current and size + n > budget:
            parts.append("\n".join(current))
            current, size = current[-2:], sum(llm.count_tokens(x) for x in current[-2:])
        current.append(line)
        size += n
    if current:
        parts.append("\n".join(current))
    return parts


def _summary_how(transcript: str) -> str:
    """Short meetings: a few bullets. Long ones: one bullet per topic with its key points, so the
    summary carries the substance (arguments, numbers, who thinks what), not just outcomes."""
    lines = _lines(transcript)
    minutes = (lines[-1][0] - lines[0][0]) / 60 if lines else 0
    if minutes < 15:
        return "The main topics and outcomes, as bullet points."
    return ("One bullet per topic discussed, in the order of the meeting: \"**Topic** — what was said\": "
            "the key arguments, facts and numbers, who argued what, and the outcome. Use 4–10 topics.")


def _actions_context(actions: list[dict]) -> str:
    """Tells the notes pass which tasks exist, so decisions and the summary stay consistent."""
    return ""  # listing them made small models leave out the decisions — the notes stand alone


def _drop_task_decisions(body: str, actions: list[dict]) -> str:
    """Removes "decisions" that are really tasks ("Sarah to contact W4…", "Marc will build…"):
    small models file commitments under Decisions too, though they are listed as action items."""
    owners = {a["owner"].split()[0].lower() for a in actions if a.get("owner")}
    out, in_decisions = [], False
    for line in body.splitlines():
        if re.match(r"^#{1,4}\s", line):
            in_decisions = "decision" in line.lower()
        m = re.match(r"^\s*[-*•]\s+\**([A-Za-zÀ-ÿ]+)\**\s+(to|will|shall|must|va|doit)\b", line)
        if in_decisions and m and m[1].lower() in owners:
            continue
        out.append(line)
    text = "\n".join(out)
    # A Decisions section left empty by the cleanup says so.
    return re.sub(r"(^#{1,4}\s*Decisions\s*\n)(\s*)(?=^#{1,4}\s|\Z)", r"\1None recorded.\n\n", text, flags=re.M | re.I)


def _with_actions(body: str, actions: list[dict]) -> str:
    """The notes with the checked action items placed before the open questions."""
    body = _drop_task_decisions(body, actions)
    table = "## Action items\n" + actions_table(actions) + "\n"
    m = re.search(r"^#{1,4}\s*open questions", body, re.I | re.M)
    return body[:m.start()] + table + "\n" + body[m.start():] if m else body.rstrip() + "\n\n" + table
