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
# Env overrides: WHO_GPU_SSH_CONFIG=/path, WHO_GPU_HOSTS=/path
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

usage() { sed -n '2,36p' "$0"; exit "${1:-0}"; }

hosts=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)    HOSTS_FILE="$2"; shift 2 ;;
    -u|--user)    SSH_USER="$2"; shift 2 ;;
    -t|--timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
    -n|--top)     TOP_N="$2"; shift 2 ;;
    -p|--parallel) PARALLEL="$2"; shift 2 ;;
    -s|--summary) SUMMARY=1; shift ;;
    -F|--full)    SUMMARY=0; shift ;;
    -S|--ssh-config) USE_SSH_CONFIG=1; shift ;;
    --no-ssh-config) USE_SSH_CONFIG=0; shift ;;
    --setup|--wizard) DO_SETUP=1; shift ;;
    -h|--help)    usage 0 ;;
    -*)           echo "unknown option: $1" >&2; usage 1 ;;
    *)            hosts+=("$1"); shift ;;
  esac
done

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

  local tagf untagf tmpout
  tagf=$(mktemp); untagf=$(mktemp); tmpout=$(mktemp)
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
probe() {
  local host="$1"
  local target="$host"
  [[ -n "$SSH_USER" && "$host" != *@* ]] && target="${SSH_USER}@${host}"

  local out
  out=$(ssh -o BatchMode=yes \
            -o ConnectTimeout="$CONNECT_TIMEOUT" \
            -o StrictHostKeyChecking=accept-new \
            "$target" "TOP_N=$TOP_N; $REMOTE" 2>&1)
  local rc=$?
  out="${out//$'\r'/}"   # strip CRs; proxied ssh errors carry \r and mangle the line

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
      echo "$out" | grep -v '^__SUMMARY__|'
    fi
    echo
  }
}

export -f probe
export SSH_USER CONNECT_TIMEOUT TOP_N REMOTE SUMMARY

echo "Probing ${#hosts[@]} host(s) with up to $PARALLEL in parallel..."
echo

# Run in parallel but keep each host's block contiguous; sort by host order.
printf '%s\n' "${hosts[@]}" \
  | xargs -P "$PARALLEL" -I{} bash -c 'probe "$@"' _ {}
