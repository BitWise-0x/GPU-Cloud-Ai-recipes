#!/usr/bin/env bash
# Tests how start watches a booting pod (not the live API), asserting:
#   - the newest system log line is read from the server-sent event stream,
#     with terminal colour codes stripped, and nothing when the API is silent
#   - a pull whose system log keeps moving is waited on until the UI answers
#   - a machine whose system log goes silent is reported stuck (exit 3)
# Run: ./pod-kit/tests/test_boot_wait.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=_setup.sh
source "${HERE}/_setup.sh"
HOSTS_FILE="${T}/hosts"

pass=0; fail=0
check() {  # desc condition
  if eval "$2"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi
}

# ---- reading the system log -------------------------------------------------
curl() {
  printf 'data: {"source":"system","line":"Pulling fs layer","ts":"2026-10-24T14:27:01Z"}\n\n'
  printf 'data: {"source":"system","line":"\\u001b[32mDownloading\\u001b[0m 512MB/1.5GB","ts":"2026-10-24T14:27:09Z"}\n\n'
  return 28
}
entry=$(rp_pod_system_log_last pod-x)
check "newest system line, colour codes stripped" '[[ "${entry}" == $'"'"'2026-10-24T14:27:09Z\tDownloading 512MB/1.5GB'"'"' ]]'

curl() { return 28; }
entry=$(rp_pod_system_log_last pod-x)
check "silent log API → nothing" '[[ -z "${entry}" ]]'

# ---- watching a boot --------------------------------------------------------
sleep() { :; }
rp_pod_runtime_state() { [[ -f "${T}/started" ]] && echo RUNNING || echo "RUNNING (container not started)"; }
rp_pod_placement()     { printf 'host1\tGPU-A\tUS-KS-2\n'; }
_check_public_ports()  { :; }
rp_tunnel_watch_start(){ :; }
ui_banner()            { :; }
# the UI answers once the container has started
rp_app_url()           { [[ -f "${T}/started" ]] && echo "http://127.0.0.1:18000"; }
curl()                 { echo 200; }

# a moving pull: a new log line on every check, the container starts on the 4th
echo 0 > "${T}/n"
rp_pod_system_log_last() {
  local n; n=$(( $(<"${T}/n") + 1 )); echo "${n}" > "${T}/n"
  [[ "${n}" -ge 4 ]] && : > "${T}/started"
  printf '2026-10-24T14:27:%02dZ\tDownloading layer %d\n' "${n}" "${n}"
}
rm -f "${T}/started"
( RUNPOD_BOOT_IDLE_TIMEOUT=240 _wait_ready pod-x ) > "${T}/out" 2>&1
rc=$?
check "moving pull → waits until the UI answers (exit 0)" '[[ ${rc} -eq 0 && "$(cut -f2 "${HOSTS_FILE}")" == good ]]'

# a silent machine: the log never moves
rp_pod_system_log_last() { :; }
rm -f "${T}/started" "${HOSTS_FILE}"
( RUNPOD_BOOT_IDLE_TIMEOUT=0 _wait_ready pod-x ) > "${T}/out" 2>&1
rc=$?
check "silent machine → stuck (exit 3)" '[[ ${rc} -eq 3 ]] && grep -q "no image pull progress" "${T}/out"'

echo
echo "tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
