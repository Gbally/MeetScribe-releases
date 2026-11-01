"""run.py's to-do steps on a PC with an NVIDIA GPU: the model in 4 bits (NF4) with transformers, with
or without a train.py adapter. Not the app's MLX model: compare runs of this script with each other.

  python eval/ami_bench/run_hf.py NAME [--adapter RUN_DIR] [--set dev|test|all] [--rounds 1] [--meetings ID…]

Writes data/runs/NAME/ID-ROUND.json and prints the score, like run.py. The decisions pass is left out
(it doesn't change the to-dos); the extraction passes, checks, second look and merge are the app's."""

import argparse
import hashlib
import json
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

import torch

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DATA = HERE / "data"

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("name")
ap.add_argument("--model", default="Qwen/Qwen3.5-4B")
ap.add_argument("--adapter", type=Path, help="a train.py run folder")
ap.add_argument("--set", default="dev", choices=["dev", "test", "all"])
ap.add_argument("--rounds", type=int, default=1)
ap.add_argument("--meetings", nargs="*", help="only these (of the set)")
a = ap.parse_args()

sys.path.insert(0, str(ROOT / "src"))
from transformers import AutoTokenizer  # noqa: E402

import hf  # noqa: E402
from meetscribe import summarize as S  # noqa: E402
from meetscribe.transcript import load_json, to_plain  # noqa: E402

CACHE = DATA / "cache"
CACHE.mkdir(exist_ok=True)
tok = AutoTokenizer.from_pretrained(a.model)
model = hf.load(a.model)
variant = f"hf-nf4:{a.model}"
if a.adapter:
    from peft import PeftModel

    model = PeftModel.from_pretrained(model, a.adapter)
    variant += "+" + hashlib.sha256((a.adapter / "adapter_model.safetensors").read_bytes()).hexdigest()
model.eval()


class HFLLM(S.LLM):
    round = 1

    def count_tokens(self, text: str) -> int:
        return len(tok.encode(text, add_special_tokens=False))

    @torch.no_grad()
    def chat(self, prompt, max_tokens=2500, on_token=None, prose=False, temperature=None, transcript=None, last=False):
        temperature = S.TEMPERATURE if temperature is None else temperature
        key = hashlib.sha256(json.dumps([variant, self.round, prompt, transcript, max_tokens, temperature,
                                         prose]).encode()).hexdigest()
        f = CACHE / f"{key}.txt"
        if f.exists():
            return f.read_text(encoding="utf-8")
        head = f"Transcript:\n{transcript}\n\n---\n\n" if transcript is not None else ""
        text = tok.apply_chat_template([{"role": "system", "content": S.SYSTEM}, {"role": "user", "content": head + prompt}],
                                       add_generation_prompt=True, tokenize=False, enable_thinking=False)
        ids = tok(text, add_special_tokens=False, return_tensors="pt")["input_ids"].to("cuda")
        gen = model.generate(input_ids=ids, attention_mask=torch.ones_like(ids), max_new_tokens=max_tokens,
                             do_sample=temperature > 0, temperature=temperature or None, top_p=0.8 if temperature else None,
                             top_k=None, repetition_penalty=1.08 if prose else None, pad_token_id=tok.eos_token_id,
                             eos_token_id=[tok.convert_tokens_to_ids("<|im_end|>"), tok.eos_token_id])  # the end of the turn
        out = re.sub(r"<think>.*?</think>", "", tok.decode(gen[0, ids.shape[1]:], skip_special_tokens=True), flags=re.S).strip()
        f.write_text(out, encoding="utf-8")
        return out


split = json.loads((DATA / "split.json").read_text())
meetings = split["dev"] + split["test"] if a.set == "all" else split[a.set]
meetings = [m for m in meetings if not a.meetings or m in a.meetings]
out = DATA / "runs" / a.name
out.mkdir(parents=True, exist_ok=True)
llm = HFLLM(SimpleNamespace(llm_model=a.model, llm_backend="hf"))
for r in range(1, a.rounds + 1):
    for mid in meetings:
        torch.manual_seed(r)
        utterances, meta = load_json(DATA / "sessions" / mid / "transcript.json")
        transcript, meeting = to_plain(utterances), datetime.fromisoformat(meta["created"]).date()
        llm.round = r
        t0 = time.time()
        raw = "".join(llm.chat(S.ACTIONS_PROMPT.format(language="English"), transcript=part, max_tokens=900,
                               temperature=S.EXTRACT_TEMPERATURE)
                      for part in S._parts(llm, transcript, S.EXTRACT_TOKENS))
        checked = S.check_actions(raw, transcript, meeting)
        actions = S.merge_actions(checked + S.second_look(llm, "English", transcript, checked, meeting))
        (out / f"{mid}-{r}.json").write_text(json.dumps(actions, indent=1, ensure_ascii=False), encoding="utf-8")
        print(f"{mid} round {r}: {len(actions)} to-dos in {time.time() - t0:.0f}s", flush=True)

subprocess.run([sys.executable, str(HERE / "score.py"), a.name, "--set", a.set])
