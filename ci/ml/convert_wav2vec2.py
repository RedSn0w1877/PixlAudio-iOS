"""Converts facebook/wav2vec2-base-960h (the model behind Android's assets/tais/wav2vec2_base_960h_fp32.onnx) to a
Core ML ML Program with a fixed 10 s input, checks it numerically against PyTorch, and packages it for the app.

Contract (mirrors Android `TaisWav2Vec2Aligner`): input `input_values` float32 [1, 160000] = 10 s of 16 kHz mono
audio, zero-mean / unit-variance normalised per window by the caller; output `logits` float32 [1, 499, 32]
(50 frames/s, 20 ms per frame, the 32-token character vocabulary; log-softmax is applied by the caller).

Parity gate (on the runner's CPU and on `ALL` compute units): a macOS `say` speech fixture and a noise window run
through PyTorch (fp32) and Core ML. Pass = frame argmax agreement >= 97 %, identical greedy transcripts, and the CTC
forced alignment of the known text giving word starts within 2 frames (40 ms) of PyTorch's. fp16 is tried first;
if it fails, the reductions/normalisations are kept in fp32 ("mixed"); the report records what shipped.

Usage: python convert_wav2vec2.py --out out/
"""

import argparse
import json
import os
import sys
import time

import numpy as np
import torch

sys.path.insert(0, os.path.dirname(__file__))
from common import read_float_wav, say_to_wav, tar_mlpackage, write_json  # noqa: E402

MODEL_ID = "facebook/wav2vec2-base-960h"
SAMPLE_RATE = 16000
INPUT_SAMPLES = 10 * SAMPLE_RATE
STRIDE, RECEPTIVE = 320, 400
FRAMES = (INPUT_SAMPLES - RECEPTIVE) // STRIDE + 1  # 499
# Android assets/tais/wav2vec2_vocab.json (the model's tokenizer vocabulary), checked against the tokenizer below.
VOCAB = {"<pad>": 0, "<s>": 1, "</s>": 2, "<unk>": 3, "|": 4, "E": 5, "T": 6, "A": 7, "O": 8, "N": 9, "I": 10,
         "H": 11, "S": 12, "R": 13, "D": 14, "L": 15, "U": 16, "M": 17, "W": 18, "C": 19, "F": 20, "G": 21, "Y": 22,
         "P": 23, "B": 24, "V": 25, "K": 26, "'": 27, "X": 28, "J": 29, "Q": 30, "Z": 31}
SPEECH_TEXT = ("the quick brown fox jumps over the lazy dog while seven singers carry the melody "
               "across a quiet river at night")


class LogitsOnly(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_values):
        return self.model(input_values=input_values, return_dict=False)[0]


def bake_weight_norm(model) -> int:
    """The positional conv uses weight norm; bake it into a plain weight so the trace has no `_weight_norm` op."""
    from torch.nn.utils import parametrize

    baked = 0
    for module in model.modules():
        if parametrize.is_parametrized(module, "weight"):
            parametrize.remove_parametrizations(module, "weight", leave_parametrized=True)
            baked += 1
        elif hasattr(module, "weight_g") and hasattr(module, "weight_v"):
            torch.nn.utils.remove_weight_norm(module)
            baked += 1
    return baked


def normalise(x: np.ndarray) -> np.ndarray:
    """Android `normalize`: (x - mean) / sqrt(var + 1e-7), in float64 then float32."""
    x64 = x.astype(np.float64)
    mean = x64.mean()
    std = np.sqrt(((x64 - mean) ** 2).mean() + 1e-7)
    return ((x64 - mean) / std).astype(np.float32)


def log_softmax(logits: np.ndarray) -> np.ndarray:
    m = logits.max(axis=-1, keepdims=True)
    return logits - (np.log(np.exp(logits - m).sum(axis=-1, keepdims=True)) + m)


def greedy(logits: np.ndarray) -> str:
    inverse = {v: k for k, v in VOCAB.items()}
    ids = logits.argmax(axis=-1)
    out, last = [], -1
    for i in ids:
        if i != last and i != 0:
            out.append(inverse[int(i)])
        last = i
    return "".join(" " if c == "|" else c for c in out if len(c) == 1).strip()


def extended_target(words):
    symbols, ranges = [], []
    for word in words:
        chars = [c for c in word.upper() if c == "'" or "A" <= c <= "Z"]
        if not chars:
            ranges.append(None)
            continue
        if symbols:
            symbols.append(VOCAB["|"])
        start = len(symbols)
        symbols.extend(VOCAB[c] for c in chars)
        ranges.append((2 * start + 1, 2 * (len(symbols) - 1) + 1))
    ext = [0] * (2 * len(symbols) + 1)
    for i, s in enumerate(symbols):
        ext[2 * i + 1] = s
    return ext, ranges


def ctc_align(lp: np.ndarray, ext, blank: int = 0):
    """Same Viterbi as PixlAudioCore `CtcAlignmentCore.align` (torchaudio forced_align construction)."""
    frames, states = lp.shape[0], len(ext)
    ext_arr = np.array(ext)
    prev = np.full(states, -np.inf)
    prev[0] = lp[0, ext_arr[0]]
    if states > 1:
        prev[1] = lp[0, ext_arr[1]]
    skip_ok = np.zeros(states, dtype=bool)
    skip_ok[2:] = (ext_arr[2:] != blank) & (ext_arr[2:] != ext_arr[:-2])
    back = np.zeros((frames, states), dtype=np.int8)
    for t in range(1, frames):
        step = np.concatenate([[-np.inf], prev[:-1]])
        skip = np.where(skip_ok, np.concatenate([[-np.inf, -np.inf], prev[:-2]]), -np.inf)
        best = prev.copy()
        move = np.zeros(states, dtype=np.int8)
        m1 = step > best
        best[m1] = step[m1]
        move[m1] = 1
        m2 = skip > best
        best[m2] = skip[m2]
        move[m2] = 2
        prev = best + lp[t, ext_arr]
        back[t] = move
    s = states - 1 if states == 1 or prev[states - 1] >= prev[states - 2] else states - 2
    if not np.isfinite(prev[s]):
        return None
    path = [0] * frames
    path[-1] = s
    for t in range(frames - 1, 0, -1):
        s -= int(back[t, s])
        path[t - 1] = s
    return path


def word_starts(lp: np.ndarray, words):
    ext, ranges = extended_target(words)
    path = ctc_align(lp, ext)
    if path is None:
        return None
    first = {}
    for t, s in enumerate(path):
        if ext[s] != 0 and s not in first:
            first[s] = t
    starts = []
    for r in ranges:
        if r is None:
            starts.append(None)
            continue
        frames = [first[s] for s in range(r[0], r[1] + 1, 2) if s in first]
        starts.append(min(frames) if frames else None)
    return starts


def compare(reference: np.ndarray, candidate: np.ndarray, words=None) -> dict:
    ref_lp, cand_lp = log_softmax(reference), log_softmax(candidate)
    agreement = float((reference.argmax(-1) == candidate.argmax(-1)).mean())
    result = {
        "max_abs_logit_diff": float(np.abs(reference - candidate).max()),
        "mean_abs_logit_diff": float(np.abs(reference - candidate).mean()),
        "max_abs_logprob_diff": float(np.abs(ref_lp - cand_lp).max()),
        "argmax_agreement": agreement,
        "finite": bool(np.isfinite(candidate).all()),
    }
    if words is not None:
        result["transcript_reference"] = greedy(reference)
        result["transcript_candidate"] = greedy(candidate)
        a, b = word_starts(ref_lp, words), word_starts(cand_lp, words)
        if a is None or b is None:
            result["max_word_start_diff_frames"] = None
        else:
            diffs = [abs(x - y) for x, y in zip(a, b) if x is not None and y is not None]
            result["max_word_start_diff_frames"] = max(diffs) if diffs else None
            result["word_starts_ms"] = [None if x is None else x * 20 for x in b]
    return result


def passes(speech: dict, noise: dict) -> bool:
    return (speech["finite"] and noise["finite"]
            and speech["argmax_agreement"] >= 0.97
            and speech["transcript_reference"] == speech["transcript_candidate"]
            and speech["max_word_start_diff_frames"] is not None
            and speech["max_word_start_diff_frames"] <= 2
            and noise["argmax_agreement"] >= 0.90)


def main() -> int:
    import coremltools as ct
    from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor

    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="out")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    report = {"model": MODEL_ID, "input_samples": INPUT_SAMPLES, "frames": FRAMES, "coremltools": ct.__version__,
              "torch": torch.__version__, "attempts": []}

    processor = Wav2Vec2Processor.from_pretrained(MODEL_ID)
    tokenizer_vocab = processor.tokenizer.get_vocab()
    mismatched = {k: v for k, v in VOCAB.items() if tokenizer_vocab.get(k) != v}
    if mismatched or len(tokenizer_vocab) != len(VOCAB):
        print("Vocabulary differs from Android's wav2vec2_vocab.json:", tokenizer_vocab)
        return 1

    try:
        model = Wav2Vec2ForCTC.from_pretrained(MODEL_ID, attn_implementation="eager")
    except TypeError:
        model = Wav2Vec2ForCTC.from_pretrained(MODEL_ID)
    model.eval()
    report["weight_norm_baked"] = bake_weight_norm(model)
    wrapper = LogitsOnly(model).eval()

    # Fixtures: TTS speech padded to 10 s, and a noise window.
    wav = os.path.join(args.out, "speech.wav")
    say_to_wav(SPEECH_TEXT, wav)
    speech, rate = read_float_wav(wav)
    assert rate == SAMPLE_RATE, rate
    speech = speech[:INPUT_SAMPLES]
    report["speech_seconds"] = len(speech) / SAMPLE_RATE
    speech = np.pad(speech, (0, INPUT_SAMPLES - len(speech)))
    rng = np.random.default_rng(1234)
    noise = (rng.standard_normal(INPUT_SAMPLES) * 0.1).astype(np.float32)
    speech_in, noise_in = normalise(speech)[None, :], normalise(noise)[None, :]
    words = SPEECH_TEXT.split()

    with torch.no_grad():
        example = torch.from_numpy(speech_in)
        ref_speech = wrapper(example).numpy()[0]
        ref_noise = wrapper(torch.from_numpy(noise_in)).numpy()[0]
        traced = torch.jit.trace(wrapper, example, check_trace=False)
    assert ref_speech.shape == (FRAMES, len(VOCAB)), ref_speech.shape
    report["pytorch_transcript"] = greedy(ref_speech)
    print("PyTorch transcript:", report["pytorch_transcript"])

    def reductions_in_fp32(op):
        return op.op_type not in {"reduce_mean", "reduce_sum", "reduce_sum_square", "reduce_l2_norm", "instance_norm",
                                  "layer_norm", "batch_norm", "rsqrt", "sqrt", "pow", "real_div"}

    precisions = [("fp16", ct.precision.FLOAT16),
                  ("mixed", ct.transform.FP16ComputePrecision(op_selector=reductions_in_fp32))]
    shipped = None
    for name, precision in precisions:
        started = time.time()
        mlmodel = ct.convert(
            traced,
            source="pytorch",
            inputs=[ct.TensorType(name="input_values", shape=(1, INPUT_SAMPLES), dtype=np.float32)],
            outputs=[ct.TensorType(name="logits", dtype=np.float32)],
            convert_to="mlprogram",
            compute_precision=precision,
            minimum_deployment_target=ct.target.iOS17,
        )
        mlmodel.author = "PixlAudio (converted from facebook/wav2vec2-base-960h, Apache-2.0)"
        mlmodel.short_description = "wav2vec2-base-960h CTC acoustic model, 10 s windows at 16 kHz (TAIS lyric sync)"
        mlmodel.user_defined_metadata["pixl.inputSamples"] = str(INPUT_SAMPLES)
        mlmodel.user_defined_metadata["pixl.frames"] = str(FRAMES)
        mlmodel.user_defined_metadata["pixl.strideSamples"] = str(STRIDE)
        mlmodel.user_defined_metadata["pixl.vocab"] = json.dumps(VOCAB, sort_keys=True)
        mlmodel.user_defined_metadata["pixl.precision"] = name
        package = os.path.join(args.out, "Wav2Vec2Base960h.mlpackage")
        if os.path.exists(package):
            import shutil
            shutil.rmtree(package)
        mlmodel.save(package)
        attempt = {"precision": name, "convert_seconds": round(time.time() - started, 1), "units": {}}
        ok = True
        for unit_name, unit in [("CPU_ONLY", ct.ComputeUnit.CPU_ONLY), ("ALL", ct.ComputeUnit.ALL)]:
            loaded = ct.models.MLModel(package, compute_units=unit)
            t0 = time.time()
            out_speech = loaded.predict({"input_values": speech_in})["logits"][0]
            latency = time.time() - t0
            out_noise = loaded.predict({"input_values": noise_in})["logits"][0]
            s, n = compare(ref_speech, out_speech, words), compare(ref_noise, out_noise)
            unit_ok = passes(s, n)
            attempt["units"][unit_name] = {"speech": s, "noise": n, "latency_seconds": round(latency, 3),
                                           "passed": unit_ok}
            print(name, unit_name, json.dumps(attempt["units"][unit_name], indent=1))
            ok = ok and unit_ok
        attempt["passed"] = ok
        report["attempts"].append(attempt)
        if ok:
            shipped = (name, package)
            break

    if shipped is None:
        report["passed"] = False
        write_json(os.path.join(args.out, "wav2vec2-report.json"), report)
        print("Parity gate FAILED for every precision")
        return 1
    report["passed"] = True
    report["precision"] = shipped[0]
    asset = tar_mlpackage(shipped[1], os.path.join(args.out, "wav2vec2_base_960h.mlpackage.tar"))
    asset.update({"id": "wav2vec2", "precision": shipped[0], "input": "input_values", "output": "logits",
                  "inputSamples": INPUT_SAMPLES, "frames": FRAMES})
    report["asset"] = asset
    write_json(os.path.join(args.out, "wav2vec2-report.json"), report)
    print(json.dumps(asset, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
