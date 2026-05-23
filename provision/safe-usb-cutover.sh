#!/usr/bin/env bash
set -euo pipefail

ROLLBACK_AFTER_SEC="${ROLLBACK_AFTER_SEC:-180}"
VERIFY_AFTER_SEC="${VERIFY_AFTER_SEC:-8}"
VERIFY_TIMEOUT_SEC="${VERIFY_TIMEOUT_SEC:-45}"
VERIFY_POLL_SEC="${VERIFY_POLL_SEC:-1}"
ROLLBACK_UNIT="${ROLLBACK_UNIT:-usb-cutover-rollback}"

log() {
  logger -t safe-usb-cutover "$*"
  printf '[safe-usb-cutover] %s\n' "$*"
}

gadget_bound() {
  [[ -f /sys/kernel/config/usb_gadget/g1/UDC ]] && [[ -n "$(cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null)" ]]
}

uac2_visible() {
  arecord -l 2>/dev/null | grep -qi 'UAC2Gadget'
}

usb0_ready() {
  ip -4 addr show dev usb0 2>/dev/null | grep -q 'inet '
}

ensure_usb0_address() {
  if usb0_ready; then
    return 0
  fi

  nmcli connection up usb-gadget >/dev/null 2>&1 || true
  ip link set usb0 up >/dev/null 2>&1 || true
  ip addr replace 192.168.7.2/24 dev usb0 >/dev/null 2>&1 || true
  ip addr replace 169.254.64.64/16 dev usb0 >/dev/null 2>&1 || true
  usb0_ready
}

cancel_rollback() {
  systemctl stop "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
  systemctl reset-failed "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
}

schedule_rollback() {
  cancel_rollback
  systemd-run --unit "$ROLLBACK_UNIT" --on-active="${ROLLBACK_AFTER_SEC}" \
    /bin/bash -lc 'FORCE_GETHER=1 /usr/local/sbin/usb-fallback-guard.sh'
}

log "Scheduling rollback in ${ROLLBACK_AFTER_SEC}s unless cutover validates"
schedule_rollback

log 'Restarting usb-gadget.service for composite cutover'
systemctl restart usb-gadget.service

sleep "$VERIFY_AFTER_SEC"
elapsed=0
while (( elapsed < VERIFY_TIMEOUT_SEC )); do
  ensure_usb0_address || true
  if gadget_bound && uac2_visible && usb0_ready; then
    log 'Composite cutover validated; canceling rollback timer'
    cancel_rollback
    exit 0
  fi
  sleep "$VERIFY_POLL_SEC"
  ((elapsed += VERIFY_POLL_SEC))
done

log 'Composite cutover did not validate; rollback timer remains active'
exit 1
