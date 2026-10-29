# LoRA experiment: teaching the 4B the to-do pass

An experiment, not part of the app. It trains a small adapter on Qwen3.5 4B for one job: the
to-do extraction pass (`ACTIONS_PROMPT`). The training meetings are invented (`gen.py`), never
real recordings.

## Files

- `gen.py OUT N_TRAIN N_VALID SEED` writes invented meetings and their exact answers as `train.jsonl` and `valid.jsonl`.
  - Each meeting has 0–5 real commitments: volunteered, asked and accepted, or given to someone else. Some are hidden inside longer turns.
  - It also has traps that must give no answer: done in the meeting, already done, questions, wishes, hypotheticals, availability, leaving the call. English and French.
- `train.py DATA ADAPTERS` is the LoRA trainer for MLX. It writes `adapters.safetensors` and `adapter_config.json`, which `mlx_lm.load(…, adapter_path=…)` can load.

## What we learned on the M2 (8 GB), 2026-10-29

- **The stock trainer runs out of memory.** `mlx_lm lora` fails even at 2,000 tokens. The output layer has 248k words, and its logits for every position take about 2 GB. `train.py` only computes them on the answer tokens.
- **The linear-attention layers block training.** 24 of Qwen3.5's 32 layers are GatedDeltaNet. Their fast Metal kernel has no backward pass. The differentiable path stores a huge state per token: 256 tokens take 7 GB and 39 s per step, 1,024 tokens take 21 GB and 417 s.
  - So on this Mac only the last layer (31, full attention) can be adapted: about 1 M parameters. A step with ~800-token examples takes ~20 s and 3.9 GB.
- **First run.** 600 invented meetings, 60 steps, batch 2, lr 3e-5, rank 16, gradients clipped at 1.0. Validation loss fell from 1.61 to 0.16. lr 2e-4 diverged (loss 15).
- **Result.** No gain on the notes benchmark: 8.57 against 8.65 without the adapter (6 meetings, 2 interleaved rounds), with deadlines slightly worse. The adapter learned the invented meetings' style, not the task in general. One layer is too little, and the invented meetings are too uniform.

## Next: train on a CUDA PC (RTX 3080, 8–10 GB)

On CUDA, PyTorch with PEFT or Unsloth and `flash-linear-attention` have a real backward pass for the GatedDeltaNet layers. QLoRA on all layers with ~2,500-token parts should fit in 8–10 GB.

1. Generate more varied data: more tasks, more filler, real-meeting style (fragments, interruptions, several people at once), and meetings 2–3 times longer.
2. Train in 4-bit (QLoRA), rank 16, on the attention + MLP projections of all layers, with `--mask-prompt` (loss on the answer only).
3. Bring the adapter back to the Mac:
   - merge it into the full-precision model;
   - convert with `mlx_lm.convert --quantize` (4-bit);
   - score it with `eval/notes_bench/run.py --model <path>`, interleaved with the stock 4B.
