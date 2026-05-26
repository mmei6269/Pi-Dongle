#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PI_HOST="${PI_HOST:-}"
RUN_HEALTHCHECK="${RUN_HEALTHCHECK:-1}"
REMOTE_ENV="${REMOTE_ENV:-/etc/default/pi-audio-dongle}"
SSH_OPTS=(-o ConnectTimeout=5)
if [[ -n "${SSH_CONTROL_PATH:-}" ]]; then
  SSH_OPTS=(-S "$SSH_CONTROL_PATH" "${SSH_OPTS[@]}")
fi

LOCAL_FILES=(
  "provision/usb-gadget-uac2-ecm.sh"
  "provision/usb-fallback-guard.sh"
  "provision/safe-usb-cutover.sh"
  "provision/run-camilladsp.sh"
  "provision/airpods-connect.sh"
  "provision/healthcheck.sh"
  "provision/airpods.yml"
  "provision/reference-speaker/speaker_30_ipsi_fir.txt"
  "provision/reference-speaker/speaker_30_contra_fir.txt"
  "provision/wireplumber/51-bluez-aac.conf"
  "provision/wireplumber/52-dongle-settings.conf"
  "provision/systemd/usb-gadget.service"
  "provision/systemd/usb-fallback-guard.service"
  "provision/systemd/camilladsp.service"
  "provision/systemd/airpods-connect.service"
)

REMOTE_FILES=(
  "/usr/local/sbin/usb-gadget-uac2-ecm.sh"
  "/usr/local/sbin/usb-fallback-guard.sh"
  "/usr/local/sbin/safe-usb-cutover.sh"
  "/usr/local/bin/run-camilladsp.sh"
  "/usr/local/bin/airpods-connect.sh"
  "/usr/local/bin/dongle-healthcheck.sh"
  "/etc/camilladsp/airpods.yml"
  "/etc/camilladsp/reference-speaker/speaker_30_ipsi_fir.txt"
  "/etc/camilladsp/reference-speaker/speaker_30_contra_fir.txt"
  "/etc/wireplumber/wireplumber.conf.d/51-bluez-aac.conf"
  "/etc/wireplumber/wireplumber.conf.d/52-dongle-settings.conf"
  "/usr/local/lib/systemd/system/usb-gadget.service"
  "/usr/local/lib/systemd/system/usb-fallback-guard.service"
  "/usr/local/lib/systemd/system/camilladsp.service"
  "/usr/local/lib/systemd/system/airpods-connect.service"
)

log() { printf '[verify-live] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; }

local_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

env_value() {
  local key="$1"
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, length(key) + 2)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      exit
    }
  ' "$REMOTE_ENV_FILE"
}

remote_hash_for() {
  local path="$1"
  awk -v path="$path" '$2 == path { print $1; found = 1; exit } END { if (!found) exit 1 }' "$REMOTE_HASH_FILE"
}

sed_escape() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

resolve_host() {
  if [[ -n "$PI_HOST" ]]; then
    return 0
  fi

  if [[ -t 0 ]]; then
    read -r -p "Pi SSH target (user@raspberrypi.local or user@192.168.7.2): " PI_HOST
  fi

  if [[ -z "$PI_HOST" ]]; then
    fail "PI_HOST is required"
    exit 1
  fi
}

selected_dsp_config() {
  case "$DSP_CONFIG" in
    clean|'') printf '%s\n' "${REPO_ROOT}/provision/airpods.yml" ;;
    crossfeed) printf '%s\n' "${REPO_ROOT}/provision/airpods-crossfeed.yml" ;;
    monitor-crossfeed) printf '%s\n' "${REPO_ROOT}/provision/airpods-monitor-crossfeed.yml" ;;
    virtual-speaker-crossfeed) printf '%s\n' "${REPO_ROOT}/provision/airpods-virtual-speaker-crossfeed.yml" ;;
    reference-speaker-crossfeed) printf '%s\n' "${REPO_ROOT}/provision/airpods-reference-speaker-crossfeed.yml" ;;
    airpods-pro-3-neutral) printf '%s\n' "${REPO_ROOT}/provision/airpods-pro-3-neutral.yml" ;;
    airpods-pro-3-neutral-crossfeed) printf '%s\n' "${REPO_ROOT}/provision/airpods-pro-3-neutral-crossfeed.yml" ;;
    airpods-pro-3-neutral-monitor-crossfeed) printf '%s\n' "${REPO_ROOT}/provision/airpods-pro-3-neutral-monitor-crossfeed.yml" ;;
    airpods-pro-3-neutral-virtual-speaker-crossfeed) printf '%s\n' "${REPO_ROOT}/provision/airpods-pro-3-neutral-virtual-speaker-crossfeed.yml" ;;
    airpods-pro-3-neutral-reference-speaker-crossfeed) printf '%s\n' "${REPO_ROOT}/provision/airpods-pro-3-neutral-reference-speaker-crossfeed.yml" ;;
    *)
      fail "unknown remote DSP_CONFIG=${DSP_CONFIG}"
      return 1
      ;;
  esac
}

render_service_template() {
  local src="$1"
  local dst="$2"
  local user uid mac

  user="$(sed_escape "$TARGET_USER")"
  uid="$(sed_escape "$TARGET_UID")"
  mac="$(sed_escape "$AIRPODS_MAC")"

  sed \
    -e "s/__TARGET_USER__/${user}/g" \
    -e "s/__TARGET_UID__/${uid}/g" \
    -e "s/__AIRPODS_MAC__/${mac}/g" \
    "$src" >"$dst"
}

prepare_local_file() {
  local local_file="$1"
  local prepared

  case "$local_file" in
    provision/airpods.yml)
      selected_dsp_config
      ;;
    provision/systemd/camilladsp.service|provision/systemd/airpods-connect.service)
      prepared="${TMP_DIR}/$(basename "$local_file")"
      render_service_template "${REPO_ROOT}/${local_file}" "$prepared"
      printf '%s\n' "$prepared"
      ;;
    provision/wireplumber/51-bluez-aac.conf)
      prepared="${TMP_DIR}/51-bluez-aac.conf"
      cp "${REPO_ROOT}/${local_file}" "$prepared"
      if [[ -n "$WIREPLUMBER_CODEC" ]]; then
        sed -i.bak "s/bluez5.codecs = \\[ aac \\]/bluez5.codecs = [ ${WIREPLUMBER_CODEC} ]/" "$prepared"
        rm -f "${prepared}.bak"
      fi
      printf '%s\n' "$prepared"
      ;;
    *)
      printf '%s\n' "${REPO_ROOT}/${local_file}"
      ;;
  esac
}

if [[ "${#LOCAL_FILES[@]}" -ne "${#REMOTE_FILES[@]}" ]]; then
  fail 'internal file map length mismatch'
  exit 1
fi

resolve_host
log "Using ${PI_HOST}"

TMP_DIR="$(mktemp -d)"
REMOTE_HASH_FILE="${TMP_DIR}/remote-hashes"
REMOTE_ENV_FILE="${TMP_DIR}/remote-env"
trap 'rm -rf "$TMP_DIR"' EXIT

ssh "${SSH_OPTS[@]}" "$PI_HOST" "sudo cat '$REMOTE_ENV' 2>/dev/null || true" >"$REMOTE_ENV_FILE"
TARGET_USER="$(env_value TARGET_USER)"
TARGET_UID="$(env_value TARGET_UID)"
AIRPODS_MAC="$(env_value AIRPODS_MAC)"
DSP_CONFIG="$(env_value DSP_CONFIG)"

if [[ -z "$TARGET_USER" || -z "$TARGET_UID" || -z "$AIRPODS_MAC" ]]; then
  fail "remote env ${REMOTE_ENV} is missing required install metadata"
  exit 1
fi

WIREPLUMBER_CODEC="$(ssh "${SSH_OPTS[@]}" "$PI_HOST" "grep -E '^[[:space:]]*bluez5.codecs' /etc/wireplumber/wireplumber.conf.d/51-bluez-aac.conf 2>/dev/null | sed -E 's/.*\\[ ([^] ]+) \\].*/\\1/'" || true)"

ssh "${SSH_OPTS[@]}" "$PI_HOST" "sudo sha256sum ${REMOTE_FILES[*]}" >"$REMOTE_HASH_FILE"

failures=0
for i in "${!LOCAL_FILES[@]}"; do
  local_file="${LOCAL_FILES[$i]}"
  remote_file="${REMOTE_FILES[$i]}"
  local_path="$(prepare_local_file "$local_file")"

  if [[ ! -f "$local_path" ]]; then
    fail "missing local file: ${local_file}"
    failures=$((failures + 1))
    continue
  fi

  local_hash="$(local_sha "$local_path")"
  if ! remote_hash="$(remote_hash_for "$remote_file")"; then
    fail "missing remote file: ${remote_file}"
    failures=$((failures + 1))
    continue
  fi

  if [[ "$local_hash" == "$remote_hash" ]]; then
    pass "${local_file} == ${remote_file}"
  else
    fail "${local_file} differs from ${remote_file}"
    printf '       local:  %s\n' "$local_hash"
    printf '       remote: %s\n' "$remote_hash"
    failures=$((failures + 1))
  fi
done

boot_cmdline="$(ssh "${SSH_OPTS[@]}" "$PI_HOST" 'sudo cat /boot/firmware/cmdline.txt')"
if [[ "$boot_cmdline" == *"modules-load="* && "$boot_cmdline" == *"dwc2"* ]]; then
  pass 'boot cmdline loads dwc2'
else
  fail 'boot cmdline does not load dwc2'
  failures=$((failures + 1))
fi

if [[ "$boot_cmdline" == *"g_ether"* || "$boot_cmdline" == *"g_audio"* ]]; then
  fail 'boot cmdline still contains legacy g_ether/g_audio'
  failures=$((failures + 1))
else
  pass 'boot cmdline excludes legacy g_ether/g_audio'
fi

overlay_count="$(ssh "${SSH_OPTS[@]}" "$PI_HOST" "grep -c '^dtoverlay=dwc2,dr_mode=peripheral$' /boot/firmware/config.txt || true")"
if [[ "$overlay_count" == "1" ]]; then
  pass 'boot config has one dwc2 peripheral overlay'
else
  fail "boot config has ${overlay_count} dwc2 peripheral overlay lines"
  failures=$((failures + 1))
fi

if [[ "$RUN_HEALTHCHECK" == "1" ]]; then
  log 'Running installed healthcheck'
  if ssh "${SSH_OPTS[@]}" "$PI_HOST" 'sudo /usr/local/bin/dongle-healthcheck.sh'; then
    pass 'installed healthcheck exited cleanly'
  else
    fail 'installed healthcheck failed'
    failures=$((failures + 1))
  fi
fi

if ((failures > 0)); then
  fail "live verification completed with ${failures} failure(s)"
  exit 1
fi

pass 'live verification completed cleanly'
