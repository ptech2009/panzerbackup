# Abnahmetest: vollständige Wiederherstellung

Ein Backup, das nie zurückgespielt wurde, ist keine Sicherung, sondern eine
Vermutung. Dieser Test macht aus dem Release Candidate eine belastbare Aussage.

Solange er nicht bestanden ist, gilt für PVE-DR ausdrücklich **nicht**
„bootfähig garantiert" — nur „strukturell vollständig und byteweise unversehrt".

## Vorbereitung

- Ein Ziel, das **nicht** das Produktivsystem ist: ein Testserver, eine zweite
  SSD oder ein verschachteltes Proxmox in einer VM.
- Die Zieldisk muss **mindestens so groß** sein wie die ursprüngliche Systemdisk.
- Ein Linux-Mint-Live-USB.
- Die Backup-Platte mit der `.pzb`-Datei.

## Teil 1 — Sicherung auf dem laufenden Proxmox

```bash
# 1  Bereitschaft prüfen. Verändert nichts.
sudo /root/bin/panzerbackup.sh backup --mode pve-dr --dry-run

# 2  Erst wenn "BEREIT" gemeldet wird: sichern.
sudo /root/bin/panzerbackup.sh backup --mode pve-dr

# 3  Fortschritt beobachten
sudo /root/bin/panzerbackup.sh status

# 4  Ergebnis prüfen - eine einzige Datei
ls -lh /mnt/PANZERBACKUP/panzer_*.pzb
sudo /root/bin/panzerbackup.sh verify
```

**Währenddessen zu beobachten:** die VMs dürfen nur Sekunden hängen. Prüfe im
Log, wie lange zwischen „Dateisysteme angehalten" und „freigegeben" liegt:

```bash
grep -E 'angehalten|freigegeben|frozen|released' /mnt/PANZERBACKUP/panzerbackup.log
```

**Danach zu prüfen:** es darf kein Panzerbackup-Snapshot übrig sein.

```bash
sudo lvs -o vg_name,lv_name,lv_tags | grep pbdr_ || echo "sauber - keine Reste"
```

## Teil 2 — Wiederherstellung auf leere Disk

1. Zielsystem herunterfahren, Systemdisk entfernen bzw. leere Disk einbauen.
2. Linux-Mint-Live-USB booten, Backup-Platte anschließen.
3. Skript von der Backup-Platte starten:

```bash
sudo apt update && sudo apt install -y lvm2 zstd gnupg
sudo /mnt/PANZERBACKUP/panzerbackup.sh
```

4. Im Menü: **2) Backup wiederherstellen** → `.pzb` auswählen → Zieldisk
   auswählen → bestätigen.

Vorher lässt sich der Plan gefahrlos ansehen:

```bash
sudo ./panzerbackup.sh restore --dry-run --select-backup
```

## Teil 3 — Abnahme

Nach dem Neustart von der wiederhergestellten Disk der Reihe nach prüfen:

| # | Prüfung | Erwartung |
|---|---|---|
| 1 | System startet | Proxmox-Anmeldung erscheint |
| 2 | `pveversion` | dieselbe Version wie vorher |
| 3 | Weboberfläche | erreichbar |
| 4 | `ls /etc/pve/qemu-server/` | alle VM-Konfigurationen vorhanden |
| 5 | `ip a` und `ping` | Netzwerk wie vorher |
| 6 | `lvs` | Root, Swap, Thin-Pool und alle Gast-Datenträger vorhanden |
| 7 | `lvs -o data_percent pve/data` | ähnlich wie vor der Sicherung, **nicht** 100 % |
| 8 | `qm start 100` | VM startet |
| 9 | in VM 100: Dateisystem und Testdatei | unbeschädigt, Inhalt korrekt |
| 10 | alle weiteren VMs starten | laufen |
| 11 | `journalctl -u panzerbackup-firstboot` | Sicherungspunkte wurden aufgeräumt |
| 12 | `qm listsnapshot <id>` | keine verwaisten Einträge |

Punkt 7 ist der wichtigste Einzelnachweis: er belegt, dass das sparsame
Zurückschreiben funktioniert hat und der Thin-Pool nicht vollgelaufen ist.

## Testdaten vorher anlegen

Damit Punkt 9 aussagekräftig ist, vor der Sicherung in jedem Gast:

```bash
dd if=/dev/urandom of=/root/panzertest.bin bs=1M count=64
sha256sum /root/panzertest.bin > /root/panzertest.sha256
sync
```

Nach der Wiederherstellung im Gast:

```bash
sha256sum -c /root/panzertest.sha256
```

## Was zurückzumelden ist

- Ausgabe von Schritt 1 und 4 aus Teil 1
- die gemessene Anhaltedauer je VM aus dem Log
- die Tabelle aus Teil 3, Zeile für Zeile
- `lvs -o data_percent` vor der Sicherung und nach der Wiederherstellung
- alles, was unerwartet war, auch wenn es harmlos schien
