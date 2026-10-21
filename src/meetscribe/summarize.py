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

NOTES_PROMPT = """Write the meeting notes in {language}, in Markdown (even if parts of the meeting were in
another language — translate those; lines tagged e.g. "(FR)" were spoken in that language).

Level of detail — {style}

Scale everything to what was actually said: a short or trivial meeting gets 1–2 summary
bullets. Never pad: no bullets about the transcript itself, the meeting's length, or what
did NOT happen.

Start with one line "Title: <a short title for this meeting, max 6 words>", then exactly
these sections:

## Summary
The main topics and outcomes, as bullet points.

## Decisions
Only things the group agreed or decided (not tasks). Write "None recorded." if none.

## Action items
A Markdown table with columns: Owner | Task | Due. Go through the transcript line by line
and include EVERY real commitment: tasks someone was asked to do, and anything a speaker says
they will do ("I will…", "I'll…", "let me…") — including the person running the meeting.
Don't turn the meeting's topic into a task. Use the speaker label as the owner when no name
is given; use "—" for an unknown due date. Write "None recorded." if none.

## Open questions
Unresolved questions or topics to follow up on (write "None." if none).

Do not add any other section.

Transcript:
{transcript}"""

CHUNK_PROMPT = """This is part {part} of {total} of a long meeting transcript. Write detailed
notes in {language} of everything important in this part: topics, facts and numbers,
decisions, and every action item with its owner and due date if stated. Use bullet points.

Transcript part:
{transcript}"""


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

    def chat(self, prompt: str, max_tokens: int = 2500) -> str:
        messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}]
        if self.cfg.llm_backend == "mlx":
            from mlx_lm import generate
            from mlx_lm.sample_utils import make_sampler

            self._load()
            text = self._tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False,
                enable_thinking=False,  # Qwen3: answer directly (ignored by other models)
            )
            out = generate(self._model, self._tokenizer, text, max_tokens=max_tokens,
                           sampler=make_sampler(temp=0.7, top_p=0.8))
        elif self.cfg.llm_backend == "openai":
            req = urllib.request.Request(
                self.cfg.llm_url.rstrip("/") + "/chat/completions",
                data=json.dumps({"model": self.cfg.llm_model, "messages": messages,
                                 "temperature": 0.7, "max_tokens": max_tokens}).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=1800) as r:
                out = json.load(r)["choices"][0]["message"]["content"]
        else:
            raise SystemExit(f"Unknown llm_backend '{self.cfg.llm_backend}' (use 'mlx' or 'openai')")
        return re.sub(r"<think>.*?</think>", "", out, flags=re.S).strip()


def summarize(transcript: str, cfg: Config, language: str = "", context: str = "") -> str:
    llm = LLM(cfg)
    lang = language or cfg.summary_language
    if context:
        # Calendar details help with names and the topic — but labels stay as they are.
        transcript = (f"{context}\n(Speaker labels in the transcript are not necessarily these people; "
                      f"keep the labels unless the transcript makes a name obvious.)\n\n{transcript}")
    if cfg.summary_style not in STYLES:
        raise SystemExit(f"summary_style must be one of: {', '.join(STYLES)}")
    style = STYLES[cfg.summary_style]
    max_tokens = 4000 if cfg.summary_style == "detailed" else 2500
    if llm.count_tokens(transcript) <= cfg.max_context_tokens:
        return llm.chat(NOTES_PROMPT.format(language=lang, style=style, transcript=transcript), max_tokens=max_tokens)

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
            CHUNK_PROMPT.format(part=i, total=len(chunks), language=lang, transcript=chunk), max_tokens=1500))
    return llm.chat(NOTES_PROMPT.format(language=lang, style=style, transcript="\n\n".join(partial)),
                    max_tokens=max_tokens)
