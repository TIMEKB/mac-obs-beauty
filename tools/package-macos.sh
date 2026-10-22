#!/bin/bash
# Package the redistributable adapter; proprietary runtimes/models are excluded.
set -euo pipefail
source "$(dirname "$0")/release-common.sh"
[[ "$(uname -s)" == Darwin ]] || lb_die 'Packaging requires macOS.'
lb_scan source "$LB_PROJECT_ROOT"
plugin="$LB_BUILD_DIR/obs-live-beauty.plugin"
installer="$LB_BUILD_DIR/$LB_INSTALLER_NAME"
[[ -d "$plugin" && -x "$installer" ]] || lb_die 'Run tools/build-macos.sh first.'
for required in resources/install-manifest.json data/windows-catalog.json README.md LICENSE THIRD-PARTY.md ACKNOWLEDGMENTS.md; do
  [[ -f "$LB_PROJECT_ROOT/$required" ]] || lb_die "Missing package input: $required"
done
[[ -d "$LB_PROJECT_ROOT/data/detector" ]] || lb_die 'Missing data/detector metadata directory.'
lb_clean_bundle_metadata "$plugin"
lb_scan plugin "$plugin"
mkdir -p "$LB_DIST_DIR" "$LB_BUILD_DIR"
# Assemble/sign on the native temporary filesystem, so ExFAT cannot synthesize
# AppleDouble sidecars while codesign and xattr walk the bundle.
LB_PACKAGE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/obs-live-beauty-package.XXXXXX")"
trap 'rm -rf "$LB_PACKAGE_STAGE"' EXIT
app="$LB_PACKAGE_STAGE/$LB_APP_NAME"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lb_copy "$installer" "$app/Contents/MacOS/$LB_INSTALLER_NAME"
chmod 755 "$app/Contents/MacOS/$LB_INSTALLER_NAME"
lb_copy "$plugin" "$app/Contents/Resources/obs-live-beauty.plugin"
lb_copy "$LB_PROJECT_ROOT/resources/install-manifest.json" "$app/Contents/Resources/install-manifest.json"
lb_copy "$LB_PROJECT_ROOT/data/windows-catalog.json" "$app/Contents/Resources/windows-catalog.json"
lb_copy "$LB_PROJECT_ROOT/data/detector" "$app/Contents/Resources/detector"
lb_copy "$LB_PROJECT_ROOT/LICENSE" "$app/Contents/Resources/LICENSE"
for document in README.md README.en.md THIRD-PARTY.md ACKNOWLEDGMENTS.md AGENTS.md; do
  [[ ! -f "$LB_PROJECT_ROOT/$document" ]] || lb_copy "$LB_PROJECT_ROOT/$document" "$app/Contents/Resources/$document"
done
for notice in "$LB_PROJECT_ROOT"/LICENSE-* "$LB_PROJECT_ROOT"/NOTICE "$LB_PROJECT_ROOT"/NOTICE.md; do
  [[ ! -f "$notice" ]] || lb_copy "$notice" "$app/Contents/Resources/$(basename "$notice")"
done
"$LB_PYTHON" - "$app/Contents/Info.plist" "$LB_VERSION" "$LB_INSTALLER_NAME" "$LB_MIN_MACOS" <<'PY'
import plistlib, sys
path, version, executable, minimum = sys.argv[1:]
with open(path, 'wb') as f:
    plistlib.dump({
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleDisplayName': 'Install OBS Live Beauty',
        'CFBundleExecutable': executable,
        'CFBundleIdentifier': 'io.github.timekb.obs-live-beauty.installer',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'Install OBS Live Beauty',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': version,
        'CFBundleVersion': version,
        'LSMinimumSystemVersion': minimum,
        'NSHighResolutionCapable': True,
        'NSPrincipalClass': 'NSApplication',
    }, f)
PY
lb_clean_bundle_metadata "$app"
# Clear only real staged entries. Attribute cleanup is best effort because an
# unsupported attribute must not mask the later strict allowlist/signature checks.
if ! /usr/bin/find "$app" \( -name '._*' -o -name '.DS_Store' \) -prune -o -exec /usr/bin/xattr -c {} +; then
  printf 'Note: some staging attributes could not be cleared; strict payload/signature checks follow.\n' >&2
fi
lb_clean_bundle_metadata "$app"
lb_scan app "$app"
lb_sign "$app/Contents/Resources/obs-live-beauty.plugin"
lb_sign "$app"
lb_clean_bundle_metadata "$app"
/usr/bin/codesign --verify --strict "$app/Contents/Resources/obs-live-beauty.plugin"
/usr/bin/codesign --verify --strict "$app"

zip="$LB_PACKAGE_STAGE/$LB_ARTIFACT_BASE.zip"
dmg="$LB_PACKAGE_STAGE/$LB_ARTIFACT_BASE.dmg"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noacl --noqtn --keepParent "$app" "$zip"
stage="$LB_PACKAGE_STAGE/dmg-root"
mkdir -p "$stage"
lb_copy "$app" "$stage/$LB_APP_NAME"
lb_clean_bundle_metadata "$stage/$LB_APP_NAME"
# ExFAT can also put a sidecar next to the copied .app in this generated staging directory.
/usr/bin/find "$stage" -maxdepth 1 -type f \( -name '._*' -o -name '.DS_Store' \) -delete
/usr/bin/hdiutil create -quiet -ov -format UDZO -fs HFS+ \
  -volname "OBS Live Beauty $LB_VERSION" -srcfolder "$stage" "$dmg"
if [[ "${LB_CODESIGN_IDENTITY:--}" != '-' ]]; then
  /usr/bin/codesign --force --timestamp --sign "$LB_CODESIGN_IDENTITY" "$dmg"
fi
# Only completed archives cross back to the output volume. A plain .app is also
# provided for local inspection; its contents must pass the same strict checks.
dist_app="$LB_DIST_DIR/$LB_APP_NAME"
rm -rf "$dist_app"
lb_copy "$app" "$dist_app"
lb_clean_bundle_metadata "$dist_app"
lb_copy "$zip" "$LB_DIST_DIR/$LB_ARTIFACT_BASE.zip"
lb_copy "$dmg" "$LB_DIST_DIR/$LB_ARTIFACT_BASE.dmg"
(
  cd "$LB_DIST_DIR"
  /usr/bin/shasum -a 256 "$LB_ARTIFACT_BASE.dmg" "$LB_ARTIFACT_BASE.zip" > SHA256SUMS
)
printf '\nPackaged %s\n' "$LB_DIST_DIR"
if [[ "${LB_CODESIGN_IDENTITY:--}" == '-' ]]; then
  printf 'Signature: ad-hoc. No Developer ID or notarization is claimed.\n'
else
  printf 'Signature: supplied Developer ID identity. Notarization was not performed.\n'
fi
"$LB_PROJECT_ROOT/tools/verify-release.sh" "$LB_DIST_DIR"
