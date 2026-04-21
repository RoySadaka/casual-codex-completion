#!/bin/zsh

# Shared script helpers for CCC build, install, and packaging workflows.

if [[ -n "${CCC_ENV_SH_LOADED:-}" ]]; then
  return 0
fi
readonly CCC_ENV_SH_LOADED=1

: "${CCC_APP_NAME:=CCC}"
: "${CCC_BINARY_NAME:=CCC}"
: "${CCC_BUNDLE_NAME:=${CCC_APP_NAME}.app}"
: "${CCC_MIN_MACOS_VERSION:=13.0}"

export CCC_APP_NAME
export CCC_BINARY_NAME
export CCC_BUNDLE_NAME
export CCC_MIN_MACOS_VERSION
export CCC_SWIFT_TARGET="${CCC_SWIFT_TARGET:-$(uname -m)-apple-macos${CCC_MIN_MACOS_VERSION}}"

ccc_info() {
  print -u2 -r -- "==> $*"
}

ccc_warn() {
  print -u2 -r -- "warning: $*"
}

ccc_fail() {
  print -u2 -r -- "error: $*"
  exit 1
}

ccc_require_tool() {
  local tool_name="$1"
  local install_hint="${2:-Install Xcode Command Line Tools or full Xcode, then retry.}"

  if ! command -v "$tool_name" >/dev/null 2>&1; then
    ccc_fail "Missing required tool '$tool_name'. $install_hint"
  fi
}

ccc_sdk_path() {
  local candidate=""

  if command -v xcrun >/dev/null 2>&1; then
    candidate="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    if [[ -n "$candidate" && -d "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  fi

  for candidate in \
    /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX13.1.sdk
  do
    if [[ -d "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done

  return 1
}

ccc_preflight_build() {
  local root_dir="$1"
  local -a problems
  local sdk_path=""

  problems=()

  command -v swiftc >/dev/null 2>&1 || problems+=("Missing required tool 'swiftc'. Install Xcode Command Line Tools or full Xcode.")
  command -v xcrun >/dev/null 2>&1 || problems+=("Missing required tool 'xcrun'. Install Xcode Command Line Tools or full Xcode.")
  command -v ditto >/dev/null 2>&1 || problems+=("Missing required tool 'ditto'.")
  command -v rsync >/dev/null 2>&1 || problems+=("Missing required tool 'rsync'.")
  command -v find >/dev/null 2>&1 || problems+=("Missing required tool 'find'.")

  if [[ ! -d "$root_dir/Sources/CCCApp" ]]; then
    problems+=("Missing source directory: $root_dir/Sources/CCCApp")
  fi

  if [[ ! -f "$root_dir/Support/Info.plist" ]]; then
    problems+=("Missing app bundle metadata: $root_dir/Support/Info.plist")
  fi

  if [[ ! -d "$root_dir/Resources/Prompts" ]]; then
    problems+=("Missing prompt resources: $root_dir/Resources/Prompts")
  fi

  if command -v swiftc >/dev/null 2>&1 && command -v xcrun >/dev/null 2>&1; then
    sdk_path="$(ccc_sdk_path || true)"
    if [[ -z "$sdk_path" ]]; then
      problems+=("Unable to locate a usable macOS SDK. Open Xcode once or run 'xcode-select --install', then retry.")
    fi
  fi

  if (( ${#problems[@]} > 0 )); then
    print -u2 -r -- "CCC install/build preflight failed:"
    local problem
    for problem in "${problems[@]}"; do
      print -u2 -r -- " - $problem"
    done
    exit 1
  fi
}
