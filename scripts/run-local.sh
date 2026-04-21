#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/ccc-env.sh"

MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"
BUILD_DIR="$ROOT_DIR/.build/debug-local"
OUTPUT_BIN="$BUILD_DIR/$CCC_BINARY_NAME"
CONFIG_DIR="$ROOT_DIR/.local"
CONFIG_FILE="$CONFIG_DIR/config.toml"
STATE_DIR="$CONFIG_DIR/state"
SDK_PATH=""

ccc_preflight_build "$ROOT_DIR"
SDK_PATH="$(ccc_sdk_path)"

ccc_info "Preparing local development build"
ccc_info "Using deployment target macOS $CCC_MIN_MACOS_VERSION ($CCC_SWIFT_TARGET)"
mkdir -p "$MODULE_CACHE_DIR" "$BUILD_DIR" "$CONFIG_DIR" "$STATE_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
  ccc_info "Creating local config from template"
  cp "$ROOT_DIR/Support/config.example.toml" "$CONFIG_FILE"
fi

typeset -a SWIFT_SOURCES
SWIFT_SOURCES=("${(@f)$(find "$ROOT_DIR/Sources/CCCApp" -name '*.swift' | sort)}")

ccc_info "Compiling local binary"
swiftc \
  -sdk "$SDK_PATH" \
  -target "$CCC_SWIFT_TARGET" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  "${SWIFT_SOURCES[@]}" \
  -o "$OUTPUT_BIN"

export CCC_PROJECT_ROOT="$ROOT_DIR"
export CCC_CONFIG_FILE="$CONFIG_FILE"
export CCC_APP_SUPPORT_DIR="$STATE_DIR"

ccc_info "Launching local app"
exec "$OUTPUT_BIN"
