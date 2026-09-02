# Changelog

All notable changes to this project are documented here.

## v2.7.0 - 2026-09-02

- **Proxmox guest quiesce is now off by default.** Previous versions froze every running VM and container for the entire duration of the disk image, which on a full `dd` run means hours. Inside a frozen guest every write blocks in D state; after ~180 s the `systemd-journald` watchdog fires, journald is restarted repeatedly and the journal is corrupted. Services then lose their log socket (`Transport endpoint is not connected`) and exit — on a Proxmox Backup Server guest this stops `proxmox-backup-api`, and because it exits *cleanly* its `Restart=on-failure` never restarts it, so backups fail silently until the next reboot. A full-disk image of a live system is crash-consistent in any case, since the host's own mounted root filesystem is written into the same image while `dd` runs.
- Guest consistency belongs to `vzdump`/PBS, which freezes each VM for about a second. This tool now images the host and leaves the guests running.
- Added `--quiesce` / `PVE_QUIESCE_MODE=freeze` to restore the old behaviour deliberately.
- Added `--quiesce-max-sec N` / `PVE_QUIESCE_MAX_SEC` (default: 120) as a hard upper bound for any freeze, deliberately below journald's 180 s watchdog.
- Freezing now arms a detached watchdog (`setsid`) that thaws guests unconditionally when the cap expires. It survives `SIGKILL` of the worker, a closed console, and crashed runs — necessary because the QEMU guest agent has no freeze timeout of its own, so an interrupted run previously left guests frozen indefinitely.
- Added `--no-quiesce` for explicitness.
- Fixed the quiesce loops iterating once over an empty value when no guest was frozen or suspended, which produced calls like `qm resume ""` and log lines such as `- VM : resume`.

## v2.6.8 - 2026-08-17

- Space check now estimates the real backup size instead of demanding the full raw disk size: the source disk is sampled (default 64 x 8 MiB) and compressed with the configured zstd level to measure the actual ratio.
- Added `SPACE_ESTIMATE_MODE`, `SPACE_SAMPLE_COUNT`, `SPACE_SAMPLE_CHUNK_MIB`, and `SPACE_SAFETY_PERCENT` (default safety margin: 15 %) plus the `--no-space-estimate` flag for the previous strict behaviour.
- Added `--force-space` / `ALLOW_LOW_SPACE=1` to start a backup despite a failed space check; the stream still aborts cleanly on ENOSPC.
- Low-space aborts now explain why raw images of LUKS-encrypted disks hardly compress and list the available options.
- Kept the Linux Mint variant in sync with the main script.

## v2.6.7 - 2026-07-19

- Automatically recover empty, malformed, and orphaned backup startup locks.
- Preserve concurrent-start protection by allowing an active starter time to write its PID before stale-lock cleanup.
- Keep the Linux Mint variant in sync with the main script.

## v2.6.6 - 2026-07-19

- Removed full-image SHA256 scans from automatic cleanup, eliminating hour-long delays when `LATEST_OK` is deleted.
- Batched deletion of old backups and their metadata based on allocated size, with a free-space check after each batch.
- Clear stale `LATEST_OK` links immediately during cleanup; checksum validation remains part of explicit verify/restore operations.
- Fixed fallback backup selection so progress messages no longer corrupt the selected file path.
- Prevented concurrent backup starts and improved propagation of backup-stream failures.
- Kept the Linux Mint variant in sync with the main script.

## v2.6.5 - 2026-05-26

- Fixed manual backup cancellation so the full worker process group is stopped instead of only the top-level worker process.
- Added worker-side signal handling for INT, TERM, and HUP to terminate active `dd | zstd | gpg/tee | sha256sum` pipelines.
- Preserved the manual stop status after Proxmox VM/CT resume cleanup.
- Kept the Linux Mint variant in sync with the main script.

## v2.6.4 - 2026-05-24

- Added a dedicated changelog for release tracking.
- Documented the current project version in the README.
- Kept top-level and worker script version metadata in sync.

## v2.6.3

- Adds advanced live status display with elapsed time and persistent process tracking.
- Improves background backup workflow for SSH disconnect resilience.
- Documents restore, verification, logging, and stop workflows.
