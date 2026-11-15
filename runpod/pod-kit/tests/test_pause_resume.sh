#!/usr/bin/env bash
# Tests _resume_paused, the first thing cmd_start tries after pause (not the
# live API). The pod lookup and the start action are scripted, asserting:
#   - a paused pod on the current image is resumed on its machine and waited on
#   - a refused resume (the machine's GPU is taken) terminates it and falls back
#   - a paused pod on an older image is terminated, not resumed
#   - a paused pod that is gone or no longer EXITED falls back without a resume
#   - a resumed pod whose container never starts is released as a stuck machine
# Run: ./pod-kit/tests/test_pause_resume.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=_setup.sh
source "${HERE}/_setup.sh"
POD_ID_FILE="${T}/pod-id"
HOSTS_FILE="${T}/hosts"
PAUSED_FILE="${T}/paused"
RUNPOD_IMAGE="ghcr.io/test/app:v2"

# ${T}/pod is the pod GET answer (empty = 404); ${T}/action the start action's HTTP code
rp_get() { [[ -s "${T}/pod" ]] && cat "${T}/pod"; }
_rp_raw() { echo "$2 $3" >> "${T}/actions"; printf '{}\n%s' "$(cat "${T}/action")"; }
_terminate_pod()   { echo "$1" >> "${T}/terminated"; }
rp_pod_placement() { printf 'host1\tGPU-A\tUS-KS-2\n'; }
_wait_ready()      { echo "$1" > "${T}/ready"; return "$(cat "${T}/wait")"; }

# run_resume <pod json> <action http> <wait rc> : one _resume_paused. Sets RC,
# RESUMED (start action sent), TERMINATED, READY.
run_resume() {
  echo pod-p > "${PAUSED_FILE}"
  printf '%s' "$1" > "${T}/pod"
  echo "$2" > "${T}/action"
  echo "$3" > "${T}/wait"
  rm -f "${T}/actions" "${T}/terminated" "${T}/ready" "${HOSTS_FILE}"
  ( set -e; _resume_paused ) > "${T}/out" 2>&1
  RC=$?
  RESUMED=$(grep -c '"action":"start"' "${T}/actions" 2>/dev/null)
  TERMINATED=$(cat "${T}/terminated" 2>/dev/null)
  READY=$(cat "${T}/ready" 2>/dev/null)
}

pass=0; fail=0
check() {  # desc condition
  if eval "$2"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s (rc=%s resumed=%s terminated=%s ready=%s)\n' "$1" "${RC}" "${RESUMED:-0}" "${TERMINATED}" "${READY}"; fi
}

PAUSED='{"id":"pod-p","status":"EXITED","image":"ghcr.io/test/app:v2"}'

run_resume "${PAUSED}" 200 0
check "paused pod on the current image → resumed and up" '[[ ${RC} -eq 0 && ${RESUMED} -eq 1 && ${READY} == pod-p && -z ${TERMINATED} && ! -f ${PAUSED_FILE} ]]'

run_resume "${PAUSED}" 400 0
check "resume refused → terminated, falls back" '[[ ${RC} -eq 1 && ${RESUMED} -eq 1 && ${TERMINATED} == pod-p && -z ${READY} ]]'

run_resume '{"id":"pod-p","status":"EXITED","image":"ghcr.io/test/app:v1"}' 200 0
check "older image → terminated, never resumed" '[[ ${RC} -eq 1 && ${RESUMED:-0} -eq 0 && ${TERMINATED} == pod-p ]]'

run_resume "" 200 0
check "paused pod gone → falls back, nothing sent" '[[ ${RC} -eq 1 && ${RESUMED:-0} -eq 0 && -z ${TERMINATED} ]]'

run_resume '{"id":"pod-p","status":"RUNNING","image":"ghcr.io/test/app:v2"}' 200 0
check "pod not EXITED → falls back, not resumed" '[[ ${RC} -eq 1 && ${RESUMED:-0} -eq 0 ]]'

run_resume "${PAUSED}" 200 3
check "resumed container never starts → released as stuck" '[[ ${RC} -eq 1 && ${TERMINATED} == pod-p && "$(cut -f1,2 "${HOSTS_FILE}")" == $'"'"'host1\tbad'"'"' ]]'

echo
echo "tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
