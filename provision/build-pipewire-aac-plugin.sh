#!/usr/bin/env bash
set -Eeuo pipefail

# Build and install the missing PipeWire BlueZ AAC codec plugin:
#   /usr/lib/<multiarch>/spa-0.2/bluez5/libspa-codec-bluez5-aac.so
#
# This is needed on images where libspa-0.2-bluetooth ships without AAC.

WORKDIR="${WORKDIR:-/tmp/pw-aac-build}"
PW_TAG_FALLBACK="${PW_TAG_FALLBACK:-1.4.2}"

detect_pipewire_package_version() {
  local pkg version
  for pkg in libpipewire-0.3-0t64 libpipewire-0.3-0 pipewire; do
    version="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
    if [[ -n "$version" ]]; then
      printf '%s\n' "$version"
      return 0
    fi
  done
}

pipewire_tag_from_version() {
  local version="$1"
  version="${version#*:}"
  version="${version%%-*}"
  printf '%s\n' "$version"
}

detect_multiarch() {
  local multiarch arch
  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
  if [[ -n "$multiarch" ]]; then
    printf '%s\n' "$multiarch"
    return 0
  fi

  multiarch="$(gcc -print-multiarch 2>/dev/null || true)"
  if [[ -n "$multiarch" ]]; then
    printf '%s\n' "$multiarch"
    return 0
  fi

  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$arch" in
    amd64) printf 'x86_64-linux-gnu\n' ;;
    arm64) printf 'aarch64-linux-gnu\n' ;;
    armhf) printf 'arm-linux-gnueabihf\n' ;;
    *) printf 'aarch64-linux-gnu\n' ;;
  esac
}

PW_VERSION_PKG="${PW_VERSION_PKG:-$(detect_pipewire_package_version || true)}"
PW_TAG="${PW_TAG:-$(pipewire_tag_from_version "$PW_VERSION_PKG")}"

if [[ -z "${PW_TAG}" ]]; then
  PW_TAG="$PW_TAG_FALLBACK"
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

MULTIARCH="${MULTIARCH:-$(detect_multiarch)}"

PLUGIN_DIR="/usr/lib/${MULTIARCH}/spa-0.2/bluez5"
PLUGIN_OUT="${PLUGIN_DIR}/libspa-codec-bluez5-aac.so"

log "Using PipeWire tag ${PW_TAG}"
log "Build dir: ${WORKDIR}"
log "Install target: ${PLUGIN_OUT}"

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

if [[ ! -d pipewire/.git ]]; then
  rm -rf pipewire
  git clone --depth 1 --branch "${PW_TAG}" https://github.com/PipeWire/pipewire.git pipewire
else
  current_tag="$(git -C pipewire describe --tags --exact-match 2>/dev/null || true)"
  if [[ "$current_tag" == "$PW_TAG" ]]; then
    log "Reusing existing source checkout in ${WORKDIR}/pipewire"
  else
    log "Replacing existing source checkout (current=${current_tag:-unknown}, wanted=${PW_TAG})"
    rm -rf pipewire
    git clone --depth 1 --branch "${PW_TAG}" https://github.com/PipeWire/pipewire.git pipewire
  fi
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
