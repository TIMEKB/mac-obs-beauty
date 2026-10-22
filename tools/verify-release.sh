#!/bin/bash
# Read-only release checks; mounting a DMG does not install or launch the app.
set -euo pipefail
source "$(dirname "$0")/release-common.sh"
[[ "$(uname -s)" == Darwin ]] || lb_die 'Release verification requires macOS.'
if [[ $# -gt 0 ]]; then LB_DIST_DIR="$1"; fi
app="$LB_DIST_DIR/$LB_APP_NAME"
zip="$LB_DIST_DIR/$LB_ARTIFACT_BASE.zip"
dmg="$LB_DIST_DIR/$LB_ARTIFACT_BASE.dmg"
for required in "$app" "$zip" "$dmg" "$LB_DIST_DIR/SHA256SUMS"; do
  [[ -e "$required" ]] || lb_die "Missing release artifact: $required"
done
lb_scan source "$LB_PROJECT_ROOT"
lb_scan app "$app"
lb_scan zip "$zip" --compare-app "$app"
"$LB_PYTHON" - "$app" "$LB_VERSION" "$LB_DIST_DIR/SHA256SUMS" "$LB_ARTIFACT_BASE" <<'PY'
import pathlib, plistlib, re, sys
app = pathlib.Path(sys.argv[1])
p = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert p['CFBundleIdentifier'] == 'io.github.timekb.obs-live-beauty.installer', 'Wrong installer identifier'
assert p['CFBundleShortVersionString'] == sys.argv[2], 'Installer version differs from source'
assert p['CFBundleVersion'] == sys.argv[2], 'Installer build version differs from source'
plugin = plistlib.loads((app/'Contents/Resources/obs-live-beauty.plugin/Contents/Info.plist').read_bytes())
assert plugin['CFBundleShortVersionString'] == sys.argv[2], 'Plugin version differs from source'
checksums = pathlib.Path(sys.argv[3]).read_text().splitlines()
expected = {sys.argv[4] + '.dmg', sys.argv[4] + '.zip'}
actual = set()
for line in checksums:
    match = re.fullmatch(r'([a-f0-9]{64})  ([^/]+)', line)
    assert match, 'Invalid SHA256SUMS line'
    assert match[2] not in actual, 'Duplicate checksum entry'
    actual.add(match[2])
assert actual == expected, 'SHA256SUMS must contain exactly the DMG and ZIP'
print('Bundle identifiers and versions: OK')
PY
for executable in "$app/Contents/MacOS/$LB_INSTALLER_NAME" \
  "$app/Contents/Resources/obs-live-beauty.plugin/Contents/MacOS/obs-live-beauty"; do
  [[ "$(/usr/bin/lipo -archs "$executable")" == "$LB_ARCH" ]] || lb_die "Unexpected architecture: $executable"
  printf '\nArchitecture: %s (%s)\n' "$LB_ARCH" "$(basename "$executable")"
  /usr/bin/otool -L "$executable"
done
/usr/bin/codesign --verify --strict --verbose=2 "$app/Contents/Resources/obs-live-beauty.plugin"
/usr/bin/codesign --verify --strict --verbose=2 "$app"
(
  cd "$LB_DIST_DIR"
  /usr/bin/shasum -a 256 -c SHA256SUMS
)
/usr/bin/hdiutil verify -quiet "$dmg"
mount="$(mktemp -d "${TMPDIR:-/tmp}/obs-live-beauty-verify.XXXXXX")"
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then /usr/bin/hdiutil detach -quiet "$mount" || true; fi
  rmdir "$mount" 2>/dev/null || true
}
trap cleanup EXIT
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg"
mounted=1
"$LB_PYTHON" - "$mount" "$LB_APP_NAME" <<'PY'
import pathlib, sys
volume = pathlib.Path(sys.argv[1])
filesystem_metadata = {'.fseventsd', '.Trashes', '.Spotlight-V100'}
unexpected = [p.name for p in volume.iterdir() if p.name != sys.argv[2] and p.name not in filesystem_metadata]
assert not unexpected, 'Unexpected files at DMG root: ' + ', '.join(unexpected)
print('DMG root allowlist: OK')
PY
lb_scan app "$mount/$LB_APP_NAME"
/usr/bin/codesign --verify --strict "$mount/$LB_APP_NAME"
/usr/bin/diff -qr "$app" "$mount/$LB_APP_NAME" >/dev/null || lb_die 'DMG bundle differs from the ZIP/source bundle.'
printf '\nPASS: source and artifact allowlists, arm64 binaries, signatures, matching ZIP/DMG payloads, and SHA-256 checksums.\n'
printf 'No installation, OBS restart, or live camera verification was performed.\n'
