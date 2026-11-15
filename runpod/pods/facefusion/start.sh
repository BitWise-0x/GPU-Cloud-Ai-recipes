#!/usr/bin/env bash
# Launch FaceFusion's Gradio UI on a RunPod GPU pod.
#
# Pure ONNX app (no torch): serves on port 7860 on the pod's loopback, CUDA via
# onnxruntime-gpu's CUDAExecutionProvider. Override any value below through the
# template env (FACEFUSION_* in pod.env, copied by pod.sh setup).

set -euo pipefail

cd /workspace/facefusion

# facefusion.ini points output_path here; FaceFusion does not create it.
mkdir -p /workspace/output

PORT="${FACEFUSION_PORT:-7860}"
LISTEN="${FACEFUSION_LISTEN:-127.0.0.1}"

# FaceFusion's `run` has no listen or port flag; it calls gradio's launch()
# with no server_name, and gradio reads these env vars instead. Loopback: the
# UI is reached only through the SSH tunnel or the pod's own cloudflared.
export GRADIO_SERVER_NAME="${LISTEN}"
export GRADIO_SERVER_PORT="${PORT}"

# One OpenCV thread per frame worker. OpenCV sizes its pool to the CPU quota,
# so each of the execution_thread_count workers would run a full-size pool of
# its own, all contending for the same few cores.
export OPENCV_FOR_THREADS_NUM=1

# Video encodes on the GPU's NVENC when it has one (A100 and H100 have none):
# it frees the CPU cores for the face work, which is what limits FaceFusion on
# a small host. The encoder dropdown still offers the others.
if ffmpeg -v error -f lavfi -i nullsrc=s=256x256 -frames:v 1 -c:v h264_nvenc -f null - 2>/dev/null; then
  ENCODER_ARGS="--output-video-encoder h264_nvenc"
  VIDEO_ENCODER="h264_nvenc (GPU)"
else
  ENCODER_ARGS=""
  VIDEO_ENCODER="libx264 on the CPU (this GPU has no NVENC)"
fi
# pod.sh start reads it over SSH for its "is up" banner
printf 'Video out: %s\n' "${VIDEO_ENCODER}" > /workspace/.pod-banner

# Extra args appended verbatim to the `run` command (e.g. --face-swapper-model
# hyperswap_1b_256 to change the UI default).
EXTRA_ARGS="${FACEFUSION_EXTRA_ARGS:-}"

# SSH is the only way into the pod: the template publishes 22/tcp alone and
# the app listens on loopback. RunPod injects the account's keys as PUBLIC_KEY;
# without one nobody could connect, so refuse to start rather than bill for an
# unreachable pod. Key auth only.
if [[ -z "${PUBLIC_KEY:-}" ]]; then
  echo "FATAL: PUBLIC_KEY is unset (no SSH key in the RunPod account); the pod would be unreachable." >&2
  exit 1
fi
mkdir -p /root/.ssh /run/sshd
chmod 700 /root/.ssh
# written whole, not appended: a restarted container keeps its writable layer
printf '%s\n' "${PUBLIC_KEY}" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -A
/usr/sbin/sshd -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
  -o PermitRootLogin=prohibit-password
echo "sshd started (key auth only)"

# Refuse to start if the CUDA execution provider is not available. FaceFusion
# would otherwise fall back to the CPU and crawl on a billed GPU pod.
python3 -c "
import sys
try:
    import onnxruntime as ort
except ImportError as e:
    print(f'STARTUP CHECK FAILED: onnxruntime not importable: {e}', file=sys.stderr)
    sys.exit(1)
providers = ort.get_available_providers()
if 'CUDAExecutionProvider' not in providers:
    print(f'STARTUP CHECK FAILED: CUDAExecutionProvider absent (have {providers}).', file=sys.stderr)
    print('  onnxruntime-gpu and the host driver do not match. Check RUNPOD_ALLOWED_CUDA_VERSIONS.', file=sys.stderr)
    sys.exit(1)
print(f'startup check OK: onnxruntime {ort.__version__}, providers {providers}')
"

echo "=========================================="
echo " FaceFusion pod"
echo "=========================================="
echo " Listen      : ${LISTEN}:${PORT}"
echo " Providers   : CUDA (onnxruntime-gpu)"
echo " Video out   : ${VIDEO_ENCODER}"
echo " Extra args  : ${EXTRA_ARGS}"
echo " Baked models:"
ls -1 /workspace/facefusion/.assets/models/*.onnx 2>/dev/null | sed 's#.*/#   #'
echo "------------------------------------------"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || true
echo "=========================================="

# shellcheck disable=SC2086
exec python facefusion.py run \
  --execution-providers cuda \
  ${ENCODER_ARGS} \
  ${EXTRA_ARGS}
