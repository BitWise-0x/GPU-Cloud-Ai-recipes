#!/usr/bin/env bash
# Unit tests for _rp_is_retryable_err, the classifier that decides whether a
# failed POST /pods is a transient capacity shortage (retry) or a hard error
# (fail fast). It takes the error text only: v2 answers capacity and
# validation both with HTTP 400, so the status is not passed in.
# Run: ./pod-kit/tests/test_retryable_err.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=_setup.sh
source "${HERE}/_setup.sh"

pass=0; fail=0
check() {
  local desc="$1" expected="$2" body="$3"
  local got="no"
  if _rp_is_retryable_err "${body}"; then got="yes"; fi
  if [[ "${got}" == "${expected}" ]]; then
    pass=$((pass+1)); printf '  ok   %s\n' "${desc}"
  else
    fail=$((fail+1)); printf '  FAIL %s (expected=%s got=%s body=%q)\n' \
      "${desc}" "${expected}" "${got}" "${body}"
  fi
}

# --- retryable: capacity messages RunPod returns ---
check "no instances available"          yes "create pod: There are no instances currently available"
check "machine lacks resources"         yes "create pod: This machine does not have the resources to deploy your pod. Please try a different machine"
check "no longer any instances"         yes "create pod: There are no longer any instances available with the requested specifications"
check "v2 400 no longer any instances"  yes "Bad Request: There are no longer any instances available with the requested specifications. Please refresh and try again."

# --- retryable: the classifier's broader patterns, matched case-insensitively ---
check "pattern: case-insensitive"       yes "THERE ARE NO INSTANCES CURRENTLY AVAILABLE"
check "pattern: no available"           yes "no available GPUs of the requested type"
check "pattern: not enough"             yes "not enough free GPUs on the host"
check "pattern: capacity"               yes "insufficient capacity"
check "pattern: unavailable"            yes "GPU type temporarily unavailable"
check "pattern: out of stock"           yes "GPU out of stock"

# --- NOT retryable: hard errors where retrying is pointless/harmful ---
check "401 unauthorized"                no  "Unauthorized"
check "403 forbidden"                   no  "You do not have permission to perform this action."
check "404 template not found"          no  "template not found"
check "400 bad request / validation"    no  "invalid gpuTypeIds"
check "v2 400 schema validation"        no  "Bad Request: request body invalid: \$: additional properties 'gpuTypeIds' not allowed"
check "500 but unknown message"         no  "internal database error: constraint violation"
check "no response (empty body)"        no  ""

echo
echo "tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
