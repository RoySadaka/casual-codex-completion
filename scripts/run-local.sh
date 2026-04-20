#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"
BUILD_DIR="$ROOT_DIR/.build/debug-local"
OUTPUT_BIN="$BUILD_DIR/CCC"
CONFIG_DIR="$ROOT_DIR/.local"
CONFIG_FILE="$CONFIG_DIR/config.toml"
STATE_DIR="$CONFIG_DIR/state"
MIN_MACOS_VERSION="${CCC_MIN_MACOS_VERSION:-13.0}"
SWIFT_TARGET="$(uname -m)-apple-macos${MIN_MACOS_VERSION}"

sdk_path() {
  local candidate
  for candidate in \
    /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX13.1.sdk
  do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  echo "Unable to find a usable macOS SDK." >&2
  exit 1
}

mkdir -p "$MODULE_CACHE_DIR" "$BUILD_DIR" "$CONFIG_DIR" "$STATE_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
  cp "$ROOT_DIR/Support/config.example.toml" "$CONFIG_FILE"
fi

typeset -a SWIFT_SOURCES
SWIFT_SOURCES=("${(@f)$(find "$ROOT_DIR/Sources/CCCApp" -name '*.swift' | sort)}")

swiftc \
  -sdk "$(sdk_path)" \
  -target "$SWIFT_TARGET" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  "${SWIFT_SOURCES[@]}" \
  -o "$OUTPUT_BIN"

export CCC_PROJECT_ROOT="$ROOT_DIR"
export CCC_CONFIG_FILE="$CONFIG_FILE"
export CCC_APP_SUPPORT_DIR="$STATE_DIR"

exec "$OUTPUT_BIN"
