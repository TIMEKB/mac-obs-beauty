#!/bin/bash
# Shared release settings. Sourcing this file never installs or launches anything.
set -euo pipefail

LB_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LB_BUILD_DIR="${LB_BUILD_DIR:-$LB_PROJECT_ROOT/build}"
LB_DIST_DIR="${LB_DIST_DIR:-$LB_PROJECT_ROOT/dist}"
LB_APP_NAME="Install OBS Live Beauty.app"
LB_INSTALLER_NAME="obs-live-beauty-installer"
LB_ARCH="arm64"
LB_MIN_MACOS="13.0"
export COPYFILE_DISABLE=1
if [[ -z "${DEVELOPER_DIR:-}" && -x /Library/Developer/CommandLineTools/usr/bin/clang++ ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
if [[ -z "${LB_PYTHON:-}" ]]; then
  LB_PYTHON="$(command -v python3 || true)"
  if [[ -x /opt/homebrew/bin/python3 && ( -z "$LB_PYTHON" || "$LB_PYTHON" == /usr/bin/python3 ) ]]; then
    LB_PYTHON=/opt/homebrew/bin/python3
  fi
fi

lb_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
lb_need() { command -v "$1" >/dev/null 2>&1 || lb_die "Required tool not found: $1"; }
lb_need "$LB_PYTHON"
LB_VERSION="$("$LB_PYTHON" - "$LB_PROJECT_ROOT/CMakeLists.txt" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r'project\s*\(\s*obs-live-beauty\s+VERSION\s+([0-9]+\.[0-9]+\.[0-9]+)', text, re.I)
if not m:
    raise SystemExit('Cannot read the project version from CMakeLists.txt')
print(m[1])
PY
)"
LB_ARTIFACT_BASE="obs-live-beauty-$LB_VERSION-macos-$LB_ARCH"

lb_select_developer_dir() {
  # An explicit developer directory is preserved; otherwise the common setup chose CLT.
  /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null || lb_die 'A usable macOS SDK is required.'
}

lb_scan() { "$LB_PYTHON" "$LB_PROJECT_ROOT/tools/scan-release.py" "$@"; }

lb_copy() {
  # AppleDouble, extended attributes and resource forks are not release inputs.
  COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr --noacl --noqtn "$1" "$2"
}

lb_clean_bundle_metadata() {
  local path="$1"
  # ExFAT can create AppleDouble files even while building/copying an original bundle.
  # Restrict cleanup to generated bundles; never clean the source tree or installed apps.
  case "$path" in
    "$LB_BUILD_DIR/"*.plugin|"$LB_BUILD_DIR/"*.app|"$LB_DIST_DIR/"*.plugin|"$LB_DIST_DIR/"*.app) ;;
    *)
      if [[ -z "${LB_PACKAGE_STAGE:-}" || "$path" != "$LB_PACKAGE_STAGE/"* ]]; then
        lb_die "Refusing metadata cleanup outside a generated bundle: $path"
      fi
      case "$path" in *.plugin|*.app) ;; *) lb_die 'Metadata cleanup requires a generated bundle.' ;; esac
      ;;
  esac
  [[ -d "$path" && ! -L "$path" ]] || lb_die 'Generated bundle is missing or is a symlink.'
  /usr/bin/find "$path" -type f \( -name '._*' -o -name '.DS_Store' \) -delete
}

lb_sign() {
  local path="$1"
  local identity="${LB_CODESIGN_IDENTITY:--}"
  if [[ "$identity" == '-' ]]; then
    /usr/bin/codesign --force --sign - "$path"
  else
    /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$path"
  fi
}
