#!/usr/bin/env bash
# Shared helpers for pod.sh. Sourced, not executed.
# Loads the pod's pod.env and the secrets file, and exposes the terminal output
# helpers, the SSH tunnel and its watcher, the Cloudflare Tunnel connector, the
# RunPod REST v2 wrapper, the allocation-retry classifier and the host health
# record.
#
# The caller sets POD_DIR (the recipe directory holding pod.env) and KIT_DIR
# (pod-kit/) before sourcing.

: "${POD_DIR:?POD_DIR must be set before sourcing common.sh}"
: "${KIT_DIR:?KIT_DIR must be set before sourcing common.sh}"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "ERROR: pod.sh needs bash 4.4 or newer (macOS: brew install bash)" >&2
  exit 1
fi

# Config: pod.env (per recipe) then the secrets file (shared, gitignored).
# Caller-exported RUNPOD_*, REGISTRY_*, CF_*, POD_* and POD_ENV_PREFIX variables
# win over both files, so one-run overrides like
# `RUNPOD_GPU_TYPES="NVIDIA L40S" ./pod.sh <dir> start` work. They are restored
# after sourcing because the prefix is known only once pod.env is loaded.
declare -A _CALLER_ENV=()
for _v in $(compgen -e); do
  _CALLER_ENV["${_v}"]="${!_v}"
done
# Lets `start <list>` keep an exact list or vCPU floor the caller passed inline.
export _RUNPOD_GPU_TYPES_FROM_CALLER="${_CALLER_ENV[RUNPOD_GPU_TYPES]+set}"
export _RUNPOD_MIN_VCPU_FROM_CALLER="${_CALLER_ENV[RUNPOD_MIN_VCPU_PER_GPU]+set}"

[[ -f "${POD_DIR}/pod.env" ]] || {
  echo "ERROR: ${POD_DIR}/pod.env not found (copy pod.env.example to pod.env and edit it)" >&2
  exit 1
}
SECRETS_FILE="${RUNPOD_SECRETS_FILE:-${KIT_DIR}/../.secrets.env}"

set -a
# shellcheck disable=SC1091
source "${POD_DIR}/pod.env"
# shellcheck disable=SC1090
[[ -f "${SECRETS_FILE}" ]] && source "${SECRETS_FILE}"
set +a

for _v in "${!_CALLER_ENV[@]}"; do
  case "${_v}" in
    RUNPOD_*|REGISTRY_*|CF_*|POD_*) export "${_v}=${_CALLER_ENV[$_v]}" ;;
    *) if [[ -n "${POD_ENV_PREFIX:-}" && "${_v}" == "${POD_ENV_PREFIX}"* ]]; then
         export "${_v}=${_CALLER_ENV[$_v]}"
       fi ;;
  esac
done
unset _v _CALLER_ENV

: "${RUNPOD_IMAGE:?RUNPOD_IMAGE missing from pod.env}"
: "${RUNPOD_POD_NAME:?RUNPOD_POD_NAME missing from pod.env}"
: "${RUNPOD_TEMPLATE_NAME:=${RUNPOD_POD_NAME}}"
: "${POD_APP_PORT:?POD_APP_PORT missing from pod.env}"
: "${RUNPOD_CONTAINER_DISK_GB:=50}"
: "${RUNPOD_VOLUME_GB:=0}"
: "${RUNPOD_CLOUD_TYPE:=SECURE}"
# the request bodies are built by inline python, which reads os.environ
export RUNPOD_TEMPLATE_NAME RUNPOD_CONTAINER_DISK_GB RUNPOD_VOLUME_GB RUNPOD_CLOUD_TYPE

API="https://api.runpod.io/v2"

# State files: one recipe directory, one pod. pod.sh uses them.
# shellcheck disable=SC2034
{
  POD_ID_FILE="${POD_DIR}/.runpod-pod-id"
  TPL_ID_FILE="${POD_DIR}/.runpod-template-id"
  AUTH_ID_FILE="${POD_DIR}/.runpod-registry-auth-id"
  PAUSED_FILE="${POD_DIR}/.runpod-paused-pod-id"
}
# Machines that started or never started a pod, shared by every recipe: a stuck
# machine is stuck whatever the image.
HOSTS_FILE="${RUNPOD_HOSTS_FILE:-${XDG_CACHE_HOME:-${HOME}/.cache}/gpu-cloud-recipes/runpod-hosts}"

# ---- terminal output --------------------------------------------------------
# Colour only when the stream is a terminal and NO_COLOR is unset, so CI logs
# and pipes get plain text. Decided once here: the helpers below paint inside
# $(...), where stdout is always a pipe.
_UI_TTY1=0 _UI_TTY2=0
if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
  [[ -t 1 ]] && _UI_TTY1=1
  [[ -t 2 ]] && _UI_TTY2=1
fi
_ui_on() { if [[ "$1" == 2 ]]; then [[ "${_UI_TTY2}" == 1 ]]; else [[ "${_UI_TTY1}" == 1 ]]; fi; }
# _ui_paint <fd> <sgr> <text> : text in an SGR colour when fd is a terminal.
_ui_paint() {
  if _ui_on "$1"; then printf '\033[%sm%s\033[0m' "$2" "$3"; else printf '%s' "$3"; fi
}
ui_step()  { printf '%s %s\n' "$(_ui_paint 1 '1;36' '==>')" "$(_ui_paint 1 1 "$*")"; }
ui_info()  { printf '    %s\n' "$*"; }
ui_ok()    { printf '    %s %s\n' "$(_ui_paint 1 '1;32' 'ok')" "$*"; }
ui_miss()  { printf '    %s %s\n' "$(_ui_paint 1 33 '--')" "$*"; }
ui_hint()  { printf '    %s\n' "$(_ui_paint 1 2 "$*")"; }
ui_warn()  { printf '%s %s\n' "$(_ui_paint 2 '1;33' 'WARNING:')" "$*" >&2; }
ui_err()   { printf '%s %s\n' "$(_ui_paint 2 '1;31' 'ERROR:')" "$*" >&2; }
ui_more()  { printf '    %s\n' "$*" >&2; }
ui_hl()    { _ui_paint 1 '1;32' "$*"; }
ui_kv()    { printf '  %s  %s\n' "$(_ui_paint 1 2 "$(printf '%-16s' "$1")")" "$2"; }
# ui_state <state> : a pod/container state, green when up, yellow on the way, red otherwise.
ui_state() {
  case "$1" in
    RUNNING|running|open) _ui_paint 1 32 "$1" ;;
    PROVISIONING*|STARTING*|RUNNING\ *|pulling*|closed*) _ui_paint 1 33 "$1" ;;
    *) _ui_paint 1 31 "${1:-unknown}" ;;
  esac
}
# ui_banner <title> [line...] : a ruled box for the result a command exists to produce.
ui_banner() {
  local rule='============================================================' line
  printf '\n%s\n  %s\n' "$(_ui_paint 1 36 "${rule}")" "$(_ui_paint 1 '1;32' "$1")"
  shift
  for line in "$@"; do printf '  %s\n' "${line}"; done
  printf '%s\n' "$(_ui_paint 1 36 "${rule}")"
}
# ui_progress <text> : rewrite the current line (wait loops); ui_progress_end ends it.
ui_progress() {
  if _ui_on 1; then printf '\r\033[K  %s' "$*"; else printf '\r  %s   ' "$*"; fi
}
ui_progress_end() { printf '\n'; }

# ---- SSH tunnel -------------------------------------------------------------
# The pod publishes only 22/tcp and the app listens on the container's
# loopback, so the UI is reachable only through an SSH tunnel from a machine
# whose key is in the RunPod account (RunPod injects those keys as PUBLIC_KEY).
# Each pod's sshd makes fresh host keys at boot, so there is no key to pin:
# the tunnel trusts whatever answers on the pod's mapped SSH port. RunPod's SSH
# proxy (ssh.runpod.io) cannot forward ports, so this needs the direct mapping.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

[[ "${RUNPOD_TUNNEL_PORT:-}" =~ ^[0-9]+$ ]] || {
  ui_err "RUNPOD_TUNNEL_PORT must be a port number (got '${RUNPOD_TUNNEL_PORT:-}')"
  exit 1
}

# rp_ssh_target <pod_id> : "<host> <port>" for the pod's direct SSH mapping
# (its published 22/tcp), or empty if not yet registered.
rp_ssh_target() {
  local pod_id="$1"
  [[ -z "${pod_id}" ]] && return 0
  { rp_get "/pods/${pod_id}" 2>/dev/null || true; } | python3 -c '
import json, sys
try: pod = json.load(sys.stdin)
except Exception: sys.exit(0)
direct = (pod.get("ssh") or {}).get("direct") or {}
if direct.get("host") and direct.get("port"):
    print(direct["host"], direct["port"])
'
}

# One control-master socket per pod name, with files beside it in /tmp (not the
# recipe dir: macOS caps a socket path near 104 bytes):
#   .target   the "<host> <port>" the master points at, so a new pod gets a new tunnel
#   .log      ssh's own log for the current master (-E): why it died
#   .watchlog the watcher's own output (API errors)
#   .events   timestamped drops and reconnects, copied to the pod for the app's log
#   .watch    the watcher's pid
_rp_tunnel_sock() { printf '/tmp/rp-tunnel-%s.sock' "${RUNPOD_POD_NAME}"; }
rp_tunnel_url() { printf 'http://127.0.0.1:%s' "${RUNPOD_TUNNEL_PORT}"; }
# Where the events land inside the pod; an app can tail it into its log view.
RP_POD_EVENTS=/workspace/.tunnel-events.log

rp_tunnel_is_open() {
  local sock; sock=$(_rp_tunnel_sock)
  [[ -S "${sock}" ]] && ssh -S "${sock}" -O check rp >/dev/null 2>&1
}

rp_tunnel_close() {
  local sock; sock=$(_rp_tunnel_sock)
  if [[ -S "${sock}" ]]; then ssh -S "${sock}" -O exit rp >/dev/null 2>&1 || true; fi
  rm -f "${sock}" "${sock}.target"
}

# rp_tunnel_error : the last lines ssh logged for the tunnel (e.g. "Permission
# denied" for a key the pod does not have, or why a live tunnel died), minus the
# known-hosts notice every connect logs.
rp_tunnel_error() {
  grep -v 'Permanently added' "$(_rp_tunnel_sock).log" 2>/dev/null | tail -n 3 || true
}

# rp_tunnel_open <pod_id> : forward 127.0.0.1:RUNPOD_TUNNEL_PORT to the app's
# port inside the pod, reusing a live tunnel to the same pod. Fails while the
# pod's SSH is not up yet, or when something else holds the local port.
# LogLevel=INFO comes first because ssh keeps the first value it sees: at INFO
# the log records "Timeout, server not responding" and resets; stderr goes to the
# same file for the "closed by remote host" notice, which bypasses -E.
# IPQoS=throughput avoids the interactive DSCP marking some routers and Wi-Fi
# mishandle on long transfers. A dead connection is noticed after 3 unanswered
# 5 s keepalives: until ssh notices, it still looks open, every request through
# it hangs, and the watcher cannot reconnect.
rp_tunnel_open() {
  local pod_id="$1" sock target host port
  sock=$(_rp_tunnel_sock)
  target=$(rp_ssh_target "${pod_id}")
  [[ -n "${target}" ]] || return 1
  if rp_tunnel_is_open; then
    [[ "$(cat "${sock}.target" 2>/dev/null)" == "${target}" ]] && return 0
  fi
  rp_tunnel_close
  read -r host port <<< "${target}"
  : > "${sock}.log"
  ssh -o LogLevel=INFO "${SSH_OPTS[@]}" -M -S "${sock}" -fNT -E "${sock}.log" \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
    -o IPQoS=throughput \
    -L "127.0.0.1:${RUNPOD_TUNNEL_PORT}:127.0.0.1:${POD_APP_PORT}" \
    -p "${port}" "root@${host}" </dev/null >/dev/null 2>>"${sock}.log" || return 1
  printf '%s\n' "${target}" > "${sock}.target"
}

# _rp_tunnel_event <text> : append a timestamped line to the local events file.
_rp_tunnel_event() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$(_rp_tunnel_sock).events"
}

# _rp_tunnel_push_events : copy the events file into the pod over the live
# tunnel's connection, so the app's log view can show drops and reconnects.
# Fails when the copy did not land, so the watcher retries it.
_rp_tunnel_push_events() {
  local sock; sock=$(_rp_tunnel_sock)
  [[ -s "${sock}.events" ]] || return 0
  ssh -S "${sock}" rp "cat > ${RP_POD_EVENTS}" < "${sock}.events" >/dev/null 2>&1
}

# rp_tunnel_watch <pod_id> : keep the tunnel up until the pod is gone. Checks the
# master every 5 s (no API call while it is up); when it dies, logs why, reopens
# it as soon as the pod's SSH answers, and pushes the events to the pod. Runs in
# the background from rp_tunnel_watch_start, the only writer of the socket.
#
# A live master can still be jammed one way: uploads stall while the app keeps
# streaming back, so ssh's keepalive never fires and every request through the
# tunnel hangs. The watcher also loads the app page through the tunnel every 15 s;
# three misses in a row (no answer in 30 s) close the master, and it reopens.
rp_tunnel_watch() {
  local pod_id="$1" sock down_since="" reason pushed=-1 lines misses=0 last_probe=0 last_cloudflare=0
  sock=$(_rp_tunnel_sock)
  : > "${sock}.events"
  _rp_tunnel_event "tunnel watcher started for pod ${pod_id}"
  while :; do
    if rp_tunnel_is_open; then
      if [[ -n "${down_since}" ]]; then
        _rp_tunnel_event "tunnel reconnected after $((SECONDS - down_since)) s"
        down_since=""
        misses=0
        last_cloudflare=0
      fi
      # a restarted container lost its cloudflared, and the Cloudflare address with it
      if (( SECONDS - last_cloudflare >= 60 )); then
        last_cloudflare=${SECONDS}
        _rp_watch_cloudflare
      fi
      if (( SECONDS - last_probe >= 15 )); then
        last_probe=${SECONDS}
        if curl -s -o /dev/null --max-time 30 "$(rp_tunnel_url)/" 2>/dev/null; then
          misses=0
        else
          misses=$((misses + 1))
        fi
        if (( misses >= 3 )); then
          _rp_tunnel_event "tunnel jammed: the app did not answer through it three times in a row, reconnecting"
          ssh -S "${sock}" -O exit rp >/dev/null 2>&1 || true
          misses=0
          continue
        fi
      fi
      lines=$(wc -l < "${sock}.events")
      if [[ "${lines}" != "${pushed}" ]]; then
        _rp_tunnel_push_events && pushed=${lines}
      fi
      sleep 5
      continue
    fi
    if [[ -z "${down_since}" ]]; then
      down_since=${SECONDS}
      reason=$(rp_tunnel_error | tail -n 1 | tr -d '\r')
      _rp_tunnel_event "tunnel dropped: ${reason:-no reason logged}"
    fi
    if [[ "$(rp_pod_exists "${pod_id}")" == "no" ]]; then
      _rp_tunnel_event "pod ${pod_id} is gone, watcher exiting"
      rp_tunnel_close
      rm -f "${sock}.watch"
      return 0
    fi
    rp_tunnel_open "${pod_id}" || true
    sleep 5
  done
}

# _rp_watch_cloudflare : the watcher's check of the pod's cloudflared; logs when it
# had to start it again, or why it could not.
_rp_watch_cloudflare() {
  local running reason
  [[ -n "${CF_TUNNEL_NAME:-}" && -n "${CF_PUBLIC_HOSTNAME:-}" ]] || return 0
  running=$(ssh -S "$(_rp_tunnel_sock)" rp 'pgrep -x cloudflared >/dev/null && echo yes' </dev/null 2>/dev/null || true)
  [[ "${running}" == yes ]] && return 0
  if reason=$(rp_cloudflare_up); then
    _rp_tunnel_event "Cloudflare tunnel was not running on the pod, started it again"
  else
    _rp_tunnel_event "Cloudflare tunnel is down and could not start: ${reason}"
  fi
}

rp_tunnel_watching() {
  local pid; pid=$(cat "$(_rp_tunnel_sock).watch" 2>/dev/null || true)
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

# rp_tunnel_watch_start <pod_id> : start the watcher in the background unless one
# is running. It re-runs pod.sh (hidden _watch command) for the same recipe so it
# loads the same config. nohup + closed fds + disown: an inherited pipe would
# hold a caller's $(...) open.
rp_tunnel_watch_start() {
  local pod_id="$1" sock
  sock=$(_rp_tunnel_sock)
  rp_tunnel_watching && return 0
  nohup "${KIT_DIR}/pod.sh" "${POD_DIR}" _watch "${pod_id}" \
    </dev/null >>"${sock}.watchlog" 2>&1 &
  printf '%s\n' "$!" > "${sock}.watch"
  disown "$!" 2>/dev/null || true
}

# rp_tunnel_watch_stop : stop the watcher and the tunnel, and drop their files.
rp_tunnel_watch_stop() {
  local sock pid; sock=$(_rp_tunnel_sock)
  pid=$(cat "${sock}.watch" 2>/dev/null || true)
  if [[ -n "${pid}" ]]; then kill "${pid}" 2>/dev/null || true; fi
  rp_tunnel_close
  rm -f "${sock}.watch" "${sock}.log" "${sock}.watchlog" "${sock}.events"
}

# rp_app_url <pod_id> : the local URL of the app (opening the tunnel if needed),
# or empty when it cannot be opened yet. Always exits 0, for use under set -e.
rp_app_url() {
  if rp_tunnel_open "$1"; then rp_tunnel_url; fi
}

# rp_public_ports <pod_id> : "<private>/<type>" for every port the pod publishes
# on a public IP, one per line. Only 22/tcp is expected. RunPod can add
# 19123/http to a pod on its own (not in the create's ports); nothing in these
# images listens on it, so it is skipped.
rp_public_ports() {
  local pod_id="$1"
  [[ -z "${pod_id}" ]] && return 0
  { rp_get "/pods/${pod_id}" 2>/dev/null || true; } | python3 -c '
import ipaddress, json, sys
try: pod = json.load(sys.stdin)
except Exception: sys.exit(0)
for p in (pod.get("runtime") or {}).get("ports") or []:
    ip = p.get("ip") or ""
    try: public_ip = not ipaddress.ip_address(ip).is_private
    except ValueError: public_ip = False
    if p.get("private") == 19123 and p.get("type") == "http":
        continue
    if p.get("type") == "http" or (public_ip and p.get("public")):
        print("%s/%s" % (p.get("private"), p.get("type")))
'
}

# ---- Cloudflare Tunnel (optional) -------------------------------------------
# With CF_TUNNEL_NAME and CF_PUBLIC_HOSTNAME set, the pod's cloudflared dials
# out to that tunnel and the app is served at https://CF_PUBLIC_HOSTNAME behind
# Cloudflare Access. The pod still publishes only SSH. Setup: docs/access.md.

# rp_cloudflare_connections : how many connections the tunnel holds right now
# (0 while no pod runs cloudflared), or empty when cloudflared or its account
# certificate is not on this machine.
rp_cloudflare_connections() {
  [[ -n "${CF_TUNNEL_NAME:-}" && -f "${HOME}/.cloudflared/cert.pem" ]] || return 0
  command -v cloudflared >/dev/null || return 0
  { cloudflared tunnel info -o json "${CF_TUNNEL_NAME}" 2>/dev/null || true; } | python3 -c '
import json, sys
try: info = json.load(sys.stdin)
except Exception: sys.exit(0)
print(sum(len(c.get("conns") or []) for c in info.get("conns") or []))
'
}

# rp_cloudflare_up : run the pod's end of the Cloudflare Tunnel unless it already
# runs, over the live SSH tunnel. The token goes from this machine's cloudflared
# (its account certificate) through ssh's stdin into cloudflared's environment on
# the pod: never on a command line, in the template or in any output. A container
# restart ends it, so the watcher runs this again. Prints why when it cannot.
rp_cloudflare_up() {
  [[ -n "${CF_TUNNEL_NAME:-}" && -n "${CF_PUBLIC_HOSTNAME:-}" ]] || return 0
  command -v cloudflared >/dev/null || { echo "cloudflared is not installed on this machine"; return 1; }
  [[ -f "${HOME}/.cloudflared/cert.pem" ]] || { echo "this machine has no Cloudflare login (cloudflared tunnel login, once)"; return 1; }
  local sock; sock=$(_rp_tunnel_sock)
  rp_tunnel_is_open || { echo "the SSH tunnel is down"; return 1; }
  # one that runs but never connected (e.g. a bad token) is replaced
  ssh -S "${sock}" rp 'pgrep -x cloudflared >/dev/null && grep -q "Registered tunnel connection" /workspace/cloudflared.log' </dev/null 2>/dev/null && return 0
  { cloudflared tunnel token "${CF_TUNNEL_NAME}" 2>/dev/null || true; } | ssh -S "${sock}" rp \
    'read -r t; [ "${#t}" -gt 100 ] || { echo "no token for the tunnel '"${CF_TUNNEL_NAME}"' (cloudflared tunnel list)"; exit 1; }
    pkill -x cloudflared
    : > /workspace/cloudflared.log
    TUNNEL_TOKEN="$t" nohup cloudflared tunnel --no-autoupdate run >> /workspace/cloudflared.log 2>&1 < /dev/null &
    for _ in $(seq 1 30); do
      sleep 1
      grep -q "Registered tunnel connection" /workspace/cloudflared.log && exit 0
      pgrep -x cloudflared >/dev/null || { echo "cloudflared exited: $(tail -n 1 /workspace/cloudflared.log)"; exit 1; }
    done
    echo "cloudflared runs but registered no connection in 30 s (/workspace/cloudflared.log on the pod)"; exit 1' 2>/dev/null
}

# rp_print_cloudflare : the app's Cloudflare address and whether the tunnel is up.
rp_print_cloudflare() {
  [[ -n "${CF_PUBLIC_HOSTNAME:-}" && -n "${CF_TUNNEL_NAME:-}" ]] || return 0
  local connections; connections=$(rp_cloudflare_connections)
  if [[ -z "${connections}" ]]; then
    ui_kv "Cloudflare" "$(ui_hl "https://${CF_PUBLIC_HOSTNAME}")  (Access login)"
  elif (( connections > 0 )); then
    ui_kv "Cloudflare" "$(ui_hl "https://${CF_PUBLIC_HOSTNAME}")  $(ui_state open)  (${connections} connections, Access login)"
  else
    ui_kv "Cloudflare" "https://${CF_PUBLIC_HOSTNAME}  $(ui_state closed)  (no connection; the pod log is /workspace/cloudflared.log)"
  fi
}

# rp_print_access <pod_id> : how to reach the pod: the Cloudflare address, the
# tunnel URL and whether it is open, the ssh/scp commands, and the ports the pod
# publishes.
rp_print_access() {
  local pod_id="$1" host="" port="" pub
  [[ -z "${pod_id}" ]] && return 0
  rp_print_cloudflare
  read -r host port <<< "$(rp_ssh_target "${pod_id}")"
  if [[ -z "${host}" ]]; then
    ui_kv "UI" "$(ui_state closed)  (the pod's SSH is not up yet)"
    return 0
  fi
  if rp_tunnel_is_open && [[ "$(cat "$(_rp_tunnel_sock).target" 2>/dev/null)" == "${host} ${port}" ]]; then
    ui_kv "UI" "$(ui_hl "$(rp_tunnel_url)")  $(ui_state open)"
  else
    ui_kv "UI" "$(rp_tunnel_url)  $(ui_state closed)  (open: pod.sh <dir> tunnel)"
  fi
  local events drops last
  events="$(_rp_tunnel_sock).events"
  drops=$(grep -c 'tunnel dropped' "${events}" 2>/dev/null || true)
  last=$(grep 'tunnel dropped' "${events}" 2>/dev/null | tail -n 1 || true)
  if rp_tunnel_watching; then
    ui_kv "Watcher" "$(ui_state running)  drops: ${drops:-0}${last:+  (last: ${last})}"
  else
    ui_kv "Watcher" "$(_ui_paint 1 33 'not running')  (pod.sh <dir> tunnel starts it)"
  fi
  ui_kv "SSH" "ssh -p ${port} root@${host}"
  ui_kv "scp" "scp -P ${port} <file> root@${host}:/workspace/"
  pub=$(rp_public_ports "${pod_id}" | paste -sd' ' -)
  case "${pub}" in
    "22/tcp") ui_kv "Public ports" "$(_ui_paint 1 32 '22/tcp only')" ;;
    "")       ui_kv "Public ports" "$(_ui_paint 1 33 'none registered yet')" ;;
    *)        ui_kv "Public ports" "$(_ui_paint 1 '1;31' "${pub}  (only 22/tcp should be public)")" ;;
  esac
}

# ---- RunPod REST wrapper ----------------------------------------------------
# _rp_raw <method> <path> [body] : the response body, then a final line holding
# the HTTP status (000 = no response). Every call goes through here so a rate
# limit (HTTP 429) backs off exponentially instead of reading as a hard failure.
_rp_raw() {
  local method="$1" path="$2" body="${3:-}"
  : "${RUNPOD_API_KEY:?RUNPOD_API_KEY missing (set it in the secrets file)}"
  local args=(-sS -X "${method}" "${API}${path}"
    -H "Content-Type: application/json" --max-time 60
    -w $'\n%{http_code}')
  [[ -n "${body}" ]] && args+=(--data-binary "${body}")
  local resp http delay=2 try
  for try in 1 2 3 4 5 6; do
    # the key reaches curl as a header file from the printf builtin, never as an
    # argument a process listing would show
    resp=$(curl -H @<(printf 'Authorization: Bearer %s\n' "${RUNPOD_API_KEY}") "${args[@]}" 2>/dev/null) || resp=$'\n000'
    http="${resp##*$'\n'}"
    [[ "${http}" == "429" && "${try}" -lt 6 ]] || break
    echo "RunPod API rate limit (HTTP 429) on ${method} ${path}; retrying in ${delay}s" >&2
    sleep "${delay}"
    delay=$((delay * 2))
  done
  printf '%s' "${resp}"
}

# _rp_err_text : the readable part of an error body on stdin (v2 problem JSON:
# title, detail, errors[]), or the raw body if it is not JSON.
_rp_err_text() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except Exception:
    print(raw); sys.exit(0)
if not isinstance(d, dict):
    print(raw); sys.exit(0)
parts = [str(d[k]) for k in ("title", "detail") if d.get(k)]
parts += [str(e) for e in d.get("errors") or []]
print(": ".join(parts) if parts else raw)
'
}

# _rp_call <method> <path> [body] : the body on 2xx; otherwise the error goes to
# stderr and the call returns 1.
_rp_call() {
  local resp http
  resp=$(_rp_raw "$@")
  http="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"
  if [[ "${http}" == 2* ]]; then
    printf '%s' "${resp}"; return 0
  fi
  echo "API $1 $2 -> HTTP ${http}: $(printf '%s' "${resp}" | _rp_err_text)" >&2
  return 1
}
rp_get()    { _rp_call GET    "$1"; }
rp_post()   { _rp_call POST   "$1" "${2:-}"; }
rp_patch()  { _rp_call PATCH  "$1" "${2:-}"; }
# DELETE treats 404 as success: the resource is already gone.
rp_delete() {
  local resp http
  resp=$(_rp_raw DELETE "$1")
  http="${resp##*$'\n'}"
  [[ "${http}" == 2* || "${http}" == "404" ]] && return 0
  echo "API DELETE $1 -> HTTP ${http}: $(printf '%s' "${resp%$'\n'*}" | _rp_err_text)" >&2
  return 1
}

# jpy '<json path>' : read one dotted field from stdin JSON (e.g. jpy .id).
jpy() {
  python3 -c '
import json, sys
path = sys.argv[1].lstrip(".")
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for key in [p for p in path.split(".") if p]:
    if isinstance(data, list):
        try: data = data[int(key)]
        except Exception: sys.exit(0)
    elif isinstance(data, dict):
        data = data.get(key)
    else:
        sys.exit(0)
    if data is None: sys.exit(0)
print(data if not isinstance(data, (dict, list)) else json.dumps(data))
' "$1"
}

# rp_find_by_name <collection-path> <name> : id of the first item named <name>.
# v2 wraps every list ({"pods": [...], "pagination": ...}); the default page of
# 1000 is enough for one account's pods, templates and registry auths.
rp_find_by_name() {
  local path="$1" name="$2"
  rp_get "${path}" | NAME="${name}" python3 -c '
import json, os, sys
name = os.environ["NAME"]
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
items = d if isinstance(d, list) else next((v for v in d.values() if isinstance(v, list)), [])
for it in items:
    if it.get("name") == name:
        print(it.get("id", "")); break
'
}

# rp_template_id : the cached template id, else looked up by name and cached.
# Empty when setup has not run.
rp_template_id() {
  local tpl_id
  if [[ -s "${TPL_ID_FILE}" ]]; then
    cat "${TPL_ID_FILE}"
    return 0
  fi
  tpl_id=$(rp_find_by_name "/templates" "${RUNPOD_TEMPLATE_NAME}")
  [[ -n "${tpl_id}" ]] && printf '%s\n' "${tpl_id}" > "${TPL_ID_FILE}"
  printf '%s' "${tpl_id}"
}

# rp_template_image : the image the template points at, or empty.
rp_template_image() {
  local tpl_id
  tpl_id=$(rp_template_id)
  [[ -z "${tpl_id}" ]] && return 0
  rp_get "/templates/${tpl_id}" | jpy .image
}

# _rp_is_retryable_err <error-text> : exit 0 if the error is a transient
# capacity shortage worth retrying, 1 if it is a hard error (auth, validation).
# v2 answers both capacity and validation with HTTP 400, so the text decides.
_rp_is_retryable_err() {
  local body="$1"
  printf '%s' "${body}" | grep -qiE "no instances|no longer any instances|does not have the resources|no available|not enough|capacity|unavailable|out of stock"
}

# rp_datacenter_ids_json : JSON list of the data centers in RUNPOD_COUNTRY_CODES,
# or [] when unset. v2 pod create has no country filter, only dataCenterIds,
# whose ids lead with the country or region code RUNPOD_COUNTRY_CODES matches
# (US-TX-3, CA-MTL-1, EU-NL-1). dataCenterIds is a hard filter: a data center
# left out is never used, not a fallback.
rp_datacenter_ids_json() {
  local codes="${RUNPOD_COUNTRY_CODES:-}"
  [[ -z "${codes// }" ]] && { echo "[]"; return 0; }
  local ids
  ids=$(rp_get "/catalog/datacenters" | CC="${codes}" python3 -c '
import json, os, sys
codes = {c.strip().upper() for c in os.environ["CC"].split(",") if c.strip()}
d = json.load(sys.stdin)
items = d if isinstance(d, list) else next((v for v in d.values() if isinstance(v, list)), [])
print(json.dumps(sorted(dc["id"] for dc in items if dc.get("id", "").split("-")[0] in codes)))
') || return 1
  if [[ "${ids}" == "[]" ]]; then
    echo "ERROR: no RunPod data center matches RUNPOD_COUNTRY_CODES=${codes}" >&2
    return 1
  fi
  echo "${ids}"
}

# The pod probes below (SSH target, runtime state) run inside wait loops under
# set -e, so an API blip yields empty output, never a non-zero exit that would
# abort a pod that is already billing.

# rp_resolve_pod_id : id of any pod named RUNPOD_POD_NAME (stopped included), or empty.
rp_resolve_pod_id() {
  rp_find_by_name "/pods" "${RUNPOD_POD_NAME}"
}

# rp_resolve_alive_pod_id : id of the pod named RUNPOD_POD_NAME that is running
# or on its way there, or empty. An EXITED pod of the same name does not block
# a new start.
rp_resolve_alive_pod_id() {
  rp_get "/pods" | NAME="${RUNPOD_POD_NAME}" python3 -c '
import json, os, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
alive = {"PROVISIONING", "STARTING", "RUNNING"}
for p in d.get("pods", []):
    if p.get("name") == os.environ["NAME"] and p.get("status") in alive:
        print(p.get("id", "")); break
'
}

# rp_pod_exists <pod_id> : "yes", "no" (404, or listed as TERMINATED while the
# delete settles) or "error". Always exit 0.
rp_pod_exists() {
  local pod_id="$1"
  [[ -z "${pod_id}" ]] && { echo "no"; return 0; }
  local resp http
  resp=$(_rp_raw GET "/pods/${pod_id}")
  http="${resp##*$'\n'}"
  case "${http}" in
    2*)
      if [[ "$(printf '%s' "${resp%$'\n'*}" | jpy .status)" == "TERMINATED" ]]; then
        echo "no"
      else
        echo "yes"
      fi ;;
    404) echo "no" ;;
    *)   echo "error" ;;
  esac
}

# rp_wait_gone <pod_id> : after a DELETE, wait until the pod is gone (404, or
# listed TERMINATED). The pod passes through EXITED while RunPod tears the
# container down, which can outlast 30 s; RUNPOD_DELETE_WAIT (default 180)
# seconds bound the wait. Returns 1 if it is still listed then.
rp_wait_gone() {
  local pod_id="$1" waited=0 limit="${RUNPOD_DELETE_WAIT:-180}"
  while (( waited < limit )); do
    [[ "$(rp_pod_exists "${pod_id}")" == "no" ]] && return 0
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# rp_pod_system_log_last <pod_id> : "<ts>\t<line>" of the pod's newest system log
# line (the image pull, container create and start), or empty when the log API
# does not answer within a few seconds, which is also what it does for a stuck
# machine. The endpoint streams server-sent events; tail backfills the newest
# lines and the short timeout ends the read.
rp_pod_system_log_last() {
  local pod_id="$1"
  [[ -z "${pod_id}" ]] && return 0
  curl -sS -N --max-time 4 -H @<(printf 'Authorization: Bearer %s\n' "${RUNPOD_API_KEY}") \
    "${API}/pods/${pod_id}/logs?source=system&tail=5" 2>/dev/null | python3 -c '
import json, re, sys
last = None
for raw in sys.stdin:
    if raw.startswith("data:"):
        try: last = json.loads(raw[5:].strip())
        except ValueError: pass
if isinstance(last, dict) and last.get("ts"):
    line = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", str(last.get("line", ""))).replace("\r", " ").strip()
    print(str(last["ts"]) + "\t" + line)
' || true
}

# rp_pod_runtime_state <pod_id> : the pod status (PROVISIONING, STARTING,
# RUNNING, EXITED, ERROR, TERMINATED), flagged when RunPod reports RUNNING but
# the container has not started (the host is still pulling, or cannot create
# it), or empty.
rp_pod_runtime_state() {
  local pod_id="$1"
  [[ -z "${pod_id}" ]] && return 0
  { rp_get "/pods/${pod_id}" 2>/dev/null || true; } | python3 -c '
import json, sys
try: pod = json.load(sys.stdin)
except Exception: sys.exit(0)
status = pod.get("status") or ""
if status == "RUNNING" and not pod.get("runtime"):
    status += " (container not started)"
print(status)
'
}

# ---- host health: keep new pods off machines that never start one -----------
# v2 has no machine field and pod create cannot name or exclude a machine. The
# SSH proxy user is "<pod id>-<host id>", and pods placed on the same machine
# carry the same host id, so that suffix identifies the machine. The scheduler
# hands the same machine out again and again, so a machine that never started a
# container is recorded in HOSTS_FILE and steered around by data center for
# RUNPOD_BAD_HOST_HOURS.

# rp_placement_from_json <pod_id> : "<host>\t<gpu>\t<data center>" from the pod
# JSON on stdin (any field may be empty).
rp_placement_from_json() {
  POD="$1" python3 -c '
import json, os, sys
try: pod = json.load(sys.stdin)
except Exception: pod = {}
user = ((pod.get("ssh") or {}).get("proxy") or {}).get("username") or ""
prefix = os.environ["POD"] + "-"
host = user[len(prefix):] if user.startswith(prefix) else ""
print("\t".join([host, (pod.get("gpu") or {}).get("id") or "", pod.get("dataCenterId") or ""]))
'
}

# rp_pod_placement <pod_id> : the same, read from the API.
rp_pod_placement() {
  [[ -z "$1" ]] && return 0
  { rp_get "/pods/$1" 2>/dev/null || true; } | rp_placement_from_json "$1"
}

# rp_host_record <host> <good|bad> <gpu> <data center> : append a verdict.
rp_host_record() {
  [[ -z "$1" ]] && return 0
  mkdir -p "$(dirname "${HOSTS_FILE}")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" "$3" "$4" >> "${HOSTS_FILE}"
}

# _rp_bad_hosts : "<host>\t<gpu>\t<data center>" for every host whose latest
# verdict is bad and younger than RUNPOD_BAD_HOST_HOURS. A later good boot on
# the same host clears it.
_rp_bad_hosts() {
  [[ -f "${HOSTS_FILE}" ]] || return 0
  awk -F '\t' -v now="$(date +%s)" -v ttl="$(( ${RUNPOD_BAD_HOST_HOURS:-6} * 3600 ))" '
    { verdict[$1] = $2; at[$1] = $3; gpu[$1] = $4; dc[$1] = $5 }
    END { for (h in verdict) if (verdict[h] == "bad" && now - at[h] < ttl) print h "\t" gpu[h] "\t" dc[h] }
  ' "${HOSTS_FILE}"
}

# rp_host_is_bad <host> : exit 0 when the host has a fresh bad verdict.
rp_host_is_bad() {
  [[ -n "$1" ]] && _rp_bad_hosts | cut -f1 | grep -qxF "$1"
}

# rp_bad_placements : "<gpu>\t<data center>" pairs to avoid on this start.
rp_bad_placements() {
  _rp_bad_hosts | cut -f2,3 | sort -u
}

# rp_all_datacenter_ids_json : every data center id in the catalog, for
# steering around a bad host when RUNPOD_COUNTRY_CODES does not narrow them.
rp_all_datacenter_ids_json() {
  rp_get "/catalog/datacenters" | python3 -c '
import json, sys
d = json.load(sys.stdin)
items = d if isinstance(d, list) else next((v for v in d.values() if isinstance(v, list)), [])
print(json.dumps(sorted(dc["id"] for dc in items if dc.get("id"))))
'
}
