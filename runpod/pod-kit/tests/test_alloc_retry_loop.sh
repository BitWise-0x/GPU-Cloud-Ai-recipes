#!/usr/bin/env bash
# Tests the allocation RETRY-LOOP control flow of cmd_start (not the live API).
# Runs the real cmd_start from pod.sh with _rp_raw replaced by scripted mock
# create results and the lookups around the loop stubbed, asserting:
#   - stops immediately on success (never attempts another create)
#   - moves to the next GPU on a capacity error within one walk
#   - fails fast on the first hard (non-retryable) error, even mid-walk
#   - re-walks exactly RUNPOD_ALLOC_RETRIES extra times (default 6) on capacity
#   - releases a pod that lands on a machine recorded as stuck and walks on
#   - places a (GPU, data center) pair with a stuck machine outside that data
#     center, and skips the GPU when that leaves no data center
#   - re-places a pod whose container never started (watchdog), recording the
#     machine as stuck
#   - with RUNPOD_COUNTRY_FALLBACK=1, tries every country in the same walk once
#     the preferred countries are out, and not at all without it
# Run: ./pod-kit/tests/test_alloc_retry_loop.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=_setup.sh
source "${HERE}/_setup.sh"
# Keep the real state files untouched.
POD_ID_FILE="${T}/pod-id"
HOSTS_FILE="${T}/hosts"
PAUSED_FILE="${T}/paused"

rp_template_image()       { echo "${RUNPOD_IMAGE}"; }
rp_resolve_alive_pod_id() { :; }
rp_template_id()          { echo "tpl-test"; }
rp_datacenter_ids_json()  { echo "[]"; }
rp_all_datacenter_ids_json() { echo '["US-KS-2","US-TX-3"]'; }
_terminate_pod()          { echo "$1" >> "${T}/terminated"; }
# the host a created pod lands on comes from its create response here; the
# fallback GET would consume the scripted create sequence
rp_pod_placement()        { printf '%s\t%s\t%s\n' "$(cat "${T}/host" 2>/dev/null)" GPU-A US-KS-2; }
# ${T}/boots holds one _wait_ready exit code per boot (default 0, i.e. up)
_wait_ready() {
  local n rc
  n=$(( $(<"${T}/waits") + 1 )); echo "${n}" > "${T}/waits"
  rc=$(sed -n "${n}p" "${T}/boots" 2>/dev/null); rc="${rc:-0}"
  [[ "${rc}" -eq 0 ]] && echo "$1" > "${T}/ready"
  return "${rc}"
}

# cmd_start reads _rp_raw through $(...), a subshell, so the create counter and
# the scripted sequence live in files. ${T}/seq holds one "<http> <body>" line
# per create attempt; running past its end returns a hard error.
_rp_raw() {
  local n line
  n=$(( $(<"${T}/creates") + 1 ))
  echo "${n}" > "${T}/creates"
  line=$(sed -n "${n}p" "${T}/seq")
  [[ -n "${line}" ]] || line='599 {"title":"mock sequence exhausted"}'
  printf '%s\n%s' "${line#* }" "${line%% *}"
}

OK='201 {"id":"pod-test","dataCenterId":"US-TX-3","cost":0.69}'
CAP='400 {"title":"Bad Request","detail":"There are no longer any instances available with the requested specifications. Please refresh and try again."}'
E401='401 {"title":"Unauthorized"}'
E403='403 {"title":"Forbidden","detail":"You do not have permission to perform this action."}'

RUNPOD_GPU_TYPES="GPU-A|GPU-B"
RUNPOD_ALLOC_RETRY_DELAY=0
# the vCPU preference adds a walk; its own cases are at the end
RUNPOD_MIN_VCPU_PER_GPU=""

# run_start <retries|unset> <result>... : one cmd_start against the scripted
# results. Sets RESULT (success/hardfail/exhausted/other) and CREATES.
run_start() {
  if [[ "$1" == "unset" ]]; then unset RUNPOD_ALLOC_RETRIES; else RUNPOD_ALLOC_RETRIES="$1"; fi
  shift
  printf '%s\n' "$@" > "${T}/seq"
  echo 0 > "${T}/creates"
  echo 0 > "${T}/waits"
  rm -f "${T}/ready" "${POD_ID_FILE}" "${T}/terminated"
  ( set -e; cmd_start ) > "${T}/out" 2>&1
  local rc=$?
  CREATES=$(<"${T}/creates")
  if [[ "${rc}" -eq 0 && "$(cat "${T}/ready" 2>/dev/null)" == "pod-test" \
        && "$(cat "${POD_ID_FILE}" 2>/dev/null)" == "pod-test" ]]; then
    RESULT="success"
  elif [[ "${rc}" -ne 0 ]] && grep -q "pod create failed (non-capacity" "${T}/out"; then
    RESULT="hardfail"
  elif [[ "${rc}" -ne 0 ]] && grep -q "no capacity on any GPU after retries" "${T}/out"; then
    RESULT="exhausted"
  else
    RESULT="other"
  fi
}

# rep <n> <result> : the result n times, one per line.
rep() { local i; for (( i=0; i<$1; i++ )); do printf '%s\n' "$2"; done; }

pass=0; fail=0
expect() {  # desc expected_result expected_creates
  local desc="$1" exp_res="$2" exp_creates="$3"
  if [[ "${RESULT}" == "${exp_res}" && "${CREATES}" == "${exp_creates}" ]]; then
    pass=$((pass+1)); printf '  ok   %s\n' "${desc}"
  else
    fail=$((fail+1)); printf '  FAIL %s (result=%s/%s creates=%s/%s)\n' \
      "${desc}" "${RESULT}" "${exp_res}" "${CREATES}" "${exp_creates}"
  fi
}

# success on the first GPU → exactly 1 create, pod id cached, readiness wait runs
run_start 3 "${OK}"
expect "success first try → 1 create" success 1

# capacity on GPU-A, GPU-B lands in the same walk → 2 creates
run_start 3 "${CAP}" "${OK}" "${CAP}"
expect "capacity, next GPU lands → 2 creates" success 2

# a whole walk out of capacity, GPU-A lands on the first retry → 3 creates, stops
run_start 3 "${CAP}" "${CAP}" "${OK}" "${CAP}"
expect "success on the retry walk → stops, 3 creates" success 3

# all capacity, retries=2 → 3 walks x 2 GPUs = 6 creates, exhausted
mapfile -t seq < <(rep 6 "${CAP}")
run_start 2 "${seq[@]}"
expect "exhausted after retries=2 → 6 creates" exhausted 6

# retries=0 → a single walk, 2 creates, then give up
run_start 0 "${CAP}" "${CAP}" "${CAP}"
expect "retries=0 → single walk, 2 creates" exhausted 2

# hard error (401) on GPU-A → fail fast: GPU-B never tried, no retry walk
run_start 5 "${E401}" "${OK}"
expect "hard 401 → fail fast, 1 create" hardfail 1

# capacity on GPU-A, then hard 403 on GPU-B → abort mid-walk, no retry walk
run_start 5 "${CAP}" "${E403}" "${OK}"
expect "capacity then hard 403 → fail fast, 2 creates" hardfail 2

# RUNPOD_ALLOC_RETRIES unset → pod.sh's default 6 → 7 walks x 2 GPUs = 14
mapfile -t seq < <(rep 14 "${CAP}")
run_start unset "${seq[@]}" "${OK}"
expect "retries unset → default 6, 14 creates" exhausted 14

# ---- stuck machines -------------------------------------------------------
# a create answer that carries the machine it landed on
landed() { printf '201 {"id":"pod-test","dataCenterId":"%s","cost":0.82,"gpu":{"id":"%s"},"ssh":{"proxy":{"username":"pod-test-%s"}}}' "$1" "$2" "$3"; }
# payload_of <n> : the n-th create body the loop sent
payload_of() { sed -n "$1p" "${T}/payloads"; }
_rp_raw_scripted="$(declare -f _rp_raw)"
_rp_raw() {
  [[ "$1" == POST && "$2" == /pods ]] && printf '%s\n' "$3" >> "${T}/payloads"
  eval "${_rp_raw_scripted/_rp_raw/_rp_raw_inner}"
  _rp_raw_inner "$@"
}

# a pod that lands on a machine with a fresh stuck verdict is released, the walk goes on
rm -f "${HOSTS_FILE}" "${T}/payloads" "${T}/boots"
printf 'badhost\tbad\t%s\tGPU-Z\tUS-OTHER\n' "$(date +%s)" > "${HOSTS_FILE}"
run_start 0 "$(landed US-KS-2 GPU-A badhost)" "$(landed US-TX-3 GPU-B goodhost)"
if [[ "${RESULT}" == success && "${CREATES}" == 2 && "$(cat "${T}/terminated" 2>/dev/null)" == pod-test ]]; then
  pass=$((pass+1)); echo "  ok   lands on a stuck machine → released, next GPU lands"
else
  fail=$((fail+1)); echo "  FAIL lands on a stuck machine (result=${RESULT} creates=${CREATES})"
fi

# a stuck (GPU-A, US-KS-2) pair is placed outside US-KS-2; GPU-B keeps the full list
rm -f "${HOSTS_FILE}" "${T}/payloads"
printf 'badhost\tbad\t%s\tGPU-A\tUS-KS-2\n' "$(date +%s)" > "${HOSTS_FILE}"
rp_datacenter_ids_json() { echo '["US-KS-2","US-TX-3"]'; }
run_start 0 "${CAP}" "${OK}"
if [[ "$(payload_of 1)" == *'"GPU-A"'* && "$(payload_of 1)" == *'"dataCenterIds": ["US-TX-3"]'* \
      && "$(payload_of 2)" == *'"dataCenterIds": ["US-KS-2", "US-TX-3"]'* ]]; then
  pass=$((pass+1)); echo "  ok   stuck pair → that data center left out for that GPU only"
else
  fail=$((fail+1)); echo "  FAIL stuck pair steering: $(payload_of 1) / $(payload_of 2)"
fi

# the stuck pair's only data center → GPU-A skipped without a create
rm -f "${T}/payloads"
rp_datacenter_ids_json() { echo '["US-KS-2"]'; }
run_start 0 "${OK}"
if [[ "${RESULT}" == success && "${CREATES}" == 1 && "$(payload_of 1)" == *'"GPU-B"'* ]]; then
  pass=$((pass+1)); echo "  ok   stuck pair in its only data center → GPU skipped"
else
  fail=$((fail+1)); echo "  FAIL stuck pair skip (result=${RESULT} creates=${CREATES} $(payload_of 1))"
fi
rp_datacenter_ids_json() { echo "[]"; }

# preferred countries out → the same walk tries every country (no dataCenterIds)
rm -f "${HOSTS_FILE}" "${T}/payloads"
rp_datacenter_ids_json() { echo '["US-TX-3"]'; }
RUNPOD_COUNTRY_FALLBACK=1 run_start 0 "${CAP}" "${CAP}" "${OK}"
if [[ "${RESULT}" == success && "${CREATES}" == 3 && "$(payload_of 2)" == *'"dataCenterIds": ["US-TX-3"]'* \
      && "$(payload_of 3)" != *dataCenterIds* ]]; then
  pass=$((pass+1)); echo "  ok   preferred countries out → every country in the same walk"
else
  fail=$((fail+1)); echo "  FAIL country fallback (result=${RESULT} creates=${CREATES}: $(payload_of 3))"
fi

# without the fallback the walk stays in the preferred countries
rm -f "${T}/payloads"
RUNPOD_COUNTRY_FALLBACK=0 run_start 0 "${CAP}" "${CAP}" "${OK}"
if [[ "${RESULT}" == exhausted && "${CREATES}" == 2 ]]; then
  pass=$((pass+1)); echo "  ok   no fallback → stays in the preferred countries"
else
  fail=$((fail+1)); echo "  FAIL no fallback (result=${RESULT} creates=${CREATES})"
fi
rp_datacenter_ids_json() { echo "[]"; }

# a container that never starts → machine recorded as stuck, pod re-placed and up
rm -f "${HOSTS_FILE}" "${T}/payloads"
echo stuckhost > "${T}/host"
printf '3\n0\n' > "${T}/boots"
run_start 0 "${OK}" "$(landed US-TX-3 GPU-A goodhost)"
if [[ "${RESULT}" == success && "${CREATES}" == 2 && "$(cut -f1,2 "${HOSTS_FILE}" 2>/dev/null)" == $'stuckhost\tbad' ]]; then
  pass=$((pass+1)); echo "  ok   container never starts → machine recorded, pod re-placed"
else
  fail=$((fail+1)); echo "  FAIL watchdog re-place (result=${RESULT} creates=${CREATES} hosts=$(cat "${HOSTS_FILE}" 2>/dev/null))"
fi

# every boot stuck → gives up after RUNPOD_BOOT_RETRIES + 1 machines
rm -f "${HOSTS_FILE}"
printf '3\n3\n3\n' > "${T}/boots"
RUNPOD_BOOT_RETRIES=2 run_start 0 "${OK}" "$(landed US-TX-3 GPU-A host2)" "$(landed US-TX-3 GPU-A host3)"
if [[ "${CREATES}" == 3 ]] && grep -q "machines in a row never started" "${T}/out"; then
  pass=$((pass+1)); echo "  ok   every machine stuck → gives up after 3 boots"
else
  fail=$((fail+1)); echo "  FAIL boot retries (creates=${CREATES})"
fi
rm -f "${T}/host" "${T}/boots"

# ---- vCPU preference ------------------------------------------------------
# first walk asks for the vCPU floor; a host that has it lands with no fallback
rm -f "${T}/payloads" "${HOSTS_FILE}"
RUNPOD_MIN_VCPU_PER_GPU=32
run_start 0 "${CAP}" "${OK}"
if [[ "${RESULT}" == success && "${CREATES}" == 2 && "$(payload_of 1)" == *'"minVcpuCountPerGpu": 32'* && "$(payload_of 2)" == *'"minVcpuCountPerGpu": 32'* ]]; then
  pass=$((pass+1)); echo "  ok   vCPU floor asked first, lands with it"
else
  fail=$((fail+1)); echo "  FAIL vCPU floor first (result=${RESULT} creates=${CREATES})"
fi

# the floor is free again on a later walk → it lands with the floor, no fallback
rm -f "${T}/payloads"
RUNPOD_MIN_VCPU_WALKS=3 RUNPOD_MIN_VCPU_STRICT=1
run_start 0 "${CAP}" "${CAP}" "${CAP}" "${OK}"
if [[ "${RESULT}" == success && "${CREATES}" == 4 && "$(payload_of 4)" == *'"minVcpuCountPerGpu": 32'* ]] && ! grep -q "placing the pod on any host" "${T}/out"; then
  pass=$((pass+1)); echo "  ok   floor free on a later walk → lands with it"
else
  fail=$((fail+1)); echo "  FAIL floor on a later walk (result=${RESULT} creates=${CREATES} $(payload_of 4))"
fi

# no host with the floor for RUNPOD_MIN_VCPU_WALKS walks, not strict → one walk
# without it, the floor walks not counted as retries
rm -f "${T}/payloads"
RUNPOD_MIN_VCPU_WALKS=2 RUNPOD_MIN_VCPU_STRICT=0
run_start 0 "${CAP}" "${CAP}" "${CAP}" "${CAP}" "${CAP}" "${OK}"
if [[ "${RESULT}" == success && "${CREATES}" == 6 && "$(payload_of 5)" != *minVcpuCountPerGpu* ]] && grep -q "placing the pod on any host" "${T}/out"; then
  pass=$((pass+1)); echo "  ok   no host with the floor, not strict → falls back to any host"
else
  fail=$((fail+1)); echo "  FAIL vCPU fallback (result=${RESULT} creates=${CREATES} $(payload_of 5))"
fi

# strict → gives up after the floor walks instead of taking fewer vCPUs
rm -f "${T}/payloads"
RUNPOD_MIN_VCPU_WALKS=2 RUNPOD_MIN_VCPU_STRICT=1
run_start 0 "${CAP}" "${CAP}" "${CAP}" "${CAP}" "${OK}"
if [[ "${CREATES}" == 4 && ! -f "${T}/ready" ]] && grep -q "not settling for fewer" "${T}/out"; then
  pass=$((pass+1)); echo "  ok   no host with the floor, strict → gives up, no pod"
else
  fail=$((fail+1)); echo "  FAIL vCPU strict (result=${RESULT} creates=${CREATES})"
fi
RUNPOD_MIN_VCPU_PER_GPU=""

echo
echo "tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
