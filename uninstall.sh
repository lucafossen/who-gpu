#!/usr/bin/env bash
# Removes the who-gpu CLI and any desktop launcher (Linux, macOS, or Windows).
# Leaves the repo, your ~/.ssh/config, and any hosts file untouched.
set -euo pipefail

# Resolve the Desktop directory (xdg-user-dir on Linux, else ~/Desktop).
DESKTOP_DIR="$( { command -v xdg-user-dir >/dev/null 2>&1 && xdg-user-dir DESKTOP; } 2>/dev/null || true )"
[[ -n "$DESKTOP_DIR" ]] || DESKTOP_DIR="$HOME/Desktop"

rm -f "$HOME/.local/bin/who-gpu"
rm -f "$HOME/.local/share/applications/who-gpu.desktop"
rm -f "$DESKTOP_DIR/who-gpu.desktop"     # Linux
rm -f "$DESKTOP_DIR/who-gpu.command"     # macOS
rm -f "$DESKTOP_DIR/who-gpu.cmd"         # Windows

echo "Removed the who-gpu CLI and desktop launcher."
echo "Your ~/.ssh/config and hosts file were not touched."
