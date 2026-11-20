"""The notes model outside the Mac: llama.cpp's server (llama-server), started by the engine on a free
port of this machine only (127.0.0.1), the model on the GPU when there is a usable NVIDIA one
(hardware.py), stopped when the engine exits.

The model is a GGUF on Hugging Face, "repo:quant" (llama-server downloads it into models/gguf the
first time), or a local .gguf file. The server keeps what it last read: a pass over the same
transcript only reads its own instructions, as the MLX path does with its prompt cache."""

import atexit
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from .config import MODELS_DIR, Config
from .hardware import device

CONTEXT = 24576  # tokens: max_context_tokens (20k) of transcript + the instructions and the answer
MODEL_GB = 3.0   # Qwen3.5 4B in Q4_K_M, for how many layers fit on the GPU

_server = None


def binary(cfg: Config) -> str:
    exe = "llama-server.exe" if sys.platform == "win32" else "llama-server"
    for c in (cfg.llama_server, str(MODELS_DIR / "llama.cpp" / exe), shutil.which(exe) or ""):
        if c and Path(c).exists():
            return c
    raise SystemExit(f"{exe} not found: put llama.cpp's release in {MODELS_DIR / 'llama.cpp'} or set llama_server")


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class LlamaServer:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.proc = None
        self.url = ""

    def start(self) -> str:
        if self.proc and self.proc.poll() is None:
            return self.url
        port = _free_port()
        model = self.cfg.llm_model
        source = ["-m", model] if model.lower().endswith(".gguf") else ["-hf", model]
        layers = device().gpu_layers(MODEL_GB)
        cmd = [binary(self.cfg), *source, "--host", "127.0.0.1", "--port", str(port), "--ctx-size", str(CONTEXT),
               "--jinja", "--parallel", "1", "--n-gpu-layers", str(layers),
               "--no-mmproj"]  # -hf also fetches the vision part (~0.7 GB on the GPU): text only here
        env = {**os.environ, "LLAMA_CACHE": str(MODELS_DIR / "gguf")}
        log = open(MODELS_DIR.parent / "llama-server.log", "ab")
        flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
        self.proc = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, creationflags=flags)
        self.url = f"http://127.0.0.1:{port}"
        atexit.register(self.stop)
        print(f"   notes model: llama.cpp on {'the GPU' if layers else 'the CPU'} ({device().name or 'no NVIDIA GPU'})",
              flush=True)
        deadline = time.monotonic() + 1800  # the first start downloads the model
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise SystemExit(f"llama-server stopped (exit {self.proc.returncode}): see {log.name}")
            try:
                with urllib.request.urlopen(self.url + "/health", timeout=5) as r:
                    if r.status == 200:
                        return self.url
            except (urllib.error.URLError, OSError):
                pass
            time.sleep(1)
        raise SystemExit("llama-server didn't start in 30 minutes")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def post(self, path: str, body: dict, stream: bool = False):
        req = urllib.request.Request(self.start() + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            return urllib.request.urlopen(req, timeout=3600) if stream else json.load(urllib.request.urlopen(req, timeout=3600))
        except urllib.error.HTTPError as e:
            msg = e.read().decode(errors="replace")
            if "memory" in msg.lower() or "alloc" in msg.lower():
                raise MemoryError(msg) from e
            raise SystemExit(f"llama-server: {e.code} {msg[:500]}") from e

    def count_tokens(self, text: str) -> int:
        return len(self.post("/tokenize", {"content": text, "add_special": False})["tokens"])

    def yes_odds(self, messages: list[dict], yes, no) -> float | None:
        """log P(yes) − log P(no) for the answer's first token, from the server's top log-probabilities
        (the judge, summarize.judge_actions). The instructions at the start of the message are the same
        for the whole meeting: cache_prompt keeps them read."""
        import math

        body = {"messages": messages, "max_tokens": 1, "temperature": 0, "logprobs": True, "top_logprobs": 20,
                "chat_template_kwargs": {"enable_thinking": False}, "cache_prompt": True}
        try:
            top = self.post("/v1/chat/completions", body)["choices"][0]["logprobs"]["content"][0]["top_logprobs"]
        except (KeyError, IndexError, TypeError):
            return None
        floor = min((t["logprob"] for t in top), default=-30.0) - 1  # not in the top 20: below the last one

        def mass(words) -> float:
            found = [t["logprob"] for t in top if t["token"] in words]
            return math.log(sum(math.exp(x) for x in found)) if found else floor
        return mass(set(yes)) - mass(set(no))

    def chat(self, messages: list[dict], max_tokens: int, temperature: float, prose: bool, on_token=None) -> str:
        """As LLM.chat's MLX path: no thinking, top-p 0.8, a mild repetition penalty for prose only."""
        body = {"messages": messages, "max_tokens": max_tokens, "temperature": temperature, "top_p": 0.8,
                "chat_template_kwargs": {"enable_thinking": False}, "cache_prompt": True, "stream": True}
        if prose:
            body |= {"repeat_penalty": 1.08, "repeat_last_n": 256}
        out, n = "", 0
        with self.post("/v1/chat/completions", body, stream=True) as r:
            for line in r:
                line = line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:") or line == "data: [DONE]":
                    continue
                delta = json.loads(line[5:])["choices"][0].get("delta", {}).get("content") or ""
                if delta:
                    out += delta
                    n += 1
                    if on_token:
                        on_token(n)
        return out


def server(cfg: Config) -> LlamaServer:
    global _server
    if _server is None or _server.cfg.llm_model != cfg.llm_model:
        if _server:
            _server.stop()
        _server = LlamaServer(cfg)
    return _server
