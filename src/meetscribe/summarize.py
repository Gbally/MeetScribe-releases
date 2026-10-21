"""Meeting notes (summary, decisions, action items) from a transcript, with a local LLM."""

import json
import re
import urllib.request

from .config import Config

SYSTEM = """You are an assistant that writes concise, accurate meeting notes from a transcript.
The transcript is machine-generated: it may contain recognition errors, and speakers are
labelled by name or as "Speaker N". Only state what the transcript supports — never invent
owners, dates or decisions. If something is unclear, say so."""

NOTES_PROMPT = """Write the meeting notes in {language}, in Markdown, with exactly these sections:

## Summary
3–8 bullet points covering the main topics and outcomes.

## Decisions
Only things the group agreed or decided (not tasks). Write "None recorded." if none.

## Action items
A Markdown table with columns: Owner | Task | Due. Go through the transcript line by line
and include EVERY commitment: tasks someone was asked to do, and anything a speaker says
they will do ("I will…", "I'll…", "let me…") — including the person running the meeting.
Use the speaker label as the owner when no name is given; use "—" for an unknown due date.
Write "None recorded." if none.

## Open questions
Unresolved questions or topics to follow up on (write "None." if none).

Do not add a title or any other section.

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


def summarize(transcript: str, cfg: Config) -> str:
    llm = LLM(cfg)
    lang = cfg.summary_language
    if llm.count_tokens(transcript) <= cfg.max_context_tokens:
        return llm.chat(NOTES_PROMPT.format(language=lang, transcript=transcript))

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
    return llm.chat(NOTES_PROMPT.format(language=lang, transcript="\n\n".join(partial)))
