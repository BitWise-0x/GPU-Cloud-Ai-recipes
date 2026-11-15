#!/usr/bin/env bash
# Run one recipe's GPU pod on RunPod.
#
#   pod.sh <recipe-dir> setup          find-or-create the registry auth + template
#   pod.sh <recipe-dir> start [list]   allocate a pod from a GPU list, wait for the app
#   pod.sh <recipe-dir> status         template image, pod state, how to reach it
#   pod.sh <recipe-dir> tunnel         (re)open the SSH tunnel to the app
#   pod.sh <recipe-dir> pause          stop the pod but keep its machine
#   pod.sh <recipe-dir> stop           terminate the pod (billing stops)
#
# The pod publishes only SSH (22/tcp); the app listens on the pod's loopback and
# is reached at http://127.0.0.1:RUNPOD_TUNNEL_PORT through an SSH tunnel, or
# through an optional Cloudflare Tunnel (docs/access.md).
#
# Config is the recipe's pod.env plus the secrets file (runpod/.secrets.env).
# This script never builds images: build.sh does.

set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 || ! -d "${1:-}" ]]; then
  echo "usage: pod.sh <recipe-dir> <command>   (pod.sh <recipe-dir> help)" >&2
  # exit when executed, return when sourced by a test
  return 1 2>/dev/null || exit 1
fi
POD_DIR="$(cd "$1" && pwd)"
shift
export KIT_DIR POD_DIR
# shellcheck source=lib/common.sh
source "${KIT_DIR}/lib/common.sh"

# ---- registry auth: find-or-create the pull credential ----------------------
# Only for a private image: REGISTRY_USER and REGISTRY_TOKEN (a read-only token)
# in the secrets file. A public image needs no auth.
_registry_host() { printf '%s' "${RUNPOD_IMAGE%%/*}"; }

_ensure_registry_auth() {
  local name="${RUNPOD_REGISTRY_AUTH_NAME:-$(_registry_host)-${REGISTRY_USER}-read}"
  local id body
  id=$(rp_find_by_name "/registries" "${name}")
  if [[ -n "${id}" ]]; then
    echo "${id}" > "${AUTH_ID_FILE}"; echo "${id}"; return 0
  fi
  body=$(NAME="${name}" U="${REGISTRY_USER}" T="${REGISTRY_TOKEN}" python3 -c '
import json, os
print(json.dumps({"name": os.environ["NAME"], "username": os.environ["U"], "password": os.environ["T"]}))')
  id=$(rp_post "/registries" "${body}" | jpy .id)
  [[ -z "${id}" ]] && { ui_err "failed to create registry auth '${name}'."; return 1; }
  echo "${id}" > "${AUTH_ID_FILE}"; echo "${id}"
}

cmd_setup() {
  local reg_id=""
  if [[ -n "${REGISTRY_USER:-}" && -n "${REGISTRY_TOKEN:-}" ]]; then
    ui_step "Registry pull auth for $(_registry_host)"
    reg_id=$(_ensure_registry_auth)
    ui_ok "auth id=${reg_id}"
  else
    ui_hint "no REGISTRY_USER/REGISTRY_TOKEN: the image must be public"
  fi

  ui_step "Template '${RUNPOD_TEMPLATE_NAME}' -> ${RUNPOD_IMAGE}"
  # Every variable whose name starts with POD_ENV_PREFIX goes into the template
  # env (e.g. COMFYUI_ for COMFYUI_MAX_UPLOAD_MB).
  local env_json
  env_json=$(PREFIX="${POD_ENV_PREFIX:-}" python3 -c '
import json, os
p = os.environ["PREFIX"]
print(json.dumps({k: v for k, v in os.environ.items() if p and k.startswith(p)}))')

  # v2 template: create takes the full shape; PATCH sends only the mutable
  # fields setup owns. Only SSH is published: startSsh injects the account SSH
  # keys, and the app is reached through the tunnel, never a public port. A
  # volume is a persistent mount, omitted at 0 GB.
  local tpl_create tpl_patch
  tpl_patch=$(REG_ID="${reg_id}" ENV_JSON="${env_json}" python3 -c '
import json, os
body = {
  "image":               os.environ["RUNPOD_IMAGE"],
  "disk":                int(os.environ["RUNPOD_CONTAINER_DISK_GB"]),
  "ports":               ["22/tcp"],
  "env":                 json.loads(os.environ["ENV_JSON"]),
  "startSsh":            True,
  # RunPod turns Jupyter on for a new template by default; these images have none.
  "startJupyter":        False,
  "allowedCudaVersions": [v for v in os.environ.get("RUNPOD_ALLOWED_CUDA_VERSIONS", "").split(",") if v],
}
if os.environ["REG_ID"]:
    body["registry"] = os.environ["REG_ID"]
vol = int(os.environ["RUNPOD_VOLUME_GB"])
if vol:
    body["mounts"] = {"persistent": {"size": vol, "path": "/workspace"}}
print(json.dumps(body))')
  tpl_create=$(TPL_PATCH="${tpl_patch}" python3 -c '
import json, os
body = json.loads(os.environ["TPL_PATCH"])
body.update({"name": os.environ["RUNPOD_TEMPLATE_NAME"], "category": "NVIDIA", "public": False, "serverless": False})
print(json.dumps(body))')

  local tpl_id
  tpl_id=$(rp_find_by_name "/templates" "${RUNPOD_TEMPLATE_NAME}")
  if [[ -n "${tpl_id}" ]]; then
    rp_patch "/templates/${tpl_id}" "${tpl_patch}" >/dev/null
    ui_ok "updated template (id=${tpl_id})"
  else
    tpl_id=$(rp_post "/templates" "${tpl_create}" | jpy .id)
    [[ -z "${tpl_id}" ]] && { ui_err "template create failed."; return 1; }
    ui_ok "created template (id=${tpl_id})"
  fi
  echo "${tpl_id}" > "${TPL_ID_FILE}"
  ui_banner "SETUP DONE" "Start a pod with: pod.sh ${POD_DIR} start"
}

# ---- start: walk the GPU list with allocation retry -------------------------
# `start` walks RUNPOD_GPU_TYPES with RUNPOD_MIN_VCPU_PER_GPU; `start <list>`
# walks RUNPOD_GPU_TYPES_<LIST> with RUNPOD_MIN_VCPU_PER_GPU_<LIST>, falling back
# to RUNPOD_MIN_VCPU_PER_GPU. A list or floor passed inline wins over both.
# RP_START_CMD names the command in the hints that tell you to run it again.
cmd_start_list() {
  local list="${1:-}" upper var floor_var
  RP_START_CMD="start${list:+ ${list}}"
  if [[ -n "${list}" ]]; then
    upper=$(printf '%s' "${list}" | tr '[:lower:]-' '[:upper:]_')
    var="RUNPOD_GPU_TYPES_${upper}"
    floor_var="RUNPOD_MIN_VCPU_PER_GPU_${upper}"
    if [[ -z "${_RUNPOD_GPU_TYPES_FROM_CALLER}" ]]; then
      [[ -n "${!var:-}" ]] || { ui_err "${var} is not set in pod.env"; return 1; }
      RUNPOD_GPU_TYPES="${!var}"
      ui_hint "start ${list}: the ${var} list"
    fi
    if [[ -z "${_RUNPOD_MIN_VCPU_FROM_CALLER}" && -n "${!floor_var+set}" ]]; then
      RUNPOD_MIN_VCPU_PER_GPU="${!floor_var}"
    fi
  fi
  [[ -n "${RUNPOD_GPU_TYPES:-}" ]] || { ui_err "RUNPOD_GPU_TYPES is not set in pod.env"; return 1; }
  cmd_start
}

cmd_start() {
  local existing rc tpl_image
  tpl_image=$(rp_template_image)
  if [[ "${tpl_image}" != "${RUNPOD_IMAGE}" ]]; then
    ui_err "the template points at '${tpl_image:-nothing}', pod.env at '${RUNPOD_IMAGE}'."
    ui_more "Run: pod.sh ${POD_DIR} setup"
    return 1
  fi
  existing=$(rp_resolve_alive_pod_id)
  if [[ -n "${existing}" ]]; then
    local running; running=$(rp_running_image "${existing}")
    if [[ "${running}" != "${RUNPOD_IMAGE}" ]]; then
      ui_err "REFUSING: pod '${RUNPOD_POD_NAME}' (id=${existing}) is alive but runs a different image."
      ui_more "Running: ${running:-<unknown>}"
      ui_more "Wanted:  ${RUNPOD_IMAGE}"
      ui_more "Replace it: pod.sh ${POD_DIR} stop && pod.sh ${POD_DIR} ${RP_START_CMD:-start}"
      return 1
    fi
    ui_step "Pod '${RUNPOD_POD_NAME}' already running the current image (id=${existing})"
    rc=0; _wait_ready "${existing}" || rc=$?
    [[ "${rc}" -ne 3 ]] && return "${rc}"
    _release_stuck_pod "${existing}"
  fi
  _resume_paused && return 0
  local tpl_id; tpl_id=$(rp_template_id)

  local cuda_json dc_json
  cuda_json=$(CUDA="${RUNPOD_ALLOWED_CUDA_VERSIONS:-}" python3 -c '
import json, os
v = [x for x in os.environ["CUDA"].split(",") if x]
print(json.dumps(v))')
  dc_json=$(rp_datacenter_ids_json)

  # a machine that never starts the container is released and the pod placed
  # again elsewhere, up to RUNPOD_BOOT_RETRIES times
  local boot_retries="${RUNPOD_BOOT_RETRIES:-2}" boot
  for (( boot=0; boot<=boot_retries; boot++ )); do
    _allocate "${tpl_id}" "${cuda_json}" "${dc_json}" || return 1
    rc=0; _wait_ready "${ALLOC_POD_ID}" || rc=$?
    [[ "${rc}" -ne 3 ]] && return "${rc}"
    _release_stuck_pod "${ALLOC_POD_ID}"
  done
  ui_err "no pod booted: $((boot_retries + 1)) machines in a row never started the container."
  ui_more "RunPod may be degraded: https://uptime.runpod.io"
  return 1
}

# _allocate <template id> <cuda json> <data center json> : walk the GPU list
# with allocation retry; sets ALLOC_POD_ID. A (GPU, data center) pair that
# recently held a stuck machine is placed outside that data center, and a pod
# that still lands on a known stuck machine is released at once.
_allocate() {
  local tpl_id="$1" cuda_json="$2" dc_json="$3" avoid all_dc_json="[]" scope
  ALLOC_POD_ID=""
  # RUNPOD_COUNTRY_CODES first; with RUNPOD_COUNTRY_FALLBACK=1 each walk then
  # tries every country before it waits, so a free host abroad is taken in the
  # same walk rather than after every walk at home came up empty
  local -a scopes=("${dc_json}")
  if [[ "${RUNPOD_COUNTRY_FALLBACK:-}" == 1 && "${dc_json}" != "[]" ]]; then
    scopes+=("[]")
  fi
  avoid=$(rp_bad_placements)
  if [[ -n "${avoid}" && ( "${dc_json}" == "[]" || ${#scopes[@]} -gt 1 ) ]]; then
    all_dc_json=$(rp_all_datacenter_ids_json) || all_dc_json="[]"
  fi
  [[ -n "${avoid}" ]] && ui_hint "avoiding machines that never started a pod: $(printf '%s' "${avoid}" | tr '\t\n' '@ ' )"

  local -a gpu_list
  IFS='|' read -r -a gpu_list <<< "${RUNPOD_GPU_TYPES}"

  local retries="${RUNPOD_ALLOC_RETRIES:-6}" delay="${RUNPOD_ALLOC_RETRY_DELAY:-20}"
  # the vCPU floor is asked for RUNPOD_MIN_VCPU_WALKS walks first, which do not
  # count as retries; then the normal walks place the pod anywhere, or with
  # RUNPOD_MIN_VCPU_STRICT=1 start gives up instead
  local min_vcpu="${RUNPOD_MIN_VCPU_PER_GPU:-}" floor_walks="${RUNPOD_MIN_VCPU_WALKS:-9}" floor_walk=0 attempt
  for (( attempt=0; attempt<=retries; attempt++ )); do
    if [[ -n "${min_vcpu}" ]]; then
      ui_hint "first choice: hosts with at least ${min_vcpu} vCPUs per GPU"
    fi
    for scope in "${scopes[@]}"; do
      if [[ "${scope}" == "[]" && "${dc_json}" != "[]" ]]; then
        ui_hint "nothing free in ${RUNPOD_COUNTRY_CODES:-the preferred countries}; trying every country (RUNPOD_COUNTRY_FALLBACK=1)"
      fi
      for gpu in "${gpu_list[@]}"; do
        [[ -z "${gpu// }" ]] && continue
        local payload
        payload=$(TPL_ID="${tpl_id}" GPU_TRY="${gpu}" CUDA_JSON="${cuda_json}" DC_JSON="${scope}" ALL_DC_JSON="${all_dc_json}" AVOID="${avoid}" MIN_VCPU="${min_vcpu}" python3 -c '
import json, os, sys
gpu = {"id": os.environ["GPU_TRY"], "count": 1}
cuda = json.loads(os.environ["CUDA_JSON"])
if cuda: gpu["allowedCudaVersions"] = cuda
if os.environ["MIN_VCPU"]: gpu["minVcpuCountPerGpu"] = int(os.environ["MIN_VCPU"])
body = {
  "name":       os.environ["RUNPOD_POD_NAME"],
  "templateId": os.environ["TPL_ID"],
  "gpu":        gpu,
  "disk":       int(os.environ["RUNPOD_CONTAINER_DISK_GB"]),
  "cloud":      os.environ["RUNPOD_CLOUD_TYPE"],
  "ports":      ["22/tcp"],
  "startSsh":   True,
}
dcs = json.loads(os.environ["DC_JSON"])
avoid_dcs = {line.split("\t")[1] for line in os.environ["AVOID"].splitlines() if line.split("\t")[0] == os.environ["GPU_TRY"]}
base_dcs = dcs or json.loads(os.environ["ALL_DC_JSON"])
if avoid_dcs and base_dcs:
    dcs = [dc for dc in base_dcs if dc not in avoid_dcs]
    if not dcs:
        sys.exit(0)
if dcs: body["dataCenterIds"] = dcs
print(json.dumps(body))')
        if [[ -z "${payload}" ]]; then
          ui_miss "${gpu}: skipped, its data centers only hold a machine that never started a pod"
          continue
        fi
        ui_step "Trying ${gpu} (attempt $((attempt+1))/$((retries+1)))"
        local resp http
        resp=$(_rp_raw POST "/pods" "${payload}")
        http="${resp##*$'\n'}"
        resp="${resp%$'\n'*}"
        if [[ "${http}" == 2* ]]; then
          local pod_id host
          pod_id=$(printf '%s' "${resp}" | jpy .id)
          host=$(printf '%s' "${resp}" | rp_placement_from_json "${pod_id}" | cut -f1)
          [[ -z "${host}" ]] && host=$(rp_pod_placement "${pod_id}" | cut -f1)
          if rp_host_is_bad "${host}"; then
            ui_miss "${gpu}: landed on machine ${host}, which never started a pod earlier; releasing it"
            _terminate_pod "${pod_id}" || true
            continue
          fi
          ui_ok "allocated pod $(ui_hl "${pod_id}") on ${gpu} in $(printf '%s' "${resp}" | jpy .dataCenterId) at $(ui_hl "\$$(printf '%s' "${resp}" | jpy .cost)/hr"), $(printf '%s' "${resp}" | jpy .gpu.vcpuCount) vCPUs${host:+ (machine ${host})}"
          echo "${pod_id}" > "${POD_ID_FILE}"
          ALLOC_POD_ID="${pod_id}"
          return 0
        fi
        local err; err=$(printf '%s' "${resp}" | _rp_err_text)
        if _rp_is_retryable_err "${err}"; then
          # RunPod's own words, so a filter that matches nothing (vCPU floor, data
          # centers, CUDA versions) reads differently from a sold-out card
          ui_miss "${gpu}: no capacity (RunPod: ${err:0:100}), trying next"
        else
          ui_err "pod create failed (non-capacity, HTTP ${http}): ${err}"
          return 1
        fi
      done
    done
    if [[ -n "${min_vcpu}" ]]; then
      attempt=$((attempt - 1))
      floor_walk=$((floor_walk + 1))
      if (( floor_walk < floor_walks )); then
        ui_hint "no host with ${min_vcpu}+ vCPUs per GPU free yet (walk ${floor_walk}/${floor_walks}); again in ${delay}s"
        sleep "${delay}"
        continue
      fi
      if [[ "${RUNPOD_MIN_VCPU_STRICT:-}" == 1 ]]; then
        ui_err "no host with ${min_vcpu}+ vCPUs per GPU had capacity in ${floor_walks} walks; not settling for fewer (RUNPOD_MIN_VCPU_STRICT=1)."
        ui_more "Try again in a few minutes, or take any host now: RUNPOD_MIN_VCPU_PER_GPU= pod.sh ${POD_DIR} ${RP_START_CMD:-start}"
        return 1
      fi
      ui_warn "no host with ${min_vcpu}+ vCPUs per GPU had capacity in ${floor_walks} walks; placing the pod on any host (CPU-heavy jobs run slower on fewer vCPUs)"
      min_vcpu=""
      continue
    fi
    (( attempt < retries )) && { ui_hint "all GPUs out of capacity; retry in ${delay}s"; sleep "${delay}"; }
  done
  ui_err "no capacity on any GPU after retries. Widen RUNPOD_GPU_TYPES or raise RUNPOD_ALLOC_RETRIES."
  return 1
}

# _release_stuck_pod <pod_id> : record the pod's machine as one that never
# started a container, and terminate the pod.
_release_stuck_pod() {
  local pod_id="$1" host gpu dc
  IFS=$'\t' read -r host gpu dc < <(rp_pod_placement "${pod_id}"; echo)
  rp_host_record "${host}" bad "${gpu}" "${dc}"
  ui_warn "machine ${host:-?} (${gpu:-?} in ${dc:-?}) never started the container; releasing pod ${pod_id} and placing it elsewhere"
  _terminate_pod "${pod_id}" || true
}

# _resume_paused : start the pod that pause left, on its own machine (the image
# is already cached there). Exit 0 once it is up; 1 when there is none to resume
# or it cannot run (the image moved on, the machine's GPU is taken, the machine
# is stuck), and the caller allocates a new pod.
_resume_paused() {
  [[ -f "${PAUSED_FILE}" ]] || return 1
  local pod_id pod status image resp http rc
  pod_id=$(<"${PAUSED_FILE}")
  rm -f "${PAUSED_FILE}"
  pod=$(rp_get "/pods/${pod_id}" 2>/dev/null) || { ui_hint "paused pod ${pod_id} is gone; allocating a new one"; return 1; }
  status=$(printf '%s' "${pod}" | jpy .status)
  image=$(printf '%s' "${pod}" | jpy .image)
  if [[ "${status}" != "EXITED" ]]; then
    ui_hint "paused pod ${pod_id} is ${status:-unknown}, not paused; allocating a new one"
    return 1
  fi
  if [[ "${image}" != "${RUNPOD_IMAGE}" ]]; then
    ui_step "Paused pod ${pod_id} runs ${image}, pod.env names a newer image; terminating it"
    _terminate_pod "${pod_id}" || true
    return 1
  fi
  ui_step "Resuming paused pod ${pod_id} on its own machine"
  resp=$(_rp_raw POST "/pods/${pod_id}/action" '{"action":"start"}')
  http="${resp##*$'\n'}"
  if [[ "${http}" != 2* ]]; then
    ui_miss "resume refused (HTTP ${http}: $(printf '%s' "${resp%$'\n'*}" | _rp_err_text)); the machine's GPU is likely taken"
    _terminate_pod "${pod_id}" || true
    return 1
  fi
  echo "${pod_id}" > "${POD_ID_FILE}"
  rc=0; _wait_ready "${pod_id}" || rc=$?
  if [[ "${rc}" -eq 3 ]]; then
    _release_stuck_pod "${pod_id}"
    return 1
  fi
  return 0
}

# _wait_ready <pod_id> : wait until the app answers through the tunnel, showing
# the pod's newest system log line (the image pull) while the container has not
# started. Returns 3 when the machine looks stuck: no new system log line for
# RUNPOD_BOOT_IDLE_TIMEOUT seconds, or no container after RUNPOD_BOOT_TIMEOUT. A
# healthy host shows steady pull progress; a stuck one logs nothing (its log API
# times out) and never starts the container.
_wait_ready() {
  local pod_id="$1" t0=${SECONDS} state url code shown
  local dash="https://www.runpod.io/console/pods/${pod_id}"
  local boot_timeout="${RUNPOD_BOOT_TIMEOUT:-900}" idle_timeout="${RUNPOD_BOOT_IDLE_TIMEOUT:-240}"
  local t_activity=${SECONDS} last_ts="" log_entry log_ts

  # A cold boot is dominated by the image pull when the models are baked in.
  # 200 x 5 s is about 16 min, enough for a slow app start once the container
  # runs; a warm restart answers in the first few.
  ui_step "Waiting for the app (a cold boot pulls the image; the pull shows below)"
  for _ in $(seq 1 200); do
    state=$(rp_pod_runtime_state "${pod_id}")
    url=$(rp_app_url "${pod_id}")
    code="---"
    shown="pod ${state:-?}, waiting for SSH"
    if [[ -z "${url}" && "${state}" == *"not started"* ]]; then
      log_entry=$(rp_pod_system_log_last "${pod_id}")
      log_ts="${log_entry%%$'\t'*}"
      if [[ -n "${log_ts}" && "${log_ts}" != "${last_ts}" ]]; then
        last_ts="${log_ts}"
        t_activity=${SECONDS}
      fi
      if [[ -n "${log_entry}" ]]; then
        shown="pulling: ${log_entry#*$'\t'}"
        shown="${shown:0:90}"
      else
        shown="container not started, no system log yet"
      fi
    fi
    if [[ -n "${url}" ]]; then
      code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "${url}" 2>/dev/null || echo "000")
      shown="tunnel open, app HTTP ${code}"
    fi
    ui_progress "$(printf '%3ds' $((SECONDS - t0)))  ${shown}"
    if [[ "${code}" == "200" || "${code}" == "302" ]]; then
      ui_progress_end
      local host gpu dc
      IFS=$'\t' read -r host gpu dc < <(rp_pod_placement "${pod_id}"; echo)
      rp_host_record "${host}" good "${gpu}" "${dc}"
      _check_public_ports "${pod_id}"
      rp_tunnel_watch_start "${pod_id}"
      local public_lines=() cloudflare_error banner_lines=() pod_banner
      if [[ -n "${CF_PUBLIC_HOSTNAME:-}" && -n "${CF_TUNNEL_NAME:-}" ]]; then
        ui_step "Starting the pod's Cloudflare Tunnel"
        if cloudflare_error=$(rp_cloudflare_up); then
          ui_ok "Cloudflare tunnel connected"
          public_lines=("$(ui_hl "https://${CF_PUBLIC_HOSTNAME}")  through Cloudflare (Access login)" "")
        else
          ui_warn "Cloudflare tunnel not up: ${cloudflare_error:-no reason given}. The SSH tunnel below works;"
          ui_more "the watcher retries every minute (pod.sh <dir> status shows it)."
        fi
      fi
      # a start.sh can leave one line about itself in /workspace/.pod-banner
      pod_banner=$(ssh -S "$(_rp_tunnel_sock)" rp 'cat /workspace/.pod-banner 2>/dev/null' </dev/null 2>/dev/null || true)
      [[ -n "${pod_banner}" ]] && banner_lines=("${pod_banner}" "")
      ui_banner "${RUNPOD_POD_NAME} is up" \
        "${banner_lines[@]}" \
        "${public_lines[@]}" \
        "$(ui_hl "${url}")  through SSH, on this machine only" \
        "" \
        "A background watcher reopens the SSH tunnel if it drops or jams." \
        "Pause (keeps this machine for the next start): pod.sh ${POD_DIR} pause" \
        "Stop the pod and its billing:                  pod.sh ${POD_DIR} stop"
      return 0
    fi
    if [[ -z "${url}" && "${state}" == *"not started"* ]]; then
      if (( SECONDS - t_activity >= idle_timeout )); then
        ui_progress_end
        ui_warn "no image pull progress for ${idle_timeout}s (RUNPOD_BOOT_IDLE_TIMEOUT): the machine looks stuck"
        ui_more "${dash}"
        return 3
      fi
      if (( SECONDS - t0 >= boot_timeout )); then
        ui_progress_end
        ui_warn "the container has not started after ${boot_timeout}s (RUNPOD_BOOT_TIMEOUT): the machine looks stuck"
        ui_more "${dash}"
        return 3
      fi
    fi
    sleep 5
  done
  ui_progress_end
  ui_warn "app not confirmed after ~16 min. The container runs, but the app or the tunnel is not answering."
  ui_more "Check pod.sh <dir> status, and the pod logs: ${dash}"
}

# _check_public_ports <pod_id> : warn loudly if the pod publishes anything but SSH.
_check_public_ports() {
  local pub; pub=$(rp_public_ports "$1" | paste -sd' ' -)
  if [[ "${pub}" == "22/tcp" ]]; then
    ui_ok "public ports: 22/tcp only"
  else
    ui_warn "pod publishes '${pub:-?}', not just 22/tcp. Check the template: pod.sh <dir> setup"
  fi
}

cmd_status() {
  local tpl_image; tpl_image=$(rp_template_image)
  local pod_id; pod_id=$(rp_resolve_pod_id)
  if [[ -z "${pod_id}" ]]; then
    ui_step "No pod found for name '${RUNPOD_POD_NAME}'"
    ui_kv "Template image" "${tpl_image:-no template yet (pod.sh <dir> setup)}"
    return 0
  fi
  local state; state=$(rp_pod_runtime_state "${pod_id}")
  local running; running=$(rp_running_image "${pod_id}")
  ui_kv "Pod" "${RUNPOD_POD_NAME} (id=${pod_id})"
  ui_kv "State" "$(ui_state "${state:-unknown}")"
  ui_kv "Template image" "${tpl_image:-none}"
  ui_kv "Pod image" "${running}"
  if [[ -n "${running}" && "${running}" != "${RUNPOD_IMAGE}" ]]; then
    ui_warn "IMAGE DRIFT: the pod runs ${running}, pod.env names ${RUNPOD_IMAGE}."
    ui_more "setup, then stop + start, to move the pod onto it."
  fi
  rp_print_access "${pod_id}"
}

cmd_tunnel() {
  local pod_id; pod_id=$(rp_resolve_alive_pod_id)
  if [[ -z "${pod_id}" ]]; then
    ui_err "no live pod named '${RUNPOD_POD_NAME}'. Start one: pod.sh ${POD_DIR} start"
    return 1
  fi
  _tunnel_up "${pod_id}"
}

# _tunnel_up <pod_id> : make sure the tunnel and its watcher run. With a watcher
# already up it only waits for the watcher's reconnect: two writers on one
# socket would race.
_tunnel_up() {
  local pod_id="$1"
  if ! rp_tunnel_watching; then
    rp_tunnel_open "${pod_id}" || true
    rp_tunnel_watch_start "${pod_id}"
  fi
  for _ in $(seq 1 6); do
    rp_tunnel_is_open && { ui_ok "tunnel open: $(ui_hl "$(rp_tunnel_url)")"; return 0; }
    sleep 5
  done
  ui_err "could not open the tunnel: the pod's SSH is not up yet, or port ${RUNPOD_TUNNEL_PORT} is taken on this machine."
  rp_tunnel_error | sed 's/^/    ssh: /' >&2
  ui_more "The watcher keeps trying. Check: pod.sh <dir> status"
  return 1
}

rp_running_image() {
  local pod_id="$1"
  [[ -z "${pod_id}" ]] && return 0
  { rp_get "/pods/${pod_id}" 2>/dev/null || true; } | jpy .image
}

# _terminate_pod <pod_id> : delete the pod and wait until the API reports it
# gone. DELETE is async: a 2xx means accepted, not gone, and a half-deleted pod
# still holds the name.
_terminate_pod() {
  local pod_id="$1"
  rp_delete "/pods/${pod_id}" >/dev/null
  rp_wait_gone "${pod_id}" && return 0
  ui_warn "pod ${pod_id} still listed ${RUNPOD_DELETE_WAIT:-180} s after the delete; re-run status, or use"
  ui_more "https://www.runpod.io/console/pods/${pod_id}"
  return 1
}

cmd_pause() {
  local pod_id status; pod_id=$(rp_resolve_alive_pod_id)
  if [[ -z "${pod_id}" ]]; then
    ui_step "No live pod named '${RUNPOD_POD_NAME}', nothing to pause."; return 0
  fi
  rp_tunnel_watch_stop
  ui_step "Pausing pod ${pod_id} (GPU billing stops, the pod keeps its machine)"
  rp_post "/pods/${pod_id}/action" '{"action":"stop"}' >/dev/null
  for _ in $(seq 1 30); do
    status=$({ rp_get "/pods/${pod_id}" 2>/dev/null || true; } | jpy .status)
    [[ "${status}" == "EXITED" ]] && break
    sleep 2
  done
  echo "${pod_id}" > "${PAUSED_FILE}"
  rm -f "${POD_ID_FILE}"
  ui_banner "PAUSED (pod ${pod_id}, ${status:-state unknown})" \
    "start resumes it on the same machine, image cached there." \
    "The container disk is wiped; a volume (RUNPOD_VOLUME_GB) keeps /workspace." \
    "If that machine's GPU is taken by then, start places a new pod instead." \
    "The paused pod still bills for its disk until stop terminates it."
}

cmd_stop() {
  # Target the ALIVE pod, not the first match by name: a stale EXITED pod of the
  # same name can list ahead of the running one, and deleting it would report
  # success while the running pod keeps billing.
  local pod_id; pod_id=$(rp_resolve_alive_pod_id)
  rp_tunnel_watch_stop
  if [[ -z "${pod_id}" && -f "${PAUSED_FILE}" ]]; then
    pod_id=$(<"${PAUSED_FILE}")
    ui_step "Terminating paused pod ${pod_id}"
  elif [[ -z "${pod_id}" ]]; then
    ui_step "No live pod named '${RUNPOD_POD_NAME}', nothing to stop."; return 0
  else
    ui_step "Terminating pod ${pod_id} (billing stops)"
  fi
  rm -f "${PAUSED_FILE}"
  if _terminate_pod "${pod_id}"; then
    ui_ok "confirmed gone."
  fi
  rm -f "${POD_ID_FILE}"
}

usage() {
  cat <<EOF
Usage: pod.sh <recipe-dir> <command>

  setup         find-or-create the registry pull auth (private images) and the
                RunPod template for RUNPOD_IMAGE (idempotent; re-run after an
                image or pod.env change)
  start [list]  allocate a pod from RUNPOD_GPU_TYPES (or RUNPOD_GPU_TYPES_<LIST>)
                and wait until the app answers through the SSH tunnel
                (RUNPOD_GPU_TYPES="A|B" pod.sh <dir> start forces an exact list)
  status        template and pod image, pod state, tunnel URL, ssh/scp, public ports
  tunnel        make sure the SSH tunnel and its watcher run
  pause         stop the pod but keep its machine: no GPU billing, and the next
                start resumes it there with the image cached (container disk wiped)
  stop          terminate the pod (running or paused) and close the tunnel

The pod publishes only SSH. The app is at http://127.0.0.1:RUNPOD_TUNNEL_PORT
through the tunnel that start opens, from a machine whose SSH key is in the
RunPod account. Nothing stops a pod for you: run stop when you are done.
EOF
}

main() {
  local cmd="${1:-help}"
  case "${cmd}" in
    setup)  cmd_setup ;;
    start)  cmd_start_list "${2:-}" ;;
    status) cmd_status ;;
    tunnel) cmd_tunnel ;;
    _watch) rp_tunnel_watch "${2:?pod id}" ;;
    pause)  cmd_pause ;;
    stop)   cmd_stop ;;
    help|-h|--help) usage ;;
    *) ui_err "unknown command: ${cmd}"; usage; exit 1 ;;
  esac
}
main "$@"
