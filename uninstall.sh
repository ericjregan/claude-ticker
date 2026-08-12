#!/bin/bash
# Removes the login agent and stops the panel. Leaves the source alone.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.claude-ticker.plist"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
pkill -f "$DIR/ClaudeTicker" 2>/dev/null || true

# Position, size, and read-markers.
defaults delete ClaudeTicker 2>/dev/null || true

echo "Uninstalled. Source and binary are still in $DIR"
