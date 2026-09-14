#!/usr/bin/env bash
# Download a pinned bblanchon/pdfium-binaries shared lib and stage it for
# :cl-repo overlays + publish-native-package (flat native-bundle/ dest names).
# Do not vendor Chromium source. Do not commit the binaries.
#
# Usage: ./scripts/stage-pdfium.sh [os] [arch]
# Env:   PDFIUM_BINARIES_TAG (default chromium/8035)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${PDFIUM_BINARIES_TAG:-chromium/8035}"

supported="linux/amd64 linux/arm64 darwin/arm64 windows/amd64"

detect_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) echo windows ;;
    *) echo "error: unknown OS from uname -s: $(uname -s) (supported: ${supported})" >&2; exit 1 ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "error: unknown arch from uname -m: $(uname -m) (supported: ${supported})" >&2; exit 1 ;;
  esac
}

OS="${1:-}"
ARCH="${2:-}"
if [[ -z "$OS" && -z "$ARCH" ]]; then
  OS="$(detect_os)"
  ARCH="$(detect_arch)"
elif [[ -z "$OS" || -z "$ARCH" ]]; then
  echo "error: pass both OS and ARCH, or neither (to detect). supported: ${supported}" >&2
  exit 1
fi

case "${OS}/${ARCH}" in
  linux/amd64) ASSET="pdfium-linux-x64.tgz" ;;
  linux/arm64) ASSET="pdfium-linux-arm64.tgz" ;;
  darwin/arm64) ASSET="pdfium-mac-arm64.tgz" ;;
  windows/amd64) ASSET="pdfium-win-x64.tgz" ;;
  *)
    echo "error: unknown platform ${OS}/${ARCH} (supported: ${supported})" >&2
    exit 1
    ;;
esac

case "$OS" in
  linux) DEST_NAMES=(libpdfium.so libpdfium.so.1) ;;
  darwin) DEST_NAMES=(libpdfium.dylib libpdfium.1.dylib) ;;
  windows) DEST_NAMES=(pdfium.dll libpdfium.dll) ;;
esac

TAG_ENC="${TAG//\//%2F}"
URL="https://github.com/bblanchon/pdfium-binaries/releases/download/${TAG_ENC}/${ASSET}"
SAFE_TAG="${TAG//\//-}"
BUILD="$ROOT/build"
TGZ="$BUILD/pdfium-${SAFE_TAG}-${ASSET}"
EXTRACT="$BUILD/pdfium-${SAFE_TAG}-${OS}-${ARCH}"
LIB_DIR="$ROOT/lib/${OS}-${ARCH}"
BUNDLE="$ROOT/native-bundle"

mkdir -p "$BUILD"
if [[ ! -s "$TGZ" ]]; then
  echo "==> download ${URL}"
  curl -fsSL "$URL" -o "$TGZ"
else
  echo "==> reuse ${TGZ}"
fi

rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"
tar -xzf "$TGZ" -C "$EXTRACT"

find_src() {
  local extract="$1"
  local candidates=()
  case "$OS" in
    linux)
      candidates=(
        "${extract}/lib/libpdfium.so"
        "${extract}/lib/libpdfium.so.1"
        "${extract}/lib64/libpdfium.so"
      )
      ;;
    darwin)
      candidates=(
        "${extract}/lib/libpdfium.dylib"
        "${extract}/lib/libpdfium.1.dylib"
      )
      ;;
    windows)
      candidates=(
        "${extract}/bin/pdfium.dll"
        "${extract}/lib/pdfium.dll"
        "${extract}/pdfium.dll"
      )
      ;;
  esac
  local c
  for c in "${candidates[@]}"; do
    if [[ -e "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  local found=""
  found="$(find "$extract" \( -type f -o -type l \) \
    \( -name 'libpdfium.so' -o -name 'libpdfium.so.*' \
       -o -name 'libpdfium.dylib' -o -name 'libpdfium.*.dylib' \
       -o -name 'pdfium.dll' \) \
    -print | head -n 1 || true)"
  if [[ -n "$found" && -e "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi
  echo "error: libpdfium not found in ${extract} (${ASSET} / ${TAG})" >&2
  find "$extract" -type f | head -n 40 >&2 || true
  exit 1
}

SRC="$(find_src "$EXTRACT")"
echo "==> source ${SRC}"

rm -rf "$LIB_DIR" "$BUNDLE"
mkdir -p "$LIB_DIR" "$BUNDLE"

name=""
for name in "${DEST_NAMES[@]}"; do
  # Copy (not symlink): upload-artifact and the packager want real files.
  cp -f "$SRC" "${LIB_DIR}/${name}"
  cp -f "$SRC" "${BUNDLE}/${name}"
done

echo "==> verify overlay inventory"
for name in "${DEST_NAMES[@]}"; do
  test -e "${LIB_DIR}/${name}"
  test -e "${BUNDLE}/${name}"
done

echo "staged ${OS}/${ARCH} from ${TAG} (${ASSET}):"
ls -la "$LIB_DIR"
ls -la "$BUNDLE"
