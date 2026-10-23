#!/bin/bash
# Read-only payload verification; never installs the PKG or starts OBS.
set -euo pipefail
source "$(dirname "$0")/release-common.sh"
if [[ $# -gt 0 ]]; then LB_DIST_DIR="$1"; fi
kit="$LB_DIST_DIR/Mac OBS Beauty"
zip="$LB_DIST_DIR/$LB_ARTIFACT_BASE.zip"
pkg="$LB_DIST_DIR/$LB_ARTIFACT_BASE.pkg"
for required in "$kit" "$zip" "$pkg" "$LB_DIST_DIR/SHA256SUMS"; do [[ -e "$required" ]] || lb_die "Missing artifact: $required"; done
lb_scan source "$LB_PROJECT_ROOT"
lb_scan kit "$kit"
verify_temp="$(mktemp -d "${TMPDIR:-/tmp}/mac-obs-release-verify.XXXXXX")"
trap 'rm -rf "$verify_temp"' EXIT
/usr/bin/ditto -x -k "$zip" "$verify_temp/zip"
lb_scan kit "$verify_temp/zip"
/usr/bin/diff -qr "$kit" "$verify_temp/zip" >/dev/null || lb_die 'ZIP differs from staged payload.'
/usr/sbin/pkgutil --expand-full "$pkg" "$verify_temp/pkg"
expanded="$verify_temp/pkg/component.pkg/Payload"
lb_scan kit "$expanded"
/usr/bin/diff -qr "$kit" "$expanded" >/dev/null || lb_die 'PKG differs from staged payload.'
/usr/bin/cmp "$LB_PROJECT_ROOT/installer/postinstall.sh" "$verify_temp/pkg/component.pkg/Scripts/postinstall" || lb_die 'PKG postinstall differs from source.'
"$LB_PYTHON" - "$kit" "$LB_VERSION" "$verify_temp/pkg" "$LB_DIST_DIR/SHA256SUMS" "$LB_ARTIFACT_BASE" <<'PY'
import pathlib, plistlib, re, sys, xml.etree.ElementTree as ET
kit=pathlib.Path(sys.argv[1]); version=sys.argv[2]; expanded=pathlib.Path(sys.argv[3])
p=plistlib.loads((kit/'obs-live-beauty.plugin/Contents/Info.plist').read_bytes())
assert p['CFBundleShortVersionString']==version
assert p['CFBundleIdentifier']=='io.github.timekb.obs-live-beauty'
assert (kit/'README-INSTALL.txt').read_bytes()==(kit/'README.install.md').read_bytes()
info=ET.parse(expanded/'component.pkg/PackageInfo').getroot()
assert info.attrib['install-location']=='/Library/Application Support/Mac OBS Beauty'
assert info.attrib['version']==version
expected={sys.argv[5]+'.pkg',sys.argv[5]+'.zip'};names=set()
for line in pathlib.Path(sys.argv[4]).read_text().splitlines():
 m=re.fullmatch(r'([a-f0-9]{64})  ([^/]+)',line);assert m and m[2] not in names;names.add(m[2])
assert names==expected
assert not list(kit.rglob('*.app'))
print('Versions, PKG installation target, checksums list, trilingual guide, and no-.app payload: OK')
PY
for binary in "$kit/$LB_INSTALLER_NAME" "$kit/obs-live-beauty.plugin/Contents/MacOS/obs-live-beauty"; do
  [[ "$(/usr/bin/lipo -archs "$binary")" == arm64 ]] || lb_die 'Expected arm64 binary.'
  /usr/bin/codesign --verify --strict "$binary"
done
/usr/bin/codesign --verify --strict "$kit/obs-live-beauty.plugin"
(cd "$LB_DIST_DIR" && /usr/bin/shasum -a 256 -c SHA256SUMS)
printf 'PASS: standard-plugin ZIP and PKG match source, signatures, architecture, allowlists and hashes. No installed applications were changed.\n'
