# Third-party notices

MeetScribe itself is released under the [MIT License](LICENSE). It builds on the projects below,
which keep their own licenses. Only `uv` ships inside the app; the rest is downloaded on first
setup (the Python engine) or when a model is chosen (the AI models).

## AI models

| Model | Used for | License | Source |
|---|---|---|---|
| OpenAI Whisper large-v3-turbo (MLX conversion) | speech to text | MIT | [openai/whisper](https://github.com/openai/whisper), [mlx-community/whisper-large-v3-turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo) |
| Qwen3 4B / 8B (MLX 4-bit conversions) | notes, answers | Apache 2.0 | [Qwen](https://huggingface.co/Qwen), [mlx-community](https://huggingface.co/mlx-community) |
| pyannote segmentation 3.0 (ONNX) | speaker separation | MIT | [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0), via [sherpa-onnx models](https://github.com/k2-fsa/sherpa-onnx/releases) |
| NVIDIA NeMo TitaNet small (ONNX) | speaker voiceprints | CC BY 4.0 | [nvidia/speakerverification_en_titanet_small](https://huggingface.co/nvidia/speakerverification_en_titanet_small), via [sherpa-onnx models](https://github.com/k2-fsa/sherpa-onnx/releases) |

Custom models chosen in Settings → AI models come with their own licenses (see their Hugging Face
page).

## Software

| Project | License | Source |
|---|---|---|
| uv (bundled in the app) | MIT or Apache 2.0 | [astral-sh/uv](https://github.com/astral-sh/uv) |
| Python (installed by uv) | PSF License | [python.org](https://docs.python.org/3/license.html) |
| MLX, mlx-lm, mlx-whisper | MIT | [ml-explore](https://github.com/ml-explore) |
| sherpa-onnx | Apache 2.0 | [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) |
| ONNX Runtime | MIT | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) |
| Hugging Face Hub, Transformers, tokenizers | Apache 2.0 | [huggingface](https://github.com/huggingface) |
| NumPy | BSD 3-Clause | [numpy/numpy](https://github.com/numpy/numpy) |
| soundfile / libsndfile | BSD 3-Clause / LGPL 2.1 | [bastibe/python-soundfile](https://github.com/bastibe/python-soundfile), [libsndfile](https://github.com/libsndfile/libsndfile) |

The complete list of Python packages and versions is in [`uv.lock`](uv.lock); each package's
license file is installed next to it in `~/Library/Application Support/MeetScribe/venv`.

The full license texts are at the links above. CC BY 4.0 attribution: TitaNet © NVIDIA
Corporation, used unmodified (converted to ONNX by the sherpa-onnx project).
