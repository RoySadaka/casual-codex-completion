#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"
BUILD_DIR="$ROOT_DIR/.build/release-app"
APP_DIR="$ROOT_DIR/dist/CCC.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
OUTPUT_BIN="$MACOS_DIR/CCC"
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

mkdir -p "$MODULE_CACHE_DIR" "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

typeset -a SWIFT_SOURCES
SWIFT_SOURCES=("${(@f)$(find "$ROOT_DIR/Sources/CCCApp" -name '*.swift' | sort)}")

swiftc \
  -O \
  -sdk "$(sdk_path)" \
  -target "$SWIFT_TARGET" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  "${SWIFT_SOURCES[@]}" \
  -o "$OUTPUT_BIN"

cp "$ROOT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
rsync -a "$ROOT_DIR/Resources/Prompts/" "$RESOURCES_DIR/Prompts/"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "$APP_DIR"
