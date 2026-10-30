"""Scores a run of run.py against the AMI annotators' actions.

  python3 eval/ami_bench/score.py NAME [--set dev|test|all] [--show]

found: annotated actions that a to-do matches (shares the words that say what the task is);
owner: … with the right person; unmatched: to-dos that match no annotated action. The annotators
only wrote down the main tasks, so some unmatched to-dos are real small ones: compare runs on the
same meetings, don't read unmatched as a count of mistakes. --show lists each meeting's matches."""

import argparse
import json
import re
from pathlib import Path

DATA = Path(__file__).resolve().parent / "data"

STOP = set("""a an the to of for on in at by with and or is be it this that they their them he she his her
will would should also need needs to into about some any all each other own both more which what how
work working look looking come up do doing make making get find finding see check try think go going
team member members next meeting meetings remote control thing things""".split())
ROLES = {"Project Manager": r"project manager|\bpm\b", "Industrial Designer": r"industrial|\bid\b",
         "Interface Designer": r"interface (designer|specialist)|\bui\b", "Marketing Expert": r"marketing expert|\bme\b"}
# Who will do it, not what: "The user interface designer will…" → "will…"
ROLE_NAMES = re.compile(r"\b(the )?(project manager|pm|industrial designer|id|(user )?interface (designer|specialist)|ui|"
                        r"marketing expert|me)\b", re.I)


def stem(word: str) -> str:
    """"presentation", "presenting" → "prese": crude, but enough to match a task's wording."""
    return word[:5] if len(word) >= 5 else word.rstrip("s")


def content(text: str) -> set[str]:
    return {stem(w) for w in re.findall(r"[a-z]+", text.lower()) if w not in STOP and len(w) > 2}


def matches(truth: str, task: str) -> bool:
    """Two words in common that say what the task is, or the one word of a short task."""
    t, m = content(ROLE_NAMES.sub("", truth)), content(task)
    common = t & m
    return len(common) >= 2 or (len(common) == 1 and min(len(t), len(m)) == 1)


def owners(truth: str) -> set[str]:
    """The roles the annotated action names; none (the team, "they") counts any owner as right."""
    return {role for role, pat in ROLES.items() if re.search(pat, truth, re.I)}


def annotated(mid: str) -> list[tuple[str, set[str]]]:
    """The annotated actions with the roles they name ("He will also…": the previous one's). Being
    told something ("they will receive more information by email") isn't a task."""
    out, last = [], set()
    for t in json.loads((DATA / "sessions" / mid / "truth.json").read_text())["actions"]:
        if t == "*NA*" or re.search(r"\breceiv|\binstructions\b", t, re.I):  # *NA*: no actions in that meeting
            continue
        who = owners(t) or (last if re.match(r"(he|she)\b", t, re.I) else set())
        out.append((t, who))
        last = who
    return out


def score(name: str, meetings: list[str], show: bool = False) -> dict:
    tot = {"actions": 0, "found": 0, "owner": 0, "todos": 0, "unmatched": 0, "runs": 0}
    for mid in meetings:
        truth = annotated(mid)
        for f in sorted((DATA / "runs" / name).glob(f"{mid}-*.json")):
            todos = json.loads(f.read_text())
            tot["runs"] += 1
            tot["actions"] += len(truth)
            tot["todos"] += len(todos)
            hit = [False] * len(todos)
            if show:
                print(f"=== {f.stem}")
            for t, who in truth:
                ms = [i for i, a in enumerate(todos) if matches(t, a["task"])]
                for i in ms:
                    hit[i] = True
                right = [i for i in ms if not who or todos[i]["owner"] in who]
                tot["found"] += bool(ms)
                tot["owner"] += bool(right)
                if show:
                    print(f"  {'✓' if right else '~' if ms else '✗'} {t}")
                    for i in ms:
                        print(f"        ← {todos[i]['owner']} | {todos[i]['task']}")
            tot["unmatched"] += hit.count(False)
            if show:
                for a, h in zip(todos, hit):
                    if not h:
                        print(f"  ? {a['owner']} | {a['task']}")
    return tot


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--set", default="dev", choices=["dev", "test", "all"])
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args()
    split = json.loads((DATA / "split.json").read_text())
    s = score(a.name, split["dev"] + split["test"] if a.set == "all" else split[a.set], a.show)
    n = max(1, s["actions"])
    print(f"{a.name} ({a.set}, {s['runs']} meeting runs): found {s['found']}/{s['actions']} ({100 * s['found'] / n:.0f} %), "
          f"right owner {s['owner']} ({100 * s['owner'] / n:.0f} %), to-dos {s['todos']}, unmatched {s['unmatched']} "
          f"({100 * s['unmatched'] / max(1, s['todos']):.0f} %)")
