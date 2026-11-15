#!/usr/bin/env bash
# Asserts the GPU lists in every recipe's pod.env.example:
#   - no list holds a duplicate
#   - every video list (RUNPOD_GPU_TYPES_VIDEO, and comfyui-upscale's default
#     list, which only takes video) puts every card with an NVENC encoder before
#     every card without one (A100, H100, H200, B200, B300), and ends on one of
#     those as the last resort
# Run: ./pod-kit/tests/test_gpu_lists.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PODS="${HERE}/../../pods"

pass=0; fail=0
assert() { local d="$1"; shift; if "$@"; then pass=$((pass+1)); echo "  ok   $d"; else fail=$((fail+1)); echo "  FAIL $d"; fi; }

# no_nvenc <gpu> : true for the datacenter cards that have no NVENC engine
no_nvenc() { [[ "$1" =~ A100|H100|H200|B200|B300 ]]; }

nvenc_first() {
  local list="$1" seen_no_nvenc=0 gpu IFS='|'
  read -ra gpus <<< "${list}"
  for gpu in "${gpus[@]}"; do
    if no_nvenc "${gpu}"; then seen_no_nvenc=1; elif (( seen_no_nvenc )); then return 1; fi
  done
}

unique() { [[ "$(tr '|' '\n' <<< "$1" | sort | uniq -d)" == "" ]]; }

# list_of <file> <var> : the quoted literal list, read without sourcing.
list_of() { sed -nE "s/^$2=\"([^\"\$]*)\"\$/\1/p" "$1"; }

for env in "${PODS}"/*/pod.env.example; do
  recipe=$(basename "$(dirname "${env}")")
  while IFS= read -r var; do
    list=$(list_of "${env}" "${var}")
    [[ -z "${list}" ]] && continue
    assert "${recipe} ${var}: no duplicates" unique "${list}"
    if [[ "${var}" == *_VIDEO || "${recipe}/${var}" == comfyui-upscale/RUNPOD_GPU_TYPES ]]; then
      assert "${recipe} ${var}: NVENC cards first" nvenc_first "${list}"
      assert "${recipe} ${var}: ends on a card without NVENC" no_nvenc "${list##*|}"
    fi
  done < <(sed -nE 's/^(RUNPOD_GPU_TYPES[A-Z_]*)=.*/\1/p' "${env}")
done

echo
echo "tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
