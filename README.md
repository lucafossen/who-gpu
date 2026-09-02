# who-gpu

A small Bash tool that SSHes into a list of machines, runs
`nvidia-smi` (and a bit of `ps`/`who`), and tells you **which machines are in
use and by which users**.

<img width="2150" height="702" alt="image" src="https://github.com/user-attachments/assets/5f091518-7f6c-4f75-9bf4-d0be66834c59" />


Also includes a dependency-free web GUI:
[dashboard](#web-gui):
<img width="2702" height="1632" alt="image" src="https://github.com/user-attachments/assets/22aa8c8c-db4e-456f-ac3f-eb4401c88ee4" />


## Why

On a shared GPU one often needs to figure out which machines are free, and who's using them. This gives an insightful, easily readable overview of that.

## Requirements & platform support

- **Local:** `bash`, `ssh`, and standard coreutils.
- **Remote:**
  - SSH access (key-based auth is recommended so there are no
  password prompts)
  - `nvidia-smi` (Hosts without `nvidia-smi`
  can still report logged-in users and top CPU processes.)

| Platform | CLI | Web GUI (`--web`) | Desktop launcher (`--icon`) |
|----------|-----|-------------------|-----------------------------|
| Linux | yes | yes | yes, a `.desktop` entry (GNOME/KDE/XFCE terminals) |
| macOS | yes | yes | yes, a double-click `who-gpu.command` that opens Terminal |
| Windows | yes, via Git Bash | yes, via Git Bash | a `who-gpu.cmd` on the Desktop that launches Git Bash |

> **Help wanted:** The macOS `.command` has not yet been verified on real hardware.
> If you try one, please report back (or open a PR) so this note can be updated.

## Install

```bash
git clone https://github.com/lucafossen/who-gpu.git
cd who-gpu
./install.sh           # installs the `who-gpu` command
./install.sh --icon    # also adds a desktop icon
```
Uninstall with `./uninstall.sh` (add `--purge` to also drop your preferences).

You could also skip the installer entirely and run `./who-gpu.sh` directly.

Your install options are saved at `~/.config/who-gpu/config` in plain text, and is safe to edit. Re-running
the installer lets you choose again.

## Updating

```bash
who-gpu --update
```

New versions are mentioned once a day, in the terminal and as a dashboard badge. Disable by setting `UPDATE_CHECK=0`.
who-gpu never updates itself.

## Setup

Run the guided setup (also runs on first-time launch):

```bash
who-gpu --setup
```

It asks what a plain `who-gpu` should open, then scans your `~/.ssh/config`,
shows every host with its current
probe state, and lets you toggle each one on or off. Flipping a host **on** adds
a `#probe` marker, flipping it **off** removes one. Your config is backed up
(timestamped) before any change.

## Web GUI

```bash
who-gpu --web
```

Opens a dashboard in your browser straight away and fills it in as each machine
answers, then keeps running until Ctrl-C. Machines are grouped **Available**
/ **In use** / **Unreachable** (plus **Probing** while results are still coming
in); click one for a full breakdown.

Serverless and dependency-free: the webpage and data is just a file on disk that the probe loop
rewrites, which is why it works everywhere the CLI does.

Files live in `~/who-gpu-web/` and stay there after you quit, so you can reopen
the last probe (clearly marked stale).

### Connection reuse

`--web` reuses one SSH connection per host (`ControlMaster`) instead of logging
in on every refresh. Where that isn't supported (**notably Git Bash**) it falls
back to a full login per refresh and slows the refresh to 60s, unless you pinned an
interval (`WHO_GPU_INTERVAL`, `--interval`, or `INTERVAL=` in your config).

## Managing which hosts to probe

By default who-gpu reads your `~/.ssh/config` and probes every host tagged with
a `#probe` comment.

1. **`~/.ssh/config` `#probe` markers (default):**
   ```sshconfig
   Host gpu-node-1
       HostName 10.0.0.1
       User alice
       #probe
   ```
   I recommend letting `who-gpu --setup` add these for you.

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

By default who-gpu prints the compact summary (or the dashboard, with
`DEFAULT_MODE=web`) and takes hosts from `~/.ssh/config`. The flags below
change that:

| Flag | Meaning |
|------|---------|
| `--web` | Live dashboard in your browser (see [Web GUI](#web-gui)) |
| `--update` | Update to the latest version (see [Updating](#updating)) |
| `--version` | Print the installed version |
| `--setup` | Pick what plain `who-gpu` opens; toggle `#probe` markers on/off |
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

`--json` dumps the same data as JSON for scripting; it's what `--web` is
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

## Other notes

- Uses `ssh -o BatchMode=yes`. Hosts without working key auth show up as failed.
- Probes run in parallel, so one dead host won't hold up the rest.
- It reads GPU process owners via `nvidia-smi` + `ps`.

## License

[MIT](LICENSE)
