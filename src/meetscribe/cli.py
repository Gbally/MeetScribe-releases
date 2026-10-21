"""meetscribe — local meeting recorder, transcriber and note-taker.

  meetscribe record [--title T] [--app "Microsoft Teams"] [--room] [--speakers N]
  meetscribe process <folder-or-audio-file> [--title T] [--room] [--speakers N]
  meetscribe rename <folder> "Speaker 1=Alice" "Speaker 2=Bob"
  meetscribe summarize <folder>
  meetscribe setup
"""

import argparse
import json
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from datetime import datetime
from pathlib import Path

from .config import PROJECT_ROOT, Config, load_config

RECORDER = PROJECT_ROOT / "bin" / "meeting-recorder"


def new_session_dir(cfg: Config, title: str) -> Path:
    slug = re.sub(r"[^\w-]+", "-", title).strip("-")[:50]
    name = datetime.now().strftime("%Y-%m-%d_%H%M") + (f"_{slug}" if slug else "")
    path = cfg.notes_path / name
    path.mkdir(parents=True, exist_ok=True)
    return path


def step(msg: str):
    print(f"→ {msg}", flush=True)


# ---------------------------------------------------------------- record


def cmd_record(args, cfg: Config):
    if not RECORDER.exists():
        sys.exit("Recorder not built — run ./setup.sh")
    session = new_session_dir(cfg, args.title or "")
    cmd = [str(RECORDER), str(session)]
    app = args.app if args.app is not None else cfg.app
    if app:
        cmd += ["--app", app]
    if args.room:
        cmd += ["--no-system"]
    proc = subprocess.Popen(cmd)
    try:
        proc.wait()
    except KeyboardInterrupt:  # Ctrl+C also reaches the recorder, which saves and exits
        proc.wait()
    if proc.returncode != 0 or not any(session.glob("*.caf")):
        if not any(session.iterdir()):
            session.rmdir()
            sys.exit("Recording failed.")
        sys.exit(f"Recording failed (folder kept: {session})")
    if args.no_process:
        print(f"Saved to {session}. Process later with: meetscribe process \"{session}\"")
        return
    process_session(session, cfg, args.title or "", args.room, args.speakers, summary=not args.no_summary)


# ---------------------------------------------------------------- process


def process_session(session: Path, cfg: Config, title: str, room: bool, speakers: int,
                    audio_file: Path | None = None, summary: bool = True):
    from .audio import is_silent, load_audio
    from .diarize import diarize
    from .transcribe import transcribe
    from .transcript import drop_echo, group_words, merge, save_json, speaker_for

    from .voices import embed, enroll, identify, save_session_prints, speaker_prints

    t0 = time.time()
    tracks: list[list] = []
    track_names: list[str] = []  # which audio was usable: "meeting", "mic", "room", "file"
    languages = set()
    session_prints: dict = {}  # label → voiceprint, saved so naming a speaker teaches the library

    def diarized_track(audio, prefix: str, n: int, exclude: set[str] = frozenset(), guess_me: bool = False):
        # Diarization (+ voiceprints) runs on the CPU while Whisper uses the GPU.
        # Voices re-recorded through laptop speakers sound alike less: be stricter (fewer splits).
        threshold = max(cfg.diarization_threshold, 0.8) if guess_me else cfg.diarization_threshold

        def who():
            turns = diarize(audio, n, threshold)
            return turns, speaker_prints(audio, turns)

        with ThreadPoolExecutor(1) as pool:
            fut = pool.submit(who)
            words, lang = transcribe(audio, cfg.whisper_model, cfg.language, cfg.vocabulary)
            turns, prints = fut.result()
        languages.add(lang)
        known = identify(prints, exclude)
        labels = {spk: known[spk][0] if spk in known else f"{prefix}{spk + 1}" for spk in {t.speaker for t in turns}}
        if guess_me and cfg.me not in labels.values() and len(labels) > 1:
            # On your own mic you're the closest voice: clearly the loudest speaker is you.
            loud = {}
            for spk in labels:
                seg = [audio[int(t.start * 16000): int(t.end * 16000)] for t in turns if t.speaker == spk and spk not in known]
                if seg:
                    loud[spk] = float(np.sqrt(np.mean(np.concatenate(seg) ** 2)))
            ranked = sorted(loud, key=loud.get, reverse=True)
            if len(ranked) >= 2 and loud[ranked[0]] >= 1.4 * loud[ranked[1]]:
                labels[ranked[0]] = cfg.me
        for spk, p in prints.items():
            session_prints[labels[spk]] = p
        recognised = ", ".join(f"{name} ({sim:.0%})" for name, sim in known.values())
        print(f"   {len(words)} words, {len(labels)} speaker(s)" + (f" — recognised: {recognised}" if recognised else ""))
        if not turns:
            return words, group_words(words, lambda w: prefix.strip() or "Speaker")
        return words, group_words(words, lambda w: labels[speaker_for(w, turns)])

    if audio_file:  # a single recording (e.g. exported from Teams or a phone)
        step(f"Loading {audio_file.name}")
        audio = load_audio(audio_file)
        step(f"Transcribing + identifying speakers ({len(audio) / 16000 / 60:.0f} min of audio)")
        tracks.append(diarized_track(audio, "Speaker ", speakers)[1])
        track_names.append("file")
    else:
        system_words: list = []
        sys_file, mic_file = session / "system.caf", session / "mic.caf"
        if has_audio(sys_file):
            audio = load_audio(sys_file)
            if is_silent(audio):
                print("   system track is silent — skipping")
            else:
                step(f"Remote participants: transcribing + identifying speakers ({len(audio) / 16000 / 60:.0f} min)")
                system_words, system_utts = diarized_track(audio, "Speaker ", speakers, exclude={cfg.me})
                tracks.append(system_utts)
                track_names.append("meeting")
        if has_audio(mic_file):
            audio = load_audio(mic_file)
            if not room and not system_words:
                # No meeting audio (permission missing, or an in-person meeting): everyone is on
                # the mic, so separate the voices instead of labelling them all as you.
                print("   no meeting audio — separating the voices on your microphone")
                room = True
            if room:
                step(f"Room microphone: transcribing + identifying speakers ({len(audio) / 16000 / 60:.0f} min)")
                tracks.append(diarized_track(audio, "Speaker ", speakers, guess_me=True)[1])
                track_names.append("room")
            else:
                step(f"Your microphone: transcribing ({len(audio) / 16000 / 60:.0f} min)")
                words, lang = transcribe(audio, cfg.whisper_model, cfg.language, cfg.vocabulary)
                languages.add(lang)
                own = drop_echo(words, system_words)
                print(f"   {len(own)} words ({len(words) - len(own)} dropped as speaker echo)")
                tracks.append(group_words(own, lambda w: cfg.me))
                track_names.append("mic")
                # Learn your own voice too (helps in-room meetings and imported recordings).
                # Only here: with the meeting audio on its own track, the mic is really just you.
                spans = [audio[int(w.start * 16000): int(w.end * 16000)] for w in own]
                if cfg.me != "Me" and sum(len(x) for x in spans) > 16000 * 5:
                    enroll(cfg.me, [embed(np.concatenate(spans)[: 16000 * 60])])

    utterances = merge(*tracks)
    if not utterances:
        sys.exit("No speech found in the recording.")
    if session_prints:
        save_session_prints(session, session_prints)
    meta = {"title": title, "languages": sorted(l for l in languages if l), "tracks": track_names,
            "duration": max(u.end for u in utterances), "created": started_at(session).isoformat(timespec="seconds")}
    save_json(utterances, session / "transcript.json", meta)
    write_transcript(session, utterances, title or "Meeting")
    print(f"   transcript ready in {time.time() - t0:.0f}s")

    if summary:
        free_whisper()
        write_notes(session, cfg)
    print(f"\n✅ Done in {time.time() - t0:.0f}s → {session}")



def has_audio(path: Path) -> bool:
    return path.exists() and path.stat().st_size > 8192


def started_at(session: Path) -> datetime:
    """Recording start: from the app's meeting.json, else the folder's creation time."""
    try:
        return datetime.fromisoformat(json.loads((session / "meeting.json").read_text())["started"])
    except Exception:
        return datetime.fromtimestamp(session.stat().st_birthtime)


def free_whisper():
    """Release Whisper's GPU memory before loading the LLM (matters on 16 GB Macs)."""
    try:
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder

        ModelHolder.model = None
        ModelHolder.model_path = None
        mx.clear_cache()
    except Exception:
        pass


def write_transcript(session: Path, utterances, title: str):
    from .transcript import to_markdown

    (session / "transcript.md").write_text(to_markdown(utterances, title))


def write_notes(session: Path, cfg: Config):
    from .notes import parse_notes, split_title
    from .summarize import summarize
    from .transcript import fmt_time, load_json, main_language, to_plain

    utterances, meta = load_json(session / "transcript.json")
    language = notes_language(cfg, main_language(utterances) or (meta.get("languages") or [""])[0])
    context = calendar_context(session)
    step(f"Writing the summary and to-do list ({language})")
    t0 = time.time()
    ai_title, body = split_title(summarize(to_plain(utterances), cfg, language, context))
    speakers = list(dict.fromkeys(u.speaker for u in utterances))
    created = datetime.fromisoformat(meta["created"]) if "created" in meta else datetime.now()
    title = meta.get("title") or ai_title or f"Meeting {created:%Y-%m-%d %H:%M}"
    header = [
        f"# {title}",
        "",
        f"- **Date:** {created:%Y-%m-%d %H:%M}",
        f"- **Duration:** {fmt_time(meta['duration'])}",
        f"- **Participants:** {', '.join(speakers)}",
        "- **Full transcript:** [transcript.md](transcript.md)",
        "",
        "",
    ]
    (session / "notes.md").write_text("\n".join(header) + body + "\n")
    write_transcript(session, utterances, title)
    notes = {"title": title, "date": created.isoformat(timespec="seconds"), "duration": meta["duration"],
             "participants": speakers, "tracks": meta.get("tracks", []), **parse_notes(body)}
    (session / "notes.json").write_text(json.dumps(notes, indent=1, ensure_ascii=False))
    print(f"   notes ready in {time.time() - t0:.0f}s")


def notes_language(cfg: Config, spoken: str) -> str:
    """The notes' language: fixed in settings, or ("auto") the meeting's main language."""
    if cfg.summary_language.lower() != "auto":
        return cfg.summary_language
    from mlx_whisper.tokenizer import LANGUAGES

    return LANGUAGES.get(spoken, "english").title()


def calendar_context(session: Path) -> str:
    """Calendar details the app saved in meeting.json (event title, attendees)."""
    try:
        info = json.loads((session / "meeting.json").read_text())
    except Exception:
        return ""
    cal = info.get("calendar") or {}
    lines = []
    if cal.get("title"):
        lines.append(f"Calendar event: {cal['title']}")
    names = [a.get("name") or a.get("email", "") for a in cal.get("attendees", [])]
    if cal.get("organizer"):
        lines.append(f"Organizer: {cal['organizer']}")
    if names:
        lines.append(f"Invited: {', '.join(n for n in names if n)}")
    return "\n".join(lines)


def cmd_process(args, cfg: Config):
    target = Path(args.path).expanduser().resolve()
    if target.is_dir():
        if not any(target.glob("*.caf")):
            sys.exit(f"No mic.caf / system.caf in {target}")
        process_session(target, cfg, args.title or "", args.room, args.speakers, summary=not args.no_summary)
    elif target.is_file():
        session = new_session_dir(cfg, args.title or target.stem)
        process_session(session, cfg, args.title or "", args.room, args.speakers,
                        audio_file=target, summary=not args.no_summary)
    else:
        sys.exit(f"Not found: {target}")


# ---------------------------------------------------------------- rename / summarize


def cmd_rename(args, cfg: Config):
    from .transcript import load_json, save_json

    session = Path(args.folder).expanduser().resolve()
    utterances, meta = load_json(session / "transcript.json")
    mapping = {}
    for pair in args.mapping:
        if "=" not in pair:
            sys.exit(f'Expected "Old name=New name", got: {pair}')
        old, new = (s.strip() for s in pair.split("=", 1))
        mapping[old] = new
    known = {u.speaker for u in utterances}
    for old in mapping:
        if old not in known:
            sys.exit(f"No speaker called '{old}'. Speakers: {', '.join(sorted(known))}")
    for u in utterances:
        u.speaker = mapping.get(u.speaker, u.speaker)
    save_json(utterances, session / "transcript.json", meta)

    # Teach the voice library: next time these voices get their names automatically.
    from .voices import enroll, load_session_prints, save_session_prints

    prints = load_session_prints(session)
    for old, new in mapping.items():
        if old in prints:
            p = prints.pop(old)
            prints[new] = p
            if not re.fullmatch(r"Speaker \d+", new):
                enroll(new, [p])
                print(f"Learned {new}'s voice.")
    if prints:
        save_session_prints(session, prints)
    write_transcript(session, utterances, meta.get("title") or "Meeting")
    print("Transcript updated.")
    if not args.no_summary:
        write_notes(session, cfg)


def cmd_setup(args, cfg: Config):
    from .setup import run_setup

    run_setup(cfg)


def cmd_summarize(args, cfg: Config):
    write_notes(Path(args.folder).expanduser().resolve(), cfg)


def main():
    p = argparse.ArgumentParser(prog="meetscribe", description="Local meeting transcription + notes")
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--title", help="meeting title (used for the folder name)")
        sp.add_argument("--room", action="store_true",
                        help="in-person meeting: everyone on the mic, identify speakers on it")
        sp.add_argument("--speakers", type=int, default=0,
                        help="number of (remote) speakers if known — improves speaker separation")
        sp.add_argument("--no-summary", action="store_true", help="transcript only, skip the AI notes")

    r = sub.add_parser("record", help="record a meeting (Ctrl+C to stop), then process it")
    common(r)
    r.add_argument("--app", help='only capture this app\'s audio, e.g. "Microsoft Teams"')
    r.add_argument("--no-process", action="store_true", help="just record; process later")
    r.set_defaults(func=cmd_record)

    pr = sub.add_parser("process", help="process a recording folder or any audio file")
    pr.add_argument("path")
    common(pr)
    pr.set_defaults(func=cmd_process)

    rn = sub.add_parser("rename", help='name speakers, e.g. "Speaker 1=Alice", then redo the notes')
    rn.add_argument("folder")
    rn.add_argument("mapping", nargs="+")
    rn.add_argument("--no-summary", action="store_true")
    rn.set_defaults(func=cmd_rename)

    sm = sub.add_parser("summarize", help="(re)write notes.md from transcript.json")
    sm.add_argument("folder")
    sm.set_defaults(func=cmd_summarize)

    st = sub.add_parser("setup", help="download the speaker, speech and summary models")
    st.set_defaults(func=cmd_setup)

    args = p.parse_args()
    args.func(args, load_config())


if __name__ == "__main__":
    main()
