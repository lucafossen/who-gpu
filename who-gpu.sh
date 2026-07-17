#!/usr/bin/env bash
#
# who-gpu.sh - SSH into a list of hosts and report who's using each machine.
#
# For every host it collects:
#   - GPU utilization + memory (nvidia-smi)
#   - Which usernames own the running GPU processes
#   - Logged-in users and the top CPU/RAM consumers (ps, htop-style but scrapeable)
#
# By default it reads hosts from ~/.ssh/config (#probe markers) and prints a
# compact one-line-per-host summary; plain `who-gpu` behaves like `who-gpu -S -s`.
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

usage() { sed -n '2,32p' "$0"; exit "${1:-0}"; }

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
    -h|--help)    usage 0 ;;
    -*)           echo "unknown option: $1" >&2; usage 1 ;;
    *)            hosts+=("$1"); shift ;;
  esac
done

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

# Pull hosts from ~/.ssh/config markers (unless hosts were given explicitly).
if [[ "$USE_SSH_CONFIG" == "1" && ${#hosts[@]} -eq 0 && -z "$HOSTS_FILE" ]]; then
  [[ -r "$SSH_CONFIG_FILE" ]] || { echo "cannot read ssh config: $SSH_CONFIG_FILE" >&2; exit 1; }
  while IFS= read -r h; do hosts+=("$h"); done < <(hosts_from_ssh_config "$SSH_CONFIG_FILE")
  [[ ${#hosts[@]} -gt 0 ]] || {
    cat >&2 <<EOF
who-gpu: no #probe markers found in $SSH_CONFIG_FILE

who-gpu reads the host list from your SSH config. Mark each machine you want
probed by adding a "#probe" comment line inside its Host block, for example:

    Host gpu-node-1
        HostName 10.0.0.1
        User alice
        #probe

SSH ignores comment lines, so this does not affect ssh itself. Then re-run:

    who-gpu

Other ways to pass hosts without editing your SSH config:
    who-gpu host1 host2 ...      # hosts directly on the command line
    who-gpu -f hosts.txt        # a file with one host per line
    who-gpu --no-ssh-config     # use the ~/.who-gpu-hosts fallback file
EOF
    exit 1
  }
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
