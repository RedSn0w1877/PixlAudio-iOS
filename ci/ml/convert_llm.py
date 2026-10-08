"""The downloadable local AI model (2026-10-07, plan local-ai option C): a Qwen2.5 instruct model (Apache-2.0)
converted to a stateful Core ML ML Program, checked against the transformers reference, and packaged with our own
tokenizer file. Build-time only; nothing here ships in the app (the app runs the model through Core ML with its own
Swift tokenizer and sampler).

Contract with the app (App/Services/AI/LocalModel/, ModelCatalog.LocalLLM):
  inputs   inputIds    int32   [1, Q]          the new tokens, Q in 1...maxQuery
           causalMask  float16 [1, 1, Q, E]    E = P + Q, P = tokens already in the cache; 0 = attend, -inf = masked
  states   keyCache    float16 [L, KV, C, D]   rows 0..<P must hold this sequence's earlier tokens (C = context)
           valueCache  float16 [L, KV, C, D]
  output   logits      float16 [1, 1, V]       next-token logits after the LAST input position only
  metadata pixl.* (context, maxQuery, vocab, eos ids, model id, revision, precision, quantization)
Positions are implicit (the new tokens sit at P..<E); rows past E are never read, so a state can be reused for a
prompt that shares a prefix with the previous one.

Subcommands:
  convert   (Linux, ~16 GB RAM) download the pinned revision; reference greedy continuations and teacher-forced
            logits with transformers (fp32, eager); our stateful PyTorch module checked against them through the
            app's chunked-prefill + decode path (argmax must agree everywhere); trace + ct.convert (iOS 18 ML Program
            with states) in two compute precisions — fp16, and "mixed" (RMSNorm reductions in fp32) — each
            weight-quantized to int4 per block of 32 (linear symmetric, Apple's on-device Llama recipe); the tokenizer
            file and PixlCore's tokenizer fixtures; the tiny random model for the app's simulator smoke test.
  parity    (macOS) runs every candidate through Core ML (CPU_ONLY and ALL) along the same path, gates it against the
            reference, and packages the first passing one with the tokenizer as an uncompressed ustar tar.
  tokenizer (anywhere) only the tokenizer file + fixtures (used locally to regenerate PixlCore's test fixtures).

Gate (per compute unit, over every teacher-forced position of every test prompt): finite logits; argmax agreement
with the fp32 reference >= 0.85; the reference's top token within the candidate's top 5 >= 0.97; mean |log-prob
difference| of the reference's top token <= 0.6. The PyTorch module (fp32) must match transformers' argmax at >= 99 %
of the positions (only near-ties may flip) with a mean |log-prob difference| <= 0.01.
"""

import argparse
import gc
import json
import os
import resource
import struct
import sys
import tarfile
import time

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from common import sha256_of, write_json  # noqa: E402

MODELS = {
    "qwen2.5-1.5b": {"id": "Qwen/Qwen2.5-1.5B-Instruct", "revision": "989aa7980e4cf806f80c7fef2b1adb7bc71aa306",
                     "package": "Qwen25Instruct1_5B.mlpackage", "asset": "qwen2_5_1_5b_instruct",
                     "title": "Qwen2.5 1.5B Instruct"},
    "qwen2.5-0.5b": {"id": "Qwen/Qwen2.5-0.5B-Instruct", "revision": "7ae557604adf67be50417f59c2c2f167def9a775",
                     "package": "Qwen25Instruct0_5B.mlpackage", "asset": "qwen2_5_0_5b_instruct",
                     "title": "Qwen2.5 0.5B Instruct"},
}
TOKENIZER_FILE = "qwen2_5.pxbpe"
# float16 safety, exact in fp32 (build_module): Core ML computes in float16, where Qwen2.5-1.5B's RMSNorm statistics
# and unscaled attention scores overflow (probe run 37711190768; parity run 37708304642 gave NaN everywhere).
CONVERT_OPTIONS = {"safe_norm": True, "q_fold": True, "mlp_scale": 1 / 32}
CONTEXT = 4096
MAX_QUERY = 512
PREFILL_CHUNK = 64
CONTINUATION = 32
TOP_K = 10
GATE = {"argmax_agreement": 0.85, "reference_in_top5": 0.97, "mean_abs_logprob_diff": 0.6}

# The app's prompt shapes (App/Services/AI/OnDevicePrompts.swift, OnDeviceCuration.swift,
# OnDeviceLyricsTranslation.swift), so the gate measures what the features send.
PROMPTS = [
    ("You are a music curator. Choose songs from the numbered list that fit the listener's request, in a good play "
     "order: open gently, build up, finish strong, and avoid the same artist twice in a row. Answer only with song "
     "numbers from the list.",
     "Request: rainy day indie\nListener: plays mostly Indie, Alternative; top artists Phoebe Bridgers, The National.\n"
     "Songs:\n1. Motion Sickness — Phoebe Bridgers · Indie · liked · 12 plays\n2. Bloodbuzz Ohio — The National · "
     "Alternative · 4 plays\n3. Holocene — Bon Iver · Folk\n4. Mr. Brightside — The Killers · Rock · 30 plays\n"
     "5. Skinny Love — Bon Iver · Folk · liked\n6. Pink + White — Frank Ocean · R&B\n7. Re: Stacks — Bon Iver · Folk\n"
     "8. Kyoto — Phoebe Bridgers · Indie · 2 plays\nChoose 3 to 5 songs for the request, in play order.\n"
     "Answer with the song numbers only, separated by commas."),
    ("Write one short, upbeat sentence of at most 12 words that introduces the music the user asked for. No quotes, "
     "no emoji, no lists.",
     "Request: play some chill lo-fi for studying\nSongs found: 14"),
    ("You translate song lyrics. Translate each numbered line into the language the user names, keeping its meaning "
     "and tone. Answer with one line per number, in the same order: the number, a period, then only the translation. "
     "Keep names as they are. No notes.",
     "Translate into Vietnamese:\n1. I keep on dancing in the rain\n2. Every heartbeat sings your name\n"
     "3. We were young and wild and free"),
    ("You are Taizo, the AI DJ inside the PixlAudio music app, running privately on this iPhone.\nAnswer in 1 to 4 "
     "warm, plain sentences. No markdown, no JSON, no lists unless the user asks for one.",
     "Who wrote Bohemian Rhapsody, and which album is it on?"),
    ("You plan playlists from a listener's request. Pick the genres and artists that fit the request best, only from "
     "the allowed values (none when nothing fits), up to three mood words, an energy level from 1 (calm) to 5 "
     "(intense), and whether the listener's familiar favorites suit it. Answer in exactly five lines:\n"
     "genres: …\nartists: …\nmoods: …\nenergy: 1-5\nfamiliar: yes or no",
     "Request: upbeat songs for a summer road trip\nListener: plays mostly Pop, Rock; top artists Taylor Swift, "
     "The Killers.\nAllowed genres: Pop, Rock, Indie, Hip-Hop, Folk\nAllowed artists: Taylor Swift, The Killers, "
     "Phoebe Bridgers, Kendrick Lamar"),
    ("You write a short listening insight for a music app's home screen. From the facts given, write 2 to 3 warm "
     "sentences about the listener's habits and what they might enjoy next. No quotes, no emoji, no markdown.",
     "Time: evening\nTop genres this week: Indie, Folk\nTop artist: Bon Iver\nSongs played today: 23\n"
     "New favorites: 2"),
]

# Tokenizer fixtures: what PixlCore's BytePairTokenizer must reproduce exactly (ids from the real tokenizer).
TOKENIZER_CASES = [
    "", " ", "  ", "\n", "\n\n", " \n ", "a", "Hello, world!", "hello world", "Hello  world", "Hello   world  ",
    "I'm sure you'll love it. We've, they'd, SHE'S, IT'LL, 'ſ", "it'ſ x'S y'Re z'VE q'D w'M", "don't stop believin'",
    "'tis the season", "'", "a'b'c", "''s",
    "Track 01 — 3:45, 128 bpm, 2024-10-07, $9.99, 100%, 1e-6, 3.14159",
    "12345678901234567890", "x = [1, 2, 3]; y = {\"a\": 1}", "def f(x):\n\treturn x * 2\n",
    "line one\r\nline two\r\n\r\nline four", "tabs\tand\tspaces \t mixed", "trailing spaces   ", "   leading",
    "Mưa rơi trên phố vắng, anh nhớ em nhiều lắm", "Tôi yêu âm nhạc Việt Nam", "Đường về nhà",
    "你好，世界！我爱音乐。", "日本語のテキストとカタカナ", "안녕하세요 음악", "Привет, мир", "مرحبا بالعالم",
    "Ünïcödé çàfé naïve résumé", "é café (decomposed)", "emoji 🎵🎶 👩‍👩‍👧 ❤️ 🇻🇳",
    "<|im_start|>user\nhi there<|im_end|>\n<|im_start|>assistant\n", "a<|endoftext|>b", "<|im_end|><|im_end|>",
    "https://example.com/path?query=1&b=2#frag", "C'est la vie, n'est-ce pas?", "rock'n'roll", "...!!!???",
    " non-breaking space", "zero​width", "‘curly’ “quotes”", "#hashtag @mention", "ALLCAPS WORDS HERE",
    "1, 2, 3, 12, 40", "3,4,5", "Choose 3 to 5 songs.", "Bohemian Rhapsody — Queen · Rock · liked · 5 plays",
    "genres: Rock, Indie\nartists: Radiohead\nmoods: calm, rainy\nenergy: 2\nfamiliar: yes",
]


def peak_rss_gb() -> float:
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss  # KiB on Linux, bytes on macOS
    return round(peak / (1 << 30 if sys.platform == "darwin" else 1 << 20), 2)


def log(*args):
    print(f"[{time.strftime('%H:%M:%S')}] [rss {peak_rss_gb()} GB]", *args, flush=True)


# MARK: - Tokenizer file ("pixl BPE v1")

def bytes_to_unicode() -> dict:
    """GPT-2's byte-level alphabet: every byte maps to a printable character."""
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return dict(zip(bs, [chr(c) for c in cs]))


def export_tokenizer(tokenizer_json: str, out_path: str, vocab_rows: int) -> dict:
    """Writes the compact tokenizer file the app loads (PixlNet `BytePairTokenizer`), little-endian:

        "PXBPE1\\0\\0", u32 version (1), u32 flags (bit 0: ignore_merges), u32 vocab rows (the embedding's row count)
        256 x u32           the token id of each byte value
        u32 M, M x (u32 left, u32 right, u32 result)          merges in priority order
        u32 S, S x (u32 id, u8 special, u16 n, n bytes UTF-8)  added tokens (matched in text before BPE)

    Only the Qwen2 shape is accepted: NFC normaliser, the Qwen2 split regex + byte-level pre-tokeniser, BPE without
    byte fallback, a byte-level decoder. The Swift side hard-codes that pipeline.
    """
    with open(tokenizer_json, encoding="utf-8") as f:
        tj = json.load(f)
    model = tj["model"]
    assert model["type"] == "BPE", model["type"]
    assert not model.get("byte_fallback"), "byte fallback is not supported"
    assert model.get("dropout") in (None, 0, 0.0)
    normalizer = tj.get("normalizer") or {}
    assert normalizer.get("type") == "NFC", normalizer
    pre = tj["pre_tokenizer"]
    assert pre["type"] == "Sequence", pre
    split, level = pre["pretokenizers"]
    expected_regex = (r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|"
                      r"\s*[\r\n]+|\s+(?!\S)|\s+")
    assert split["type"] == "Split" and split["pattern"]["Regex"] == expected_regex, split
    assert split["behavior"] == "Isolated" and not split.get("invert")
    assert level["type"] == "ByteLevel" and not level.get("add_prefix_space") and not level.get("use_regex"), level
    assert tj["decoder"]["type"] == "ByteLevel", tj["decoder"]

    vocab = model["vocab"]
    b2u = bytes_to_unicode()
    byte_ids = [vocab[b2u[b]] for b in range(256)]
    merges = []
    for m in model["merges"]:
        a, b = m.split(" ", 1) if isinstance(m, str) else m
        merges.append((vocab[a], vocab[b], vocab[a + b]))
    added = sorted((t["id"], bool(t.get("special")), t["content"]) for t in tj.get("added_tokens", []))
    for _, _, content in added:
        assert content, "empty added token"
    flags = 1 if model.get("ignore_merges") else 0

    blob = bytearray(b"PXBPE1\0\0")
    blob += struct.pack("<III", 1, flags, vocab_rows)
    blob += struct.pack(f"<{len(byte_ids)}I", *byte_ids)
    blob += struct.pack("<I", len(merges))
    for left, right, result in merges:
        blob += struct.pack("<III", left, right, result)
    blob += struct.pack("<I", len(added))
    for token_id, special, content in added:
        data = content.encode("utf-8")
        blob += struct.pack("<IBH", token_id, 1 if special else 0, len(data)) + data
    with open(out_path, "wb") as f:
        f.write(blob)
    return {"file": os.path.basename(out_path), "bytes": len(blob), "sha256": sha256_of(out_path),
            "merges": len(merges), "vocab": len(vocab), "added": len(added), "ignoreMerges": bool(flags)}


def tokenizer_fixtures(tokenizer_json: str, out_path: str, chat_tokenizer=None) -> None:
    """Encode/decode cases from the real tokenizer (Hugging Face `tokenizers`) plus a rendered chat."""
    from tokenizers import Tokenizer

    tok = Tokenizer.from_file(tokenizer_json)
    cases = []
    for text in TOKENIZER_CASES:
        ids = tok.encode(text, add_special_tokens=False).ids
        cases.append({"text": text, "ids": ids, "decoded": tok.decode(ids, skip_special_tokens=False)})
    chat = None
    if chat_tokenizer is not None:
        messages = [{"role": "system", "content": "You are Taizo, a friendly DJ."},
                    {"role": "user", "content": "Play something calm."},
                    {"role": "assistant", "content": "Here's a calm mix for you."},
                    {"role": "user", "content": "Who sings Holocene?"}]
        text = chat_tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        chat = {"messages": messages, "text": text, "ids": tok.encode(text, add_special_tokens=False).ids}
    specials = {name: tok.token_to_id(name) for name in ["<|endoftext|>", "<|im_start|>", "<|im_end|>"]}
    digits = {str(d): tok.token_to_id(str(d)) for d in range(10)}
    marks = {"comma": tok.token_to_id(","), "space": tok.encode(" ", add_special_tokens=False).ids}
    write_json(out_path, {"cases": cases, "chat": chat, "specials": specials, "digits": digits, "marks": marks})


# MARK: - The stateful PyTorch module

def build_module(cfg: dict, weights: dict, context: int, options: dict | None = None):
    """`options` (fp16 safety, all exact in fp32 arithmetic):
      mlp_scale     float, folded into the weights: up_proj x s, down_proj / s, so the MLP's widest values
                    (silu(gate) * up) are s times smaller while the layer's output is unchanged.
      q_fold        bool: 1/sqrt(head_dim) folded into q_proj (weight and bias; RoPE is linear), and attention written
                    out (matmul, mask, softmax, matmul) with no further scale, so q.k never forms unscaled.
      norm_fp32     bool: RMSNorm statistics in fp32 when the module runs in fp16 (what the "mixed" selector keeps).
      safe_norm     bool: RMSNorm on x / max|x| (eps / max|x|^2 added), so x^2 never forms: Qwen2.5-1.5B's residual
                    reaches ~6,600, its square overflows float16 (probe run 37711190768: mean x^2 = 79,556).
      probe         dict to fill with the largest |value| seen per kind (residual, mlp, q, k, scores, variance).
    """
    import torch
    import torch.nn.functional as F

    options = options or {}
    mlp_scale = float(options.get("mlp_scale", 1.0))
    q_fold = bool(options.get("q_fold", False))
    norm_fp32 = bool(options.get("norm_fp32", False))
    safe_norm = bool(options.get("safe_norm", False))

    layers = cfg["num_hidden_layers"]
    hidden = cfg["hidden_size"]
    heads = cfg["num_attention_heads"]
    kv_heads = cfg["num_key_value_heads"]
    head_dim = hidden // heads
    rep = heads // kv_heads
    eps = cfg["rms_norm_eps"]
    theta = cfg.get("rope_theta", 10000.0)

    class QwenStateful(torch.nn.Module):
        """Qwen2 decoder over a fixed-size KV cache held in two registered buffers (the Core ML states). Grouped
        query attention without copying the cache: each KV head's queries are stacked along the sequence axis."""

        def __init__(self):
            super().__init__()
            self.embed = torch.nn.Embedding(cfg["vocab_size"], hidden)
            self.input_norms = torch.nn.ParameterList()
            self.post_norms = torch.nn.ParameterList()
            self.q = torch.nn.ModuleList()
            self.k = torch.nn.ModuleList()
            self.v = torch.nn.ModuleList()
            self.o = torch.nn.ModuleList()
            self.gate = torch.nn.ModuleList()
            self.up = torch.nn.ModuleList()
            self.down = torch.nn.ModuleList()
            for _ in range(layers):
                self.input_norms.append(torch.nn.Parameter(torch.ones(hidden)))
                self.post_norms.append(torch.nn.Parameter(torch.ones(hidden)))
                self.q.append(torch.nn.Linear(hidden, heads * head_dim, bias=True))
                self.k.append(torch.nn.Linear(hidden, kv_heads * head_dim, bias=True))
                self.v.append(torch.nn.Linear(hidden, kv_heads * head_dim, bias=True))
                self.o.append(torch.nn.Linear(heads * head_dim, hidden, bias=False))
                self.gate.append(torch.nn.Linear(hidden, cfg["intermediate_size"], bias=False))
                self.up.append(torch.nn.Linear(hidden, cfg["intermediate_size"], bias=False))
                self.down.append(torch.nn.Linear(cfg["intermediate_size"], hidden, bias=False))
            self.final_norm = torch.nn.Parameter(torch.ones(hidden))
            shape = (layers, kv_heads, context, head_dim)
            self.register_buffer("keyCache", torch.zeros(shape, dtype=torch.float32))
            self.register_buffer("valueCache", torch.zeros(shape, dtype=torch.float32))
            # transformers' Qwen2RotaryEmbedding, tabulated for every position of the context.
            inv_freq = 1.0 / (theta ** (torch.arange(0, head_dim, 2, dtype=torch.int64).float() / head_dim))
            freqs = torch.outer(torch.arange(context, dtype=torch.float32), inv_freq)
            emb = torch.cat((freqs, freqs), dim=-1)
            self.register_buffer("ropeCos", emb.cos(), persistent=False)
            self.register_buffer("ropeSin", emb.sin(), persistent=False)

            self.probe = None

        def note(self, kind, value):
            if self.probe is not None:
                self.probe[kind] = max(self.probe.get(kind, 0.0), float(value.detach().abs().max().float()))

        def rms_norm(self, x, weight):
            if safe_norm:
                scale = x.abs().amax(-1, keepdim=True).clamp(min=1e-3)
                scaled = x / scale
                variance = scaled.pow(2).mean(-1, keepdim=True)
                self.note("variance", variance)
                return weight * (scaled * torch.rsqrt(variance + eps / (scale * scale)))
            if norm_fp32 and x.dtype != torch.float32:
                wide = x.float()
                variance = wide.pow(2).mean(-1, keepdim=True)
                self.note("variance", variance)
                return weight * (wide * torch.rsqrt(variance + eps)).to(x.dtype)
            variance = x.pow(2).mean(-1, keepdim=True)
            self.note("variance", variance)
            return weight * (x * torch.rsqrt(variance + eps))

        @staticmethod
        def rotate(x, cos, sin):
            half = x.shape[-1] // 2
            rotated = torch.cat((-x[..., half:], x[..., :half]), dim=-1)
            return x * cos + rotated * sin

        def forward(self, input_ids, causal_mask):
            q_len = input_ids.shape[-1]
            end = causal_mask.shape[-1]
            past = end - q_len
            x = self.embed(input_ids)
            cos = self.ropeCos[past:end].unsqueeze(0).unsqueeze(0)
            sin = self.ropeSin[past:end].unsqueeze(0).unsqueeze(0)
            mask = causal_mask.repeat(1, 1, rep, 1)
            for i in range(layers):
                h = self.rms_norm(x, self.input_norms[i])
                q = self.q[i](h).view(1, q_len, heads, head_dim).transpose(1, 2)
                k = self.k[i](h).view(1, q_len, kv_heads, head_dim).transpose(1, 2)
                v = self.v[i](h).view(1, q_len, kv_heads, head_dim).transpose(1, 2)
                q = self.rotate(q, cos, sin)
                k = self.rotate(k, cos, sin)
                self.note("q", q)
                self.note("k", k)
                self.keyCache[i:i + 1, :, past:end, :] = k
                self.valueCache[i:i + 1, :, past:end, :] = v
                keys = self.keyCache[i:i + 1, :, :end, :]
                values = self.valueCache[i:i + 1, :, :end, :]
                # [1, heads, Q, D] -> [1, kv_heads, rep * Q, D]: head h reads KV head h // rep, like repeat_kv.
                grouped = q.reshape(1, kv_heads, rep * q_len, head_dim)
                if q_fold:
                    scores = torch.matmul(grouped, keys.transpose(-1, -2))
                    self.note("scores", scores)
                    attn = torch.matmul(torch.softmax(scores + mask, dim=-1), values)
                else:
                    if self.probe is not None:
                        self.note("scores", torch.matmul(grouped, keys.transpose(-1, -2)) / head_dim ** 0.5)
                    attn = F.scaled_dot_product_attention(grouped, keys, values, attn_mask=mask)
                attn = attn.reshape(1, heads, q_len, head_dim).transpose(1, 2).reshape(1, q_len, heads * head_dim)
                x = x + self.o[i](attn)
                self.note("residual", x)
                h = self.rms_norm(x, self.post_norms[i])
                inner = F.silu(self.gate[i](h)) * self.up[i](h)
                self.note("mlp", inner)
                x = x + self.down[i](inner)
                self.note("residual", x)
            x = self.rms_norm(x[:, -1:, :], self.final_norm)
            return F.linear(x, self.embed.weight)

    module = QwenStateful()
    with torch.no_grad():
        def take(name):
            return weights.pop(name).to(torch.float32)

        module.embed.weight.copy_(take("model.embed_tokens.weight"))
        for i in range(layers):
            p = f"model.layers.{i}."
            module.input_norms[i].copy_(take(p + "input_layernorm.weight"))
            module.post_norms[i].copy_(take(p + "post_attention_layernorm.weight"))
            for name, target in (("q", module.q[i]), ("k", module.k[i]), ("v", module.v[i])):
                target.weight.copy_(take(p + f"self_attn.{name}_proj.weight"))
                target.bias.copy_(take(p + f"self_attn.{name}_proj.bias"))
            if q_fold:
                module.q[i].weight.mul_(1.0 / head_dim ** 0.5)
                module.q[i].bias.mul_(1.0 / head_dim ** 0.5)
            module.o[i].weight.copy_(take(p + "self_attn.o_proj.weight"))
            module.gate[i].weight.copy_(take(p + "mlp.gate_proj.weight"))
            module.up[i].weight.copy_(take(p + "mlp.up_proj.weight") * mlp_scale)
            module.down[i].weight.copy_(take(p + "mlp.down_proj.weight") / mlp_scale)
        module.final_norm.copy_(take("model.norm.weight"))
        lm_head = weights.pop("lm_head.weight", None)
        if lm_head is not None and not torch.equal(lm_head.to(torch.float32), module.embed.weight):
            raise SystemExit("untied lm_head is not supported by this export")
    assert not weights, f"unused weights: {sorted(weights)[:5]}"
    return module.eval()


def causal_mask(past: int, q_len: int) -> np.ndarray:
    """[1, 1, Q, P+Q]: row i attends to columns 0...P+i."""
    end = past + q_len
    mask = np.full((1, 1, q_len, end), -np.inf, dtype=np.float32)
    for i in range(q_len):
        mask[0, 0, i, :past + i + 1] = 0
    return mask


def run_sequence(step, prompt_ids, continuation, chunk=PREFILL_CHUNK):
    """The app's path: prefill the prompt in chunks, then teacher-force the continuation one token at a time.
    `step(ids, mask) -> logits[V]`. Returns logits for the prompt's last position and each continuation position
    but the last."""
    outputs = []
    past = 0
    logits = None
    for start in range(0, len(prompt_ids), chunk):
        ids = prompt_ids[start:start + chunk]
        logits = step(np.array([ids], dtype=np.int32), causal_mask(past, len(ids)))
        past += len(ids)
    outputs.append(logits)
    for token in continuation[:-1]:
        logits = step(np.array([[token]], dtype=np.int32), causal_mask(past, 1))
        past += 1
        outputs.append(logits)
    return np.stack(outputs)


def greedy_sequence(step, prompt_ids, count, eos, chunk=PREFILL_CHUNK):
    past = 0
    logits = None
    for start in range(0, len(prompt_ids), chunk):
        ids = prompt_ids[start:start + chunk]
        logits = step(np.array([ids], dtype=np.int32), causal_mask(past, len(ids)))
        past += len(ids)
    out = []
    for _ in range(count):
        token = int(np.argmax(logits))
        out.append(token)
        if token in eos:
            break
        logits = step(np.array([[token]], dtype=np.int32), causal_mask(past, 1))
        past += 1
    return out


def log_softmax(x: np.ndarray) -> np.ndarray:
    x = x.astype(np.float64)
    m = x.max(axis=-1, keepdims=True)
    return x - (np.log(np.exp(x - m).sum(axis=-1, keepdims=True)) + m)


def compare(reference: dict, logits: np.ndarray) -> dict:
    """Candidate logits [N, V] against the reference's argmax and top-k at the same N positions."""
    finite = bool(np.isfinite(logits).all())
    lp = log_softmax(logits)
    ref_top = np.array(reference["top_ids"])  # [N, K]
    ref_lp = np.array(reference["top_logprobs"])
    ref_arg = ref_top[:, 0]
    cand_arg = lp.argmax(-1)
    top5 = np.argsort(-lp, axis=-1)[:, :5]
    in_top5 = np.array([ref_arg[i] in top5[i] for i in range(len(ref_arg))])
    diff = np.abs(lp[np.arange(len(ref_arg)), ref_arg] - ref_lp[:, 0])
    return {"positions": int(len(ref_arg)), "finite": finite,
            "argmax_agreement": float((cand_arg == ref_arg).mean()),
            "reference_in_top5": float(in_top5.mean()),
            "mean_abs_logprob_diff": float(np.nan_to_num(diff, nan=99).mean()),
            "max_abs_logprob_diff": float(np.nan_to_num(diff, nan=99).max())}


def aggregate(results: list) -> dict:
    n = sum(r["positions"] for r in results)
    out = {"positions": n, "finite": all(r["finite"] for r in results)}
    for key in ("argmax_agreement", "reference_in_top5", "mean_abs_logprob_diff"):
        out[key] = sum(r[key] * r["positions"] for r in results) / max(n, 1)
    out["max_abs_logprob_diff"] = max(r["max_abs_logprob_diff"] for r in results)
    return out


def passes(summary: dict) -> bool:
    return (summary["finite"] and summary["argmax_agreement"] >= GATE["argmax_agreement"]
            and summary["reference_in_top5"] >= GATE["reference_in_top5"]
            and summary["mean_abs_logprob_diff"] <= GATE["mean_abs_logprob_diff"])


# MARK: - convert

def load_weights(model_dir: str) -> dict:
    from safetensors.torch import load_file

    weights = {}
    for name in sorted(os.listdir(model_dir)):
        if name.endswith(".safetensors"):
            weights.update(load_file(os.path.join(model_dir, name)))
    return weights


def reference(model_dir: str, tokenizer, prompts) -> list:
    """transformers fp32 (eager attention): greedy continuations and teacher-forced top-k log-probs."""
    import torch
    from transformers import AutoModelForCausalLM

    model = AutoModelForCausalLM.from_pretrained(model_dir, torch_dtype=torch.float32, attn_implementation="eager")
    model.eval()
    eos = [tokenizer.convert_tokens_to_ids("<|im_end|>"), tokenizer.convert_tokens_to_ids("<|endoftext|>")]
    out = []
    with torch.no_grad():
        for system, user in prompts:
            text = tokenizer.apply_chat_template([{"role": "system", "content": system}, {"role": "user", "content": user}],
                                                 tokenize=False, add_generation_prompt=True)
            prompt_ids = tokenizer(text, add_special_tokens=False)["input_ids"]
            generated = model.generate(torch.tensor([prompt_ids]), max_new_tokens=CONTINUATION, do_sample=False,
                                       eos_token_id=eos, pad_token_id=eos[1], repetition_penalty=1.0)
            continuation = generated[0, len(prompt_ids):].tolist()
            full = torch.tensor([prompt_ids + continuation])
            logits = model(full).logits[0].float().numpy()
            positions = logits[len(prompt_ids) - 1:len(prompt_ids) - 1 + len(continuation)]
            lp = log_softmax(positions)
            top = np.argsort(-lp, axis=-1)[:, :TOP_K]
            out.append({"system": system, "user": user, "prompt_ids": prompt_ids, "continuation": continuation,
                        "text": tokenizer.decode(continuation),
                        "top_ids": top.tolist(), "top_logprobs": np.take_along_axis(lp, top, -1).tolist()})
            log("reference:", repr(out[-1]["text"]))
    del model
    gc.collect()
    return out


def torch_step(module):
    import torch

    def step(ids, mask):
        with torch.no_grad():
            return module(torch.from_numpy(ids), torch.from_numpy(mask)).numpy()[0, 0]
    return step


def mixed_selector(op) -> bool:
    """fp16 everywhere except the RMSNorm statistics (pow, mean, the epsilon add, rsqrt) and other reductions."""
    keep = {"pow", "reduce_mean", "reduce_sum", "reduce_sum_square", "rsqrt", "sqrt", "real_div"}
    if op.op_type in keep:
        return False
    if op.op_type == "add":
        for value in op.inputs.values():
            producer = getattr(value, "op", None)
            if producer is not None and producer.op_type in {"reduce_mean", "reduce_sum"}:
                return False
    return True


def convert_variants(module, cfg: dict, context: int, out_dir: str, info: dict, variants, quantize=True,
                     quantizations=("int4-affine-block32",)) -> list:
    import coremltools as ct
    import torch

    module.keyCache.zero_()
    module.valueCache.zero_()
    example = (torch.randint(0, cfg["vocab_size"], (1, 3), dtype=torch.int32),
               torch.from_numpy(causal_mask(2, 3)))
    with torch.no_grad():
        traced = torch.jit.trace(module, example, check_trace=False)
    module.keyCache.zero_()
    module.valueCache.zero_()
    log("traced")
    query = ct.RangeDim(lower_bound=1, upper_bound=min(MAX_QUERY, context), default=1)
    end = ct.RangeDim(lower_bound=1, upper_bound=context, default=1)
    shape = tuple(module.keyCache.shape)
    inputs = [ct.TensorType(name="inputIds", shape=(1, query), dtype=np.int32),
              ct.TensorType(name="causalMask", shape=(1, 1, query, end), dtype=np.float16)]
    states = [ct.StateType(wrapped_type=ct.TensorType(shape=shape, dtype=np.float16), name="keyCache"),
              ct.StateType(wrapped_type=ct.TensorType(shape=shape, dtype=np.float16), name="valueCache")]
    outputs = [ct.TensorType(name="logits", dtype=np.float16)]
    produced = []
    for name in variants:
        started = time.time()
        precision = ct.precision.FLOAT16 if name == "fp16" else ct.transform.FP16ComputePrecision(op_selector=mixed_selector)
        converted = ct.convert(traced, inputs=inputs, states=states, outputs=outputs, convert_to="mlprogram",
                               compute_precision=precision, minimum_deployment_target=ct.target.iOS18,
                               skip_model_load=True)
        log(f"converted {name} in {time.time() - started:.0f} s")
        for quantization in (list(quantizations) if quantize else ["none"]):
            try:
                produced.append(save_variant(converted, name, quantization, cfg, context, out_dir, info, started))
            except Exception as error:  # noqa: BLE001 — one quantization failing must not lose the others
                log(f"FAILED {name} {quantization}: {error!r}")
            started = time.time()
        del converted
        gc.collect()
    del traced
    gc.collect()
    return produced


# Weight quantizations, in the order the parity gate prefers them (smallest first). Symmetric int4 per block of 32
# (Apple's Llama recipe) kept only 83-84 % of the reference's top tokens on Qwen2.5-1.5B (parity run 37712774773).
QUANTIZATIONS = {
    "int4-affine-block32": {"mode": "linear", "dtype": "int4", "granularity": "per_block", "block_size": 32},
    "int4-affine-block16": {"mode": "linear", "dtype": "int4", "granularity": "per_block", "block_size": 16},
    "int8-channel": {"mode": "linear_symmetric", "dtype": "int8", "granularity": "per_channel"},
}


def save_variant(converted, name: str, quantization: str, cfg: dict, context: int, out_dir: str, info: dict,
                 started: float) -> dict:
    import coremltools as ct

    mlmodel = converted
    if quantization != "none":
        op_config = ct.optimize.coreml.OpLinearQuantizerConfig(**QUANTIZATIONS[quantization])
        mlmodel = ct.optimize.coreml.linear_quantize_weights(
            converted, config=ct.optimize.coreml.OptimizationConfig(global_config=op_config))
        log(f"quantized {name} {quantization}")
    mlmodel.author = f"PixlAudio (converted from {info['id']}, Apache-2.0)"
    mlmodel.license = "Apache-2.0"
    mlmodel.short_description = f"{info['title']}, stateful KV cache, {context}-token context (PixlAudio local AI)"
    meta = {"pixl.model": info["id"], "pixl.revision": info["revision"], "pixl.context": str(context),
            "pixl.maxQuery": str(min(MAX_QUERY, context)), "pixl.vocab": str(cfg["vocab_size"]),
            "pixl.layers": str(cfg["num_hidden_layers"]), "pixl.kvHeads": str(cfg["num_key_value_heads"]),
            "pixl.headDim": str(cfg["hidden_size"] // cfg["num_attention_heads"]), "pixl.precision": name,
            "pixl.quantization": quantization, "pixl.tokenizer": TOKENIZER_FILE,
            "pixl.eos": json.dumps(info.get("eos", [])), "pixl.fp16Safety": json.dumps(CONVERT_OPTIONS)}
    for key, value in meta.items():
        mlmodel.user_defined_metadata[key] = value
    path = os.path.join(out_dir, f"{name}-{quantization}", info["package"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mlmodel.save(path)
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(path) for f in fs)
    log(f"saved {path} ({size / 1e9:.2f} GB)")
    if mlmodel is not converted:
        del mlmodel
        gc.collect()
    return {"variant": f"{name}-{quantization}", "precision": name, "quantization": quantization,
            "path": os.path.relpath(path, out_dir), "bytes": size, "convert_seconds": round(time.time() - started, 1)}


TINY_CONFIG = {"vocab_size": 256, "hidden_size": 64, "num_hidden_layers": 2, "num_attention_heads": 4,
               "num_key_value_heads": 2, "intermediate_size": 128, "rms_norm_eps": 1e-6, "rope_theta": 1000000.0}
TINY_CONTEXT = 64
TINY_PROMPT = [17, 42, 99, 3, 250, 7, 64, 128, 5, 33]
TINY_STEPS = 12


def tiny_weights(seed: int, embed_scale: float) -> dict:
    import torch

    cfg = TINY_CONFIG
    generator = torch.Generator().manual_seed(seed)
    h, i_size, kv = cfg["hidden_size"], cfg["intermediate_size"], cfg["num_key_value_heads"] * 16

    def rnd(*shape, scale=0.35):
        return torch.randn(*shape, generator=generator) * scale

    weights = {"model.embed_tokens.weight": rnd(cfg["vocab_size"], h, scale=embed_scale)}
    for layer in range(cfg["num_hidden_layers"]):
        p = f"model.layers.{layer}."
        weights[p + "input_layernorm.weight"] = 1 + rnd(h, scale=0.1)
        weights[p + "post_attention_layernorm.weight"] = 1 + rnd(h, scale=0.1)
        weights[p + "self_attn.q_proj.weight"] = rnd(h, h, scale=0.5)
        weights[p + "self_attn.q_proj.bias"] = rnd(h, scale=0.1)
        weights[p + "self_attn.k_proj.weight"] = rnd(kv, h, scale=0.5)
        weights[p + "self_attn.k_proj.bias"] = rnd(kv, scale=0.1)
        weights[p + "self_attn.v_proj.weight"] = rnd(kv, h, scale=0.5)
        weights[p + "self_attn.v_proj.bias"] = rnd(kv, scale=0.1)
        weights[p + "self_attn.o_proj.weight"] = rnd(h, h, scale=0.3)
        weights[p + "mlp.gate_proj.weight"] = rnd(i_size, h, scale=0.3)
        weights[p + "mlp.up_proj.weight"] = rnd(i_size, h, scale=0.3)
        weights[p + "mlp.down_proj.weight"] = rnd(h, i_size, scale=0.3)
    weights["model.norm.weight"] = 1 + rnd(h, scale=0.1)
    return weights


def tiny_model(out_dir: str, keep: int = 4) -> dict:
    """Tiny random Qwen2-shaped models (same export path, int4 like the real one) for the app's simulator smoke test.
    Seeds are ranked by how varied their greedy tokens are (a cache bug must change them) and by the smallest
    top-1/top-2 logit margin along the path (fp16 and int4 noise mustn't flip them); `parity` picks the final one by
    its Core ML margins."""
    scored = []
    for seed in range(120):
        for embed_scale in (0.5, 1.0):
            module = build_module(TINY_CONFIG, tiny_weights(seed, embed_scale), TINY_CONTEXT, CONVERT_OPTIONS)
            step = torch_step(module)
            tokens = greedy_sequence(step, TINY_PROMPT, TINY_STEPS, eos=[])
            module.keyCache.zero_()
            module.valueCache.zero_()
            rows = run_sequence(step, TINY_PROMPT, tokens + [0], chunk=4)
            margins = [float(np.sort(row)[-1] - np.sort(row)[-2]) for row in rows[:TINY_STEPS]]
            scored.append({"seed": seed, "embed_scale": embed_scale, "tokens": tokens, "distinct": len(set(tokens)),
                           "min_margin": min(margins)})
    scored.sort(key=lambda c: (min(c["distinct"], 8), c["min_margin"]), reverse=True)
    candidates = []
    for c in scored[:keep]:
        info = {"id": "pixl/tiny-random-qwen2", "revision": f"seed-{c['seed']}-embed-{c['embed_scale']}",
                "package": "TinyQwen.mlpackage", "title": "Tiny random Qwen2 (tests only)", "eos": []}
        module = build_module(TINY_CONFIG, tiny_weights(c["seed"], c["embed_scale"]), TINY_CONTEXT, CONVERT_OPTIONS)
        produced = convert_variants(module, TINY_CONFIG, TINY_CONTEXT,
                                    os.path.join(out_dir, "tiny", f"seed{c['seed']}-{c['embed_scale']}"), info, ["fp16"])
        c["path"] = os.path.join(f"seed{c['seed']}-{c['embed_scale']}", produced[0]["path"])
        candidates.append(c)
        log(f"tiny candidate: seed {c['seed']} x{c['embed_scale']}, distinct {c['distinct']}, "
            f"min margin {c['min_margin']:.2f}, tokens {c['tokens']}")
    return {"config": TINY_CONFIG, "context": TINY_CONTEXT, "prompt": TINY_PROMPT, "steps": TINY_STEPS,
            "candidates": candidates}


def cmd_convert(args) -> int:
    import torch
    from huggingface_hub import snapshot_download
    from transformers import AutoTokenizer

    torch.set_num_threads(int(os.environ.get("PIXL_THREADS", os.cpu_count() or 1)))
    info = dict(MODELS[args.model])
    os.makedirs(args.out, exist_ok=True)
    report = {"model": info["id"], "revision": info["revision"], "context": args.context, "gate": GATE,
              "steps": {}, "passed": False}

    def save():
        report["peak_rss_gb"] = peak_rss_gb()
        write_json(os.path.join(args.out, "llm-convert-report.json"), report)

    model_dir = args.model_dir or snapshot_download(info["id"], revision=info["revision"],
                                                    allow_patterns=["*.json", "*.safetensors", "merges.txt", "LICENSE"])
    with open(os.path.join(model_dir, "config.json")) as f:
        cfg = json.load(f)
    assert cfg["model_type"] == "qwen2" and cfg.get("tie_word_embeddings"), cfg
    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    info["eos"] = [tokenizer.convert_tokens_to_ids("<|im_end|>"), tokenizer.convert_tokens_to_ids("<|endoftext|>")]
    report["config"] = {k: cfg[k] for k in ("hidden_size", "num_hidden_layers", "num_attention_heads",
                                            "num_key_value_heads", "intermediate_size", "vocab_size", "rope_theta")}

    # Tokenizer file + fixtures.
    tokenizer_json = os.path.join(model_dir, "tokenizer.json")
    report["tokenizer"] = export_tokenizer(tokenizer_json, os.path.join(args.out, TOKENIZER_FILE), cfg["vocab_size"])
    tokenizer_fixtures(tokenizer_json, os.path.join(args.out, "tokenizer-cases.json"), tokenizer)
    save()

    # Tiny smoke-test model first (cheap; independent of the big model).
    if not args.skip_tiny:
        report["tiny"] = tiny_model(args.out)
        save()

    # Reference.
    reference_path = os.path.join(args.out, "llm-reference.json")
    if args.reuse_reference and os.path.exists(reference_path):
        with open(reference_path) as f:
            refs = json.load(f)["prompts"]
    else:
        refs = reference(model_dir, tokenizer, PROMPTS)
    write_json(os.path.join(args.out, "llm-reference.json"), {"model": info["id"], "revision": info["revision"],
                                                               "eos": info["eos"], "prompts": refs})
    report["reference"] = [{"text": r["text"], "prompt_tokens": len(r["prompt_ids"])} for r in refs]
    save()

    # Our module through the app's path vs the reference.
    weights = load_weights(model_dir)
    module = build_module(cfg, weights, args.context, CONVERT_OPTIONS)
    del weights
    gc.collect()
    step = torch_step(module)
    results = []
    greedy_match = []
    for r in refs:
        module.keyCache.zero_()
        module.valueCache.zero_()
        logits = run_sequence(step, r["prompt_ids"], r["continuation"])
        results.append(compare(r, logits))
        module.keyCache.zero_()
        module.valueCache.zero_()
        tokens = greedy_sequence(step, r["prompt_ids"], len(r["continuation"]), info["eos"])
        greedy_match.append(tokens == r["continuation"])
    summary = aggregate(results)
    summary["greedy_identical"] = greedy_match
    report["steps"]["torch_module"] = summary
    log("torch module vs reference:", json.dumps(summary))
    save()
    # fp32 against fp32: only a near-tie may flip (SDPA and eager attention sum in different orders).
    if summary["argmax_agreement"] < 0.99 or summary["mean_abs_logprob_diff"] > 0.01 or not summary["finite"]:
        log("FAILED: the PyTorch module disagrees with transformers")
        return 1

    variants = [v for v in args.variants.split(",") if v]
    report["candidates"] = convert_variants(module, cfg, args.context, args.out, info, variants,
                                            quantize=not args.no_quantize,
                                            quantizations=[q for q in args.quantizations.split(",") if q])
    report["passed"] = True
    save()

    # Informational: the same module in float16 (torch, CPU) on the first two prompts, as a first sign of how Core ML's
    # float16 will do (the parity gate on macOS decides).
    started = time.time()
    module = module.half()

    def half_step(ids, mask):
        with torch.no_grad():
            return module(torch.from_numpy(ids), torch.from_numpy(mask.astype(np.float16))).float().numpy()[0, 0]

    half = []
    for r in refs[:2]:
        module.keyCache.zero_()
        module.valueCache.zero_()
        half.append(compare(r, run_sequence(half_step, r["prompt_ids"], r["continuation"])))
    report["steps"]["torch_fp16"] = dict(aggregate(half), seconds=round(time.time() - started, 1))
    log("torch fp16 vs reference:", json.dumps(report["steps"]["torch_fp16"]))
    save()
    log("done")
    return 0


# MARK: - probe (Linux): where float16 overflows

PROBE_CONFIGS = [
    ("fp16", {}),
    ("fp16+norm32", {"norm_fp32": True}),
    ("fp16+convert-options", CONVERT_OPTIONS),
]


def cmd_probe(args) -> int:
    """The fp32 module's largest values per kind (anything over 65504 overflows float16), then the module run in
    float16 (CPU, torch) with each fp16-safety option set, against the fp32 module's own greedy continuations."""
    import torch
    from huggingface_hub import snapshot_download
    from transformers import AutoTokenizer

    torch.set_num_threads(int(os.environ.get("PIXL_THREADS", os.cpu_count() or 1)))
    info = MODELS[args.model]
    os.makedirs(args.out, exist_ok=True)
    model_dir = args.model_dir or snapshot_download(info["id"], revision=info["revision"],
                                                    allow_patterns=["*.json", "*.safetensors", "merges.txt"])
    with open(os.path.join(model_dir, "config.json")) as f:
        cfg = json.load(f)
    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    eos = [tokenizer.convert_tokens_to_ids("<|im_end|>"), tokenizer.convert_tokens_to_ids("<|endoftext|>")]
    prompts = []
    for system, user in PROMPTS[: args.prompts]:
        text = tokenizer.apply_chat_template([{"role": "system", "content": system}, {"role": "user", "content": user}],
                                             tokenize=False, add_generation_prompt=True)
        prompts.append(tokenizer(text, add_special_tokens=False)["input_ids"])
    base = load_weights(model_dir)
    report = {"model": info["id"], "configs": {}}

    def save():
        write_json(os.path.join(args.out, "llm-probe.json"), report)

    # fp32: the largest values, and the continuations the others are compared on.
    probe = {}
    module = build_module(cfg, dict(base), args.context)
    module.probe = probe
    step = torch_step(module)
    refs = []
    for ids in prompts:
        module.keyCache.zero_()
        module.valueCache.zero_()
        continuation = greedy_sequence(step, ids, CONTINUATION, eos)
        module.keyCache.zero_()
        module.valueCache.zero_()
        logits = run_sequence(step, ids, continuation)
        refs.append({"ids": ids, "continuation": continuation, "argmax": logits.argmax(-1).tolist()})
    report["fp32_max"] = probe
    report["continuations"] = [tokenizer.decode(r["continuation"]) for r in refs]
    log("fp32 maxima:", json.dumps(probe))
    save()
    del module
    gc.collect()

    for name, options in PROBE_CONFIGS:
        started = time.time()
        probe = {}
        module = build_module(cfg, dict(base), args.context, options).half()
        module.probe = probe

        def half_step(ids, mask, module=module):
            with torch.no_grad():
                out = module(torch.from_numpy(ids), torch.from_numpy(mask.astype(np.float16)))
                return out.float().numpy()[0, 0]

        agree, total, finite = 0, 0, True
        for r in refs:
            module.keyCache.zero_()
            module.valueCache.zero_()
            logits = run_sequence(half_step, r["ids"], r["continuation"])
            finite = finite and bool(np.isfinite(logits).all())
            agree += int((logits.argmax(-1) == np.array(r["argmax"])).sum())
            total += len(r["argmax"])
        result = {"options": options, "finite": finite, "argmax_agreement": agree / max(total, 1), "positions": total,
                  "max": probe, "seconds": round(time.time() - started, 1)}
        report["configs"][name] = result
        log(name, json.dumps(result))
        save()
        del module
        gc.collect()
    return 0


def cmd_tokenizer(args) -> int:
    from huggingface_hub import hf_hub_download

    info = MODELS[args.model]
    path = hf_hub_download(info["id"], "tokenizer.json", revision=info["revision"])
    cfg_path = hf_hub_download(info["id"], "config.json", revision=info["revision"])
    with open(cfg_path) as f:
        vocab_rows = json.load(f)["vocab_size"]
    os.makedirs(args.out, exist_ok=True)
    print(json.dumps(export_tokenizer(path, os.path.join(args.out, TOKENIZER_FILE), vocab_rows), indent=2))
    chat = None
    try:
        from transformers import AutoTokenizer

        chat = AutoTokenizer.from_pretrained(info["id"], revision=info["revision"])
    except Exception as error:  # noqa: BLE001 — fixtures without the chat case
        print("no chat template case:", error)
    tokenizer_fixtures(path, os.path.join(args.out, "tokenizer-cases.json"), chat)
    return 0


# MARK: - parity (macOS)

def coreml_step(mlmodel, state):
    def step(ids, mask):
        out = mlmodel.predict({"inputIds": ids.astype(np.int32), "causalMask": mask.astype(np.float16)}, state=state)
        return np.asarray(out["logits"], dtype=np.float32).reshape(-1)
    return step


def tar_files(entries, tar_path: str) -> dict:
    """An uncompressed ustar tar of (path on disk, name in the archive) entries, directories walked, deterministic."""
    def scrub(info):
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        info.mode = 0o755 if info.isdir() else 0o644
        return info

    with tarfile.open(tar_path, "w", format=tarfile.USTAR_FORMAT) as tar:
        for path, arcname in entries:
            if os.path.isdir(path):
                for root, dirs, files in os.walk(path):
                    dirs.sort()
                    for name in sorted(files):
                        if name.startswith("._") or name == ".DS_Store":
                            continue
                        full = os.path.join(root, name)
                        inner = os.path.join(arcname, os.path.relpath(full, path)).replace(os.sep, "/")
                        if len(inner.encode()) > 255:
                            raise ValueError(f"path too long for ustar: {inner}")
                        tar.add(full, arcname=inner, recursive=False, filter=scrub)
            else:
                tar.add(path, arcname=arcname, recursive=False, filter=scrub)
    return {"file": os.path.basename(tar_path), "bytes": os.path.getsize(tar_path), "sha256": sha256_of(tar_path)}


def cmd_parity(args) -> int:
    import coremltools as ct

    info = MODELS[args.model]
    with open(os.path.join(args.candidates, "llm-convert-report.json")) as f:
        convert_report = json.load(f)
    with open(os.path.join(args.candidates, "llm-reference.json")) as f:
        reference_data = json.load(f)
    refs = reference_data["prompts"]
    eos = reference_data["eos"]
    os.makedirs(args.out, exist_ok=True)
    report = {"model": info["id"], "revision": info["revision"], "gate": GATE, "coremltools": ct.__version__,
              "convert": {k: convert_report.get(k) for k in ("steps", "peak_rss_gb", "tokenizer", "candidates")},
              "attempts": [], "passed": False}
    tokenizer_path = os.path.join(args.candidates, TOKENIZER_FILE)
    if args.expect_tokenizer_sha and sha256_of(tokenizer_path) != args.expect_tokenizer_sha:
        print("The tokenizer differs from the one PixlCore's fixtures were made from:", sha256_of(tokenizer_path))
        write_json(os.path.join(args.out, "llm-report.json"), report)
        return 1

    # The tiny model: what the simulator smoke test must reproduce (Core ML CPU tokens, the clearest candidate).
    tiny = convert_report.get("tiny")
    if tiny:
        chosen = None
        report["tiny"] = []
        for candidate in tiny["candidates"]:
            path = os.path.join(args.candidates, "tiny", candidate["path"])
            result = {"seed": candidate["seed"], "embed_scale": candidate["embed_scale"],
                      "torch_greedy": candidate["tokens"], "units": {}}
            for unit_name, unit in [("CPU_ONLY", ct.ComputeUnit.CPU_ONLY), ("ALL", ct.ComputeUnit.ALL)]:
                mlmodel = ct.models.MLModel(path, compute_units=unit)
                step = coreml_step(mlmodel, mlmodel.make_state())
                tokens = greedy_sequence(step, tiny["prompt"], tiny["steps"], eos=[], chunk=4)
                rows = run_sequence(coreml_step(mlmodel, mlmodel.make_state()), tiny["prompt"], tokens + [0], chunk=4)
                margins = [float(np.sort(row)[-1] - np.sort(row)[-2]) for row in rows[:tiny["steps"]]]
                result["units"][unit_name] = {"tokens": tokens, "min_margin": min(margins)}
            cpu = result["units"]["CPU_ONLY"]
            result["usable"] = (cpu["tokens"] == result["units"]["ALL"]["tokens"] and len(set(cpu["tokens"])) >= 4
                                and cpu["min_margin"] >= 0.25)
            report["tiny"].append(result)
            print("tiny:", json.dumps(result), flush=True)
            if result["usable"] and (chosen is None or cpu["min_margin"] > chosen[1]["units"]["CPU_ONLY"]["min_margin"]):
                chosen = (path, result)
        if chosen:
            path, result = chosen
            tar = tar_files([(path, os.path.basename(path))], os.path.join(args.out, "tiny_qwen.mlpackage.tar"))
            write_json(os.path.join(args.out, "tiny-expected.json"),
                       {"package": os.path.basename(path), "context": tiny["context"], "prompt": tiny["prompt"],
                        "greedy": result["units"]["CPU_ONLY"]["tokens"],
                        "minMargin": result["units"]["CPU_ONLY"]["min_margin"], "seed": result["seed"],
                        "embedScale": result["embed_scale"], "tar": tar})

    shipped = None
    for candidate in convert_report.get("candidates", []):
        path = os.path.join(args.candidates, candidate["path"])
        attempt = {"variant": candidate["variant"], "bytes": candidate["bytes"], "units": {}}
        ok = True
        for unit_name, unit in [("CPU_ONLY", ct.ComputeUnit.CPU_ONLY), ("ALL", ct.ComputeUnit.ALL)]:
            started = time.time()
            mlmodel = ct.models.MLModel(path, compute_units=unit)
            load_seconds = time.time() - started
            results, greedy, timings = [], [], []
            for r in refs:
                state = mlmodel.make_state()
                t0 = time.time()
                logits = run_sequence(coreml_step(mlmodel, state), r["prompt_ids"], r["continuation"])
                timings.append((time.time() - t0) / max(1, len(r["continuation"])))
                results.append(compare(r, logits))
                state = mlmodel.make_state()
                tokens = greedy_sequence(coreml_step(mlmodel, state), r["prompt_ids"], len(r["continuation"]), eos)
                same = 0
                for a, b in zip(tokens, r["continuation"]):
                    if a != b:
                        break
                    same += 1
                greedy.append(same)
            summary = aggregate(results)
            summary["per_prompt"] = results
            summary["greedy_prefix_tokens"] = greedy
            summary["load_seconds"] = round(load_seconds, 1)
            summary["seconds_per_token_with_prefill"] = round(float(np.mean(timings)), 3)
            summary["passed"] = passes(summary)
            attempt["units"][unit_name] = summary
            ok = ok and summary["passed"]
            print(candidate["variant"], unit_name, json.dumps({k: v for k, v in summary.items() if k != "per_prompt"}),
                  flush=True)
            del mlmodel
            gc.collect()
        attempt["passed"] = ok
        report["attempts"].append(attempt)
        if ok and shipped is None and candidate["quantization"] != "none":
            shipped = (candidate, path, attempt)
        write_json(os.path.join(args.out, "llm-report.json"), report)
        if shipped is not None:
            break  # candidates come smallest first: the first that passes ships

    if shipped is None:
        print("Parity gate FAILED for every candidate")
        write_json(os.path.join(args.out, "llm-report.json"), report)
        return 1
    candidate, path, attempt = shipped
    # The manifest reads the last attempt as the shipped one's parity.
    report["attempts"] = [a for a in report["attempts"] if a is not attempt] + [attempt]
    # The release asset is named after the quantization that passed (assets are never replaced).
    asset_name = f"{info['asset']}_{candidate['quantization'].replace('-', '_')}.tar"
    asset = tar_files([(path, info["package"]), (tokenizer_path, TOKENIZER_FILE)], os.path.join(args.out, asset_name))
    asset.update({"id": "llm", "package": info["package"], "tokenizer": TOKENIZER_FILE, "variant": candidate["variant"],
                  "model": info["id"], "revision": info["revision"],
                  "tokenizerSha256": sha256_of(tokenizer_path)})
    report["asset"] = asset
    report["passed"] = True
    write_json(os.path.join(args.out, "llm-report.json"), report)
    print(json.dumps(asset, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    convert = sub.add_parser("convert")
    convert.add_argument("--model", choices=sorted(MODELS), default="qwen2.5-1.5b")
    convert.add_argument("--model-dir")
    convert.add_argument("--context", type=int, default=CONTEXT)
    convert.add_argument("--variants", default="fp16")
    convert.add_argument("--quantizations", default=",".join(QUANTIZATIONS))
    convert.add_argument("--no-quantize", action="store_true")
    convert.add_argument("--skip-tiny", action="store_true")
    convert.add_argument("--reuse-reference", action="store_true", help="local iteration: keep out/llm-reference.json")
    convert.add_argument("--out", default="out")
    parity = sub.add_parser("parity")
    parity.add_argument("--model", choices=sorted(MODELS), default="qwen2.5-1.5b")
    parity.add_argument("--candidates", default="candidates")
    parity.add_argument("--expect-tokenizer-sha")
    parity.add_argument("--out", default="out")
    probe = sub.add_parser("probe")
    probe.add_argument("--model", choices=sorted(MODELS), default="qwen2.5-1.5b")
    probe.add_argument("--model-dir")
    probe.add_argument("--context", type=int, default=CONTEXT)
    probe.add_argument("--prompts", type=int, default=2)
    probe.add_argument("--out", default="out")
    tok = sub.add_parser("tokenizer")
    tok.add_argument("--model", choices=sorted(MODELS), default="qwen2.5-1.5b")
    tok.add_argument("--out", default="out")
    args = parser.parse_args()
    return {"convert": cmd_convert, "parity": cmd_parity, "probe": cmd_probe, "tokenizer": cmd_tokenizer}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
