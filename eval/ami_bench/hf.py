"""The base model in 4 bits on an NVIDIA GPU (transformers + bitsandbytes), for train.py and run_hf.py."""

import torch
import torch.nn.functional as F
from transformers import AttentionInterface, AutoModelForImageTextToText, BitsAndBytesConfig
from transformers.integrations.sdpa_attention import repeat_kv


def attention(module, q, k, v, mask, dropout=0.0, scaling=None, **kw):
    """SDPA with the keys and values repeated for each query head. PyTorch on Windows has no flash
    attention, and its memory-efficient kernel refuses grouped heads: the stock path then falls back to
    the math kernel, whose L×L matrices took 8 GB at 4k tokens (5 GB with this one)."""
    n = q.shape[1] // k.shape[1]
    out = F.scaled_dot_product_attention(q, repeat_kv(k, n), repeat_kv(v, n), attn_mask=mask, dropout_p=dropout,
                                         scale=scaling, is_causal=mask is None and q.shape[2] > 1)
    return out.transpose(1, 2).contiguous(), None


AttentionInterface.register("sdpa_kv", attention)


def load(name: str):
    return AutoModelForImageTextToText.from_pretrained(
        name, dtype=torch.bfloat16, device_map={"": 0}, attn_implementation="sdpa_kv",
        quantization_config=BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_use_double_quant=True,
                                               bnb_4bit_compute_dtype=torch.bfloat16,
                                               llm_int8_skip_modules=["visual", "lm_head"]))
