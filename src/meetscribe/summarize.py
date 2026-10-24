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
not "June 2025", unless the year was said). Keep who does what, and whether it is already done
or still to do, exactly as said ("Priya will fix the crash today", not "Priya fixed the crash").
Never link facts nobody linked: no "because", "due to" or "so" unless someone gave that reason.
Keep each date, number and request with the item it was said about.

Scale everything to what was actually said: a short or trivial meeting gets 1–2 summary
bullets. Never pad: no bullets about the transcript itself, the meeting's length, or what
did NOT happen.

Start with one line "Title: <a short title for this meeting, max 6 words>", then exactly
these sections (the action items are listed separately — don't write them):

## Summary
{summary_how}
{extra_sections}
## Decisions
What the group agreed or decided, each written as the decision itself (like "<option> stays as
a fallback", "<project> moves to <month>"). Look for choices made, conditions agreed ("if <test>
goes well, <next step>"), rules or policies set or kept as they are, priorities set, and things
approved, dropped or postponed. Not decisions: news, results or dates that are only announced —
they go in the summary. A decision is never a task: no "X will…" or "X to…", no owner, no
deadline for someone's work — those are action items, listed separately. Write "None recorded."
only if nothing at all was decided.

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
EXTRACT_TEMPERATURE = TEMPERATURE  # the action-item passes (benchmarks compare 0 = no randomness)


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

    def chat(self, prompt: str, max_tokens: int = 2500, on_token=None, prose: bool = False,
             temperature: float | None = None) -> str:
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
                                         sampler=make_sampler(temp=TEMPERATURE if temperature is None else temperature, top_p=0.8),
                                         logits_processors=penalty)
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
                                 "temperature": TEMPERATURE if temperature is None else temperature,
                                 "max_tokens": max_tokens}).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=1800) as r:
                out = json.load(r)["choices"][0]["message"]["content"]
        else:
            raise SystemExit(f"Unknown llm_backend '{self.cfg.llm_backend}' (use 'mlx' or 'openai')")
        return re.sub(r"<think>.*?</think>", "", out, flags=re.S).strip()


def _plain_text(text: str) -> str:
    import unicodedata

    return unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()


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
    """The extraction answer: JSON objects (one per line is asked for, but some models spread an
    object over several lines or wrap them in a code block), or "owner | due | hh:mm:ss | task |
    quote" lines from models that prefer tables."""
    out = []
    for chunk in re.findall(r"\{[^{}]*\}", raw, flags=re.S):
        try:
            out.append(json.loads(chunk))
        except json.JSONDecodeError:
            continue
    if out:
        return out
    for line in raw.splitlines():
        cells = [c.strip() for c in line.strip().strip("`").strip("|").split("|")]
        if len(cells) >= 5 and re.fullmatch(r"\d+:\d{2}(:\d{2})?", cells[2]):
            out.append({"owner": cells[0], "due": "" if cells[1] in ("-", "—", "") else cells[1],
                        "at": cells[2], "task": cells[3], "quote": " | ".join(cells[4:])})
    return out


# Resolutions about one's own behaviour, not tasks ("je vais faire attention", "I'll try to be clearer").
BEHAVIOUR = re.compile(r"^(faire attention|be careful|pay attention|try to|try and|essayer|keep in mind|garder en t[eê]te|"
                       r"r[ée]fl[ée]chir|think about|be more|[eê]tre plus|take care to|veiller [àa])", re.I)
# "je vais en parler à l'équipe" copied as the task: the subject goes ("en parler à l'équipe").
SUBJECT = re.compile(r"^(je vais |je m'en |je |j'|i'll |i will |i'm going to |we'll |we will |on va |nous allons )", re.I)


def check_actions(raw: str, transcript: str, meeting) -> list[dict]:
    """Keeps the extracted commitments whose quote really is in the transcript (anything else
    was made up), places them at that line, and keeps a deadline only when that date is said
    there, just around it, or in a line naming the owner (a recap). Duplicates are left to
    merge_actions."""
    from .dates import parse_due

    lines = _lines(transcript)
    words_of = [set(_norm_words(text)) for _, _, text in lines]
    speakers = {sp for _, sp, _ in lines}
    out = []
    for item in _action_lines(raw):
        task, owner = str(item.get("task", "")).strip(), str(item.get("owner", "")).strip()
        task = SUBJECT.sub("", task).strip()
        quote = set(_norm_words(str(item.get("quote", ""))))
        if not task or len(quote) < 2 or BEHAVIOUR.match(task):
            continue
        scores = [len(quote & w) / len(quote) for w in words_of]
        best = max(scores, default=0.0)
        if best < 0.7:
            continue
        # A common quote ("yes, I'll do it") can fit several lines: take the one nearest to
        # the time the model gave.
        said = _seconds(str(item.get("at", ""))) if re.fullmatch(r"\d+:\d{2}:\d{2}", str(item.get("at", ""))) else None
        close = [i for i, sc in enumerate(scores) if sc >= best - 0.1]
        best_i = min(close, key=lambda i: abs(lines[i][0] - said)) if said is not None else close[0]
        # "Guillaume, can you prepare …?" said by Sarah: the task is Guillaume's, not hers. Only
        # the sentence the quote comes from counts: a long turn can mention someone ("the roles
        # Peter mentioned"), ask him something else and ask something of everyone ("please…").
        t_line, speaker, text = lines[best_i]
        if owner.lower() == speaker.lower():
            sentences = re.split(r"(?<=[.?!])\s+", text)
            k = max(range(len(sentences)), key=lambda j: len(quote & set(_norm_words(sentences[j]))))
            ask = sentences[k]
            tokens = " ".join(re.findall(r"[a-z0-9]+|[,?]", _plain_text(ask)))  # "sarah , can you"
            asked = [sp for sp in speakers if sp.lower() != speaker.lower() and _norm_words(sp)[:1]
                     and re.search(rf"\b{_norm_words(sp)[0]} [,?]", tokens)]
            if len(asked) == 1 and REQUEST.search(ask):
                owner = asked[0]
        due = str(item.get("due", "")).strip()
        if due and meeting:
            first = (_norm_words(owner) or [""])[0]
            near = [t for _, _, t in lines[max(0, best_i - 1): best_i + 2]]  # the line, the ask, the answer
            near += [t for (_, sp, t), w in zip(lines, words_of)
                     if first and first in w and (_norm_words(sp) or [""])[0] != first]
            d = parse_due(due, meeting)
            if d is None or d not in _dates_said(near, meeting):
                due = ""
        out.append({"owner": owner, "task": task, "due": due, "quote": str(item.get("quote", "")),
                    "at": f"{t_line // 3600:02d}:{t_line % 3600 // 60:02d}:{t_line % 60:02d}"})
    return out


SECOND_LOOK_PROMPT = """Below are lines from a meeting, each with the line said just before it (for context only).
In some of them someone takes on a task to do after the meeting: volunteered ("I'll send it",
"we will submit it on the 10th"), accepted when asked ("Yes, I'll…"), or given to them ("Aisha
will send you the exercise today").

For each such task, answer with one JSON object per line, and nothing else:
{{"owner": "…", "task": "…", "due": "…", "at": "hh:mm:ss", "quote": "…"}}
- owner: who will DO it: the speaker for "I", "we" or "je", else the person named.
- task: short, starting with a verb, in {language}. due: the deadline exactly as said, or "".
- at: the time of the line. quote: 5 to 8 words copied exactly from that line (not the context).
Give nothing for a line without such a task: what is done right now in the meeting ("let me
think", "I'll start", asking or presenting), what is already done, opinions, news, and what only
might happen ("if we…, we can…").

Lines:
{excerpts}"""

# Things done in the meeting itself ("I'll start", "let me think out loud", "Chloe will say more").
IN_MEETING = re.compile(r"\b(say|talk|tell|present|explain|speak|start|think|ask (you|most|a few|some)|give you|"
                        r"walk (you|us) through|dire|parler|presenter|expliquer|commencer)\b")

# Someone taking something on ("I'll…", "we will…", "je m'en occupe"). The first pass misses
# some of these in a long stretch; the ones no extracted task comes from get a second look.
TAKES_ON = re.compile(r"\b(i'll|i will|i'm going to|i am going to|let me|leave it with me|i'm on it|i can (do|take)|"
                      r"we'll|we will|we're going to|we are going to|je vais|je m'en (occupe|charge)|"
                      r"je peux (le |la |les )?(faire|prendre|envoyer|regarder|préparer)|on va|nous allons)\b", re.I)


def unclaimed(transcript: str, checked: list[dict], meeting) -> list[dict]:
    """Sentences where someone seems to take on a task that none of the extracted ones comes
    from: "I'll…", "Aisha will…", or "I"/"we" with a date ("je leur écris la semaine
    prochaine"). A sentence can hold two ("I'm writing the notes, and I'll deploy on Monday"):
    each part is checked. → [{"at", "speaker", "sentence", "before"}]"""
    lines = _lines(transcript)
    names = {(_norm_words(sp) or [""])[0] for _, sp, _ in lines} - {"speaker", ""}
    content = lambda text: set(_norm_words(text)) - STOP
    quotes: dict[int, list[set]] = {}
    for a in checked:
        quotes.setdefault(_seconds(a["at"]), []).append(content(a.get("quote", "")))
    out = []
    for i, (t, sp, text) in enumerate(lines):
        sentences = re.split(r"(?<=[.?!])\s+", text)
        for k, sentence in enumerate(sentences):
            if sentence.rstrip().endswith("?"):
                continue
            # Parts: a new clause with its own subject ("…, and I'll deploy…"), not "the plan and the quote".
            parts = re.split(r",?\s+(?:and|then|so|et|puis|donc)\s+(?=(?:i|i'll|i'm|we|we'll|we're|je|j'|on|nous)\b)|;\s*",
                             sentence, flags=re.I)
            for j, part in enumerate(parts):
                plain = _plain_text(part)
                if len(plain.split()) < 3:
                    continue
                third = re.search(r"\b([a-z]+) (will|is going to|va|doit|s'occupe)\b", plain)
                dates = _dates_said([part], meeting) if meeting else set()
                dated = re.search(r"\b(i|i'm|we|we're|je|j|nous)\b", plain) and any(d >= meeting for d in dates)
                if not (TAKES_ON.search(part) or (third and third[1] in names) or dated):
                    continue
                if IN_MEETING.search(plain) and not any(d > meeting for d in dates):
                    continue  # "Chloe will say more about that", "I'll ask the questions today": done in the meeting
                words = content(part)
                if any(q and words and max(len(q & words) / len(q), len(q & words) / len(words)) >= 0.6
                       for q in quotes.get(t, [])):
                    continue  # already extracted from this part
                # Only that part is put to the model (a commitment at the end of a long sentence gets
                # overlooked); what comes just before is shown for context.
                if j:
                    before = (sp, " ".join(parts[:j]))
                elif k:
                    before = (sp, sentences[k - 1])
                else:
                    before = (lines[i - 1][1], re.split(r"(?<=[.?!])\s+", lines[i - 1][2])[-1]) if i else None
                out.append({"at": t, "speaker": sp, "sentence": part.strip(), "before": before})
    return out


def second_look(llm, lang: str, transcript: str, checked: list[dict], meeting) -> list[dict]:
    """The commitments the first pass left out, from the sentences `unclaimed` finds — checked
    like the first pass's (quote in the transcript, owner when asked, deadline said)."""
    found = unclaimed(transcript, checked, meeting)
    raw = ""
    for k in range(0, len(found), 20):
        excerpts = "\n\n".join(
            (f"(context) {c['before'][0]}: {c['before'][1]}\n" if c["before"] else "")
            + f"[{c['at'] // 3600:02d}:{c['at'] % 3600 // 60:02d}:{c['at'] % 60:02d}] {c['speaker']}: {c['sentence']}"
            for c in found[k:k + 20])
        raw += llm.chat(SECOND_LOOK_PROMPT.format(language=lang, excerpts=excerpts), max_tokens=700,
                        temperature=EXTRACT_TEMPERATURE)
    return check_actions(raw, transcript, meeting) if raw else []


STOP = set("""a an the to of for on in at by with and or is be it this that our we you they he she i
le la les un une des de du d l et ou en au aux pour par avec sur dans ce cette son sa ses leur
the his her their qui que them those these him us lui eux ceux cela""".split())


# Words that say nothing about WHICH task it is: two tasks sharing only these aren't the same.
GENERIC = set("""prepare send make create get have check add provide share write update give take do
ask tell set start finish follow next week today tomorrow monday tuesday wednesday thursday friday
january february march april may june july august september october november december lundi mardi
mercredi jeudi vendredi janvier fevrier mars avril mai juin juillet aout septembre octobre novembre
decembre semaine prochaine prepare envoie envoyer faire fait demande before after noon morning
afternoon evening tonight end month soon avant apres matin soir midi fin mois""".split())


def _content(task: str) -> set[str]:
    words = {w[:-1] if len(w) > 4 and w.endswith("s") else w for w in _norm_words(task)
             if (len(w) > 2 or any(c.isdigit() for c in w)) and w not in STOP and not w.isdigit()}  # "W4", "PS5"
    words |= {w.lower() for w in re.findall(r"\b[A-Z]{2}\b", task)}  # "HR", "IT", "QA"
    return {w for w in words if w not in GENERIC}


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
            if b["owner"].lower() != a["owner"].lower():
                continue
            if a["task"].lower() == b["task"].lower():
                same = b
                break
            other = _content(b["task"])
            common = len(words & other)
            shared = common / max(1, min(len(words), len(other)))
            if not words and _seconds(a["at"]) - _seconds(b["at"]) <= 60:
                same = b  # "I'll do it before noon", "check with them by Wednesday": the task just said
                break
            if not common:  # nothing that names the task in common ("prepare", "November" don't count)
                continue
            if (recap and shared >= 0.3) or _seconds(a["at"]) - _seconds(b["at"]) <= 60:
                same = b  # restated in the recap, or asked and accepted a moment apart
                break
            if common >= min(2, len(words), len(other)) and shared >= 0.5:
                same = b  # the same task said again later (one shared word like "support" isn't enough)
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
        import gc

        gc.collect()  # let the first attempt's model and buffers go before loading it again
        if cfg.llm_backend == "mlx":
            import mlx.core as mx

            mx.clear_cache()

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
                            temperature=EXTRACT_TEMPERATURE,
                            on_token=lambda n, i=i: progress.update(0.05 + 0.4 * (i + min(n / 300, 0.97)) / len(parts)))
        checked = check_actions(raw, transcript, meeting)
        progress.update(0.45)
        actions = merge_actions(checked + second_look(llm, lang, transcript, checked, meeting))
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
    # Commitments: the same small parts as for shorter meetings, checked against the whole
    # transcript (a recap at the end confirms dates said much earlier).
    raw = "".join(llm.chat(ACTIONS_PROMPT.format(language=lang, transcript=part), max_tokens=900,
                           temperature=EXTRACT_TEMPERATURE)
                  for part in _parts(llm, transcript, EXTRACT_TOKENS))
    checked = check_actions(raw, transcript, meeting)
    actions = merge_actions(checked + second_look(llm, lang, transcript, checked, meeting))
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
        m = re.match(r"^\s*[-*•]\s+\**([A-Za-zÀ-ÿ]+)(?: \d+)?\**(?: \([A-Z]{2}\))?\s+(to|will|shall|must|va|doit)\b", line)
        if in_decisions and m and m[1].lower() in owners:  # also "Speaker 1 (FR) will…"
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
