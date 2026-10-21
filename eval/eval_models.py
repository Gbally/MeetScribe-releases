"""Quality / speed check of notes models on fixed test meetings (run before adding a model to
the catalog).   .venv/bin/python eval/eval_models.py mlx-community/Qwen3-8B-4bit [...]"""

import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from meetscribe.cli import write_notes  # noqa: E402
from meetscribe.config import Config  # noqa: E402

FIXTURES = ROOT / "eval" / "fixtures"


def check(notes: dict, exp: dict) -> list[str]:
    problems = []
    if not notes.get("title") or notes["title"].startswith("Meeting 20"):
        problems.append("no AI title")
    if not notes.get("summary"):
        problems.append("empty summary")
    acts = notes.get("actions", [])
    if len(acts) < exp["min_actions"]:
        problems.append(f"{len(acts)} to-dos (expected ≥ {exp['min_actions']})")
    owners = {a["owner"] for a in acts}
    for o in exp["owners"]:
        if o not in owners:
            problems.append(f"missing owner {o}")
    dates = {a.get("due_date") for a in acts}
    for d in exp["due_dates"]:
        if d not in dates:
            problems.append(f"missing due date {d}")
    text = json.dumps(notes, ensure_ascii=False).lower()
    if "<think>" in text:
        problems.append("thinking text leaked")
    for word in exp.get("must_mention", []):
        if word not in text:
            problems.append(f"doesn't mention '{word}'")
    return problems


def run(model: str) -> dict:
    import mlx.core as mx

    expected = json.loads((FIXTURES / "expected.json").read_text())
    cfg = Config(llm_model=model, summary_style="standard", me="Guillaume")
    results = {"model": model, "meetings": {}}
    for name, exp in expected.items():
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / name
            shutil.copytree(FIXTURES / name, session)
            mx.reset_peak_memory()
            t0 = time.time()
            try:
                write_notes(session, cfg)
                notes = json.loads((session / "notes.json").read_text())
                problems = check(notes, exp)
            except Exception as e:  # a model that crashes fails the check
                notes, problems = {}, [f"error: {e.__class__.__name__}: {e}"]
            results["meetings"][name] = {"seconds": round(time.time() - t0), "problems": problems,
                                         "peak_gb": round(mx.get_peak_memory() / 1e9, 1),
                                         "actions": notes.get("actions", [])}
    results["passed"] = all(not m["problems"] for m in results["meetings"].values())
    return results


if __name__ == "__main__":
    for model in sys.argv[1:]:
        r = run(model)
        print("@@eval " + json.dumps(r, ensure_ascii=False), flush=True)
        status = "PASS" if r["passed"] else "FAIL"
        print(f"{status} {model}: " + "; ".join(f"{k} {v['seconds']}s {v['peak_gb']}GB {v['problems'] or 'ok'}"
                                               for k, v in r["meetings"].items()), flush=True)
