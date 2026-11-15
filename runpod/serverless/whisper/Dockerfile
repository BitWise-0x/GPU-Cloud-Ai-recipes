# syntax=docker/dockerfile:1.6
#
# RunPod serverless worker: faster-whisper large-v3, weights baked in.
#   faster-whisper  1.2.1, on CTranslate2 4.8.3 (CUDA 12 + cuDNN 9)
#   model           Systran/faster-whisper-large-v3 (MIT), pinned by commit
#   runpod          2.1.0 (the serverless SDK)
#
# Baked weights mean a cold worker pays only the image pull, never a model
# download inside a billed job, and no network volume ties the endpoint to one
# data center.

# -----------------------------------------------------------------------------
# Stage `weights`: download the model once, pinned by commit, into a layer the
# final stage copies with --link. A code change never re-downloads or re-pushes
# it; only a WHISPER_REVISION change does.
# -----------------------------------------------------------------------------
FROM python:3.12-slim AS weights
ARG WHISPER_REPO=Systran/faster-whisper-large-v3
ARG WHISPER_REVISION=edaa852ec7e145841d8ffdb056a99866b5f0a478
RUN pip install --no-cache-dir huggingface_hub==2.3.0 \
    && python -c "import os; from huggingface_hub import snapshot_download; \
snapshot_download(os.environ['WHISPER_REPO'], revision=os.environ['WHISPER_REVISION'], local_dir='/models/whisper')" \
    && rm -rf /models/whisper/.cache \
    && test -s /models/whisper/model.bin \
    && find /models -exec touch -h -d @0 {} +

# -----------------------------------------------------------------------------
# Final stage. CUDA 12.8 + cuDNN 9: what the CTranslate2 4.x wheels link
# against. Ubuntu 24.04 ships Python 3.12 in its own archive.
# -----------------------------------------------------------------------------
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH \
    WHISPER_MODEL_DIR=/models/whisper

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-venv ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && python3.12 -m venv /opt/venv

# Dependencies before the weights and the code: the most stable layer first.
COPY requirements.txt /tmp/requirements.txt
RUN pip install -r /tmp/requirements.txt && rm /tmp/requirements.txt \
    && python -c "import ctranslate2, faster_whisper, runpod; print('ctranslate2', ctranslate2.__version__)"

COPY --link --from=weights /models/whisper /models/whisper

WORKDIR /app
COPY validation.py handler.py /app/

# Fail the build, not a billed worker, if the model files do not load as a
# Whisper model. CPU here: the builder has no GPU.
RUN python -c "from faster_whisper import WhisperModel; WhisperModel('/models/whisper', device='cpu', compute_type='int8'); print('model loads')"

CMD ["python", "-u", "/app/handler.py"]
