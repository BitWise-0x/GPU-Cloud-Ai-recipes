# syntax=docker/dockerfile:1.6
#
# ComfyUI video upscale pod for RunPod
# Pinned versions:
#   ComfyUI            v0.45.2 (Comfy-Org/ComfyUI); its core nodes do the
#                      upscaling: ImageUpscaleWithModel (spandrel) and the
#                      native SeedVR2 nodes
#   comfyui-vhs        commit 3234937ff5f3 (= registry 1.7.9): chunked video
#                      load/save with audio
#   Python 3.12, torch 2.14.1 cu130
#   cloudflared        2026.10.3 (Cloudflare Tunnel connector, pinned + sha256)
# Bakes the per-frame upscale models (~230 MB), one frame-interpolation model
# and the two upscale workflows. SeedVR2 (6.8 GB) is NOT baked: start.sh
# downloads it from Hugging Face at boot, sha256-checked, which keeps the image
# small enough to push from a home uplink. Bake it instead (a COPY --link layer
# like the models below) when boot time matters more than image size.

# -----------------------------------------------------------------------------
# Stage `models`: per-frame upscale models, sha256-pinned. COPY --link layers
# below, so nothing in the main stage re-downloads or re-pushes them.
#   2xLiveActionV1_SPAN       live-action film/TV/camcorder (workflow default)
#                             CC-BY-NC-SA, jcj83429/upscaling
#   2xVHS2HD-RealPLKSR        VHS / analog tape captures, CC-BY-SA
#   1xDeH264_realplksr        1x clean-up pass for H.264 blocking, CC-BY-4.0
#   RealESRGAN_x2plus/x4plus  clean digital sources, BSD-3
#   realesr-general-x4v3      small, degraded sources at 4x, BSD-3
#   rife_v4.26                frame interpolation for ComfyUI's core
#                             "Frame Interpolation" blueprint, MIT
# The SPAN file is renamed (upstream ships it as 2xLiveActionV1_SPAN_490000.pth).
# -----------------------------------------------------------------------------
FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc AS models
RUN apk add --no-cache wget
WORKDIR /models

RUN mkdir -p upscale_models frame_interpolation && cd upscale_models && \
    wget -q -O 2xLiveActionV1_SPAN.pth \
      https://raw.githubusercontent.com/jcj83429/upscaling/f73a3a02874360ec6ced18f8bdd8e43b5d7bba57/2xLiveActionV1_SPAN/2xLiveActionV1_SPAN_490000.pth && \
    wget -q https://github.com/starinspace/StarinspaceUpscale/releases/download/Models/2xVHS2HD-RealPLKSR.pth && \
    wget -q https://github.com/Phhofm/models/releases/download/1xDeH264_realplksr/1xDeH264_realplksr.safetensors && \
    wget -q https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth && \
    wget -q https://huggingface.co/Comfy-Org/Real-ESRGAN_repackaged/resolve/main/RealESRGAN_x4plus.safetensors && \
    wget -q https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth && \
    cd ../frame_interpolation && \
    wget -q https://huggingface.co/Comfy-Org/frame_interpolation/resolve/main/frame_interpolation/rife_v4.26.safetensors && \
    cd /models && printf '%s\n' \
      "8b166c75831ea7f694d9058ee9c8df8148af8cc1d2b57e69e6581b15cab572f7  upscale_models/2xLiveActionV1_SPAN.pth" \
      "a702c79ec1d0421b46e91b1848b384a064b88ecffd14cffc998ded716a9e2d8a  upscale_models/2xVHS2HD-RealPLKSR.pth" \
      "91f054af6308e37b81c261ecf775a58be5fa1d37a816709db5d0fea6fceb24b8  upscale_models/1xDeH264_realplksr.safetensors" \
      "49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb  upscale_models/RealESRGAN_x2plus.pth" \
      "37f9a931c215f040aa6d50f711f2cb115f713c46df1d0d6469a8bd7bfe9a60bb  upscale_models/RealESRGAN_x4plus.safetensors" \
      "8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292  upscale_models/realesr-general-x4v3.pth" \
      "151874592c877740e5db11522f4514df569eeafb0a0fcb2696f16e9e8d317c94  frame_interpolation/rife_v4.26.safetensors" \
    | sha256sum -c - && \
    find /models -exec touch -h -d @0 {} +

FROM nvidia/cuda:13.0.3-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    COMFYUI_PORT=8188 \
    COMFYUI_LISTEN=127.0.0.1

# OS packages: Python 3.12 + pip (not in nvidia/cuda base), ffmpeg for VHS
# video read/encode, libGL for OpenCV, git for the clones below. 3.12 has no
# distutils, and get-pip provides pip, so no distutils or python3-pip package
# is installed.
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common gnupg \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-dev python3.12-venv \
        wget curl ca-certificates \
        ffmpeg libgl1 libglib2.0-0 \
        build-essential git \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.12 1 \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.12 \
    && rm -rf /var/lib/apt/lists/*

# PyTorch 2.14.1 + torchvision 0.29.1 for CUDA 13.0 (cu130). Stable cp312
# wheels. No torchaudio: ComfyUI v0.42.1 dropped it from its requirements, no
# baked node imports it, and cu130 torchaudio stops at 2.11 (cannot pair with
# torch 2.14).
#
# LAYER LAYOUT: why the CUDA wheels are installed FIRST, in their own RUNs,
# before torch:
#   The torch wheel does NOT bundle the CUDA libs; it declares them as pip deps
#   (cuda-toolkit[...]==13.0.3, which pins nvidia-cublas, cufft, ... exactly,
#   plus nvidia-cudnn-cu13, nccl, cusparselt, nvshmem and triton). Installing
#   `torch` in one RUN therefore resolves them all into a single multi-GB image
#   layer. Docker/containerd extracts a layer as one sequential
#   decompress+untar+write; a multi-GB blob of this kind can stall pod startup
#   for many minutes on a slow-disk host. The download is fast; the extraction
#   is the bottleneck (visible in the pod's system log).
#
#   Pre-installing the CUDA wheels (versions copied verbatim from torch 2.14.1+
#   cu130's Requires-Dist and cuda-toolkit 13.0.3's extras, read from the wheel
#   METADATA) in four grouped RUNs keeps each extract unit
#   to roughly 450-700 MB compressed. torch/vision then find their deps already
#   satisfied and become thin layers holding only torch's own .so files. The
#   CUDA layers are byte-identical across rebuilds (node-pin bumps, model
#   swaps), so warm hosts skip re-extracting them. They come from PyPI; torch
#   and torchvision come from the cu130 index.
#
#   IMPORTANT: if a future torch patch bumps any of these versions, torch will
#   pull a SECOND copy of that wheel into its own layer (silently defeating the
#   split). verify-torch-deps.py below fails the build when that happens:
#   re-derive the versions from the wheel METADATA when bumping torch.
#
#   The RUN order follows the wheels' own deps (PyPI requires_dist): cudnn needs
#   cublas, cublas needs nvrtc, cusolver needs cublas + cusparse + nvjitlink,
#   cufft and cusparse need nvjitlink. Each RUN only installs wheels whose
#   nvidia deps an earlier RUN (or the same one) already pinned; otherwise pip
#   would pull the newest version into the earlier layer and a later RUN would
#   replace it, leaving two copies in the image.
RUN pip install nvidia-cuda-nvrtc==13.0.88 nvidia-nvjitlink==13.4.92 \
        nvidia-cublas==13.1.1.3
RUN pip install nvidia-cudnn-cu13==9.24.0.43
RUN pip install nvidia-cusparse==12.6.3.3 nvidia-cusolver==12.0.4.66 \
        nvidia-cufft==12.0.0.61 nvidia-curand==10.4.0.35 \
        nvidia-cuda-cupti==13.0.85 nvidia-cuda-runtime==13.0.96 \
        nvidia-cufile==1.15.1.6 nvidia-nvtx==13.0.85
RUN pip install nvidia-nccl-cu13==2.30.7 nvidia-cusparselt-cu13==0.8.1 \
        nvidia-nvshmem-cu13==3.4.5 triton==3.8.0 cuda-bindings==13.4.4 \
        "cuda-toolkit[cublas,cudart,cufft,cufile,cupti,curand,cusolver,cusparse,nvjitlink,nvrtc,nvtx]==13.0.3"
# torch itself last: its deps are pre-satisfied above, so this layer holds
# only torch's own .so files (libtorch_cuda.so etc.), not the CUDA libs.
RUN pip install --index-url https://download.pytorch.org/whl/cu130 torch==2.14.1
RUN pip install --index-url https://download.pytorch.org/whl/cu130 torchvision==0.29.1
# Guard the layer split: verify torch imports and that every CUDA/triton dep
# torch declares (directly, or through the cuda-toolkit extras) is satisfied by
# what was pre-installed above. A future torch bump that changes a version
# would make torch pull a second copy into its own layer (defeating the split);
# the installed version would then not satisfy torch's Requires-Dist and this
# fails the build. Scoped to torch's own CUDA deps on purpose: a plain
# `pip check` also audits unrelated OS base-image packages (e.g. pygobject's
# missing pycairo) and fails on noise we don't control.
COPY build_assets/scripts/verify-torch-deps.py /tmp/verify-torch-deps.py
RUN python3 /tmp/verify-torch-deps.py && rm /tmp/verify-torch-deps.py

WORKDIR /

# -----------------------------------------------------------------------------
# LAYER ORDER (least to most volatile):
#   1. CUDA/torch base (above)
#   2. model set, COPY --link from stage `models`
#   3. ComfyUI clone + requirements
#   4. VHS clone
#   5. workflows, start.sh
# -----------------------------------------------------------------------------
COPY --link --from=models /models/upscale_models      /opt/comfyui-models/upscale_models
COPY --link --from=models /models/frame_interpolation /opt/comfyui-models/frame_interpolation

# ComfyUI at a release tag. A shallow clone of one tag: bump COMFYUI_VERSION
# to move to a newer release, and re-check the workflows in the UI.
ARG COMFYUI_VERSION=v0.45.2
RUN git clone --depth 1 --branch "${COMFYUI_VERSION}" \
        https://github.com/Comfy-Org/ComfyUI.git /workspace/ComfyUI \
    && rm -rf /workspace/ComfyUI/.git

WORKDIR /workspace/ComfyUI
RUN pip install -r requirements.txt

# models/ points at the clone-independent set above. diffusion_models/ and vae/
# are where start.sh puts the SeedVR2 download.
RUN rm -rf /workspace/ComfyUI/models && \
    ln -s /opt/comfyui-models /workspace/ComfyUI/models && \
    mkdir -p /opt/comfyui-models/diffusion_models /opt/comfyui-models/vae

# VideoHelperSuite 1.7.9: Load Video, Meta Batch Manager (chunks long videos
# so a movie never sits in RAM at once) and Video Combine (ffmpeg encode with
# the source audio).
WORKDIR /workspace/ComfyUI/custom_nodes
RUN git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git comfyui-videohelpersuite && \
    cd comfyui-videohelpersuite && git checkout 3234937ff5f3 && \
    pip install -r requirements.txt

RUN mkdir -p /workspace/ComfyUI/user/default/workflows \
             /workspace/ComfyUI/input \
             /workspace/ComfyUI/output

# Fail the build, not a billed pod, if ComfyUI or VHS no longer imports
# (--cpu: the builder has no GPU). The log goes to a file, not through `tee`:
# /bin/sh has no pipefail.
WORKDIR /workspace/ComfyUI
RUN python main.py --quick-test-for-ci --cpu > /tmp/quicktest.log 2>&1; rc=$?; \
    cat /tmp/quicktest.log; \
    [ "$rc" -eq 0 ] && ! grep -q "IMPORT FAILED" /tmp/quicktest.log && \
    rm -f /tmp/quicktest.log /workspace/ComfyUI/comfyui*.log

COPY --link build_assets/workflows/*.json /workspace/ComfyUI/user/default/workflows/
# sshd is the only way into the pod: the template publishes 22/tcp alone and
# ComfyUI is reached through an SSH tunnel (start.sh starts sshd, key auth
# only). Host keys are deleted so every pod generates its own at boot. Its own
# late layer keeps every layer above cached and shared with earlier tags.
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server \
    && rm -f /etc/ssh/ssh_host_* \
    && rm -rf /var/lib/apt/lists/*

# cloudflared connects the pod out to a Cloudflare Tunnel; pod.sh start runs it
# over SSH with the token from the starting machine (pod-kit/lib/common.sh,
# rp_cloudflare_up). ComfyUI is then served at the tunnel's hostname behind
# Cloudflare Access, and uploads reach a nearby Cloudflare edge instead of
# taking a slow route into the pod's network. Optional: unused without a tunnel
# name in pod.env. Pinned and checksummed.
ARG CLOUDFLARED_VERSION=2026.10.3
ARG CLOUDFLARED_SHA256=053b80b0a23031a038fdbf3c073f59f82b8f1f152aa67971d7383ffafc0dbab0
RUN curl -fsSL -o /usr/local/bin/cloudflared \
        "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64" \
    && echo "${CLOUDFLARED_SHA256}  /usr/local/bin/cloudflared" | sha256sum -c - \
    && chmod +x /usr/local/bin/cloudflared \
    && cloudflared --version

# FFmpeg 8.1 with NVENC (BtbN linux64-gpl build, pinned release and sha256) for
# VideoHelperSuite's video output; start.sh points VHS at it and encodes with
# h264_nvenc when the GPU has an encoder. It lives in /opt/ffmpeg so Ubuntu's
# apt ffmpeg stays the one on PATH for everything else. 8.1, not 9.0: BtbN's 9.0
# build asks for NVENC API 13.1 (driver >=610), newer than many RunPod hosts
# run; the 8.1 build encodes on NVENC API 13.0. BtbN removes dated builds after a while: a failed
# download here means picking a current autobuild and its sha256 from the
# release's checksums.sha256. NVIDIA's container runtime mounts the encoder
# libraries only for the video capability; the base image asks for compute and
# utility. Late, like sshd, so the layers above stay cached.
ARG FFMPEG_BUILD=autobuild-2026-11-07-12-47
ARG FFMPEG_ARCHIVE=ffmpeg-n8.1.3-34-ga35157abb9-linux64-gpl-8.1
ARG FFMPEG_SHA256=d9e9ab7ecc262a4d6cdb334b17af16ce227a9ed44d052f194ad0deca1a29e037
RUN apt-get update && apt-get install -y --no-install-recommends xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/ffmpeg.tar.xz "https://github.com/BtbN/FFmpeg-Builds/releases/download/${FFMPEG_BUILD}/${FFMPEG_ARCHIVE}.tar.xz" \
    && echo "${FFMPEG_SHA256}  /tmp/ffmpeg.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/ffmpeg.tar.xz -C /tmp \
    && install -D -m 0755 "/tmp/${FFMPEG_ARCHIVE}/bin/ffmpeg" /opt/ffmpeg/bin/ffmpeg \
    && install -D -m 0755 "/tmp/${FFMPEG_ARCHIVE}/bin/ffprobe" /opt/ffmpeg/bin/ffprobe \
    && rm -rf /tmp/ffmpeg.tar.xz "/tmp/${FFMPEG_ARCHIVE}" \
    && /opt/ffmpeg/bin/ffmpeg -hide_banner -encoders | grep -q ' h264_nvenc ' \
    && /opt/ffmpeg/bin/ffmpeg -hide_banner -encoders | grep -q ' libx264 ' \
    && /opt/ffmpeg/bin/ffmpeg -version | head -1
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

# Logs the SSH tunnel's drops and reconnects (written into the pod by
# pod.sh's watcher) to ComfyUI's Logs panel. Late, like sshd, so the layers
# above stay cached.
COPY --link build_assets/custom_nodes/connection_events.py /workspace/ComfyUI/custom_nodes/

# Resumable chunked uploads: every upload from the browser goes up in chunks that
# survive a dropped tunnel and stay under Cloudflare's 100 MB request cap, then
# lands where /upload/image puts it (README, "Uploads").
COPY --link build_assets/custom_nodes/chunked_upload/ /workspace/ComfyUI/custom_nodes/chunked_upload/

COPY --link --chmod=755 start.sh /usr/local/bin/start.sh

WORKDIR /workspace/ComfyUI

EXPOSE 8188

CMD ["/usr/local/bin/start.sh"]
