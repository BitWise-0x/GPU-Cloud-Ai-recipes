#!/usr/bin/env bash
# Tests how `start [list]` picks the GPU list and the vCPU floor (not the live
# API), asserting:
#   - `start` walks RUNPOD_GPU_TYPES with RUNPOD_MIN_VCPU_PER_GPU
#   - `start video` walks RUNPOD_GPU_TYPES_VIDEO with RUNPOD_MIN_VCPU_PER_GPU_VIDEO
#   - a list without its own floor keeps RUNPOD_MIN_VCPU_PER_GPU
#   - an unknown list fails and names the missing variable
#   - a list or floor passed inline wins over pod.env
# Run: ./pod-kit/tests/test_start_lists.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=_setup.sh
source "${HERE}/_setup.sh"

pass=0; fail=0
check() {  # desc condition
  if eval "$2"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s (got %s)\n' "$1" "${GOT:-}"; fi
}

cmd_start() { GOT="${RUNPOD_GPU_TYPES}#${RUNPOD_MIN_VCPU_PER_GPU:-}"; }

# run_list <list> : one cmd_start_list against fresh pod.env values. Sets GOT, RC.
run_list() {
  RUNPOD_GPU_TYPES="GPU-A|GPU-B"
  RUNPOD_MIN_VCPU_PER_GPU=8
  RUNPOD_GPU_TYPES_VIDEO="GPU-V1|GPU-V2"
  RUNPOD_MIN_VCPU_PER_GPU_VIDEO=24
  RUNPOD_GPU_TYPES_CHEAP="GPU-C"
  unset RUNPOD_MIN_VCPU_PER_GPU_CHEAP
  GOT=""
  cmd_start_list "$1" > "${T}/out" 2>&1
  RC=$?
}

_RUNPOD_GPU_TYPES_FROM_CALLER="" _RUNPOD_MIN_VCPU_FROM_CALLER=""

run_list ""
check "start → default list and floor" '[[ ${RC} -eq 0 && "${GOT}" == "GPU-A|GPU-B#8" ]]'

run_list video
check "start video → video list and its floor" '[[ ${RC} -eq 0 && "${GOT}" == "GPU-V1|GPU-V2#24" ]]'

run_list cheap
check "list without its own floor → default floor" '[[ ${RC} -eq 0 && "${GOT}" == "GPU-C#8" ]]'

run_list nope
check "unknown list → fails naming the variable" '[[ ${RC} -ne 0 ]] && grep -q "RUNPOD_GPU_TYPES_NOPE is not set" "${T}/out"'

_RUNPOD_GPU_TYPES_FROM_CALLER=set
run_list video
check "inline list wins over the named list" '[[ ${RC} -eq 0 && "${GOT}" == "GPU-A|GPU-B#24" ]]'
_RUNPOD_GPU_TYPES_FROM_CALLER=""

_RUNPOD_MIN_VCPU_FROM_CALLER=set
run_list video
check "inline floor wins over the list's floor" '[[ ${RC} -eq 0 && "${GOT}" == "GPU-V1|GPU-V2#8" ]]'
_RUNPOD_MIN_VCPU_FROM_CALLER=""

echo
echo "tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
