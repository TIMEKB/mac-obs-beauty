#!/usr/bin/env python3
"""Exercise native installer first-run states with isolated app/payload fixtures.
Usage: python3 tools/test-installer.py build/obs-live-beauty-installer
No real application, OBS scene, or user plugin directory is modified.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
checks = 0

def require(condition, label):
    global checks
    assert condition, label
    checks += 1
    print('PASS:', label)

with tempfile.TemporaryDirectory(prefix='mac-obs-first-run-') as temporary:
    root = Path(temporary)
    obs, companion = root/'apps/OBS.app', root/'apps/Douyin Webcast Mate.app'
    assets, resources, plugins, imports = [root/p for p in ('assets', 'resources', 'plugins', 'import')]
    assets.mkdir(); imports.mkdir()
    def write(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    def app_info(app, version, identifier):
        write(app/'Contents/Info.plist', plistlib.dumps({'CFBundleShortVersionString':version, 'CFBundleIdentifier':identifier, 'CFBundleExecutable':'fixture', 'CFBundlePackageType':'APPL'}))
    plugin = Path('obs-live-beauty.plugin/Contents/MacOS/obs-live-beauty')
    write(assets/plugin, b'own-plugin-fixture')
    write(assets/'windows-catalog.json', b'{}')
    write(assets/'detector/config.json', b'{}')
    runtime_relative = 'Contents/Resources/fixture-runtime'
    runtime_data = b'local test fixture; never loaded as a library'
    runtime = {'relative_path':runtime_relative, 'sha256':hashlib.sha256(runtime_data).hexdigest()}
    asset_data = b'local model fixture'
    spec = {'source_app_version':'10.0.0', 'obs_version':'32.2.1', 'runtime':runtime,
            'supported_runtimes':[{'version':v, 'runtime':runtime} for v in ('10.0.0', '10.0.4')],
            'models':[], 'downloads':[{'kind':'file', 'relative_path':'models/fixture', 'sha256':hashlib.sha256(asset_data).hexdigest(), 'urls':[]}]}
    write(assets/'install-manifest.json', json.dumps(spec).encode())
    write(imports/'models/fixture', asset_data)
    args = [str(binary), '--json', '--obs-app', str(obs), '--app', str(companion), '--assets-dir', str(assets), '--resource-dir', str(resources), '--plugin-dir', str(plugins)]
    def run(action='--check', extra=()):
        process = subprocess.run(args+[action]+list(extra), capture_output=True, text=True, env={**os.environ, 'PATH':'/usr/bin:/bin:/usr/sbin:/sbin'})
        result = json.loads(process.stdout)
        return process.returncode, result
    code, result = run()
    require(code == 2 and [d['status'] for d in result['dependencies']] == ['missing','missing'], 'fresh Mac: both dependencies missing')
    require(all(d['download_url'].startswith('https://') and d['instructions'] for d in result['dependencies']), 'missing dependencies include official download actions and instructions')
    require(not resources.exists() and not plugins.exists(), 'preflight does not create installation directories')
    if not result['obs_running']:
        code, plugin_result = run('--install', ['--plugin-only', '--non-interactive'])
        require(code == 0 and plugin_result['scope'] == 'plugin' and plugin_result['plugin_ready'], 'plugin-only installation succeeds with neither OBS nor companion installed')
        require(not resources.exists(), 'plugin-only installation does not download or create runtime resources')
        code, plugin_result = run('--check', ['--plugin-only'])
        require(code == 0 and plugin_result['ready'], 'plugin-only post-install check succeeds independently of runtime dependencies')
        shutil.rmtree(plugins)
    app_info(obs, '32.2.1', 'com.obsproject.obs-studio')
    write(obs/'Contents/MacOS/fixture', binary.read_bytes())
    (obs/'Contents/MacOS/fixture').chmod(0o755)
    code, result = run()
    require([d['status'] for d in result['dependencies']] == ['ready','missing'], 'OBS installed, companion still missing')
    app_info(companion, '10.0.0', 'com.bytedance.webcastmate.mac')
    write(companion/runtime_relative, runtime_data)
    code, result = run()
    require(code == 2 and all(d['ready'] for d in result['dependencies']) and not result['ready'], 'dependencies found at custom paths; plugin not installed yet')
    app_info(companion, '10.0.4', 'com.bytedance.webcastmate.mac')
    require(all(d['ready'] for d in run()[1]['dependencies']), 'second validated companion version selected')
    app_info(companion, '99.0.0', 'com.bytedance.webcastmate.mac')
    require(run()[1]['dependencies'][1]['status'] == 'unsupported_version', 'unsupported companion version offers compatible download')
    app_info(companion, '10.0.0', 'other.app')
    require(run()[1]['dependencies'][1]['status'] == 'invalid_app', 'wrong selected companion application rejected')
    app_info(companion, '10.0.0', 'com.bytedance.webcastmate.mac')
    write(companion/runtime_relative, b'changed')
    require(run()[1]['dependencies'][1]['status'] == 'runtime_mismatch', 'modified runtime rejected')
    write(companion/runtime_relative, runtime_data)
    app_info(obs, '99.0.0', 'com.obsproject.obs-studio')
    require(run()[1]['dependencies'][0]['status'] == 'unsupported_version', 'unsupported OBS version offers pinned compatible build')
    app_info(obs, '32.2.1', 'other.app')
    require(run()[1]['dependencies'][0]['status'] == 'invalid_app', 'wrong selected OBS application rejected')
    app_info(obs, '32.2.1', 'com.obsproject.obs-studio')
    (obs/'Contents/MacOS/fixture').unlink()
    require(run()[1]['dependencies'][0]['status'] == 'unsupported_architecture', 'OBS without Apple Silicon executable rejected')
    write(obs/'Contents/MacOS/fixture', binary.read_bytes()); (obs/'Contents/MacOS/fixture').chmod(0o755)
    if run()[1]['obs_running']:
        code, result = run('--install', ['--non-interactive', '--resources-from', str(imports)])
        require(code == 1 and not result['dependencies_ready'], 'running OBS blocks installation without ending the process')
        require(not resources.exists() and not plugins.exists(), 'blocked installation leaves target directories untouched')
        print('SKIP: positive offline installation and post-install checks while OBS is running')
    else:
        code, result = run('--install', ['--non-interactive', '--resources-from', str(imports)])
        require(code == 0 and result['ready'], 'native install succeeds offline with verified resources and system-only PATH')
        code, result = run()
        require(code == 0 and result['ready'] and result['resources_ready'] and result['plugin_ready'], 'post-install verification succeeds')
        require((resources/'manifest.json').is_file() and json.loads((resources/'manifest.json').read_text())['runtime_sha256'] == runtime['sha256'], 'selected version hash persisted in local manifest')
    require(result['repository'] == 'https://github.com/TIMEKB/mac-obs-beauty', 'installer points to renamed public repository')
print(f'{checks} first-run installer checks passed')
