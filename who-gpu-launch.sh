#!/usr/bin/env bash
# Opened by the desktop icon: runs the fleet report, then waits so the terminal
# window stays open until you've read it. Resolves its own location, so it works
# no matter where the repo is cloned.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# No args -> who-gpu's default (ssh-config hosts, compact summary).
"$DIR/who-gpu.sh" "$@"

echo
echo "----------------------------------------------------------------------"
read -r -p "Done. Press Enter to close this window... "
