#!/usr/bin/env bash
#
# who-gpu.sh: SSH into a list of hosts and report who's using each machine.
#
# For every host it collects:
#   - GPU utilization + memory (nvidia-smi)
#   - Which usernames own the running GPU processes
#   - Logged-in users and the top CPU/RAM consumers (ps, htop-style but scrapeable)
#
# By default it reads hosts from ~/.ssh/config (#probe markers) and prints a
# compact one-line-per-host summary; plain `who-gpu` behaves like `who-gpu -S -s`.
#
# Setup:
#   who-gpu --setup                   # scan SSH hosts, toggle which to probe
#                                     # (adds/removes #probe markers for you)
#
# Usage:
#   who-gpu                           # ssh-config hosts, compact summary (default)
#   who-gpu --web                     # live dashboard in your browser
#   who-gpu --full                    # same hosts, full per-host breakdown
#   who-gpu host1 host2 ...           # probe these hosts instead
#   who-gpu -f hosts.txt              # read hosts from a file (one per line)
#   who-gpu -u alice host1            # ssh as a specific user
#
# Host sources (first that applies wins):
#   1. hosts on the command line
#   2. -f FILE
#   3. ~/.ssh/config #probe markers   (default; disable with --no-ssh-config)
#   4. ~/.who-gpu-hosts fallback      (used only with --no-ssh-config)
#
# Tag a Host block in ~/.ssh/config by adding a comment line inside it:
#       Host exaba-1
#           HostName 10.0.0.1
#           #probe
# Env overrides: WHO_GPU_SSH_CONFIG=/path, WHO_GPU_HOSTS=/path,
#                WHO_GPU_OUT=/dir (--web output), WHO_GPU_INTERVAL=secs,
#                WHO_GPU_NO_MUX=1 (disable --web SSH connection reuse)
#
# Hosts may be "hostname", "user@hostname", or anything your ~/.ssh/config knows.

set -u

SSH_USER=""
HOSTS_FILE=""
DEFAULT_HOSTS_FILE="${WHO_GPU_HOSTS:-$HOME/.who-gpu-hosts}"  # used when no hosts/-f given
USE_SSH_CONFIG=1        # default: pull hosts from ~/.ssh/config #probe markers
SSH_CONFIG_FILE="${WHO_GPU_SSH_CONFIG:-$HOME/.ssh/config}"
CONNECT_TIMEOUT=8       # seconds to wait for the SSH handshake
TOP_N=5                 # how many top CPU processes to show per host
PARALLEL=6              # how many hosts to probe at once
SUMMARY=1               # default: one compact line per host (use --full for blocks)
DO_SETUP=0              # 1 = run the interactive #probe setup wizard
DO_WEB=0                # 1 = --web: render the browser dashboard and keep it fresh
DO_JSON=0               # 1 = --json: dump the structured fleet data and exit
MODE_FLAGS=""           # which output mode flags were given (to reject combinations)

# --web writes into a NON-HIDDEN directory on purpose. Snap- and flatpak-confined
# browsers (Ubuntu's default Chromium/Firefox) cannot read dotfile directories
# under $HOME, so a tidy ~/.cache/who-gpu would silently fail to open for them.
WEB_OUT="${WHO_GPU_OUT:-$HOME/who-gpu-web}"
WEB_INTERVAL=10                # seconds between probe cycles
WEB_INTERVAL_NO_MUX=60         # gentler default when connections can't be reused
INTERVAL_PINNED=0              # 1 = the user chose a value; never override it

# SSH connection reuse (--web only). Without this, every refresh cycle would be
# a fresh login on every host: a new TCP handshake, key exchange and PAM/LDAP
# auth, several times a minute, forever. That is enough to trip connection rate
# limits (iptables -m recent, fail2ban), flood auth.log, and put real load on a
# shared auth backend. With it, each host is logged into ONCE and every later
# probe is just another channel on the connection already open.
# Set WHO_GPU_NO_MUX=1 to disable if your ssh misbehaves.
SSH_MUX_DIR=""          # non-empty = reuse enabled
SSH_MUX_PERSIST=""

DO_UPDATE=0             # 1 = --update: fast-forward the checkout and reinstall
DO_VERSION=0            # 1 = --version

# Defaults chosen at install time live here. One file for every platform, so the
# .desktop / .command / .cmd launchers all read the same settings, and it can be
# hand-edited later without re-running the installer.
CONFIG_FILE="${WHO_GPU_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/who-gpu/config}"
CFG_ICON_MODE="web"     # what the desktop icon opens: web | terminal
CFG_INTERVAL=""         # dashboard refresh seconds (empty = built-in default)
CFG_UPDATE_CHECK=1      # 1 = tell the user when a newer version exists

# Read the config without sourcing it: only known keys, only sane values, so a
# mangled file can never execute anything.
load_config() {
  [[ -r "$CONFIG_FILE" ]] || return 0
  local key val
  while IFS='=' read -r key val; do
    key="${key%%[[:space:]]*}"
    case "$key" in
      ICON_MODE)    [[ "$val" == "web" || "$val" == "terminal" ]] && CFG_ICON_MODE="$val" ;;
      INTERVAL)     [[ "$val" =~ ^[0-9]+$ ]] && CFG_INTERVAL="$val" ;;
      UPDATE_CHECK) [[ "$val" =~ ^[01]$ ]]   && CFG_UPDATE_CHECK="$val" ;;
    esac
  done < <(grep -E '^[A-Z_]+=' "$CONFIG_FILE" 2>/dev/null)
}
load_config

# Precedence: environment, then config, then the built-in default. Either of the
# first two counts as the user having picked a number, which the automatic
# backoff below must respect.
if [[ -n "${WHO_GPU_INTERVAL:-}" ]]; then
  WEB_INTERVAL="$WHO_GPU_INTERVAL"; INTERVAL_PINNED=1
elif [[ -n "$CFG_INTERVAL" ]]; then
  WEB_INTERVAL="$CFG_INTERVAL";     INTERVAL_PINNED=1
fi

# Without connection reuse every cycle is a fresh login on every host, so a
# 10s default becomes hostile to the fleet. Back off to something gentle --
# but only when nobody asked for a specific interval, and never downwards.
relax_interval_without_mux() {
  [[ "$INTERVAL_PINNED" == "1" ]] && return 1
  [[ "$WEB_INTERVAL" -ge "$WEB_INTERVAL_NO_MUX" ]] && return 1
  WEB_INTERVAL="$WEB_INTERVAL_NO_MUX"
  return 0
}

usage() { sed -n '2,38p' "$0"; exit "${1:-0}"; }

hosts=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)    HOSTS_FILE="$2"; shift 2 ;;
    -u|--user)    SSH_USER="$2"; shift 2 ;;
    -t|--timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
    -n|--top)     TOP_N="$2"; shift 2 ;;
    -p|--parallel) PARALLEL="$2"; shift 2 ;;
    -s|--summary) SUMMARY=1; MODE_FLAGS="$MODE_FLAGS --summary"; shift ;;
    -F|--full)    SUMMARY=0; MODE_FLAGS="$MODE_FLAGS --full"; shift ;;
    --web)        DO_WEB=1;  MODE_FLAGS="$MODE_FLAGS --web";  shift ;;
    --json)       DO_JSON=1; MODE_FLAGS="$MODE_FLAGS --json"; shift ;;
    -S|--ssh-config) USE_SSH_CONFIG=1; shift ;;
    --no-ssh-config) USE_SSH_CONFIG=0; shift ;;
    --setup|--wizard) DO_SETUP=1; shift ;;
    --update)     DO_UPDATE=1; shift ;;
    --version|-V) DO_VERSION=1; shift ;;
    -h|--help)    usage 0 ;;
    -*)           echo "unknown option: $1" >&2; usage 1 ;;
    *)            hosts+=("$1"); shift ;;
  esac
done

# --summary/--full/--web/--json all answer "what do I emit?", so combining them
# is a user error rather than something to silently resolve.
read -r -a _modes <<< "$MODE_FLAGS"
if [[ ${#_modes[@]} -gt 1 ]]; then
  echo "who-gpu: pick one output mode, got:${MODE_FLAGS}" >&2
  exit 1
fi

# Interactive setup: scans ~/.ssh/config, shows every Host entry with its current
# probe state, and lets you toggle each one on or off. Works for first-time setup
# and for changing an existing configuration (adding OR removing #probe markers).
# Writes changes back after making a timestamped backup.
run_setup_wizard() {
  local cfg="$SSH_CONFIG_FILE"
  echo "who-gpu setup"
  echo "SSH config: $cfg"
  echo
  if [[ ! -e "$cfg" ]]; then
    echo "No SSH config found there yet. Create it with your GPU hosts"
    echo "(Host blocks with HostName/User), then re-run:  who-gpu --setup"
    return 1
  fi

  # One row per Host block: "alias<TAB>tagged(0|1)".
  local rows
  rows=$(awk '
    function flush(){ if (cur != "") print cur "\t" (marked ? 1 : 0) }
    tolower($1) == "host"  { flush(); cur=""; marked=0;
                             for (i=2;i<=NF;i++) if ($i!~/[*?!]/ && $i!~/^#/){ cur=$i; break }; next }
    tolower($1) == "match" { flush(); cur=""; marked=0; next }
    /^[ \t]*#[ \t]*[Pp][Rr][Oo][Bb][Ee]([ \t:].*)?$/ { if (cur != "") marked=1 }
    END { flush() }
  ' "$cfg")

  if [[ -z "$rows" ]]; then
    echo "No Host entries found in $cfg."
    echo "Add some Host blocks first, then re-run:  who-gpu --setup"
    return 1
  fi

  # Parallel arrays: alias, current state (0/1), and the desired state we edit.
  local -a aliases=() state=() desired=()
  local a t
  while IFS=$'\t' read -r a t; do aliases+=("$a"); state+=("$t"); desired+=("$t"); done <<< "$rows"

  # Toggle loop: redraw the checklist until the user presses Enter to apply.
  local i mark reply tok idx
  while true; do
    echo "Toggle which hosts who-gpu should probe  ([x] = probe on):"
    for i in "${!aliases[@]}"; do
      mark=' '; [[ "${desired[$i]}" == "1" ]] && mark='x'
      printf "   %2d) [%s] %s\n" $((i + 1)) "$mark" "${aliases[$i]}"
    done
    echo
    echo "Enter numbers to toggle (e.g. 1 3), 'all', 'none', or Enter to apply."
    printf "> "
    IFS= read -r reply </dev/tty || reply=""
    [[ -z "$reply" ]] && { echo; break; }
    case "$reply" in
      all)  for i in "${!desired[@]}"; do desired[$i]=1; done ;;
      none) for i in "${!desired[@]}"; do desired[$i]=0; done ;;
      *)
        for tok in $reply; do
          if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#aliases[@]} )); then
            idx=$((tok - 1))
            [[ "${desired[$idx]}" == "1" ]] && desired[$idx]=0 || desired[$idx]=1
          else
            echo "  (ignoring: $tok)" >&2
          fi
        done ;;
    esac
    echo
  done

  # Diff desired vs current into add/remove sets.
  local -a to_tag=() to_untag=()
  for i in "${!aliases[@]}"; do
    [[ "${desired[$i]}" == "${state[$i]}" ]] && continue
    if [[ "${desired[$i]}" == "1" ]]; then to_tag+=("${aliases[$i]}"); else to_untag+=("${aliases[$i]}"); fi
  done

  if [[ ${#to_tag[@]} -eq 0 && ${#to_untag[@]} -eq 0 ]]; then
    echo "No changes."; return 0
  fi
  echo "Changes to $cfg:"
  [[ ${#to_tag[@]}   -gt 0 ]] && echo "  will start probing: ${to_tag[*]}"
  [[ ${#to_untag[@]} -gt 0 ]] && echo "  will stop probing:  ${to_untag[*]}"
  printf "Apply? [y/N] "
  local confirm
  IFS= read -r confirm </dev/tty || confirm=""
  [[ "$confirm" =~ ^[Yy] ]] || { echo "Cancelled. No changes made."; return 0; }

  # Back up, then add/remove #probe markers in one pass.
  local backup="${cfg}.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$cfg" "$backup"

  # BSD mktemp (macOS) requires a template, GNU does not -- give one either way.
  local tagf untagf tmpout
  tagf=$(mktemp 2>/dev/null   || mktemp -t who-gpu)
  untagf=$(mktemp 2>/dev/null || mktemp -t who-gpu)
  tmpout=$(mktemp 2>/dev/null || mktemp -t who-gpu)
  printf '%s\n' "${to_tag[@]}"   > "$tagf"
  printf '%s\n' "${to_untag[@]}" > "$untagf"
  awk -v tagfile="$tagf" -v untagfile="$untagf" '
    BEGIN {
      while ((getline x < tagfile)   > 0) if (x != "") tag[x]=1
      while ((getline y < untagfile) > 0) if (y != "") untag[y]=1
    }
    tolower($1) == "host" {
      print
      cur=""
      for (i=2;i<=NF;i++) if ($i!~/[*?!]/ && $i!~/^#/){ cur=$i; break }
      if (cur in tag) print "    #probe"       # add marker to newly-selected hosts
      next
    }
    tolower($1) == "match" { print; cur=""; next }
    {
      # drop existing #probe lines in hosts being switched off
      if ((cur in untag) && $0 ~ /^[ \t]*#[ \t]*[Pp][Rr][Oo][Bb][Ee]([ \t:].*)?$/) next
      print
    }
  ' "$cfg" > "$tmpout"
  cat "$tmpout" > "$cfg"      # overwrite in place to preserve permissions
  rm -f "$tmpout" "$tagf" "$untagf"

  echo
  echo "Updated ${#aliases[@]} host(s) worth of config. Backup saved at: $backup"
  echo "Run:  who-gpu"
  return 0
}

# ---- version / self-update ------------------------------------------------
# Where does this script actually live? When installed, ~/.local/bin/who-gpu is
# a symlink into the clone, so BASH_SOURCE points at the link, not the repo.
# Resolved by hand because `readlink -f` does not exist on macOS.
resolve_self_dir() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -L "$src" ]; do
    dir=$(cd -P "$(dirname "$src")" && pwd)
    src=$(readlink "$src")
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  (cd -P "$(dirname "$src")" && pwd)
}

version_string() {
  local dir; dir="$(resolve_self_dir)"
  if command -v git >/dev/null 2>&1 && [ -d "$dir/.git" ]; then
    git -C "$dir" describe --tags --always --dirty 2>/dev/null && return 0
  fi
  echo "unknown"
}

# Did the user install a desktop icon? Determines whether an update needs to
# regenerate it (the Linux .desktop bakes in the terminal found at install time).
icon_installed() {
  local d
  [ -f "$HOME/.local/share/applications/who-gpu.desktop" ] && return 0
  for d in "$( { command -v xdg-user-dir >/dev/null 2>&1 && xdg-user-dir DESKTOP; } 2>/dev/null )" \
           "$HOME/Desktop"; do
    [ -n "$d" ] || continue
    [ -f "$d/who-gpu.desktop" ] || [ -f "$d/who-gpu.command" ] || [ -f "$d/who-gpu.cmd" ] && return 0
  done
  return 1
}

# Is a newer version available? Prints the remote description, or nothing.
# Cached for a day: the network round trip costs about a second and this must
# never be something the user waits on.
update_available() {
  [[ "$CFG_UPDATE_CHECK" == "1" ]] || return 1
  command -v git >/dev/null 2>&1 || return 1
  local dir cache now last remote local_rev cached_rev
  dir="$(resolve_self_dir)"
  [ -d "$dir/.git" ] || return 1

  # Cache holds "<checked-at> <rev-or-empty>". The RESULT has to be cached too,
  # not just the timestamp -- otherwise a found update would vanish again for a
  # day on the very next call.
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/who-gpu/update-check"
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 1
  now=$(date +%s)
  if [ -f "$cache" ]; then
    read -r last cached_rev < "$cache" 2>/dev/null || true
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt 86400 ]; then
      [ -n "${cached_rev:-}" ] || return 1
      printf '%s' "$cached_rev"
      return 0
    fi
  fi

  remote=$(git -C "$dir" ls-remote --quiet origin -h refs/heads/main 2>/dev/null | awk '{print $1}')
  if [ -z "$remote" ]; then
    # Offline or unreachable: remember we tried, so we do not retry every run.
    printf '%s \n' "$now" > "$cache"
    return 1
  fi
  local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  # Behind only if the remote commit is not already an ancestor of HEAD.
  if [ "$remote" = "$local_rev" ] || git -C "$dir" merge-base --is-ancestor "$remote" HEAD 2>/dev/null; then
    printf '%s \n' "$now" > "$cache"
    return 1
  fi
  printf '%s %s\n' "$now" "${remote:0:7}" > "$cache"
  printf '%s' "${remote:0:7}"
  return 0
}

# "Notify only": say a version exists, change nothing. Goes to stderr so that
# piping `who-gpu` somewhere never picks up a version notice as if it were data.
notify_update() {
  local v
  v=$(update_available) || return 0
  {
    echo
    echo "who-gpu: a newer version is available ($v)."
    echo "         get it with:  who-gpu --update"
  } >&2
}

run_update() {
  local dir before after
  dir="$(resolve_self_dir)"

  command -v git >/dev/null 2>&1 || {
    echo "who-gpu: git is not installed, so I cannot update automatically." >&2
    echo "         Reinstall from https://github.com/lucafossen/who-gpu" >&2
    return 1; }
  [ -d "$dir/.git" ] || {
    echo "who-gpu: $dir is not a git checkout (downloaded as a zip?)." >&2
    echo "         To get updates from now on, clone it instead:" >&2
    echo "           git clone https://github.com/lucafossen/who-gpu.git" >&2
    echo "           cd who-gpu && ./install.sh" >&2
    return 1; }
  if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
    echo "who-gpu: you have local changes in $dir -- not touching them." >&2
    echo "         Commit or discard them, then run who-gpu --update again." >&2
    return 1; fi

  before=$(git -C "$dir" rev-parse HEAD)
  echo "who-gpu: updating $dir"
  if ! git -C "$dir" pull --ff-only 2>&1 | sed 's/^/  /'; then
    echo "who-gpu: could not fast-forward (diverged branch, or no network)." >&2
    return 1; fi
  after=$(git -C "$dir" rev-parse HEAD)

  if [ "$before" = "$after" ]; then
    echo "who-gpu: already up to date ($(version_string))"
    return 0
  fi

  echo
  echo "who-gpu: updated to $(version_string)"
  git -C "$dir" log --oneline "$before..$after" 2>/dev/null | sed 's/^/  - /'

  # The installed launchers point into the clone, so they update themselves.
  # The exception is anything install.sh *generates* -- rerun it if that changed.
  if git -C "$dir" diff --name-only "$before" "$after" 2>/dev/null \
       | grep -qE '^(install\.sh|who-gpu-launch\.sh)$'; then
    echo
    echo "who-gpu: install scripts changed, refreshing your installation..."
    if icon_installed; then bash "$dir/install.sh" --icon; else bash "$dir/install.sh"; fi
  fi
  rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/who-gpu/update-check" 2>/dev/null
  return 0
}

if [[ "$DO_VERSION" == "1" ]]; then echo "who-gpu $(version_string)"; exit 0; fi
if [[ "$DO_UPDATE"  == "1" ]]; then run_update; exit $?; fi

# Extract host aliases tagged for probing from an ssh_config file.
# A host is included when its block contains a comment line "#probe"
# (also matches "# probe" or "# probe: some note"). The first non-wildcard
# pattern on the "Host" line is used as the name to ssh to.
hosts_from_ssh_config() {
  awk '
    tolower($1) == "host" {
      cur = ""
      for (i = 2; i <= NF; i++) {
        if ($i !~ /[*?!]/ && $i !~ /^#/) { cur = $i; break }
      }
      next
    }
    /^[ \t]*#[ \t]*[Pp][Rr][Oo][Bb][Ee]([ \t:].*)?$/ {
      if (cur != "" && !(cur in seen)) { seen[cur] = 1; print cur }
    }
  ' "$1"
}

# --setup: run the interactive wizard and exit.
if [[ "$DO_SETUP" == "1" ]]; then
  run_setup_wizard; exit $?
fi

# Pull hosts from ~/.ssh/config markers (unless hosts were given explicitly).
if [[ "$USE_SSH_CONFIG" == "1" && ${#hosts[@]} -eq 0 && -z "$HOSTS_FILE" ]]; then
  [[ -r "$SSH_CONFIG_FILE" ]] || { echo "cannot read ssh config: $SSH_CONFIG_FILE" >&2; exit 1; }
  while IFS= read -r h; do hosts+=("$h"); done < <(hosts_from_ssh_config "$SSH_CONFIG_FILE")

  if [[ ${#hosts[@]} -eq 0 ]]; then
    echo "who-gpu: no #probe markers found in $SSH_CONFIG_FILE" >&2
    # If we're on a terminal, offer the guided setup right now.
    if [[ -t 0 && -t 1 ]]; then
      printf 'Scan your SSH config and choose hosts to probe now? [Y/n] ' >&2
      IFS= read -r ans </dev/tty || ans=""
      if [[ -z "$ans" || "$ans" =~ ^[Yy] ]]; then
        echo >&2
        run_setup_wizard || exit 1
        while IFS= read -r h; do hosts+=("$h"); done < <(hosts_from_ssh_config "$SSH_CONFIG_FILE")
      fi
    fi
    # Still nothing (declined, cancelled, or non-interactive)? Explain and stop.
    if [[ ${#hosts[@]} -eq 0 ]]; then
      cat >&2 <<EOF

To set this up manually, add a "#probe" comment line inside each Host block you
want probed (SSH ignores comment lines, so ssh itself is unaffected):

    Host gpu-node-1
        HostName 10.0.0.1
        User alice
        #probe

Or run the guided setup any time with:  who-gpu --setup

Other ways to pass hosts without editing your SSH config:
    who-gpu host1 host2 ...      # hosts directly on the command line
    who-gpu -f hosts.txt        # a file with one host per line
    who-gpu --no-ssh-config     # use the ~/.who-gpu-hosts fallback file
EOF
      exit 1
    fi
  fi
fi

# No hosts on the command line and no -f? Fall back to the default hosts file.
if [[ ${#hosts[@]} -eq 0 && -z "$HOSTS_FILE" && -r "$DEFAULT_HOSTS_FILE" ]]; then
  HOSTS_FILE="$DEFAULT_HOSTS_FILE"
fi

if [[ -n "$HOSTS_FILE" ]]; then
  [[ -r "$HOSTS_FILE" ]] || { echo "cannot read hosts file: $HOSTS_FILE" >&2; exit 1; }
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"   # strip comments + trim
    [[ -n "$line" ]] && hosts+=("$line")
  done < "$HOSTS_FILE"
fi

[[ ${#hosts[@]} -gt 0 ]] || {
  echo "no hosts given, and no default hosts file at $DEFAULT_HOSTS_FILE" >&2
  echo "create it (one host per line) or pass hosts / -f <file>." >&2
  usage 1
}

# ---- remote snippet -------------------------------------------------------
# Runs ON each host. Emits plain-text sections that the local side prints as-is.
# Kept POSIX-sh friendly so it works on whatever login shell the host has.
read -r -d '' REMOTE <<'REMOTE_EOF'
TOP_N="${TOP_N:-5}"
echo "=== uptime ==="
uptime 2>/dev/null | sed 's/^ *//'

echo "=== logged-in users ==="
who 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ' - || echo "(none)"

echo "=== gpus ==="
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total \
             --format=csv,noheader,nounits 2>/dev/null \
  | awk -F', *' '{printf "  GPU%s %s | util %s%% | mem %s/%s MiB\n",$1,$2,$3,$4,$5}'

  echo "=== gpu processes ==="
  # pid, used mem, process name -> resolve owner via ps
  nvidia-smi --query-compute-apps=pid,used_memory,process_name \
             --format=csv,noheader,nounits 2>/dev/null \
  | while IFS=',' read -r pid mem pname; do
      pid=$(echo "$pid" | xargs); mem=$(echo "$mem" | xargs); pname=$(echo "$pname" | xargs)
      [ -z "$pid" ] && continue
      user=$(ps -o user= -p "$pid" 2>/dev/null | xargs)
      [ -z "$user" ] && user="?"
      printf "  %-12s pid %-7s %6s MiB  %s\n" "$user" "$pid" "$mem" "$pname"
    done
  # if the loop printed nothing, note it
  if [ -z "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)" ]; then
    echo "  (no active GPU processes)"
  fi
else
  echo "  (nvidia-smi not found)"
fi

echo "=== top cpu (by %cpu) ==="
ps -eo user,pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null \
  | awk 'NR==1 || $3+0>0.5' | head -n "$((TOP_N+1))" | sed 's/^/  /'

# Machine-readable per-GPU lines consumed by --web / --json. Deliberately a
# separate nvidia-smi call from the human-readable section above, so that
# section's output stays byte-identical to what it has always printed.
# Format: __GPU__|index|name|util_pct|mem_used_mib|mem_total_mib
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total \
             --format=csv,noheader,nounits 2>/dev/null \
  | awk -F', *' 'NF>=5 {printf "__GPU__|%s|%s|%s|%s|%s\n",$1,$2,$3,$4,$5}'
fi

# Machine-readable one-liner consumed by the local --summary mode.
# Format: __SUMMARY__|busy_gpus|total_gpus|gpu_users|logged_in_users
if command -v nvidia-smi >/dev/null 2>&1; then
  s_total=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | xargs)
  s_busy=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null \
           | awk '$1+0>=5' | wc -l | xargs)
  s_gu=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null \
         | while read -r p; do ps -o user= -p "$(echo "$p" | xargs)" 2>/dev/null; done \
         | sort -u | xargs)
else
  s_total=0; s_busy=0; s_gu=""
fi
s_li=$(who 2>/dev/null | awk '{print $1}' | sort -u | xargs)
echo "__SUMMARY__|${s_busy}|${s_total}|${s_gu}|${s_li}"
REMOTE_EOF

# ---- probe one host -------------------------------------------------------
# Run the remote snippet on one host and echo its raw output. Returns ssh's exit
# code. Shared by the terminal, --json and --web paths so there is exactly one
# place that knows how to reach a host.
ssh_probe_raw() {
  local host="$1"
  local target="$host"
  [[ -n "$SSH_USER" && "$host" != *@* ]] && target="${SSH_USER}@${host}"

  # Built as positional params rather than an array: bash cannot export arrays,
  # and this function runs inside the xargs workers via `export -f`. Safe here
  # because $host was already captured above.
  set -- -o BatchMode=yes \
         -o ConnectTimeout="$CONNECT_TIMEOUT" \
         -o StrictHostKeyChecking=accept-new
  if [[ -n "${SSH_MUX_DIR:-}" ]]; then
    set -- "$@" -o ControlMaster=auto \
                -o ControlPath="$SSH_MUX_DIR/%C" \
                -o ControlPersist="$SSH_MUX_PERSIST"
  fi

  local out
  out=$(ssh "$@" "$target" "TOP_N=$TOP_N; $REMOTE" 2>&1)
  local rc=$?
  out="${out//$'\r'/}"   # strip CRs; proxied ssh errors carry \r and mangle the line
  printf '%s' "$out"
  return $rc
}

probe() {
  local host="$1"

  local out rc
  out=$(ssh_probe_raw "$host"); rc=$?

  if [[ "$SUMMARY" == "1" ]]; then
    if [[ $rc -ne 0 ]]; then
      printf '%-22s UNREACHABLE (%s)\n' "$host" "$(echo "$out" | head -n1)"
      return
    fi
    local line busy total gu li
    line=$(echo "$out" | grep '^__SUMMARY__|' | head -n1)
    IFS='|' read -r _ busy total gu li <<<"$line"
    [[ -z "$gu" ]] && gu="none"
    [[ -z "$li" ]] && li="none"
    # Usernames are space-separated and space-padded so each is one
    # double-click-to-copy word (no commas/colons touching them).
    printf '%-22s %s/%s GPUs busy   gpu:  %s   logged in:  %s \n' \
      "$host" "${busy:-0}" "${total:-0}" "$gu" "$li"
    return
  fi

  {
    echo "########################################################################"
    echo "# $host"
    echo "########################################################################"
    if [[ $rc -ne 0 ]]; then
      echo "  !! unreachable / ssh failed (rc=$rc): $(echo "$out" | head -n1)"
    else
      echo "$out" | grep -v -e '^__SUMMARY__|' -e '^__GPU__|'
    fi
    echo
  }
}

# ---- structured data (--json / --web) -------------------------------------
# Escape stdin into a JSON string literal, quotes included. Usernames and
# process names are untrusted, so this has to be right: `<` becomes < so a
# process called "</script>" cannot break out of an inlined script block, and
# control characters are dropped outright (tab and newline are kept, as \t/\n).
json_str() {
  tr -d '\000-\010\013-\037\177' | awk '
    BEGIN { ORS=""; printf "\"" }
    {
      s = $0
      gsub(/\\/,   "\\\\",    s)
      gsub(/"/,    "\\\"",    s)
      gsub(/\t/,   "\\t",     s)
      gsub(/</,    "\\u003c", s)
      if (NR > 1) printf "\\n"
      printf "%s", s
    }
    END { printf "\"" }'
}

# Space-separated words -> JSON array of strings. Unquoted $1 on purpose.
json_words_array() {
  local out="" w
  for w in $1; do
    out="${out:+$out,}$(printf '%s' "$w" | json_str)"
  done
  printf '[%s]' "$out"
}

# Probe one host and write its JSON object to $WEB_TMP/<idx>.json. Keyed by
# index so the caller can reassemble the array in the order hosts were given,
# which xargs -P cannot guarantee on its own.
probe_json_one() {
  local idx="$1" host="$2"
  local out rc line busy total gu li gpus detail err

  out=$(ssh_probe_raw "$host"); rc=$?

  if [[ $rc -ne 0 ]]; then
    err=$(printf '%s\n' "$out" | head -n1)
    {
      printf '{"name":%s,'    "$(printf '%s' "$host" | json_str)"
      printf '"reachable":false,"error":%s,' "$(printf '%s' "$err" | json_str)"
      printf '"busy":0,"total":0,"gpu_users":[],"logged_in":[],"gpus":[],'
      printf '"detail":%s}'   "$(printf '%s' "$out" | json_str)"
    } > "$WEB_TMP/$idx.json"
    return
  fi

  line=$(printf '%s\n' "$out" | grep '^__SUMMARY__|' | head -n1)
  IFS='|' read -r _ busy total gu li <<<"$line"

  # Per-GPU objects. Values can legitimately be "[N/A]" (MIG, unsupported
  # cards), so anything non-numeric becomes -1 and the UI renders it as unknown
  # rather than a misleading 0.
  gpus=$(printf '%s\n' "$out" | awk -F'|' '
    $1 == "__GPU__" {
      name = $3
      gsub(/[\\"<]/, "", name)          # vendor model string; strip, do not escape
      u  = ($4 ~ /^[0-9]+$/) ? $4 + 0 : -1
      mu = ($5 ~ /^[0-9]+$/) ? $5 + 0 : -1
      mt = ($6 ~ /^[0-9]+$/) ? $6 + 0 : -1
      if (n++) printf ","
      printf "{\"index\":%d,\"name\":\"%s\",\"util\":%d,\"mem_used\":%d,\"mem_total\":%d}", \
             $2 + 0, name, u, mu, mt
    }')

  detail=$(printf '%s\n' "$out" | grep -v -e '^__SUMMARY__|' -e '^__GPU__|')

  {
    printf '{"name":%s,'  "$(printf '%s' "$host" | json_str)"
    printf '"reachable":true,"error":"",'
    printf '"busy":%s,"total":%s,' "${busy:-0}" "${total:-0}"
    printf '"gpu_users":%s,'  "$(json_words_array "$gu")"
    printf '"logged_in":%s,'  "$(json_words_array "$li")"
    printf '"gpus":[%s],'     "$gpus"
    printf '"detail":%s}'     "$(printf '%s' "$detail" | json_str)"
  } > "$WEB_TMP/$idx.json"
}

# Probe every host in parallel, then emit one JSON document in host order.
collect_fleet_json() {
  local i first=1
  rm -f "$WEB_TMP"/*.json 2>/dev/null

  # "<idx> <host>" pairs; -n 2 hands each pair to one worker. Host names never
  # contain spaces (they are ssh aliases or user@host), so this split is safe.
  for i in "${!hosts[@]}"; do printf '%s %s\n' "$i" "${hosts[$i]}"; done \
    | xargs -P "$PARALLEL" -n 2 bash -c 'probe_json_one "$1" "$2"' _

  printf '{"ts":%s,"interval":%s,"version":%s,"update":%s,"hosts":[' \
    "$(date +%s)" "$WEB_INTERVAL" \
    "$(version_string | json_str)" \
    "$( { update_available || true; } | json_str)"
  for i in "${!hosts[@]}"; do
    [[ -f "$WEB_TMP/$i.json" ]] || continue
    [[ $first -eq 1 ]] || printf ','
    first=0
    cat "$WEB_TMP/$i.json"
  done
  printf ']}\n'
}

export -f probe ssh_probe_raw probe_json_one json_str json_words_array
export SSH_USER CONNECT_TIMEOUT TOP_N REMOTE SUMMARY SSH_MUX_DIR SSH_MUX_PERSIST

# ---- --web ----------------------------------------------------------------
# The dashboard is two files: a shell page written once, and a data file the
# probe loop rewrites. The page pulls new data in by injecting a <script src>
# at it -- script tags ignore the same-origin policy, which is what makes this
# work from file:// where fetch() is blocked. No server, no dependencies.

# The shell never changes, so it is written once per run.
write_shell_html() {
  cat > "$WEB_OUT/fleet.html" <<'WEB_HTML_EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>who-gpu</title>
<style>
  * { box-sizing: border-box; }
  body {
    margin: 0; background: #444444; color: #f0f0f0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
                 "Helvetica Neue", Arial, sans-serif;
  }
  .navbar {
    background: #333333; border-bottom: 1px solid #262626;
    padding: 12px 20px; display: flex; flex-wrap: wrap;
    align-items: center; gap: 16px;
    position: sticky; top: 0; z-index: 10;
  }
  .navheader h1 { margin: 0; font-size: 20px; font-weight: 600; letter-spacing: .3px; }
  .pagenav { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; margin-left: auto; }
  .pagenav input, .pagenav select, .pagenav button {
    background: #4d4d4d; color: #f0f0f0; border: 1px solid #5e5e5e;
    border-radius: 4px; padding: 6px 10px; font-size: 13px; font-family: inherit;
  }
  .pagenav button { cursor: pointer; }
  .pagenav button:hover { background: #5a5a5a; }
  .pagenav input { min-width: 160px; }
  #status { font-size: 13px; color: #b9b9b9; white-space: nowrap; }
  #status.stale { color: #ffb347; font-weight: 600; }
  /* "Notify only": says an update exists, never installs anything. */
  #update {
    font-size: 12px; color: #2b2b2b; background: #8ade8a; text-decoration: none;
    padding: 4px 9px; border-radius: 4px; white-space: nowrap; font-weight: 600;
    cursor: default;
  }

  .main-content { padding: 20px; max-width: 1600px; margin: 0 auto; }
  .summary { font-size: 15px; color: #d8d8d8; margin-bottom: 20px; }
  .summary strong { color: #ffffff; font-size: 17px; }

  .systems-container { margin-bottom: 28px; }
  .systems-container h2 {
    font-size: 15px; font-weight: 600; text-transform: uppercase;
    letter-spacing: .8px; color: #bdbdbd; margin: 0 0 12px;
    border-bottom: 1px solid #555; padding-bottom: 6px;
  }
  .cards-container { display: flex; flex-wrap: wrap; gap: 14px; }

  /* The whole card is the wrapper: header row + GPU bars + detail pane share
     one background, so the bars read as part of the card rather than floating
     on the page. */
  .card-wrap {
    display: flex; flex-direction: column;
    min-width: 340px; flex: 1 1 340px; max-width: 520px;
    background: #545454; border-radius: 6px; border-left: 5px solid #777;
    overflow: hidden; cursor: pointer; transition: background .12s;
  }
  .card-wrap:hover { background: #5c5c5c; }
  .card-wrap.free    { border-left-color: #6fcf6f; }
  .card-wrap.partial { border-left-color: #f0c24b; }
  .card-wrap.full    { border-left-color: #e5735f; }
  .card-wrap.down    { border-left-color: #8a8a8a; opacity: .8; }

  .card { display: flex; }
  .card .left  { padding: 14px 16px; flex: 0 0 46%; }
  .card .right { padding: 14px 16px; flex: 1; background: rgba(255,255,255,.05); }

  .card .left h1 {
    margin: 0 0 4px; font-size: 15px; font-weight: 600;
    word-break: break-all; color: #ffffff;
  }
  .percent { line-height: 1; margin: 6px 0 2px; }
  .percent span { font-size: 42px; font-weight: 300; }
  .percentsymbol { font-size: 18px; font-weight: 300; color: #c4c4c4; margin-left: 1px; }
  .card-wrap.free    .percent span { color: #8ade8a; }
  .card-wrap.partial .percent span { color: #f5d180; }
  .card-wrap.full    .percent span { color: #f0968a; }
  .card-wrap.down    .percent span { color: #9e9e9e; font-size: 30px; }
  .sublabel { font-size: 11px; text-transform: uppercase; letter-spacing: .6px; color: #a8a8a8; }
  .procuser { margin-top: 8px; font-size: 13px; color: #e6e6e6; word-break: break-word; }
  .procuser .none { color: #909090; }

  .stat { margin-bottom: 9px; }
  .stat:last-child { margin-bottom: 0; }
  .stat h3 {
    margin: 0; font-size: 10px; font-weight: 600; text-transform: uppercase;
    letter-spacing: .6px; color: #a0a0a0;
  }
  .stat p { margin: 1px 0 0; font-size: 13px; color: #f0f0f0; word-break: break-word; }

  .gpubars { padding: 2px 16px 12px; }
  .gpubar { display: flex; align-items: center; gap: 8px; margin-top: 5px; font-size: 11px; color: #b5b5b5; }
  .gpubar .idx { flex: 0 0 34px; }
  .gpubar .track { flex: 1; height: 6px; background: #3a3a3a; border-radius: 3px; overflow: hidden; }
  .gpubar .fill { height: 100%; background: #6fcf6f; border-radius: 3px; }
  .gpubar .fill.mid  { background: #f0c24b; }
  .gpubar .fill.high { background: #e5735f; }
  .gpubar .pct { flex: 0 0 38px; text-align: right; }

  .detail {
    margin: 0; padding: 12px 16px; background: #3b3b3b; border-top: 1px solid #565656;
    font-size: 12px; line-height: 1.45; white-space: pre-wrap; word-break: break-word;
    color: #d5d5d5; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  .empty { color: #9a9a9a; font-size: 14px; }
</style>
</head>
<body>

<div class="navbar">
  <div class="navheader"><h1>who-gpu</h1></div>
  <div class="pagenav">
    <input id="filter" type="search" placeholder="Filter machines" autocomplete="off">
    <select id="sort">
      <option value="name">Sort: name</option>
      <option value="busiest">Sort: busiest first</option>
      <option value="freest">Sort: freest first</option>
    </select>
    <button id="refresh" type="button">Refresh</button>
    <button id="pause" type="button">Pause</button>
    <span id="status">loading&hellip;</span>
    <a id="update" href="#" hidden></a>
  </div>
</div>

<div class="main-content">
  <div class="summary" id="summary">Waiting for the first probe&hellip;</div>

  <div class="systems-container" id="sec-free" hidden>
    <h2>Available</h2><div class="cards-container" id="cards-free"></div>
  </div>
  <div class="systems-container" id="sec-busy" hidden>
    <h2>In use</h2><div class="cards-container" id="cards-busy"></div>
  </div>
  <div class="systems-container" id="sec-down" hidden>
    <h2>Unreachable</h2><div class="cards-container" id="cards-down"></div>
  </div>
  <div class="systems-container" id="sec-none" hidden>
    <p class="empty">No machines match that filter.</p>
  </div>
</div>

<script>
(function () {
  "use strict";

  var POLL_MS = 3000;         // how often to re-read the data file (a local read)
  var data = null;            // most recent payload
  var cards = {};             // host name -> DOM nodes, so updates patch in place
  var expanded = {};          // host name -> detail pane open?
  var paused = false;
  var pollTimer = null;

  var $ = function (id) { return document.getElementById(id); };

  // --- data in ------------------------------------------------------------
  // A <script src> is not subject to the same-origin policy, so this works on
  // file:// where fetch() does not. The query string defeats caching.
  function pull() {
    var s = document.createElement("script");
    s.src = "fleet-data.js?t=" + Date.now();
    s.onload = function () { s.remove(); };
    s.onerror = function () { s.remove(); setStatus(true, "data file unreadable"); };
    document.body.appendChild(s);
  }

  window.whoGpuUpdate = function (payload) {
    data = payload;
    render();
  };

  // --- helpers ------------------------------------------------------------
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }
  function setText(node, value) {           // only touch the DOM when it changed
    if (node.textContent !== value) node.textContent = value;
  }
  function classFor(h) {
    if (!h.reachable) return "down";
    if (h.total === 0 || h.busy === 0) return "free";
    return h.busy >= h.total ? "full" : "partial";
  }
  function statusWord(h) {
    if (!h.reachable) return "Unreachable";
    if (h.total === 0) return "No GPUs";
    if (h.busy === 0) return "Free";
    return h.busy >= h.total ? "Fully busy" : "Partly busy";
  }
  function peakUtil(h) {
    var p = -1, i;
    for (i = 0; i < h.gpus.length; i++) if (h.gpus[i].util > p) p = h.gpus[i].util;
    return p;
  }
  function memPct(h) {
    var used = 0, total = 0, i, g;
    for (i = 0; i < h.gpus.length; i++) {
      g = h.gpus[i];
      if (g.mem_used >= 0 && g.mem_total > 0) { used += g.mem_used; total += g.mem_total; }
    }
    return total > 0 ? Math.round((used / total) * 100) : -1;
  }
  function joinUsers(list) { return list.length ? list.join("  ") : ""; }

  // --- card construction / patching ---------------------------------------
  function buildCard(h) {
    var wrap = el("div", "card-wrap");
    var card = el("div", "card");
    var left = el("div", "left");
    var right = el("div", "right");

    var title = el("h1", null, h.name);
    var pct = el("div", "percent");
    var big = el("span"); var sup = el("sup", "percentsymbol");
    pct.appendChild(big); pct.appendChild(sup);
    var sub = el("div", "sublabel", "GPUs busy");
    var users = el("div", "procuser");
    left.appendChild(title); left.appendChild(pct);
    left.appendChild(sub); left.appendChild(users);

    var stats = {};
    ["Status", "Peak util", "Memory", "Logged in"].forEach(function (label) {
      var box = el("div", "stat");
      box.appendChild(el("h3", null, label));
      var p = el("p", null, "");
      box.appendChild(p); right.appendChild(box);
      stats[label] = p;
    });

    card.appendChild(left); card.appendChild(right);
    var bars = el("div", "gpubars");
    var detail = el("pre", "detail");
    detail.hidden = true;

    wrap.appendChild(card); wrap.appendChild(bars); wrap.appendChild(detail);

    card.addEventListener("click", function () {
      expanded[h.name] = !expanded[h.name];
      detail.hidden = !expanded[h.name];
    });

    var refs = { wrap: wrap, card: card, title: title, big: big, sup: sup,
                 sub: sub, users: users, stats: stats, bars: bars, detail: detail };
    cards[h.name] = refs;
    return refs;
  }

  function updateCard(h) {
    var r = cards[h.name] || buildCard(h);
    var cls = "card-wrap " + classFor(h);
    if (r.wrap.className !== cls) r.wrap.className = cls;

    setText(r.title, h.name);

    if (!h.reachable) {
      setText(r.big, "—");
      setText(r.sup, "");
      setText(r.sub, "no response");
    } else if (h.total === 0) {
      setText(r.big, "—");
      setText(r.sup, "");
      setText(r.sub, "no GPUs detected");
    } else {
      setText(r.big, String(h.busy));
      setText(r.sup, "/" + h.total);
      setText(r.sub, "GPUs busy");
    }

    var gu = joinUsers(h.gpu_users);
    setText(r.users, gu || (h.reachable ? "nobody on the GPUs" : ""));
    r.users.className = gu ? "procuser" : "procuser none";

    var pu = peakUtil(h), mp = memPct(h);
    setText(r.stats["Status"], statusWord(h));
    setText(r.stats["Peak util"], pu >= 0 ? pu + "%" : "—");
    setText(r.stats["Memory"], mp >= 0 ? mp + "%" : "—");
    setText(r.stats["Logged in"], joinUsers(h.logged_in) || "nobody");

    if (!h.reachable && h.error) setText(r.stats["Status"], h.error);

    // GPU bars: rebuilt only when the shape or the numbers actually changed.
    var sig = h.gpus.map(function (g) { return g.index + ":" + g.util; }).join(",");
    if (r.bars.dataset.sig !== sig) {
      r.bars.dataset.sig = sig;
      r.bars.textContent = "";
      h.gpus.forEach(function (g) {
        var row = el("div", "gpubar");
        row.appendChild(el("span", "idx", "GPU" + g.index));
        var track = el("div", "track");
        var fill = el("div", "fill");
        var u = g.util < 0 ? 0 : g.util;
        fill.style.width = u + "%";
        if (u >= 70) fill.className = "fill high";
        else if (u >= 25) fill.className = "fill mid";
        track.appendChild(fill);
        row.appendChild(track);
        row.appendChild(el("span", "pct", g.util < 0 ? "—" : g.util + "%"));
        r.bars.appendChild(row);
      });
    }

    var det = h.detail || "";
    if (r.detail.textContent !== det) r.detail.textContent = det;
    r.detail.hidden = !expanded[h.name];

    return r;
  }

  // --- rendering ----------------------------------------------------------
  function render() {
    if (!data) return;

    var q = $("filter").value.trim().toLowerCase();
    var mode = $("sort").value;

    var shown = data.hosts.filter(function (h) {
      if (!q) return true;
      var hay = (h.name + " " + h.gpu_users.join(" ") + " " + h.logged_in.join(" ")).toLowerCase();
      return hay.indexOf(q) !== -1;
    });

    shown.sort(function (a, b) {
      if (mode === "busiest") return (b.busy - a.busy) || a.name.localeCompare(b.name);
      if (mode === "freest") return ((a.busy - a.total) - (b.busy - b.total)) || a.name.localeCompare(b.name);
      return a.name.localeCompare(b.name);
    });

    var buckets = { free: [], busy: [], down: [] };
    shown.forEach(function (h) {
      var c = classFor(h);
      if (c === "down") buckets.down.push(h);
      else if (c === "free") buckets.free.push(h);
      else buckets.busy.push(h);
    });

    ["free", "busy", "down"].forEach(function (key) {
      var container = $("cards-" + key);
      var list = buckets[key];
      list.forEach(function (h, i) {
        var r = updateCard(h);
        // appendChild moves an existing node, so this reorders without rebuilding
        if (container.children[i] !== r.wrap) container.insertBefore(r.wrap, container.children[i] || null);
      });
      while (container.children.length > list.length) container.removeChild(container.lastChild);
      $("sec-" + key).hidden = list.length === 0;
    });

    $("sec-none").hidden = shown.length !== 0;

    var upd = $("update");
    if (data.update) {
      setText(upd, "update available (" + data.update + ") — run: who-gpu --update");
      upd.hidden = false;
    } else {
      upd.hidden = true;
    }

    var free = data.hosts.filter(function (h) { return classFor(h) === "free"; }).length;
    var down = data.hosts.filter(function (h) { return !h.reachable; }).length;
    var msg = "<strong>" + free + " of " + data.hosts.length + "</strong> machines free";
    if (down) msg += " · " + down + " unreachable";
    if ($("summary").innerHTML !== msg) $("summary").innerHTML = msg;

    tickStatus();
  }

  // --- staleness ----------------------------------------------------------
  // The page cannot trigger a probe, so it must never let old numbers pass for
  // current ones. This is the honesty valve.
  function setStatus(stale, text) {
    var s = $("status");
    setText(s, text);
    if (s.classList.contains("stale") !== !!stale) s.classList.toggle("stale", !!stale);
  }
  function tickStatus() {
    if (!data) return;
    var age = Math.max(0, Math.round(Date.now() / 1000 - data.ts));
    var limit = Math.max(30, (data.interval || 10) * 3);
    var txt = age < 2 ? "updated just now" : "updated " + age + "s ago";
    if (paused) txt += " · paused";
    setStatus(age > limit, age > limit ? txt + " · probe loop stopped?" : txt);
  }

  // --- controls -----------------------------------------------------------
  $("refresh").addEventListener("click", pull);
  $("filter").addEventListener("input", render);
  $("sort").addEventListener("change", render);
  $("pause").addEventListener("click", function () {
    paused = !paused;
    this.textContent = paused ? "Resume" : "Pause";
    tickStatus();
  });

  pollTimer = setInterval(function () { if (!paused) pull(); }, POLL_MS);
  setInterval(tickStatus, 1000);
  pull();
})();
</script>
</body>
</html>
WEB_HTML_EOF
}

# Rewrite the data file atomically: rename within one directory cannot be seen
# half-finished, so the page never loads a torn file.
write_data_js() {
  local tmp="$WEB_OUT/fleet-data.js.new"
  { printf 'whoGpuUpdate('; collect_fleet_json; printf ');\n'; } > "$tmp" \
    && mv -f "$tmp" "$WEB_OUT/fleet-data.js"
}

# Can this ssh reuse connections? `-G` only parses the config and prints it --
# no network, no side effects. It arrived in OpenSSH 6.8 and the %C token in
# 6.7, so an ssh that accepts this also understands the ControlPath we use.
ssh_supports_mux() {
  [[ -z "${WHO_GPU_NO_MUX:-}" ]] || return 1
  ssh -o ControlMaster=auto -o ControlPath=none -o ControlPersist=60 \
      -G localhost >/dev/null 2>&1
}

# Control sockets need a SHORT path: the sun_path limit is ~104 bytes and %C
# spends most of it. $TMPDIR is far too long on macOS (/var/folders/...), so
# use a fixed, per-user directory instead. 0700 plus an ownership check, since
# /tmp is shared and a socket someone else owns must never be trusted.
setup_ssh_mux() {
  ssh_supports_mux || return 1
  local dir="/tmp/who-gpu-mux-$(id -u)"
  mkdir -m 700 -p "$dir" 2>/dev/null || return 1
  [[ -O "$dir" && -d "$dir" ]] || return 1     # exists but is not ours -> refuse
  SSH_MUX_DIR="$dir"
  # The master has to outlive the gap between cycles, or we would be paying for
  # a fresh login every time after all.
  SSH_MUX_PERSIST=$(( WEB_INTERVAL * 6 + 60 ))
  export SSH_MUX_DIR SSH_MUX_PERSIST
  return 0
}

# Did multiplexing actually happen? `ssh -G` only proves the options PARSE --
# an ssh can accept them and then not implement them, which is reported to be
# the case on Git Bash / Win32 OpenSSH. If no control socket appeared after a
# full probe cycle, multiplexing is not working and must be switched off:
# leaving it on risks every host failing rather than merely re-authenticating.
mux_took_effect() {
  [[ -n "${SSH_MUX_DIR:-}" ]] || return 1
  local f
  for f in "$SSH_MUX_DIR"/*; do
    [[ -S "$f" ]] && return 0      # a real socket, not just any leftover file
  done
  return 1
}

disable_ssh_mux() {
  local dir="${SSH_MUX_DIR:-}"
  SSH_MUX_DIR=""
  SSH_MUX_PERSIST=""
  export SSH_MUX_DIR SSH_MUX_PERSIST
  [[ -n "$dir" ]] && rmdir "$dir" 2>/dev/null
  return 0
}

# Hang up the shared connections on the way out instead of leaving them open
# until ControlPersist expires.
close_ssh_mux() {
  [[ -n "${SSH_MUX_DIR:-}" ]] || return 0
  local sock
  for sock in "$SSH_MUX_DIR"/*; do
    [[ -S "$sock" ]] || continue
    ssh -o ControlPath="$sock" -O exit who-gpu-mux >/dev/null 2>&1
  done
  rmdir "$SSH_MUX_DIR" 2>/dev/null
}

# Same OS detection shape as install.sh, for the same reasons.
web_detect_os() {
  case "$(uname -s)" in
    Linux*)               echo linux ;;
    Darwin*)              echo darwin ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *)                    echo unknown ;;
  esac
}

# The Windows-native form of a path, for handing to a native .exe.
win_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$p"; return; fi
  # cygpath missing (unusual): /c/Users/... is C:/Users/... by hand. Windows
  # takes forward slashes, so only the drive letter needs moving.
  case "$p" in
    /?/*) printf '%s:%s\n' "${p:1:1}" "${p:2}" ;;
    *)    printf '%s\n' "$p" ;;
  esac
}

open_browser() {
  local path="$1" win
  case "$(web_detect_os)" in
    darwin)
      open "$path" >/dev/null 2>&1 && return 0 ;;
    windows)
      # Two Windows-only traps here. First, Git Bash and MSYS2 rewrite arguments
      # that look like Unix paths before a native .exe sees them, and /c is a
      # path: it is the C: drive. So cmd.exe /c arrives as cmd.exe C:\ and cmd
      # does nothing. MSYS_NO_PATHCONV (Git Bash) and MSYS2_ARG_CONV_EXCL
      # (MSYS2/Cygwin) switch that off for the one call that must not be touched.
      # Second, hand `start` a plain Windows path rather than a file:// URL --
      # a URL would need the spaces in C:\Users\First Last percent-encoded, and
      # Windows already knows to open .html in the default browser.
      win="$(win_path "$path")"
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
        cmd.exe /c start "" "$win" >/dev/null 2>&1 && return 0
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
        powershell.exe -NoProfile -Command "Start-Process '${win//\'/\'\'}'" >/dev/null 2>&1 && return 0
      # explorer.exe opens the file and *then* exits non-zero, so its status
      # says nothing. Ask it last and take silence for success.
      command -v explorer.exe >/dev/null 2>&1 && { explorer.exe "$win" >/dev/null 2>&1; return 0; } ;;
    *)
      command -v xdg-open >/dev/null 2>&1 && xdg-open "$path" >/dev/null 2>&1 && return 0 ;;
  esac
  return 1
}

run_web() {
  mkdir -p "$WEB_OUT" || { echo "who-gpu: cannot create $WEB_OUT" >&2; exit 1; }
  WEB_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t who-gpu) || {
    echo "who-gpu: cannot create a temp directory" >&2; exit 1; }
  export WEB_TMP
  trap 'close_ssh_mux; rm -rf "$WEB_TMP"; printf "\nwho-gpu: stopped. Dashboard left at %s\n" "$WEB_OUT/fleet.html"; exit 0' INT TERM HUP

  write_shell_html
  echo "who-gpu: probing ${#hosts[@]} host(s) (up to $PARALLEL at once)"

  # Announced only after we know whether reuse worked, since that decides the
  # refresh rate. Saying "every 10s" and then changing it would be a lie.
  no_reuse_note() {
    echo "who-gpu: this ssh will not reuse connections, so every refresh is a" >&2
    echo "         fresh login on each host." >&2
    if relax_interval_without_mux; then
      echo "         Slowing the refresh rate to go easy on the fleet." >&2
      echo "         Override with WHO_GPU_INTERVAL if you want it faster." >&2
    fi
  }

  setup_ssh_mux || no_reuse_note
  write_data_js

  # Confirm reuse actually took effect rather than assuming it did. `ssh -G`
  # proves only that the options parse; Git Bash / Win32 OpenSSH are reported to
  # accept them without implementing them. The first cycle is re-run after
  # switching off, because unsupported options may have failed it outright.
  if [[ -n "$SSH_MUX_DIR" ]]; then
    if mux_took_effect; then
      echo "who-gpu: reusing one SSH connection per host (no repeat logins)"
    else
      disable_ssh_mux
      no_reuse_note
      write_data_js      # re-probe, and re-stamp the data with the new interval
    fi
  fi
  echo "who-gpu: refreshing every ${WEB_INTERVAL}s"

  if open_browser "$WEB_OUT/fleet.html"; then
    echo "who-gpu: opened $WEB_OUT/fleet.html"
  else
    echo "who-gpu: open this in your browser:"
    # A Unix file:// URL is no use to a Windows browser, so hand that shell the
    # path in the form it can actually paste.
    if [[ "$(web_detect_os)" == windows ]]; then
      echo "         $(win_path "$WEB_OUT/fleet.html")"
    else
      echo "         file://$WEB_OUT/fleet.html"
    fi
  fi
  echo "who-gpu: press Ctrl-C to stop (closing this window also stops it)."
  notify_update

  while true; do
    sleep "$WEB_INTERVAL"
    write_data_js
  done
}

if [[ "$DO_WEB" == "1" || "$DO_JSON" == "1" ]]; then
  WEB_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t who-gpu) || {
    echo "who-gpu: cannot create a temp directory" >&2; exit 1; }
  export WEB_TMP
  if [[ "$DO_JSON" == "1" ]]; then
    trap 'rm -rf "$WEB_TMP"' EXIT
    collect_fleet_json
    exit 0
  fi
  rm -rf "$WEB_TMP"
  run_web
fi

echo "Probing ${#hosts[@]} host(s) with up to $PARALLEL in parallel..."
echo

# Run in parallel but keep each host's block contiguous; sort by host order.
printf '%s\n' "${hosts[@]}" \
  | xargs -P "$PARALLEL" -I{} bash -c 'probe "$@"' _ {}

# After the report, never before it: the check can cost a second and the numbers
# are what the user came for.
notify_update
