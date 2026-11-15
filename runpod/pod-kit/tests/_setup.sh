#!/usr/bin/env bash
# Sourced by every test: a throwaway recipe directory with a test pod.env, dummy
# credentials, and pod.sh sourced with `help` so every cmd_* and helper is
# defined without touching the API. Leaves T (the temp dir, removed on exit).
# Dummy values set before sourcing win over the files (common.sh keeps caller
# values), so nothing here can reach the API with a real key.

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/recipe"
cat > "${T}/recipe/pod.env" <<'EOF'
RUNPOD_IMAGE=ghcr.io/test/app:v1
RUNPOD_POD_NAME=test-pod
POD_APP_PORT=8000
RUNPOD_TUNNEL_PORT=18000
RUNPOD_CONTAINER_DISK_GB=20
RUNPOD_CLOUD_TYPE=SECURE
RUNPOD_GPU_TYPES="GPU-A|GPU-B"
CF_TUNNEL_NAME=test-tunnel
CF_PUBLIC_HOSTNAME=app.example.com
EOF
export RUNPOD_API_KEY=test-dummy
export RUNPOD_SECRETS_FILE="${T}/no-secrets.env"
export RUNPOD_HOSTS_FILE="${T}/hosts"

# shellcheck source=../pod.sh
source "${HERE}/../pod.sh" "${T}/recipe" help >/dev/null 2>&1 || {
  echo "FAIL: could not source pod.sh"; exit 1; }
set +e
