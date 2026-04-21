#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/ccc-env.sh"

MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"
BUILD_DIR="$ROOT_DIR/.build/release-app"
APP_DIR="$ROOT_DIR/dist/$CCC_BUNDLE_NAME"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
OUTPUT_BIN="$MACOS_DIR/$CCC_BINARY_NAME"
SDK_PATH=""

ccc_preflight_build "$ROOT_DIR"
SDK_PATH="$(ccc_sdk_path)"

ccc_info "Building $CCC_BUNDLE_NAME"
ccc_info "Using deployment target macOS $CCC_MIN_MACOS_VERSION ($CCC_SWIFT_TARGET)"
ccc_info "Using SDK $SDK_PATH"
mkdir -p "$MODULE_CACHE_DIR" "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

typeset -a SWIFT_SOURCES
SWIFT_SOURCES=("${(@f)$(find "$ROOT_DIR/Sources/CCCApp" -name '*.swift' | sort)}")

ccc_info "Compiling Swift sources"
swiftc \
  -O \
  -sdk "$SDK_PATH" \
  -target "$CCC_SWIFT_TARGET" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  "${SWIFT_SOURCES[@]}" \
  -o "$OUTPUT_BIN"

ccc_info "Copying bundle resources"
cp "$ROOT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
rsync -a "$ROOT_DIR/Resources/Prompts/" "$RESOURCES_DIR/Prompts/"

if command -v codesign >/dev/null 2>&1; then
  ccc_info "Codesigning app bundle"
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

ccc_info "Build complete: $APP_DIR"
print -r -- "$APP_DIR"
