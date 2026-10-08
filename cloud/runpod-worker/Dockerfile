# syntax=docker/dockerfile:1.10@sha256:865e5dd094beca432e8c0a1d5e1c465db5f998dca4e439981029b3b81fb39ed5
#
# PixlAudio Cloud Studio worker for RunPod Serverless (docs/handoff/2026-10-07-plans/cloud-studio-design.md, 2.2).
#
# Stages: test  - CPU-only unit tests (no torch, no weights)
#         deps  - the PyTorch base + ffmpeg + every Python dependency, installed from hashes
#         small - the KB-sized configs and tokenizers (fetch_small.py, sha256-checked)
#         final - the image that is pushed and deployed. It has no RUN on purpose: a RUN here would need every
#                 layer below it unpacked, which re-downloads 7 GB of weights whenever it re-runs.
#         smoke - CI only, never pushed: loads the real weights on CPU and runs each model once.
#
# Pinning: every FROM (and this frontend) by digest; every model file by sha256 in weights.lock (each large file
# is its own `ADD --link --checksum` layer, keyed by its checksum, so it is downloaded once and its layer digest
# never changes); every Python package by hash in requirements.lock. ci/check_weights.py fails the build when an
# ADD line and weights.lock disagree, or when a FROM is not pinned.

ARG BASE=pytorch/pytorch:2.11.0-cuda12.8-cudnn9-runtime@sha256:eee11b3b3872a8c838e35ef48f08b2d5def2080902c7f666831310ca1a0ef2be
ARG SLIM=python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f

########## test: CPU-only unit tests (runs on every worker change, never pushes anything)
FROM ${SLIM} AS test
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg openssl \
 && rm -rf /var/lib/apt/lists/*
COPY requirements-test.lock /t/
RUN pip install --no-deps --require-hashes -r /t/requirements-test.lock
COPY . /t/
WORKDIR /t
CMD ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider", "tests"]

########## deps: base + ffmpeg + the hashed Python closure (torch itself comes from the base and is never touched)
FROM ${BASE} AS deps
# The base installs its packages into Ubuntu's own Python 3.12 (PEP 668 marks it externally managed), so pip
# needs PIP_BREAK_SYSTEM_PACKAGES; everything lands next to torch in /usr/local/lib/python3.12/dist-packages.
ENV DEBIAN_FRONTEND=noninteractive PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1 PIP_ROOT_USER_ACTION=ignore PYTHONDONTWRITEBYTECODE=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/pixl \
 && dpkg-query -W -f='${Package} ${Version}\n' > /opt/pixl/apt-versions.txt
COPY requirements.lock ci/pip_check.py /opt/pixl/build/
# --no-deps: the lock is the complete closure (ci/lock.py), so pip resolves nothing and cannot replace torch.
# --no-build-isolation: the one source-only package (antlr4-python3-runtime, pure Python) builds with the base's
# setuptools instead of fetching unpinned build tools.
# spin is a PyTorch developer tool in the base image (never used at runtime) that pins click<8.4, which runpod
# 1.12.0 (click>=8.4.2) can't share, so it is removed rather than ignored by the check.
RUN python3 -m pip freeze --all > /opt/pixl/base-freeze.txt \
 && python3 /opt/pixl/build/pip_check.py --save-baseline /opt/pixl/build/pip-check-base.txt \
 && python3 -m pip install --no-deps --no-build-isolation --require-hashes -r /opt/pixl/build/requirements.lock \
 && python3 -m pip uninstall -y spin \
 && python3 /opt/pixl/build/pip_check.py --baseline /opt/pixl/build/pip-check-base.txt \
 && python3 -m pip freeze --all > /opt/pixl/pip-freeze.txt \
 && python3 -c "import torch, torchaudio, runpod, msst, msst.utils.model_utils, msst.models.bs_roformer, \
demucs.pretrained, demucs.apply, qwen_asr, nagisa, soynlp.tokenizer, soundfile, soxr, librosa, transformers, \
accelerate, numpy; print('imports ok: torch', torch.__version__, 'runpod', runpod.__version__)" \
 && ffmpeg -hide_banner -version | head -n 1 \
 && rm -rf /opt/pixl/build /root/.cache

########## small: configs, tokenizers and the model card text, by pinned URL, sha256-verified
FROM ${SLIM} AS small
COPY weights.lock fetch_small.py /w/
RUN python /w/fetch_small.py --lock /w/weights.lock --out /models

########## final: the deployed image. One layer per large weight file; no RUN (see the top of this file).
FROM deps AS final
# sep: BS-RoFormer anvuew ft1, 204.5 MB, GPL-3.0
ADD --link --chmod=644 --checksum=sha256:60347271e8493fdff28ef558c3b2297afb869a1f4462594ed548038264bec395 \
    https://huggingface.co/anvuew/BS-RoFormer/resolve/24988f47270cb3529b62c4f3bbb8234f4586de9b/bs_roformer_ft1_anvuew_sdr_12.55.ckpt \
    /models/sep/bs_roformer_ft1_anvuew_sdr_12.55.ckpt
# demucs: htdemucs_ft, a bag of 4 x 84 MB, MIT (loaded on first 4-stem job)
ADD --link --chmod=644 --checksum=sha256:ba3fe64ae8ef66ac9a4857222ce48efbdc5eb3ad375cb79dd13debee5aaa4066 \
    https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/f7e0c4bc-ba3fe64a.th \
    /models/demucs/f7e0c4bc-ba3fe64a.th
ADD --link --chmod=644 --checksum=sha256:e57c48e6b0e38af4f7118d7bd08c49f0a0c0edf7d09143bdd902ea0d237303e6 \
    https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/d12395a8-e57c48e6.th \
    /models/demucs/d12395a8-e57c48e6.th
ADD --link --chmod=644 --checksum=sha256:ef3bcb9c8b40d14ae5d51b6db2587339cc12c6b77c0be151ce6d69002e087bf2 \
    https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/92cfc3b6-ef3bcb9c.th \
    /models/demucs/92cfc3b6-ef3bcb9c.th
ADD --link --chmod=644 --checksum=sha256:f3cf25b222c4eed7cd49dd8b2c9597d50c18bd154090f7b919cfa5f93cf22c49 \
    https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/04573f0d-f3cf25b2.th \
    /models/demucs/04573f0d-f3cf25b2.th
# aligner: Qwen3-ForcedAligner-0.6B, 1.84 GB, Apache-2.0 (loaded at start)
ADD --link --chmod=644 --checksum=sha256:47831d0e82f96b20e9034dba01a075ee06436654719f6a68289e49f1b65ce0e7 \
    https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B/resolve/c7cbfc2048c462b0d63a45797104fc9db3ad62b7/model.safetensors \
    /models/aligner/model.safetensors
# asr: Qwen3-ASR-1.7B, 4.22 GB + 0.48 GB, Apache-2.0 (loaded on the first song without lyrics)
ADD --link --chmod=644 --checksum=sha256:a4cd1f1a04d90b757dc7f7dd26254e69a013b19e80efe590a83c6a3bde8608d6 \
    https://huggingface.co/Qwen/Qwen3-ASR-1.7B/resolve/7278e1e70fe206f11671096ffdd38061171dd6e5/model-00001-of-00002.safetensors \
    /models/asr/model-00001-of-00002.safetensors
ADD --link --chmod=644 --checksum=sha256:6e0b9d9e09e2e0238e7ef3cc8a484ab387e91b90f1900bedf88bc92d7929ccfc \
    https://huggingface.co/Qwen/Qwen3-ASR-1.7B/resolve/7278e1e70fe206f11671096ffdd38061171dd6e5/model-00002-of-00002.safetensors \
    /models/asr/model-00002-of-00002.safetensors
COPY --link --from=small /models/ /models/
COPY --link models/demucs/htdemucs_ft.yaml /models/demucs/htdemucs_ft.yaml
COPY --link LICENSES/ /opt/pixl/LICENSES/
COPY --link NOTICE weights.lock /opt/pixl/
COPY --link src/ /opt/pixl/src/
ARG GIT_SHA=unknown
ENV PYTHONPATH=/opt/pixl/src PYTHONUNBUFFERED=1 PIXL_WORKER_GIT_SHA=${GIT_SHA} PIXL_MODELS_DIR=/models \
    HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 TOKENIZERS_PARALLELISM=false RUNPOD_LOG_LEVEL=INFO
LABEL org.opencontainers.image.source=https://github.com/RedSn0w1877/PixlAudio-iOS \
      org.opencontainers.image.description="PixlAudio Cloud Studio RunPod worker" \
      org.opencontainers.image.licenses="GPL-3.0-only AND MIT AND Apache-2.0"
WORKDIR /opt/pixl
CMD ["python3", "-u", "-m", "pixl_worker.handler"]

########## smoke: CI only. The same weights as final (same ADD lines, so the same cached layers) minus ASR, which
# is too big to run in fp32 on a CI runner; `op: bench` on RunPod covers it.
FROM deps AS smoke
ADD --link --chmod=644 --checksum=sha256:60347271e8493fdff28ef558c3b2297afb869a1f4462594ed548038264bec395 \
    https://huggingface.co/anvuew/BS-RoFormer/resolve/24988f47270cb3529b62c4f3bbb8234f4586de9b/bs_roformer_ft1_anvuew_sdr_12.55.ckpt \
    /models/sep/bs_roformer_ft1_anvuew_sdr_12.55.ckpt
ADD --link --chmod=644 --checksum=sha256:ba3fe64ae8ef66ac9a4857222ce48efbdc5eb3ad375cb79dd13debee5aaa4066 \
    https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/f7e0c4bc-ba3fe64a.th \
    /models/demucs/f7e0c4bc-ba3fe64a.th
ADD --link --chmod=644 --checksum=sha256:e57c48e6b0e38af4f7118d7bd08c49f0a0c0edf7d09143bdd902ea0d237303e6 \
    https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/d12395a8-e57c48e6.th \
    /models/demucs/d12395a8-e57c48e6.th
ADD --link --chmod=644 --checksum=sha256:ef3bcb9c8b40d14ae5d51b6db2587339cc12c6b77c0be151ce6d69002e087bf2 \
    https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/92cfc3b6-ef3bcb9c.th \
    /models/demucs/92cfc3b6-ef3bcb9c.th
ADD --link --chmod=644 --checksum=sha256:f3cf25b222c4eed7cd49dd8b2c9597d50c18bd154090f7b919cfa5f93cf22c49 \
    https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/04573f0d-f3cf25b2.th \
    /models/demucs/04573f0d-f3cf25b2.th
ADD --link --chmod=644 --checksum=sha256:47831d0e82f96b20e9034dba01a075ee06436654719f6a68289e49f1b65ce0e7 \
    https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B/resolve/c7cbfc2048c462b0d63a45797104fc9db3ad62b7/model.safetensors \
    /models/aligner/model.safetensors
COPY --link --from=small /models/ /models/
COPY --link models/demucs/htdemucs_ft.yaml /models/demucs/htdemucs_ft.yaml
COPY --link src/ /opt/pixl/src/
ENV PYTHONPATH=/opt/pixl/src PIXL_MODELS_DIR=/models HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
    TOKENIZERS_PARALLELISM=false
RUN python3 -m pixl_worker.smoke --models /models
