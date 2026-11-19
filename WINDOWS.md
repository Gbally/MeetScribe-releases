# MeetScribe on Windows — handover for the PC session

Handover for a Claude Code session on the Windows PC (RTX 3080 8 GB, 16 GB RAM). The Mac app is the
product today; this is step B of the Windows plan: **does the engine hold its quality on Windows,
on the GPU and on the CPU, before any Windows UI is written?** Talk to the owner in French.

## Rules

- Install nothing system-wide: everything in one folder (as `eval/ami_bench/setup_windows.ps1` does
  for the training), so deleting it removes it all. Don't change Windows settings.
- The owner commits and pushes: give him the commands, don't run them.
- The engine (`src/meetscribe`) is shared with the Mac app. Don't change how the Mac path behaves:
  anything Windows-only goes behind `hardware.IS_MAC` / `hardware.device()`.
- Real meetings: the owner will send some to this PC (SSH) for the tests. They never go into the
  repository, into training data, or anywhere else; delete them from the PC after the tests.
- No telemetry.

## What step A (on the Mac, 2026-11-18) did

- `hardware.py`: one place decides the backends. Mac → MLX. A PC with a usable NVIDIA GPU
  (nvidia-smi finds it and CTranslate2 sees CUDA) → faster-whisper on CUDA float16, llama.cpp with
  the model on the GPU (all layers if it fits with ~1.5 GB to spare, else a share). Any other PC →
  faster-whisper int8 and llama.cpp on the CPU. `MEETSCRIBE_DEVICE=cpu` forces the CPU (a colleague's
  laptop); `MEETSCRIBE_AS_PC=1` makes a Mac use the PC backends (that's how step A tested them).
- `pyproject.toml`: MLX on the Mac only; `faster-whisper` (+ `av<19`: PyAV 19 dropped an option
  faster-whisper's decoder passes) elsewhere. One universal `uv.lock`; the Mac's pins didn't move.
- `transcribe.py`: `_transcribe_faster` with the MLX path's settings (word times, no text carried
  between windows, vocabulary as `hotwords` on every window, the same hallucination filters);
  language switching with faster-whisper's `base` model (`detect_language`).
- `audio.py`: outside the Mac, decoded with faster-whisper's `decode_audio` (FFmpeg via PyAV):
  .caf from the Mac, .wav, .m4a, .mp3, video files.
- `llama_server.py` + `llm_backend = "llama"` (the default outside the Mac): the engine starts
  `llama-server(.exe)` on 127.0.0.1 and a free port, `-hf unsloth/Qwen3.5-4B-GGUF:Q4_K_M` (downloaded
  into `models/gguf` the first time), `--jinja`, 24k context; exact token counts through `/tokenize`
  (so transcripts are cut into the same parts as on the Mac); no thinking, top-p 0.8, the mild
  repetition penalty for prose only, `cache_prompt` (the transcript is read once per meeting, as the
  MLX prompt cache does). Looked for in `config.llama_server`, then `models/llama.cpp/`, then PATH.
- Checked on the Mac: the 28 rule tests pass; AMI dev replays to the same numbers (19/51, 163
  to-dos); a bench meeting re-transcribed with MLX is identical. The PC path on the Mac's CPU:
  99.4 % of the MLX words on `standup` (EN), 97.5 % on `client_bilingue` (EN/FR, language switching
  works). llama.cpp was **not** tested (no binary on the Mac).

## Step B, here

1. **Setup** in one folder (e.g. `C:\Users\guill\Documents\Project\MeetScribe\win`): uv + Python 3.12
   (as `setup_windows.ps1`), `uv sync` of the repo, llama.cpp's Windows release (CUDA build and CPU
   build, from github.com/ggml-org/llama.cpp releases) into `models/llama.cpp`. The CUDA libraries
   faster-whisper needs on the GPU (cuBLAS, cuDNN 9: the `nvidia-cublas-cu12`, `nvidia-cudnn-cu12`
   wheels, put on PATH) only on a PC with an NVIDIA GPU. `MEETSCRIBE_HOME` = a folder inside it.
2. **First check: does llama.cpp run Qwen3.5 4B?** It's a hybrid (linear attention + full attention),
   the part that made the Mac training fail. Check the GGUF repo/quant name too. If llama.cpp can't,
   fall back to `Qwen3-4B-Instruct-2507` (GGUF), measured on the Mac before (a bit lower).
3. **AMI** (`eval/ami_bench`: manual transcripts, so the notes/to-dos only). `run.py` uses MLX: add a
   PC mode (the engine's `LLM` with `llm_backend = "llama"`, same cache idea) or a sibling script.
   Mac reference, one round, 4-bit MLX: **found 19/51, right owner 14, 163 to-dos, 139 unmatched,
   64 min**. Run it on the GPU and with `MEETSCRIBE_DEVICE=cpu`.
4. **Notes bench** (`eval/notes_bench`: real audio, so transcription + speakers + notes). Its audio is
   made with macOS voices: the owner sends the folders from the Mac (synthetic, nothing private).
   `run.py` is Mac-centric (paths, MLX model names): adapt it or call `python -m meetscribe process`
   on each folder, then `score.py`. Mac reference (base, 2 rounds): **136/142 tasks found, noise 24,
   right deadlines 115, wrong 0**; speakers 89–100 % of words to the right person.
5. **Time** per 30 min of meeting, GPU and CPU-only.
6. **Real meetings** the owner sends (his 3 scored ones from 27 Oct, and new ones from his work PC
   never seen before): compare with the Mac's notes of the same meetings.

Decision: if the quality holds (no more than 2–3 tasks lost on the bench compared with the Mac,
same order on AMI), next is the Windows app (tray icon, mic + WASAPI loopback, toasts, settings),
then the installer and the updates. If not, find out why first.

## Later: publishing (decided 2026-11-18)

- Same repo `Gbally/MeetScribe-releases`: a release `vX.Y.Z` holds the DMG and the Windows installer.
- Feeds per platform: `latest-windows.json`, `latest-windows-beta.json`, same format as `latest.json`
  (version, build, url, sha256, notes). Mac apps only read `latest.json`: untouched.
- Per-user install (`%LOCALAPPDATA%\Programs\MeetScribe`): no admin, silent updates.
- Updates signed with our own Ed25519 key (public key in the app), since there's no Windows code
  certificate yet; SmartScreen will warn on the first download until there is one.
- `catalog/models.json` gets per-platform entries (MLX for the Mac, GGUF / faster-whisper for Windows).
