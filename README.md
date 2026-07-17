# who-gpu

A tiny, Bash tool that SSHes into a list of machines, runs
`nvidia-smi` (and a bit of `ps`/`who`), and tells you **which machines are in
use and by which usernames**.

```
$ who-gpu
Probing 9 host(s) with up to 6 in parallel...

cluster-node-1             0/1 GPUs busy   gpu:  none   logged in:  none
cluster-node-2             1/2 GPUs busy   gpu:  alice5   logged in:  none
private_server             4/4 GPUs busy   gpu:  bob2 alice5   logged in:  bob2 alice5
gpubox                     UNREACHABLE (channel 0: open failed: connect failed: No route to host)
```

## Why

On a shared GPU fleet the recurring question is "which boxes are free, and who's
hogging the busy ones?" This answers it in one command.

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

By default the installer puts a `who-gpu` command on your `PATH` (`~/.local/bin`)
and nothing else. Pass `--icon` to also add a double-click launcher for your
platform. You can also skip the installer entirely and run `./who-gpu.sh`
directly. Uninstall with `./uninstall.sh`.

### Platform support

| Platform | CLI | Desktop launcher (`--icon`) |
|----------|-----|-----------------------------|
| Linux | yes | yes, a `.desktop` entry (GNOME/KDE/XFCE terminals) |
| macOS | yes | yes, a double-click `who-gpu.command` that opens Terminal |
| Windows | yes, via WSL or Git Bash | best-effort `who-gpu.cmd` on Git Bash |

The report tool itself needs only `bash` and `ssh`, so it runs on all three.
Native Windows (cmd/PowerShell) has no bash, so use WSL or Git Bash there.

> **Help wanted:** the Linux CLI and desktop icon are tested in daily use. The
> macOS `.command` and Windows `.cmd` launchers are best-effort and have not yet
> been verified on real hardware. If you try one, please report back (or open a
> PR) so this note can be updated.

## Setup

Run the guided setup:

```bash
who-gpu --setup
```

It scans your `~/.ssh/config`, shows every host with its current probe state, and
lets you toggle each one on or off. It works both for first-time setup and for
changing things later. Flipping a host **on** adds a `#probe` marker, flipping it
**off** removes one. Your config is backed up (timestamped) before any change.

If you just run `who-gpu` with no hosts tagged yet, it offers to launch this setup
for you. You can also skip the wizard and tag hosts by hand (see below).

## Telling it which hosts to probe

By default who-gpu reads your `~/.ssh/config` and probes every host tagged with
a `#probe` comment, so `who-gpu` with no arguments works once your hosts are
tagged (via `who-gpu --setup` or by hand).

1. **`~/.ssh/config` `#probe` markers (default):** tag each host block you want
   probed with a `#probe` comment line. SSH ignores comments, so this is
   invisible to ssh itself:
   ```sshconfig
   Host gpu-node-1
       HostName 10.0.0.1
       User alice
       #probe
   ```
   Then just run `who-gpu`. (Or let `who-gpu --setup` add these for you.)

2. **On the command line** (bash brace-expansion is your friend):
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

Environment overrides: `WHO_GPU_HOSTS` (fallback hosts file path),
`WHO_GPU_SSH_CONFIG` (ssh config path).

## What it reports

- **Summary mode (default):** per host: busy/total GPUs, the usernames running
  GPU processes, and who's logged in.
- **Full mode (`--full`):** per host: uptime/load, logged-in users, per-GPU
  utilization and memory, each GPU process mapped to its owning username, and
  the top CPU processes.

## Notes & caveats

- Uses `ssh -o BatchMode=yes`. Hosts without working key auth show up as failed.
- Probes run in parallel, so one dead host won't hold up the rest.
- It reads GPU process owners via `nvidia-smi` + `ps`.

## License

[MIT](LICENSE)
