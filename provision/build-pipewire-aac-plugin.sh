#!/usr/bin/env bash
set -Eeuo pipefail

# Build and install the missing PipeWire BlueZ AAC codec plugin:
#   /usr/lib/<multiarch>/spa-0.2/bluez5/libspa-codec-bluez5-aac.so
#
# This is needed on images where libspa-0.2-bluetooth ships without AAC.

WORKDIR="${WORKDIR:-/tmp/pw-aac-build}"
PW_VERSION_PKG="${PW_VERSION_PKG:-$(dpkg-query -W -f='${Version}' libpipewire-0.3-0t64 2>/dev/null || true)}"
PW_TAG="${PW_TAG:-${PW_VERSION_PKG%%-*}}"

if [[ -z "${PW_TAG}" ]]; then
  PW_TAG="1.4.2"
fi

log() { printf '[aac-build] %s\n' "$*"; }
die() { printf '[aac-build][ERR] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

require_cmd git
require_cmd gcc
require_cmd pkg-config

if ! pkg-config --exists fdk-aac; then
  die "fdk-aac dev files are missing (install libfdk-aac-dev)"
fi

MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
if [[ -z "${MULTIARCH}" ]]; then
  MULTIARCH="aarch64-linux-gnu"
fi

PLUGIN_DIR="/usr/lib/${MULTIARCH}/spa-0.2/bluez5"
PLUGIN_OUT="${PLUGIN_DIR}/libspa-codec-bluez5-aac.so"

log "Using PipeWire tag ${PW_TAG}"
log "Build dir: ${WORKDIR}"
log "Install target: ${PLUGIN_OUT}"

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

if [[ ! -d pipewire ]]; then
  git clone --depth 1 --branch "${PW_TAG}" https://github.com/PipeWire/pipewire.git pipewire
else
  log "Reusing existing source checkout in ${WORKDIR}/pipewire"
fi

mkdir -p build

gcc -fPIC -shared -O2 -Wall -Wextra -Wno-unused-parameter \
  -DCODEC_PLUGIN \
  -Ipipewire/spa/include \
  -Ipipewire/spa/plugins/bluez5 \
  pipewire/spa/plugins/bluez5/a2dp-codec-aac.c \
  pipewire/spa/plugins/bluez5/media-codecs.c \
  -o build/libspa-codec-bluez5-aac.so \
  -lfdk-aac

sudo install -Dm755 build/libspa-codec-bluez5-aac.so "${PLUGIN_OUT}"

log "Installed ${PLUGIN_OUT}"
log "Restart user PipeWire stack to load AAC plugin:"
log "  systemctl --user restart pipewire pipewire-pulse wireplumber"
