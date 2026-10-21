# MeetScribe

Local meeting recorder → speaker-labelled transcript → AI notes (summary, decisions,
action items). Everything runs on your Mac; no audio or text leaves the machine.

```
Teams audio (ScreenCaptureKit) ─┐                 ┌─ Whisper large-v3-turbo (MLX, GPU)
                                ├─ 2 tracks ──────┤
Your microphone (AVAudioEngine) ┘                 └─ speaker separation (sherpa-onnx, CPU)
                                                          │
                     transcript.md ◄── merge + echo removal ┘
                     notes.md      ◄── Qwen3-8B (MLX) summary / decisions / action items
```

Your mic and the meeting audio are recorded **separately**, so everything you say is
labelled with your name for free, and speaker separation only has to tell the remote
people apart (`Speaker 1`, `Speaker 2`, …). If you're not wearing headphones, the remote
voices picked up by your mic are detected and removed.

## Setup (once)

```sh
./setup.sh --models     # Python env, speaker models, recorder, Whisper + LLM (~6 GB)
cp config.example.toml config.toml   # then set `me = "Your Name"`
```

Handy alias (add to `~/.zshrc`):
`alias meetscribe=~/Documents/MeetingScribe/.venv/bin/meetscribe`

**Permissions:** the first `meetscribe record` needs your terminal app (Terminal / iTerm)
allowed in System Settings → Privacy & Security → **Microphone** and **Screen & System
Audio Recording**. Restart the terminal after granting.

## Use

```sh
meetscribe record --title "Weekly sync"            # Ctrl+C when the meeting ends
meetscribe record --app "Microsoft Teams"           # only Teams' audio (no notifications/music)
meetscribe record --room                            # in-person meeting: everyone on your mic
meetscribe record --speakers 3                      # if you know how many remote people talk

meetscribe process ~/Downloads/recording.m4a        # any existing audio file (Teams export, phone…)
meetscribe rename <folder> "Speaker 1=Alice" "Speaker 2=Bob"   # name speakers, redo the notes
meetscribe summarize <folder>                       # rewrite notes (e.g. after changing the model)
```

Each meeting gets a folder in `~/Documents/MeetingNotes/` with `notes.md`,
`transcript.md`, `transcript.json` and the raw audio (`mic.caf`, `system.caf`).

## Tips

- **Headphones** give the cleanest result (no echo to remove).
- Put names and jargon in `vocabulary` in `config.toml` so Whisper spells them right.
- Meetings are mostly English; set `language = "en"` to stop Whisper from guessing
  wrong on short French bits, or leave it empty to auto-detect.
- Better notes: `llm_model = "mlx-community/Qwen3.5-9B-4bit"` (≈6 GB; fine on 16 GB if
  you're not running much else). Or point `llm_backend = "openai"` at Ollama / LM Studio.
- Too many / too few speakers? Pass `--speakers N`, or tune `diarization_threshold`.

## Layout

- `recorder/Recorder.swift` — the capture tool (`bin/meeting-recorder`, built by `setup.sh`)
- `src/meetscribe/` — `audio` (decode), `transcribe` (Whisper), `diarize` (speakers),
  `transcript` (merge, echo removal, output), `summarize` (LLM notes), `cli`

## Ideas / next steps

- Voice enrollment: remember colleagues' voices → real names automatically
- Live transcript while the meeting runs
- Auto-start when a Teams call begins; menu-bar app
- Export notes to OneNote / Outlook tasks
