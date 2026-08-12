#!/bin/bash
# Builds Claude Ticker and installs it as a login agent.
# Works from wherever you cloned or unzipped this — no paths to edit.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.claude-ticker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINARY="$DIR/ClaudeTicker"

command -v swiftc >/dev/null || {
  echo "swiftc not found. Install the Xcode Command Line Tools:  xcode-select --install" >&2
  exit 1
}

echo "Building..."
swiftc -O -o "$BINARY" "$DIR/ClaudeTicker.swift"

# Stop any previous copy so we never end up with two panels on screen.
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f "$BINARY" 2>/dev/null || true

mkdir -p "$HOME/Library/LaunchAgents"
# LaunchAgents don't expand ~ or $HOME, so the absolute path is written in here.
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <!-- Deliberately false: closing the panel with its own button should stay
         closed until next login, not get resurrected by launchd. -->
    <key>KeepAlive</key>
    <false/>

    <key>StandardOutPath</key>
    <string>$DIR/ticker.log</string>
    <key>StandardErrorPath</key>
    <string>$DIR/ticker.log</string>
</dict>
</plist>
PLIST_EOF

launchctl load "$PLIST"
sleep 2

if pgrep -f "$BINARY" >/dev/null; then
  echo "Running. The panel is in the top-right — drag it anywhere."
  echo "It will start automatically at login. Uninstall with ./uninstall.sh"
else
  echo "Built and installed, but it isn't running. Check $DIR/ticker.log" >&2
  exit 1
fi
