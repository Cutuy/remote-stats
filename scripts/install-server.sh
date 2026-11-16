#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
make server
install_dir="$HOME/.local/libexec/remote-stats"
mkdir -p "$install_dir"
install -m 755 bin/remote-stats-server "$install_dir/remote-stats-server.tmp"
mv -f "$install_dir/remote-stats-server.tmp" "$install_dir/remote-stats-server"
mkdir -p "$HOME/.config/systemd/user"
python3 - "$install_dir/remote-stats-server" "$HOME/.config/systemd/user/remote-stats.service" <<'PY'
import os, sys
binary, destination = sys.argv[1:]
port = int(os.environ.get('REMOTE_STATS_PORT', '47391'))
interval = int(os.environ.get('REMOTE_STATS_INTERVAL_MS', '2000'))
if not 1 <= port <= 65535 or not 500 <= interval <= 60000:
    raise SystemExit('Invalid port or sample interval (500..60000ms)')
if any(c in binary for c in '\r\n\x00'):
    raise SystemExit('Unsupported control character in installation path')
# systemd ExecStart quoting and literal-percent escaping; no shell is involved.
binary = binary.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('$', '$$')
with open(destination, 'w') as f:
    f.write(f'''[Unit]
Description=Remote Stats lightweight Linux collector
After=network.target

[Service]
ExecStart="{binary}" --port {port} --interval-ms {interval}
Restart=on-failure
RestartSec=3
Nice=10
CPUWeight=10
MemoryMax=64M
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
RestrictAddressFamilies=AF_INET AF_UNIX
UMask=0077

[Install]
WantedBy=default.target
''')
PY
systemctl --user daemon-reload
systemctl --user enable remote-stats.service
systemctl --user restart remote-stats.service
systemctl --user --no-pager status remote-stats.service
