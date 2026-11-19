"""Scores to-dos with the judge: the base model (MLX 4-bit), with or without a judge adapter, asked
yes/no about each to-do as judge_data.py asks it. Writes the log-odds of yes, one line per to-do.

  python eval/ami_bench/judge.py OUT.jsonl RUN [RUN…] [--adapter DIR]

RUN: a run.py run folder (data/runs/NAME), its meetings' transcripts in data/sessions. Done to-dos
are skipped when OUT exists (a run cut short goes on). score() is for other benches' runs."""

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "src"))
sys.path.insert(0, str(HERE))

from judge_data import prompt  # noqa: E402
from meetscribe.summarize import SYSTEM  # noqa: E402
from meetscribe.transcript import load_json, to_plain  # noqa: E402


class Judge:
    def __init__(self, adapter: Path | None = None, model: str = "mlx-community/Qwen3.5-4B-4bit"):
        from mlx_lm import load

        self.model, self.tok = load(model, adapter_path=str(adapter) if adapter else None)
        first = lambda w: self.tok.encode(w, add_special_tokens=False)[0]  # noqa: E731
        self.yes = [first(w) for w in ("yes", "Yes", " yes", " Yes")]
        self.no = [first(w) for w in ("no", "No", " no", " No")]

    def score(self, lines: list[str], todo: dict) -> float:
        """log P(yes) − log P(no) for the answer's first token."""
        import mlx.core as mx

        text = self.tok.apply_chat_template([{"role": "system", "content": SYSTEM},
                                             {"role": "user", "content": prompt(lines, todo)}],
                                            add_generation_prompt=True, tokenize=False, enable_thinking=False)
        logits = self.model(mx.array(self.tok.encode(text, add_special_tokens=False))[None])[0, -1]
        s = mx.logsumexp(logits[mx.array(self.yes)]).item() - mx.logsumexp(logits[mx.array(self.no)]).item()
        mx.clear_cache()
        return round(s, 3)


def run_todos(out: Path, jobs, judge: Judge) -> None:
    """jobs: (key prefix, transcript.json, to-dos). Appends {"key", "s"} to out."""
    done = {json.loads(line)["key"] for line in out.read_text().splitlines()} if out.exists() else set()
    with open(out, "a") as f:
        for prefix, transcript, todos in jobs:
            lines = None
            for i, todo in enumerate(todos):
                key = f"{prefix}/{i}"
                if key in done:
                    continue
                lines = lines or to_plain(load_json(transcript)[0]).split("\n")
                f.write(json.dumps({"key": key, "s": judge.score(lines, todo)}) + "\n")
                f.flush()
            print(prefix, len(todos), flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", type=Path)
    ap.add_argument("runs", nargs="+", type=Path)
    ap.add_argument("--adapter", type=Path)
    a = ap.parse_args()
    jobs = [(f"ami/{f.stem}", HERE / "data" / "sessions" / f.stem.rsplit("-", 1)[0] / "transcript.json", json.loads(f.read_text()))
            for run in a.runs for f in sorted(run.glob("*.json"))]
    run_todos(a.out, jobs, Judge(a.adapter))
