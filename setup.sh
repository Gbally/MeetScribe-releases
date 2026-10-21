#!/bin/sh
# One-time setup: Python env, speaker models, recorder binary, and (optionally) the AI models.
set -e
cd "$(dirname "$0")"

if ! command -v uv >/dev/null 2>&1; then
  echo "Installing uv (Python package manager)…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
uv sync

mkdir -p models
if [ ! -f models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx ]; then
  echo "Downloading speaker segmentation model…"
  curl -fL https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2 | tar xj -C models
fi
if [ ! -f models/nemo_en_titanet_small.onnx ]; then
  echo "Downloading speaker embedding model…"
  curl -fL -o models/nemo_en_titanet_small.onnx https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx
fi

./scripts/build_recorder.sh

if [ "$1" = "--models" ]; then
  echo "Pre-downloading Whisper (~1.6 GB) and the summary model (~4.6 GB)…"
  .venv/bin/python -c "from huggingface_hub import snapshot_download as d; d('mlx-community/whisper-large-v3-turbo'); d('mlx-community/Qwen3-8B-4bit')"
fi
echo "✅ Setup done. Try: .venv/bin/meetscribe --help"
