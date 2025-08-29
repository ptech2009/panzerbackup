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

---

## Usage

You can either run Panzerbackup directly into the **interactive main menu**:

```bash
./panzerbackup.sh
```

Or you can call it with specific commands:

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
```

---

## Features

- Runs online without downtime (quiescing ensures consistency).
- Designed for both **Proxmox servers** and **regular Linux desktops/servers**.
- Backup rotation with symlink `LATEST_OK`.
- Works as a "fire and forget" replacement for Clonezilla.

---

## License

MIT License – feel free to use, share, and improve.
