"""Report of a notes benchmark run:   report.py OUT   → tables, and OUT/report.json.
Each meeting counts the same in the means; a rubric is 0–10."""

import json
import re
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from scenarios import SCENARIOS  # noqa: E402
from score import score, score_engine  # noqa: E402

WEIGHTS = {"To-dos found": .12, "To-dos without noise": .08, "Owner named": .08, "Deadlines": .07, "Decisions": .15,
           "Summary topics": .15, "Figures": .08, "Risks": .07, "Ideas (workshop)": .10, "Strengths (interview)": .10}
UNNAMED = re.compile(r"^Speaker \d+$")


def clip(x):
    return max(0.0, min(10.0, x))


def rubric(m: dict) -> dict:
    r = {"To-dos found": 10 * m["tasks_found"] / m["tasks_total"],
         "To-dos without noise": 10 * m["tasks_found"] / m["rows"] if m["rows"] else 0,
         "Owner named": 10 * m.get("tasks_named", m["tasks_found"]) / m["tasks_found"] if m["tasks_found"] else 0,
         "Deadlines": clip((10 * m["right_due"] / m["dues_total"] if m.get("dues_total") else 10) - 2 * m["wrong_due"]),
         "Decisions": 10 * m["decisions"] / m["decisions_total"], "Summary topics": 10 * m["topics"] / m["topics_total"],
         "Figures": 10 * m["figures"] / m["figures_total"], "Risks": 10 * m["risks"] / m["risks_total"]}
    if "ideas" in m:
        r["Ideas (workshop)"] = 10 * m["ideas"] / m["ideas_total"]
    if "strengths" in m:
        r["Strengths (interview)"] = 10 * m["strengths"] / m["strengths_total"]
    return r


def overall(r: dict) -> float:
    return sum(r[k] * WEIGHTS[k] for k in r) / sum(WEIGHTS[k] for k in r)


def attribution(run: Path, sc: str) -> dict:
    """Against who really spoke: share of the words under a label whose main person they are, people
    without a label of their own (merged), names put on the wrong voice."""
    tf, truth_f = run / sc / "meeting" / "transcript.json", run / sc / "meeting" / "truth_turns.json"
    if not tf.exists() or not truth_f.exists():
        return {}
    tr, truth = json.loads(tf.read_text()), json.loads(truth_f.read_text())

    def who(u):
        ov = defaultdict(float)
        for t in truth:
            ov[t["person"]] += max(0.0, min(u["end"], t["end"]) - max(u["start"], t["start"]))
        return max(ov, key=ov.get) if ov and max(ov.values()) > 0 else None

    words = defaultdict(lambda: defaultdict(int))
    for u in tr["utterances"]:
        p = who(u)
        if p:
            words[u["speaker"]][p] += len(u["text"].split())
    main = {lb: max(v, key=v.get) for lb, v in words.items()}
    total = sum(sum(v.values()) for v in words.values()) or 1
    first = lambda x: x.split()[0].lower()
    me = "Guillaume"
    labels = {u["speaker"] for u in tr["utterances"]} - {me}
    return dict(attribution=round(100 * sum(words[lb][main[lb]] for lb in words) / total, 1),
                voices=len(labels), merged=sorted({t["person"] for t in truth} - set(main.values())),
                named=sorted(lb for lb in labels if not UNNAMED.match(lb)),
                wrong_names=sorted(f"{lb}→{main[lb]}" for lb in words if not UNNAMED.match(lb) and first(lb) != first(main[lb])))


def main():
    run = Path(sys.argv[1])
    rows = defaultdict(list)
    for d in sorted(run.glob("*/*-*-*")):
        if not (d / "notes.json").exists() or d.parent.name == "homes":
            continue
        sc, (arm, tpl, _) = d.parent.name, d.name.rsplit("-", 2)
        m = score_engine(d / "notes.json") if sc == "engine" else score(sc, d / "notes.json", d / "transcript.json")
        rows[(sc, arm, tpl)].append((rubric(m), m))
    secs = defaultdict(list)
    for line in (run / "times.txt").read_text().splitlines() if (run / "times.txt").exists() else []:
        m = re.match(r"(\S+) (\S+) (\S+) (\d+) exit=0 seconds=(\d+)", line)
        if m:
            secs[(m[1], m[2], m[3])].append(int(m[5]))
    cells = {}
    for (sc, arm, tpl), runs in sorted(rows.items()):
        ov = [overall(r) for r, _ in runs]
        dp = [10 * m["dec_matched"] / m["dec_rows"] for _, m in runs if m.get("dec_rows")]
        cells[f"{sc}|{arm}|{tpl}"] = dict(
            n=len(runs), overall=round(st.mean(ov), 2), spread=round(max(ov) - min(ov), 2),
            seconds=round(st.mean(secs.get((sc, arm, tpl), [0]))), decisions_without_noise=round(st.mean(dp), 1) if dp else None,
            rubric={k: round(st.mean(r[k] for r, _ in runs), 1) for k in runs[0][0]},
            missed={x: sum(x in m.get("missing", []) for _, m in runs) for x in {x for _, m in runs for x in m.get("missing", [])}})
    arms = sorted({k.split("|")[1] for k in cells})
    report = {"cells": cells, "arms": {}, "speakers": {sc: attribution(run, sc) for sc in SCENARIOS if (run / sc).exists()}}
    print(f"{'meeting':16} " + " ".join(f"{a:>16}" for a in arms))
    for sc in sorted({k.split("|")[0] for k in cells}):
        line = f"{sc:16} "
        for a in arms:
            c = [v for k, v in cells.items() if k.startswith(f"{sc}|{a}|")]
            text = f"{st.mean(x['overall'] for x in c):.2f} ({st.mean(x['seconds'] for x in c):.0f}s)" if c else "—"
            line += f"{text:>16} "
        print(line)
    for a in arms:
        c = [v for k, v in cells.items() if k.split("|")[1] == a]
        by_meeting = defaultdict(list)
        for k, v in cells.items():
            if k.split("|")[1] == a:
                by_meeting[k.split("|")[0]].append(v["overall"])
        rub = defaultdict(list)
        for v in c:
            for name, x in v["rubric"].items():
                rub[name].append(x)
        report["arms"][a] = dict(overall=round(st.mean(st.mean(v) for v in by_meeting.values()), 2),
                                 rubric={k: round(st.mean(v), 1) for k, v in rub.items()})
        print(f"\n{a}: overall {report['arms'][a]['overall']:.2f}   " + "  ".join(f"{k} {v:.1f}" for k, v in report["arms"][a]["rubric"].items()))
    if report["speakers"]:
        print("\nspeakers (transcription):")
        for sc, v in report["speakers"].items():
            if v:
                print(f"  {sc:16} {v['voices']} voices, {v['attribution']}% of words to the right person, named {v['named']}"
                      + (f", MERGED {v['merged']}" if v["merged"] else "") + (f", WRONG {v['wrong_names']}" if v["wrong_names"] else ""))
    (run / "report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
