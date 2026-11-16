#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-macos.sh
app="$HOME/Applications/Remote Stats.app"
agent="$HOME/Library/LaunchAgents/com.cutuy.remote-stats.plist"
launchctl bootout "gui/$(id -u)/com.cutuy.remote-stats" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Remote Stats"
# ditto preserves the app signature and bundle structure.
ditto "build/Remote Stats.app" "$app"
python3 - "$app" "$agent" <<'PY'
import os, plistlib, sys
app, destination = sys.argv[1:]
with open(destination, 'wb') as f:
    plistlib.dump({
        'Label': 'com.cutuy.remote-stats',
        'ProgramArguments': [app + '/Contents/MacOS/RemoteStats'],
        'RunAtLoad': True,
        'KeepAlive': {'SuccessfulExit': False},
        'ThrottleInterval': 10,
        'StandardOutPath': os.path.expanduser('~/Library/Logs/Remote Stats/client.log'),
        'StandardErrorPath': os.path.expanduser('~/Library/Logs/Remote Stats/client-error.log'),
    }, f)
PY
launchctl bootstrap "gui/$(id -u)" "$agent"
echo "Installed $app (starts at login)."
