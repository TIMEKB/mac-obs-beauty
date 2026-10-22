#!/bin/bash
# Build only. No OBS restart, installation, SDK download, or account lookup.
set -euo pipefail
source "$(dirname "$0")/release-common.sh"
[[ "$(uname -s)" == Darwin ]] || lb_die 'This build requires macOS.'
LB_CMAKE="${LB_CMAKE:-$(command -v cmake || true)}"
if [[ -z "$LB_CMAKE" && -x /opt/homebrew/bin/cmake ]]; then LB_CMAKE=/opt/homebrew/bin/cmake; fi
lb_need "$LB_CMAKE"
lb_select_developer_dir
[[ -n "${OBS_SDK_ROOT:-}" ]] || lb_die 'Set OBS_SDK_ROOT to the OBS header SDK directory.'
LB_QT_INCLUDE_ROOT="${LB_QT_INCLUDE_ROOT:-$OBS_SDK_ROOT/qt6/include}"
OBS_APP="${OBS_APP:-/Applications/OBS.app}"
[[ -f "$OBS_SDK_ROOT/libobs/obs-module.h" ]] || lb_die 'OBS_SDK_ROOT is missing libobs/obs-module.h.'
[[ -f "$OBS_SDK_ROOT/frontend/api/obs-frontend-api.h" ]] || lb_die 'OBS_SDK_ROOT is missing frontend/api/obs-frontend-api.h.'
[[ -f "$LB_QT_INCLUDE_ROOT/QtWidgets/QApplication" ]] || lb_die 'LB_QT_INCLUDE_ROOT is missing QtWidgets/QApplication.'
[[ -d "$OBS_APP/Contents/Frameworks/libobs.framework" ]] || lb_die 'OBS_APP must point to a compatible installed OBS application.'
[[ -f "$LB_PROJECT_ROOT/installer/main.mm" ]] || lb_die 'installer/main.mm is required to build the installer.'
lb_scan source "$LB_PROJECT_ROOT"
mkdir -p "$LB_BUILD_DIR"

# Keep local source/SDK locations out of __FILE__ and compiler debug paths.
prefix_flags="$("$LB_PYTHON" - "$LB_PROJECT_ROOT" "$OBS_SDK_ROOT" "$LB_QT_INCLUDE_ROOT" <<'PY'
import shlex, sys
flags = []
for path, public in zip(sys.argv[1:], ('.', 'obs-sdk', 'qt-include')):
    flags.extend(f'-{kind}-prefix-map={path}={public}' for kind in ('ffile', 'fdebug'))
print(shlex.join(flags))
PY
)"
"$LB_CMAKE" -S "$LB_PROJECT_ROOT" -B "$LB_BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_OSX_ARCHITECTURES="$LB_ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$LB_MIN_MACOS" \
  -DCMAKE_C_FLAGS="${CFLAGS:-} $prefix_flags" \
  -DCMAKE_CXX_FLAGS="${CXXFLAGS:-} $prefix_flags" \
  -DCMAKE_OBJCXX_FLAGS="${OBJCXXFLAGS:-} $prefix_flags" \
  -DOBS_APP="$OBS_APP" -DOBS_SDK_ROOT="$OBS_SDK_ROOT" \
  -DLB_QT_INCLUDE_ROOT="$LB_QT_INCLUDE_ROOT" -DLB_BUILD_STUB=OFF
"$LB_CMAKE" --build "$LB_BUILD_DIR" --config Release --parallel "${LB_JOBS:-4}"

installer_flags=("-ffile-prefix-map=$LB_PROJECT_ROOT=." "-fdebug-prefix-map=$LB_PROJECT_ROOT=.")
/usr/bin/xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -fblocks -O2 -Wall -Wextra \
  -arch "$LB_ARCH" "-mmacosx-version-min=$LB_MIN_MACOS" \
  "${installer_flags[@]}" "$LB_PROJECT_ROOT/installer/main.mm" \
  -framework AppKit -framework Foundation -framework Security \
  -o "$LB_BUILD_DIR/$LB_INSTALLER_NAME"
[[ -f "$LB_BUILD_DIR/obs-live-beauty.plugin/Contents/MacOS/obs-live-beauty" ]] || lb_die 'CMake did not produce the expected plugin bundle.'
lb_clean_bundle_metadata "$LB_BUILD_DIR/obs-live-beauty.plugin"
lb_scan plugin "$LB_BUILD_DIR/obs-live-beauty.plugin"
printf '\nBuilt plugin and native installer in %s\nNext: tools/package-macos.sh\n' "$LB_BUILD_DIR"
