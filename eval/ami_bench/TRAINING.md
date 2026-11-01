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

## Rules

- The owner's real meetings never leave the Mac and never go into training data or the repo.
- The owner commits and pushes: give him the commands, don't run them.
- Talk to the owner in French.
