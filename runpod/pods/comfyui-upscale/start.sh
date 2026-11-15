#!/usr/bin/env bash
# Launch ComfyUI on a RunPod GPU pod for video upscaling.
#
# The per-frame upscale models are baked into the image. SeedVR2 is fetched
# from Hugging Face in the background while ComfyUI starts, so the fast
# workflow is usable at once and the SeedVR2 one a few minutes later.
# Override any of these via the RunPod template's environment variables.

set -euo pipefail

cd /workspace/ComfyUI

# SSH is the only way into the pod: the template publishes 22/tcp alone and
# the app listens on loopback, reached through an SSH tunnel. RunPod injects
# the account's keys as PUBLIC_KEY; without one nobody could connect, so refuse
# to start rather than bill for an unreachable pod. Key auth only.
if [[ -z "${PUBLIC_KEY:-}" ]]; then
  echo "FATAL: PUBLIC_KEY is unset (no SSH key in the RunPod account); the pod would be unreachable." >&2
  exit 1
fi
mkdir -p /root/.ssh /run/sshd
chmod 700 /root/.ssh
printf '%s\n' "${PUBLIC_KEY}" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -A
/usr/sbin/sshd -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
  -o PermitRootLogin=prohibit-password
echo "sshd started (key auth only)"

PORT="${COMFYUI_PORT:-8188}"
LISTEN="${COMFYUI_LISTEN:-127.0.0.1}"
EXTRA_ARGS="${COMFYUI_EXTRA_ARGS:-}"
# ComfyUI's --max-upload-size (stock 100 MB). 16 GB default: whole films are
# uploaded as single files.
MAX_UPLOAD_MB="${COMFYUI_MAX_UPLOAD_MB:-16384}"
# Which SeedVR2 diffusion model to download, or "none". 3B fp16 fits the 48 GB
# tier at 1080p; the 7B files want an 80 GB card.
SEEDVR2_MODEL="${COMFYUI_SEEDVR2_MODEL:-seedvr2_3b_fp16.safetensors}"

# No VRAM flag: --highvram pins most of host RAM and can get the container
# OOM-killed; ComfyUI's default management fits the 48 GB cards this targets.

# The pod sees every host CPU (nproc can say 128) but runs on a cgroup quota of
# a few dozen vCPUs. torch and OpenCV size their thread pools to the visible
# CPUs, and that many busy threads on a small quota throttle the container, so
# cap the pools at the quota.
CPU_QUOTA="none"
if read -r quota period 2>/dev/null < /sys/fs/cgroup/cpu.max && [[ "${quota}" != "max" ]]; then
  CPU_QUOTA=$(( (quota + period - 1) / period ))
  export OMP_NUM_THREADS="${OMP_NUM_THREADS:-${CPU_QUOTA}}"
  export OPENCV_FOR_THREADS_NUM="${OPENCV_FOR_THREADS_NUM:-${CPU_QUOTA}}"
fi

python3 -c "
import sys
import torch
if not torch.cuda.is_available():
    print('STARTUP CHECK FAILED: torch.cuda.is_available() is False.', file=sys.stderr)
    print('  The upscale models would run on the CPU, hundreds of times slower.', file=sys.stderr)
    sys.exit(1)
print(f'startup check OK: torch {torch.__version__}, CUDA {torch.version.cuda}, device {torch.cuda.get_device_name(0)}')
"

# SeedVR2 files from Comfy-Org/SeedVR2, pinned to a repo commit, with their
# LFS sha256. Written as .part and renamed only after the hash matches, so the
# loader dropdown never lists a half-written file.
SEEDVR2_REPO="https://huggingface.co/Comfy-Org/SeedVR2/resolve/df48879708206a403d2a61acd55578c2e80fd233"
declare -A SEEDVR2_SHA256=(
  [seedvr2_3b_fp16.safetensors]=98669fd2c06df5eca88baf68cd5c478775c8e61fc110e598c52b350145ea2660
  [seedvr2_7b_fp16.safetensors]=2742ca6fee63bc5cc1773f426dd4b07b78cad27f51c9ea5cd42b035e6b592252
  [seedvr2_7b_sharp_fp16.safetensors]=70823bca54b9c24eeb56e1c452697c7c2a430867e58db0e376c6e260f3a4489d
  [seedvr2_ema_vae_fp16.safetensors]=20678548f420d98d26f11442d3528f8b8c94e57ee046ef93dbb7633da8612ca1
)

fetch_seedvr2() {
  local subdir="$1" name="$2"
  local dest="models/${subdir}/${name}"
  if [[ -s "${dest}" ]]; then
    echo ">> SeedVR2: ${name} already present"
    return 0
  fi
  local t0
  t0=$(date +%s)
  if ! curl -fsSL --retry 5 --retry-delay 5 -o "${dest}.part" "${SEEDVR2_REPO}/${subdir}/${name}"; then
    echo "SEEDVR2 DOWNLOAD FAILED: ${name}. The fast workflow still works." >&2
    rm -f "${dest}.part"
    return 1
  fi
  if ! echo "${SEEDVR2_SHA256[${name}]}  ${dest}.part" | sha256sum -c --status -; then
    echo "SEEDVR2 DOWNLOAD FAILED: ${name} has the wrong sha256. The fast workflow still works." >&2
    rm -f "${dest}.part"
    return 1
  fi
  mv "${dest}.part" "${dest}"
  echo ">> SeedVR2: ${name} ready in $(( $(date +%s) - t0 ))s (press R in the UI to refresh the model list)"
}

if [[ "${SEEDVR2_MODEL}" == none ]]; then
  echo ">> SeedVR2: download disabled (COMFYUI_SEEDVR2_MODEL=none)"
elif [[ -z "${SEEDVR2_SHA256[${SEEDVR2_MODEL}]:-}" || "${SEEDVR2_MODEL}" == seedvr2_ema_vae_fp16.safetensors ]]; then
  echo "SEEDVR2: unknown COMFYUI_SEEDVR2_MODEL '${SEEDVR2_MODEL}'. Known: seedvr2_3b_fp16.safetensors, seedvr2_7b_fp16.safetensors, seedvr2_7b_sharp_fp16.safetensors, none" >&2
else
  echo ">> SeedVR2: downloading ${SEEDVR2_MODEL} + VAE in the background"
  ( fetch_seedvr2 vae seedvr2_ema_vae_fp16.safetensors && \
    fetch_seedvr2 diffusion_models "${SEEDVR2_MODEL}" ) || true &
fi

# VHS writes video through the auto-h264-mp4 format generated here: h264_nvenc
# when the GPU has an encoder (L40, L40S, A6000, 6000 Ada), else libx264 with
# VHS's stock h264-mp4 arguments (A100, H100). NVENC runs preset p4, tune hq,
# constant quality from its cq widget. The workflows set cq = crf + 6, where
# NVENC matched libx264's quality at a smaller size (VMAF 96.5 at cq 24 vs 95.8
# at crf 18, 3.4 MB vs 4.4). Each format reads its own widget and ignores the
# other. VHS is forced onto the image's NVENC-capable ffmpeg.
export VHS_FORCE_FFMPEG_PATH=/opt/ffmpeg/bin/ffmpeg
VHS_FORMAT=/workspace/ComfyUI/custom_nodes/comfyui-videohelpersuite/video_formats/auto-h264-mp4.json
if "${VHS_FORCE_FFMPEG_PATH}" -v error -f lavfi -i nullsrc=s=256x256 -frames:v 1 -c:v h264_nvenc -f null - 2>/dev/null; then
  VIDEO_ENCODER="h264_nvenc (GPU)"
  cat > "${VHS_FORMAT}" <<'FORMAT'
{
    "main_pass":
    [
        "-n", "-c:v", "h264_nvenc", "-preset", "p4", "-tune", "hq",
        "-pix_fmt", ["pix_fmt", ["yuv420p"]],
        "-rc", "vbr", "-cq", ["cq", "INT", {"default": 24, "min": 0, "max": 51, "step": 1}], "-b:v", "0",
        "-vf", "scale=out_color_matrix=bt709",
        "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"
    ],
    "fake_trc": "bt709",
    "audio_pass": ["-c:a", "aac"],
    "save_metadata": ["save_metadata", "BOOLEAN", {"default": true}],
    "trim_to_audio": ["trim_to_audio", "BOOLEAN", {"default": false}],
    "extension": "mp4"
}
FORMAT
else
  VIDEO_ENCODER="libx264 on the CPU (this GPU has no NVENC)"
  cat > "${VHS_FORMAT}" <<'FORMAT'
{
    "main_pass":
    [
        "-n", "-c:v", "libx264",
        "-pix_fmt", ["pix_fmt", ["yuv420p", "yuv420p10le"]],
        "-crf", ["crf", "INT", {"default": 19, "min": 0, "max": 51, "step": 1}],
        "-vf", "scale=out_color_matrix=bt709",
        "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"
    ],
    "fake_trc": "bt709",
    "audio_pass": ["-c:a", "aac"],
    "save_metadata": ["save_metadata", "BOOLEAN", {"default": true}],
    "trim_to_audio": ["trim_to_audio", "BOOLEAN", {"default": false}],
    "extension": "mp4"
}
FORMAT
fi
# pod.sh start reads it over SSH for its "is up" banner
printf 'Video out: %s\n' "${VIDEO_ENCODER}" > /workspace/.pod-banner

echo "=========================================="
echo " ComfyUI video upscale pod"
echo "=========================================="
echo " Listen      : ${LISTEN}:${PORT}"
echo " Max upload  : ${MAX_UPLOAD_MB} MB"
echo " SeedVR2     : ${SEEDVR2_MODEL}"
echo " Extra args  : ${EXTRA_ARGS}"
echo " Video out   : ${VIDEO_ENCODER}, VHS format auto-h264-mp4"
echo " CPU         : $(getconf _NPROCESSORS_ONLN) visible, quota ${CPU_QUOTA} vCPU, OMP/OpenCV threads ${OMP_NUM_THREADS:-default}"
echo "------------------------------------------"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || true
echo "------------------------------------------"
echo " UI         : ${LISTEN}:${PORT} inside the pod, through the SSH tunnel"
echo "              (pod.sh <dir> tunnel), or the Cloudflare address."
echo "=========================================="

# shellcheck disable=SC2086
exec python main.py \
  --listen "${LISTEN}" \
  --port "${PORT}" \
  --preview-method none \
  --disable-api-nodes \
  --max-upload-size "${MAX_UPLOAD_MB}" \
  ${EXTRA_ARGS}
