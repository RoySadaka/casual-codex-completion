#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/ccc-env.sh"

INSTALL_DIR="${CCC_INSTALL_DIR:-$HOME/Applications}"
TARGET_APP_DIR="$INSTALL_DIR/$CCC_BUNDLE_NAME"

ccc_info "Running installer preflight"
ccc_preflight_build "$ROOT_DIR"

ccc_info "Building app"
BUILT_APP_DIR="$("$ROOT_DIR/scripts/build-app.sh")"

ccc_info "Copying to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET_APP_DIR"
ditto "$BUILT_APP_DIR" "$TARGET_APP_DIR"

ccc_info "Running post-install smoke test"
"$ROOT_DIR/scripts/smoke-test-app.sh" "$TARGET_APP_DIR" >/dev/null

ccc_info "Install complete"
ccc_info "App bundle: $TARGET_APP_DIR"
ccc_info "Logs: $HOME/Library/Logs/CCC/ccc.log"
print -r -- "$TARGET_APP_DIR"
