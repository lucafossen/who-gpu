#!/usr/bin/env bash
# Opened by the desktop icon.
#
# By default this opens the web dashboard in your browser and keeps it updating;
# the terminal window it opens is the engine driving it, so closing that window
# stops the dashboard. Set ICON_MODE=terminal in the config file to get the
# old-style one-shot text report instead.
#
# Config: ~/.config/who-gpu/config  (written by install.sh, safe to hand-edit)
#
# The whole body lives in main() on purpose: bash reads a script lazily from
# disk as it executes, so if `who-gpu --update` ever rewrites this file
# mid-flight, a partially-read script would run garbage. Bash parses a function
# completely before running it, which closes that hole.
main() {
  local DIR MODE cfg key val
  DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Widen/size the window (30 rows x 100 cols). Honored by macOS Terminal, xterm,
  # and Windows consoles; gnome-terminal ignores it (it's sized via --geometry).
  printf '\033[8;30;100t'

  MODE=web
  cfg="${WHO_GPU_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/who-gpu/config}"
  if [ -r "$cfg" ]; then
    while IFS='=' read -r key val; do
      case "$key" in
        ICON_MODE) [ "$val" = "terminal" ] && MODE=terminal ;;
      esac
    done < <(grep -E '^[A-Z_]+=' "$cfg" 2>/dev/null)
  fi

  if [ "$MODE" = "terminal" ]; then
    # Explicit, so a DEFAULT_MODE=web preference cannot turn this icon into the
    # dashboard: ICON_MODE is what the icon opens, DEFAULT_MODE is what a plain
    # `who-gpu` opens, and the two are set independently.
    "$DIR/who-gpu.sh" --summary "$@"
    echo
    echo "======================================================================"
    read -r -p "Done. Press Enter to close this window... "
    return
  fi

  echo "Starting the who-gpu dashboard..."
  echo "Keep this window open -- closing it stops the dashboard."
  echo
  "$DIR/who-gpu.sh" --web "$@"

  # Only reached if --web exits on its own (bad config, no hosts, an error).
  echo
  echo "======================================================================"
  read -r -p "The dashboard stopped. Press Enter to close this window... "
}

main "$@"
