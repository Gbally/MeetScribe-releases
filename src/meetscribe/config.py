"""Settings, with optional overrides from config.toml at the project root."""

import tomllib
from dataclasses import dataclass, fields
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
CONFIG_FILE = PROJECT_ROOT / "config.toml"
MODELS_DIR = PROJECT_ROOT / "models"


@dataclass
class Config:
    # Where meeting folders are created.
    notes_dir: str = "~/Documents/MeetingNotes"
    # Your name in transcripts (everything from the mic track).
    me: str = "Me"
    # Only capture audio from this app (e.g. "Microsoft Teams"); empty = all system audio.
    app: str = ""

    # Speech-to-text (any MLX Whisper repo on Hugging Face).
    whisper_model: str = "mlx-community/whisper-large-v3-turbo"
    # "en", "fr", … or "" to auto-detect per track.
    language: str = ""
    # Names / jargon that Whisper should spell correctly, e.g. "FlagQuest, Supabase, Kubernetes".
    vocabulary: str = ""

    # Speaker separation: clustering threshold (lower = more speakers), 0 < x < 1.
    diarization_threshold: float = 0.5

    # Summary. backend = "mlx" (in-process, default) or "openai" (Ollama / LM Studio server).
    llm_backend: str = "mlx"
    llm_model: str = "mlx-community/Qwen3-8B-4bit"
    # For llm_backend = "openai": Ollama = http://localhost:11434/v1, LM Studio = http://localhost:1234/v1
    llm_url: str = "http://localhost:11434/v1"
    summary_language: str = "English"
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
