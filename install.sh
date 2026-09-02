#!/usr/bin/env bash
# Installs who-gpu for the current user.
#
#   ./install.sh          install the `who-gpu` command only (default)
#   ./install.sh --icon   also add a double-click desktop launcher
#
# Defaults for the desktop icon (asked interactively with --icon, or set here):
#   --icon-mode web|terminal   what the icon opens (default: web dashboard)
#   --interval SECS            pin the dashboard refresh rate (default: auto,
#                              10s, or 60s when SSH connections can't be reused)
#   --default-mode terminal|web  what a plain `who-gpu` opens (default: terminal;
#                              `who-gpu --setup` can change it later)
#   --no-update-check          don't check whether a newer version exists
#   --no-path                  don't touch your shell profile, even if
#                              ~/.local/bin is missing from PATH
#
# Works on Linux (.desktop), macOS (.command), and Windows/Git Bash (.cmd).
# Idempotent. Re-run any time. Uninstall with ./uninstall.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/who-gpu.sh"
LAUNCH="$DIR/who-gpu-launch.sh"

WANT_ICON=0
WANT_PATH=1             # fix PATH if ~/.local/bin is missing from it
ICON_MODE=""            # empty = ask (interactive) or default to web
DEFAULT_MODE=""         # what a plain `who-gpu` opens; empty = keep/terminal
INTERVAL=""
INTERVAL_SET=0          # 1 = a human picked a number, so who-gpu must not adapt it
UPDATE_CHECK=""
ASKED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --icon|--desktop) WANT_ICON=1; shift ;;
    --icon-mode)
      case "${2:-}" in
        web|terminal) ICON_MODE="$2" ;;
        *) echo "--icon-mode must be 'web' or 'terminal'" >&2; exit 1 ;;
      esac; shift 2 ;;
    --default-mode)
      case "${2:-}" in
        web|terminal) DEFAULT_MODE="$2" ;;
        *) echo "--default-mode must be 'terminal' or 'web'" >&2; exit 1 ;;
      esac; shift 2 ;;
    --interval)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "--interval needs a number of seconds" >&2; exit 1; }
      INTERVAL="$2"; INTERVAL_SET=1; shift 2 ;;
    --no-update-check) UPDATE_CHECK=0; shift ;;
    --no-path) WANT_PATH=0; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; sed -n '2,18p' "$0"; exit 1 ;;
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

# Put ~/.local/bin on PATH if it isn't already. This matters most on Windows,
# where Git Bash does not include it by default, so `who-gpu --update` would not
# be a runnable command at all.
#
# Strictly additive: we APPEND one line to an existing profile (never rewrite
# one), and the line itself keeps the old value -- PATH="$HOME/.local/bin:$PATH"
# -- so nothing the user had is lost. A timestamped backup is taken first, the
# same way --setup backs up ~/.ssh/config.
add_local_bin_to_path() {
  local f target line marker backup
  marker='# added by who-gpu install.sh'
  line='export PATH="$HOME/.local/bin:$PATH"'

  # Bash reads only the FIRST of these that exists. Creating ~/.bash_profile
  # when the user already has ~/.profile would silently stop ~/.profile from
  # being read at all, so always extend the file bash is actually using.
  target=""
  for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    [[ -f "$f" ]] && { target="$f"; break; }
  done
  [[ -n "$target" ]] || target="$HOME/.bash_profile"

  if [[ -f "$target" ]] && grep -qF '.local/bin' "$target"; then
    echo "  (~/.local/bin is already handled in ${target/#$HOME/\~}; left as-is)"
    echo "  (open a new terminal for the 'who-gpu' command to work)"
    return 0
  fi

  if [[ -f "$target" ]]; then
    backup="$target.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$target" "$backup"
  fi
  printf '\n%s\n%s\n' "$marker" "$line" >> "$target"      # append, never rewrite

  echo "* PATH:     added ~/.local/bin in ${target/#$HOME/\~}"
  [[ -n "${backup:-}" ]] && echo "            (backup: ${backup/#$HOME/\~})"
  echo "            open a new terminal for the 'who-gpu' command to work"
}

case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *)
    if [[ "$WANT_PATH" == "1" ]]; then
      add_local_bin_to_path
    else
      echo "  (note: add ~/.local/bin to your PATH to use the 'who-gpu' command)"
    fi ;;
esac

# 2) Preferences. Written to one config file that every platform's launcher
#    reads, so the same settings work for .desktop, .command and .cmd alike.
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/who-gpu/config"

# Carry over existing choices so re-running the installer never silently resets
# preferences the user already made.
if [[ -r "$CONFIG_FILE" ]]; then
  while IFS='=' read -r k v; do
    case "$k" in
      ICON_MODE)    [[ -z "$ICON_MODE"    ]] && ICON_MODE="$v" ;;
      DEFAULT_MODE) [[ -z "$DEFAULT_MODE" ]] && DEFAULT_MODE="$v" ;;
      INTERVAL)     [[ -z "$INTERVAL"     ]] && { INTERVAL="$v"; INTERVAL_SET=1; } ;;
      UPDATE_CHECK) [[ -z "$UPDATE_CHECK" ]] && UPDATE_CHECK="$v" ;;
    esac
  done < <(grep -E '^[A-Z_]+=' "$CONFIG_FILE" 2>/dev/null || true)
fi

# Ask, but only when there's a human present and something to ask about.
if [[ "$WANT_ICON" == "1" && -t 0 && -t 1 && -z "$ICON_MODE" ]]; then
  ASKED=1
  echo
  echo "What should the desktop icon open?"
  echo "  1) the web dashboard in your browser  (default)"
  echo "  2) the plain text report in a terminal"
  printf "> "
  IFS= read -r reply </dev/tty || reply=""
  case "$reply" in
    2) ICON_MODE="terminal" ;;
    *) ICON_MODE="web" ;;
  esac
  if [[ "$ICON_MODE" == "web" ]]; then
    printf "How often should the dashboard refresh, in seconds? [auto] "
    IFS= read -r reply </dev/tty || reply=""
    [[ "$reply" =~ ^[0-9]+$ ]] && { INTERVAL="$reply"; INTERVAL_SET=1; }
  fi
fi

ICON_MODE="${ICON_MODE:-web}"
DEFAULT_MODE="${DEFAULT_MODE:-terminal}"
UPDATE_CHECK="${UPDATE_CHECK:-1}"

if [[ "$INTERVAL_SET" == "1" ]]; then
  INTERVAL_LINE="INTERVAL=$INTERVAL"
  INTERVAL_DESC="refresh: ${INTERVAL}s"
else
  # Commented out on purpose: an unset interval lets who-gpu use 10s normally
  # and fall back to 60s when SSH connections cannot be reused.
  INTERVAL_LINE="# INTERVAL=10"
  INTERVAL_DESC="refresh: auto"
fi

mkdir -p "$(dirname "$CONFIG_FILE")"
cat > "$CONFIG_FILE" <<EOF
# who-gpu preferences. Edit freely, or re-run ./install.sh to change them.
# ICON_MODE     web | terminal   what the desktop icon opens
# DEFAULT_MODE  terminal | web   what a plain \`who-gpu\` (no flags) opens
# INTERVAL      seconds          how often --web re-probes the fleet. Leave it
#                                commented out to let who-gpu choose: 10s
#                                normally, 60s if SSH connections cannot be
#                                reused (Git Bash), which avoids hammering the
#                                fleet with repeated logins.
# UPDATE_CHECK  1 | 0            check whether a newer version exists
ICON_MODE=$ICON_MODE
DEFAULT_MODE=$DEFAULT_MODE
$INTERVAL_LINE
UPDATE_CHECK=$UPDATE_CHECK
EOF
echo "* Config:   $CONFIG_FILE (plain who-gpu: $DEFAULT_MODE, icon opens: $ICON_MODE, $INTERVAL_DESC)"
[[ "$ASKED" == "1" ]] && echo

# 3) The desktop launcher is opt-in via --icon.
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
