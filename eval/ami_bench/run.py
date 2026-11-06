"""To-do extraction on the AMI meetings, as the app does it (extraction passes, checks, second look,
merge), without the notes pass. Every model answer is kept in data/cache, so after the first run a
change to the rules is scored in minutes: only the prompts it changes go to the model again.

  "$HOME/Library/Application Support/MeetScribe/venv/bin/python" eval/ami_bench/run.py NAME \\
      [--set dev|test|all] [--rounds 2] [--model mlx-community/Qwen3.5-4B-4bit] [--src DIR]

Writes data/runs/NAME/ID-ROUND.json (the to-dos) and prints the score (score.py NAME again).
--src: another copy of the engine's code (a variant to compare), else this repository's src/.
Each round is its own sample of the model (it runs at the app's temperature)."""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DATA = HERE / "data"
SUPPORT = Path.home() / "Library/Application Support/MeetScribe"

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("name")
ap.add_argument("--set", default="dev", choices=["dev", "test", "all"])
ap.add_argument("--rounds", type=int, default=2)
ap.add_argument("--model", default="mlx-community/Qwen3.5-4B-4bit")
ap.add_argument("--src", type=Path, default=ROOT / "src")
ap.add_argument("--adapter", type=Path, help="an mlx-lm LoRA adapter (to_mlx.py's output), for the extraction passes")
ap.add_argument("--adapter-scale", type=float, help="the LoRA scale, instead of the adapter's own (weaker: lower)")
ap.add_argument("--adapter-everywhere", action="store_true", help="… and for the second look too")
a = ap.parse_args()

home = DATA / "home"
home.mkdir(parents=True, exist_ok=True)
(home / "config.toml").write_text(f'llm_model = "{a.model}"\nlanguage = "en"\n')
if not (home / "models").exists():
    (home / "models").symlink_to(SUPPORT / "models")
os.environ["MEETSCRIBE_HOME"] = str(home)
sys.path.insert(0, str(a.src.resolve()))

from meetscribe import summarize as S  # noqa: E402
from meetscribe.config import load_config  # noqa: E402
from meetscribe.transcript import load_json, to_plain  # noqa: E402

CACHE = DATA / "cache"
CACHE.mkdir(exist_ok=True)
# The adapter's weights, not its folder: a run trained again under the same name gets new answers
ADAPTER = hashlib.sha256((a.adapter / "adapters.safetensors").read_bytes()).hexdigest() if a.adapter else ""
if a.adapter_scale is not None:
    ADAPTER += f"@{a.adapter_scale}"


class CachedLLM(S.LLM):
    round = 1
    adapter_on = True  # off: the LoRA layers' scale at 0, so the base model (as run_hf.py does it)

    def _load(self):
        if self._model is None and a.adapter:
            from mlx_lm import load
            self._model, self._tokenizer = load(self.cfg.llm_model, adapter_path=str(a.adapter))
            self._lora = [(m, m.scale if a.adapter_scale is None else a.adapter_scale)
                          for _, m in self._model.named_modules() if hasattr(m, "lora_a")]
            for m, scale in self._lora:
                m.scale = scale
        super()._load()

    def use_adapter(self, on: bool):
        if a.adapter and on != self.adapter_on:
            self._load()
            for m, scale in self._lora:
                m.scale = scale if on else 0.0
            self.adapter_on, self._read = on, None  # the transcript read with the other weights

    def chat(self, prompt, max_tokens=2500, on_token=None, prose=False, temperature=None, transcript=None, last=False):
        model = self.cfg.llm_model + (f"+{ADAPTER}" if a.adapter and self.adapter_on else "")  # the cache tells them apart
        key = hashlib.sha256(json.dumps([model, self.round, prompt, transcript, max_tokens, temperature,
                                         prose]).encode()).hexdigest()
        f = CACHE / f"{key}.txt"
        if f.exists():
            return f.read_text()
        out = super().chat(prompt, max_tokens, on_token, prose, temperature, transcript, last)
        f.write_text(out)
        return out


split = json.loads((DATA / "split.json").read_text())
meetings = split["dev"] + split["test"] if a.set == "all" else split[a.set]
out = DATA / "runs" / a.name
out.mkdir(parents=True, exist_ok=True)
llm = CachedLLM(load_config())
for r in range(1, a.rounds + 1):  # round by round, so a run cut short still covers every meeting
    for mid in meetings:
        utterances, meta = load_json(DATA / "sessions" / mid / "transcript.json")
        transcript, meeting = to_plain(utterances), datetime.fromisoformat(meta["created"]).date()
        llm.round, llm._read = r, None
        llm.use_adapter(True)
        t0 = time.time()
        parts = S._parts(llm, transcript, S.EXTRACT_TOKENS)
        raw, _ = S._extract(llm, "English", parts)
        checked = S.check_actions(raw, transcript, meeting)
        llm.use_adapter(a.adapter_everywhere)
        actions = S.merge_actions(checked + S.second_look(llm, "English", transcript, checked, meeting))
        (out / f"{mid}-{r}.json").write_text(json.dumps(actions, indent=1, ensure_ascii=False))
        print(f"{mid} round {r}: {len(actions)} to-dos in {time.time() - t0:.0f}s", flush=True)

subprocess.run([sys.executable, str(HERE / "score.py"), a.name, "--set", a.set])
