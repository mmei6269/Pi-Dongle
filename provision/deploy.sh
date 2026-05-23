#!/usr/bin/env bash
set -euo pipefail

PI_HOST="${PI_HOST:-}"
REMOTE_DIR="${REMOTE_DIR:-pi-audio-dongle-provision}"
AIRPODS_MAC="${AIRPODS_MAC:-}"
ENABLE_AIRPODS_PRO3_EQ="${ENABLE_AIRPODS_PRO3_EQ:-}"
ENABLE_CROSSFEED="${ENABLE_CROSSFEED:-}"
RESTART_GADGET_NOW="${RESTART_GADGET_NOW:-0}"
SKIP_APT="${SKIP_APT:-0}"
DISABLE_WIFI_AFTER_INSTALL="${DISABLE_WIFI_AFTER_INSTALL:-0}"
SSH_OPTS=(-o ConnectTimeout=5)

sh_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

sync_bundle() {
  local remote_dir_q
  remote_dir_q="$(sh_quote "$REMOTE_DIR")"

  ssh "${SSH_OPTS[@]}" "$PI_HOST" "mkdir -p ${remote_dir_q}"

  if command -v rsync >/dev/null 2>&1; then
    if rsync -av --delete -e "ssh ${SSH_OPTS[*]}" ./provision/ "$PI_HOST:$REMOTE_DIR/"; then
      return 0
    fi
    printf '[deploy] rsync failed; falling back to tar-over-ssh\n' >&2
  else
    printf '[deploy] rsync not found locally; falling back to tar-over-ssh\n' >&2
  fi

  tar -C ./provision -cf - . | ssh "${SSH_OPTS[@]}" "$PI_HOST" "rm -rf ${remote_dir_q} && mkdir -p ${remote_dir_q} && tar -C ${remote_dir_q} -xf -"
}

if [[ -z "$PI_HOST" ]]; then
  read -r -p "Pi SSH target (user@raspberrypi.local or user@192.168.7.2): " PI_HOST
fi

if [[ -z "$PI_HOST" ]]; then
  printf '[deploy] ERROR: PI_HOST is required\n' >&2
  exit 1
fi

printf '[deploy] Syncing provision bundle to %s:%s\n' "$PI_HOST" "$REMOTE_DIR"
sync_bundle

printf '[deploy] Running remote installer (ENABLE_CROSSFEED=%s RESTART_GADGET_NOW=%s SKIP_APT=%s)\n' "${ENABLE_CROSSFEED:-interactive}" "$RESTART_GADGET_NOW" "$SKIP_APT"
remote_dir_q="$(sh_quote "$REMOTE_DIR")"
airpods_mac_q="$(sh_quote "$AIRPODS_MAC")"
eq_q="$(sh_quote "$ENABLE_AIRPODS_PRO3_EQ")"
crossfeed_q="$(sh_quote "$ENABLE_CROSSFEED")"
restart_gadget_q="$(sh_quote "$RESTART_GADGET_NOW")"
skip_apt_q="$(sh_quote "$SKIP_APT")"
disable_wifi_q="$(sh_quote "$DISABLE_WIFI_AFTER_INSTALL")"

ssh -t "${SSH_OPTS[@]}" "$PI_HOST" "cd ${remote_dir_q} && AIRPODS_MAC=${airpods_mac_q} ENABLE_AIRPODS_PRO3_EQ=${eq_q} ENABLE_CROSSFEED=${crossfeed_q} RESTART_GADGET_NOW=${restart_gadget_q} SKIP_APT=${skip_apt_q} DISABLE_WIFI_AFTER_INSTALL=${disable_wifi_q} sudo -E bash ./install.sh"
