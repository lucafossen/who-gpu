# who-gpu

A tiny Bash tool that SSHes into a list of machines, runs
`nvidia-smi` (and a bit of `ps`/`who`), and tells you **which machines are in
use and by which users**.

```
$ who-gpu
Probing 9 host(s) with up to 6 in parallel...

cluster-node-1             0/1 GPUs busy   gpu:  none   logged in:  none
cluster-node-2             1/2 GPUs busy   gpu:  alice5   logged in:  none
private_server             4/4 GPUs busy   gpu:  bob2 alice5   logged in:  bob2 alice5
gpubox                     UNREACHABLE (channel 0: open failed: connect failed: No route to host)
```

Prefer a browser? `who-gpu --web` opens the same information as a live
dashboard that keeps itself up to date. See [Web GUI](#web-gui).

## Why

On a shared GPU fleet the recurring question is "which machines are free, and who's using them?" This answers it in one command.

## Requirements

- **Local:** `bash`, `ssh`, and standard coreutils.
- **Remote:**
  - SSH access (key-based auth is recommended so there are no
  password prompts)
  - `nvidia-smi` (Hosts without `nvidia-smi`
  can still report logged-in users and top CPU processes.)

## Install

```bash
git clone https://github.com/lucafossen/who-gpu.git
cd who-gpu
./install.sh           # installs the `who-gpu` command
./install.sh --icon    # also adds a double-click desktop launcher
```
Uninstall with `./uninstall.sh` (add `--purge` to also drop your preferences).

You can also skip the installer entirely and run `./who-gpu.sh`
directly.

**The desktop icon opens the web dashboard.** With `--icon` the installer asks
what you'd prefer and how often it should refresh; answer with flags instead to
skip the questions:

```bash
./install.sh --icon                          # asks, defaults to the dashboard
./install.sh --icon --icon-mode terminal     # old-style text report instead
./install.sh --icon --interval 30            # dashboard, refreshing every 30s
./install.sh --no-update-check               # never check for new versions
```

Answers are written to `~/.config/who-gpu/config`, which is plain text and safe
to edit by hand. Re-running the installer keeps your existing choices unless you
override them.

## Updating

```bash
who-gpu --update
```

That's it, on every platform. The installer **links** into your clone rather
than copying files out of it, so a single update refreshes the `who-gpu`
command and the desktop icon together — there's nothing to reinstall. (If the
installer itself changed, `--update` re-runs it for you.)

`who-gpu --version` tells you what you're on. who-gpu checks for new versions at
most once a day and simply mentions it — in the terminal, and as a badge in the
dashboard. It never updates itself. Turn the check off with
`UPDATE_CHECK=0` in your config, or `./install.sh --no-update-check`.

If you downloaded a zip instead of cloning, `--update` will say so and tell you
how to switch to a clone.

### Platform support

| Platform | CLI | Web GUI (`--web`) | Desktop launcher (`--icon`) |
|----------|-----|-------------------|-----------------------------|
| Linux | yes | yes | yes, a `.desktop` entry (GNOME/KDE/XFCE terminals) |
| macOS | yes | yes | yes, a double-click `who-gpu.command` that opens Terminal |
| Windows | yes, via Git Bash | yes | a `who-gpu.cmd` on the Desktop that launches Git Bash |

The web GUI works everywhere the CLI does, because it adds no dependencies —
it is still just `bash` and `ssh` (see [Web GUI](#web-gui)).

The report tool itself needs only `bash` and `ssh`, so it runs on all three.
Native Windows (cmd/PowerShell) has no bash, so **run the installer from Git
Bash** (or use WSL).

> **Help wanted:** the Linux CLI and desktop icon are tested in daily use. The
> macOS `.command` and Windows `.cmd` versions are best-effort and have not yet
> been verified on real hardware. If you try one, please report back (or open a
> PR) so this note can be updated.

## Setup

Run the guided setup (also runs on first-time launch):

```bash
who-gpu --setup
```

It scans your `~/.ssh/config`, shows every host with its current probe state, and
lets you toggle each one on or off. Flipping a host **on** adds a `#probe` marker, flipping it
**off** removes one. Your config is backed up (timestamped) before any change.

## Web GUI

```bash
who-gpu --web
```

That's the whole thing. It probes your fleet, opens a dashboard in your browser,
and keeps it up to date until you press Ctrl-C. Machines are grouped into
**Available**, **In use** and **Unreachable**, so the question "what's free right
now?" is answered at a glance. Click any machine for the full breakdown.

All the usual flags still work — `who-gpu --web -f myhosts.txt`,
`who-gpu --web gpu-node-{1..8}`, and so on.

**No new dependencies.** There is no web server and nothing to install: the page
is a plain file on disk that the probe loop rewrites, and it pulls in fresh data
by loading that file. This is why the web GUI works on every platform the CLI
does, including Git Bash on Windows.

A consequence worth knowing: the page can show you the newest data instantly,
but it **cannot make the loop go probe right now** — that would require a
server. In practice this doesn't bite, because the loop re-probes every 10
seconds on its own. The page always displays how old its data is ("updated 4s
ago"), and says so loudly if the loop stops, so old numbers never masquerade as
current ones.

Files are written to `~/who-gpu-web/`. They stay there after you stop, so you
can reopen the dashboard any time to see the last probe — clearly marked stale.

### It does not re-login every cycle

Refreshing every 10 seconds could mean a fresh SSH login on every host, several
times a minute, forever — enough to trip connection rate limits, flood
`auth.log`, and hammer a shared LDAP/Kerberos backend. who-gpu avoids this by
using OpenSSH **connection multiplexing** (`ControlMaster`/`ControlPersist`):

- each host is logged into **once**, when `--web` starts
- every later probe reuses that connection — no TCP handshake, no key exchange,
  no PAM/auth round trip
- connections are hung up when you press Ctrl-C

On startup you'll see `reusing one SSH connection per host (no repeat logins)`
confirming it's active. If your `ssh` is too old to support it, who-gpu says so
and suggests a longer interval instead — in that case set something gentle like
`WHO_GPU_INTERVAL=60`. Disable reuse entirely with `WHO_GPU_NO_MUX=1`.

Control sockets live in `/tmp/who-gpu-mux-$UID/`, created `0700` and refused if
it already exists owned by somebody else.

> **Why not `~/.cache`?** Snap- and flatpak-confined browsers (Ubuntu's default
> Chromium and Firefox) cannot read dot-directories under your home directory,
> so a tidier location would silently fail to open for many people.

## Telling it which hosts to probe

By default who-gpu reads your `~/.ssh/config` and probes every host tagged with
a `#probe` comment.

1. **`~/.ssh/config` `#probe` markers (default):**
   ```sshconfig
   Host gpu-node-1
       HostName 10.0.0.1
       User alice
       #probe
   ```
   Then just run `who-gpu`. (Or let `who-gpu --setup` add these for you.)

2. **On the command line** (you can use bash brace-expansion):
   ```bash
   who-gpu gpu-node-{1..8}
   who-gpu alice@boxA boxB
   ```

3. **A hosts file:** one host per line (`#` comments / blanks ignored). Pass it
   with `-f`, or use `--no-ssh-config` to fall back to `~/.who-gpu-hosts`. See
   [`hosts.example`](hosts.example).
   ```bash
   who-gpu -f myhosts.txt
   ```

## Options

By default who-gpu prints the compact summary and takes hosts from
`~/.ssh/config`. The flags below change that:

| Flag | Meaning |
|------|---------|
| `--web` | Live dashboard in your browser (see [Web GUI](#web-gui)) |
| `--update` | Update to the latest version (see [Updating](#updating)) |
| `--version` | Print the installed version |
| `--setup` | Interactively scan SSH hosts and toggle `#probe` markers on/off |
| `-F`, `--full` | Verbose breakdown instead of the compact summary |
| `-s`, `--summary` | Compact one line per host (the default) |
| `-S`, `--ssh-config` | Read hosts from `~/.ssh/config` `#probe` markers (the default) |
| `--no-ssh-config` | Ignore ssh config; use `-f` or the `~/.who-gpu-hosts` fallback |
| `-f FILE`, `--file FILE` | Read hosts from FILE (one per line) |
| `-u USER`, `--user USER` | SSH as USER (for hosts without a `user@`) |
| `-t SECS`, `--timeout SECS` | SSH connect timeout (default 8) |
| `-n N`, `--top N` | How many top CPU processes to show per host (default 5) |
| `-p N`, `--parallel N` | How many hosts to probe at once (default 6) |
| `-h`, `--help` | Usage |

`--summary`, `--full` and `--web` all answer "what should I emit?", so only one
of them can be given at a time.

Environment overrides: `WHO_GPU_HOSTS` (fallback hosts file path),
`WHO_GPU_SSH_CONFIG` (ssh config path), `WHO_GPU_OUT` (where `--web` writes,
default `~/who-gpu-web`), `WHO_GPU_INTERVAL` (seconds between `--web` probe
cycles, default 10), `WHO_GPU_NO_MUX` (set to `1` to disable `--web` SSH
connection reuse).

There is also an undocumented-by-design `--json`, which dumps the same fleet
data as a JSON document for scripting. It's what `--web` is built on.

## What it reports

- **Summary mode (default):** per host: busy/total GPUs, the usernames running
  GPU processes, and who's logged in.
- **Full mode (`--full`):** per host: uptime/load, logged-in users, per-GPU
  utilization and memory, each GPU process mapped to its owning username, and
  the top CPU processes.
- **Web GUI (`--web`):** one card per machine, grouped by availability, with
  busy/total GPUs, GPU users, per-GPU utilization bars, and the full breakdown
  on click.

## Notes & caveats

- Uses `ssh -o BatchMode=yes`. Hosts without working key auth show up as failed.
- Probes run in parallel, so one dead host won't hold up the rest.
- It reads GPU process owners via `nvidia-smi` + `ps`.

## License

[MIT](LICENSE)
