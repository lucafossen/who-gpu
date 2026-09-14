# TODO

- **Spare SD cards on Raspberry Pi kiosks.** `--web` rewrites `fleet-data.js`
  a handful of times per cycle and touches `probe-now.js` once per cycle, and
  the per-host results from `mktemp -d` land in `/tmp`, which Raspberry Pi OS
  does not mount as tmpfs. Small rewrites plus journal commits are the pattern
  that wears out SD cards. Options: default `WEB_OUT` (and `TMPDIR`) to a tmpfs
  such as `/dev/shm` or `/run/user/$UID` when one exists, or at least add a
  README note recommending `WHO_GPU_OUT=/dev/shm/who-gpu` and a longer
  `WHO_GPU_INTERVAL` for always-on Pi displays. Cost of the tmpfs default: the
  page vanishes on reboot, harmless since the loop rewrites it on start.

- **Show which users control which processes in the full view.** The
  `=== gpu processes ===` section lists user, pid, memory and process name, but
  not which GPU each process sits on: the remote snippet reads the GPU uuid
  from `--query-compute-apps` and discards it (`_uuid`). Make the full view
  (and the dashboard's Details tab, which shows the same text) map each
  process to its GPU and user, so it is clear who holds what.
