# syntax=docker/dockerfile:1.6
#
# FaceFusion pod for RunPod (the standalone Gradio app, not ComfyUI).
# Pinned versions:
#   FaceFusion       3.9.2   (facefusion/facefusion)
#   onnxruntime-gpu  1.31.0  (3.9.2 installer.py's cuda@13 pin)
#   FFmpeg           8.1.3   (BtbN linux64-gpl build with NVENC, pinned + sha256)
#   cloudflared      2026.10.3 (Cloudflare Tunnel connector, pinned + sha256)
#
# The image holds the application and its model weights only. No faces, photos
# or videos are baked in; inputs come in at runtime through the UI or scp.
# Pure ONNX Runtime: no torch.
#
# Model licenses vary (several face swappers are non-commercial). This recipe
# downloads them at build time into your own image; check each model's terms
# before you use the image for anything beyond personal use, and keep the image
# private.

# -----------------------------------------------------------------------------
# Stage `models`: the baked model subset (.onnx + .hash pairs) in the flat
# .assets/models layout FaceFusion expects. Base pinned by digest so a moved
# alpine tag cannot re-run the downloads; one RUN per model scopes a swap to
# one layer. Release tags per file come from 3.9.2's create_static_model_set in
# each module.
# -----------------------------------------------------------------------------
FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc AS models
RUN apk add --no-cache wget
WORKDIR /models/.assets/models
ARG A=https://github.com/facefusion/facefusion-assets/releases/download

# Face swappers. hyperswap_1a_256 is FaceFusion's stock default; the rest are
# the common alternatives to A/B against. Any model not baked is downloaded on
# first use, the main cause of slow first runs.
RUN wget -q ${A}/models-3.3.0/hyperswap_1a_256.onnx \
      && wget -q ${A}/models-3.3.0/hyperswap_1a_256.hash
RUN wget -q ${A}/models-3.3.0/hyperswap_1b_256.onnx \
      && wget -q ${A}/models-3.3.0/hyperswap_1b_256.hash
RUN wget -q ${A}/models-3.3.0/hyperswap_1c_256.onnx \
      && wget -q ${A}/models-3.3.0/hyperswap_1c_256.hash
RUN wget -q ${A}/models-3.0.0/simswap_unofficial_512.onnx \
      && wget -q ${A}/models-3.0.0/simswap_unofficial_512.hash
RUN wget -q ${A}/models-3.0.0/inswapper_128.onnx \
      && wget -q ${A}/models-3.0.0/inswapper_128.hash

# Face detectors. yoloface_8n = default; retinaface_10g + scrfd_2.5g let
# --face-detector-model many run for hard angles and profiles.
RUN wget -q ${A}/models-3.0.0/yoloface_8n.onnx \
      && wget -q ${A}/models-3.0.0/yoloface_8n.hash
RUN wget -q ${A}/models-3.0.0/retinaface_10g.onnx \
      && wget -q ${A}/models-3.0.0/retinaface_10g.hash
RUN wget -q ${A}/models-3.0.0/scrfd_2.5g.onnx \
      && wget -q ${A}/models-3.0.0/scrfd_2.5g.hash

# Face landmarker (2dfan4) + recognizer (arcface, needed for reference-face
# selection, the default selector mode).
RUN wget -q ${A}/models-3.0.0/2dfan4.onnx \
      && wget -q ${A}/models-3.0.0/2dfan4.hash
RUN wget -q ${A}/models-3.0.0/arcface_w600k_r50.onnx \
      && wget -q ${A}/models-3.0.0/arcface_w600k_r50.hash

# Face masker: xseg occluder (hands, hair, glasses in front of the face) +
# bisenet parser (region mask).
RUN wget -q ${A}/models-3.1.0/xseg_1.onnx \
      && wget -q ${A}/models-3.1.0/xseg_1.hash
RUN wget -q ${A}/models-3.0.0/bisenet_resnet_34.onnx \
      && wget -q ${A}/models-3.0.0/bisenet_resnet_34.hash

# Face enhancers: gfpgan_1.4 = default; gpen_bfr_2048 (high-res faces) and
# codeformer in the dropdown.
RUN wget -q ${A}/models-3.0.0/gfpgan_1.4.onnx \
      && wget -q ${A}/models-3.0.0/gfpgan_1.4.hash
RUN wget -q ${A}/models-3.0.0/gpen_bfr_2048.onnx \
      && wget -q ${A}/models-3.0.0/gpen_bfr_2048.hash
RUN wget -q ${A}/models-3.0.0/codeformer.onnx \
      && wget -q ${A}/models-3.0.0/codeformer.hash

# Support models FaceFusion loads whatever swapper is chosen:
#   fan_68_5     the 68->5 landmark converter, loaded with every landmarker
#   fairface     the face classifier (age, gender, race) the selector uses
#   kim_vocal_2  the default voice extractor, for video audio handling
#   nsfw_1/2/3   FaceFusion's content analyser, which checks every source and
#                target before processing
RUN wget -q ${A}/models-3.0.0/fan_68_5.onnx \
      && wget -q ${A}/models-3.0.0/fan_68_5.hash
RUN wget -q ${A}/models-3.0.0/fairface.onnx \
      && wget -q ${A}/models-3.0.0/fairface.hash
RUN wget -q ${A}/models-3.0.0/kim_vocal_2.onnx \
      && wget -q ${A}/models-3.0.0/kim_vocal_2.hash
RUN wget -q ${A}/models-3.3.0/nsfw_1.onnx \
      && wget -q ${A}/models-3.3.0/nsfw_1.hash
RUN wget -q ${A}/models-3.3.0/nsfw_2.onnx \
      && wget -q ${A}/models-3.3.0/nsfw_2.hash
RUN wget -q ${A}/models-3.3.0/nsfw_3.onnx \
      && wget -q ${A}/models-3.3.0/nsfw_3.hash

# Fixed mtime so an identical re-fetch produces the same layer digest.
RUN find /models/.assets/models -type f -exec touch -d @0 {} +

# -----------------------------------------------------------------------------
# Final stage: CUDA 13 runtime base, Python 3.12, FaceFusion, CUDA ONNX Runtime.
# 13.0.x, not the newest 13.x: the base's runtime enforces cuda>=<its version>
# at the container prestart hook, and many RunPod hosts report CUDA 13.0.
# -----------------------------------------------------------------------------
FROM nvidia/cuda:13.0.3-cudnn-runtime-ubuntu22.04

# NVIDIA's container runtime mounts only the driver libraries a capability asks
# for; the base image asks for compute and utility. video adds the encoder and
# decoder libraries NVENC needs (ffmpeg's h264_nvenc and hevc_nvenc).
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video \
    FACEFUSION_PORT=7860 \
    FACEFUSION_LISTEN=127.0.0.1

# Python 3.12: FaceFusion 3.9.2 pins scipy==1.18.1, which requires >=3.12.
# curl for FaceFusion's pre_check, xz for the FFmpeg archive below, libGL and
# glib for OpenCV. openssh-server is the only way into the pod; host keys are
# deleted so every pod generates its own at boot.
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common gnupg \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-dev python3.12-venv \
        curl ca-certificates xz-utils git \
        libgl1 libglib2.0-0 \
        openssh-server \
    && rm -f /etc/ssh/ssh_host_* \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.12 1 \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.12 \
    && rm -rf /var/lib/apt/lists/*

# FFmpeg 8.1. Ubuntu 22.04's ffmpeg 4.4 lacks `-fps_mode` (5.1+), which
# FaceFusion 3.9.2 passes to every frame reader: on 4.4 every read is empty,
# the preview stays blank and every output frame is a black placeholder. Its
# HDR tone-map for HLG/PQ sources also needs a modern build. The check runs
# FaceFusion's reader command shape on a test source. BtbN's linux64-gpl build
# loads NVENC from the driver at runtime (h264_nvenc, hevc_nvenc). Not 9.0:
# BtbN's 9.0 build needs NVENC API 13.1 (driver >=610), newer than many RunPod
# hosts run. BtbN prunes dated builds: if the download fails, take a current
# autobuild and its sha256 from the release's checksums.sha256.
ARG FFMPEG_BUILD=autobuild-2026-11-07-12-47
ARG FFMPEG_ARCHIVE=ffmpeg-n8.1.3-34-ga35157abb9-linux64-gpl-8.1
ARG FFMPEG_SHA256=d9e9ab7ecc262a4d6cdb334b17af16ce227a9ed44d052f194ad0deca1a29e037
RUN curl -fsSL -o /tmp/ffmpeg.tar.xz "https://github.com/BtbN/FFmpeg-Builds/releases/download/${FFMPEG_BUILD}/${FFMPEG_ARCHIVE}.tar.xz" \
    && echo "${FFMPEG_SHA256}  /tmp/ffmpeg.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/ffmpeg.tar.xz -C /tmp \
    && install -m 0755 "/tmp/${FFMPEG_ARCHIVE}/bin/ffmpeg" "/tmp/${FFMPEG_ARCHIVE}/bin/ffprobe" /usr/local/bin/ \
    && rm -rf /tmp/ffmpeg.tar.xz "/tmp/${FFMPEG_ARCHIVE}"
RUN test "$(ffmpeg -loglevel error -f lavfi -i testsrc2=size=64x64:rate=5 -t 1 \
        -vf scale=out_primaries=bt709:out_transfer=bt709:intent=perceptual \
        -fps_mode passthrough -pix_fmt bgr24 -f rawvideo - | wc -c)" -eq $((64 * 64 * 3 * 5)) \
    && ffmpeg -hide_banner -encoders | grep -q ' libx264 ' \
    && ffmpeg -hide_banner -encoders | grep -q ' h264_nvenc ' \
    && ffmpeg -hide_banner -encoders | grep -q ' hevc_nvenc ' \
    && ffmpeg -version | head -1

# cloudflared, optional (unused without a tunnel name in pod.env): pod.sh start
# runs it over SSH with the token from the starting machine
# (pod-kit/lib/common.sh, rp_cloudflare_up).
ARG CLOUDFLARED_VERSION=2026.10.3
ARG CLOUDFLARED_SHA256=053b80b0a23031a038fdbf3c073f59f82b8f1f152aa67971d7383ffafc0dbab0
RUN curl -fsSL -o /usr/local/bin/cloudflared \
        "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64" \
    && echo "${CLOUDFLARED_SHA256}  /usr/local/bin/cloudflared" | sha256sum -c - \
    && chmod +x /usr/local/bin/cloudflared \
    && cloudflared --version

# FaceFusion at its release tag. The requirements below are hand-pinned for
# this version: bump FACEFUSION_VERSION and re-pin them together (diff the new
# requirements.txt and installer.py).
ARG FACEFUSION_VERSION=3.9.2
RUN git clone --depth 1 --branch "${FACEFUSION_VERSION}" \
        https://github.com/facefusion/facefusion.git /workspace/facefusion \
    && rm -rf /workspace/facefusion/.git
WORKDIR /workspace/facefusion
RUN grep -q "'version': '${FACEFUSION_VERSION}'" facefusion/metadata.py

# Not through FaceFusion's install.py: it looks for a `pip` executable (get-pip
# installs pip3, no `pip` shim) and ignores pip's exit code, so a failed
# install would ship an image that crash-loops at pod start.
#
# 3.9.2's requirements.txt verbatim except onnxruntime, swapped for the CUDA 13
# GPU wheel (installer.py's cuda@13 pin). FaceFusion treats onnxruntime
# 1.25.1-1.29 on CUDA as leaking the memory arena (inference_manager.py).
RUN python3 -m pip install \
        gradio-rangeslider==0.0.8 \
        gradio==5.50.0 \
        numpy==2.5.4 \
        onnx==1.23.2 \
        opencv-python-headless==5.0.0.93 \
        tqdm==4.70.1 \
        scipy==1.18.1 \
        onnxruntime-gpu==1.31.0

# Fail the build, not a billed pod, if the ONNX/CUDA stack is incoherent: the
# CUDA provider is registered (the GPU wheel
# registers it even without a GPU at build time), onnxruntime-gpu is the only
# onnxruntime package (a CPU wheel next to it shadows the CUDA build), and the
# version is outside the leaking range.
RUN python3 -c "import importlib.metadata as md, onnxruntime as ort, numpy, gradio; \
provs = ort.get_available_providers(); \
assert 'CUDAExecutionProvider' in provs, f'CUDAExecutionProvider missing: {provs}'; \
v = tuple(int(x) for x in ort.__version__.split('.')[:3]); \
assert not ((1, 25, 1) < v < (1, 29, 0)), f'onnxruntime {ort.__version__} leaks the CUDA arena'; \
dists = sorted({d.metadata['Name'].lower().replace('_', '-') for d in md.distributions()} & {'onnxruntime', 'onnxruntime-gpu'}); \
assert dists == ['onnxruntime-gpu'], f'onnxruntime packages: {dists}'; \
print('stack OK: onnxruntime', ort.__version__, dists, '| numpy', numpy.__version__, '| providers', provs)"

# One fixed output directory, so outputs are easy to find and copy off over scp.
RUN sed -i -e 's#^output_path =$#output_path = /workspace/output#' facefusion.ini \
    && grep -qx 'output_path = /workspace/output' facefusion.ini

# Baked models into FaceFusion's .assets/models dir, one layer per model. A
# single layer for the whole set is several GB: slow to push from a home uplink,
# and a pod extracts it serially.
COPY --link --from=models /models/.assets/models/hyperswap_1a_256.onnx /models/.assets/models/hyperswap_1a_256.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/hyperswap_1b_256.onnx /models/.assets/models/hyperswap_1b_256.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/hyperswap_1c_256.onnx /models/.assets/models/hyperswap_1c_256.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/simswap_unofficial_512.onnx /models/.assets/models/simswap_unofficial_512.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/inswapper_128.onnx /models/.assets/models/inswapper_128.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/yoloface_8n.onnx /models/.assets/models/yoloface_8n.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/retinaface_10g.onnx /models/.assets/models/retinaface_10g.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/scrfd_2.5g.onnx /models/.assets/models/scrfd_2.5g.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/2dfan4.onnx /models/.assets/models/2dfan4.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/arcface_w600k_r50.onnx /models/.assets/models/arcface_w600k_r50.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/fan_68_5.onnx /models/.assets/models/fan_68_5.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/fairface.onnx /models/.assets/models/fairface.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/xseg_1.onnx /models/.assets/models/xseg_1.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/bisenet_resnet_34.onnx /models/.assets/models/bisenet_resnet_34.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/gfpgan_1.4.onnx /models/.assets/models/gfpgan_1.4.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/gpen_bfr_2048.onnx /models/.assets/models/gpen_bfr_2048.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/codeformer.onnx /models/.assets/models/codeformer.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/kim_vocal_2.onnx /models/.assets/models/kim_vocal_2.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/nsfw_1.onnx /models/.assets/models/nsfw_1.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/nsfw_2.onnx /models/.assets/models/nsfw_2.hash /workspace/facefusion/.assets/models/
COPY --link --from=models /models/.assets/models/nsfw_3.onnx /models/.assets/models/nsfw_3.hash /workspace/facefusion/.assets/models/

# Every expected model (.onnx + .hash) is present and non-empty.
RUN set -eu; \
    cd /workspace/facefusion/.assets/models; \
    for m in hyperswap_1a_256 hyperswap_1b_256 hyperswap_1c_256 \
             simswap_unofficial_512 inswapper_128 \
             yoloface_8n retinaface_10g scrfd_2.5g \
             2dfan4 arcface_w600k_r50 fan_68_5 fairface \
             xseg_1 bisenet_resnet_34 \
             gfpgan_1.4 gpen_bfr_2048 codeformer \
             kim_vocal_2 nsfw_1 nsfw_2 nsfw_3; do \
      for ext in onnx hash; do \
        f="${m}.${ext}"; \
        [ -s "$f" ] || { echo "BAKE INCOMPLETE: $f missing or empty" >&2; exit 1; }; \
      done; \
    done; \
    echo "model bake verified: $(ls *.onnx | wc -l) onnx files, $(du -sh . | cut -f1) total"

COPY --link --chmod=755 start.sh /usr/local/bin/start.sh

EXPOSE 7860

CMD ["/usr/local/bin/start.sh"]
