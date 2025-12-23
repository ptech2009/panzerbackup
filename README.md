# 🛡️ Panzerbackup

**Panzerbackup** is a disaster recovery backup script for Linux and Proxmox. It creates a **full 1:1 disk image** of your running system – comparable to Clonezilla, but fully automated and usable online (without reboot).

It is designed to make **restoring an entire system on new hardware** as fast and reliable as possible.

---

## 🌍 Language Selection

At startup, the script asks which language you prefer:

* 🇬🇧 English
* 🇩🇪 Deutsch

All menus and messages are shown in the chosen language.

---

## ✨ Features and Capabilities

### ✅ **Automatic Disk Detection**
* Detects system disk (NVMe, LVM, SATA, Proxmox-root)
* Auto-detects backup target by label → any ext4 drive containing `panzerbackup` in the label (case-insensitive)
* Example labels: `panzerbackup`, `PANZERBACKUP`, `panzerbackup-pm` (for Proxmox)

### ✅ **Named Backups** 🆕
* Assign custom names to backups (e.g., `proxmox-node1`, `homeserver`)
* Default: uses hostname automatically
* Makes managing backups from multiple systems easy
* Files named as: `panzer_NAME_2025-10-04_21-03-29.img.zst.gpg`

### ✅ **Background Execution with Live Status** 🆕
* Backups run in background and survive SSH disconnections
* Real-time status monitoring via `./panzerbackup.sh status`
* Live progress display with automatic log updates
* Worker process continues even if your terminal closes

### ✅ **Advanced Status Display** 🆕
* **Real-time progress monitoring** with automatic updates every 2 seconds
* **Color-coded status indicators**:
  - 🟢 Green: Successful completion
  - 🟡 Yellow: Backup/restore in progress
  - 🔴 Red: Errors or failures
* **Live log streaming** showing the last 50 lines of backup activity
* **Systemd integration display** showing timer and service status
* **Process information** with PID tracking
* **Persistent status tracking** survives terminal disconnection
* Access via interactive menu option 8 (Progress) or `./panzerbackup.sh status`

### ✅ **Systemd Integration** 🆕
* Native systemd service and timer support
* Automated scheduled backups (recommended for production)
* Integrated status display shows timer/service information
* Perfect for unattended nightly backups with auto-reboot

### ✅ **Compression**
* Uses `zstd` with multi-threading for fast and efficient backups
* Falls back to raw image if `zstd` is not available
* Automatic installation prompt if `zstd` is missing

### ✅ **Optional AES-256 GPG Encryption**
* Backups can be encrypted with a passphrase
* Passphrase prompt with confirmation
* Can be provided via `--passfile` for automation

### ✅ **Integrity Verification**
* SHA256 checksum is generated for every backup
* Automatic verification after backup
* Symlinks (`LATEST_OK`) always point to the last valid backup
* Dedicated verify mode to check existing backups

### ✅ **Proxmox VM/CT Quiesce**
* Automatically freezes or suspends running VMs/containers
* If QEMU Guest Agent is available: uses `fsfreeze` for clean, consistent snapshots
* Falls back to suspend if QGA is not available
* Containers: uses `pct freeze/unfreeze`

### ✅ **SSH Session Protection**
* Backups continue even if your SSH connection is lost (e.g., network drop, client shutdown)
* Uses `systemd-inhibit` to prevent system sleep/suspend during backup
* Session disowning keeps jobs running until finished

### ✅ **Restore Function**
* Restore to original disk or any alternative disk
* Interactive disk selection mode
* Includes **dry-run mode** (shows what would happen without writing)
* Can skip or auto-repair GRUB bootloader depending on target disk

### ✅ **Post Actions**
* After backup/restore, choose:
  * Do nothing
  * Reboot
  * Shutdown
* Can be preset via command-line flags for automation

### ✅ **Rotation**
* Keeps the last *n* backups (default: 3)
* Automatically removes older backups
* Configurable via `KEEP` variable

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
1) Backup (auto-compression, inhibit-protection)
2) Restore latest valid backup
3) Restore (dry-run / test only)
4) Backup without compression
5) Backup with compression (zstd)
6) Restore with disk selection
7) Verify latest backup
8) Show status (live progress)
9) View log file
S) Stop running job
```

During backup, you will be prompted for:
- **Backup name** (e.g., `proxmox-node1`, `homeserver`) - defaults to hostname
- **Post-action** (reboot/shutdown/none)
- **Encryption** (yes/no with passphrase)

Everything can be configured directly in the menu – no need to remember command-line flags!

---

## 📊 Live Status Monitoring

### Interactive Status Display

The status display provides real-time monitoring of running backups:

**Access via:**
- Menu option 8 (Progress)
- Command line: `sudo ./panzerbackup.sh status`

**Features:**
- **Real-time updates** every 2 seconds
- **Color-coded status** for quick visual feedback:
  - 🟢 Green: Success messages (e.g., "Backup completed successfully")
  - 🟡 Yellow: Active operations (e.g., "BACKUP: dd | zstd running...")
  - 🔴 Red: Errors or failures
- **Live log streaming** shows last 50 lines of activity
- **Process tracking** with PID information
- **Non-blocking** - exit with CTRL+C (backup continues running!)
- **Reconnect anytime** - even after SSH disconnect, status is preserved

**Example Status Output:**
```
==========================================
    Panzerbackup - Live Status
==========================================

CTRL+C to stop viewing (backup keeps running!)

Current status: BACKUP: dd | zstd running...
==========================================
Log (last 50 lines):
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

### Status When No Backup Running

If no backup is currently active:
- Shows "No backup is currently running"
- Displays last known status
- Option to return to menu

### Background Backup Workflow

1. **Start backup** via menu or CLI
2. **Backup runs in background** - you get your prompt back immediately
3. **Monitor progress** anytime with status command
4. **Disconnect SSH** if needed - backup continues
5. **Reconnect later** and check status - all information preserved
6. **Completion notification** when backup finishes

---

## 🤖 Command-Line Usage (Automation)

For scripting and automation, you can use direct commands:

### Backup Examples

```bash
# Interactive backup with prompts
sudo ./panzerbackup.sh backup

# Named backup with specific settings
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

# Check if backup is running
# Shows current status, logs, and systemd information
```

### Restore Examples

```bash
# Interactive restore
sudo ./panzerbackup.sh restore

# Dry-run (test only)
sudo ./panzerbackup.sh restore --dry-run

# Restore to specific disk
sudo ./panzerbackup.sh restore --target /dev/sdb

# Restore with disk selection menu
sudo ./panzerbackup.sh restore --select-disk
```

### Verify

```bash
# Check integrity of latest backup
sudo ./panzerbackup.sh verify
```

### Log Viewing

```bash
# View last 200 lines of log
sudo ./panzerbackup.sh log

# View specific number of lines
sudo ./panzerbackup.sh log --lines 500

# View specific log file
sudo ./panzerbackup.sh log --file /path/to/custom.log
```

### Stop Running Backup

```bash
# Gracefully stop a running backup
sudo ./panzerbackup.sh stop
```

### Available Flags

**Backup:**
- `--name NAME` - Custom backup name (default: hostname)
- `--compress` / `--no-compress` - Force compression on/off
- `--zstd-level N` - Compression level 1-19 (default: 6)
- `--encrypt` / `--no-encrypt` - Enable/disable encryption
- `--passfile FILE` - Read passphrase from file
- `--post reboot|shutdown|none` - Action after backup
- `--disk /dev/XYZ` - Override system disk detection
- `--select-backup` - Show menu if multiple backup targets found

**Restore:**
- `--dry-run` - Test restore without writing
- `--target /dev/sdX` - Restore to specific disk
- `--select-disk` - Show disk selection menu
- `--post reboot|shutdown|none` - Action after restore
- `--passfile FILE` - Read decryption passphrase from file

---

## ⚙️ Systemd Integration (Recommended for Production)

For scheduled, robust nightly backups (especially with reboots, network dependencies, or boot order requirements), systemd is the cleanest solution.

### A) Create Systemd Service

```bash
# Create/replace service unit
sudo tee /etc/systemd/system/panzerbackup.service >/dev/null <<'EOF'
[Unit]
Description=Panzerbackup – Automated System Backup
After=network-online.target local-fs.target
Wants=network-online.target
# Ensure backup target is mounted (adjust path if needed)
RequiresMountsFor=/mnt/panzerbackup-pm
# Only start if script exists and is executable
ConditionPathIsExecutable=/root/bin/panzerbackup.sh

[Service]
Type=oneshot
User=root
Group=root
# Optional: separate env file for settings (BACKUP_LABEL, KEEP, etc.)
EnvironmentFile=-/etc/panzerbackup.env
# Provide clean PATH (including /root/bin)
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/bin
# Optional: Set language to avoid prompts (script is non-interactive under systemd anyway)
# Environment=LANG_CHOICE=en
WorkingDirectory=/root/bin
ExecStart=/root/bin/panzerbackup.sh backup --post none
PrivateTmp=yes
NoNewPrivileges=yes
TimeoutStartSec=12h

[Install]
WantedBy=multi-user.target
EOF

# Reload and enable
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

### Live Status Monitoring

Even when systemd starts the job, you can always monitor progress:

```bash
sudo ./panzerbackup.sh status
```

**Important:** Detailed progress remains in the dedicated log `/mnt/panzerbackup-pm/panzerbackup.log` and status tracking `/run/panzerbackup/status`.

The `status` command shows:
- Current backup status
- Live log output (last 50 lines)
- Systemd timer/service information (if configured)
- Process information

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

### Recommended Packages
* `zstd` (for compression) - will prompt for auto-install if missing
* `gnupg` (for encryption)
* `lsblk`, `dd`, `sha256sum` (usually pre-installed)

The script will automatically check and guide you to install missing tools.

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
- `.img` - Raw disk image
- `.img.zst` - zstd compressed image
- `.img.gpg` - GPG encrypted image
- `.img.zst.gpg` - Compressed + encrypted image
- `.sha256` - SHA256 checksum
- `.sfdisk` - Partition table backup

### Runtime Files
Located in `/run/panzerbackup/`:
- `status` - Current operation status
- `pid` - Worker process PID
- `worker.sh` - Background worker script
- `startup.log` - Worker startup messages

---

## 🔧 Configuration

You can set defaults via environment variables:

```bash
# Custom backup label
BACKUP_LABEL="my-backup-drive" ./panzerbackup.sh

# Keep more backups (default: 3)
KEEP=5 ./panzerbackup.sh backup

# Set backup name
BACKUP_NAME=production ./panzerbackup.sh backup

# Custom compression level
ZSTD_LEVEL=9 ./panzerbackup.sh backup --compress

# Override disk detection
DISK_OVERRIDE=/dev/sdb ./panzerbackup.sh backup

# Set language without prompt
LANG_CHOICE=en ./panzerbackup.sh
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
# Monthly full backup of Proxmox host
sudo ./panzerbackup.sh backup --name pve-main --compress --encrypt --post shutdown
```

### Multiple Servers
```bash
# Server 1
sudo ./panzerbackup.sh backup --name web-server --compress

# Server 2
sudo ./panzerbackup.sh backup --name db-server --compress

# All backups stored on same external drive, easily distinguishable
```

### Automated Backups (Systemd Timer - Recommended)
```bash
# Set up systemd service + timer as shown above
# Configure via /etc/panzerbackup.env
# Monitor with: sudo ./panzerbackup.sh status
```

### Automated Backups (Legacy Cronjob)
```bash
# /etc/cron.monthly/panzerbackup
#!/bin/bash
BACKUP_NAME=prod-$(hostname -s) /path/to/panzerbackup.sh backup \
  --compress \
  --passfile /root/.backup-pass \
  --post none \
  >> /var/log/panzerbackup-cron.log 2>&1
```

### Disaster Recovery
```bash
# Boot from live USB, mount backup drive, restore
sudo ./panzerbackup.sh restore --select-disk
```

### Monitoring Running Backups
```bash
# Start backup in background
sudo ./panzerbackup.sh backup --name production --compress

# Monitor progress from another terminal (or after SSH reconnect)
sudo ./panzerbackup.sh status

# Exit monitoring with CTRL+C (backup continues!)
```

### Remote Monitoring via SSH
```bash
# Start backup on remote server
ssh root@server 'cd /root/panzerbackup && ./panzerbackup.sh backup --name prod --compress'

# Disconnect SSH - backup continues

# Later: Reconnect and check status
ssh root@server '/root/panzerbackup/panzerbackup.sh status'
```

---

## 📄 License

This project is licensed under the MIT License – see the [LICENSE](LICENSE) file for details.

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
* Backups stay running even if your SSH session is interrupted
* Named backups make managing multiple systems easy
* **Live status monitoring** shows real-time progress and logs
* **Systemd integration** enables professional scheduled backups

---

## 🆕 What's New in This Version

- **Named Backups**: Assign custom names to distinguish backups from different systems
- **Background Execution**: Backups run in background and survive SSH disconnections
- **Live Status Monitoring**: Real-time progress tracking with `./panzerbackup.sh status`
  - Color-coded status indicators (green/yellow/red)
  - Live log streaming (last 50 lines)
  - Process tracking with PID information
  - Persistent status across terminal sessions
- **Enhanced Log Viewing**: View logs with customizable line count via menu or CLI
- **Stop Command**: Gracefully stop running backups with `./panzerbackup.sh stop`
- **Systemd Integration**: Native service and timer support for automated scheduling
- **Enhanced Status Display**: Shows running backups, logs, and systemd information
- **Improved Robustness**: Worker process isolation and error handling
- **Better CLI**: `--name` flag for automation and environment variable support
- **Production-Ready**: Perfect for unattended operations with automatic recovery

---

## 🔄 Migration from Previous Versions

If you're upgrading from an older version:

1. **No breaking changes** - all existing backups remain compatible
2. **New status command** - use `./panzerbackup.sh status` to monitor backups
3. **New log command** - use `./panzerbackup.sh log` for quick log viewing
4. **New stop command** - use `./panzerbackup.sh stop` to gracefully stop running backups
5. **Optional systemd setup** - recommended for scheduled backups (see above)
6. **Named backups** - now prompted during interactive backup or via `--name` flag
7. **Runtime directory** - status files now in `/run/panzerbackup/` (automatically created)

---

**Made with ❤️ for system administrators who value reliability.**
