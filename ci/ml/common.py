"""Shared helpers for the Core ML conversion scripts (build-time only; never shipped).

Packaging contract with the app (`App/Services/ML/ModelCatalog.swift`): every model is an `.mlpackage` directory
archived as an uncompressed ustar `.tar` (the app streams it to disk with its own tar reader, then calls
`MLModel.compileModel(at:)`). The SHA-256 and byte size of each tar go into `models-v1.json` and are pinned in the
app's catalog.
"""

import hashlib
import json
import os
import subprocess
import tarfile


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def tar_mlpackage(package_dir: str, tar_path: str) -> dict:
    """Archives `package_dir` (an .mlpackage) as an uncompressed ustar tar with deterministic metadata."""
    base = os.path.basename(package_dir.rstrip("/"))

    def scrub(info: tarfile.TarInfo) -> tarfile.TarInfo:
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        info.mode = 0o755 if info.isdir() else 0o644
        return info

    entries = []
    for root, dirs, files in os.walk(package_dir):
        dirs.sort()
        for name in sorted(files):
            if name.startswith("._") or name == ".DS_Store":
                continue
            entries.append(os.path.join(root, name))
    with tarfile.open(tar_path, "w", format=tarfile.USTAR_FORMAT) as tar:
        for path in entries:
            arcname = os.path.join(base, os.path.relpath(path, package_dir)).replace(os.sep, "/")
            if len(arcname.encode()) > 255:
                raise ValueError(f"path too long for ustar: {arcname}")
            tar.add(path, arcname=arcname, recursive=False, filter=scrub)
    return {"file": os.path.basename(tar_path), "bytes": os.path.getsize(tar_path), "sha256": sha256_of(tar_path),
            "package": base}


def write_json(path: str, value) -> None:
    with open(path, "w") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")


def say_to_wav(text: str, path: str, rate: int = 16000) -> None:
    """macOS text-to-speech as 32-bit float little-endian mono WAV at `rate` Hz (a speech fixture on the runner)."""
    subprocess.run(["say", "-o", path, "--file-format=WAVE", f"--data-format=LEF32@{rate}", text], check=True)


def read_float_wav(path: str):
    """Reads the WAVE written by `say_to_wav` (IEEE float32, mono or interleaved) as a float32 numpy array (mono)."""
    import numpy as np

    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a WAVE file")
    pos = 12
    channels, bits, fmt, rate, samples = 1, 32, 3, 16000, None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = int.from_bytes(data[pos + 4:pos + 8], "little")
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = int.from_bytes(body[0:2], "little")
            channels = int.from_bytes(body[2:4], "little")
            rate = int.from_bytes(body[4:8], "little")
            bits = int.from_bytes(body[14:16], "little")
            if fmt == 0xFFFE and len(body) >= 26:
                fmt = int.from_bytes(body[24:26], "little")
        elif cid == b"data":
            if fmt == 3 and bits == 32:
                samples = np.frombuffer(body, dtype="<f4").astype(np.float32)
            elif fmt == 1 and bits == 16:
                samples = np.frombuffer(body, dtype="<i2").astype(np.float32) / 32768.0
            else:
                raise ValueError(f"unsupported WAVE format {fmt}/{bits}")
        pos += 8 + size + (size & 1)
    if samples is None:
        raise ValueError("no data chunk")
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    return samples, rate
