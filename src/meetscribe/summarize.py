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
KEY_FIGURES = ("Key figures and dates", "Every number, amount, percentage, count, duration and date that matters, one "
                "per line as \"figure — what it refers to\" (e.g. \"€5,000 — training budget\", \"20 Nov — final "
                "decision\", \"15 % — discounts above this need approval\"), also those given in other sections; when "
                "in doubt, include it.")
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
        KEY_FIGURES,
    ]),
    "interview": ("Interview", [
        ("Candidate background", "Experience and skills the candidate described."),
        ("Strengths", "Strengths shown, with evidence from the conversation."),
        ("Concerns", "Gaps or concerns, with evidence. No judgements beyond what was said."),
        KEY_FIGURES,
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
{actions}(The transcript is above.)"""

ACTIONS_PROMPT = """List every commitment made in this meeting: each task someone will do. Include tasks
people volunteer for ("I'll…", "I will…", "let me…", "je vais…", "je m'en occupe", "je fais…")
and tasks someone is asked to do and accepts. When someone recaps the tasks at the end, use the
recap to check who does what and by when. Skip what nobody took on: topics discussed, options
evaluated, opinions, risks, wishes ("we should…", "it would be good to…").

Answer with one JSON object per line and nothing else:
{{"owner": "…", "task": "…", "due": "…", "at": "hh:mm:ss", "quote": "…"}}
- owner: who will DO the task (not who asked for it), as written in the transcript: a speaker
  label ("Sarah", "Speaker 2") or the name of someone mentioned.
- task: short, starting with a verb, in {language}, saying what it is about ("create test data for
  each pipeline", "call the compliance team" — never just "do it", "call them").
- due: the deadline exactly as said for THIS task ("Friday the 31st", "le 14 novembre"), or ""
  when no deadline was said for it. Never guess one.
- at: the time of the line where the commitment is made.
- quote: 5 to 8 words copied exactly from that line, in the language spoken.
One line per task, no duplicates. (The transcript is above.)"""

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
        self._read = None  # (the transcript as given, its tokens, the model's state after reading them)

    def count_tokens(self, text: str) -> int:
        if self.cfg.llm_backend == "mlx":
            self._load()
            return len(self._tokenizer.encode(text))
        return len(text) // 4  # rough estimate for remote servers

    def _load(self):
        if self._model is None:
            from mlx_lm import load
            self._model, self._tokenizer = load(self.cfg.llm_model)

    def _encode(self, text: str) -> list[int]:
        """The prompt's tokens, as mlx-lm makes them: no second BOS when the chat template has one."""
        bos = self._tokenizer.bos_token
        return self._tokenizer.encode(text, add_special_tokens=bos is None or not text.startswith(bos))

    def _after_reading(self, head: str, text: str, last: bool):
        """The tokens of `text` and, when it starts with the same transcript as the last call, the
        model's state after reading it: the transcript is read once, then each pass only reads its
        own instructions (most of a pass's time was re-reading the transcript). Each pass gets a
        copy, except the `last` one, which takes it: two copies of a long meeting don't fit in 8 GB."""
        import copy

        import mlx.core as mx
        from mlx_lm.models.cache import make_prompt_cache

        tokens = self._encode(text)
        end = text.find(head) + len(head)
        if end < len(head):
            return tokens, 0, None
        if not (self._read and self._read[0] == head):
            prefix = self._encode(text[:end])
            self._read = None
            if tokens[:len(prefix)] != prefix:  # the cut falls inside a token: read it all each time
                return tokens, 0, None
            state = make_prompt_cache(self._model)
            for i in range(0, len(prefix), 512):  # small steps: much faster than 2048 with 8 GB
                self._model(mx.array(prefix[i:i + 512])[None], cache=state)
                mx.eval([c.state for c in state])
                mx.clear_cache()  # as mlx-lm does: the step's buffers would otherwise stay held
            self._read = (head, prefix, state)
        _, prefix, state = self._read
        if last:
            self._read = None
        if tokens[:len(prefix)] != prefix:
            return tokens, 0, None
        return tokens, len(prefix), state if last else copy.deepcopy(state)

    def chat(self, prompt: str, max_tokens: int = 2500, on_token=None, prose: bool = False,
             temperature: float | None = None, transcript: str | None = None, last: bool = False) -> str:
        """`prose`: free text (the notes), where a mild repetition penalty stops the loops small
        models sometimes fall into (one line repeated until the length limit). Not for the JSON
        extraction, whose keys repeat on every line by design. `transcript` comes first, before
        the instructions, so passes over the same transcript share its reading; `last`: no pass
        after this one reads that transcript."""
        head = f"Transcript:\n{transcript}\n\n---\n\n" if transcript is not None else ""
        messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": head + prompt}]
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
                import mlx.core as mx

                penalty = make_logits_processors(repetition_penalty=1.08, repetition_context_size=256) if prose else None
                ids, done, state = self._after_reading(head, text, last) if head else (self._encode(text), 0, None)
                tokens = stream_generate(self._model, self._tokenizer, mx.array(ids[done:]), max_tokens=max_tokens,
                                         sampler=make_sampler(temp=TEMPERATURE if temperature is None else temperature, top_p=0.8),
                                         logits_processors=penalty, prompt_cache=state)
                for r in tokens:
                    out += r.text
                    if on_token:
                        on_token(r.generation_tokens)
            except RuntimeError as e:  # Metal: "Insufficient Memory" on smaller Macs, or "[metal::malloc]" for one buffer too big
                if re.search(r"memory|malloc", str(e), re.I):
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


CJK = "\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uac00-\ud7af"  # kana, Chinese characters, Hangul


def _norm_words(text: str) -> list[str]:
    """Lowercase words without accents. Chinese and Japanese have no spaces between words: there,
    each pair of characters ("電話", "話し") stands for a word, so their quotes are checked too."""
    import unicodedata

    out = []
    for i, part in enumerate(re.split(f"([{CJK}]+)", text)):
        if i % 2:  # a run of those characters
            run = unicodedata.normalize("NFC", part)
            out += [run] if len(run) == 1 else [run[k:k + 2] for k in range(len(run) - 1)]
        else:
            out += re.findall(r"[a-z0-9]+", unicodedata.normalize("NFKD", part).encode("ascii", "ignore").decode().lower())
    return out


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


# What people say when they take something on, in the first person ("I'll call", "je l'envoie", "los llamo el lunes",
# "ich schicke", "eu ligo", "preparo io"): Spanish, Portuguese and Italian often drop the pronoun.
COMMIT_VERBS = (r"(llamo|mando|env[ií]o|preparo|hago|hablo|actualizo|reviso|escribo|organizo|compruebo|aviso|comparto|"
                r"termino|me encargo|me ocupo|ligo|fa[çc]o|falo|atualizo|escrevo|compartilho|cuido|chamo|chiamo|invio|faccio|"
                r"parlo|aggiorno|controllo|scrivo|organizzo|avviso|condivido|finisco|lancio|mi occupo|ci penso io)")
FIRST_PERSON = re.compile(r"\b(i'll|i will|i'm going to|i am going to|i can|let me|we'll|we will|we're going to|"
                          r"je vais|je m'en|je peux|je (le|la|les|lui|leur|te|vous) |je [lt]'|je fais|on va|nous allons|"
                          r"voy a|vamos a|yo|lo hago|vou|vamos|eu (vou|te|lhe)|io|vado a|ich|wir (werden|machen|schicken|k[üu]mmern)|"
                          rf"(lo|la|los|las|le|les|te|se|o|a|os|as|lhe|lo|li|gli|ti|ve) {COMMIT_VERBS}|{COMMIT_VERBS})\b", re.I)

REQUEST = re.compile(r"\b(can you|could you|would you|will you|please|tu peux|tu pourrais|peux-tu|pourrais-tu|"
                     r"vous pouvez|est-ce que tu|puedes|podr[ií]as|pod[eé]is|puede usted|por favor|kannst du|k[öo]nnen sie|"
                     r"k[öo]nntest du|k[öo]nnten sie|bitte|voc[eê] pode|pode|poderia|puoi|potresti|pu[oò] |per favore)\b", re.I)


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
                       r"r[ée]fl[ée]chir|think about|be more|[eê]tre plus|take care to|veiller [àa]|"
                       r"(be|stay|keep|get) in touch|rester en contact|"  # "we'll be in touch": a goodbye
                       r"tener cuidado|intentar|ser m[aá]s|mantenerse en contacto|aufpassen|versuchen|darauf achten|"
                       r"in kontakt bleiben|tomar cuidado|tentar|ser mais|manter contato|fare attenzione|provare a|"
                       r"cercare di|essere pi[uù]|restare in contatto)", re.I)
# "je vais en parler à l'équipe" copied as the task: the subject goes ("en parler à l'équipe").
SUBJECT = re.compile(r"^(je vais |je m'en |je |j'|i'll |i will |i'm going to |we'll |we will |on va |nous allons |"
                     r"voy a |yo |ich werde |ich |eu vou |vou |vado a )", re.I)  # not "eu"/"io": "EU compliance check"


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
        said = _seconds(str(item.get("at", ""))) if re.fullmatch(r"\d+:\d{2}:\d{2}", str(item.get("at", ""))) else None
        if best >= 0.7:
            # A common quote ("yes, I'll do it") can fit several lines: take the one nearest to
            # the time the model gave.
            close = [i for i, sc in enumerate(scores) if sc >= best - 0.1]
            best_i = min(close, key=lambda i: abs(lines[i][0] - said)) if said is not None else close[0]
        else:
            # Some models translate the quote ("je l'envoie demain" → "I'll send it tomorrow"): then
            # the line at the time they gave counts, if the owner says it or is named in it.
            own = _norm_words(owner)
            numbers = set(re.findall(r"\d+", str(item.get("quote", ""))))  # the same in any language
            same = lambda sp: bool(own) and (_norm_words(sp)[:len(own)] == own or own[:len(_norm_words(sp))] == _norm_words(sp))
            near = [i for i, (t, sp, _) in enumerate(lines) if said is not None and abs(t - said) <= 3
                    and (same(sp) or (own and own[0] != "speaker" and own[0] in words_of[i]))
                    and numbers <= words_of[i]]
            if not near:
                continue
            best_i = min(near, key=lambda i: abs(lines[i][0] - said))
        # "Guillaume, can you prepare …?" said by Sarah: the task is Guillaume's, not hers. Only
        # the sentence the quote comes from counts: a long turn can mention someone ("the roles
        # Peter mentioned"), ask him something else and ask something of everyone ("please…").
        t_line, speaker, text = lines[best_i]
        sentences = re.split(r"(?<=[.?!])\s+", text)
        ask = sentences[max(range(len(sentences)), key=lambda j: len(quote & set(_norm_words(sentences[j]))))]
        tokens = " ".join(re.findall(r"[a-z0-9]+|[,?]", _plain_text(ask)))  # "sarah , can you"
        if owner.lower() == speaker.lower():
            asked = [sp for sp in speakers if sp.lower() != speaker.lower() and _norm_words(sp)[:1]
                     and re.search(rf"\b{_norm_words(sp)[0]} [,?]", tokens)]
            if len(asked) == 1 and REQUEST.search(ask):
                owner = asked[0]
        elif best >= 0.7 and FIRST_PERSON.search(ask) and not REQUEST.search(ask):
            # "I'll send two dates by Friday", said by Nadia, is hers whoever the model named — unless
            # that person is in the sentence other than spoken to ("I'll ask Sarah to prepare it").
            first = (_norm_words(owner) or [""])[0]
            if not (first and re.search(rf"\b{re.escape(first)}\b(?! [,?])", tokens)):
                owner = speaker
        due = str(item.get("due", "")).strip()
        if due and meeting:
            first = (_norm_words(owner) or [""])[0]
            near = [t for _, _, t in lines[max(0, best_i - 1): best_i + 2]]  # the line, the ask, the answer
            near += [t for (_, sp, t), w in zip(lines, words_of)
                     if first and first in w and (_norm_words(sp) or [""])[0] != first]
            d = parse_due(due, meeting)
            if d is None or d not in _dates_said(near, meeting):
                due = ""
        out.append({"owner": owner, "task": task, "due": due, "quote": str(item.get("quote", "")), "line": best_i,
                    "at": f"{t_line // 3600:02d}:{t_line % 3600 // 60:02d}:{t_line % 60:02d}"})
    return out


SECOND_LOOK_PROMPT = """Below are lines from a meeting, each with the line said just before it (for context only).
In some of them someone takes on a task to do after the meeting: volunteered ("I'll send it",
"we will submit it on the 10th"), accepted when asked ("Yes, I'll…"), or given to them ("Aisha
will send you the exercise today").

For each such task, answer with one JSON object per line, and nothing else:
{{"owner": "…", "task": "…", "due": "…", "at": "hh:mm:ss", "quote": "…"}}
- owner: who will DO it: the speaker for "I", "we" or "je", else the person named.
- task: short, starting with a verb, in {language}, saying what it is about (use the context: "I
  can do it" after "each pipeline needs its own test data" → "create test data for each pipeline").
- due: the deadline exactly as said, or "".
- at: the time of the line. quote: 5 to 8 words copied exactly from that line (not the context).
Give nothing for a line without such a task: what is done right now in the meeting ("let me
think", "I'll start", asking or presenting), what is already done, opinions, news, and what only
might happen ("if we…, we can…").

Lines:
{excerpts}"""

# Things done in the meeting itself ("I'll start", "let me think out loud", "Chloe will say more").
IN_MEETING = re.compile(r"\b(say|talk|tell|present|explain|speak|start|think|ask (you|most|a few|some)|give you|"
                        r"walk (you|us) through|dire|parler|presenter|expliquer|commencer|empiezo|empezamos|presento|explico|"
                        r"fange an|stelle vor|erklare|comeco|apresento|comincio|inizio|spiego)\b")

# Someone taking something on ("I'll…", "we will…", "je m'en occupe"). The first pass misses
# some of these in a long stretch; the ones no extracted task comes from get a second look.
TAKES_ON = re.compile(r"\b(i'll|i will|i'm going to|i am going to|let me|leave it with me|i'm on it|i can (do|take|run|send|check)|"
                      r"i'm happy to|happy to (do|take|run)|je veux bien|"
                      r"we'll|we will|we're going to|we are going to|je vais|je m'en (occupe|charge)|"
                      r"je peux (le |la |les )?(faire|prendre|envoyer|regarder|préparer)|on va|nous allons|"
                      r"voy a|vamos a|lo hago yo|yo me encargo|ich werde|wir werden|ich k[üu]mmere mich|ich mache|ich schicke|"
                      rf"ich rufe|ich kl[äa]re|ich lasse|ich bereite|vou|vamos|eu cuido|vado a|me ne occupo|{COMMIT_VERBS})\b", re.I)


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
            parts = re.split(r",?\s+(?:and|then|so|et|puis|donc|y|e|und|dann|poi|quindi|entonces)\s+"
                             r"(?=(?:i|i'll|i'm|we|we'll|we're|je|j'|on|nous|yo|ich|wir|eu|io|noi)\b)|;\s*",
                             sentence, flags=re.I)
            for j, part in enumerate(parts):
                plain = _plain_text(part)
                if len(plain.split()) < 3:
                    continue
                third = any(m[1] in names for m in re.finditer(
                    r"\b([a-z]+) (will|is going to|runs|takes|handles|leads|va|doit|s'occupe|prend|gere|se encarga|asume|"
                    r"lleva|wird|ubernimmt|kummert sich|vai|assume|cuida|si occupa|prende|gestisce)\b", plain))
                dates = _dates_said([part], meeting) if meeting else set()
                dated = (re.search(r"\b(i|i'm|we|we're|je|j|nous|yo|nosotros|ich|wir|io|noi)\b", plain)
                         or re.search(COMMIT_VERBS, plain)) and any(d >= meeting for d in dates)
                if not (TAKES_ON.search(part) or third or dated):
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
the his her their qui que them those these him us lui eux ceux cela sont est ete etre sera seront ont
los las del una unos unas con para por que esta este eso der die das den dem des ein eine einen einem und oder mit
fur auf zum zur von dass uma umas dos das com pelo pela gli della delle dei degli una con per nel nella che""".split())


# Words that say nothing about WHICH task it is: two tasks sharing only these aren't the same.
GENERIC = set("""prepare send make create get have check add provide share write update give take do
ask tell set start finish follow next week today tomorrow monday tuesday wednesday thursday friday
january february march april may june july august september october november december lundi mardi
mercredi jeudi vendredi janvier fevrier mars avril mai juin juillet aout septembre octobre novembre
decembre semaine prochaine prepare envoie envoyer faire fait demande before after noon morning
afternoon evening tonight end month soon avant apres matin soir midi fin mois
preparar enviar mandar hacer revisar vorbereiten schicken senden machen erledigen fazer preparare inviare
mandare semana woche settimana proxima proximo nachste nachsten prossima prossimo manana morgen domani hoy
heute oggi hoje amanha tarde mes monat mese""".split())


def _date_words(*tables) -> set[str]:
    """The weekday or month names of every language dates are read in (dates.py), without accents."""
    import unicodedata

    return {unicodedata.normalize("NFKD", w).encode("ascii", "ignore").decode() for t in tables for w in t if len(w) > 3}


from .dates import MONTHS as _MONTH_NAMES, WEEKDAYS as _WEEKDAY_NAMES  # noqa: E402

GENERIC |= _date_words(_MONTH_NAMES, _WEEKDAY_NAMES)


def _content(task: str) -> set[str]:
    words = {w[:-1] if len(w) > 4 and w.endswith("s") else w for w in _norm_words(task)
             if (len(w) > 2 or any(c.isdigit() for c in w) or w[0] >= "\u3040") and w not in STOP and not w.isdigit()}  # "W4", "PS5", "電話"
    words |= {w.lower() for w in re.findall(r"\b[A-Z]{2}\b", task)}  # "HR", "IT", "QA"
    return {w for w in words if w not in GENERIC}


def _seconds(at: str) -> int:
    h, m, s = (int(x) for x in at.split(":"))
    return h * 3600 + m * 60 + s


def _verb(task: str) -> str:
    """A to-do's action: its first word ("send", "envoyer")."""
    return (_norm_words(task) or [""])[0]


def _days_apart(due_a: str, due_b: str) -> int | None:
    """How many days apart two said deadlines are, when both are dates."""
    from datetime import date

    from .dates import parse_due

    a, b = (parse_due(d, date.today()) if d else None for d in (due_a, due_b))
    return abs((a - b).days) if a and b else None


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
            vague = not words or (len(words) <= 1 and re.search(r"\b(it|them|this|that|ça|cela)\b", a["task"], re.I))
            if vague and _seconds(a["at"]) - _seconds(b["at"]) <= 60:
                same = b  # "I'll do it before noon", "have it running by Thursday": the task just said
                break
            if not common:  # nothing that names the task in common ("prepare", "November" don't count)
                continue
            # Saying the same thing again, not just about the same thing: "take the lead on the
            # analytics project" and "send the analytics project proposal" are two tasks.
            restated = words <= other or other <= words or _verb(a["task"]) == _verb(b["task"])
            apart = _days_apart(a["due"], b["due"])  # None unless both deadlines are dates
            dt = _seconds(a["at"]) - _seconds(b["at"])
            # Asked, then accepted in the very next line ("Tom, please order the new server" — "Will
            # do, I'll have it running by Thursday"); other lines in between: only if said again.
            reply = a.get("line") is not None and b.get("line") is not None and a["line"] - b["line"] == 1
            if (recap and shared >= 0.3) or dt == 0 or (dt <= 60 and (reply or restated) and not (apart and apart > 7)):
                same = b  # restated in the recap, two parts of one sentence, or asked and accepted
                break
            if apart:
                continue  # "propose 6 % to the director on Monday" ≠ "a proposal to the client by the 15th"
            if common >= min(2, len(words), len(other)) and shared >= 0.5 and (restated or common >= 3):
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
    import dataclasses
    import gc

    from . import progress

    try:
        return _summarize(transcript, cfg, language, context, template, meeting)
    except MemoryError:
        progress.out_of_memory()
        if cfg.max_context_tokens <= 6000:
            raise SystemExit("Not enough memory for the notes model — choose a smaller one in Settings → AI models.")
    # Retried only here, out of the `except`: its traceback would keep the first attempt's model
    # and reading in memory while the model is loaded again.
    gc.collect()
    if cfg.llm_backend == "mlx":
        import mlx.core as mx

        mx.clear_cache()
    print("   not enough memory for the whole meeting at once — writing the notes in parts")
    return summarize(transcript, dataclasses.replace(cfg, max_context_tokens=6000), language, context, template, meeting)


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
        raw, raw_decisions = _extract(llm, lang, parts, lambda i, n: progress.update(0.05 + 0.4 * (i + min(n / 400, 0.97)) / len(parts)))
        checked = check_actions(raw, transcript, meeting)
        progress.update(0.45)
        actions = merge_actions(checked + second_look(llm, lang, transcript, checked, meeting))
        decisions = finish_decisions(llm, lang, transcript, raw_decisions) if DECISIONS_MODE != "notes" else []
        progress.update(0.5)
        body = llm.chat(NOTES_PROMPT.format(language=lang, style=style, extra_sections=extra,
                                            actions=_actions_context(actions), summary_how=_summary_how(transcript)),
                        transcript=transcript, last=True, max_tokens=max_tokens, prose=True,
                        on_token=lambda n: progress.update(0.5 + 0.5 * min(n / expected, 0.97)))
        return _with_actions(_with_decisions(body, decisions, actions), actions)

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
    raw, raw_decisions = _extract(llm, lang, _parts(llm, transcript, EXTRACT_TOKENS))
    checked = check_actions(raw, transcript, meeting)
    actions = merge_actions(checked + second_look(llm, lang, transcript, checked, meeting))
    decisions = finish_decisions(llm, lang, transcript, raw_decisions) if DECISIONS_MODE != "notes" else []
    body = llm.chat(NOTES_PROMPT.format(language=lang, style=style, extra_sections=extra,
                                        actions=_actions_context(actions), summary_how=_summary_how(transcript)),
                    transcript="\n\n".join(partial), last=True, max_tokens=max_tokens, prose=True,
                    on_token=lambda n: progress.update((len(chunks) + min(n / expected, 0.97)) / (len(chunks) + 1)))
    return _with_actions(_with_decisions(body, decisions, actions), actions)


DECISIONS_PROMPT = """List every decision taken in this meeting: what the group agreed or settled. A decision
is a choice made ("we go with Unity"), a condition agreed ("if the take-home is good, he goes to
the final round"), a rule or policy set or kept ("discounts above 15 % need Laura's approval",
"the remote policy doesn't change"), a priority set, or something approved, dropped or postponed
("the trailer is dropped", "offline mode moves to January"). Not decisions: tasks someone will do,
even written without a name ("references are requested by Monday" — the to-dos are listed
separately), news or dates that are only announced, results, opinions, explanations of how
something works or would be done (a candidate's answer in an interview), proposals nobody agreed
to, questions left open.

Answer with one JSON object per line and nothing else:
{{"decision": "…", "at": "hh:mm:ss", "quote": "…"}}
- decision: the decision itself, short, in {language}, with no owner or deadline for someone's
  work ("Unreal stays as a fallback", "The final choice is made on 20 November") — what was
  decided, never only that something was ("the date is set").
- at: the time of the line where it is decided or agreed.
- quote: 5 to 8 words copied exactly from that line, in the language spoken.
One line per decision, no duplicates; nothing at all if nothing was decided. (The transcript is above.)"""

DECISIONS_SECOND_LOOK_PROMPT = """Below are lines from a meeting, each with the line said just before it (for context only).
In some of them the group settles something: a choice made, a condition agreed, a rule or policy
set or kept, a priority, something approved, dropped or postponed.

For each such decision, answer with one JSON object per line, and nothing else:
{{"decision": "…", "at": "hh:mm:ss", "quote": "…"}}
- decision: the decision itself, short, in {language}, with no owner or deadline for someone's work.
- at: the time of the line. quote: 5 to 8 words copied exactly from that line (not the context).
Give nothing for a line that only proposes, asks, explains, reports news or results, or gives
someone a task.

Lines:
{excerpts}"""

# Words that settle something ("decided", "let's keep…", "on garde…", "à partir de lundi").
DECIDES = re.compile(r"\b(decided|decision|let's (go|do|keep|move|try|say|stick|use|not|drop)|go with|agreed|approved|"
                     r"stays|remains|is dropped|we drop|forget it|moves? to|postpone|from now on|(from|starting) (next|monday|"
                     r"tomorrow|january|today)|the rule is|we keep|keep it|no change|"
                     r"d[ée]cid|on garde|on retient|on part sur|on reste|on abandonne|abandonn|on laisse|attendra|"
                     r"[àa] partir d|on teste|on le teste|valid[ée]|approuv|on passe [àa]|report[ée]|on repousse|act[ée]|"
                     r"decis|acordamos|de acuerdo|nos quedamos|se queda|mantenemos|aprobad|descartamos|aplazamos|retras|"
                     r"pospon|beschlossen|beschlie[ßs]en|entschieden|vereinbart|einverstanden|bleibt|bleiben|verschoben|"
                     r"verschieben|genehmigt|machen wir so|combinado|fica |ficam|mantemos|aprovad|adiad|adiar|vamos com|"
                     r"d'accordo|resta |restano|rimane|manteniamo|approvat|rimandiamo|rinviat|mettiamo da parte|partiamo con)", re.I)


def check_decisions(raw: str, transcript: str) -> list[dict]:
    """The extracted decisions whose quote really is in the transcript (anything else was made
    up), placed at that line. A translated quote counts at the time given if that line settles
    something ("on garde…", "decided") and has the quote's numbers."""
    lines = _lines(transcript)
    words_of = [set(_norm_words(text)) for _, _, text in lines]
    out = []
    for item in _action_lines(raw):
        text, quote_text = str(item.get("decision", "")).strip(), str(item.get("quote", ""))
        quote = set(_norm_words(quote_text))
        if not text or len(quote) < 2 or text.lower().rstrip(".") in ("none", "none recorded", "aucune"):
            continue
        scores = [len(quote & w) / len(quote) for w in words_of]
        best = max(scores, default=0.0)
        said = _seconds(str(item.get("at", ""))) if re.fullmatch(r"\d+:\d{2}:\d{2}", str(item.get("at", ""))) else None
        if best >= 0.7:
            close = [i for i, sc in enumerate(scores) if sc >= best - 0.1]
            i = min(close, key=lambda i: abs(lines[i][0] - said)) if said is not None else close[0]
        else:
            numbers = set(re.findall(r"\d+", quote_text))
            near = [i for i, (t, _, line) in enumerate(lines) if said is not None and abs(t - said) <= 3
                    and DECIDES.search(line) and numbers <= words_of[i]]
            if not near:
                continue
            i = min(near, key=lambda i: abs(lines[i][0] - said))
        t = lines[i][0]
        out.append({"decision": text, "quote": quote_text, "line": i,
                    "at": f"{t // 3600:02d}:{t % 3600 // 60:02d}:{t % 60:02d}"})
    return out


def _decision_words(text: str) -> set[str]:
    """Like _content, but months and weekdays count: "a February start" names the decision."""
    return {w[:-1] if len(w) > 4 and w.endswith("s") else w for w in _norm_words(text)
            if (len(w) > 2 or any(c.isdigit() for c in w) or w[0] >= "\u3040") and w not in STOP and not w.isdigit()}


MONTHS = set("""january february march april may june july august september october november december
janvier fevrier mars avril mai juin juillet aout septembre octobre novembre decembre""".split())
MONTHS |= _date_words(_MONTH_NAMES)


def _marks(text: str) -> set[str]:
    """The numbers and months a decision names ("20", "november")."""
    words = _norm_words(text)
    return {w for w in words if w in MONTHS} | set(re.findall(r"\d+", " ".join(words)))


def merge_decisions(items: list[dict]) -> list[dict]:
    """One line per decision, in the order of the meeting: the same decision said twice (or found
    by both passes) is kept once, in its fuller wording."""
    out: list[dict] = []
    for d in sorted(items, key=lambda x: x.get("line", 10 ** 9)):
        words, marks = _decision_words(d["decision"]), _marks(d["decision"])
        for e in out:
            other, their = _decision_words(e["decision"]), _marks(e["decision"])
            if marks and their and not (marks <= their or their <= marks):
                continue  # "phase 1 on 1 December" and "phase 2 in January" are two decisions
            common = len(words & other)
            if common and common >= min(2, len(words), len(other)) and common / max(1, min(len(words), len(other))) >= 0.5:
                if len(words) > len(other):
                    e["decision"] = d["decision"]
                break
        else:
            out.append(dict(d))
    return out


def unclaimed_decisions(transcript: str, checked: list[dict]) -> list[dict]:
    """Sentences that settle something ("on garde…", "decided", "let's…") that none of the
    extracted decisions comes from."""
    lines = _lines(transcript)
    content = lambda text: set(_norm_words(text)) - STOP
    quotes: dict[int, list[set]] = {}
    for d in checked:
        quotes.setdefault(d["line"], []).append(content(d.get("quote", "")))
    out = []
    for i, (t, sp, text) in enumerate(lines):
        sentences = re.split(r"(?<=[.?!])\s+", text)
        for k, sentence in enumerate(sentences):
            if sentence.rstrip().endswith("?") or len(sentence.split()) < 3 or not DECIDES.search(sentence):
                continue
            words = content(sentence)
            if any(q and words and max(len(q & words) / len(q), len(q & words) / len(words)) >= 0.6 for q in quotes.get(i, [])):
                continue
            if k:
                before = (sp, sentences[k - 1])
            else:
                before = (lines[i - 1][1], re.split(r"(?<=[.?!])\s+", lines[i - 1][2])[-1]) if i else None
            out.append({"at": t, "speaker": sp, "sentence": sentence.strip(), "before": before})
    return out


def decisions_second_look(llm, lang: str, transcript: str, checked: list[dict]) -> list[dict]:
    """The decisions the first pass left out, from the sentences `unclaimed_decisions` finds."""
    found = unclaimed_decisions(transcript, checked)
    raw = ""
    for k in range(0, len(found), 20):
        excerpts = "\n\n".join(
            (f"(context) {c['before'][0]}: {c['before'][1]}\n" if c["before"] else "")
            + f"[{c['at'] // 3600:02d}:{c['at'] % 3600 // 60:02d}:{c['at'] % 60:02d}] {c['speaker']}: {c['sentence']}"
            for c in found[k:k + 20])
        raw += llm.chat(DECISIONS_SECOND_LOOK_PROMPT.format(language=lang, excerpts=excerpts), max_tokens=500,
                        temperature=EXTRACT_TEMPERATURE)
    return check_decisions(raw, transcript) if raw else []


def _extract(llm, lang: str, parts: list[str], on_token=None) -> tuple[str, str]:
    """The to-dos and the decisions of each part, one part after the other: both passes over a
    part share its reading (see LLM.chat). The notes pass reads it again only when it is the
    whole transcript."""
    raw = raw_decisions = ""
    decisions = DECISIONS_MODE != "notes"
    for i, part in enumerate(parts):
        raw += llm.chat(ACTIONS_PROMPT.format(language=lang), transcript=part, last=len(parts) > 1 and not decisions,
                        max_tokens=900, temperature=EXTRACT_TEMPERATURE,
                        on_token=(lambda n, i=i: on_token(i, n)) if on_token else None)
        if decisions:
            raw_decisions += llm.chat(DECISIONS_PROMPT.format(language=lang), transcript=part, last=len(parts) > 1,
                                      max_tokens=500, temperature=EXTRACT_TEMPERATURE)
    return raw, raw_decisions


def finish_decisions(llm, lang: str, transcript: str, raw: str) -> list[dict]:
    """The decisions found part by part, checked against the whole transcript, then a second look
    at the sentences that settle something."""
    checked = check_decisions(raw, transcript)
    return merge_decisions(checked + decisions_second_look(llm, lang, transcript, checked))


EXTRACT_TOKENS = 2600  # transcript per commitment-extraction pass (~5 min of meeting): small
                       # models miss far fewer tasks in a short stretch than in a whole meeting


def _parts(llm, transcript: str, budget: int) -> list[str]:
    """The transcript in consecutive parts of about `budget` tokens (whole lines), each
    starting with the end of the previous one so a task said across the cut isn't lost. A transcript
    barely over the budget stays whole: then every pass reads the same text, read only once."""
    if llm.count_tokens(transcript) <= budget * 1.35:
        return [transcript]
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
    """Removes "decisions" that are really one of the action items again ("Sarah to contact W4…"
    when "contact W4 for a quote" is Sarah's to-do): small models file commitments under
    Decisions too. "Oliver to go to the final round" — no such to-do — is a decision and stays."""
    tasks: dict[str, list[set]] = {}
    for a in actions:
        if a.get("owner"):
            tasks.setdefault(a["owner"].split()[0].lower(), []).append(_content(a["task"]))
    out, in_decisions = [], False
    for line in body.splitlines():
        if re.match(r"^#{1,4}\s", line):
            in_decisions = "decision" in line.lower()
        m = re.match(r"^\s*[-*•]\s+\**([A-Za-zÀ-ÿ]+)(?: \d+)?\**(?: \([A-Z]{2}\))?\s+(to|will|shall|must|va|doit|wird|soll|muss|"
                     r"vai|deve|debe|se encarga)\b", line)
        if in_decisions and m and m[1].lower() in tasks:  # also "Speaker 1 (FR) will…"
            words = _content(line[m.end():])
            if any(t and len(words & t) >= min(2, len(t)) for t in tasks[m[1].lower()]):
                continue
        out.append(line)
    text = "\n".join(out)
    # A Decisions section left empty by the cleanup says so.
    return re.sub(r"(^#{1,4}\s*Decisions\s*\n)(\s*)(?=^#{1,4}\s|\Z)", r"\1None recorded.\n\n", text, flags=re.M | re.I)


DECISIONS_MODE = "union"  # "union": the checked decisions, then the notes' own ones not among them;
                          # "checked": only the checked ones; "notes": only the notes' (benchmarks compare)


# Words that settle something — a line with one is a decision even if a to-do is about the same thing.
SETTLED = re.compile(r"\b(decided|agreed|approv|stays|remains|unchanged|dropped|moves?\b|moved\b|postpon|defer|kept|keep|"
                     r"limited|restricted|blocked|priority|rule|d[ée]cid|reste|garde|abandonn|report|repouss|d[ée]cal|limit[ée]|"
                     r"bloqu|conserv|retenu|"
                     r"valid[ée]|approuv|act[ée]|priorit|r[eè]gle|decis[oaie]\b|mantien|se queda|queda |aprob|descart|retras|pospuest|"
                     r"regla|limitad|beschlossen|entschieden|bleibt|verschoben|genehmigt|gestrichen|regel|begrenzt|fica |"
                     r"mantid|aprov|adiad|cancelad|regra|resta\b|restano|rimane|mantenut|rimandat|rinviat|annullat|regola|da parte)", re.I)
# A deadline for someone's work ("by Monday", "d'ici mercredi", "due Friday"): to-dos have them, decisions don't.
DEADLINE = re.compile(r"\b(by|due|before|until|d'ici|avant|pour le|pour vendredi|pour lundi|para el|antes del?|hasta el|"
                      r"bis zum|bis|sp[äa]testens|at[ée]( o| a)?|entro( il| la)?|per il|prima di)\s+(the\s+|le\s+|el\s+|la\s+|il\s+)?"
                      r"((" + "|".join(sorted(map(re.escape, [*_WEEKDAY_NAMES, *_MONTH_NAMES]), key=len, reverse=True)) +
                      r")\b|next|tomorrow|tonight|today|end|\d|demain|ce soir|la fin|fin|ma[ñn]ana|morgen|amanh[ãa]|domani|"
                      r"finales de|fine (del|della|mese|settimana)|ende (der|des))", re.I)  # "\b": "until marketing" isn't March
# Lines that only say something was settled, not what ("The reference deadline is set").
HOLLOW = re.compile(r"(\b(is|are|has been|have been|was|were)\s+(set|requested|scheduled|defined|established|planned|fixed|"
                    r"noted|discussed|mentioned)\s*\.?$|\b(deadline|due date|date|[ée]ch[ée]ance)\b.*\b(is|are) (set|fixed|scheduled)\b)", re.I)
# "No formal decisions were recorded; the meeting focused on…": says there's none, it isn't one.
NO_DECISION = re.compile(r"^\W*(no|none|nothing|aucune?|rien|ning[uú]n[ao]?|nada|keine?|nichts|nenhum[ao]?|nessun[ao]?)\b.{0,40}"
                         r"\b(decision|decided|d[ée]cision|d[ée]cid|decisi[oó]n|decis|entscheid|beschlo|decis[aãoõ])", re.I)
OPEN = re.compile(r"\b(not (yet )?decided|undecided|to be decided|still open|tbd|pas (encore )?d[ée]cid|[àa] d[ée]cider|reste ouvert|"
                  r"no (se ha |est[aá] )?decidid|sin decidir|por decidir|noch nicht entschieden|noch offen|ainda n[aã]o (foi )?decidid|"
                  r"n[aã]o (foi )?decidid|a decidir|em aberto|non (ancora )?decis|da decidere|ancora aperto)", re.I)


def final_decisions(checked: list[str], own: list[str], actions: list[dict]) -> list[str]:
    """The decisions to list: the checked ones and — in "union" mode — the notes' own ones not among
    them; without what only repeats a to-do ("References are requested by Monday" when sending
    them is Oliver's to-do) or says nothing was decided."""
    tasks = [_content(a["task"]) for a in actions if a.get("task")]
    by_owner: dict[str, list[set]] = {}
    for a in actions:
        if a.get("owner") and a.get("task"):
            by_owner.setdefault(a["owner"].split()[0].lower(), []).append(_content(a["task"]))

    def repeats_task(text: str) -> bool:
        if SETTLED.search(text):
            return False
        words = _content(text)
        m = re.match(r"^\**([A-Za-zÀ-ÿ]+)(?: \d+)?\**(?: \([A-Z]{2}\))?\s+(to|will|shall|must|is to|needs to|va|doit|wird|soll|"
                     r"muss|vai|deve|debe|se encarga|\w{3,}r[áà]|"
                     r"s'engage|\w{3,}ra)\b", text, re.I)  # "… va envoyer", "… demandera"
        if m and m[1].lower() in by_owner:  # "Emma will send the list…" when that's her to-do
            return any(words & t for t in by_owner[m[1].lower()])
        if DEADLINE.search(text) and any(words & t for t in tasks):
            return True  # "References are requested by Monday": someone's to-do, without the name
        return any(t and (len(words & t) >= 3 or (len(words & t) >= 2 and len(words & t) / max(1, min(len(words), len(t))) >= 0.8))
                   for t in tasks)

    # Each list is cleaned first: when both give a decision, the wording kept must be one that stays.
    keep = lambda items: [d for d in (x.replace("\n", " ").strip() for x in items)
                          if d and not OPEN.search(d) and not HOLLOW.search(d) and not NO_DECISION.search(d) and not repeats_task(d)]
    checked, own = keep(checked), keep(own)
    if DECISIONS_MODE == "notes":
        return own
    if DECISIONS_MODE == "checked":
        return checked or own  # nothing found by the checked passes: keep what the notes say
    return [d["decision"] for d in merge_decisions([{"decision": d, "line": i} for i, d in enumerate(checked)]
                                                   + [{"decision": d, "line": len(checked) + i} for i, d in enumerate(own)])]


def _with_decisions(body: str, decisions: list[dict], actions: list[dict] = ()) -> str:
    """The Decisions section from the checked decisions (each one really said, found part by part
    and looked at twice) — in "union" mode followed by those the notes give that aren't among
    them. Small models writing the notes in one go leave out some decisions, differently each time."""
    if DECISIONS_MODE == "notes":
        return body
    heading = re.search(r"^#{1,4}\s*d[ée]cisions?\b.*$", body, re.I | re.M)  # also "## Decisions taken"
    if heading:
        nxt = re.search(r"^#{1,4}\s", body[heading.end():], re.M)
        end = heading.end() + (nxt.start() if nxt else len(body) - heading.end())
        own = [re.sub(r"^\s*[-*•]\s+|\*\*", "", x).strip() for x in body[heading.end():end].splitlines()
               if re.match(r"^\s*[-*•]\s+", x)]
    else:
        own = []
    items = final_decisions([d["decision"] for d in decisions], own, actions)
    section = "## Decisions\n" + ("\n".join(f"- {d}" for d in items) if items else "None recorded.") + "\n\n"
    if heading:
        return body[:heading.start()] + section + body[end:].lstrip("\n")
    m = re.search(r"^#{1,4}\s*open questions", body, re.I | re.M)
    return body[:m.start()] + section + body[m.start():] if m else body.rstrip() + "\n\n" + section


def _with_actions(body: str, actions: list[dict]) -> str:
    """The notes with the checked action items placed before the open questions."""
    body = _drop_task_decisions(body, actions)
    table = "## Action items\n" + actions_table(actions) + "\n"
    m = re.search(r"^#{1,4}\s*open questions", body, re.I | re.M)
    return body[:m.start()] + table + "\n" + body[m.start():] if m else body.rstrip() + "\n\n" + table
