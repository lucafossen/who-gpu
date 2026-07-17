#!/usr/bin/env bash
# Installs who-gpu for the current user:
#   - a `who-gpu` command on your PATH (~/.local/bin)
#   - a double-clickable desktop icon that opens a terminal and runs the report
#
# Re-run any time; it's idempotent. Uninstall with ./uninstall.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/who-gpu.sh"
LAUNCH="$DIR/who-gpu-launch.sh"
chmod +x "$SCRIPT" "$LAUNCH"

# 1) put `who-gpu` on PATH
mkdir -p "$HOME/.local/bin"
ln -sf "$SCRIPT" "$HOME/.local/bin/who-gpu"
echo "* CLI:      $HOME/.local/bin/who-gpu -> $SCRIPT"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *) echo "  (note: add ~/.local/bin to your PATH to use the 'who-gpu' command)" ;;
esac

# 2) build a terminal command that opens a window running the launcher
term_exec() {
  if   command -v gnome-terminal   >/dev/null 2>&1; then echo "gnome-terminal --geometry=100x28 -- \"$LAUNCH\""
  elif command -v konsole          >/dev/null 2>&1; then echo "konsole -e \"$LAUNCH\""
  elif command -v xfce4-terminal   >/dev/null 2>&1; then echo "xfce4-terminal --geometry=100x28 -e \"$LAUNCH\""
  elif command -v x-terminal-emulator >/dev/null 2>&1; then echo "x-terminal-emulator -e \"$LAUNCH\""
  else echo ""; fi
}
EXEC="$(term_exec)"
if [[ -z "$EXEC" ]]; then
  echo "! No supported terminal emulator found; skipping the desktop icon."
  echo "  You can still run:  who-gpu -S -s"
  exit 0
fi

# 3) write the .desktop into the app grid
APPS="$HOME/.local/share/applications"
mkdir -p "$APPS"
DESK="$APPS/who-gpu.desktop"
cat > "$DESK" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=GPU Fleet Report
Comment=SSH into the fleet and report which machines are in use and by whom
Exec=$EXEC
Icon=utilities-system-monitor
Terminal=false
Categories=System;Monitor;
EOF
chmod +x "$DESK"
echo "* App grid: $DESK"

# 4) also drop a trusted copy on the Desktop, if the user has one
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
if [[ -d "$DESKTOP_DIR" ]]; then
  cp "$DESK" "$DESKTOP_DIR/who-gpu.desktop"
  chmod +x "$DESKTOP_DIR/who-gpu.desktop"
  gio set "$DESKTOP_DIR/who-gpu.desktop" metadata::trusted true 2>/dev/null || true
  echo "* Desktop:  $DESKTOP_DIR/who-gpu.desktop"
fi

echo
echo "Done. On GNOME, the first time you may need to right-click the desktop"
echo "icon and choose 'Allow Launching'."
