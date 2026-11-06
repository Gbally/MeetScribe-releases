# Training a to-do adapter on AMI (Windows PC, NVIDIA GPU)

Handover for a Claude Code session on the training PC (RTX 3080, 8 GB VRAM, 16 GB RAM). The work so
far ran on the dev Mac; this file is what that session knew.

## Setup

```powershell
powershell -ExecutionPolicy Bypass -File setup_windows.ps1 -Root C:\Users\guill\Documents\Project\MeetScribe
cd C:\Users\guill\Documents\Project\MeetScribe; . .\env.ps1
```

`setup_windows.ps1` keeps everything inside the root folder (uv, Python 3.12, PyTorch CUDA, the
Hugging Face cache, the corpus). **Install nothing system-wide**: the owner wants to remove it all by
deleting that folder. Put new packages in `venv` with `uv pip install --python venv\Scripts\python.exe`,
models in `hf\`, outputs under the root.

## Where things stand (2026-10-30)

- `eval/ami_bench` (see README.md): 30 AMI scenario meetings, **20 dev + 10 test**, manual
  transcripts, scored against the annotators' actions.
- The app's to-do pipeline (`src/meetscribe/summarize.py`: `_parts` → `_extract` with
  `ACTIONS_PROMPT` → `check_actions` → `second_look` → `merge_actions`) with Qwen3.5 4B 4-bit (MLX)
  finds 36 % (dev) / 24 % (test) of annotated actions; ~85 % of its to-dos match none.
- Most of that noise is things done **in** the meeting ("present", "give it a three") and ideas
  thrown around in the discussion taken as tasks. Rules now drop the first kind. A prompt line asking
  to skip ideas was tested and rejected: it dropped as many real tasks as noise.
- So the next lever is an adapter: teach the 4B model, on AMI, what a commitment is.

## Plan

1. **Data.** From AMI meetings that are **not** in `data/split.json` (dev and test are only for
   scoring, never for training): the prompt the app sends (`ACTIONS_PROMPT` filled with one
   transcript part from `_parts`) → the answer it should give, in the format `_action_lines` parses,
   built from the annotated actions. The annotations aren't tied to transcript lines: matching each
   action to the part and line that says it is the hard step (AMI's `extsumm` / dialogue-act links
   may help; check what's in the corpus zip beyond what `fetch.py` keeps). Parts with no annotated
   action → an empty answer, which is what teaches it to skip.
2. **Train.** QLoRA on `Qwen/Qwen3.5-4B` (transformers + peft + trl, 4-bit with bitsandbytes) fits
   8 GB with a short context. EXTRACT_TOKENS = 2600 is the transcript per pass, so ~3–4 k tokens per
   example. Start small (rank 16, 1–2 epochs) and keep runs comparable.
3. **Score.** On the Mac: convert the adapter for MLX (`mlx_lm` LoRA format, or fuse and requantize
   to 4-bit) and run `run.py` with it on dev, then test once at the end. It must also hold on
   `eval/notes_bench` and on the owner's real meetings (scored on the Mac). Speed rule: up to +5 %
   time is fine, +5–15 % only for a clear gain, ask beyond that.
4. **Credit.** An adapter trained on AMI ships with the credit in README.md (CC BY 4.0, University
   of Edinburgh) and in the app's About.

## Done on the PC (2026-11-01)

```powershell
python eval\ami_bench\train_data.py   # → data\train\train.jsonl, valid.jsonl, report.json
python eval\ami_bench\train.py NAME   # → ..\runs\NAME: the adapter, args.json, log.json
python eval\ami_bench\run_hf.py NAME [--adapter ..\runs\RUN] [--meetings ID…]   # the to-do steps here, scored
python eval\ami_bench\to_mlx.py ..\runs\RUN   # → RUN\mlx, for run.py --adapter on the Mac
```

- **Data** (`train_data.py`). The corpus links each summary sentence to the dialogue acts it was
  written from (`extractive/*.summlink.xml` + `dialogueActs/`, now kept by `fetch.py`): 190 of the
  230 actions have a line. 108 scenario meetings outside the split (11 held out for validation),
  cut by `_parts` with the Qwen tokenizer: 411 parts, 63 with to-dos, ~3.1k tokens each. Owners are
  the four roles; group tasks ("all participants will…") and odd wordings aren't written, and the
  parts that hold them are left out, as are the empty parts of a meeting with an action linked to
  no line. The quotes are sometimes off (the annotators' links are loose): 12 of the to-dos don't
  pass `check_actions`. Same scenario teams as some dev/test meetings, other meetings.
- **Training** (`train.py`). Own loop, loss on the answer only, logits only there. Qwen3.5 is a
  hybrid (linear + full attention): needs `triton-windows` + `flash-linear-attention` (now in
  `setup_windows.ps1`), and an attention function that repeats K/V for SDPA's memory-efficient
  kernel (PyTorch on Windows has no flash attention; the default fell back to the math kernel and
  spilled past 8 GB at ~2 min per example). Now ~4.5 s per example, 5.3 GB at 4k tokens.
- **First run, `runs/r16-e2`** (rank 16, alpha 32, lr 1e-4, 2 epochs, parts with to-dos ×2, 106
  steps, 71 min). Validation loss: parts with to-dos 0.56 → 0.35 (flat from step 60), parts
  without 5.8 → 0.01. **It learnt to stay silent**: on the 6 validation parts with to-dos it
  answers on 1 (rightly), P(empty answer) 0.4–1.0 on the others; on dev TS3006a (`run_hf.py`)
  0 to-dos where the base finds 3/3 (+13 unmatched), the second look silent too. The format and
  the content of what it does write are right: it's the calibration.
- **Second run, `runs/r16-bal`** (2026-11-06): `train.py r16-bal --pos-repeat 1 --neg-per-pos 1.5
  --epochs 3`: the 57 parts with to-dos + 86 of the empty ones, 53 steps. Validation loss: to-dos
  0.56 → 0.34, empty 5.8 → 0.17. (2 h 34 instead of ~40 min: Chrome held VRAM and the run spilled to
  shared memory; close everything else on the GPU before a run.) `run_hf.py` now uses the adapter for
  the extraction passes only, not the second look.
- **Dev, 20 meetings, `run_hf.py`** (same NF4 model, one round):

  | run | found | right owner | to-dos | unmatched | time |
  |---|---|---|---|---|---|
  | `hf-base` | 30/51 (59 %) | 20 (39 %) | 359 | 318 (89 %) | 38 min |
  | `hf-r16-bal` | 27/51 (53 %) | 25 (49 %) | 85 | 53 (62 %) | 12 min |

  4× fewer to-dos, 6× less noise, 3 found actions lost, more right owners, and faster (shorter
  answers). A clear win here; the MLX adapter is in `runs/r16-bal/mlx`.
- **Next**: copy `runs/r16-bal/mlx` to the Mac, `run.py --adapter` on dev (the app's MLX 4-bit
  model, not NF4: check it holds), then `eval/notes_bench` and the owner's meetings; test once at
  the end. Maybe try `--neg-per-pos 1` for a bit more recall.

## Rules

- The owner's real meetings never leave the Mac and never go into training data or the repo.
- The owner commits and pushes: give him the commands, don't run them.
- Talk to the owner in French.
