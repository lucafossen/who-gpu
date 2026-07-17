#!/usr/bin/env bash
# Installs who-gpu for the current user.
#
#   ./install.sh          install the `who-gpu` command only (default)
#   ./install.sh --icon   also add a double-click desktop launcher
#
# Works on Linux (.desktop), macOS (.command), and Windows/Git Bash (.cmd).
# Idempotent. Re-run any time. Uninstall with ./uninstall.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/who-gpu.sh"
LAUNCH="$DIR/who-gpu-launch.sh"

WANT_ICON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --icon|--desktop) WANT_ICON=1; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; sed -n '2,8p' "$0"; exit 1 ;;
  esac
done

chmod +x "$SCRIPT" "$LAUNCH"

# Detect OS family. Override with WHO_GPU_OS (linux|darwin|windows) for testing.
detect_os() {
  if [[ -n "${WHO_GPU_OS:-}" ]]; then echo "$WHO_GPU_OS"; return; fi
  case "$(uname -s)" in
    Linux*)               echo linux ;;
    Darwin*)              echo darwin ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *)                    echo unknown ;;
  esac
}
OS="$(detect_os)"

# 1) Put `who-gpu` on PATH (~/.local/bin), for every platform.
mkdir -p "$HOME/.local/bin"
CLI="$HOME/.local/bin/who-gpu"
if [[ "$OS" == "windows" ]]; then
  # MSYS/Cygwin symlinks are unreliable, so use a tiny wrapper script instead.
  cat > "$CLI" <<EOF
#!/usr/bin/env bash
exec "$SCRIPT" "\$@"
EOF
  chmod +x "$CLI"
else
  ln -sf "$SCRIPT" "$CLI"
fi
echo "* CLI:      $CLI -> $SCRIPT"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *) echo "  (note: add ~/.local/bin to your PATH to use the 'who-gpu' command)" ;;
esac

# 2) The desktop launcher is opt-in via --icon.
if [[ "$WANT_ICON" != "1" ]]; then
  echo
  echo "Installed the CLI. Run:  who-gpu"
  echo "To add a double-click desktop launcher, re-run:  ./install.sh --icon"
  exit 0
fi

# Resolve the Desktop directory (xdg-user-dir on Linux, else ~/Desktop).
DESKTOP_DIR="$( { command -v xdg-user-dir >/dev/null 2>&1 && xdg-user-dir DESKTOP; } 2>/dev/null || true )"
[[ -n "$DESKTOP_DIR" ]] || DESKTOP_DIR="$HOME/Desktop"

case "$OS" in
  linux)
    term_exec() {
      if   command -v gnome-terminal      >/dev/null 2>&1; then echo "gnome-terminal --geometry=100x28 -- \"$LAUNCH\""
      elif command -v konsole             >/dev/null 2>&1; then echo "konsole -e \"$LAUNCH\""
      elif command -v xfce4-terminal      >/dev/null 2>&1; then echo "xfce4-terminal --geometry=100x28 -e \"$LAUNCH\""
      elif command -v x-terminal-emulator >/dev/null 2>&1; then echo "x-terminal-emulator -e \"$LAUNCH\""
      else echo ""; fi
    }
    EXEC="$(term_exec)"
    if [[ -z "$EXEC" ]]; then
      echo "! No supported terminal emulator found. Skipping the desktop icon."
      echo "  You can still run:  who-gpu"
      exit 0
    fi
    APPS="$HOME/.local/share/applications"; mkdir -p "$APPS"
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
    if [[ -d "$DESKTOP_DIR" ]]; then
      cp "$DESK" "$DESKTOP_DIR/who-gpu.desktop"
      chmod +x "$DESKTOP_DIR/who-gpu.desktop"
      gio set "$DESKTOP_DIR/who-gpu.desktop" metadata::trusted true 2>/dev/null || true
      echo "* Desktop:  $DESKTOP_DIR/who-gpu.desktop"
    fi
    echo
    echo "Done. On GNOME, the first time you may need to right-click the desktop"
    echo "icon and choose 'Allow Launching'."
    ;;
  darwin)
    mkdir -p "$DESKTOP_DIR"
    CMD="$DESKTOP_DIR/who-gpu.command"
    cat > "$CMD" <<EOF
#!/usr/bin/env bash
exec "$LAUNCH"
EOF
    chmod +x "$CMD"
    xattr -d com.apple.quarantine "$CMD" 2>/dev/null || true
    echo "* Desktop:  $CMD"
    echo
    echo "Done. Double-click who-gpu.command on your Desktop (it opens Terminal)."
    ;;
  windows)
    mkdir -p "$DESKTOP_DIR"
    CMD="$DESKTOP_DIR/who-gpu.cmd"
    # Translate paths to Windows form when cygpath is available.
    if command -v cygpath >/dev/null 2>&1; then
      WIN_LAUNCH="$(cygpath -w "$LAUNCH")"
      WIN_BASH="$(cygpath -w "$(command -v bash)")"
    else
      WIN_LAUNCH="$LAUNCH"; WIN_BASH="bash"
    fi
    cat > "$CMD" <<EOF
@echo off
"$WIN_BASH" "$WIN_LAUNCH"
EOF
    echo "* Desktop:  $CMD"
    echo
    echo "Done. Double-click who-gpu.cmd on your Desktop (best-effort on Windows)."
    ;;
  *)
    echo "! Don't know how to make a desktop icon on this OS ($OS)."
    echo "  The CLI is installed. Run:  who-gpu"
    ;;
esac
