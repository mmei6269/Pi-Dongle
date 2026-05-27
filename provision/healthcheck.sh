#!/usr/bin/env bash
set -euo pipefail

RUNTIME_ENV="${RUNTIME_ENV:-/etc/default/pi-audio-dongle}"
if [[ -f "$RUNTIME_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$RUNTIME_ENV"
fi

AIRPODS_MAC="${AIRPODS_MAC:-}"
PW_USER="${PW_USER:-${TARGET_USER:-}}"

if [[ ! "$AIRPODS_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
  printf '[FAIL] AIRPODS_MAC is not configured. Re-run install.sh or set AIRPODS_MAC.\n' >&2
  exit 1
fi

if [[ -z "$PW_USER" ]]; then
  printf '[FAIL] PW_USER/TARGET_USER is not configured. Re-run install.sh or set PW_USER.\n' >&2
  exit 1
fi

FAILURES=0
WARNINGS=0

pass() { printf '[PASS] %s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '[WARN] %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf '[FAIL] %s\n' "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

PW_UID="$(id -u "$PW_USER" 2>/dev/null || true)"
if [[ -z "$PW_UID" ]]; then
  printf '[FAIL] Unable to resolve PipeWire user %s\n' "$PW_USER" >&2
  exit 1
fi
PW_RUNTIME_DIR="/run/user/${PW_UID}"
PW_DBUS_ADDR="unix:path=${PW_RUNTIME_DIR}/bus"
ACTIVE_CAMILLADSP_CONFIG="/etc/camilladsp/airpods.yml"

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

section 'Runtime config'
printf '[INFO] runtime env = %s\n' "$RUNTIME_ENV"

if [[ -n "${DSP_CONFIG:-}" ]]; then
  printf '[INFO] DSP_CONFIG = %s\n' "$DSP_CONFIG"
else
  warn 'DSP_CONFIG is not recorded in the runtime env; rerun install.sh to refresh metadata'
fi

printf '[INFO] CROSSFEED_PRESET = %s\n' "${CROSSFEED_PRESET:-unknown}"
printf '[INFO] ENABLE_CROSSFEED = %s\n' "${ENABLE_CROSSFEED:-unknown}"
printf '[INFO] ENABLE_AIRPODS_PRO3_EQ = %s\n' "${ENABLE_AIRPODS_PRO3_EQ:-unknown}"

if [[ -f "$ACTIVE_CAMILLADSP_CONFIG" ]]; then
  pass "Active CamillaDSP config exists: ${ACTIVE_CAMILLADSP_CONFIG}"
  config_header="$(awk 'NF { sub(/^# ?/, ""); print; exit }' "$ACTIVE_CAMILLADSP_CONFIG" 2>/dev/null || true)"
  if [[ -n "$config_header" ]]; then
    printf '[INFO] config header = %s\n' "$config_header"
  fi
else
  fail "Active CamillaDSP config missing: ${ACTIVE_CAMILLADSP_CONFIG}"
fi

section 'Systemd services'
for svc in bluetooth camilladsp airpods-connect; do
  if systemctl is-active --quiet "$svc"; then
    pass "$svc is active"
  else
    fail "$svc is not active"
  fi
done

if systemctl is-active --quiet bluealsa; then
  warn 'bluealsa is still active (expected inactive after PipeWire cutover)'
else
  pass 'bluealsa is inactive'
fi

usb_gadget_enabled_state="$(systemctl is-enabled usb-gadget 2>/dev/null || true)"
if systemctl is-active --quiet usb-gadget; then
  pass 'usb-gadget is active (composite mode)'
else
  fail "usb-gadget is not active (enabled state: ${usb_gadget_enabled_state:-unknown})"
fi

section 'PipeWire user stack'
if pw_user_cmd systemctl --user is-active --quiet pipewire wireplumber pipewire-pulse; then
  pass "PipeWire user services active for ${PW_USER}"
else
  fail "PipeWire user services not healthy for ${PW_USER}"
  pw_user_cmd systemctl --user --no-pager --full status pipewire wireplumber pipewire-pulse || true
fi

if [[ -S "${PW_RUNTIME_DIR}/pipewire-0" ]] && [[ -S "${PW_RUNTIME_DIR}/bus" ]]; then
  pass "PipeWire runtime sockets present at ${PW_RUNTIME_DIR}"
else
  fail "PipeWire runtime sockets missing in ${PW_RUNTIME_DIR}"
fi

section 'USB path'
if [[ -f /sys/kernel/config/usb_gadget/g1/UDC ]] && [[ -n "$(cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null)" ]]; then
  pass "USB gadget is bound to UDC $(cat /sys/kernel/config/usb_gadget/g1/UDC)"
else
  fail 'USB gadget is not bound to any UDC'
fi

if arecord -l 2>/dev/null | grep -qi 'UAC2Gadget'; then
  pass 'UAC2Gadget capture device is visible'
else
  fail 'UAC2Gadget capture device is missing'
fi

section 'Bluetooth + AirPods sink'
if bluetoothctl info "$AIRPODS_MAC" 2>/dev/null | grep -q 'Connected: yes'; then
  pass "AirPods are connected (${AIRPODS_MAC})"
else
  warn "AirPods are not connected (${AIRPODS_MAC})"
fi

sink_id="$(get_airpods_sink_id || true)"
if [[ -n "$sink_id" ]]; then
  pass "AirPods PipeWire sink present (id=${sink_id})"
  codec_line="$(pw_user_cmd wpctl inspect "$sink_id" 2>/dev/null | grep -i 'bluez5.codec' | head -n1 || true)"
  if [[ -n "$codec_line" ]]; then
    printf '[INFO] %s\n' "$codec_line"
  else
    warn 'No explicit bluez5.codec property found on sink inspect output'
  fi
else
  warn 'No AirPods A2DP sink currently visible in PipeWire'
fi

section 'CamillaDSP process'
if systemctl is-active --quiet camilladsp; then
  pass 'camilladsp service active'
else
  fail 'camilladsp service inactive'
fi

if pgrep -af camilladsp >/dev/null 2>&1; then
  pass 'camilladsp process is running'
else
  fail 'camilladsp process not found'
fi

section 'Network usb0'
usb0_ipv4="$(ip -4 -br addr show usb0 2>/dev/null | awk '{print $3}')"
if [[ "$usb0_ipv4" == *"192.168.7.2/24"* ]] || [[ "$usb0_ipv4" == *"169.254.64.64/16"* ]]; then
  pass "usb0 has expected management IP(s): ${usb0_ipv4}"
else
  warn "usb0 does not currently have expected management IPs (current: ${usb0_ipv4:-none})"
fi

section 'Summary'
if ((FAILURES > 0)); then
  printf '[FAIL] healthcheck completed with %s failure(s)\n' "$FAILURES"
  exit 1
fi

if ((WARNINGS > 0)); then
  printf '[WARN] healthcheck completed with %s warning(s)\n' "$WARNINGS"
else
  pass 'healthcheck completed cleanly'
fi
