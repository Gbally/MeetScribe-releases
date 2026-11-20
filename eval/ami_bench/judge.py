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

from judge_data import PROMPT, prompt  # noqa: E402
from hesper.summarize import SYSTEM  # noqa: E402
from hesper.transcript import load_json, to_plain  # noqa: E402


class Judge:
    """version 2: the instructions come first and are read once (cached), then for each to-do only its
    lines and itself. version 1: judge-r16 / judge-r16s's question."""

    def __init__(self, adapter: Path | None = None, model: str = "mlx-community/Qwen3.5-4B-4bit", version: int = 2):
        from mlx_lm import load

        self.model, self.tok = load(model, adapter_path=str(adapter) if adapter else None)
        self.version, self._prefix = version, None
        first = lambda w: self.tok.encode(w, add_special_tokens=False)[0]  # noqa: E731
        self.yes = [first(w) for w in ("yes", "Yes", " yes", " Yes")]
        self.no = [first(w) for w in ("no", "No", " no", " No")]

    def score(self, lines: list[str], todo: dict) -> float:
        """log P(yes) − log P(no) for the answer's first token."""
        import copy

        import mlx.core as mx
        from mlx_lm.models.cache import make_prompt_cache

        text = self.tok.apply_chat_template([{"role": "system", "content": SYSTEM},
                                             {"role": "user", "content": prompt(lines, todo, self.version)}],
                                            add_generation_prompt=True, tokenize=False, enable_thinking=False)
        ids = self.tok.encode(text, add_special_tokens=False)
        done, state = 0, None
        if self.version == 2:
            if self._prefix is None:  # the instructions, the same for every to-do: read once
                head = self.tok.encode(text[:text.index(PROMPT) + len(PROMPT)], add_special_tokens=False)
                cache = make_prompt_cache(self.model)
                self.model(mx.array(head)[None], cache=cache)
                mx.eval([c.state for c in cache])
                self._prefix = (head, cache)
            head, cache = self._prefix
            if ids[:len(head)] == head:
                done, state = len(head), copy.deepcopy(cache)
        logits = self.model(mx.array(ids[done:])[None], cache=state)[0, -1]
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
    ap.add_argument("--version", type=int, default=2, help="the question's format: 1 for judge-r16 and judge-r16s")
    a = ap.parse_args()
    jobs = [(f"ami/{f.stem}", HERE / "data" / "sessions" / f.stem.rsplit("-", 1)[0] / "transcript.json", json.loads(f.read_text()))
            for run in a.runs for f in sorted(run.glob("*.json"))]
    run_todos(a.out, jobs, Judge(a.adapter, version=a.version))
