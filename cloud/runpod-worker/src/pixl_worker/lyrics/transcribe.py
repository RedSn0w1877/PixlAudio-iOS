"""Qwen3-ASR-1.7B for songs that arrive without lyrics (owner decision: transcribe and label them "AI-written
lyrics"). Loaded lazily on first use, because its load is billed and most jobs never need it.

Input is one clip per VAD phrase (≤ 12 s, 16 kHz mono); output is (language code or None, text) per clip. The
pipeline turns each non-empty clip into a line, then asks the word-timing backend for words where the language
is covered, and keeps line timing otherwise.
"""

from __future__ import annotations

from typing import Sequence

import numpy as np

from ..errors import GPU_OOM, WorkerError
from .languages import ASR_LANGUAGE_CODES, ASR_LANGUAGE_NAMES

MODEL_ID = "qwen3-asr-1.7b"


class QwenTranscriber:
    model_id = MODEL_ID

    def __init__(self, path: str, *, device: str = "cuda:0", batch_size: int = 8):
        import torch
        from qwen_asr import Qwen3ASRModel

        self._torch = torch
        dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
        self._impl = Qwen3ASRModel.from_pretrained(
            path, dtype=dtype, device_map=device, max_inference_batch_size=batch_size, max_new_tokens=256)
        self.batch_size = batch_size
        self.deadline = None

    def transcribe(self, clips: Sequence[np.ndarray], language: str | None) -> list[tuple[str | None, str]]:
        name = ASR_LANGUAGE_NAMES.get(language) if language else None
        out: list[tuple[str | None, str]] = []
        for i in range(0, len(clips), self.batch_size):
            if self.deadline is not None:
                self.deadline.check("lyrics")
            batch = [(np.asarray(c, dtype=np.float32), 16000) for c in clips[i:i + self.batch_size]]
            try:
                results = self._impl.transcribe(audio=batch, language=name)
            except self._torch.cuda.OutOfMemoryError:
                raise WorkerError(GPU_OOM, "the GPU ran out of memory while transcribing", refresh_worker=True) from None
            for result in results:
                detected = (result.language or "").split(",")[0].strip()
                out.append((ASR_LANGUAGE_CODES.get(detected), (result.text or "").strip()))
        return out
