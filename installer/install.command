#!/bin/bash
# ZIP entry point: install the standard plugin without a dependency wizard.
set -euo pipefail
LB_SETUP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"$LB_SETUP_ROOT/obs-live-beauty-installer" --assets-dir "$LB_SETUP_ROOT" --plugin-only --install
printf '\n完成后重新打开 OBS。安装失败时查看上方原因，退出 OBS 后重试。\n'
read -r -p '按回车关闭 / Press Return to close / Enter で閉じる: ' LB_CLOSE
