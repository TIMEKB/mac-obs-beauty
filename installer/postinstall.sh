#!/bin/bash
# Install the standard OBS plugin for the logged-in user; no dependency wizard.
set -euo pipefail
LB_SETUP_ROOT='/Library/Application Support/Mac OBS Beauty'
LB_CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console)"
if [[ "$LB_CONSOLE_USER" == root || "$LB_CONSOLE_USER" == loginwindow || -z "$LB_CONSOLE_USER" ]]; then
  echo 'Please log in to the Mac before installing this user-scoped OBS plugin.' >&2
  exit 1
fi
LB_CONSOLE_UID="$(/usr/bin/id -u "$LB_CONSOLE_USER")"
/bin/launchctl asuser "$LB_CONSOLE_UID" /usr/bin/sudo -H -u "$LB_CONSOLE_USER" \
  "$LB_SETUP_ROOT/obs-live-beauty-installer" --assets-dir "$LB_SETUP_ROOT" \
  --plugin-only --install --non-interactive --json
