# panzerbackup
Disaster Recovery Backup Script for Linux &amp; Proxmox. Automated 1:1 disk image with compression, optional GPG encryption,  integrity verification and restore support.


# Panzerbackup

A disaster recovery backup script for Linux and Proxmox.  
It creates a full 1:1 disk image of the system while running, with support for:

- **Automatic disk detection** (LVM, NVMe, SATA, Proxmox root)
- **Compression** using zstd
- **Optional AES-256 GPG encryption** with passphrase
- **Integrity verification** via SHA256 checksums
- **Automatic VM quiesce (suspend/freeze)** for Proxmox VMs/CTs
- **Easy restore** to original or alternative disks
- **Post actions** (shutdown / reboot / none)

## Usage

```bash
# Backup (auto-detect, compress if possible)
./panzerbackup.sh backup

# Backup with enforced compression
./panzerbackup.sh backup --compress

# Restore last valid backup
./panzerbackup.sh restore

# Restore with disk selection
./panzerbackup.sh restore --select-disk

# Verify latest backup
./panzerbackup.sh verify
