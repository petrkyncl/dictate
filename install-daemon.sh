#!/usr/bin/env bash
# Nainstaluje demon jako LaunchAgent — nabehne pri prihlaseni a drzi model v RAM.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
PLIST="$HOME/Library/LaunchAgents/cz.kyncl.dictate.daemon.plist"
UV="$(command -v uv)"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>cz.kyncl.dictate.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>$UV</string><string>run</string><string>python</string>
        <string>$ROOT/dictate/daemon.py</string>
    </array>
    <key>WorkingDirectory</key><string>$ROOT</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/dictate-daemon.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/dictate-daemon.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID/cz.kyncl.dictate.daemon" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "✓ démon nainstalován, naběhne i po restartu"
echo "  log:     ~/Library/Logs/dictate-daemon.log"
echo "  vypnout: launchctl bootout gui/$UID/cz.kyncl.dictate.daemon"
