#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/ccc-env.sh"

APP_DIR="${1:-${CCC_APP_PATH:-$ROOT_DIR/dist/$CCC_BUNDLE_NAME}}"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
BIN_PATH="$APP_DIR/Contents/MacOS/$CCC_BINARY_NAME"
PROMPTS_DIR="$APP_DIR/Contents/Resources/Prompts"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

ccc_info "Running smoke test for $APP_DIR"

[[ -d "$APP_DIR" ]] || ccc_fail "App bundle not found at $APP_DIR"
[[ -f "$INFO_PLIST" ]] || ccc_fail "Missing Info.plist at $INFO_PLIST"
[[ -x "$BIN_PATH" ]] || ccc_fail "Missing executable binary at $BIN_PATH"
[[ -d "$PROMPTS_DIR" ]] || ccc_fail "Missing prompts directory at $PROMPTS_DIR"
[[ -x "$PLIST_BUDDY" ]] || ccc_fail "Missing PlistBuddy at $PLIST_BUDDY"

if [[ -z "$(find "$PROMPTS_DIR" -type f 2>/dev/null | head -n 1)" ]]; then
  ccc_fail "Prompt resources were not copied into $PROMPTS_DIR"
fi

if ! "$PLIST_BUDDY" -c "Print CFBundleExecutable" "$INFO_PLIST" >/dev/null 2>&1; then
  ccc_fail "Info.plist is unreadable or missing CFBundleExecutable"
fi

if [[ "$("$PLIST_BUDDY" -c "Print CFBundleExecutable" "$INFO_PLIST" 2>/dev/null)" != "$CCC_BINARY_NAME" ]]; then
  ccc_fail "CFBundleExecutable does not match expected binary name '$CCC_BINARY_NAME'"
fi

ccc_info "Smoke test passed"
print -r -- "$APP_DIR"
