"""PixlAudio Cloud Studio worker for RunPod Serverless.

Everything importable without torch lives in this package's top-level modules (schema, storage, audio, log,
pipeline, lyrics.windows, lyrics.postprocess, ...), so the CPU-only tests run without any model library.
The model wrappers (separate, lyrics.align, lyrics.transcribe) import torch lazily.
"""

WORKER_VERSION = "1.0.0"
SUPPORTED_VERSIONS = (1,)
