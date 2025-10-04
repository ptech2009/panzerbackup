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
```

During backup, you will be prompted for:
- **Backup name** (e.g., `proxmox-node1`, `homeserver`) - defaults to hostname
- **Post-action** (reboot/shutdown/none)
- **Encryption** (yes/no with passphrase)

Everything can be configured directly in the menu – no need to remember command-line flags!

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

### Automated Backups (Cronjob)
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

---

## 🆕 What's New in This Version

- **Named Backups**: Assign custom names to distinguish backups from different systems
- **Improved Menu**: Backup name prompt integrated into interactive workflow
- **Better CLI**: `--name` flag for automation
- **Enhanced Documentation**: Complete examples and use cases

---

**Made with ❤️ for system administrators who value reliability.**
