#!/usr/bin/env bash
# Tests how start runs the pod's end of the Cloudflare Tunnel (not the live pod or
# Cloudflare): ssh runs the remote script locally, with /workspace moved to a temp
# dir and fake cloudflared/pgrep on PATH. Asserts:
#   - a pod whose cloudflared runs and connected is left alone, and no token is
#     read; one that runs but never connected is replaced
#   - otherwise the token reaches the pod's cloudflared through its environment,
#     never its arguments, and nothing is printed
#   - a missing token, a cloudflared that exits, a missing login or a down SSH
#     tunnel each fail with the reason
# Run: ./pod-kit/tests/test_cloudflare_up.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=_setup.sh
source "${HERE}/_setup.sh"
mkdir -p "${T}/bin" "${T}/home/.cloudflared"
touch "${T}/home/.cloudflared/cert.pem"
HOME="${T}/home"
TOKEN=$(printf 't%.0s' $(seq 1 150))

pass=0; fail=0
check() {  # desc condition
  if eval "$2"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi
}

# cloudflared: "tunnel token" on this machine, "tunnel run" on the pod
cat > "${T}/bin/cloudflared" <<EOF
#!/usr/bin/env bash
if [[ "\$2" == token ]]; then
  echo token-read >> "${T}/calls"
  cat "${T}/token" 2>/dev/null
  exit 0
fi
printf '%s\n' "\$*" > "${T}/pod_argv"
printf '%s\n' "\${TUNNEL_TOKEN:-}" > "${T}/pod_token"
if [[ "\$(cat "${T}/mode")" == exit ]]; then
  echo "ERR Unauthorized: Invalid tunnel secret"
  exit 1
fi
touch "${T}/running"
echo "INF Registered tunnel connection connIndex=0"
EOF
printf '#!/usr/bin/env bash\n[[ -f "%s/running" ]]\n' "${T}" > "${T}/bin/pgrep"
printf '#!/usr/bin/env bash\nrm -f "%s/running"\n' "${T}" > "${T}/bin/pkill"
chmod +x "${T}/bin/cloudflared" "${T}/bin/pgrep" "${T}/bin/pkill"
PATH="${T}/bin:${PATH}"

ssh() { local command="${!#}"; bash -c "${command//\/workspace/${T}}"; }
rp_tunnel_is_open() { [[ ! -f "${T}/tunnel_down" ]]; }
reset() { rm -f "${T}/running" "${T}/calls" "${T}/pod_argv" "${T}/pod_token" "${T}/cloudflared.log" "${T}/tunnel_down"; echo ok > "${T}/mode"; printf '%s\n' "${TOKEN}" > "${T}/token"; }

reset
touch "${T}/running"
echo "INF Registered tunnel connection connIndex=0" > "${T}/cloudflared.log"
out=$(rp_cloudflare_up); rc=$?
check "running and connected → left alone, no token read" '[[ ${rc} -eq 0 && -z "${out}" && ! -f "${T}/calls" ]]'

reset
touch "${T}/running"
echo "ERR Unauthorized: Invalid tunnel secret" > "${T}/cloudflared.log"
out=$(rp_cloudflare_up); rc=$?
check "running but never connected → replaced with the real token" '[[ ${rc} -eq 0 && "$(cat "${T}/pod_token")" == "${TOKEN}" ]]'

reset
out=$(rp_cloudflare_up); rc=$?
check "started → exit 0, nothing printed" '[[ ${rc} -eq 0 && -z "${out}" ]]'
check "token reaches the pod in the environment" '[[ "$(cat "${T}/pod_token")" == "${TOKEN}" ]]'
check "token is not in the pod's cloudflared arguments" '! grep -q "${TOKEN}" "${T}/pod_argv"'

reset
: > "${T}/token"
out=$(rp_cloudflare_up); rc=$?
check "no token → fails naming the tunnel" '[[ ${rc} -ne 0 && "${out}" == *"no token for the tunnel test-tunnel"* ]]'

reset
echo exit > "${T}/mode"
out=$(rp_cloudflare_up); rc=$?
check "cloudflared exits → fails with its last log line" '[[ ${rc} -ne 0 && "${out}" == *"Invalid tunnel secret"* ]]'

reset
touch "${T}/tunnel_down"
out=$(rp_cloudflare_up); rc=$?
check "SSH tunnel down → fails, says so" '[[ ${rc} -ne 0 && "${out}" == *"SSH tunnel is down"* ]]'

reset
rm -f "${T}/home/.cloudflared/cert.pem"
out=$(rp_cloudflare_up); rc=$?
check "no Cloudflare login → fails, says how" '[[ ${rc} -ne 0 && "${out}" == *"cloudflared tunnel login"* ]]'

echo
echo "tests: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
