"""Training data for a to-do judge: the base model's own to-dos on the AMI training meetings, each
with yes (a real task) or no (noise), asked the way the judge pass asks.

  python3 eval/ami_bench/run.py judge-cands --set train --rounds 1   # the candidates (Mac, MLX)
  python3 eval/ami_bench/judge_data.py [--cands judge-cands]          # → judge_set/train.jsonl, valid.jsonl
  python eval/ami_bench/train.py judge-r16 --data eval/ami_bench/judge_set --pos-repeat 1      # (PC)

judge_set/ is in the repository (AMI, CC BY 4.0, University of Edinburgh), so the training PC needs
neither the candidates nor the model run that made them.

A candidate is a real task when it says one of the annotators' actions (score.matches), or when it
is on a line an action was written from (extractive/*.summlink.xml) and shares a word with that
action. The
annotators only wrote the main tasks: the "no" were read by hand and the real small tasks among them
(76 of 585: "I'll get back to you on that", "I'll put the minutes in the project folder") are in
judge_relabel.json, made yes here. Meetings are split as in train_data.py (same validation meetings)."""

import argparse
import json
import random
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DATA = HERE / "data"
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(HERE))

from meetscribe import summarize as S  # noqa: E402
from meetscribe.transcript import load_json, to_plain  # noqa: E402
from score import annotated, content, matches  # noqa: E402
from train_data import dialogue_acts, links  # noqa: E402
from convert import section, utterances  # noqa: E402

PROMPT = """Lines from a meeting transcript:
{ctx}

From the line marked >>, this to-do was noted:
{owner}: {task}

A real to-do is something that person takes on, or is given, to do AFTER the meeting. It is NOT one if it is an idea or a suggestion still being discussed, something done during the meeting itself (presenting, showing, discussing, drawing), something already done, an opinion, or something that only might happen.
Is it a real to-do? Answer yes or no."""
BEFORE, AFTER = 5, 2  # context lines around the to-do's line


def context(lines: list[str], n: int | None, quote: str) -> str:
    if n is None or not 0 <= n < len(lines):
        return ">> " + quote
    return "\n".join(("   ", ">> ")[k == n] + lines[k][:400] for k in range(max(0, n - BEFORE), min(len(lines), n + AFTER + 1)))


def prompt(lines: list[str], todo: dict) -> str:
    return PROMPT.format(ctx=context(lines, todo.get("line"), todo.get("quote", "")), owner=todo["owner"], task=todo["task"])


def action_lines(mid: str) -> dict[int, set[str]]:
    """The transcript lines the annotated actions were written from → those actions' words."""
    summary = (DATA / "ami" / "abstractive" / f"{mid}.abssumm.xml").read_text(encoding="latin-1")
    block = re.search(r"<actions.*?</actions>", summary, re.S)
    sids = re.findall(r'<sentence nite:id="([^"]+)"', block.group(0)) if block else []
    texts = dict(zip(sids, section(summary, "actions")))
    utts = utterances(mid)
    where = {w: i for i, u in enumerate(utts) for w, _, _ in u["words"]}
    acts, linked = dialogue_acts(mid), links(mid)
    out = {}
    for sid in sids:
        for act in linked.get(sid, []):
            for w in acts.get(act, []):
                if w in where:
                    out.setdefault(where[w], set()).update(content(texts.get(sid, "")))
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cands", default="judge-cands", help="a run.py --set train run")
    ap.add_argument("--valid", type=float, default=0.1)
    ap.add_argument("--synth", type=int, default=3, help="the invented work-call examples (judge_synth.py), this many times")
    a = ap.parse_args()
    split = json.loads((DATA / "split.json").read_text())
    held = set(split["dev"] + split["test"])
    files = sorted((DATA / "runs" / a.cands).glob("*.json"))
    mids = sorted({f.stem.rsplit("-", 1)[0] for f in files})
    assert not held & set(mids), "dev/test meetings are only for scoring"
    order = list(mids)
    random.Random(0).shuffle(order)
    valid = set(order[:round(len(order) * a.valid)])
    out = HERE / "judge_set"
    out.mkdir(exist_ok=True)
    relabel = {(r["meeting"], r["todo"], r["at"]) for r in json.loads((HERE / "judge_relabel.json").read_text())}
    report = {"yes": 0, "no": 0, "yes by words": 0, "yes by line only": 0, "yes by hand": 0, "examples": {"yes": [], "no": []}}
    rng = random.Random(1)
    with open(out / "train.jsonl", "w", encoding="utf-8") as tr, open(out / "valid.jsonl", "w", encoding="utf-8") as va:
        for f in files:
            mid = f.stem.rsplit("-", 1)[0]
            truth = annotated(mid)
            said = action_lines(mid)
            lines = to_plain(load_json(DATA / "sessions" / mid / "transcript.json")[0]).split("\n")
            for todo in json.loads(f.read_text()):
                by_words = any(matches(t, todo["task"]) for t, _ in truth)
                yes = by_words or bool(said.get(todo.get("line"), set()) & content(todo["task"]))
                at = (lines[todo["line"]][1:9] if todo.get("line") is not None and 0 <= todo["line"] < len(lines) else "")
                if not yes and (mid, f'{todo["owner"]}: {todo["task"]}', at) in relabel:
                    yes = True
                    report["yes by hand"] += 1
                report["yes" if yes else "no"] += 1
                report["yes by words"] += by_words
                report["yes by line only"] += yes and not by_words
                p = prompt(lines, todo)
                if rng.random() < 0.05:
                    report["examples"]["yes" if yes else "no"].append(p.split("\n\nA real to-do")[0])
                (va if mid in valid else tr).write(json.dumps({"meeting": mid, "messages": [
                    {"role": "system", "content": S.SYSTEM}, {"role": "user", "content": p},
                    {"role": "assistant", "content": "yes" if yes else "no"}]}, ensure_ascii=False) + "\n")
        from judge_synth import examples as synth  # what AMI lacks: sharing / inviting after the call, other languages

        for lines, todo, answer in synth():
            ex = {"meeting": "synth", "messages": [{"role": "system", "content": S.SYSTEM},
                                                   {"role": "user", "content": prompt(lines, todo)},
                                                   {"role": "assistant", "content": answer}]}
            for _ in range(a.synth):
                tr.write(json.dumps(ex, ensure_ascii=False) + "\n")
            report["synth " + answer] = report.get("synth " + answer, 0) + a.synth
    (out / "report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"{len(mids)} meetings ({len(valid)} for validation) → {out}")
    print({k: v for k, v in report.items() if k != "examples"})
