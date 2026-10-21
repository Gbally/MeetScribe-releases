"""Ask a question across all meetings: keyword search (BM25) finds the relevant passages in
notes and transcripts, then the local LLM answers from those passages only, citing them.
Prints `@@result {json}` (answer + sources) for the app."""

import json
import math
import re
from collections import Counter
from pathlib import Path

from .config import Config
from .transcript import fmt_time

STOP = set("""a an and are as at be but by can could did do does for from had has have how i if in is it its
of on or so that the their them then there these they this to was we were what when where which who why will
with would you your about into just also any not no yes our us me my le la les un une des du de et ou est
sont que qui quoi quand comment pourquoi dans pour par sur avec ce cette ces il elle ils elles nous vous je
tu on pas ne plus au aux en été""".split())


def _tokens(text: str) -> list[str]:
    words = re.findall(r"[\w']+", text.lower())
    return [w[:-1] if len(w) > 4 and w.endswith("s") else w for w in words if w not in STOP and len(w) > 1]


def _chunks(folder: Path) -> list[dict]:
    """Searchable pieces of one meeting: its notes, and ~150-word windows of the transcript."""
    try:
        notes = json.loads((folder / "notes.json").read_text())
    except Exception:
        return []
    title, date = notes.get("title", folder.name), notes.get("date", "")[:10]
    base = {"folder": str(folder), "title": title, "date": date}
    lines = notes.get("summary", []) + notes.get("decisions", []) + notes.get("questions", [])
    lines += [f"{a.get('owner')}: {a.get('task')} (due {a.get('due') or '—'})" for a in notes.get("actions", [])]
    for sec in notes.get("sections", []):
        lines += sec.get("items", [])
    out = [{**base, "kind": "notes", "time": None, "text": f"{title}\n" + "\n".join(lines)}]
    try:
        utts = json.loads((folder / "transcript.json").read_text())["utterances"]
    except Exception:
        return out
    buf, words, start = [], 0, None
    for u in utts:
        if start is None:
            start = u["start"]
        buf.append(f"{u['speaker']}: {u['text']}")
        words += len(u["text"].split())
        if words >= 150:
            out.append({**base, "kind": "transcript", "time": start, "text": "\n".join(buf)})
            buf, words, start = buf[-1:], 0, None  # small overlap
    if buf and words > 10:
        out.append({**base, "kind": "transcript", "time": start, "text": "\n".join(buf)})
    return out


def search(question: str, roots: list[Path], k: int = 10) -> list[dict]:
    chunks = [c for root in roots if root.exists() for f in sorted(root.iterdir()) if f.is_dir() for c in _chunks(f)]
    if not chunks:
        return []
    docs = [Counter(_tokens(c["text"])) for c in chunks]
    avg = sum(sum(d.values()) for d in docs) / len(docs)
    df = Counter(t for d in docs for t in d)
    q = set(_tokens(question))
    scored = []
    for c, d in zip(chunks, docs):
        length = sum(d.values()) or 1
        s = 0.0
        for t in q:
            if t in d:
                idf = math.log(1 + (len(docs) - df[t] + 0.5) / (df[t] + 0.5))
                s += idf * d[t] * 2.2 / (d[t] + 1.2 * (0.25 + 0.75 * length / avg))
        if c["kind"] == "notes":
            s *= 1.3  # summaries are dense and reliable
        if s > 0:
            scored.append((s, c))
    scored.sort(key=lambda x: x[0], reverse=True)
    # At most 3 passages per meeting, so one long meeting doesn't crowd out the rest.
    picked, per = [], Counter()
    for s, c in scored:
        if per[c["folder"]] < 3:
            picked.append(c)
            per[c["folder"]] += 1
        if len(picked) == k:
            break
    return picked


PROMPT = """Answer the question using ONLY the meeting excerpts below. Cite the excerpts you use
like [1] or [2][4]. Mention dates when they matter (e.g. "on 14 Oct it was decided…"). If the
excerpts don't contain the answer, say so plainly — don't guess. Answer in the language of the
question, concisely (a few sentences or bullets).

Question: {question}

Excerpts:
{excerpts}"""


def ask(question: str, cfg: Config) -> dict:
    from . import progress
    from .summarize import LLM

    progress.plan([("search", 2), ("answer", 25)])
    progress.start("search")
    print("→ Searching your meetings", flush=True)
    hits = search(question, [cfg.notes_path])
    if not hits:
        return {"answer": "I couldn't find anything about that in your meetings.", "sources": []}
    excerpts = []
    for i, h in enumerate(hits, 1):
        where = f"notes" if h["kind"] == "notes" else f"transcript at {fmt_time(h['time'])}"
        excerpts.append(f"[{i}] {h['title']} ({h['date']}, {where}):\n{h['text'][:1500]}")
    progress.start("answer")
    print("→ Writing the answer", flush=True)
    answer = LLM(cfg).chat(PROMPT.format(question=question, excerpts="\n\n".join(excerpts)), max_tokens=700,
                           on_token=lambda n: progress.update(0.3 + 0.7 * min(n / 200, 0.97)))
    used = {int(n) for n in re.findall(r"\[(\d+)\]", answer)}
    sources = [{"n": i, "folder": h["folder"], "title": h["title"], "date": h["date"], "time": h["time"]}
               for i, h in enumerate(hits, 1) if i in used]
    return {"answer": answer.strip(), "sources": sources}
