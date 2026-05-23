#!/usr/bin/env bash
set -euo pipefail

CFG="${CFG:-/etc/camilladsp/airpods.yml}"
RUNTIME_ENV="${RUNTIME_ENV:-/etc/default/pi-audio-dongle}"
if [[ -f "$RUNTIME_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$RUNTIME_ENV"
fi

AIRPODS_MAC="${AIRPODS_MAC:-unknown}"
PW_USER="${PW_USER:-${TARGET_USER:-$(id -un)}}"
START_BACKOFF_SEC="${START_BACKOFF_SEC:-1}"
RESTART_BACKOFF_SEC="${RESTART_BACKOFF_SEC:-1}"

PW_UID="$(id -u "$PW_USER" 2>/dev/null || true)"
if [[ -z "$PW_UID" ]]; then
  echo "Unable to resolve PipeWire user '${PW_USER}'" >&2
  exit 1
fi
PW_RUNTIME_DIR="/run/user/${PW_UID}"

log() {
  logger -t run-camilladsp "$*"
  printf '[run-camilladsp] %s\n' "$*"
}

uac2_ready() {
  arecord -l 2>/dev/null | grep -qi 'UAC2Gadget'
}

pipewire_ready() {
  [[ -S "${PW_RUNTIME_DIR}/bus" ]] || return 1
  [[ -S "${PW_RUNTIME_DIR}/pipewire-0" ]] || return 1
  aplay -L 2>/dev/null | grep -qi '^pipewire$'
}

wait_for_prereqs() {
  local reason=""
  while true; do
    if ! uac2_ready; then
      [[ "$reason" == "uac2" ]] || log 'Waiting for UAC2Gadget capture device...'
      reason="uac2"
      sleep "$START_BACKOFF_SEC"
      continue
    fi

    if ! pipewire_ready; then
      [[ "$reason" == "pipewire" ]] || log "Waiting for PipeWire user runtime (${PW_RUNTIME_DIR})..."
      reason="pipewire"
      sleep "$START_BACKOFF_SEC"
      continue
    fi

    return 0
  done
}

if [[ ! -f "$CFG" ]]; then
  echo "CamillaDSP config not found: $CFG" >&2
  exit 1
fi

while true; do
  wait_for_prereqs
  log "Starting CamillaDSP for ${AIRPODS_MAC}..."
  /usr/bin/camilladsp -v "$CFG" || true
  log "CamillaDSP exited; restarting in ${RESTART_BACKOFF_SEC}s"
  sleep "$RESTART_BACKOFF_SEC"
done
