"""ATTEMPT: converts the MDX-Net vocal model behind Android's assets/tais/stem_separation.tflite (UVR-MDX-NET-Voc_FT)
to a Core ML ML Program and gates it against ONNX Runtime.

coremltools has no ONNX frontend any more, so the public ONNX graph goes ONNX -> PyTorch (onnx2torch) -> TorchScript
trace -> Core ML. Contract (Android `TaisStemSeparator`): input float32 [1, 4, 3072, 256] = the STFT of 44.1 kHz stereo
(6144-point periodic Hann, hop 1024, reflect padding, Nyquist dropped) as planes [L-re, L-im, R-re, R-im]; output the
predicted vocal spectrum in the same layout.

Parity gate: a speech + chord fixture's STFT through ONNX Runtime (fp32 reference) and Core ML on CPU_ONLY and ALL.
Pass = relative L2 error <= 3 % and the Android stereo-linked instrumental mask within 0.02 (mean abs) of the
reference. fp16 first, fp32 as the fallback. Any failure (conversion or parity) exits non-zero with the reason in
mdx-report.json; the app then keeps its fallbacks (cloud separation, the mid/side tap).

Usage: python convert_mdx.py --out out/
"""

import argparse
import json
import os
import sys
import time
import traceback
import urllib.request

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from common import read_float_wav, say_to_wav, sha256_of, tar_mlpackage, write_json  # noqa: E402

ONNX_URL = "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/UVR-MDX-NET-Voc_FT.onnx"
SAMPLE_RATE = 44100
FFT_SIZE, HOP, BINS, FRAMES = 6144, 1024, 3072, 256


def stft_planes(left: np.ndarray, right: np.ndarray) -> np.ndarray:
    """Android `writeChunkStft` for the first 256 frames: periodic Hann, reflect pad FFT/2, Nyquist dropped."""
    window = (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(FFT_SIZE) / FFT_SIZE)).astype(np.float32)
    planes = np.zeros((1, 4, BINS, FRAMES), dtype=np.float32)
    for c, x in enumerate((left, right)):
        padded = np.pad(x, (FFT_SIZE // 2, FFT_SIZE // 2), mode="reflect")
        for t in range(FRAMES):
            start = t * HOP
            frame = padded[start:start + FFT_SIZE]
            if len(frame) < FFT_SIZE:
                break
            spectrum = np.fft.fft(frame * window)[:BINS]
            planes[0, 2 * c, :, t] = spectrum.real
            planes[0, 2 * c + 1, :, t] = spectrum.imag
    return planes


def linked_mask(mix: np.ndarray, vocals: np.ndarray) -> np.ndarray:
    """Android `StemAudioQuality.linkedInstrumentalMask` per bin/frame."""
    mix_power = (mix[0] ** 2).sum(axis=0)
    vocal_power = (vocals[0] ** 2).sum(axis=0)
    freq = (np.arange(BINS) * SAMPLE_RATE / FFT_SIZE)[:, None]
    fraction = np.sqrt(np.clip(vocal_power, 0, None) / np.maximum(mix_power, 1e-12)).clip(0, 1)
    blend = ((freq - 55) / 95).clip(0, 1)
    smooth = blend * blend * (3 - 2 * blend)
    mask = (1 - fraction * smooth).clip(0, 1)
    return np.where(mix_power <= 1e-12, 1.0, mask)


def fixture() -> np.ndarray:
    seconds = (FRAMES - 1) * HOP / SAMPLE_RATE + 0.2
    n = int(seconds * SAMPLE_RATE)
    wav = "/tmp/mdx_speech.wav"
    say_to_wav("somewhere over the river the singers hold a long bright note and the band keeps playing", wav,
               rate=SAMPLE_RATE)
    voice, _ = read_float_wav(wav)
    voice = np.pad(voice[:n], (0, max(0, n - len(voice[:n]))))
    t = np.arange(n) / SAMPLE_RATE
    chord = sum(0.08 * np.sin(2 * np.pi * f * t) for f in (110.0, 220.0, 277.18, 329.63, 440.0))
    left = (0.6 * voice + chord + 0.03 * np.sin(2 * np.pi * 55 * t)).astype(np.float32)
    right = (0.6 * voice + 0.9 * chord).astype(np.float32)
    return stft_planes(left, right)


def compare(reference: np.ndarray, candidate: np.ndarray, mix: np.ndarray) -> dict:
    rel = float(np.linalg.norm(candidate - reference) / max(np.linalg.norm(reference), 1e-12))
    mask_diff = np.abs(linked_mask(mix, candidate) - linked_mask(mix, reference))
    return {"relative_l2": rel, "mask_mean_abs_diff": float(mask_diff.mean()),
            "mask_max_abs_diff": float(mask_diff.max()), "finite": bool(np.isfinite(candidate).all())}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="out")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    report = {"source": ONNX_URL, "passed": False, "attempts": []}
    report_path = os.path.join(args.out, "mdx-report.json")
    try:
        import coremltools as ct
        import onnx
        import onnxruntime as ort
        import torch
        from onnx2torch import convert as onnx_to_torch

        report.update({"coremltools": ct.__version__, "torch": torch.__version__, "onnx": onnx.__version__})
        onnx_path = os.path.join(args.out, "UVR-MDX-NET-Voc_FT.onnx")
        urllib.request.urlretrieve(ONNX_URL, onnx_path)
        report["onnx_sha256"] = sha256_of(onnx_path)
        graph = onnx.load(onnx_path)
        inputs = [(i.name, [d.dim_value or d.dim_param for d in i.type.tensor_type.shape.dim]) for i in graph.graph.input]
        outputs = [(o.name, [d.dim_value or d.dim_param for d in o.type.tensor_type.shape.dim]) for o in graph.graph.output]
        report["onnx_inputs"], report["onnx_outputs"] = inputs, outputs
        print("ONNX inputs", inputs, "outputs", outputs)
        input_name, output_name = inputs[0][0], outputs[0][0]

        mix = fixture()
        session = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
        reference = session.run([output_name], {input_name: mix})[0]
        report["reference_shape"] = list(reference.shape)

        stage = "onnx2torch"
        torch_model = onnx_to_torch(graph).eval()
        with torch.no_grad():
            torch_out = torch_model(torch.from_numpy(mix))
            if isinstance(torch_out, (list, tuple)):
                torch_out = torch_out[0]
            report["onnx2torch_vs_ort"] = compare(reference, torch_out.numpy(), mix)
            stage = "trace"

            class Single(torch.nn.Module):
                def __init__(self, inner):
                    super().__init__()
                    self.inner = inner

                def forward(self, x):
                    y = self.inner(x)
                    return y[0] if isinstance(y, (list, tuple)) else y

            traced = torch.jit.trace(Single(torch_model).eval(), torch.from_numpy(mix), check_trace=False)
        print("onnx2torch vs ORT", report["onnx2torch_vs_ort"])

        shipped = None
        for name, precision in [("fp16", ct.precision.FLOAT16), ("fp32", ct.precision.FLOAT32)]:
            stage = f"coreml-{name}"
            started = time.time()
            mlmodel = ct.convert(traced, source="pytorch",
                                 inputs=[ct.TensorType(name="spectrum", shape=(1, 4, BINS, FRAMES), dtype=np.float32)],
                                 outputs=[ct.TensorType(name="vocals", dtype=np.float32)],
                                 convert_to="mlprogram", compute_precision=precision,
                                 minimum_deployment_target=ct.target.iOS17)
            mlmodel.author = "PixlAudio (converted from UVR-MDX-NET-Voc_FT)"
            mlmodel.short_description = "MDX-Net vocal spectrum model, [1,4,3072,256] at 44.1 kHz (TAIS instrumental)"
            mlmodel.user_defined_metadata["pixl.precision"] = name
            package = os.path.join(args.out, "MdxNetVocFT.mlpackage")
            if os.path.exists(package):
                import shutil
                shutil.rmtree(package)
            mlmodel.save(package)
            attempt = {"precision": name, "convert_seconds": round(time.time() - started, 1), "units": {}}
            ok = True
            for unit_name, unit in [("CPU_ONLY", ct.ComputeUnit.CPU_ONLY), ("ALL", ct.ComputeUnit.ALL)]:
                loaded = ct.models.MLModel(package, compute_units=unit)
                t0 = time.time()
                out = loaded.predict({"spectrum": mix})["vocals"]
                metrics = compare(reference, out, mix)
                metrics["latency_seconds"] = round(time.time() - t0, 3)
                metrics["passed"] = (metrics["finite"] and metrics["relative_l2"] <= 0.03
                                     and metrics["mask_mean_abs_diff"] <= 0.02)
                attempt["units"][unit_name] = metrics
                print(name, unit_name, metrics)
                ok = ok and metrics["passed"]
            attempt["passed"] = ok
            report["attempts"].append(attempt)
            if ok:
                shipped = (name, package)
                break
        if shipped is None:
            report["failure"] = "parity gate failed for fp16 and fp32"
            write_json(report_path, report)
            return 1
        asset = tar_mlpackage(shipped[1], os.path.join(args.out, "mdx_net_voc_ft.mlpackage.tar"))
        asset.update({"id": "mdxnet", "precision": shipped[0], "input": "spectrum", "output": "vocals",
                      "shape": [1, 4, BINS, FRAMES]})
        report.update({"passed": True, "precision": shipped[0], "asset": asset})
        write_json(report_path, report)
        print(json.dumps(asset, indent=2))
        return 0
    except Exception as error:  # the attempt failed: record where and why
        report["failure"] = f"{type(error).__name__}: {error}"
        report["failure_stage"] = locals().get("stage", "setup")
        report["traceback"] = traceback.format_exc()[-4000:]
        write_json(report_path, report)
        print(report["traceback"])
        return 1


if __name__ == "__main__":
    sys.exit(main())
