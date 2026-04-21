#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/ccc-env.sh"

ccc_info "Building release app bundle"
APP_DIR="$("$ROOT_DIR/scripts/build-app.sh")"
ARCHIVE_PATH="$ROOT_DIR/dist/${CCC_APP_NAME}-macos.zip"

ccc_info "Packaging release zip"
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"

ccc_info "Release artifact: $ARCHIVE_PATH"
print -r -- "$ARCHIVE_PATH"
