#!/usr/bin/env bash
# Build a recipe's image for linux/amd64 and push it to your registry.
#
#   build.sh <recipe-dir> [image-ref]
#
# The image ref defaults to RUNPOD_IMAGE from the recipe's pod.env. Log in to
# the registry first (docker login ghcr.io). RunPod hosts are x86_64, so the
# build targets linux/amd64 whatever this machine is; on an ARM Mac that runs
# under emulation and is slow, a remote x86 builder is faster.
#
# Use a new tag for every build: RunPod resolves a tag when it pulls, and a host
# that already holds an older image under the same tag can keep running it.
# After a push, point pod.env at the new tag and run pod.sh <recipe-dir> setup.

set -euo pipefail

if [[ $# -lt 1 || ! -f "${1:-}/Dockerfile" ]]; then
  echo "usage: build.sh <recipe-dir> [image-ref]   (the directory must hold a Dockerfile)" >&2
  exit 1
fi
recipe="$(cd "$1" && pwd)"
image="${2:-}"
if [[ -z "${image}" ]]; then
  [[ -f "${recipe}/pod.env" ]] || { echo "ERROR: no image ref given and no ${recipe}/pod.env" >&2; exit 1; }
  # shellcheck disable=SC1091
  image="$(set -a; source "${recipe}/pod.env"; printf '%s' "${RUNPOD_IMAGE:-}")"
fi
[[ -n "${image}" ]] || { echo "ERROR: RUNPOD_IMAGE is empty in ${recipe}/pod.env" >&2; exit 1; }
case "${image}" in
  *:latest|*@*) ;;
  *:*) ;;
  *) echo "ERROR: '${image}' has no tag; give it one (e.g. :v1)" >&2; exit 1 ;;
esac

echo "==> building ${image} from ${recipe}"
docker buildx build \
  --platform linux/amd64 \
  --provenance=false \
  --tag "${image}" \
  --push \
  "${recipe}"
echo "==> pushed ${image}"
echo "    next: set RUNPOD_IMAGE=${image} in pod.env, then pod.sh ${recipe} setup"
