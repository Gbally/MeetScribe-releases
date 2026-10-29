"""Overall progress for the app: `@@progress <0..1>` lines on stdout.

The job is split into weighted stages (estimated seconds of work); each stage reports its own
0..1 fraction. Whisper's internal progress bar is redirected here.
"""

import faulthandler
import json
import os
import sys
import threading
import time
import types

_stages: list[tuple[str, float]] = []
_current = -1
_last_print = 0.0
_last_value = -1.0


def plan(stages: list[tuple[str, float]]) -> None:
    """Declare the stages as (name, estimated seconds)."""
    global _stages, _current, _last_value
    _stages = [(n, max(w, 0.1)) for n, w in stages]
    _current = -1
    _last_value = -1.0


def start(name: str) -> None:
    global _current
    names = [n for n, _ in _stages]
    if name in names:
        _current = names.index(name)
        update(0.0)


def update(fraction: float) -> None:
    global _last_print, _last_value
    if not _stages or _current < 0:
        return
    total = sum(w for _, w in _stages)
    done = sum(w for _, w in _stages[:_current]) + _stages[_current][1] * min(max(fraction, 0.0), 1.0)
    value = min(done / total, 0.999)
    now = time.monotonic()
    if value - _last_value >= 0.005 and (now - _last_print > 0.5 or value - _last_value > 0.05):
        print(f"@@progress {value:.3f}", flush=True)
        _last_print, _last_value = now, value


STALL = 600  # seconds without Whisper moving on: one 30-s window takes seconds, never minutes


def _watch() -> None:
    """Whisper once stopped moving, at a quarter of a 2-min meeting, for 10 hours (not seen again
    in 12 runs of the same audio). Rather than a job that never ends: say so, and stop — the
    meeting can be transcribed again. The Python stacks go to the log for a closer look."""
    while True:
        time.sleep(min(15, STALL / 4))
        since = _WhisperBar.moved
        if since and time.monotonic() - since > STALL:
            faulthandler.dump_traceback(sys.stderr, all_threads=True)
            print(f"Transcription stopped responding (no progress for {STALL // 60} minutes). "
                  "Try “Transcribe again”.", file=sys.stderr, flush=True)
            os._exit(3)


class _WhisperBar:
    """Stands in for tqdm inside mlx_whisper; `span` maps its 0..1 into part of the stage."""
    span = (0.0, 1.0)
    moved = 0.0  # when Whisper last moved on (0: not running)
    _watcher = None

    def __init__(self, total=0, **_):
        self.total, self.n = total or 1, 0

    def __enter__(self):
        _WhisperBar.moved = time.monotonic()
        if _WhisperBar._watcher is None:
            _WhisperBar._watcher = threading.Thread(target=_watch, daemon=True)
            _WhisperBar._watcher.start()
        return self

    def __exit__(self, *_):
        _WhisperBar.moved = 0.0
        return False

    def update(self, n):
        _WhisperBar.moved = time.monotonic()
        self.n += n
        lo, hi = _WhisperBar.span
        update(lo + (hi - lo) * self.n / self.total)


def hook_whisper() -> None:
    import importlib

    # Not `import mlx_whisper.transcribe`: the package's `transcribe` attribute is the function.
    t = importlib.import_module("mlx_whisper.transcribe")

    t.tqdm = types.SimpleNamespace(tqdm=_WhisperBar)


def whisper_span(lo: float, hi: float) -> None:
    """The next Whisper pass covers this part of the current stage."""
    _WhisperBar.span = (lo, hi)


def ensure(name: str) -> None:
    """Start `name`; if no plan includes it (e.g. regenerating notes only), it is the plan."""
    if name not in [n for n, _ in _stages]:
        plan([(name, 1.0)])
    start(name)


def out_of_memory() -> None:
    """Tells the app that a model ran out of memory — "@@memory speech" while transcribing, else
    "@@memory notes" — so it can say the model is too big for this Mac and suggest a smaller one."""
    name = _stages[_current][0] if 0 <= _current < len(_stages) else ""
    print(f"@@memory {'speech' if name in ('file', 'meeting', 'mic') else 'notes'}", flush=True)


def step(key: str, *args) -> None:
    """A status line: "→ text" for people, plus "@@step {key, args}" so the app can show it in
    the user's language (keys are translated in mac/Localization; %@ = an argument)."""
    text = key
    for a in args:
        text = text.replace("%@", str(a), 1)
    print(f"→ {text}", flush=True)
    print("@@step " + json.dumps({"key": key, "args": [str(a) for a in args]}, ensure_ascii=False), flush=True)
