#!/usr/bin/env bash
set -euo pipefail

USB_GADGET_WAIT_SEC="${USB_GADGET_WAIT_SEC:-8}"
FORCE_GETHER="${FORCE_GETHER:-0}"
NM_PROFILE="${NM_PROFILE:-usb-gadget}"
FALLBACK_USB_ADDR_PRIMARY="${FALLBACK_USB_ADDR_PRIMARY:-192.168.7.2/24}"
FALLBACK_USB_ADDR_LINKLOCAL="${FALLBACK_USB_ADDR_LINKLOCAL:-169.254.64.64/16}"

log() {
  logger -t usb-fallback-guard "$*"
  printf '[usb-fallback-guard] %s\n' "$*"
}

gadget_bound() {
  [[ -f /sys/kernel/config/usb_gadget/g1/UDC ]] && [[ -n "$(cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null)" ]]
}

composite_functions_present() {
  [[ -d /sys/kernel/config/usb_gadget/g1/functions/uac2.usb0 ]] &&
    [[ -d /sys/kernel/config/usb_gadget/g1/functions/ecm.usb0 ]] &&
    [[ -L /sys/kernel/config/usb_gadget/g1/configs/c.1/uac2.usb0 ]] &&
    [[ -L /sys/kernel/config/usb_gadget/g1/configs/c.1/ecm.usb0 ]]
}

composite_healthy() {
  gadget_bound && composite_functions_present
}

unbind_gadget() {
  if [[ -w /sys/kernel/config/usb_gadget/g1/UDC ]]; then
    echo "" >/sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null || true
  fi
}

restore_gether() {
  log 'Restoring USB management path via g_ether'
  unbind_gadget
  modprobe -r g_audio 2>/dev/null || true
  modprobe g_ether || true
  ip link set usb0 up >/dev/null 2>&1 || true
  ip addr replace "$FALLBACK_USB_ADDR_PRIMARY" dev usb0 >/dev/null 2>&1 || true
  ip addr replace "$FALLBACK_USB_ADDR_LINKLOCAL" dev usb0 >/dev/null 2>&1 || true
  if command -v nmcli >/dev/null 2>&1; then
    nmcli connection up "$NM_PROFILE" >/dev/null 2>&1 || true
  fi
}

ensure_usb_mgmt_iface() {
  ip link set usb0 up >/dev/null 2>&1 || true
  ip addr replace "$FALLBACK_USB_ADDR_PRIMARY" dev usb0 >/dev/null 2>&1 || true
  ip addr replace "$FALLBACK_USB_ADDR_LINKLOCAL" dev usb0 >/dev/null 2>&1 || true
  if command -v nmcli >/dev/null 2>&1; then
    nmcli connection up "$NM_PROFILE" >/dev/null 2>&1 || true
  fi
}

if [[ "$FORCE_GETHER" == "1" ]]; then
  restore_gether
  exit 0
fi

for ((i = 0; i < USB_GADGET_WAIT_SEC; i++)); do
  if composite_healthy; then
    ensure_usb_mgmt_iface
    log 'Composite gadget is healthy'
    exit 0
  fi
  sleep 1
done

log "Composite gadget did not become healthy in ${USB_GADGET_WAIT_SEC}s"
restore_gether
