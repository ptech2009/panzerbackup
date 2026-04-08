# 🛡️ Panzerbackup

**Panzerbackup** is a disaster recovery backup script for Linux and Proxmox. It creates a **full 1:1 disk image** of your running system – comparable to Clonezilla, but fully automated and usable online (without reboot).

It is designed to make **restoring an entire system on new hardware** as fast and reliable as possible.

---

## 🌍 Language Selection

At startup, the script asks which language you prefer:

* 🇬🇧 English
* 🇩🇪 Deutsch

All menus and messages are shown in the chosen language. You can also set the language via environment variable to skip the prompt:

```bash
LANG_CHOICE=en ./panzerbackup.sh
LANG_CHOICE=de ./panzerbackup.sh
```

---

## ✨ Features and Capabilities

### ✅ **Automatic Disk Detection**
* Detects system disk (NVMe, LVM, SATA, Proxmox-root)
* Auto-detects backup target by label → any ext4 drive containing `panzerbackup` in the label (case-insensitive)
* Example labels: `panzerbackup`, `PANZERBACKUP`, `panzerbackup-pm` (for Proxmox)
* Override disk detection with `--disk /dev/XYZ` or `DISK_OVERRIDE` environment variable

### ✅ **Disk Protection**
* The script automatically blocks unsafe restore targets to prevent accidental data loss:
  * The **live USB** the script is running from
  * The **backup medium** itself
  * The **disk the script file is stored on** (script source disk)
* All three are detected automatically and marked as `[PROTECTED]` in the disk selection menu
* Attempting to restore to a protected disk results in a clear error message

### ✅ **Named Backups**
* Assign custom names to backups (e.g., `proxmox-node1`, `homeserver`)
* Default: uses hostname automatically
* Makes managing backups from multiple systems easy
* Files named as: `panzer_NAME_2025-10-04_21-03-29.img.zst.gpg`

### ✅ **Background Execution with Live Status**
* Backups run in background and survive SSH disconnections
* Uses `nohup` + `setsid` for full process isolation
* Real-time status monitoring via `./panzerbackup.sh status`
* Live progress display with automatic log updates every 2 seconds
* Worker process continues even if your terminal closes

### ✅ **Advanced Status Display**
* **Real-time progress monitoring** with automatic updates every 2 seconds
* **Elapsed time display** shown during active backup/restore operations
* **Color-coded status indicators** (in interactive terminals):
  - 🟢 Green: Successful completion
  - 🟡 Yellow: Backup/restore in progress
  - 🔴 Red: Errors or failures
* **Live log streaming** showing the last 20 lines of backup activity (configurable via `LIVE_LOG_LINES`)
* **Process information** with PID tracking
* **Persistent status tracking** survives terminal disconnection (stored in `/run/panzerbackup/status`)
* Access via interactive menu option 8 (Progress) or `./panzerbackup.sh status`

### ✅ **Systemd Integration**
* Native systemd service and timer support
* Automated scheduled backups (recommended for production)
* Integrated status display shows timer/service information
* Perfect for unattended nightly backups
* Supports `EnvironmentFile` (`/etc/panzerbackup.env`) for clean configuration

### ✅ **Compression**
* Uses `zstd` with multi-threading (`-T0`) for fast and efficient backups
* Auto mode: uses compression if `zstd` is available, falls back to raw image otherwise
* Automatic installation prompt if `zstd` is missing
* Configurable compression level via `--zstd-level N` or `ZSTD_LEVEL` (default: 6, range: 1–19)

### ✅ **Optional AES-256 GPG Encryption**
* Backups can be encrypted with a passphrase (GnuPG symmetric, AES-256)
* Interactive passphrase prompt with confirmation (typo-safe double entry)
* Can be provided via `--passfile` for automation (passphrase read from file)
* Combines seamlessly with compression: `dd | zstd | gpg`
* Restore automatically detects encrypted backups and prompts for the passphrase

### ✅ **Integrity Verification**
* SHA256 checksum is generated inline during backup
* Automatic verification after backup completes
* Symlinks (`LATEST_OK`, `LATEST_OK.sha256`, `LATEST_OK.sfdisk`) always point to the last valid backup
* Dedicated verify mode to check existing backups
* On large backups, the finalization phase can take a long time because the script may read the completed backup file again for checksum verification. During this phase, the job can appear idle even though integrity verification is still in progress.

### ✅ **Space Management**
* Checks available disk space before starting backup
* Automatically removes oldest backups if space is insufficient (`AUTO_DELETE_OLDEST=1`)
* Configurable minimum free space reserve (`MIN_FREE_BYTES`, default: 2 GB)
* Cleans up stale `.part` files from interrupted backups
* Rotation: keeps the last *n* backups (default: 3, configurable via `KEEP`)

### ✅ **Proxmox VM/CT Quiesce**
* Automatically freezes or suspends running VMs/containers
* If QEMU Guest Agent is available: uses `fsfreeze` for clean, consistent snapshots
* Falls back to suspend if QGA is not available
* Containers: uses `pct freeze/unfreeze`
* Automatic resume/unfreeze on backup completion or error

### ✅ **SSH Session Protection**
* Backups continue even if your SSH connection is lost (network drop, client shutdown)
* Uses `systemd-inhibit` to prevent system sleep/suspend during backup
* Worker runs via `nohup setsid` for full session independence

### ✅ **Restore Function**
* Restore to original disk or any alternative disk
* Interactive disk selection mode (`--select-disk`)
* Manual backup file selection via `--select-backup` (interactive list of all available backups)
* Includes **dry-run mode** (shows what would happen without writing)
* Automatic GRUB repair when restoring to the original system disk
* Skips GRUB installation when restoring to a different disk
* Restore pipeline automatically adapts to backup format (`gpg -d | zstd -d | dd` etc.)

### ✅ **Post Actions**
* After backup/restore, choose:
  * Do nothing
  * Reboot
  * Shutdown
* Can be preset via `--post reboot|shutdown|none` for automation

### ✅ **Stop Running Backup**
* Gracefully stop a running backup via menu option `S` or `./panzerbackup.sh stop`
* Sends INT → TERM → KILL signals with escalation
* Automatically resumes/unfreezes Proxmox VMs/CTs after stop

---

## 🚀 Installation & Usage

### Quick Start

```bash
git clone https://github.com/ptech2009/panzerbackup.git
cd panzerbackup
chmod +x panzerbackup.sh
sudo ./panzerbackup.sh
```

### 🖥️ Interactive Menu

When launched without arguments, the script shows a full interactive menu:

```
╔═══════════════════════════════════════════════════╗
║        ▄▅▆ Panzerbackup Manager v2.6 ▆▅▄          ║
╚═══════════════════════════════════════════════════╝

System disk: /dev/sda
Backup dir:  /mnt/panzerbackup

STATUS: Ready

1) Backup   - Start backup (auto-compression)
2) Restore  - Restore latest valid backup
3) Dry-Run  - Restore verify only (no write)
4) Backup   - Without compression
5) Backup   - With compression (zstd)
6) Restore  - With disk selection
7) Verify   - Verify latest backup (sha256)
8) Progress - Show live status
9) Log      - View log file
S) Stop     - Stop running job
0) Exit
```

During backup, you will be prompted for:
- **Backup name** (e.g., `proxmox-node1`, `homeserver`) — defaults to hostname
- **Post-action** (reboot / shutdown / none)
- **Encryption** (yes/no, with passphrase confirmation if yes)

---

## 📊 Live Status Monitoring

### Interactive Status Display

The status display provides real-time monitoring of running backups:

**Access via:**
- Menu option 8 (Progress)
- Command line: `sudo ./panzerbackup.sh status`

**Features:**
- **Real-time updates** every 2 seconds (configurable via `MENU_REFRESH_SECONDS`)
- **Elapsed time** shown as `HH:MM:SS` during active operations
- **Color-coded status** for quick visual feedback:
  - 🟢 Green: Success messages (e.g., "Backup completed successfully")
  - 🟡 Yellow: Active operations (e.g., "BACKUP: dd | zstd running...")
  - 🔴 Red: Errors or failures
- **Live log streaming** shows last 20 lines of activity (configurable via `LIVE_LOG_LINES`)
- **Process tracking** with PID information
- **Non-blocking** — exit with CTRL+C (backup continues running!)
- **Reconnect anytime** — even after SSH disconnect, status is preserved in `/run/panzerbackup/`

**Example Status Output:**
```
==========================================
    Panzerbackup - Live Status
==========================================

CTRL+C to stop viewing (backup keeps running!)

Current status: BACKUP: dd | zstd running...
Elapsed: 00:12:34
==========================================
Log (last 20 lines):
==========================================
=== 2025-12-23 14:30:15 | Starting panzer-backup...
  - VM 100: QGA ok → fsfreeze-freeze
  - VM 101: no QGA → suspend
[*] dd | zstd | tee | sha256sum …
15360+0 records in
15360+0 records out
1073741824 bytes (1.1 GB, 1.0 GiB) copied, 45.2 s, 23.7 MB/s
...
```

### Status When No Backup Is Running

If no backup is currently active:
- Shows "No backup is currently running"
- Displays last known status from `/run/panzerbackup/status`
- Press Enter to return to the menu

### Background Backup Workflow

1. **Start backup** via menu or CLI
2. **Backup runs in background** — you get your prompt back immediately
3. **Monitor progress** anytime with `./panzerbackup.sh status`
4. **Disconnect SSH** if needed — backup continues
5. **Reconnect later** and check status — all information preserved
6. **Completion notification** shown when you next check status

---

## 🤖 Command-Line Usage (Automation)

### Backup Examples

```bash
# Interactive backup with prompts
sudo ./panzerbackup.sh backup

# Named backup with compression and encryption
sudo ./panzerbackup.sh backup --name pve-node1 --compress --encrypt

# Automated backup with passphrase file
sudo ./panzerbackup.sh backup --name homeserver --compress --passfile /root/.backup-pass --post shutdown

# Set name via environment variable
BACKUP_NAME=prod-server sudo ./panzerbackup.sh backup --compress

# Start backup and monitor progress
sudo ./panzerbackup.sh backup --name server1 --compress
sudo ./panzerbackup.sh status  # Watch live progress
```

### Status Monitoring

```bash
# Watch live backup progress (updates every 2 seconds)
sudo ./panzerbackup.sh status
```

### Restore Examples

```bash
# Interactive restore (latest valid backup)
sudo ./panzerbackup.sh restore

# Dry-run (test only, no writing)
sudo ./panzerbackup.sh restore --dry-run

# Restore to specific disk
sudo ./panzerbackup.sh restore --target /dev/sdb

# Restore with interactive disk selection menu
sudo ./panzerbackup.sh restore --select-disk

# Choose which backup file to restore from
sudo ./panzerbackup.sh restore --select-backup

# Restore encrypted backup using passphrase file
sudo ./panzerbackup.sh restore --passfile /root/.backup-pass
```

### Verify

```bash
# Check integrity of latest backup
sudo ./panzerbackup.sh verify
```

### Log Viewing

```bash
# View last 100 lines of log (default)
sudo ./panzerbackup.sh log

# View specific number of lines
sudo ./panzerbackup.sh log --lines 500

# View specific log file
sudo ./panzerbackup.sh log --file /path/to/custom.log
```

### Stop Running Backup

```bash
# Gracefully stop a running backup (with confirmation prompt)
sudo ./panzerbackup.sh stop
```

### Available Flags

**Backup:**
| Flag | Description |
|---|---|
| `--name NAME` | Custom backup name (default: hostname) |
| `--compress` / `--no-compress` | Force compression on/off |
| `--zstd-level N` | Compression level 1–19 (default: 6) |
| `--encrypt` / `--no-encrypt` | Enable/disable GPG AES-256 encryption |
| `--passfile FILE` | Read passphrase from file (for automation) |
| `--post reboot\|shutdown\|none` | Action after backup |
| `--disk /dev/XYZ` | Override system disk detection |
| `--select-backup` | Show menu if multiple backup targets found |

**Restore:**
| Flag | Description |
|---|---|
| `--dry-run` | Test restore without writing |
| `--target /dev/sdX` | Restore to specific disk |
| `--select-disk` | Show interactive disk selection menu |
| `--select-backup` | Interactively choose which backup file to restore |
| `--post reboot\|shutdown\|none` | Action after restore |
| `--passfile FILE` | Read decryption passphrase from file |

---

## ⚙️ Systemd Integration (Recommended for Production)

For scheduled, robust nightly backups, systemd is the cleanest solution.

### A) Create Systemd Service

```bash
sudo tee /etc/systemd/system/panzerbackup.service >/dev/null <<'EOF'
[Unit]
Description=Panzerbackup – Automated System Backup
After=network-online.target local-fs.target
Wants=network-online.target
RequiresMountsFor=/mnt/panzerbackup-pm
ConditionPathIsExecutable=/root/bin/panzerbackup.sh

[Service]
Type=oneshot
User=root
Group=root
EnvironmentFile=-/etc/panzerbackup.env
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/bin
WorkingDirectory=/root/bin
ExecStart=/root/bin/panzerbackup.sh backup --post none
PrivateTmp=yes
NoNewPrivileges=yes
TimeoutStartSec=12h

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable panzerbackup.service

# Test run manually
sudo systemctl start panzerbackup.service

# Check status/logs
systemctl status panzerbackup.service
journalctl -u panzerbackup.service -n 100 --no-pager
```

### B) Create Systemd Timer (Daily at 02:30 ± 30 min)

```bash
sudo tee /etc/systemd/system/panzerbackup.timer >/dev/null <<'EOF'
[Unit]
Description=Panzerbackup – Daily Backup Schedule
Requires=panzerbackup.service

[Timer]
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now panzerbackup.timer
```

### Check Timer Status

```bash
# View next/last run times
systemctl list-timers panzerbackup.timer

# Check last service execution
systemctl status panzerbackup.service
journalctl -u panzerbackup.service -n 100 --no-pager
```

Even when systemd starts the job, you can monitor progress anytime:

```bash
sudo ./panzerbackup.sh status
```

Progress details are stored in `$BACKUP_DIR/panzerbackup.log` and `/run/panzerbackup/status`.

---

## ⚠️ Requirements

### Backup Target Drive
* Must be **ext4** filesystem
* Must have a **label containing** `panzerbackup` (case-insensitive)
* Examples of valid labels:
  * `panzerbackup`
  * `PANZERBACKUP`
  * `panzerbackup-pm`
  * `Panzerbackup-2024`

Label a drive with:
```bash
e2label /dev/sdX panzerbackup
```

### Required Packages
* `lsblk`, `dd`, `sha256sum`, `sfdisk`, `blockdev` — usually pre-installed
* `zstd` — for compression (auto-install prompt if missing)
* `gnupg` — for encryption (`gpg` must be available when using `--encrypt`)

The script automatically checks and guides you to install missing tools.

---

## 📁 File Structure

Backups are stored with the following naming scheme:

```
/mnt/panzerbackup/
├── panzer_pve-node1_2025-10-04_21-03-29.img.zst.gpg
├── panzer_pve-node1_2025-10-04_21-03-29.img.zst.gpg.sha256
├── panzer_pve-node1_2025-10-04_21-03-29.sfdisk
├── panzer_homeserver_2025-09-15_03-00-12.img.zst.gpg
├── panzer_homeserver_2025-09-15_03-00-12.img.zst.gpg.sha256
├── panzer_homeserver_2025-09-15_03-00-12.sfdisk
├── LATEST_OK -> panzer_pve-node1_2025-10-04_21-03-29.img.zst.gpg
├── LATEST_OK.sha256 -> panzer_pve-node1_2025-10-04_21-03-29.img.zst.gpg.sha256
├── LATEST_OK.sfdisk -> panzer_pve-node1_2025-10-04_21-03-29.sfdisk
└── panzerbackup.log
```

### File Extensions
| Extension | Description |
|---|---|
| `.img` | Raw disk image |
| `.img.zst` | zstd compressed image |
| `.img.gpg` | GPG encrypted image (no compression) |
| `.img.zst.gpg` | Compressed + encrypted image |
| `.sha256` | SHA256 checksum |
| `.sfdisk` | Partition table backup |

### Runtime Files
Located in `/run/panzerbackup/`:
| File | Description |
|---|---|
| `status` | Current operation status (last line) |
| `pid` | Worker process PID |
| `start_ts` | Unix timestamp of backup start (used for elapsed time) |
| `worker.sh` | Generated background worker script |
| `startup.log` | Worker startup messages |

---

## 🔧 Configuration

Set defaults via environment variables:

```bash
# Custom backup label
BACKUP_LABEL="my-backup-drive" ./panzerbackup.sh

# Keep more backups (default: 3)
KEEP=5 ./panzerbackup.sh backup

# Set backup name
BACKUP_NAME=production ./panzerbackup.sh backup

# Custom compression level (1-19, default: 6)
ZSTD_LEVEL=9 ./panzerbackup.sh backup --compress

# Override disk detection
DISK_OVERRIDE=/dev/sdb ./panzerbackup.sh backup

# Set language without prompt
LANG_CHOICE=en ./panzerbackup.sh

# Live status: how many log lines to show
LIVE_LOG_LINES=50 ./panzerbackup.sh status

# How often status refreshes (seconds)
MENU_REFRESH_SECONDS=5 ./panzerbackup.sh status

# Minimum free space to require before backup (bytes, default: 2 GB)
MIN_FREE_BYTES=4294967296 ./panzerbackup.sh backup

# Disable automatic deletion of old backups on low space
AUTO_DELETE_OLDEST=0 ./panzerbackup.sh backup
```

### Environment File for Systemd

Create `/etc/panzerbackup.env`:

```bash
BACKUP_LABEL=panzerbackup-pm
KEEP=5
BACKUP_NAME=proxmox-main
ZSTD_LEVEL=6
LANG_CHOICE=en
```

---

## 💡 Use Cases

### Home Lab / Proxmox
```bash
# Full backup of Proxmox host with compression and encryption
sudo ./panzerbackup.sh backup --name pve-main --compress --encrypt --post shutdown
```

### Multiple Servers on One Backup Drive
```bash
# Server 1
sudo ./panzerbackup.sh backup --name web-server --compress

# Server 2
sudo ./panzerbackup.sh backup --name db-server --compress

# All backups stored on same external drive, easily distinguishable by name
```

### Automated Backups (Systemd Timer — Recommended)
```bash
# Set up systemd service + timer as shown above
# Configure via /etc/panzerbackup.env
# Monitor with:
sudo ./panzerbackup.sh status
```

### Automated Backups (Cronjob — Legacy)
```bash
# /etc/cron.monthly/panzerbackup
#!/bin/bash
BACKUP_NAME=prod-$(hostname -s) /path/to/panzerbackup.sh backup \
  --compress \
  --passfile /root/.backup-pass \
  --post none \
  >> /var/log/panzerbackup-cron.log 2>&1
```

### Disaster Recovery from Live USB
```bash
# Boot from live USB, mount backup drive, restore
# Protected disks (live USB, backup medium) are automatically blocked
sudo ./panzerbackup.sh restore --select-disk
```

### Restore a Specific Backup
```bash
# Choose interactively which backup file to restore
sudo ./panzerbackup.sh restore --select-backup --select-disk
```

### Remote Monitoring via SSH
```bash
# Start backup on remote server
ssh root@server 'cd /root/panzerbackup && ./panzerbackup.sh backup --name prod --compress'

# Disconnect SSH — backup continues

# Reconnect later and check status
ssh root@server '/root/panzerbackup/panzerbackup.sh status'
```

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

## 🤝 Contributions & Feedback

Contributions, suggestions, or bug reports are welcome! Feel free to open an issue or pull request.

Every bit of feedback helps make Panzerbackup even more robust.

---

## 📝 Notes

* Ideal for home labs, root servers, and Proxmox environments
* Designed as a **"fire & forget" backup solution**
* Provides consistent backups even while the system is running
* Can restore to new hardware without hassle
* Backups keep running even if your SSH session is interrupted
* Named backups make managing multiple systems easy
* **Live status monitoring** shows real-time progress, elapsed time, and logs
* **Systemd integration** enables professional scheduled backups
* **Disk protection** prevents accidental overwrite of live USB, backup medium, or script source disk
* **GPG encryption** protects backups at rest with AES-256
* Colors are only shown in interactive terminals (`-t 1` check), safe for systemd/cron logs

---

**Made with ❤️ for reliable backups.**
