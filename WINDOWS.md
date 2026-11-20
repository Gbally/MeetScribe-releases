# Hesper on Windows — handover for the PC session

Handover for a Claude Code session on the Windows PC (RTX 3080 8 GB, 16 GB RAM). The Mac app is the
product today; this is step B of the Windows plan: **does the engine hold its quality on Windows,
on the GPU and on the CPU, before any Windows UI is written?** Talk to the owner in French.

## Rules

- Install nothing system-wide: everything in one folder (as `eval/ami_bench/setup_windows.ps1` does
  for the training), so deleting it removes it all. Don't change Windows settings.
- The owner commits and pushes: give him the commands, don't run them.
- The engine (`src/hesper`) is shared with the Mac app. Don't change how the Mac path behaves:
  anything Windows-only goes behind `hardware.IS_MAC` / `hardware.device()`.
- Real meetings: the owner will send some to this PC (SSH) for the tests. They never go into the
  repository, into training data, or anywhere else; delete them from the PC after the tests.
- No telemetry.

## What step A (on the Mac, 2026-11-18) did

- `hardware.py`: one place decides the backends. Mac → MLX. A PC with a usable NVIDIA GPU
  (nvidia-smi finds it and CTranslate2 sees CUDA) → faster-whisper on CUDA float16, llama.cpp with
  the model on the GPU (all layers if it fits with ~1.5 GB to spare, else a share). Any other PC →
  faster-whisper int8 and llama.cpp on the CPU. `HESPER_DEVICE=cpu` forces the CPU (a colleague's
  laptop); `HESPER_AS_PC=1` makes a Mac use the PC backends (that's how step A tested them).
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
   wheels, put on PATH) only on a PC with an NVIDIA GPU. `HESPER_HOME` = a folder inside it.
2. **First check: does llama.cpp run Qwen3.5 4B?** It's a hybrid (linear attention + full attention),
   the part that made the Mac training fail. Check the GGUF repo/quant name too. If llama.cpp can't,
   fall back to `Qwen3-4B-Instruct-2507` (GGUF), measured on the Mac before (a bit lower).
3. **AMI** (`eval/ami_bench`: manual transcripts, so the notes/to-dos only). `run.py` uses MLX: add a
   PC mode (the engine's `LLM` with `llm_backend = "llama"`, same cache idea) or a sibling script.
   Mac reference, one round, 4-bit MLX: **found 19/51, right owner 14, 163 to-dos, 139 unmatched,
   64 min**. Run it on the GPU and with `HESPER_DEVICE=cpu`.
4. **Notes bench** (`eval/notes_bench`: real audio, so transcription + speakers + notes). Its audio is
   made with macOS voices: the owner sends the folders from the Mac (synthetic, nothing private).
   `run.py` is Mac-centric (paths, MLX model names): adapt it or call `python -m hesper process`
   on each folder, then `score.py`. Mac reference (base, 2 rounds): **136/142 tasks found, noise 24,
   right deadlines 115, wrong 0**; speakers 89–100 % of words to the right person.
5. **Time** per 30 min of meeting, GPU and CPU-only.
6. **Real meetings** the owner sends (his 3 scored ones from 27 Oct, and new ones from his work PC
   never seen before): compare with the Mac's notes of the same meetings.

### Step B results (PC, 2026-11-19)

- **Setup** in `MeetScribe\win`: `venv` (`uv sync` with `UV_PROJECT_ENVIRONMENT`), `nvidia-cublas-cu12`
  + `nvidia-cudnn-cu12` 9 in it (their `bin` folders on PATH, see `win\env.sh`), llama.cpp b12532
  (`win-cuda-12.4-x64` + its cudart in `home\models\llama.cpp`, `win-cpu-x64` in `llama.cpp-cpu`),
  the sherpa-onnx speaker models by hand. `meetscribe setup` isn't PC-ready yet: it sizes and
  downloads `llm_model` as a whole repo (a GGUF "repo:quant" would fetch every quant) and the
  language-ID model is MLX.
- **llama.cpp runs Qwen3.5 4B** (`unsloth/Qwen3.5-4B-GGUF:Q4_K_M`): 4.2 GB of VRAM, prompt ~2100
  tok/s, answer ~75 tok/s on the RTX 3080 Laptop; CPU only ~87 / 12 tok/s. `-hf` also loaded the
  vision projector (0.7 GB): now `--no-mmproj`.
- **AMI dev** (`run.py pc-gpu --rounds 1`): 26/51 found, right owner 19, 233 to-dos, 203 unmatched
  (87 %), ~13.5 min (Mac MLX 4-bit: 19/51, 14, 163, 139, 64 min). Like the Mac's 6-bit (27/51):
  Q4_K_M seems to keep more than MLX 4-bit. CPU only, 4 meetings (`pc-cpu`): 12/18 found vs 11/18 on the GPU, 40 to-dos vs 39; ~3.5 min per
  meeting vs ~20 s (the full 20 would take 1–2 h).
- **Notes bench, GPU** (`notes_bench/run.py … --audio DIR`, 2 rounds): 131/142 tasks, noise 20,
  right deadlines 106, wrong 3 (Mac same code: 132/142, 23, 108, 2); speakers 89.6–100 % of words
  to the right person. ~4 min per 30 min of meeting (allhands, 9.5 min: 39 s transcription + 40 s notes).
- **CPU only** (`HESPER_DEVICE=cpu`, `CUDA_VISIBLE_DEVICES=-1`), 3 bench meetings, 1 round: ~20 min
  per 30 min of meeting (allhands: 166 s + 211 s); 21/25 tasks vs 23/25 on the GPU, same speakers.

Decision: if the quality holds (no more than 2–3 tasks lost on the bench compared with the Mac,
same order on AMI), next is the Windows app (tray icon, mic + WASAPI loopback, toasts, settings),
then the installer and the updates. If not, find out why first.

## Later: publishing (decided 2026-11-18)

- Same repo `Gbally/Hesper`: a release `vX.Y.Z` holds the DMG and the Windows installer.
- Feeds per platform: `latest-windows.json`, `latest-windows-beta.json`, same format as `latest.json`
  (version, build, url, sha256, notes). Mac apps only read `latest.json`: untouched.
- Per-user install (`%LOCALAPPDATA%\Programs\Hesper`): no admin, silent updates.
- Updates signed with our own Ed25519 key (public key in the app), since there's no Windows code
  certificate yet; SmartScreen will warn on the first download until there is one.
- `catalog/models.json` gets per-platform entries (MLX for the Mac, GGUF / faster-whisper for Windows).

## Step C: the Windows app (preview), asked 2026-11-20

MeetScribe is now **Hesper** (0.7.0, by Nibjorg Studio). The repository moved to
`https://github.com/Gbally/Hesper.git`: on the PC, `git remote set-url origin https://github.com/Gbally/Hesper.git`,
then `git pull`. The Python package is `hesper` (`python -m hesper …`); environment variables
`HESPER_HOME`, `HESPER_DEVICE`, `HESPER_AS_PC`.

Brand (mac/App/Brand.swift): duskInk `#1B1F2E`, horizon `#2E3550`, eveningStar `#F2B544` (accent),
recording `#D93A3A` (only while recording). Tray icon in colour (Windows can't tint): a rounded
square `#2E3550` (rx 22 of 100) with the star `M50 14 Q50 40 74 40 Q50 40 50 66 Q50 40 26 40 Q50 40 50 14 Z`
in `#F2B544`; while recording, add a red dot. App icon: scripts/make_icon.swift.

Scope of the preview, minimal but clean:

1. Tray icon. Menu: Record / Stop and create notes / Open notes folder / Settings / Quit. While
   recording: the elapsed time and the red dot.
2. Microphone + PC sound (WASAPI loopback) into two 16 kHz mono WAV tracks on one timeline
   (`mic.wav`, `system.wav` in a session folder, like mic.caf / system.caf on the Mac).
3. On stop: `python -m hesper process <folder>` (src/hesper/cli.py) with its progress shown, then a
   Windows notification "Notes ready" that opens notes.md (or a simple window showing it).
4. First launch installs everything in `%LOCALAPPDATA%\Hesper`: uv, Python 3.12, `uv sync` of the
   bundled engine, the CUDA libraries only when an NVIDIA GPU is found, llama-server (CUDA or CPU),
   models via `python -m hesper setup`. Nothing system-wide, no admin rights; a simple progress window.
5. Minimal settings: your name, the notes folder, meeting languages, todo_filter (off / standard /
   strict), written to `%LOCALAPPDATA%\Hesper\config.toml` as Engine.swift does on the Mac.
6. Deliverable: one self-contained `Hesper.exe` for the GitHub releases, then `latest-windows.json`
   at the repo root, same format as latest.json (version, build, url, sha256, notes). The site
   (docs/index.html) already reads it: its Windows button turns on when the file exists.

Suggested stack: C# / .NET 8 (WinForms or WPF, NotifyIcon, NAudio for WASAPI;
`dotnet publish -r win-x64 --self-contained -p:PublishSingleFile=true`), with a portable .NET SDK
inside the project folder. Code under `win/` in the repository. No telemetry. Order: (a) capture
mic + loopback and run `hesper process` on the result, (b) tray icon and menu, (c) first-launch
install, (d) the exe. Ask the owner before each install and each long GPU job; he commits.

### Step C, done on the PC (2026-11-20)

The app is in `win/` (see win/README.md); (a)–(d) built and tested on the PC, the tray menu not yet
clicked through by hand.

- Engine changes: `cli.track()` reads `mic.wav` / `system.wav` when there's no `.caf` (the Mac's come
  first); `hesper setup` on a PC fetches faster-whisper's models (large-v3-turbo, base) and lets
  llama-server download its one GGUF file (not the whole repo); llama-server gets a random API key
  per start (LLAMA_API_KEY): a web page open in a browser can't use it; `pyproject` extra `cuda`
  (cuBLAS 12.9.2.10 — 12.9.3 has no Windows wheel — and cuDNN 9) for `uv sync --extra cuda`.
- Devices: on the PC here the "communications" defaults were the monitor's speakers and SteelSeries
  Sonar's virtual mic, both silent; the app takes Windows' default devices, or the ones picked in
  Settings, and `Hesper.exe --devices` shows which device hears what.
- Checked: 45 s recorded while a bench meeting played → its to-do with the right time; a first launch
  into an empty folder from the published 78 MB exe, without the SDK; uv picks Python 3.15 unless told
  `--python 3.12` (onnxruntime has no 3.15 wheel).
