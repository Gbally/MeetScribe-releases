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
import multiprocessing
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from datetime import datetime
from pathlib import Path

from .config import PROJECT_ROOT, Config, load_config

RECORDER = PROJECT_ROOT / "bin" / "meeting-recorder"


def new_session_dir(cfg: Config, title: str, when: datetime | None = None) -> Path:
    slug = re.sub(r"[^\w-]+", "-", title).strip("-")[:50]
    name = (when or datetime.now()).strftime("%Y-%m-%d_%H%M") + (f"_{slug}" if slug else "")
    path, n = cfg.notes_path / name, 1
    while path.exists() and any(path.iterdir()):  # never write over another meeting (same name, same minute)
        n += 1
        path = cfg.notes_path / f"{name}-{n}"
    path.mkdir(parents=True, exist_ok=True)
    return path


from .progress import step  # noqa: E402  (status lines, translatable by the app)


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
    from .diarize import speakers as diarized_speakers
    from .transcribe import transcribe
    from .transcript import drop_echo, group_words, merge, save_json, speaker_for

    from .voices import embed, enroll, identify, save_session_prints, speaker_prints

    from . import progress
    from .clips import make_clips

    t0 = time.time()
    tracks: list[list] = []
    track_names: list[str] = []  # which audio was usable: "meeting", "mic", "room", "file"
    audio_by_track: dict[str, np.ndarray] = {}
    languages = set()
    session_prints: dict = {}  # label → voiceprint, saved so naming a speaker teaches the library
    progress.hook_whisper()

    def tagged(utts, track):
        for u in utts:
            u.track = track
        tracks.append(utts)
        track_names.append(track)

    def diarized_track(audio, prefix: str, n: int, stage: str, exclude: set[str] = frozenset(), guess_me: bool = False,
                       cap: int = 0):
        # Diarization (+ voiceprints) runs on the CPU, in another process, while Whisper uses the GPU.
        # Voices re-recorded through laptop speakers sound alike less: be stricter (fewer splits).
        threshold = max(cfg.diarization_threshold, 0.8) if guess_me else cfg.diarization_threshold

        progress.start(stage)
        with ProcessPoolExecutor(1, mp_context=multiprocessing.get_context("spawn")) as pool:
            fut = pool.submit(diarized_speakers, audio, n, threshold, cap)
            words, lang = transcribe(audio, cfg.whisper_model, cfg.language, vocabulary)
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

    # Load everything first, so progress can be weighted by the amount of audio.
    sys_audio = mic_audio = file_audio = None
    if audio_file:  # a single recording (e.g. exported from Teams or a phone)
        step("Loading %@", audio_file.name)
        file_audio = load_audio(audio_file)
    else:
        sys_file, mic_file = session / "system.caf", session / "mic.caf"
        if has_audio(sys_file):
            sys_audio = load_audio(sys_file)
            if is_silent(sys_audio):
                print("   system track is silent — skipping")
                sys_audio = None
        if has_audio(mic_file):
            mic_audio = load_audio(mic_file)
        if sys_audio is None and mic_audio is not None and not room:
            # No meeting audio (permission missing, or an in-person meeting): everyone is on
            # the mic, so separate the voices instead of labelling them all as you.
            print("   no meeting audio — separating the voices on your microphone")
            room = True

    # At most this many people besides you, when the calendar knows the attendees.
    calendar = meeting_info(session).get("calendar") or {}
    others = len(calendar.get("attendees") or [])
    # Whisper spells names it has been told about: yours, the invited people's, the meeting title.
    told = [cfg.me if cfg.me != "Me" else "", calendar.get("title", "")]
    told += [a.get("name", "") for a in calendar.get("attendees") or []]
    # …and the names and jargon that came back in earlier meetings of the same series.
    from .vocab import learned
    from .voices import load_library

    try:
        earlier = learned(cfg.notes_path, calendar, [cfg.vocabulary, *told], list(load_library()), cfg.me)
    except Exception as e:  # a hint only: never worth failing the recording for
        print(f"   (no vocabulary from earlier meetings: {e})")
        earlier = []
    if earlier:
        print("   vocabulary from earlier meetings: " + ", ".join(earlier))
    vocabulary = ", ".join(x for x in [cfg.vocabulary.strip(" ,"), *told, *earlier] if x)

    def work(a):  # rough seconds of processing per track (model load + Whisper ≈ 10× real time)
        return 8 + len(a) / 16000 / 10 if a is not None else 0

    total_audio = sum(len(a) for a in (sys_audio, mic_audio, file_audio) if a is not None) / 16000
    progress.plan([("file", work(file_audio)), ("meeting", work(sys_audio)), ("mic", work(mic_audio)),
                   ("notes", notes_work(cfg, total_audio) if summary else 0)])

    if file_audio is not None:
        step("Transcribing + identifying speakers (%@ min of audio)", f"{len(file_audio) / 16000 / 60:.0f}")
        tagged(diarized_track(file_audio, "Speaker ", speakers, "file", cap=others + 1 if others else 0)[1], "file")
        audio_by_track["file"] = file_audio
    else:
        system_words: list = []
        if sys_audio is not None:
            step("Remote participants: transcribing + identifying speakers (%@ min)", f"{len(sys_audio) / 16000 / 60:.0f}")
            system_words, system_utts = diarized_track(sys_audio, "Speaker ", speakers, "meeting", exclude={cfg.me},
                                                       cap=others)
            tagged(system_utts, "meeting")
            audio_by_track["meeting"] = sys_audio
        if mic_audio is not None:
            audio = mic_audio
            if room:
                step("Room microphone: transcribing + identifying speakers (%@ min)", f"{len(audio) / 16000 / 60:.0f}")
                tagged(diarized_track(audio, "Speaker ", speakers, "mic", guess_me=True,
                                     cap=others + 1 if others else 0)[1], "room")
                audio_by_track["room"] = audio
            else:
                step("Your microphone: transcribing (%@ min)", f"{len(audio) / 16000 / 60:.0f}")
                progress.start("mic")
                words, lang = transcribe(audio, cfg.whisper_model, cfg.language, vocabulary, own_mic=True)
                languages.add(lang)
                own = drop_echo(words, system_words)
                print(f"   {len(own)} words ({len(words) - len(own)} dropped as speaker echo)")
                tagged(group_words(own, lambda w: cfg.me), "mic")
                audio_by_track["mic"] = audio
                # Learn your own voice too (helps in-room meetings and imported recordings).
                # Only here: with the meeting audio on its own track, the mic is really just you.
                spans = [audio[int(w.start * 16000): int(w.end * 16000)] for w in own]
                if cfg.me != "Me" and sum(len(x) for x in spans) > 16000 * 5:
                    enroll(cfg.me, [embed(np.concatenate(spans)[: 16000 * 60])])

    utterances = merge(*tracks)
    if not utterances:
        sys.exit("No speech found in the recording.")
    # "Speaker N" → a name from the calendar invitations, when the transcript makes it clear.
    from .names import guess_names

    invited = [a.get("name", "") for a in (meeting_info(session).get("calendar") or {}).get("attendees") or []]
    guessed = guess_names(utterances, invited, cfg.me)
    if guessed:
        print("   probably: " + ", ".join(f"{label} = {name}" for label, name in guessed.items()))
        for u in utterances:
            u.speaker = guessed.get(u.speaker, u.speaker)
        session_prints = {guessed.get(k, k): v for k, v in session_prints.items()}
    if session_prints:
        save_session_prints(session, session_prints)
    meta = {"title": title, "languages": sorted(l for l in languages if l), "tracks": track_names,
            "guessed_names": sorted(guessed.values()),
            "duration": max(u.end for u in utterances), "created": started_at(session).isoformat(timespec="seconds")}
    save_json(utterances, session / "transcript.json", meta)
    write_transcript(session, utterances, title or "Meeting")
    make_clips(session, utterances, audio_by_track)
    print(f"   transcript ready in {time.time() - t0:.0f}s")

    if summary:
        free_whisper()
        write_notes(session, cfg)
    print(f"\n✅ Done in {time.time() - t0:.0f}s → {session}")



def notes_work(cfg: Config, audio_seconds: float) -> float:
    """Rough seconds the local LLM needs for the notes (reading + writing)."""
    writing = {"brief": 30, "standard": 40, "detailed": 70}.get(cfg.summary_style, 40)
    return writing + audio_seconds / 60 * 1.5


def has_audio(path: Path) -> bool:
    return path.exists() and path.stat().st_size > 8192


def meeting_info(session: Path) -> dict:
    """The app's meeting.json (title, start, calendar event…), or {}."""
    try:
        return json.loads((session / "meeting.json").read_text())
    except Exception:
        return {}


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


def write_notes(session: Path, cfg: Config, template: str = ""):
    from .notes import parse_notes, split_title
    from .summarize import TEMPLATES, summarize
    from .transcript import load_json, main_language, to_plain

    utterances, meta = load_json(session / "transcript.json")
    language = notes_language(cfg, main_language(utterances) or (meta.get("languages") or [""])[0])
    context = calendar_context(session)
    # The type asked for on the command line, else the meeting's own (picked in the app), else the default.
    template = template or meeting_info(session).get("template") or cfg.template
    if template not in TEMPLATES:
        template = "general"
    step("Writing the summary and to-do list (%@)", language)
    from . import progress

    progress.ensure("notes")
    t0 = time.time()
    created = datetime.fromisoformat(meta["created"]) if "created" in meta else datetime.now()
    ai_title, body = split_title(summarize(to_plain(utterances), cfg, language, context, template, created.date()))
    title = meta.get("title") or ai_title or f"Meeting {created:%Y-%m-%d %H:%M}"
    if meeting_info(session).get("label"):  # a copy made to compare models: "Weekly sync (Qwen3.5 9B)"
        title = f"{title} ({meeting_info(session)['label']})"
    notes = {"title": title, "date": created.isoformat(timespec="seconds"), "duration": meta["duration"],
             "participants": list(dict.fromkeys(u.speaker for u in utterances)), "tracks": meta.get("tracks", []),
             "template": template, "guessed_names": meta.get("guessed_names", []), **parse_notes(body)}
    save_notes(session, notes)
    print(f"   notes ready in {time.time() - t0:.0f}s")


def save_notes(session: Path, notes: dict) -> None:
    """Writes notes.json (with due dates worked out) and notes.md, and titles the transcript."""
    from .dates import parse_due
    from .notes import render_markdown
    from .transcript import fmt_time, load_json

    notes["version"] = 2  # has due dates; the app upgrades older notes once via `render`
    meeting_day = datetime.fromisoformat(notes["date"]).date()
    for a in notes.get("actions", []):
        d = parse_due(a.get("due", ""), meeting_day)
        a["due_date"] = d.isoformat() if d else None
    (session / "notes.json").write_text(json.dumps(notes, indent=1, ensure_ascii=False))
    (session / "notes.md").write_text(render_markdown(notes, fmt_time(notes.get("duration", 0))) + "\n")
    if (session / "transcript.json").exists():
        utterances, _ = load_json(session / "transcript.json")
        write_transcript(session, utterances, notes["title"])


def cmd_render(args, cfg: Config):
    """Re-derive notes.md, due dates and the transcript title after notes.json was edited."""
    session = Path(args.folder).expanduser().resolve()
    save_notes(session, json.loads((session / "notes.json").read_text()))


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
    elif target.is_file() and target.suffix.lower() in TRANSCRIPT_SUFFIXES:
        import_transcript(target, cfg, args.title or "", summary=not args.no_summary)
    elif target.is_file():
        session = new_session_dir(cfg, args.title or target.stem)
        process_session(session, cfg, args.title or "", args.room, args.speakers,
                        audio_file=target, summary=not args.no_summary)
    else:
        sys.exit(f"Not found: {target}")


from .imports import SUFFIXES as TRANSCRIPT_SUFFIXES  # noqa: E402


def import_transcript(path: Path, cfg: Config, title: str, summary: bool = True):
    """A transcript made by another app (Teams, Zoom, Meet, Granola…) → a meeting folder with
    the same transcript and notes as a recording (no audio, so no voice clips)."""
    from .imports import read_transcript
    from .transcript import save_json

    step("Reading the transcript %@", path.name)
    try:
        utterances = read_transcript(path, cfg.me if cfg.me != "Me" else "")
    except (ValueError, KeyError, OSError) as e:
        sys.exit(f"Couldn't read {path.name}: {e}")
    # The meeting's day, for "Friday" or "next week": a date in the file name, else when it was saved.
    m = re.search(r"(20\d\d)[-_.]?(\d\d)[-_.]?(\d\d)", path.stem)
    try:
        created = datetime(int(m[1]), int(m[2]), int(m[3]), 9) if m else datetime.fromtimestamp(path.stat().st_mtime)
    except ValueError:
        created = datetime.fromtimestamp(path.stat().st_mtime)
    # Named after the meeting's day; the file name minus a date it starts with ("2026-10-23 Standup").
    name = title or re.sub(r"^\W*20\d\d[-_.]?\d\d[-_.]?\d\d\W*", "", path.stem) or path.stem
    session = new_session_dir(cfg, name, created)
    (session / "meeting.json").write_text(json.dumps({"title": title, "started": created.isoformat(timespec="seconds"),
                                                      "imported": path.name}))
    meta = {"title": title, "languages": sorted({u.lang for u in utterances if u.lang}), "tracks": ["file"],
            "guessed_names": [], "duration": max(u.end for u in utterances), "created": created.isoformat(timespec="seconds")}
    save_json(utterances, session / "transcript.json", meta)
    write_transcript(session, utterances, title or path.stem)
    print(f"   {len(utterances)} lines, {len({u.speaker for u in utterances})} speaker(s)")
    if summary:
        write_notes(session, cfg)
    print(f"\n✅ Done → {session}")


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
    # Names guessed from the calendar are confirmed (or corrected) once you name them.
    meta["guessed_names"] = [n for n in meta.get("guessed_names", []) if n not in mapping]
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
    from .clips import rename_clips

    rename_clips(session, mapping)
    write_transcript(session, utterances, meta.get("title") or "Meeting")
    print("Transcript updated.")
    if all(old == new for old, new in mapping.items()):  # only confirming guessed names
        notes_file = session / "notes.json"
        if notes_file.exists():
            notes = json.loads(notes_file.read_text())
            notes["guessed_names"] = meta["guessed_names"]
            notes_file.write_text(json.dumps(notes, indent=1, ensure_ascii=False))
        return
    if not args.no_summary:
        write_notes(session, cfg)


def cmd_clips(args, cfg: Config):
    """Voice clips for a meeting processed before clips existed (needs its audio files)."""
    from .audio import load_audio
    from .clips import make_clips
    from .transcript import load_json

    session = Path(args.folder).expanduser().resolve()
    utterances, meta = load_json(session / "transcript.json")
    audio = {}
    if has_audio(session / "system.caf"):
        audio["meeting"] = load_audio(session / "system.caf")
    if has_audio(session / "mic.caf"):
        audio["room" if "room" in meta.get("tracks", []) else "mic"] = load_audio(session / "mic.caf")
    if not audio:
        sys.exit("This meeting's audio was not kept, so there are no voice samples.")
    for u in utterances:  # older transcripts don't say which track a line came from
        if not u.track:
            if "room" in audio:
                u.track = "room"
            elif u.speaker == cfg.me or "meeting" not in audio:
                u.track = "mic"
            else:
                u.track = "meeting"
    make_clips(session, utterances, audio)
    print("Voice samples ready.")


def cmd_ask(args, cfg: Config):
    from .ask import ask

    result = ask(" ".join(args.question), cfg)
    if args.json:
        print("@@result " + json.dumps(result, ensure_ascii=False), flush=True)
    else:
        print("\n" + result["answer"] + "\n")
        for s in result["sources"]:
            print(f"[{s['n']}] {s['title']} — {s['date']}" + (f" at {s['time'] // 60:.0f} min" if s["time"] else ""))


def cmd_models(args, cfg: Config):
    from .setup import check_model, delete_model, download_model, installed_models

    if args.action == "check":
        print("@@result " + json.dumps(check_model(args.repo, args.kind)), flush=True)
    elif args.action == "download":
        download_model(args.repo)
    elif args.action == "delete":
        print(f"Freed {delete_model(args.repo):.1f} GB")
    else:
        print("@@result " + json.dumps(installed_models()))


def cmd_setup(args, cfg: Config):
    from .setup import run_setup

    run_setup(cfg)


def cmd_summarize(args, cfg: Config):
    write_notes(Path(args.folder).expanduser().resolve(), cfg, args.template or "")


def main():
    try:  # company networks that inspect HTTPS: trust the certificates macOS trusts (their Keychain)
        import truststore

        truststore.inject_into_ssl()
    except Exception:  # noqa: BLE001 — without it, downloads use Python's own certificates as before
        pass
    p = argparse.ArgumentParser(prog="meetscribe", description="Local meeting transcription + notes")
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--title", help="meeting title (used for the folder name)")
        sp.add_argument("--room", action="store_true",
                        help="in-person meeting: everyone on the mic, identify speakers on it")
        sp.add_argument("--speakers", type=int, default=0,
                        help="number of (remote) speakers if known — improves speaker separation")
        sp.add_argument("--no-summary", action="store_true", help="transcript only, skip the AI notes")
        sp.add_argument("--template", help="meeting type: general, one_on_one, standup, client, interview, workshop")

    r = sub.add_parser("record", help="record a meeting (Ctrl+C to stop), then process it")
    common(r)
    r.add_argument("--app", help='only capture this app\'s audio, e.g. "Microsoft Teams"')
    r.add_argument("--no-process", action="store_true", help="just record; process later")
    r.set_defaults(func=cmd_record)

    pr = sub.add_parser("process", help="process a recording folder, any audio file, or a transcript "
                                        "from another app (.vtt, .srt, .docx, .txt, .md)")
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
    sm.add_argument("--template", help="meeting type (see process --help)")
    sm.set_defaults(func=cmd_summarize)

    ak = sub.add_parser("ask", help="ask a question across all your meetings")
    ak.add_argument("question", nargs="+")
    ak.add_argument("--json", action="store_true", help="machine-readable result (for the app)")
    ak.set_defaults(func=cmd_ask)

    rd = sub.add_parser("render", help="rebuild notes.md after editing notes.json")
    rd.add_argument("folder")
    rd.set_defaults(func=cmd_render)

    cl = sub.add_parser("clips", help="make voice samples of each speaker for an older meeting")
    cl.add_argument("folder")
    cl.set_defaults(func=cmd_clips)

    md = sub.add_parser("models", help="list / download / delete AI models")
    md.add_argument("action", choices=["list", "download", "delete", "check"])
    md.add_argument("repo", nargs="?")
    md.add_argument("--kind", choices=["notes", "speech"], default="notes")
    md.set_defaults(func=cmd_models)

    st = sub.add_parser("setup", help="download the speaker, speech and summary models")
    st.set_defaults(func=cmd_setup)

    args = p.parse_args()
    cfg = load_config()
    if getattr(args, "template", None):
        cfg.template = args.template
    try:
        args.func(args, cfg)
    except (MemoryError, RuntimeError) as e:
        if isinstance(e, MemoryError) or re.search(r"memory|malloc", str(e), re.I):  # Metal: "Insufficient Memory"
            from . import progress

            progress.out_of_memory()
        raise


if __name__ == "__main__":
    main()
