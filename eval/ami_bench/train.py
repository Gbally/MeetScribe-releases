"""QLoRA on the to-do pass, with the examples of train_data.py (NVIDIA GPU, 8 GB is enough).

  python eval/ami_bench/train.py NAME [--rank 16] [--epochs 2] [--lr 1e-4] [--pos-repeat 2] [--max-steps N]
  python eval/ami_bench/train.py judge-r16 --data eval/ami_bench/judge_set --pos-repeat 1 --epochs 2   # the judge

Writes the adapter to OUT/NAME (default OUT: the folder above the repository, runs/), with
args.json and the losses in log.json, so runs stay comparable; the adapter of the step with the
lowest validation loss in OUT/NAME/best (to_mlx.py OUT/NAME/best converts it). The loss counts only the answer:
the prompt is the one LLM.chat sends, with the chat template the app uses (no thinking).
--pos-repeat: each part with to-dos is seen that many times per epoch (most parts have none).
--neg-per-pos: fewer empty parts. With all of them (5.5 per part with to-dos), r16-e2 learnt to
answer nothing."""

import argparse
import json
import random
import time
from pathlib import Path

import torch

HERE = Path(__file__).resolve().parent
DATA = HERE / "data" / "train"

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("name")
ap.add_argument("--model", default="Qwen/Qwen3.5-4B")
ap.add_argument("--out", type=Path, default=HERE.parents[2] / "runs")
ap.add_argument("--data", type=Path, default=DATA, help="train.jsonl + valid.jsonl (default: train_data.py's; judge_set: judge_data.py's)")
ap.add_argument("--rank", type=int, default=16)
ap.add_argument("--alpha", type=int, default=32)
ap.add_argument("--dropout", type=float, default=0.05)
ap.add_argument("--epochs", type=float, default=2)
ap.add_argument("--lr", type=float, default=1e-4)
ap.add_argument("--accum", type=int, default=8, help="examples per optimizer step")
ap.add_argument("--pos-repeat", type=int, default=2)
ap.add_argument("--neg-per-pos", type=float, help="keep this many empty parts per part with to-dos (default: all)")
ap.add_argument("--max-len", type=int, default=4096)
ap.add_argument("--max-steps", type=int, default=0, help="stop after N optimizer steps (a quick test)")
ap.add_argument("--seed", type=int, default=0)
ap.add_argument("--save-every", type=int, default=0, help="also keep the adapter every N steps (a multiple of 10) in NAME/step-N")
a = ap.parse_args()

from peft import LoraConfig, get_peft_model  # noqa: E402
from torch.nn.attention import SDPBackend, sdpa_kernel  # noqa: E402
from transformers import AutoTokenizer  # noqa: E402

import hf  # noqa: E402

torch.manual_seed(a.seed)
tok = AutoTokenizer.from_pretrained(a.model)


def encode(ex: dict) -> tuple[list[int], int]:
    """The tokens of prompt + answer, and how many of them are the answer (the only part learnt)."""
    prompt = tok.apply_chat_template(ex["messages"][:2], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    p = tok(prompt, add_special_tokens=False)["input_ids"]
    r = tok(ex["messages"][2]["content"] + "<|im_end|>\n", add_special_tokens=False)["input_ids"]
    p = p[-(a.max_len - len(r)):]
    return p + r, len(r)


def examples(name: str) -> list[dict]:
    return [json.loads(line) for line in (a.data / name).read_text(encoding="utf-8").splitlines()]


pos = [ex for ex in examples("train.jsonl") if ex["messages"][2]["content"]]
neg = [ex for ex in examples("train.jsonl") if not ex["messages"][2]["content"]]
if a.neg_per_pos is not None:  # the same empty parts for every run with the same seed
    neg = random.Random(a.seed).sample(neg, min(len(neg), round(len(pos) * a.neg_per_pos)))
train = [encode(ex) for ex in pos for _ in range(a.pos_repeat)] + [encode(ex) for ex in neg]
valid = [encode(ex) for ex in examples("valid.jsonl")]

model = hf.load(a.model)
# Not peft's prepare_model_for_kbit_training: it makes the embeddings float32, 1.2 GB more for nothing
model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
model.enable_input_require_grads()
model = get_peft_model(model, LoraConfig(
    r=a.rank, lora_alpha=a.alpha, lora_dropout=a.dropout, task_type="CAUSAL_LM",
    # the language model only: full attention, linear attention and MLP (in_proj_a/b are tiny)
    target_modules=r".*language_model.*\.(q_proj|k_proj|v_proj|o_proj|in_proj_qkv|in_proj_z|out_proj|gate_proj|up_proj|down_proj)"))
model.print_trainable_parameters()

steps = a.max_steps or int(len(train) * a.epochs / a.accum)
opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=a.lr, weight_decay=0.0)
sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / 10) * max(0.0, 1 - s / steps))  # warm-up, then linear


def loss_of(ids: list[int], n: int) -> torch.Tensor:
    """Logits only where the answer is predicted: over the whole prompt (~4k tokens × a 248k
    vocabulary) they alone would take 4 GB."""
    x = torch.tensor([ids], device="cuda")
    with sdpa_kernel([SDPBackend.EFFICIENT_ATTENTION]):
        logits = model(input_ids=x, logits_to_keep=n + 1, use_cache=False).logits[0, :-1].float()
    return torch.nn.functional.cross_entropy(logits, x[0, -n:])


@torch.no_grad()
def validate() -> dict:
    """The loss on the parts with to-dos and on those without, apart: an empty answer is learnt in a few
    steps and would hide the rest."""
    model.eval()
    losses = {"todos": [], "none": [], "yes": [], "no": []}
    for ids, n in valid:
        said = tok.decode(ids[-n:]).replace("<|im_end|>", "").strip()  # the judge answers yes or no
        key = said if said in ("yes", "no") else "todos" if n > 2 else "none"  # n = 2: "<|im_end|>\n" alone
        losses[key].append(loss_of(ids, n).item())
    model.train()
    return {k: round(sum(v) / len(v), 4) for k, v in losses.items() if v}


out = a.out / a.name
out.mkdir(parents=True, exist_ok=True)
(out / "args.json").write_text(json.dumps({**vars(a), "out": str(a.out), "data": str(a.data), "train": len(train), "valid": len(valid)}, indent=1))
log = [{"step": 0, "valid": validate()}]
print(log[-1], flush=True)
order, rng, t0, best = [], random.Random(a.seed), time.time(), float("inf")
model.train()
for step in range(1, steps + 1):
    total = 0.0
    for _ in range(a.accum):
        if not order:
            order = list(range(len(train)))
            rng.shuffle(order)
        loss = loss_of(*train[order.pop()]) / a.accum
        with sdpa_kernel([SDPBackend.EFFICIENT_ATTENTION]):  # the layers are run again here (checkpointing)
            loss.backward()
        total += loss.item()
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    opt.step()
    sched.step()
    opt.zero_grad(set_to_none=True)
    log.append({"step": step, "train": total, "lr": sched.get_last_lr()[0], "s": round(time.time() - t0),
                "gpu_gb": round(torch.cuda.max_memory_allocated() / 2**30, 2)})
    if step % 10 == 0 or step == steps:
        log[-1]["valid"] = validate()
        model.save_pretrained(out)
        # the validation set is small and the loss jumps around: keep the step where it was lowest
        # (the mean over the kinds of answer, so the rare one counts as much), and others on request
        mean = sum(log[-1]["valid"].values()) / len(log[-1]["valid"])
        if mean < best:
            best = mean
            model.save_pretrained(out / "best")
            (out / "best" / "step.json").write_text(json.dumps(log[-1], indent=1))
        if a.save_every and step % a.save_every == 0:
            model.save_pretrained(out / f"step-{step}")
    print(log[-1], flush=True)
    (out / "log.json").write_text(json.dumps(log, indent=1))
model.save_pretrained(out)
print(f"adapter in {out}")
