"""A train.py adapter (peft) → an mlx-lm adapter, for run.py --adapter on the Mac.

  python eval/ami_bench/to_mlx.py RUN_DIR      # writes RUN_DIR/mlx: adapters.safetensors, adapter_config.json

mlx-lm names the modules as transformers does (language_model.model.layers.N.mlp.gate_proj), but
keeps lora_a as (in, r) and lora_b as (r, out), the transpose of peft's, and takes a scale
(alpha / rank) instead of alpha. The adapter was trained on an NF4 base and is applied to MLX's
4-bit one: close, not the same, so score it there."""

import json
import re
import sys
from pathlib import Path

import numpy as np
from safetensors.numpy import load_file, save_file

run = Path(sys.argv[1])
cfg = json.loads((run / "adapter_config.json").read_text())
out, keys, layers = {}, set(), 0
for name, w in load_file(run / "adapter_model.safetensors").items():
    m = re.fullmatch(r"base_model\.model\.model\.(language_model\.layers\.(\d+)\.(.+))\.lora_([AB])\.weight", name)
    if not m:
        raise SystemExit(f"unexpected weight {name}")
    path, key, ab = m[1], m[3], m[4]
    keys.add(key)
    layers = max(layers, int(m[2]) + 1)
    out[f"{path.replace('language_model.', 'language_model.model.', 1)}.lora_{ab.lower()}"] = np.ascontiguousarray(w.T)
(run / "mlx").mkdir(exist_ok=True)
save_file(out, run / "mlx" / "adapters.safetensors")
(run / "mlx" / "adapter_config.json").write_text(json.dumps({
    "fine_tune_type": "lora", "num_layers": layers,  # mlx-lm puts LoRA on the last num_layers: all of them
    "lora_parameters": {"rank": cfg["r"], "scale": cfg["lora_alpha"] / cfg["r"], "dropout": 0.0, "keys": sorted(keys)},
}, indent=1))
print(f"{len(out)} tensors, keys {sorted(keys)} → {run / 'mlx'}")
