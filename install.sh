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

# Resolve the user's real Desktop directory.
# On Windows this must honor OneDrive folder redirection (the Desktop is often
# %USERPROFILE%\OneDrive\Desktop, not ~/Desktop), so we ask Windows itself.
desktop_dir() {
  local d
  case "$OS" in
    windows)
      d="$(powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('Desktop')" 2>/dev/null | tr -d '\r')"
      if [[ -n "$d" ]]; then
        cygpath -u "$d" 2>/dev/null || echo "${d//\\//}"
      else
        echo "$HOME/Desktop"
      fi ;;
    *)
      d="$( { command -v xdg-user-dir >/dev/null 2>&1 && xdg-user-dir DESKTOP; } 2>/dev/null || true )"
      [[ -n "$d" ]] && echo "$d" || echo "$HOME/Desktop" ;;
  esac
}

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

DESKTOP_DIR="$(desktop_dir)"

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
Name=who-gpu
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
    # cmd.exe must be able to *find* bash.exe, so that one path is given in
    # Windows form (C:\...). The launch script is passed to bash as a POSIX
    # /c/... path, which bash understands natively -- this sidesteps the
    # backslash/quoting problems of handing bash a Windows path.
    if command -v cygpath >/dev/null 2>&1; then
      WIN_BASH="$(cygpath -w "$(command -v bash)")"
    else
      # cygpath missing (unusual): fall back to Git for Windows' default path.
      WIN_BASH='C:\Program Files\Git\bin\bash.exe'
    fi
    # Write with CRLF line endings -- cmd.exe batch files need them. Use a login
    # shell (-l) so ssh and friends are on PATH.
    printf '@echo off\r\n"%s" -lc "%s"\r\n' "$WIN_BASH" "'$LAUNCH'" > "$CMD"
    echo "* Desktop:  $CMD"
    echo
    echo "Done. Double-click who-gpu.cmd on your Desktop. Requires Git Bash."
    ;;
  *)
    echo "! Don't know how to make a desktop icon on this OS ($OS)."
    echo "  The CLI is installed. Run:  who-gpu"
    ;;
esac
