"""Training data for a to-do adapter: the AMI meetings that are in neither the dev nor the test set,
cut into the parts the app reads (summarize._parts), each with the answer the to-do pass should give.

  python eval/ami_bench/train_data.py [--tokenizer Qwen/Qwen3.5-4B]

Writes data/train/train.jsonl and valid.jsonl (whole meetings held out), one example per line:
{"meeting", "part", "messages": [system, user, assistant]}, the user message being what LLM.chat sends.

The answer comes from the annotators' actions. The corpus links each sentence of a summary to the
dialogue acts it was written from (extractive/*.summlink.xml): the action goes at the line that says
it, with a quote of that act. A part where the meeting has no action gets an empty answer: that is
what teaches the model to skip ideas and things done in the meeting. Parts that can't be labelled
for sure are left out: those with an action this script can't write as a task (group tasks, odd
wordings), and, in a meeting with an action linked to no line, all the parts without an action."""

import argparse
import json
import random
import re
import sys
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DATA = HERE / "data"
CORPUS = DATA / "ami"
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(HERE))

from convert import ROLE, roles, section, utterances  # noqa: E402
from meetscribe import summarize as S  # noqa: E402
from meetscribe.transcript import Utterance, to_plain  # noqa: E402
from score import content  # noqa: E402

MEETING = date(2005, 1, 10)  # convert.py's "created"
OWNERS = [(re.compile(p), ROLE[r]) for p, r in  # the annotators' spellings, typos included
          ((r"(?i:project manager)|\bPM\b", "PM"), (r"(?i:industrial \w+)|\bID\b", "ID"),
           (r"(?i:interface (designer|specialist))|\bUI\b", "UI"), (r"(?i:marketing (expert|executive|manager|specialist))|\bME\b", "ME"))]
MODAL = re.compile(r"\b(will|is going to|are going to|has to|have to|must|(was|were) (instructed|asked|told) to|is to|are to)\b\s*(also\s+)?",
                   re.I)
INSTRUCTED = re.compile(r"\b(instructed|asked|told)\b(.*?)\bto\b\s*", re.I)  # "The PM instructed the UI and ID to construct…"
CLAUSES = re.compile(r",?\s+(?:and|while)\s+(?=(?:the|he|she)\b[^,]*?\b(?:will|is going to|has to|must)\b)", re.I)
ID = re.compile(r"#id\(([^)]+)\)(?:\.\.id\(([^)]+)\))?")


def tasks(sentence: str, last: list[str]) -> list[tuple[list[str], str]]:
    """"The industrial designer will work on the components concept." → [(["Industrial Designer"],
    "work on the components concept")]. Owners [] when none of the four roles is named (the team,
    "they"): not written as a task. "He will also…": the previous sentence's owners."""
    sentence = sentence.strip().rstrip(".")
    clauses, start = [], 0
    for m in CLAUSES.finditer(sentence):  # "The UI will…, and the ID will…" — not "The UI and the ID will…"
        if MODAL.search(sentence[start:m.start()]):
            clauses.append(sentence[start:m.start()])
            start = m.end()
    out = []
    for clause in clauses + [sentence[start:]]:
        m = MODAL.search(clause)
        i = INSTRUCTED.search(clause)
        if i and (not m or i.start() < m.start()):
            subject, task = i.group(2), clause[i.end():].strip()
        elif m:
            subject, task = clause[:m.start()], clause[m.end():].strip()
        else:
            out.append(([], clause))
            continue
        who = [name for pat, name in OWNERS if pat.search(subject)]
        if not who and re.fullmatch(r"\s*(he|she)\s*", subject, re.I):
            who = last
        out.append((who, task[:1].lower() + task[1:]))
        last = who
    return out


class Counter:
    """What _parts needs from the LLM: the model's own token count."""

    def __init__(self, name: str):
        from transformers import AutoTokenizer

        self.tok = AutoTokenizer.from_pretrained(name)

    def count_tokens(self, text: str) -> int:
        return len(self.tok.encode(text, add_special_tokens=False))


def dialogue_acts(mid: str) -> dict[str, list[str]]:
    """Dialogue act id → the ids of its words."""
    out = {}
    for agent in roles(mid):
        words = CORPUS / "words" / f"{mid}.{agent}.words.xml"
        acts = CORPUS / "dialogueActs" / f"{mid}.{agent}.dialog-act.xml"
        if not (words.exists() and acts.exists()):
            continue
        order = re.findall(r'nite:id="([^"]+)"', words.read_text(encoding="latin-1"))
        pos = {w: i for i, w in enumerate(order)}
        for act, body in re.findall(r'<dact nite:id="([^"]+)"(.*?)</dact>', acts.read_text(encoding="latin-1"), re.S):
            ids = []
            for a, b in ID.findall(" ".join(re.findall(r'<nite:child href="([^"]+)"', body))):
                ids += order[pos[a]:pos[b or a] + 1]
            out[act] = ids
    return out


def links(mid: str) -> dict[str, list[str]]:
    """Summary sentence id → the dialogue acts it was written from."""
    f = CORPUS / "extractive" / f"{mid}.summlink.xml"
    out = {}
    if f.exists():
        for act, sentence in re.findall(r'role="extractive"\s+href="[^"]*#id\(([^)]+)\)"/>\s*'
                                        r'<nite:pointer role="abstractive"\s+href="[^"]*#id\(([^)]+)\)"',
                                        f.read_text(encoding="latin-1")):
            out.setdefault(sentence, []).append(act)
    return out


def quote(u: dict, ids: list[str], about: set[str]) -> str:
    """5 to 8 words of the act, copied from the line: the ones that share the most words with the
    action. A shorter act takes the words around it."""
    words = [(w, a, b) for w, a, b in u["words"] if re.search(r"\w", u["text"][a:b])]
    at = [i for i, (w, _, _) in enumerate(words) if w in set(ids)]
    lo, hi = at[0], at[-1] + 1
    if hi - lo < 5:
        lo = max(0, lo - (5 - (hi - lo)) // 2)
        hi = min(len(words), lo + 5)
        lo = max(0, hi - 5)
    n = min(8, hi - lo)
    best = max(range(lo, hi - n + 1), key=lambda i: (len(content(u["text"][words[i][1]:words[i + n - 1][2]]) & about), -i))
    return u["text"][words[best][1]:words[best + n - 1][2]]


def meeting(mid: str, counter: Counter, report: dict) -> list[dict]:
    summary = (CORPUS / "abstractive" / f"{mid}.abssumm.xml").read_text(encoding="latin-1")
    ids = re.search(r"<actions.*?</actions>", summary, re.S)
    sentences = list(zip(re.findall(r'<sentence nite:id="([^"]+)"', ids.group(0)) if ids else [],
                         section(summary, "actions")))
    utts = utterances(mid)
    where = {w: i for i, u in enumerate(utts) for w, _, _ in u["words"]}
    acts, linked = dialogue_acts(mid), links(mid)

    # Each action: its tasks, and the lines (with their acts) that say it.
    keep, blocked, sure = [], set(), True
    last = []
    for sid, text in sentences:
        if text == "*NA*" or re.search(r"\breceiv|\binstructions\b", text, re.I):  # as score.py
            continue
        lines = {}
        for act in linked.get(sid, []):
            for w in acts.get(act, []):
                if w in where:
                    lines.setdefault(where[w], []).append(w)
        parsed = tasks(text, last)
        last = parsed[-1][0] if parsed else []
        report["actions"] += 1
        if not lines:
            report["no line"] += 1
            sure = False
            continue
        for who, task in parsed:
            if who and len(task.split()) >= 2:
                keep.append((who, task, text, lines))
                report["tasks"] += len(who)
            else:
                blocked |= set(lines)
                report["not a task"] += 1
                report.setdefault("not a task, e.g.", []).append(text)

    transcript = to_plain([Utterance(**{k: v for k, v in u.items() if k != "words"}) for u in utts])
    all_lines = transcript.splitlines()
    assert len(all_lines) == len(utts)
    parts, start = [], 0
    for part in S._parts(counter, transcript, S.EXTRACT_TOKENS):
        n = part.count("\n") + 1
        start = next(s for s in range(max(0, start - 2), len(all_lines)) if all_lines[s:s + n] == part.splitlines())
        parts.append((part, range(start, start + n)))
        start += n

    out = []
    for k, (part, span) in enumerate(parts):
        if blocked & set(span):
            report["parts left out"] += 1
            continue
        answer = []
        for who, task, text, lines in keep:
            here = [i for i in lines if i in span]
            if not here:
                continue
            about = content(text)
            i = max(here, key=lambda i: (len(content(" ".join(utts[i]["text"][a:b] for w, a, b in utts[i]["words"]
                                                              if w in set(lines[i]))) & about), -i))
            t = int(utts[i]["start"])
            for owner in who:
                answer.append(json.dumps({"owner": owner, "task": task, "due": "",
                                          "at": f"{t // 3600:02d}:{t % 3600 // 60:02d}:{t % 60:02d}",
                                          "quote": quote(utts[i], lines[i], about)}, ensure_ascii=False))
        if not answer and not sure:
            report["parts left out"] += 1
            continue
        raw = "\n".join(answer)
        checked = S.check_actions(raw, part, MEETING)
        report["dropped by check_actions"] += len(answer) - len(checked)
        if len(checked) < len(answer):
            report.setdefault("dropped, e.g.", []).append(raw)
        report["parts"] += 1
        report["parts with to-dos"] += bool(answer)
        out.append({"meeting": mid, "part": k + 1, "messages": [
            {"role": "system", "content": S.SYSTEM},
            {"role": "user", "content": f"Transcript:\n{part}\n\n---\n\n" + S.ACTIONS_PROMPT.format(language="English")},
            {"role": "assistant", "content": raw}]})
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tokenizer", default="Qwen/Qwen3.5-4B")
    ap.add_argument("--valid", type=float, default=0.1, help="share of the meetings held out for validation")
    a = ap.parse_args()
    split = json.loads((DATA / "split.json").read_text())
    held = set(split["dev"] + split["test"])  # only for scoring, never for training
    mids = sorted(f.name.split(".")[0] for f in (CORPUS / "abstractive").glob("*.abssumm.xml"))
    mids = [m for m in mids if m[:2] in ("ES", "IS", "TS") and m not in held]  # the others have no roles to name owners
    random.Random(0).shuffle(mids)
    valid = set(mids[:round(len(mids) * a.valid)])
    counter = Counter(a.tokenizer)
    report = {k: 0 for k in ("actions", "no line", "not a task", "tasks", "parts", "parts with to-dos",
                             "parts left out", "dropped by check_actions")}
    out = DATA / "train"
    out.mkdir(exist_ok=True)
    with open(out / "train.jsonl", "w", encoding="utf-8") as tr, open(out / "valid.jsonl", "w", encoding="utf-8") as va:
        for mid in sorted(mids):
            for ex in meeting(mid, counter, report):
                (va if mid in valid else tr).write(json.dumps(ex, ensure_ascii=False) + "\n")
    (out / "report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"{len(mids)} meetings ({len(valid)} for validation) → {out}")
    print({k: v for k, v in report.items() if not isinstance(v, list)})
