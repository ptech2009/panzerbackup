# Changelog

All notable changes to this project are documented here.

## v3.0.1 - 2026-09-04

A patch release for one promise version 3.0.0 made but could not keep.

- **`PVE_DR_ALLOW_SHUTDOWN=1` now reaches the shutdown path.** The preflight raised a hard finding for a VM with `freeze-fs-on-backup=0` without ever consulting the variable, and a failed preflight aborts the run long before the controlled shutdown would happen — so the documented escape hatch was unreachable. With the variable set, such a guest is now reported as a note that says what will happen to it, and the run proceeds. Without it nothing changes: the run still refuses rather than silently downgrading the guest to a crash-consistent image.
- **State images are listed under their own count** in the data area reconciliation. They were printed below "Nicht zuordenbar" / "Unattributable", which made them read as unattributable data areas — the one thing that block exists to rule out.

## v3.0.0 - 2026-09-04

**Panzerbackup 3 keeps everything that made version 2 work and changes only how the consistent state is produced.** A backup is still one file, still restored bare-metal from a Linux Mint live USB with the same script, and the RAW mode is unchanged and still the fallback for everything else.

### New: PVE-DR — a consistent Proxmox backup in one file

Instead of reading a changing disk for hours, each guest is paused for seconds, a snapshot is taken, the guest continues, and the snapshot is then read at leisure. The result is a single `panzer_<name>_<time>.pzb`.

- **Snapshot engine.** The host root is captured from a classic LVM snapshot — never with `fsfreeze /`, because `lvcreate` writes to `/etc/lvm/archive` and would deadlock the host against its own frozen filesystem. Guests are handled one at a time: freeze, snapshot every volume of that guest, thaw immediately. A running QEMU guest is frozen through the guest agent; a container through the cgroup freezer plus a host-side `fsfreeze` on each of its volumes, whose mount points are resolved from the block device rather than assumed from a path. Stopped guests need no pause at all.
- **A VM with `freeze-fs-on-backup=0` is never silently downgraded.** Either an explicitly permitted controlled shutdown is used, or the run fails. `qm suspend` is not accepted as a substitute — it stops the CPU, not the filesystems.
- **Copy-on-write and thin pool are watched throughout.** A separate monitor extends the snapshot area at 70 % and aborts at 90 %; the thin pool aborts at 90 % data or 80 % metadata. A pool running full would hit the running guests, not just the backup, so those limits are deliberately conservative. On abort the guests are released, Panzerbackup's own snapshots are removed and `LATEST_OK` is not set.
- **Snapshots are identified only by an LVM tag** unique to the run. Cleanup selects by tag, never by a name pattern, so a Proxmox snapshot can never be caught. Snapshots left behind by a crashed run are removed on the next start once their owning process is confirmed gone.
- **A watchdog in its own session** releases every paused guest unconditionally if the backup process dies, is killed, or the console closes.

### The `.pzb` container

A sequential, length-prefixed stream compressed with zstd and optionally wrapped in one GPG envelope — the same outer shape as a RAW image. Each component's size precedes its content and its checksum follows it, so backup and restore are each a single pass with no temporary copy and no doubled space, while every component stays individually verifiable. The manifest comes first so a restore can plan without reading the whole file; a mandatory end record makes a truncated file obvious. Reading needs only `dd`, `head`, `awk` and `sha256sum`. Documented in `docs/PZB-FORMAT.md`.

`manifest.tsv` is the authoritative source for restore and is parsed with plain bash — `jq` is not required, because on a live medium in an emergency it may not be there. `manifest.json` carries the same information for humans and tools.

### Restore

One menu entry restores both formats; Panzerbackup recognises which from the file. For PVE-DR it rebuilds the partition table, the boot area, the physical volume, the volume group, the root volume, swap (recreated with its original UUID rather than backed up), the thin pool, every guest volume, and the configuration — then repairs booting along the method recorded in the backup instead of running a blanket `grub-install`. A target disk smaller than the original aborts before anything is partitioned.

Thin volumes are written back skipping zero regions, so a volume that is large logically but barely used does not allocate the whole pool. Proxmox's snapshot history is not part of version 1; a one-shot first-boot service removes the dangling references using Proxmox's own commands rather than editing the configuration database from outside.

### Security fix, applies to every earlier version

The GPG passphrase was interpolated into a `bash -c` string in both the backup worker and the restore path. It was therefore visible to any local user in `ps auxww`, and a passphrase containing `` ` `` or `$(…)` was executed. It now reaches `gpg` through a root-only 0600 file on tmpfs, never through a command line and never through a shell. Verified with quotes, `$`, backticks, command substitution, backslashes, `;`, `&&`, `!`, `#`, spaces, tabs, globbing characters and non-ASCII text. The backup format is unchanged and older backups remain restorable.

Two further defects fixed along the way: the backup pipelines ran without `pipefail` inside their subshell, so an aborted `dd` produced a truncated image whose checksum matched it and the run was reported as successful; and the menu banner rendered as invalid UTF-8 because `tr` replaced each space with a single byte of a three-byte box character.

### Preflight

Refuses rather than guesses. It reports not ready for: root not on LVM, an encryption/RAID/multipath layer between partition and LVM, a volume group over several disks, guest volumes on unsupported storage, container bind mounts, a running guest on directory storage over the root volume, a VM without a reachable guest agent or with filesystem freezing disabled, a thin pool above 80 % data or 60 % metadata, too little free space for the snapshot, too little space on the backup target, an unreadable guest configuration, a Proxmox configuration filesystem that is not mounted, and any logical volume it cannot attribute. Every finding states reason, fix and technical detail; the technical report is one keypress away.

### Interface

The main menu is five entries plus advanced options. Volume groups, thin pools, mount points and bootloaders are detected, never asked about. `panzerbackup.sh diag` produces a diagnostics report with passwords, tokens, cloud-init credentials, `sshkeys` and private keys removed before anything is written.

### Tests

`tests/run-tests.sh` runs 95 checks without root and without touching any real device: container round-trips through zstd and GPG, binary payloads, corrupted and truncated files, missing end records, path traversal, unsupported format versions, zero-skip writing, twelve passphrases with special characters, eleven preflight scenarios, manifest parsing, restore planning, RAW regressions and a full backup run against simulated volumes. `tests/requires-root/lvm-thin.sh` covers the real LVM mechanisms on loop devices, including the proof that restoring a sparse thin volume does not allocate the pool.

**Validation status.** The riskiest single mechanic — writing a sparse thin volume back without allocating the whole pool — is now proven on real LVM: a 1 GiB thin volume restored into a 2 GiB pool leaves it at 6 % instead of 56 % (`tests/requires-root/lvm-thin.sh`, 24/24). Classic snapshots, copy-on-write growth and tag-only cleanup are covered by the same test. As with any disaster-recovery tool, run the full end-to-end restore once in your own environment before relying on it — see `docs/DISASTER-RECOVERY-TEST.md`.

## v2.8.0-dev - 2026-09-03

**Security fix (affects every previous version):** the GPG passphrase was interpolated into a `bash -c` command string in both the backup worker and the restore path. It therefore appeared in the process argument vector, and `/proc/<pid>/cmdline` is world-readable by default — any local user could read the passphrase with `ps auxww` while a backup or restore was running. The same interpolation was a shell-injection vector: a passphrase containing `` ` ``, `$(...)` or `"` broke out of the command string and executed. The passphrase is now handed over through a root-only 0600 file in `/run/panzerbackup` (tmpfs) via `gpg --passphrase-file`, and is removed on completion, on abort, on SIGINT/SIGTERM/SIGHUP and by `stop`. No passphrase is passed through argv or through the worker's environment any more. Verified with passphrases containing quotes, `$`, backticks, command substitution, backslashes, `;`, `&&`, `!`, `#`, spaces, tabs, globbing characters and non-ASCII text.
- Backup and restore file formats are unchanged; backups written by earlier versions restore exactly as before.
- The backup stream pipelines now set `pipefail` inside their subshell. They previously did not, so a failing `dd` or `zstd` mid-stream produced a truncated image whose checksum matched it — the run was reported as successful.
- All remaining paths and file names were moved out of the interpolated command strings into positional parameters, so a path containing a quote can no longer break or inject into the pipeline.

**New: Proxmox disaster recovery (PVE-DR), experimental.** This release adds only the read-only readiness check — the first step of a larger disaster recovery mode. It creates no snapshots, freezes no guest, changes no LVM object and writes to no block device.
- `backup --mode raw|pve-dr` selects the backup engine; `raw` stays the default and is unchanged.
- `backup --mode pve-dr --dry-run` runs the readiness check. Exit code 0 = ready, 1 = not ready.
- `backup --mode pve-dr` without `--dry-run` is refused with a pointer to the check — the mode is not usable for real backups yet.
- The check detects the Proxmox version, system disk, partition table, boot method (proxmox-boot-tool, UEFI+GRUB, UEFI+systemd-boot, legacy BIOS), volume group, root LV, swap LV, thin pool, the storage configuration, and every VM and container with its volumes. Nothing is hard-coded; layouts that are not fully understood produce a failure rather than a guess.
- Reported as not ready: root not on an LVM volume, a volume group spanning several disks, guest volumes on unsupported storage, LXC bind mounts, a running guest whose disk sits on a directory storage over the root LV, a running VM without a reachable QEMU guest agent, a thin pool above 80 % data or 60 % metadata, insufficient free space in the volume group for the root snapshot, and insufficient space on the backup target.
- Every finding states the reason, a concrete fix, and the underlying technical detail.
- The host root filesystem is deliberately never frozen: `lvcreate` writes to `/etc/lvm/archive`, so `fsfreeze -f /` followed by a snapshot deadlocks the host. The root snapshot relies on the device-mapper suspend instead and is documented as crash-consistent with journal replay.
- Space estimation is separate from the RAW one: thin volumes are read at their full logical size and only their allocated part is counted towards the written size. The report states both figures, so no time saving is implied that does not exist.

**Detection hardened against a real LVM-on-LUKS system.** The readiness check was tested against a real volume group with a LUKS layer between partition and physical volume, which exposed two defects in it:
- `lsblk -rno PKNAME` returns nothing for device-mapper devices (LVM, LUKS), so the walk from the physical volume up to the disk stopped at the first such layer and the system disk was never identified. It now uses the inverse device tree (`lsblk -s`), the method `detect_system_disk` already relied on — verified to traverse LVM → LUKS → partition → disk.
- That same tree also makes an encryption, RAID or multipath layer between the physical volume and the disk visible. Such a layout is now reported as not ready, because the restore cannot rebuild that layer; the classic RAW backup covers it instead.
- Container volumes are located by resolving the block device to its host mount point (`findmnt --source`, verified to resolve `/dev/<vg>/<lv>`, `/dev/mapper/…` and `/dev/dm-N` alike), with a name-independent fallback comparing device numbers against `/proc/self/mountinfo`. No path like `/var/lib/lxc/<id>/rootfs` is assumed. Every container volume is checked, not only the root filesystem.
- The EFI partition is located by its GPT type GUID and its mount point resolved, instead of assuming `/boot/efi`. Multiple EFI partitions are reported. "Mounted but unreadable" is now distinguished from "not mounted".
- Proxmox detection and the version no longer depend on a running service: the package database (`dpkg-query`) answers even when `pvedaemon` or `pmxcfs` are down, with `pveversion` as a fallback.
- If the Proxmox configuration filesystem is not mounted, that is now reported explicitly — previously the check would have seen zero guests and said nothing.
- A guest whose configuration cannot be read is reported. Previously it silently counted as having no disks.
- The check refuses to run without root instead of producing an incomplete picture.
- Storage paths from `storage.cfg` are probed with a timeout, so a dead network share cannot hang the check.

**Validated against a real Proxmox VE 9.2.11 host** (7 VMs, no containers, VG `pve` with a 816 GiB thin pool and 16 GiB free) through its API. Two defects in the readiness check surfaced that fixtures had not:
- **A VM configured with `freeze-fs-on-backup=0` was reported as consistently backupable.** The guest agent answers, so the check passed it — but the operator has explicitly forbidden pausing that guest's filesystems, usually because the guest does not tolerate it. Backing it up as if it were quiesced would have been exactly the silent downgrade the strict mode exists to prevent. Such a VM is now reported as not ready, with both options named.
- **Volumes were enumerated from the guest configurations only, which misses about a third of what is in the pool.** The real host holds 15 guest disks, 12 LVM restore points and 6 VM state images (85 GiB) that no current configuration references. A backup built on the configuration alone would have silently omitted them. The volume list is now taken from LVM itself and every logical volume must be attributable — to the host, to a guest, to a restore point, or to the storage inventory. Anything left over makes the check fail rather than pass with a gap.
- Existing guest restore points are reported: the backup captures each guest's current state, and the restore points themselves will not survive a restore. That is stated instead of silently dropped.

**New: `diag` — a diagnostics report that is safe to send.** `panzerbackup.sh diag`, or "Advanced options → Export diagnostics report", collects the storage layout, guest configurations, boot setup and the readiness report into one 0600 file. Passwords, tokens, cloud-init credentials, `sshkeys` and private key blocks are removed before anything is written, in both the `key: value` and the `key value` notations that Proxmox uses; `/etc/pve/priv` is never read. Nobody has to review the file by hand before sharing it.

**Simplified interface.** The main menu is down to five entries (create, restore, check, status, log) plus advanced options. On a Proxmox host, "create backup" offers the readiness check and the classic RAW backup with a one-line explanation each; everywhere else it starts the RAW backup directly. Restore dry-run, disk selection, backup selection, stopping a job and releasing frozen guests moved to "Advanced options". "Stop" appears in the main menu only while a job is running.
- Fixed the menu banner: `tr ' ' '═'` replaced each space with a single byte of the three-byte box character, so the frame rendered as invalid UTF-8. The width is now measured in characters instead of bytes.
- Added `BACKUP_DIR_OVERRIDE` to skip backup-target auto-detection.

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
