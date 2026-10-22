"""One-time download of the models, with machine-readable progress for the app:
`→ <status>` lines and `@@progress <0..1>` lines on stdout."""

import tarfile
import threading
import time
import urllib.request
from pathlib import Path

from .config import MODELS_DIR, Config
from .progress import step

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

    step("Checking what needs downloading…")
    sizes = {repo: _repo_size(repo) for repo in (cfg.whisper_model, cfg.llm_model)}
    small = 50e6
    total = small + sum(sizes.values())

    step("Downloading speaker models")
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
    for repo, label in ((cfg.whisper_model, "Downloading the speech recognition model (%@ GB)"),
                        (cfg.llm_model, "Downloading the summary model (%@ GB)")):
        step(label, f"{sizes[repo] / 1e9:.1f}")
        for attempt in range(3):
            try:
                _hf_download(repo, base, total)
                break
            except Exception as e:  # flaky networks: resume a couple of times
                if attempt == 2:
                    raise
                step("Download interrupted (%@), retrying…", e.__class__.__name__)
                time.sleep(3)
        base += sizes[repo]
        _progress(base, total)

    step("Ready")


def download_model(repo: str) -> None:
    """Download one model (when switching models in the app), with progress."""
    size = _repo_size(repo)
    step("Downloading %@ (%@ GB)", repo.split("/")[-1], f"{size / 1e9:.1f}")
    for attempt in range(3):
        try:
            _hf_download(repo, 0, size)
            break
        except Exception as e:
            if attempt == 2:
                raise
            step("Download interrupted (%@), retrying…", e.__class__.__name__)
            time.sleep(3)
    step("Ready")


def _linked_blobs(repo_paths) -> set[Path]:
    """Weight files outside the repo folders that their blobs/ entries link to. Recent Hugging Face
    versions keep them in a shared folder, and deleting a model only removes the links."""
    out = set()
    for repo_path in repo_paths:
        blobs = Path(repo_path) / "blobs"
        for link in blobs.iterdir() if blobs.is_dir() else []:
            if link.is_symlink():
                target = link.resolve()
                if target.exists() and Path(repo_path).resolve() not in target.parents:
                    out.add(target)
    return out


def delete_model(repo: str) -> float:
    """Remove a downloaded model from the Hugging Face cache; returns GB freed."""
    from huggingface_hub import scan_cache_dir

    cache = scan_cache_dir()
    for r in cache.repos:
        if r.repo_id == repo:
            shared = _linked_blobs([r.repo_path])
            strategy = cache.delete_revisions(*[rev.commit_hash for rev in r.revisions])
            strategy.execute()
            # Shared weight files nothing links to any more.
            still_used = _linked_blobs([o.repo_path for o in cache.repos if o.repo_id != repo])
            for target in shared - still_used:
                target.unlink(missing_ok=True)
            return r.size_on_disk / 1e9
    return 0.0


def installed_models() -> dict[str, float]:
    """repo id → size on disk (GB) of the models in the cache."""
    from huggingface_hub import scan_cache_dir

    return {r.repo_id: round(r.size_on_disk / 1e9, 2) for r in scan_cache_dir().repos}


def check_model(repo: str, kind: str) -> dict:
    """Can the engine run this Hugging Face model as a `notes` or `speech` model? Reads only its
    config and file list (a few KB). → {"compatible": True/False, "reason": str, "architecture": str}"""
    import importlib.util
    import json as _json

    from huggingface_hub import HfApi, hf_hub_download

    try:
        files = {s.rfilename for s in HfApi().model_info(repo, files_metadata=False).siblings}
        cfg = _json.loads(Path(hf_hub_download(repo, "config.json")).read_text())
    except Exception as e:
        return {"compatible": False, "architecture": "",
                "reason": f"Couldn't read the model's configuration ({e.__class__.__name__}).",
                "key": "Couldn't read the model's configuration (%@).", "args": [e.__class__.__name__]}

    arch = cfg.get("model_type") or (cfg.get("text_config") or {}).get("model_type") or ""
    if kind == "speech":
        if "n_mels" in cfg and ({"weights.safetensors", "weights.npz"} & files):
            return {"compatible": True, "architecture": "whisper (MLX)", "reason": "A Whisper model in MLX format.", "key": "A Whisper model in MLX format.", "args": []}
        if arch == "whisper":
            return {"compatible": False, "architecture": "whisper",
                    "reason": "This Whisper model isn't in MLX format. Use a version from mlx-community instead.", "key": "This Whisper model isn't in MLX format. Use a version from mlx-community instead.", "args": []}
        return {"compatible": False, "architecture": arch,
                "reason": "MeetScribe's speech engine only runs Whisper models in MLX format.", "key": "MeetScribe's speech engine only runs Whisper models in MLX format.", "args": []}

    # Notes: an architecture mlx-lm knows, plus a tokenizer.
    if arch in ("whisper", "wav2vec2", "hubert") or "n_mels" in cfg:
        return {"compatible": False, "architecture": arch, "reason": "This is a speech model, not a text model.", "key": "This is a speech model, not a text model.", "args": []}
    from mlx_lm.utils import MODEL_REMAPPING

    module = MODEL_REMAPPING.get(arch, arch).replace("-", "_")
    if not module or importlib.util.find_spec(f"mlx_lm.models.{module}") is None:
        return {"compatible": False, "architecture": arch,
                "reason": f"MeetScribe's notes engine can't run the “{arch or 'unknown'}” architecture.",
                "key": "MeetScribe's notes engine can't run the “%@” architecture.", "args": [arch or "unknown"]}
    if not ({"tokenizer.json", "tokenizer.model", "tokenizer_config.json"} & files):
        return {"compatible": False, "architecture": arch, "reason": "The model has no tokenizer files.", "key": "The model has no tokenizer files.", "args": []}
    if not any(f.endswith(".safetensors") for f in files):
        return {"compatible": False, "architecture": arch, "reason": "The model has no .safetensors weights.", "key": "The model has no .safetensors weights.", "args": []}
    return {"compatible": True, "architecture": arch, "reason": f"Supported architecture ({arch}).",
            "key": "Supported architecture (%@).", "args": [arch]}
