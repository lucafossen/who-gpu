# who-gpu

A small Bash tool that SSHes into a list of machines, runs
`nvidia-smi` (and a bit of `ps`/`who`), and tells you **which machines are in
use and by which users**.

<img width="2150" height="702" alt="image" src="https://github.com/user-attachments/assets/999556ac-79d5-4755-a00b-77978368e691" />

Also includes a dependency-free web GUI.

<img width="3692" height="2156" alt="image" src="https://github.com/user-attachments/assets/14450af2-c77a-4c5f-a355-26d96d4846f2" />

## Why

If you are sharing GPU resources with others across multiple machines without a scheduling system, you often need to figure out which machines are free, and who's using them. This gives an insightful, easily readable overview of that.

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
answers, then keeps running until you Ctrl-C. Click a machine for full output (either the `who-gpu --full` view or plain `nvidia-smi`).

**List view** in the top bar swaps the cards for one row per machine
under a column header:

<img width="3558" height="1496" alt="image" src="https://github.com/user-attachments/assets/193c3384-f678-46ae-8f69-ac5ffad7aa32" />

Also featured: Grouping, sorting and all your choices remembered by the browser.

The Web GUI is *serverless and dependency-free*: the webpage and data is just a file on disk that the CLI tool
rewrites, so it works everywhere the CLI does.

Files live in `~/.local/share/who-gpu/` (or `$XDG_DATA_HOME/who-gpu/`) and
stay there after you quit, so you can reopen the last probe (clearly marked
stale).

Only one dashboard runs per output directory: a second `--web` (or a second
click on the desktop icon) exits with a message pointing at the one already
running, instead of two engines fighting over the same page.

### Connection reuse

`--web` reuses one SSH connection per host (`ControlMaster`) instead of logging
in on every refresh. Where that isn't supported (**notably Git Bash**) it falls
back to a full login per refresh and slows the refresh to 60s, unless you pinned an
interval (`WHO_GPU_INTERVAL`, `--interval`, or `INTERVAL=` in your config).

## Managing which hosts to probe

At startup, or by running `who-gpu --setup`, you will be prompted to choose which machines to probe.
To track this, who-gpu will add `#probe` comments to tag your ssh config file entries, like this:

```sshconfig
 Host gpu-node-1
     HostName 10.0.0.1
     User alice
     #probe
```

You can of course also edit this manually.
   
I you don't want to use a config file, you can use:

* **The command line** (you can use bash brace-expansion):
   ```bash
   who-gpu gpu-node-{1..8}
   who-gpu alice@192.168.10.14 192.168.10.15
   ```

* **A hosts file:** one host per line (`#` comments / blanks ignored). Pass it
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
| `-t SECS`, `--timeout SECS` | SSH connect timeout (default 8; hosts behind a jump host get four times this) |
| `-n N`, `--top N` | How many top CPU processes to show per host (default 5) |
| `-p N`, `--parallel N` | How many hosts to probe at once (default 6) |
| `-h`, `--help` | Usage |

Only one of `--summary`, `--full` or `--web` are to be used at a time.

Environment overrides: `WHO_GPU_HOSTS` (fallback hosts file path),
`WHO_GPU_SSH_CONFIG` (ssh config path), `WHO_GPU_OUT` (where `--web` writes,
default `~/.local/share/who-gpu`), `WHO_GPU_INTERVAL` (seconds between `--web` probe
cycles; unset means 10, or 60 when SSH connections can't be reused),
`WHO_GPU_NO_MUX` (set to `1` to disable `--web` SSH connection reuse).

`--json` dumps JSON for scripting; it's what `--web` is
built on.

## What it reports

- **CLI Summary mode (default):** per host: busy/total GPUs, the usernames running
  GPU processes, and who's logged in.
- **CLI Full mode (`--full`):** per host: uptime/load, logged-in users, per-GPU
  utilization and memory, each GPU process mapped to its owning username, and
  the top CPU processes.
- **Web GUI (`--web`):** one card per machine, grouped by availability, with
  busy/total GPUs, GPU users, per-GPU utilization bars, and on click the full
  breakdown plus the plain `nvidia-smi` table.

## Other notes

- Uses `ssh -o BatchMode=yes`. Hosts without working key auth show up as failed.
- Probes run in parallel, so one dead host won't hold up the rest.
- It reads GPU process owners via `nvidia-smi` + `ps`.
- If you are using this and would like to see any features or changes implemented, don't hesitate to open an issue (or a PR)!
## License

[MIT](LICENSE)
