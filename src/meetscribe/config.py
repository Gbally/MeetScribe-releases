"""Settings, with optional overrides from config.toml at the project root."""

import os
import tomllib
from dataclasses import dataclass, fields
from pathlib import Path

from .hardware import IS_MAC

PROJECT_ROOT = Path(__file__).resolve().parents[2]
# Data dir: the project folder when run from source, ~/Library/Application Support/MeetScribe
# when run by the menu bar app (which sets MEETSCRIBE_HOME).
HOME = Path(os.environ.get("MEETSCRIBE_HOME", PROJECT_ROOT))
CONFIG_FILE = HOME / "config.toml"
MODELS_DIR = HOME / "models"


@dataclass
class Config:
    # Where meeting folders are created.
    notes_dir: str = "~/Documents/MeetingNotes"
    # Your name in transcripts (everything from the mic track).
    me: str = "Me"
    # Only capture audio from this app (e.g. "Microsoft Teams"); empty = all system audio.
    app: str = ""

    # Speech-to-text: an MLX Whisper repo on a Mac; elsewhere a faster-whisper model (a name it
    # knows, like "large-v3-turbo", or a CTranslate2 repo on Hugging Face).
    whisper_model: str = "mlx-community/whisper-large-v3-turbo" if IS_MAC else "large-v3-turbo"
    # "" = auto-detect (one language per track); "en" = English only; "en,fr" = the meeting
    # may switch between these languages (detected every few seconds).
    language: str = ""
    # Names / jargon that Whisper should spell correctly, e.g. "FlagQuest, Supabase, Kubernetes".
    vocabulary: str = ""

    # Speaker separation: clustering threshold (lower = more speakers), 0 < x < 1. Fine enough
    # not to glue two people together (0.7 did, with 4+ voices); the extra splits are merged
    # back afterwards (matching voiceprints, the calendar's head count).
    diarization_threshold: float = 0.6

    # Summary. backend = "mlx" (in-process, the Mac's), "llama" (llama.cpp's server, started by the
    # engine: other PCs; llm_model is then a GGUF "repo:quant") or "openai" (Ollama / LM Studio).
    llm_backend: str = "mlx" if IS_MAC else "llama"
    llm_model: str = "mlx-community/Qwen3-8B-4bit" if IS_MAC else "unsloth/Qwen3.5-4B-GGUF:Q4_K_M"
    # For llm_backend = "llama": llama-server(.exe); "" = models/llama.cpp/ or on the PATH.
    llama_server: str = ""
    # For llm_backend = "openai": Ollama = http://localhost:11434/v1, LM Studio = http://localhost:1234/v1
    llm_url: str = "http://localhost:11434/v1"
    # Language of the notes: "auto" = the meeting's main language, or e.g. "English".
    summary_language: str = "auto"
    # How much detail: "detailed" (long, full context), "standard", or "brief" (bullets only).
    summary_style: str = "standard"
    # Default meeting type: general, one_on_one, standup, client, interview, workshop.
    template: str = "general"
    # Transcripts longer than this (in tokens) are summarized in chunks first.
    max_context_tokens: int = 20000

    @property
    def notes_path(self) -> Path:
        return Path(self.notes_dir).expanduser()


def load_config() -> Config:
    cfg = Config()
    if CONFIG_FILE.exists():
        data = tomllib.loads(CONFIG_FILE.read_text())
        known = {f.name for f in fields(Config)}
        for key, value in data.items():
            if key not in known:
                raise SystemExit(f"config.toml: unknown setting '{key}'")
            setattr(cfg, key, value)
    return cfg
