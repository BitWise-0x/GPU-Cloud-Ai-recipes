#!/usr/bin/env bash
# Tests how stop waits for a deleted pod (not the live
# API), asserting:
#   - a pod that shows EXITED for a while after the delete, then 404s, is gone
#   - a pod still listed after RUNPOD_DELETE_WAIT seconds is reported, exit 1
# Run: ./pod-kit/tests/test_wait_gone.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=_setup.sh
source "${HERE}/_setup.sh"

pass=0; fail=0
check() {  # desc condition
  if eval "$2"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi
}

sleep() { :; }
# ${T}/answers holds one rp_pod_exists answer per call; past its end the pod stays
rp_pod_exists() {
  local n
  n=$(( $(cat "${T}/calls" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${T}/calls"
  sed -n "${n}p" "${T}/answers" | grep . || echo yes
}

rm -f "${T}/calls"; printf 'yes\nyes\nyes\nyes\nyes\nyes\nyes\nno\n' > "${T}/answers"
rp_wait_gone pod-x; rc=$?
check "listed for 35 s, then gone → exit 0" '[[ ${rc} -eq 0 && "$(cat "${T}/calls")" == 8 ]]'

rm -f "${T}/calls"; : > "${T}/answers"
RUNPOD_DELETE_WAIT=20 rp_wait_gone pod-x; rc=$?
check "still listed at the limit → exit 1 after limit/5 checks" '[[ ${rc} -eq 1 && "$(cat "${T}/calls")" == 4 ]]'

echo
echo "tests: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
