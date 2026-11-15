#!/usr/bin/env bash
# Tests config loading and the template setup builds (not the live API),
# asserting:
#   - defaults pod.env leaves out (disk, volume, cloud, template name) reach the
#     template body, which inline python reads from the environment
#   - only variables under POD_ENV_PREFIX go into the template env
#   - no volume mount at RUNPOD_VOLUME_GB=0, and no registry without credentials
#   - a value passed inline wins over pod.env, for RUNPOD_* and for the recipe's
#     own prefix
# Run: ./pod-kit/tests/test_setup_config.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

pass=0; fail=0
check() {  # desc condition
  if eval "$2"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi
}

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/recipe"
cat > "${T}/recipe/pod.env" <<'ENV'
RUNPOD_IMAGE=ghcr.io/test/app:v1
RUNPOD_POD_NAME=test-pod
POD_APP_PORT=8000
RUNPOD_TUNNEL_PORT=18000
RUNPOD_GPU_TYPES="GPU-A"
POD_ENV_PREFIX=APP_
APP_MODE=fast
APP_LIMIT=10
OTHER_VAR=stays-out
ENV

# run_setup [VAR=value...] : one cmd_setup in a fresh shell with the API
# stubbed; the POST /templates body lands in ${T}/body
run_setup() {
  rm -f "${T}/body"
  env "$@" RUNPOD_API_KEY=test-dummy RUNPOD_SECRETS_FILE="${T}/none" \
    RUNPOD_HOSTS_FILE="${T}/hosts" T="${T}" HERE="${HERE}" bash -c '
    source "${HERE}/../pod.sh" "${T}/recipe" help >/dev/null 2>&1 || exit 9
    set +e
    rp_find_by_name() { :; }
    rp_post() { printf "%s" "$2" > "${T}/body"; echo "{\"id\":\"tpl-1\"}"; }
    cmd_setup >/dev/null 2>&1
    printf "%s" "${RUNPOD_GPU_TYPES}" > "${T}/gpu"
  '
}
body() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "${T}/body" "$1"; }

run_setup
check "template body written" '[[ -s "${T}/body" ]]'
check "default disk, template name from pod name" '[[ "$(body "d[\"disk\"], d[\"name\"]")" == "(50, '"'"'test-pod'"'"')" ]]'
check "no volume mount at the default 0 GB" '[[ "$(body "\"mounts\" in d")" == False ]]'
check "no registry without credentials" '[[ "$(body "\"registry\" in d")" == False ]]'
check "only APP_* in the template env" '[[ "$(body "sorted(d[\"env\"].items())")" == "[('"'"'APP_LIMIT'"'"', '"'"'10'"'"'), ('"'"'APP_MODE'"'"', '"'"'fast'"'"')]" ]]'
check "only SSH published" '[[ "$(body "d[\"ports\"]")" == "['"'"'22/tcp'"'"']" ]]'

run_setup APP_MODE=slow RUNPOD_CONTAINER_DISK_GB=80 RUNPOD_GPU_TYPES="GPU-Z"
check "inline APP_* wins over pod.env" '[[ "$(body "d[\"env\"][\"APP_MODE\"]")" == slow ]]'
check "inline RUNPOD_* wins over pod.env" '[[ "$(body "d[\"disk\"]")" == 80 && "$(cat "${T}/gpu")" == GPU-Z ]]'

run_setup RUNPOD_VOLUME_GB=40
check "a volume mounts at /workspace" '[[ "$(body "d[\"mounts\"]")" == "{'"'"'persistent'"'"': {'"'"'size'"'"': 40, '"'"'path'"'"': '"'"'/workspace'"'"'}}" ]]'

echo
echo "tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
