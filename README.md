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

## Menu bar app (recommended)

Build the installer, then share `dist/MeetScribe-<version>.dmg` with colleagues:

```sh
./scripts/build_app.sh        # → build/MeetScribe.app + dist/MeetScribe-<version>.dmg (~16 MB)
```

The app is a waveform icon in the menu bar. Click it → **Start recording** (● + timer in the
menu bar) → click again → **Stop & create notes**. A few minutes later the window shows the
to-do list (tick items off), summary, decisions and open questions, with buttons to open the
transcript, copy the notes for an email, name the speakers, etc. Every meeting stays in the
history list. Also: transcribe an existing audio file, launch at login, notes folder, language
and vocabulary in Settings.

- **Calendar:** the current Outlook/Exchange event (via macOS Calendar) names the meeting and
  gives the AI the attendees; "Email" opens an Outlook draft to them with the notes.
- **My to-dos:** every action item assigned to you, across all meetings, in one list.
- **Known voices:** name a speaker once (⋯ → Name the speakers) and they're recognised in later
  meetings (voiceprints in `voices.json`, never uploaded).
- **Call reminder:** when Teams/Zoom/a browser opens the microphone, a notification offers
  **Record**; when the calendar meeting is over, it offers **Stop & create notes**.
- **Languages:** tick the languages your meetings use (e.g. English + French) and switches are
  detected every few seconds; notes are written in the meeting's main language (or a fixed one).
- **Reminders:** send your to-dos to Apple Reminders.
- **Briefs:** 5 min before a calendar meeting that happened before (same series, title or
  people), a notification shows what's still open from last time.
- **Due dates:** "Friday", "next week", "30 Oct", "fin du mois"… become real dates; "My to-dos" is
  sorted by them and you get a reminder the day before.
- **Ask your meetings:** search box on the main window; ↩ asks the local AI, which answers from
  your notes/transcripts with sources.
- **Automatic mode** (optional): starts recording when a call app opens the mic, stops when it
  releases it (per-process CoreAudio, macOS 14+).
- **Meeting types:** General, 1:1, Stand-up, Client call, Interview, Workshop — each with its
  own sections; "Regenerate as…" to switch.
- **Shortcut:** start/stop from anywhere (default ⌃⌥R, changeable in Settings).
- **Edit:** rename a meeting, fix/add/delete to-dos (notes.md is rebuilt with `meetscribe render`).
- **Privacy:** audio (and voice samples) deleted after 7 days by default; notes are kept.

On first launch it installs its engine into `~/Library/Application Support/MeetScribe`
(Python via the bundled `uv`) and downloads the models (~6 GB) — see `mac/INSTALL.txt`, which
is included in the DMG. Requirements: Apple Silicon, macOS 13+, 16 GB RAM recommended.

**Permissions across updates:** macOS remembers permissions per code signature. Run
`./scripts/make_signing_identity.sh` once: it creates a fixed self-signed identity in
`signing/` (its own keychain file, gitignored — **back it up**), and every build is signed with it,
so permissions survive updates. Without it, builds are ad-hoc signed and every update re-asks.

**Signing:** without a Developer ID the app is self-signed, so on another Mac macOS blocks the first
open (System Settings → Privacy & Security → Open Anyway). For a warning-free install, build
with an Apple Developer ID (`SIGN_ID="Developer ID Application: …" ./scripts/build_app.sh`)
and notarize the DMG (`xcrun notarytool submit dist/MeetScribe-*.dmg --wait`, then
`xcrun stapler staple`) — or have IT deploy it via MDM.

## Command line (for development)

### Setup (once)

```sh
./setup.sh --models     # Python env, speaker models, recorder, Whisper + LLM (~6 GB)
cp config.example.toml config.toml   # then set `me = "Your Name"`
```

Handy alias (add to `~/.zshrc`):
`alias meetscribe=~/Documents/MeetingScribe/.venv/bin/meetscribe`

**Permissions:** the first `meetscribe record` needs your terminal app (Terminal / iTerm)
allowed in System Settings → Privacy & Security → **Microphone** and **Screen & System
Audio Recording**. Restart the terminal after granting.

### Use

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

### Tips

- **Headphones** give the cleanest result (no echo to remove).
- Put names and jargon in `vocabulary` in `config.toml` so Whisper spells them right.
- Meetings are mostly English; set `language = "en"` to stop Whisper from guessing
  wrong on short French bits, or leave it empty to auto-detect.
- Better notes: `llm_model = "mlx-community/Qwen3.5-9B-4bit"` (≈6 GB; fine on 16 GB if
  you're not running much else). Or point `llm_backend = "openai"` at Ollama / LM Studio.
- Too many / too few speakers? Pass `--speakers N`, or tune `diarization_threshold`.

## Layout

- `mac/Shared/AudioCapture.swift` — mic + system audio capture (shared)
- `mac/App/` — the menu bar app (SwiftUI); `mac/CLI/` — `bin/meeting-recorder`
- `scripts/` — `build_app.sh` (app + DMG), `build_recorder.sh`, `make_icon.swift`
- `src/meetscribe/` — `audio` (decode), `transcribe` (Whisper), `diarize` (speakers),
  `transcript` (merge, echo removal, output), `summarize` (LLM notes), `cli`

## Ideas / next steps

- Live transcript while the meeting runs
- Microsoft To Do / Planner export (needs a Microsoft Graph app registration)
- Automatic updates for colleagues
