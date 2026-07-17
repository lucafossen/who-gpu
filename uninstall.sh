#!/usr/bin/env bash
# Removes the who-gpu CLI symlink and desktop launcher. Leaves the repo,
# your ~/.ssh/config, and any hosts file untouched.
set -euo pipefail

rm -f "$HOME/.local/bin/who-gpu"
rm -f "$HOME/.local/share/applications/who-gpu.desktop"
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
rm -f "$DESKTOP_DIR/who-gpu.desktop"

echo "Removed the who-gpu CLI symlink and desktop launcher."
echo "Your ~/.ssh/config and hosts file were not touched."
