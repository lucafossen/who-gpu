#!/usr/bin/env bash
# Removes the who-gpu CLI and any desktop launcher (Linux, macOS, or Windows).
# Leaves the repo, your ~/.ssh/config, and any hosts file untouched.
set -euo pipefail

# Detect OS family (override with WHO_GPU_OS for testing).
case "${WHO_GPU_OS:-$(uname -s)}" in
  linux|Linux*)                       OS=linux ;;
  darwin|Darwin*)                     OS=darwin ;;
  windows|MINGW*|MSYS*|CYGWIN*)       OS=windows ;;
  *)                                  OS=unknown ;;
esac

# Resolve the Desktop directory. On Windows, honor OneDrive folder redirection
# (matches install.sh) so we remove the launcher from the real Desktop.
if [[ "$OS" == "windows" ]]; then
  DESKTOP_DIR="$(powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('Desktop')" 2>/dev/null | tr -d '\r')"
  if [[ -n "$DESKTOP_DIR" ]]; then
    DESKTOP_DIR="$(cygpath -u "$DESKTOP_DIR" 2>/dev/null || echo "${DESKTOP_DIR//\\//}")"
  else
    DESKTOP_DIR="$HOME/Desktop"
  fi
else
  DESKTOP_DIR="$( { command -v xdg-user-dir >/dev/null 2>&1 && xdg-user-dir DESKTOP; } 2>/dev/null || true )"
  [[ -n "$DESKTOP_DIR" ]] || DESKTOP_DIR="$HOME/Desktop"
fi

rm -f "$HOME/.local/bin/who-gpu"
rm -f "$HOME/.local/share/applications/who-gpu.desktop"
rm -f "$DESKTOP_DIR/who-gpu.desktop"     # Linux
rm -f "$DESKTOP_DIR/who-gpu.command"     # macOS
rm -f "$DESKTOP_DIR/who-gpu.cmd"         # Windows

echo "Removed the who-gpu CLI and desktop launcher."
echo "Your ~/.ssh/config and hosts file were not touched."
