#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${CCC_INSTALL_DIR:-$HOME/Applications}"
TARGET_APP_DIR="$INSTALL_DIR/CCC.app"
BUILT_APP_DIR="$("$ROOT_DIR/scripts/build-app.sh")"

mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET_APP_DIR"
ditto "$BUILT_APP_DIR" "$TARGET_APP_DIR"

echo "$TARGET_APP_DIR"
