# Changelog

All notable changes to this project are documented here.

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
