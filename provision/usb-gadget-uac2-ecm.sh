#!/usr/bin/env bash
set -euo pipefail

G=/sys/kernel/config/usb_gadget/g1
FALLBACK_RESTORE_ON_FAIL="${FALLBACK_RESTORE_ON_FAIL:-1}"
failure_stage="init"
USB_VID="${USB_VID:-0x1d6b}"
USB_PID="${USB_PID:-0x1050}"
USB_BCD_USB="${USB_BCD_USB:-0x0200}"
USB_BCD_DEVICE="${USB_BCD_DEVICE:-0x0201}"
USB_SERIAL="${USB_SERIAL:-PIZERO2W-AE-0001}"
USB_MANUFACTURER="${USB_MANUFACTURER:-Raspberry Pi}"
USB_PRODUCT="${USB_PRODUCT:-Pi Zero 2W (Audio + Ethernet)}"
ECM_IFACE="${ECM_IFACE:-usb0}"
USB_IFACE_WAIT_SEC="${USB_IFACE_WAIT_SEC:-8}"
USB_ADDR_PRIMARY="${USB_ADDR_PRIMARY:-192.168.7.2/24}"
USB_ADDR_LINKLOCAL="${USB_ADDR_LINKLOCAL:-169.254.64.64/16}"

log() {
  printf '[usb-gadget] %s\n' "$*"
}

unbind_existing_gadget() {
  if [[ -d "$G" ]]; then
    if [[ -w "$G/UDC" ]]; then
      echo "" >"$G/UDC" 2>/dev/null || true
    fi

    # Configfs attributes are not removable files; cleanup must use unlink/rmdir.
    find "$G/configs" -type l -delete 2>/dev/null || true

    rmdir "$G/functions/uac2.usb0" 2>/dev/null || true
    rmdir "$G/functions/ecm.usb0" 2>/dev/null || true

    rmdir "$G/configs/c.1/strings/0x409" 2>/dev/null || true
    rmdir "$G/configs/c.1/strings" 2>/dev/null || true
    rmdir "$G/configs/c.1" 2>/dev/null || true
    rmdir "$G/configs" 2>/dev/null || true

    rmdir "$G/strings/0x409" 2>/dev/null || true
    rmdir "$G/strings" 2>/dev/null || true

    rmdir "$G/os_desc" 2>/dev/null || true
    rmdir "$G/webusb" 2>/dev/null || true
    rmdir "$G" 2>/dev/null || true
  fi
}

restore_gether_fallback() {
  log "Restoring g_ether fallback"
  unbind_existing_gadget || true
  modprobe g_ether || true
}

bring_up_usb_iface() {
  local iface=""
  local i=0

  for ((i = 0; i < USB_IFACE_WAIT_SEC; i++)); do
    if ip link show "$ECM_IFACE" >/dev/null 2>&1; then
      iface="$ECM_IFACE"
      break
    fi
    sleep 1
  done

  if [[ -z "$iface" ]]; then
    log "ECM interface ${ECM_IFACE} not found after ${USB_IFACE_WAIT_SEC}s; leaving IP setup to NetworkManager"
    return 0
  fi

  ip link set "$iface" up >/dev/null 2>&1 || true
  ip addr replace "$USB_ADDR_PRIMARY" dev "$iface" >/dev/null 2>&1 || true
  ip addr replace "$USB_ADDR_LINKLOCAL" dev "$iface" >/dev/null 2>&1 || true
  log "ECM interface ${iface} brought up with static management IPs"
}

on_error() {
  local rc="$?"
  if [[ "$FALLBACK_RESTORE_ON_FAIL" == "1" ]]; then
    log "Composite gadget setup failed at stage '${failure_stage}' (exit ${rc})"
    restore_gether_fallback
  fi
  exit "$rc"
}

trap on_error ERR

failure_stage="module load"
modprobe libcomposite
modprobe usb_f_uac2
modprobe usb_f_ecm
modprobe u_ether

# Make sure legacy single-function gadgets are not holding the UDC.
modprobe -r g_audio 2>/dev/null || true
modprobe -r g_ether 2>/dev/null || true

failure_stage="configfs mount + cleanup"
[[ -d /sys/kernel/config ]] || mount -t configfs none /sys/kernel/config
unbind_existing_gadget

failure_stage="gadget create"
mkdir -p "$G"

# Use a composite-specific PID to avoid host descriptor cache confusion with g_ether fallback.
echo "$USB_VID" > "$G/idVendor"
echo "$USB_PID" > "$G/idProduct"
echo "$USB_BCD_USB" > "$G/bcdUSB"
echo "$USB_BCD_DEVICE" > "$G/bcdDevice"

mkdir -p "$G/strings/0x409"
echo "$USB_SERIAL" > "$G/strings/0x409/serialnumber"
echo "$USB_MANUFACTURER" > "$G/strings/0x409/manufacturer"
echo "$USB_PRODUCT" > "$G/strings/0x409/product"

mkdir -p "$G/configs/c.1" "$G/configs/c.1/strings/0x409"
echo "UAC2 + CDC-ECM" > "$G/configs/c.1/strings/0x409/configuration"
echo 250 > "$G/configs/c.1/MaxPower"

mkdir -p "$G/functions/uac2.usb0"
echo 3 > "$G/functions/uac2.usb0/p_chmask"
echo 48000 > "$G/functions/uac2.usb0/p_srate"
echo 2 > "$G/functions/uac2.usb0/p_ssize"
echo 3 > "$G/functions/uac2.usb0/c_chmask"
echo 48000 > "$G/functions/uac2.usb0/c_srate"
echo 2 > "$G/functions/uac2.usb0/c_ssize"

mkdir -p "$G/functions/ecm.usb0"
echo "02:1A:7D:DA:71:13" > "$G/functions/ecm.usb0/dev_addr"
echo "02:1A:7D:DA:71:14" > "$G/functions/ecm.usb0/host_addr"
if [[ -w "$G/functions/ecm.usb0/ifname" ]]; then
  echo "$ECM_IFACE" >"$G/functions/ecm.usb0/ifname" 2>/dev/null || true
fi

ln -s "$G/functions/uac2.usb0" "$G/configs/c.1/uac2.usb0"
ln -s "$G/functions/ecm.usb0" "$G/configs/c.1/ecm.usb0"

failure_stage="udc bind"
UDC="$(ls /sys/class/udc | head -n1 || true)"
if [[ -z "$UDC" ]]; then
  echo "No USB Device Controller found under /sys/class/udc" >&2
  exit 1
fi

echo "$UDC" > "$G/UDC"
if [[ "$(cat "$G/UDC")" != "$UDC" ]]; then
  echo "Failed to bind gadget to UDC ${UDC}" >&2
  exit 1
fi

failure_stage="network bring-up"
bring_up_usb_iface

trap - ERR
log "Bound gadget to UDC ${UDC}"
