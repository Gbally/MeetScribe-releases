"""LoRA on Qwen3.5 4B (4-bit) that fits in 8 GB: the loss only looks at the answer tokens, so the
248k-word output layer runs on ~100 positions instead of the whole ~1500-token transcript.

    python train.py DATA_DIR ADAPTER_DIR [--iters 300] [--layers 8] [--rank 8] [--lr 1e-4]
Writes adapters.safetensors + adapter_config.json (loadable by mlx_lm.load(adapter_path=…)).
"""
import argparse
import json
import math
import random
import time
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
from mlx.utils import tree_flatten, tree_map
from mlx_lm import load
from mlx_lm.tuner.trainer import grad_checkpoint
from mlx_lm.tuner.utils import linear_to_lora_layers

ap = argparse.ArgumentParser()
ap.add_argument("data", type=Path)
ap.add_argument("out", type=Path)
ap.add_argument("--model", default="mlx-community/Qwen3.5-4B-4bit")
ap.add_argument("--iters", type=int, default=300)
ap.add_argument("--layers", type=int, default=8)
ap.add_argument("--rank", type=int, default=8)
ap.add_argument("--lr", type=float, default=1e-4)
ap.add_argument("--accum", type=int, default=4)
ap.add_argument("--eval-every", type=int, default=50)
ap.add_argument("--max-tokens", type=int, default=2600)
a = ap.parse_args()

model, tok = load(a.model)
model.freeze()
lora = {"rank": a.rank, "scale": 20.0, "dropout": 0.0}
linear_to_lora_layers(model, a.layers, lora)
text = model.language_model
grad_checkpoint(text.model.layers[0])
n_train = sum(v.size for _, v in tree_flatten(model.trainable_parameters()))
print(f"trainable parameters: {n_train / 1e6:.2f} M", flush=True)


def encode(row):
    msgs = row["messages"]
    prompt = tok.apply_chat_template(msgs[:-1], add_generation_prompt=True, tokenize=False, enable_thinking=False)
    ids = tok.encode(prompt)
    ans = tok.encode(msgs[-1]["content"] + "<|im_end|>", add_special_tokens=False) if msgs[-1]["content"] else \
        tok.encode("<|im_end|>", add_special_tokens=False)
    return ids, ans


def rows(name):
    out = [encode(json.loads(l)) for l in open(a.data / f"{name}.jsonl")]
    return [r for r in out if len(r[0]) + len(r[1]) <= a.max_tokens]


train, valid = rows("train"), rows("valid")
print(f"{len(train)} train, {len(valid)} valid examples", flush=True)


def loss_fn(model, prompt, answer):
    x = mx.array(prompt + answer[:-1])[None]
    h = model.language_model.model(x)
    h = h[:, len(prompt) - 1:]  # the positions that predict the answer
    logits = model.language_model.model.embed_tokens.as_linear(h).astype(mx.float32)
    return nn.losses.cross_entropy(logits, mx.array(answer)[None]).mean()


def val_loss():
    tot = 0.0
    for p, ans in valid:
        tot += loss_fn(model, p, ans).item()
        mx.clear_cache()
    return tot / len(valid)


# Only the adapted layers use the linear-attention layers' differentiable path (their Metal kernel
# has no backward pass); the frozen layers below keep the fast kernel.
model.eval()
for layer in text.model.layers[-a.layers:]:
    layer.train()
opt = optim.Adam(learning_rate=optim.cosine_decay(a.lr, a.iters, a.lr / 10))
grad = nn.value_and_grad(model, loss_fn)
rng = random.Random(0)
print(f"iter 0 val loss {val_loss():.3f}", flush=True)
acc, t0, running = None, time.time(), []
for it in range(1, a.iters * a.accum + 1):
    p, ans = rng.choice(train)
    loss, g = grad(model, p, ans)
    acc = g if acc is None else tree_map(lambda x, y: x + y, acc, g)
    mx.eval(loss, acc)
    running.append(loss.item())
    if it % a.accum == 0:
        acc, _ = optim.clip_grad_norm(tree_map(lambda x: x / a.accum, acc), 1.0)
        opt.update(model, acc)
        mx.eval(model.trainable_parameters(), opt.state)
        acc = None
        step = it // a.accum
        if step % 10 == 0:
            print(f"step {step} train loss {sum(running) / len(running):.3f}  {(time.time() - t0) / step:.1f}s/step "
                  f"peak {mx.get_peak_memory() / 1e9:.1f} GB", flush=True)
            running = []
        if step % a.eval_every == 0 or step == a.iters:
            print(f"step {step} val loss {val_loss():.3f}", flush=True)
            a.out.mkdir(parents=True, exist_ok=True)
            mx.save_safetensors(str(a.out / "adapters.safetensors"), dict(tree_flatten(model.trainable_parameters())))
            (a.out / "adapter_config.json").write_text(json.dumps(
                {"fine_tune_type": "lora", "num_layers": a.layers, "lora_parameters": lora, "model": a.model}, indent=1))
    mx.clear_cache()
print("done", flush=True)
