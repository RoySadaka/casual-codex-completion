#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/ccc-env.sh"

INSTALL_DIR="${CCC_INSTALL_DIR:-$HOME/Applications}"
APP_SUPPORT_DIR="${CCC_APP_SUPPORT_DIR:-$HOME/Library/Application Support/$CCC_APP_NAME}"
LOGS_DIR="${CCC_LOGS_DIR:-$HOME/Library/Logs/$CCC_APP_NAME}"
TARGET_APP_DIR="$INSTALL_DIR/$CCC_BUNDLE_NAME"

remove_path_if_present() {
  local target_path="$1"

  if [[ -e "$target_path" ]]; then
    ccc_info "Removing $target_path"
    rm -rf "$target_path"
  else
    ccc_info "Skipping missing path $target_path"
  fi
}

ccc_info "Uninstalling $CCC_APP_NAME"
remove_path_if_present "$TARGET_APP_DIR"
remove_path_if_present "$APP_SUPPORT_DIR"
remove_path_if_present "$LOGS_DIR"

ccc_info "Uninstall complete"
