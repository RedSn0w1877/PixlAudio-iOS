"""Qwen3-ForcedAligner-0.6B as a WordTimingBackend (loaded at import by the handler; needs torch + qwen_asr).

Each request is one window of the isolated vocals (≤ 180 s, 16 kHz mono) and the text to place in it. The
aligner returns tokens with times in seconds relative to the window. Requests are batched by count and by total
audio length to bound VRAM; a failed batch is retried one request at a time so one bad line can't sink the song.
"""

from __future__ import annotations

from typing import Sequence

from ..errors import GPU_OOM, WorkerError
from ..log import log
from .languages import ALIGNER_LANGUAGES, AlignRequest, Token

MODEL_ID = "qwen3-forced-aligner-0.6b"


class QwenAligner:
    model_id = MODEL_ID

    def __init__(self, path: str, *, device: str | None = None, batch_size: int = 8, max_batch_s: float = 240.0):
        import torch
        from qwen_asr import Qwen3ForcedAligner

        self._torch = torch
        cuda = torch.cuda.is_available()
        device = device or ("cuda:0" if cuda else "cpu")  # CPU only for the CI smoke test
        dtype = torch.bfloat16 if cuda else torch.float32
        self._impl = Qwen3ForcedAligner.from_pretrained(path, dtype=dtype, device_map=device)
        self.batch_size = batch_size
        self.max_batch_s = max_batch_s
        self.deadline = None  # set per job by the pipeline

    def supports(self, language: str | None) -> bool:
        return language in ALIGNER_LANGUAGES

    def _run(self, batch: Sequence[AlignRequest]):
        return self._impl.align(
            audio=[(r.audio, 16000) for r in batch],
            text=[r.text for r in batch],
            language=[ALIGNER_LANGUAGES[r.language] for r in batch],
        )

    def align(self, requests: Sequence[AlignRequest]) -> list[list[Token] | None]:
        results: list[list[Token] | None] = [None] * len(requests)
        batches: list[list[int]] = []
        current: list[int] = []
        seconds = 0.0
        for k, request in enumerate(requests):
            length = len(request.audio) / 16000.0
            if current and (len(current) >= self.batch_size or seconds + length > self.max_batch_s):
                batches.append(current)
                current, seconds = [], 0.0
            current.append(k)
            seconds += length
        if current:
            batches.append(current)

        oom = self._torch.cuda.OutOfMemoryError
        for batch in batches:
            if self.deadline is not None:
                self.deadline.check("lyrics")
            try:
                outputs = self._run([requests[k] for k in batch])
                pairs = list(zip(batch, outputs))
            except oom:
                raise WorkerError(GPU_OOM, "the GPU ran out of memory while aligning lyrics", refresh_worker=True) from None
            except Exception as exc:  # retry one by one
                log.warning("align_batch_failed", size=len(batch), reason=type(exc).__name__)
                pairs = []
                for k in batch:
                    try:
                        pairs.append((k, self._run([requests[k]])[0]))
                    except oom:
                        raise WorkerError(GPU_OOM, "the GPU ran out of memory while aligning lyrics",
                                          refresh_worker=True) from None
                    except Exception as exc2:
                        log.warning("align_line_failed", reason=type(exc2).__name__)
            for k, output in pairs:
                results[k] = [Token(text=item.text, start_s=float(item.start_time), end_s=float(item.end_time))
                              for item in output.items]
        return results
