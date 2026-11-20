"""Which machine the engine runs on, and so which backends it uses.

  Mac (Apple silicon)    MLX: Whisper and the notes model on the GPU, in this process
  PC with an NVIDIA GPU  faster-whisper on CUDA (float16), llama.cpp's server with the model on the GPU
  any other PC           faster-whisper on the CPU (int8), llama.cpp's server on the CPU

HESPER_DEVICE=cpu (or cuda) forces a choice: e.g. to see how a colleague's laptop without a GPU
does on a PC that has one."""

import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from functools import cache

# HESPER_AS_PC=1: a Mac runs the other PCs' backends (faster-whisper, llama.cpp), to test them.
IS_MAC = sys.platform == "darwin" and not os.environ.get("HESPER_AS_PC")


@dataclass(frozen=True)
class Device:
    kind: str           # "mlx", "cuda" or "cpu"
    name: str = ""      # the GPU's name
    vram_gb: float = 0  # its memory

    @property
    def whisper(self) -> tuple[str, str]:
        """faster-whisper's (device, compute_type)."""
        return ("cuda", "float16") if self.kind == "cuda" else ("cpu", "int8")

    def gpu_layers(self, model_gb: float) -> int:
        """llama.cpp's --n-gpu-layers: all of them when the model fits with room for its context
        (~1.5 GB at 16k tokens), a share of them when it fits partly, none on the CPU."""
        if self.kind != "cuda":
            return 0
        room = self.vram_gb - 1.5
        if room >= model_gb:
            return 999
        return max(0, int(32 * room / model_gb))  # Qwen3.5 4B has 32 layers; a rough share


def _nvidia() -> tuple[str, float] | None:
    """The first NVIDIA GPU (name, GB), from nvidia-smi (installed with the driver)."""
    smi = shutil.which("nvidia-smi")
    if not smi and sys.platform == "win32":
        smi = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "nvidia-smi.exe")
    if not smi or not os.path.exists(smi):
        return None
    try:
        out = subprocess.run([smi, "--query-gpu=name,memory.total", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10).stdout.strip().splitlines()
    except (OSError, subprocess.SubprocessError):
        return None
    if not out or "," not in out[0]:
        return None
    name, mib = out[0].rsplit(",", 1)
    try:
        return name.strip(), float(mib) / 1024
    except ValueError:
        return None


def _cuda_works() -> bool:
    """The driver is there, but can CTranslate2 (faster-whisper) use it? Not without the CUDA
    libraries, which are only downloaded on PCs with an NVIDIA GPU."""
    try:
        import ctranslate2

        return ctranslate2.get_cuda_device_count() > 0
    except Exception:
        return False


@cache
def device() -> Device:
    forced = os.environ.get("HESPER_DEVICE", "").lower()
    if IS_MAC:
        return Device("mlx")
    if forced == "cpu":
        return Device("cpu")
    gpu = _nvidia()
    if gpu and (forced == "cuda" or _cuda_works()):
        return Device("cuda", *gpu)
    return Device("cpu")
