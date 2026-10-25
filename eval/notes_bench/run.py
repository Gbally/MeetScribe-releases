"""Notes benchmark: synthetic meetings (macOS voices, known script and truth) → transcription →
notes with one or more models → scores.   Run with the app's Python, from the repository:

  "$HOME/Library/Application Support/MeetScribe/venv/bin/python" eval/notes_bench/run.py OUT \\
      --model mlx-community/Qwen3.5-4B-4bit [--model mlx-community/Qwen3-4B-Instruct-2507-4bit] \\
      [--rounds 3] [--meetings standup,client|all] [--templates own|general|both] [--engine]

OUT keeps the audio (made once), the transcripts and every set of notes; run again with more
rounds or models and only what's missing is done. The report is printed at the end and written
to OUT/report.json (python eval/notes_bench/report.py OUT prints it again). The models must be
downloaded already (Settings → AI models). Your own settings and voice library aren't used:
each model gets its own MeetScribe home in OUT/homes."""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from scenarios import SCENARIOS  # noqa: E402

SUPPORT = Path.home() / "Library/Application Support/MeetScribe"


def arm_name(repo: str) -> str:
    """mlx-community/Qwen3.5-4B-4bit → qwen3.5-4b"""
    name = repo.split("/")[-1].lower()
    for tail in ("-4bit", "-8bit", "-mlx", "-instruct-2507"):
        name = name.replace(tail, "")
    return name


def home_for(out: Path, repo: str) -> Path:
    home = out / "homes" / arm_name(repo)
    home.mkdir(parents=True, exist_ok=True)
    (home / "config.toml").write_text(
        f'notes_dir = "{out / "notes"}"\nme = "Guillaume"\nlanguage = "en,fr"\nsummary_language = "auto"\n'
        f'summary_style = "standard"\ntemplate = "general"\nllm_model = "{repo}"\n'
        f'whisper_model = "mlx-community/whisper-large-v3-turbo"\n')
    if not (home / "models").exists():
        (home / "models").symlink_to(SUPPORT / "models")
    return home


def run_engine(home: Path, log: Path, *args) -> tuple[int, float]:
    env = dict(os.environ, MEETSCRIBE_HOME=str(home), PYTHONPATH=str(ROOT / "src"), PYTHONUNBUFFERED="1",
               HF_HUB_DISABLE_PROGRESS_BARS="1", TOKENIZERS_PARALLELISM="false")
    t0 = time.time()
    with open(log, "w") as f:
        code = subprocess.run([sys.executable, "-m", "meetscribe", *args], cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT).returncode
    return code, time.time() - t0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", type=Path)
    ap.add_argument("--model", action="append", required=True, help="notes model repo (repeat for several)")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--meetings", default="all")
    ap.add_argument("--templates", choices=["own", "general", "both"], default="own")
    ap.add_argument("--engine", action="store_true", help="also the 30-min bilingual meeting (its audio takes a few minutes to make)")
    a = ap.parse_args()
    out = a.out.resolve()
    meetings = list(SCENARIOS) if a.meetings == "all" else a.meetings.split(",")
    if a.engine:
        meetings.append("engine")
    homes = {repo: home_for(out, repo) for repo in a.model}
    times = out / "times.txt"

    for sc in meetings:  # audio once, transcription once (it doesn't depend on the notes model)
        base = out / sc / "meeting"
        if not (base / "mic.caf").exists():
            base.mkdir(parents=True, exist_ok=True)
            subprocess.run([sys.executable, str(HERE / "make_audio.py"), sc, str(base)], check=True)
        if not (base / "transcript.json").exists():
            code, secs = run_engine(homes[a.model[0]], base / "process.log", "process", str(base), "--no-summary")
            with open(times, "a") as f:
                f.write(f"{sc} transcribe exit={code} seconds={secs:.0f}\n")
            if code:
                sys.exit(f"Transcribing {sc} failed — see {base / 'process.log'}")

    for r in range(1, a.rounds + 1):  # round by round, so a run cut short still covers every meeting
        for sc in meetings:
            own = "workshop" if sc == "engine" else SCENARIOS[sc]["template"]
            templates = {"own": [own], "general": ["general"], "both": sorted({own, "general"})}[a.templates]
            for repo in a.model:
                for t in templates:
                    d = out / sc / f"{arm_name(repo)}-{t}-{r}"
                    if (d / "notes.json").exists():
                        continue
                    d.mkdir(parents=True, exist_ok=True)
                    for f in ("transcript.json", "transcript.md", "meeting.json"):
                        (d / f).write_bytes((out / sc / "meeting" / f).read_bytes())
                    code, secs = run_engine(homes[repo], d / "log.txt", "summarize", str(d), "--template", t)
                    with open(times, "a") as f:
                        f.write(f"{sc} {arm_name(repo)} {t} {r} exit={code} seconds={secs:.0f}\n")
                    print(f"{sc:16} {arm_name(repo):14} {t:11} round {r}: {'ok' if code == 0 else 'FAILED'} in {secs:.0f}s", flush=True)
                    if code and r == 1:
                        sys.exit(f"Notes failed — see {d / 'log.txt'}")

    subprocess.run([sys.executable, str(HERE / "report.py"), str(out)])


if __name__ == "__main__":
    main()
