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

Prefer a browser? `who-gpu --web` shows the same thing as a live
[dashboard](#web-gui).

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

You can also skip the installer entirely and run `./who-gpu.sh` directly.

The desktop icon opens the web dashboard. `--icon` asks what you want and how
often it refreshes; flags skip the questions:

```bash
./install.sh --icon --icon-mode terminal   # text report instead
./install.sh --icon --interval 30          # dashboard, pinned to 30s
./install.sh --no-update-check             # never check for new versions
```

Answers go to `~/.config/who-gpu/config` — plain text, safe to edit. Re-running
the installer keeps your choices.

### Platform support

| Platform | CLI | Web GUI (`--web`) | Desktop launcher (`--icon`) |
|----------|-----|-------------------|-----------------------------|
| Linux | yes | yes | yes, a `.desktop` entry (GNOME/KDE/XFCE terminals) |
| macOS | yes | yes | yes, a double-click `who-gpu.command` that opens Terminal |
| Windows | yes, via Git Bash | yes | a `who-gpu.cmd` on the Desktop that launches Git Bash |

Everything needs only `bash` and `ssh` — the web GUI adds no dependencies, so it
runs wherever the CLI does. Native Windows (cmd/PowerShell) has no bash, so
**run the installer from Git Bash** (or use WSL).

> **Help wanted:** the Linux CLI and desktop icon are tested in daily use. The
> macOS `.command` and Windows `.cmd` versions are best-effort and have not yet
> been verified on real hardware. If you try one, please report back (or open a
> PR) so this note can be updated.

## Updating

```bash
who-gpu --update
```

Every platform, Windows included, and you never re-run the installer by hand:
the install links into your clone, so one update refreshes the command and the
desktop icon together. If `install.sh` itself changed, `--update` re-runs it.
`who-gpu --version` shows what you're on; a zip download is told to clone
instead.

The installer also puts `~/.local/bin` on your `PATH`, which Git Bash omits, by
appending one line to your shell profile after backing it up (`--no-path`
skips it).

New versions are mentioned once a day, in the terminal and as a dashboard badge.
who-gpu never updates itself; `UPDATE_CHECK=0` silences it.

### Upgrading from before v1.1

`--update` didn't exist then, so it can't deliver itself — you'll just get
`unknown option`, and old installs never report being behind. Once, by hand:

```bash
cd /path/to/who-gpu
git pull
./install.sh
```

After that `--update` handles everything. Your desktop icon will start opening
the web dashboard, which is the new default.

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

Probes the fleet, opens a dashboard in your browser, and keeps it current until
Ctrl-C. Machines are grouped **Available** / **In use** / **Unreachable**; click
one for the full breakdown. All the usual flags still work
(`who-gpu --web -f myhosts.txt`).

No server, no dependencies: the page is a file on disk that the probe loop
rewrites, which is why it works everywhere the CLI does. The page can't trigger
a probe itself, so it always shows how old its data is and flags it loudly if
the loop stops.

Files live in `~/who-gpu-web/` and stay there after you quit, so you can reopen
the last probe (clearly marked stale). Not `~/.cache`, because snap- and
flatpak-confined browsers can't read dot-directories under `$HOME`.

### Connection reuse

`--web` reuses one SSH connection per host (`ControlMaster`) instead of logging
in on every refresh. Where that isn't supported — **notably Git Bash** — it falls
back to a login per refresh and slows the refresh to 60s, unless you pinned an
interval (`WHO_GPU_INTERVAL`, `--interval`, or `INTERVAL=` in your config).

`WHO_GPU_NO_MUX=1` disables reuse.

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
cycles; unset means 10, or 60 when SSH connections can't be reused),
`WHO_GPU_NO_MUX` (set to `1` to disable `--web` SSH connection reuse).

`--json` dumps the same fleet data as JSON for scripting; it's what `--web` is
built on.

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
