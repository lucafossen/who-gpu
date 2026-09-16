#!/usr/bin/env bash
# Smoke test for who-gpu.sh. Needs nothing but bash: it puts a fake ssh,
# nvidia-smi and who on PATH, runs every mode against them, and greps the
# output. The fake ssh runs the remote snippet locally under sh, so this
# also checks that the snippet is plain POSIX sh.
#
#   ./test.sh          run everything; exits non-zero on any failure
#   ./test.sh -v       also print each command's output
#
# Nothing here touches the real ~/.ssh/config, config file or dashboard:
# HOME and the XDG dirs point into a temp directory for the duration.
set -u

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHO="$HERE/who-gpu.sh"
ME="$(id -un)"

# ---- sandbox ----------------------------------------------------------------
T=$(mktemp -d 2>/dev/null || mktemp -d -t who-gpu-test) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/gpubin" "$T/home"
export HOME="$T/home"
export XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" XDG_DATA_HOME="$T/home/.local/share"
export WHO_GPU_CONFIG="$T/config"
printf 'UPDATE_CHECK=0\n' > "$WHO_GPU_CONFIG"     # never go near the network
export WHO_GPU_NO_MUX=1                            # never touch the shared control-socket dir
export PATH="$T/bin:$T/gpubin:$PATH"

# Fake ssh: swallows the -o options, answers -G and -O with nothing, and runs
# the command locally under sh, the way a remote login shell would. The host
# name picks the scenario: dead* refuses the connection, nogpu* has no
# nvidia-smi, idle* has GPUs but no processes.
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -G|-O) exit 0 ;;
    -o) shift 2 ;;
    *) break ;;
  esac
done
target="\$1"; shift
case "\$target" in
  dead*)  echo "ssh: connect to host \$target port 22: Connection refused" >&2; exit 255 ;;
  nogpu*) PATH="$T/nogpubin" ;;
esac
export FAKE_HOST="\$target"
exec sh -c "\$*"
EOF

# Fake nvidia-smi: three cards. GPU0 is held by a live process of ours, GPU1
# by a pid ps cannot see (owner "?") whose path has an apostrophe and a
# script tag in it, GPU2 is a unified-memory part reporting [N/A].
cat > "$T/gpubin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *query-gpu*)
    echo "0, NVIDIA A100-SXM4-80GB, 95, 70000, 81920, GPU-aaaa"
    echo "1, NVIDIA A100-SXM4-80GB, 0, 40000, 81920, GPU-bbbb"
    echo "2, NVIDIA GB10, 3, [N/A], [N/A], GPU-cccc" ;;
  *query-compute-apps*)
    case "${FAKE_HOST:-}" in idle*) exit 0 ;; esac
    echo "GPU-aaaa, $PPID, 60000, /usr/bin/python3 train.py"
    echo "GPU-bbbb, 999999, 100, /home/o'brien/run.py </script>" ;;
  *) echo "+---- fake nvidia-smi table ----+" ;;
esac
EOF

# Fake who: one line per name in $FAKE_WHO.
cat > "$T/bin/who" <<'EOF'
#!/usr/bin/env bash
for u in ${FAKE_WHO:-}; do echo "$u  pts/0  2026-01-01 00:00"; done
EOF

# A PATH with no nvidia-smi on it at all, real or fake, for the nogpu* hosts:
# just the tools the remote snippet uses, linked in one by one.
mkdir -p "$T/nogpubin"
for tool in sh awk sed sort paste ps xargs grep wc cut head uptime; do
  p=$(command -v "$tool") && ln -s "$p" "$T/nogpubin/$tool"
done
ln -s "$T/bin/who" "$T/nogpubin/who"

# No browser windows during a test run.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/xdg-open"
cp "$T/bin/xdg-open" "$T/bin/open"
chmod +x "$T/bin/"* "$T/gpubin/"*

# ---- assertions -------------------------------------------------------------
PASS=0; FAIL=0
show() { [[ "$VERBOSE" == 1 ]] && printf '%s\n' "$1" | sed 's/^/    | /'; return 0; }
expect() {      # expect DESCRIPTION REGEX TEXT: TEXT must contain a line matching REGEX
  if printf '%s\n' "$3" | grep -qE -- "$2"; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "      wanted /$2/ in:"; printf '%s\n' "$3" | sed 's/^/      /' | head -30; fi
}
refuse() {      # refuse DESCRIPTION REGEX TEXT: no line may match
  if printf '%s\n' "$3" | grep -qE -- "$2"; then FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "      did not want /$2/ in:"; printf '%s\n' "$3" | grep -E -- "$2" | sed 's/^/      /'
  else PASS=$((PASS + 1)); fi
}
expect_rc() {   # expect_rc DESCRIPTION WANTED GOT
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (exit $3, wanted $2)"; fi
}

# ---- summary ----------------------------------------------------------------
out=$(FAKE_WHO="alice bob" "$WHO" --summary --no-ssh-config box1 idle1 nogpu1 dead1 2>&1); rc=$?; show "$out"
expect_rc "summary exits 0"          0 "$rc"
expect "summary: busy count"          "^box1 +2/3 GPUs busy"           "$out"
expect "summary: unknown owner shown" "^box1 .*gpu:  \? $ME "          "$out"
expect "summary: logged-in users"     "^box1 .*logged in:  alice bob"  "$out"
expect "summary: idle host"           "^idle1 +1/3 GPUs busy +gpu:  none" "$out"
expect "summary: no nvidia-smi"       "^nogpu1 +0/0 GPUs busy"         "$out"
expect "summary: dead host"           "^dead1 +UNREACHABLE \(ssh: connect" "$out"

# ---- full -------------------------------------------------------------------
out=$(FAKE_WHO="" "$WHO" --full --no-ssh-config box1 2>&1); rc=$?; show "$out"
expect_rc "full exits 0"             0 "$rc"
expect "full: host banner"           "^# box1$"                                        "$out"
expect "full: nobody logged in"      "^\(none\)$"                                      "$out"
expect "full: gpu line"              "GPU0 NVIDIA A100-SXM4-80GB \| util 95% \| mem 70000/81920 MiB" "$out"
expect "full: unified memory marked" "GPU2 NVIDIA GB10 .*\(unified\)"                  "$out"
expect "full: process owner"         "GPU 0 \| User: $ME \| PID: [0-9]+ \| Memory: 60000 MiB \| Process: /usr/bin/python3 train.py" "$out"
expect "full: quote in process name" "GPU 1 \| User: \? \| PID: 999999 .*Process: /home/o'brien/run.py </script>" "$out"
expect "full: top cpu section"       "^=== top cpu"                                    "$out"
refuse "full: no machine lines"      "^__(SUMMARY|GPU)__"                              "$out"
refuse "full: no xargs noise"        "xargs:"                                          "$out"

out=$(FAKE_WHO="" "$WHO" --full --no-ssh-config nogpu1 dead1 2>&1); show "$out"
expect "full: nvidia-smi missing"    "\(nvidia-smi not found\)"                        "$out"
expect "full: dead host"             "!! unreachable / ssh failed \(rc=255\)"          "$out"

# ---- json -------------------------------------------------------------------
out=$(FAKE_WHO="alice" "$WHO" --json --no-ssh-config box1 dead1 2>&1); rc=$?; show "$out"
expect_rc "json exits 0"            0 "$rc"
expect "json: one line"             "^\{\"ts\":[0-9]+,.*\}$"                          "$out"
expect "json: counts"               "\"name\":\"box1\",\"reachable\":true,\"error\":\"\",\"busy\":2,\"total\":3" "$out"
expect "json: gpu users"            "\"gpu_users\":\[\"\?\",\"$ME\"\]"                "$out"
expect "json: logged in"            "\"logged_in\":\[\"alice\"\]"                     "$out"
expect "json: per-gpu users"        "\"index\":1,.*\"users\":\[\"\?\"\]"              "$out"
expect "json: N/A becomes -1"       "\"index\":2,\"name\":\"NVIDIA GB10\",\"util\":3,\"mem_used\":-?[0-9]+,\"mem_total\":-?[0-9]+,\"unified\":true" "$out"
expect "json: nvidia-smi table"     "\"smi\":\"\+---- fake nvidia-smi table ----\+\"" "$out"
expect "json: < escaped"            "run.py \\\\u003c/script>"                        "$out"
refuse "json: raw script tag"       "</script>"                                       "$out"
expect "json: dead host"            "\"name\":\"dead1\",\"reachable\":false,\"error\":\"ssh: connect to host dead1" "$out"
if command -v python3 >/dev/null 2>&1; then
  if printf '%s\n' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); echo "FAIL: json: python3 cannot parse it"; fi
fi

# ---- host sources -----------------------------------------------------------
printf '# comment\n\nbox1   # trailing\n  idle1\n' > "$T/hosts"
out=$("$WHO" --summary -f "$T/hosts" 2>&1); show "$out"
expect "hosts file: first host"     "^box1 "  "$out"
expect "hosts file: second host"    "^idle1 " "$out"
refuse "hosts file: comment"        "comment" "$out"

cat > "$T/sshcfg" <<'EOF'
Host box1
  HostName 10.0.0.1
  #probe
Match host something
  #probe
Host idle1 idle2
  # probe: note
Host *
  #probe
Host dead1
EOF
out=$(WHO_GPU_SSH_CONFIG="$T/sshcfg" "$WHO" --summary 2>&1); show "$out"
expect "ssh config: tagged host"       "^box1 "  "$out"
expect "ssh config: # probe: note"     "^idle1 " "$out"
refuse "ssh config: untagged host"     "^dead1 " "$out"
refuse "ssh config: wildcard"          "^\* "    "$out"

out=$(WHO_GPU_HOSTS="$T/hosts" "$WHO" --summary --no-ssh-config 2>&1); show "$out"
expect "fallback hosts file"           "^box1 "  "$out"

# ---- argument errors --------------------------------------------------------
out=$("$WHO" --summary --full 2>&1); rc=$?
expect_rc "two modes: exit 1"  1 "$rc"; expect "two modes: message" "pick one output mode" "$out"
out=$("$WHO" -t 2>&1); rc=$?
expect_rc "-t without value: exit 1" 1 "$rc"; expect "-t without value: message" "needs a number of seconds" "$out"
out=$("$WHO" -p x 2>&1); rc=$?
expect_rc "-p x: exit 1" 1 "$rc"; expect "-p x: message" "whole number of hosts, got 'x'" "$out"
out=$("$WHO" --bogus 2>&1); rc=$?
expect_rc "unknown option: exit 1" 1 "$rc"; expect "unknown option: message" "unknown option: --bogus" "$out"
out=$("$WHO" -f "$T/missing" 2>&1); rc=$?
expect_rc "missing hosts file: exit 1" 1 "$rc"
out=$("$WHO" --version 2>&1); rc=$?
expect_rc "--version exits 0" 0 "$rc"; expect "--version output" "^who-gpu " "$out"
out=$("$WHO" --help 2>&1); rc=$?
expect_rc "--help exits 0" 0 "$rc"; expect "--help shows usage" "^# Usage:" "$out"

# ---- web --------------------------------------------------------------------
# Run one instance until a full cycle has landed, then stop it. TERM rather
# than INT: a script's background jobs start with SIGINT ignored, so INT would
# never reach the trap. No `timeout` either, it is not on macOS.
export WHO_GPU_OUT="$T/web" WHO_GPU_INTERVAL=1
FAKE_WHO="alice" "$WHO" --web --no-ssh-config box1 dead1 > "$T/web.log" 2>&1 < /dev/null &
wpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '"pending":0' "$T/web/fleet-data.js" 2>/dev/null && grep -q '"ts":[1-9]' "$T/web/fleet-data.js" && break
  sleep 1
done
kill -TERM "$wpid" 2>/dev/null
for _ in 1 2 3 4 5; do kill -0 "$wpid" 2>/dev/null || break; sleep 1; done
kill -KILL "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
out=$(cat "$T/web.log"); show "$out"
data=$(cat "$T/web/fleet-data.js" 2>/dev/null); show "$data"
expect "web: page copied"          "^<!doctype html>"                        "$(head -n1 "$T/web/fleet.html" 2>/dev/null)"
expect "web: data is a JS call"    "^whoGpuUpdate\(\{\"ts\":[1-9][0-9]*,\"pending\":0,\"interval\":1," "$data"
expect "web: host in data"         "\"name\":\"box1\",\"reachable\":true"    "$data"
expect "web: dead host in data"    "\"name\":\"dead1\",\"reachable\":false"  "$data"
expect "web: probe marker written" "probe"                                    "$(cat "$T/web/probe-now.js" 2>/dev/null)"
expect "web: announced the page"   "who-gpu: opened|open this in your browser" "$out"
expect "web: stopped cleanly"      "who-gpu: stopped\. Dashboard left at"    "$out"
if [[ -e "$T/web/.who-gpu.pid" ]]; then FAIL=$((FAIL + 1)); echo "FAIL: web: pid file left behind"; else PASS=$((PASS + 1)); fi
unset WHO_GPU_OUT WHO_GPU_INTERVAL

# ---- result -----------------------------------------------------------------
echo
echo "who-gpu tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
