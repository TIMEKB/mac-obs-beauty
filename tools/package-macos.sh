#!/bin/bash
# Standard OBS plugin distribution. No standalone .app, vendor SDK or models.
set -euo pipefail
source "$(dirname "$0")/release-common.sh"
[[ "$(uname -s)" == Darwin ]] || lb_die 'Packaging requires macOS.'
lb_scan source "$LB_PROJECT_ROOT"
plugin="$LB_BUILD_DIR/obs-live-beauty.plugin"
installer="$LB_BUILD_DIR/$LB_INSTALLER_NAME"
[[ -d "$plugin" && -x "$installer" ]] || lb_die 'Run tools/build-macos.sh first.'
LB_PACKAGE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mac-obs-beauty-package.XXXXXX")"
trap 'rm -rf "$LB_PACKAGE_STAGE"' EXIT
kit="$LB_PACKAGE_STAGE/kit"
mkdir -p "$kit" "$LB_DIST_DIR"
lb_copy "$plugin" "$kit/obs-live-beauty.plugin"
lb_copy "$installer" "$kit/$LB_INSTALLER_NAME"
lb_copy "$LB_PROJECT_ROOT/resources/install-manifest.json" "$kit/install-manifest.json"
lb_copy "$LB_PROJECT_ROOT/data/windows-catalog.json" "$kit/windows-catalog.json"
lb_copy "$LB_PROJECT_ROOT/data/detector" "$kit/detector"
lb_copy "$LB_PROJECT_ROOT/installer/install.command" "$kit/install.command"
for document in README.md README.en.md README.ja.md README.install.md AGENTS.md LICENSE THIRD-PARTY.md ACKNOWLEDGMENTS.md; do
  lb_copy "$LB_PROJECT_ROOT/$document" "$kit/$document"
done
lb_copy "$LB_PROJECT_ROOT/README.install.md" "$kit/README-INSTALL.txt"
/usr/bin/find "$kit" -type f \( -name '._*' -o -name '.DS_Store' \) -delete
/usr/bin/find "$kit" -type f -exec chmod 644 {} +
chmod 755 "$kit/$LB_INSTALLER_NAME" "$kit/install.command" "$kit/obs-live-beauty.plugin/Contents/MacOS/obs-live-beauty"
/usr/bin/find "$kit" -exec /usr/bin/xattr -c {} + 2>/dev/null || true
lb_sign "$kit/obs-live-beauty.plugin"
lb_sign "$kit/$LB_INSTALLER_NAME"
lb_scan kit "$kit"
/usr/bin/codesign --verify --strict "$kit/obs-live-beauty.plugin"
/usr/bin/codesign --verify --strict "$kit/$LB_INSTALLER_NAME"
zip="$LB_PACKAGE_STAGE/$LB_ARTIFACT_BASE.zip"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noacl --noqtn "$kit" "$zip"
scripts="$LB_PACKAGE_STAGE/scripts"
mkdir -p "$scripts"
lb_copy "$LB_PROJECT_ROOT/installer/postinstall.sh" "$scripts/postinstall"
chmod 755 "$scripts/postinstall"
/usr/bin/pkgbuild --root "$kit" --scripts "$scripts" --ownership recommended \
  --identifier io.github.timekb.mac-obs-beauty.setup --version "$LB_VERSION" \
  --install-location '/Library/Application Support/Mac OBS Beauty' "$LB_PACKAGE_STAGE/component.pkg" >/dev/null
"$LB_PYTHON" - "$LB_PACKAGE_STAGE" "$LB_PROJECT_ROOT/README.install.md" "$LB_VERSION" <<'PY'
import html, pathlib, sys
p=pathlib.Path(sys.argv[1]); resources=p/'installer-resources';resources.mkdir()
text=pathlib.Path(sys.argv[2]).read_text()
(resources/'welcome.html').write_text('<html><meta charset="utf-8"><body style="font:13px -apple-system"><pre style="white-space:pre-wrap">'+html.escape(text)+'</pre></body></html>')
(resources/'conclusion.html').write_text('<html><meta charset="utf-8"><body><h2>插件已安装 / Plugin installed / 導入完了</h2><p>重新打开 OBS，在停靠窗口或工具菜单中打开「直播美颜」。安装过程无需依赖向导或二次安装。缺少美颜运行资源时，首次打开面板会提供处理入口。</p><p>Restart OBS and open Live Beauty under Docks or Tools. The standard plugin is installed directly; runtime setup is offered inside OBS only if needed.</p><p>OBS を再起動し、ドックまたはツールから直播美颜を開いてください。プラグインは導入済みです。必要な実行素材は OBS 内で案内します。</p></body></html>')
(p/'Distribution.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
<title>Mac OBS Beauty</title>
<options customize="never" require-scripts="false" hostArchitectures="arm64"/>
<allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
<welcome file="welcome.html"/><conclusion file="conclusion.html"/>
<domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
<choices-outline><line choice="default"/></choices-outline>
<choice id="default" visible="false"><pkg-ref id="io.github.timekb.mac-obs-beauty.setup"/></choice>
<pkg-ref id="io.github.timekb.mac-obs-beauty.setup" version="'''+sys.argv[3]+'''">component.pkg</pkg-ref>
</installer-gui-script>
''')
PY
pkg="$LB_PACKAGE_STAGE/$LB_ARTIFACT_BASE.pkg"
/usr/bin/productbuild --distribution "$LB_PACKAGE_STAGE/Distribution.xml" \
  --resources "$LB_PACKAGE_STAGE/installer-resources" --package-path "$LB_PACKAGE_STAGE" "$pkg" >/dev/null
# Only build artifacts are replaced. No application or installed OBS plugin is touched.
kit_dist="$LB_DIST_DIR/Mac OBS Beauty"
rm -rf "$kit_dist"
lb_copy "$kit" "$kit_dist"
/usr/bin/find "$kit_dist" -type f \( -name '._*' -o -name '.DS_Store' \) -delete
lb_copy "$zip" "$LB_DIST_DIR/$LB_ARTIFACT_BASE.zip"
lb_copy "$pkg" "$LB_DIST_DIR/$LB_ARTIFACT_BASE.pkg"
(cd "$LB_DIST_DIR" && /usr/bin/shasum -a 256 "$LB_ARTIFACT_BASE.pkg" "$LB_ARTIFACT_BASE.zip" > SHA256SUMS)
printf 'Packaged standard .plugin ZIP and native .pkg setup; no standalone .app.\n'
printf 'Signature: ad-hoc binaries; PKG is unsigned, no Apple notarization is claimed.\n'
"$LB_PROJECT_ROOT/tools/verify-release.sh" "$LB_DIST_DIR"
