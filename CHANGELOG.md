# Changelog

All notable changes to this project are documented here.

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
