"""One-time download of the models, with machine-readable progress for the app:
`→ <status>` lines and `@@progress <0..1>` lines on stdout."""

import tarfile
import threading
import time
import urllib.request
from pathlib import Path

from .config import MODELS_DIR, Config

SHERPA = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
SEGMENTATION_URL = f"{SHERPA}/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
EMBEDDING_URL = f"{SHERPA}/speaker-recongition-models/nemo_en_titanet_small.onnx"


def _progress(done: float, total: float):
    print(f"@@progress {min(1.0, done / total) if total else 0:.3f}", flush=True)


def _download(url: str, dest: Path, base: float, total: float, size_hint: float):
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url, timeout=60) as r, open(tmp, "wb") as f:
        size = float(r.headers.get("Content-Length") or size_hint)
        got = 0
        while chunk := r.read(1 << 20):
            f.write(chunk)
            got += len(chunk)
            _progress(base + got / size * size_hint, total)
    tmp.rename(dest)


def _repo_size(repo: str) -> int:
    from huggingface_hub import HfApi

    info = HfApi().model_info(repo, files_metadata=True)
    return sum(s.size or 0 for s in info.siblings)


def _hf_download(repo: str, base: float, total: float):
    from huggingface_hub import snapshot_download
    from huggingface_hub.constants import HF_HUB_CACHE

    blobs = Path(HF_HUB_CACHE) / f"models--{repo.replace('/', '--')}" / "blobs"
    stop = threading.Event()

    def watch():
        while not stop.wait(1):
            size = sum(p.stat().st_size for p in blobs.glob("*") if p.is_file()) if blobs.exists() else 0
            _progress(base + size, total)

    t = threading.Thread(target=watch, daemon=True)
    t.start()
    try:
        snapshot_download(repo)
    finally:
        stop.set()
        t.join()


def run_setup(cfg: Config):
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    seg_dir = MODELS_DIR / "sherpa-onnx-pyannote-segmentation-3-0"
    emb = MODELS_DIR / "nemo_en_titanet_small.onnx"

    print("→ Checking what needs downloading…", flush=True)
    sizes = {repo: _repo_size(repo) for repo in (cfg.whisper_model, cfg.llm_model)}
    small = 50e6
    total = small + sum(sizes.values())

    print("→ Downloading speaker models", flush=True)
    if not (seg_dir / "model.onnx").exists():
        archive = MODELS_DIR / "segmentation.tar.bz2"
        _download(SEGMENTATION_URL, archive, 0, total, 7e6)
        with tarfile.open(archive) as tar:
            tar.extractall(MODELS_DIR, filter="data")
        archive.unlink()
    if not emb.exists():
        _download(EMBEDDING_URL, emb, 7e6, total, 40e6)
    _progress(small, total)

    base = small
    for repo, label in ((cfg.whisper_model, "speech recognition"), (cfg.llm_model, "summary")):
        print(f"→ Downloading the {label} model ({sizes[repo] / 1e9:.1f} GB)", flush=True)
        for attempt in range(3):
            try:
                _hf_download(repo, base, total)
                break
            except Exception as e:  # flaky networks: resume a couple of times
                if attempt == 2:
                    raise
                print(f"→ Download interrupted ({e.__class__.__name__}), retrying…", flush=True)
                time.sleep(3)
        base += sizes[repo]
        _progress(base, total)

    print("→ Ready", flush=True)


def download_model(repo: str) -> None:
    """Download one model (when switching models in the app), with progress."""
    size = _repo_size(repo)
    print(f"→ Downloading {repo.split('/')[-1]} ({size / 1e9:.1f} GB)", flush=True)
    for attempt in range(3):
        try:
            _hf_download(repo, 0, size)
            break
        except Exception as e:
            if attempt == 2:
                raise
            print(f"→ Download interrupted ({e.__class__.__name__}), retrying…", flush=True)
            time.sleep(3)
    print("→ Ready", flush=True)


def delete_model(repo: str) -> float:
    """Remove a downloaded model from the Hugging Face cache; returns GB freed."""
    from huggingface_hub import scan_cache_dir

    cache = scan_cache_dir()
    for r in cache.repos:
        if r.repo_id == repo:
            strategy = cache.delete_revisions(*[rev.commit_hash for rev in r.revisions])
            strategy.execute()
            return strategy.expected_freed_size / 1e9
    return 0.0


def installed_models() -> dict[str, float]:
    """repo id → size on disk (GB) of the models in the cache."""
    from huggingface_hub import scan_cache_dir

    return {r.repo_id: round(r.size_on_disk / 1e9, 2) for r in scan_cache_dir().repos}
