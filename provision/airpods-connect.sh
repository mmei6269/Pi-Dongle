#!/usr/bin/env bash
set -euo pipefail

RUNTIME_ENV="${RUNTIME_ENV:-/etc/default/pi-audio-dongle}"
if [[ -f "$RUNTIME_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$RUNTIME_ENV"
fi

AIRPODS_MAC="${AIRPODS_MAC:-}"
PW_USER="${PW_USER:-${TARGET_USER:-}}"
CONNECT_RETRY_SEC="${CONNECT_RETRY_SEC:-8}"
SINK_RETRY_SEC="${SINK_RETRY_SEC:-5}"
CAMILLA_RESTART_DELAY_SEC="${CAMILLA_RESTART_DELAY_SEC:-1}"
BTCTL_TIMEOUT_SEC="${BTCTL_TIMEOUT_SEC:-4}"
BT_DEV_PATH="/org/bluez/hci0/dev_${AIRPODS_MAC^^}"
BT_DEV_PATH="${BT_DEV_PATH//:/_}"

if [[ ! "$AIRPODS_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
  echo "AIRPODS_MAC must be set to a Bluetooth MAC like AA:BB:CC:DD:EE:FF" >&2
  exit 1
fi

if [[ -z "$PW_USER" ]]; then
  echo "PW_USER/TARGET_USER must be set" >&2
  exit 1
fi

PW_UID="$(id -u "$PW_USER" 2>/dev/null || true)"
if [[ -z "$PW_UID" ]]; then
  echo "Unable to resolve PipeWire user '${PW_USER}'" >&2
  exit 1
fi
PW_RUNTIME_DIR="/run/user/${PW_UID}"
PW_DBUS_ADDR="unix:path=${PW_RUNTIME_DIR}/bus"

log() {
  logger -t airpods-connect "$*"
  printf '[airpods-connect] %s\n' "$*"
}

pw_user_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$PW_USER" -- \
        env XDG_RUNTIME_DIR="$PW_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$PW_DBUS_ADDR" "$@"
    else
      sudo -u "$PW_USER" \
        XDG_RUNTIME_DIR="$PW_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$PW_DBUS_ADDR" \
        "$@"
    fi
  else
    XDG_RUNTIME_DIR="$PW_RUNTIME_DIR" \
      DBUS_SESSION_BUS_ADDRESS="$PW_DBUS_ADDR" \
      "$@"
  fi
}

is_connected() {
  busctl --system get-property org.bluez "$BT_DEV_PATH" org.bluez.Device1 Connected 2>/dev/null | awk '{print $2}' | grep -q true
}

attempt_connect() {
  timeout "$BTCTL_TIMEOUT_SEC" bluetoothctl trust "$AIRPODS_MAC" >/dev/null 2>&1 || true
  timeout "$BTCTL_TIMEOUT_SEC" bluetoothctl connect "$AIRPODS_MAC" >/dev/null 2>&1 || true
}

pipewire_ready() {
  [[ -S "${PW_RUNTIME_DIR}/pipewire-0" ]] || return 1
  [[ -S "${PW_RUNTIME_DIR}/bus" ]] || return 1
  pw_user_cmd wpctl status >/dev/null 2>&1
}

get_airpods_sink_id() {
  local mac_upper sink_id
  local -a sink_ids
  mac_upper="${AIRPODS_MAC^^}"

  mapfile -t sink_ids < <(
    pw_user_cmd wpctl status 2>/dev/null | awk '
      /Sinks:/ { in_sinks = 1; next }
      /Sources:/ { in_sinks = 0 }
      in_sinks {
        if (match($0, /[0-9]+\./)) {
          id = substr($0, RSTART, RLENGTH)
          sub(/\.$/, "", id)
          print id
        }
      }
    '
  )

  for sink_id in "${sink_ids[@]}"; do
    if pw_user_cmd wpctl inspect "$sink_id" 2>/dev/null | grep -qi "api.bluez5.address = \"${mac_upper}\""; then
      printf '%s\n' "$sink_id"
      return 0
    fi
  done

  return 1
}

set_default_sink() {
  local sink_id
  sink_id="$(get_airpods_sink_id)"
  [[ -n "$sink_id" ]] || return 1

  pw_user_cmd wpctl set-default "$sink_id" >/dev/null 2>&1
  log "Default PipeWire sink set to AirPods (id=${sink_id})"
}

camilla_active() {
  systemctl is-active --quiet camilladsp.service
}

last_state="unknown"
last_connect_try=0
last_sink_try=0

attempt_connect

while true; do
  now="$(date +%s)"

  if is_connected; then
    if [[ "$last_state" != "connected" ]]; then
      log "AirPods connected (${AIRPODS_MAC})"
    fi

    if (( now - last_sink_try >= SINK_RETRY_SEC )) || [[ "$last_state" != "connected" ]]; then
      last_sink_try="$now"
      if pipewire_ready; then
        set_default_sink || log 'AirPods sink not yet exposed in PipeWire, will retry'
      fi
    fi

    if [[ "$last_state" != "connected" ]] && ! camilla_active; then
      log 'CamillaDSP not active after connect; restarting service'
      sleep "$CAMILLA_RESTART_DELAY_SEC"
      systemctl restart camilladsp.service || true
    fi

    last_state="connected"
  else
    if [[ "$last_state" != "disconnected" ]]; then
      log "AirPods disconnected (${AIRPODS_MAC}); retry loop active"
    fi
    last_state="disconnected"

    if (( now - last_connect_try >= CONNECT_RETRY_SEC )); then
      last_connect_try="$now"
      attempt_connect
    fi
  fi

  sleep 1
done
