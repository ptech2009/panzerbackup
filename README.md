# 🛡️ Panzerbackup

**Panzerbackup** is a disaster recovery backup script for Linux and Proxmox.
It creates a **full 1:1 disk image** of your running system – comparable to Clonezilla, but fully automated and usable online (without reboot).

It is designed to make **restoring an entire system on new hardware** as fast and reliable as possible.

---

## 🌍 Language Selection

At startup, the script asks which language you prefer:

* 🇬🇧 English
* 🇩🇪 Deutsch

All menus and messages are shown in the chosen language.

---

## ✨ Features and Capabilities

✅ **Automatic Disk Detection**

* Detects system disk (NVMe, LVM, SATA, Proxmox-root).
* Auto-detects backup target by label → any ext4 drive containing **`panzerbackup`** in the label (case-insensitive).
  Example: `panzerbackup` or `panzerbackup-pm` (for Proxmox).

✅ **Compression**

* Uses `zstd` with multi-threading for fast and efficient backups.
* Falls back to raw image if `zstd` is not available.

✅ **Optional AES-256 GPG Encryption**

* Backups can be encrypted with a passphrase.
* Passphrase prompt with confirmation.

✅ **Integrity Verification**

* SHA256 checksum is generated for every backup.
* Automatic verification after backup.
* Symlinks (`LATEST_OK`) always point to the last valid backup.

✅ **Proxmox VM/CT Quiesce**

* Automatically freezes or suspends running VMs/containers.
* If QEMU Guest Agent is available: uses `fsfreeze` for clean, consistent snapshots.

✅ **SSH Session Protection** (NEW)

* Backups continue even if your SSH connection is lost (e.g., network drop, client shutdown).
* Uses `systemd-inhibit` + session disowning to keep jobs running until finished.

✅ **Restore Function**

* Restore to original disk or any alternative disk.
* Includes **dry-run mode** (shows what would happen without writing).
* Can skip or auto-repair GRUB bootloader depending on target disk.

✅ **Post Actions**

* After backup/restore, choose:

  * Do nothing
  * Reboot
  * Shutdown

✅ **Verification Mode**

* Menu option to re-check integrity of the latest backup.

✅ **Rotation**

* Keeps the last *n* backups (default: 3) and removes older ones automatically.

---

## 🚀 Installation & Usage

```bash
git clone https://github.com/ptech2009/panzerbackup.git
cd panzerbackup
chmod +x panzerbackup.sh
sudo ./panzerbackup.sh
```

🖥️ **Interactive Menu**

When launched, the script shows a full interactive menu:

1. Backup (auto-compression, inhibit-protection)
2. Restore latest valid backup
3. Restore (dry-run / test only)
4. Backup without compression
5. Backup with compression (zstd)
6. Restore with disk selection
7. Verify latest backup

👉 Everything can be selected directly in the menu –
compression, encryption, restore target, and post-action (shutdown/reboot).

💡 **Note**: The additional direct calls (`./panzerbackup.sh backup` or `./panzerbackup.sh restore`) are optional shortcuts for automation (e.g., cronjobs). For normal use, the menu is already sufficient.

---

## ⚠️ Requirements

* Target backup drive must be **ext4** and have a **label containing `panzerbackup`** (case-insensitive). Examples:

  * `panzerbackup`
  * `PanzerBackup`
  * `panzerbackup-pm`

* Recommended packages:

  * `zstd` (for compression)
  * `gnupg` (for encryption)

The script will automatically check and guide you to install missing tools.

---

## 📄 License

This project is licensed under the MIT License – see the LICENSE file for details.

---

## 🤝 Contributions & Feedback

Contributions, suggestions, or bug reports are welcome!
Feel free to open an issue or pull request.

💡 Every bit of feedback helps make Panzerbackup even more robust.

---

## 📝 Notes

* Ideal for home labs, root servers, and Proxmox environments.
* Designed as a **“fire & forget” backup solution**.
* Provides consistent backups even while the system is running.
* Can restore to new hardware without hassle.
* Backups stay running even if your SSH session is interrupted.
