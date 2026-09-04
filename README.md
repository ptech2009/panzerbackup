# 🛡️ Panzerbackup

**Bare-Metal-Backup für Linux und Proxmox VE — ein Backup ist eine Datei.**

Panzerbackup sichert ein laufendes System auf eine USB-Platte und stellt es im
Ernstfall mit demselben Skript von einem Linux-Live-USB auf eine leere Disk
wieder her. Kein Backup-Server, kein zusätzliches Werkzeug, kein manuelles
Entpacken.

```
Proxmox läuft  →  Backup erstellen  →  eine .pzb-Datei auf der Backup-Platte

Systemdisk defekt  →  neue Disk  →  Live-USB booten  →  Backup wiederherstellen
                   →  Datei wählen  →  Zieldisk wählen  →  Proxmox bootet wieder
```

> **Version 3.0.0 — stabiles Release.**
> Kern-Engine und LVM-Mechanik sind durch 95 automatisierte Tests plus echte
> LVM-/Thin-Pool-Tests auf Loop-Geräten abgesichert (u. a. der Nachweis, dass
> der Sparse-Restore einen Thin-Pool nicht vollständig belegt: 6 % statt 56 %).
> Wie bei jedem Disaster-Recovery-Werkzeug gilt: validiere den vollständigen
> Restore einmal in deiner Umgebung, bevor du dich darauf verlässt — die
> Anleitung dazu steht in [docs/DISASTER-RECOVERY-TEST.md](docs/DISASTER-RECOVERY-TEST.md).

---

## Zwei Betriebsarten, ein Programm

### RAW — universell

Sichert die komplette Systemdisk als Rohabbild: `dd → zstd → optional GPG`.
Funktioniert auf **jedem** Linux, unabhängig vom Dateisystem, und ist der
Fallback für alles, was PVE-DR nicht abdeckt.

Ein laufendes System liefert dabei ein absturzkonsistentes Abbild — so, als wäre
in dem Moment der Strom ausgefallen. Journaling-Dateisysteme kommen damit klar.

### PVE-DR — konsistent für Proxmox

Der eigentliche Fortschritt in Version 3. Statt stundenlang eine sich ändernde
Disk zu lesen:

```
VM kurz anhalten (Sekunden)  →  Momentaufnahme  →  VM sofort weiter
                             →  Momentaufnahme in Ruhe sichern
```

Erfasst wird der Systemdatenträger, jeder VM- und Container-Datenträger, die
Partitionstabelle, der Startbereich und die Proxmox-Konfiguration — alles in
**einer** `.pzb`-Datei.

| | RAW | PVE-DR |
|---|---|---|
| Läuft auf | jedem Linux | Proxmox VE |
| Gäste angehalten | gar nicht | Sekunden je Gast |
| Konsistenz Host | absturzkonsistent | absturzkonsistent (journalfähig) |
| Konsistenz Gäste | absturzkonsistent | Dateisystem-konsistent über den Gastagenten |
| Ergebnis | eine `.img.zst[.gpg]` | eine `.pzb` |
| Restore | Disk-Abbild zurückschreiben | Partitionen, LVM, Volumes, Startbereich |

---

## Support-Matrix

PVE-DR ist für Version 1 bewusst eng gefasst. Alles außerhalb dieser Liste führt
im Preflight zu **NICHT BEREIT** mit Verweis auf RAW — es gibt keine halbherzige
Unterstützung.

**Unterstützt**

- Proxmox VE, ein einzelner Knoten
- eine Systemdisk, GPT
- Root auf einem klassischen LVM-Volume
- Gast-Datenträger auf LVM-Thin in derselben Volume-Group
- UEFI mit `proxmox-boot-tool`, UEFI mit GRUB, UEFI mit systemd-boot, Legacy BIOS mit GRUB
- QEMU-VMs mit erreichbarem Gastagenten; gestoppte Gäste
- LXC-Container mit Datenträgern auf LVM-Thin

**Nicht unterstützt (→ RAW)**

- ZFS- oder BTRFS-Root, Root auf einer normalen Partition
- Verschlüsselung, Software-RAID oder Multipath zwischen Partition und LVM
- Volume-Group über mehrere Datenträger
- Gast-Datenträger auf NFS, CIFS, Ceph, ZFS oder Verzeichnis-Speicher
- LXC-Bind-Mounts und externe Mountpoints
- mehrere Thin-Pools
- Cluster-Knoten (Sicherung möglich, Wiederherstellung braucht Handarbeit — wird gemeldet)
- VMs mit `freeze-fs=0` (Aliase `freeze-fs-on-backup`, `guest-fsfreeze`), sofern kein
  Herunterfahren erlaubt wurde

---

## Installation

```bash
sudo mkdir -p /root/bin
sudo cp panzerbackup.sh /root/bin/panzerbackup.sh
sudo chown root:root /root/bin/panzerbackup.sh
sudo chmod 700 /root/bin/panzerbackup.sh
```

Die Backup-Platte braucht ein Dateisystem-Label, das `PANZERBACKUP` enthält.
Panzerbackup findet und mountet sie dann selbst.

**Voraussetzungen:** `bash`, `dd`, `zstd`, `sha256sum`, `sfdisk`, `lvm2`;
für Verschlüsselung `gnupg`. Auf dem Live-System für den Restore dasselbe.

---

## Bedienung

Ohne Argumente startet ein Menü. Mehr muss man nicht kennen:

```
1) Backup erstellen
2) Backup wiederherstellen
3) Backup prüfen
4) Status / Fortschritt
5) Log anzeigen

E) Erweiterte Optionen
0) Beenden
```

Auf einem Proxmox-Host fragt „Backup erstellen" nur noch, welche Art:

```
1) Proxmox Disaster-Recovery Backup
2) Klassisches RAW-Backup
3) Nur prüfen, ob Proxmox gesichert werden kann
```

Beim Wiederherstellen und Prüfen erkennt Panzerbackup selbst, ob eine Datei ein
RAW-Abbild oder ein PVE-DR-Backup ist. Nach Volume-Groups, Thin-Pools,
Mountpunkten oder Bootloadern wird nie gefragt — das wird erkannt.

### Für Automatisierung

```bash
panzerbackup.sh backup --mode pve-dr                   # sichern
panzerbackup.sh backup --mode pve-dr --dry-run         # nur prüfen, ändert nichts
panzerbackup.sh backup --mode raw --encrypt --passfile /root/.pb-pass
panzerbackup.sh verify                                 # letzte Sicherung prüfen
panzerbackup.sh restore --dry-run                      # Plan zeigen, nichts schreiben
panzerbackup.sh restore --target /dev/sdX --passfile …
panzerbackup.sh status | log | stop | diag
```

Der Rückgabewert von `--dry-run` ist `0` für bereit und `1` für nicht bereit —
brauchbar für Überwachung.

Ein automatisches Herunterfahren von Gästen passiert **nie** von selbst. Es
braucht `PVE_DR_ALLOW_SHUTDOWN=1`, und auch dann nur für Gäste, bei denen das
Anhalten der Dateisysteme abgeschaltet ist.

---

## Preflight: im Zweifel Nein

Vor jeder Proxmox-Sicherung prüft Panzerbackup das System und sagt im
Zweifelsfall ab. Ein „BEREIT" bedeutet, dass jeder Datenbereich zugeordnet
werden konnte — nicht nur, dass nichts aufgefallen ist.

```
  System:                unterstützt (Proxmox VE 9.2.11)
  Virtuelle Maschinen:   7 geprüft
  Container:             0 geprüft
  Momentaufnahme:        möglich
  Speicherpool:          ausreichend
  Backup-Ziel:           ausreichend (3,9TiB frei)

Ergebnis: NICHT BEREIT

Es wurde 1 Problem gefunden:

  - VM 105 kann nicht konsistent gesichert werden
```

Jeder Befund nennt **Grund**, **Lösung** und den technischen Hintergrund. Mit
`[D]` gibt es den vollständigen technischen Bericht.

Geprüft werden unter anderem: Proxmox-Version, Systemdisk, Partitionierung,
Startverfahren, PV/VG/Root-LV/Thin-Pool, alle Gast-Datenträger, vorhandene
Sicherungspunkte und VM-Zustandsabbilder, **unbekannte Logical Volumes**,
Gastagent, `freeze-fs`-Einstellung, Bind-Mounts, fremde Speicher,
Thin-Pool-Belegung und -Metadaten, freier Platz in der Volume-Group für die
Momentaufnahme und Platz auf dem Backup-Ziel.

---

## Verschlüsselung

Optional AES-256 über GnuPG. Die ganze `.pzb` wird als ein Strom verschlüsselt —
die Passphrase wird einmal abgefragt.

Die Passphrase erreicht `gpg` über eine Datei in `/run/panzerbackup` mit Modus
`0600` auf einem tmpfs. Sie steht **nie** in der Kommandozeile, ist damit nicht
in `ps` sichtbar und wird nirgends von einer Shell interpretiert. Sonderzeichen
funktionieren vollständig — geprüft mit Anführungszeichen, `$`, Backticks,
Kommandosubstitution, Backslash, `;`, `&&`, `!`, `#`, Tabulatoren und Umlauten.

> **Sicherheitshinweis zu Versionen bis 2.7.0:** dort wurde die Passphrase in
> einen `bash -c`-String eingesetzt. Sie war dadurch für jeden lokalen Benutzer
> in `ps auxww` lesbar, und eine Passphrase mit `` ` `` oder `$(…)` wurde
> ausgeführt. Wer eine ältere Version einsetzt, sollte aktualisieren und die
> Passphrase wechseln. Das Dateiformat ist unverändert; alte Backups bleiben
> lesbar.

---

## Sicherheitsvorkehrungen

- Live-Medium, Backup-Platte und die Disk, von der das Skript läuft, sind als
  Wiederherstellungsziel gesperrt.
- Auf ein laufendes System wird nicht zurückgeschrieben.
- Eine zu kleine Zieldisk führt zum Abbruch, **bevor** irgendetwas partitioniert wird.
- Momentaufnahmen von Panzerbackup tragen eine eindeutige LVM-Markierung.
  Aufgeräumt wird ausschließlich darüber — ein Proxmox-eigener Sicherungspunkt
  kann nicht getroffen werden.
- Ein unabhängiger Wächter gibt angehaltene Gäste auch dann frei, wenn der
  Sicherungsvorgang abstürzt oder hart beendet wird.
- Läuft der Thin-Pool oder der Momentaufnahme-Bereich voll, bricht die Sicherung
  kontrolliert ab: Gäste werden freigegeben, eigene Momentaufnahmen entfernt,
  `LATEST_OK` nicht gesetzt.
- `panzerbackup.sh diag` erzeugt einen Diagnosebericht, aus dem Kennwörter,
  Tokens, Cloud-Init-Zugangsdaten, `sshkeys` und private Schlüssel **vor** dem
  Schreiben entfernt werden. `/etc/pve/priv` wird nie gelesen.

---

## Prüfen

```bash
panzerbackup.sh verify
```

Für ein PVE-DR-Backup wird der komplette Strom gelesen und geprüft: Format,
Version, jeder Bestandteil einzeln gegen seine Prüfsumme, die Prüfsummenliste,
die angekündigte Anzahl und Gesamtgröße sowie der Abschluss.

Ein Erfolg bedeutet: **strukturell vollständig und byteweise unversehrt.**
Er bedeutet ausdrücklich nicht „startet garantiert" — das bestätigt nur ein
echter Restore-Test.

---

## Tests

```bash
./tests/run-tests.sh              # 95 Tests, ohne root, ohne echte Datenträger
./tests/run-tests.sh container    # einzelne Gruppe
sudo ./tests/requires-root/lvm-thin.sh   # echte LVM-/Thin-Pool-Tests auf Loop-Geräten
```

Der Test mit root legt eine eigene Volume-Group auf einer temporären Loop-Datei
an und fasst kein vorhandenes Gerät an. Er weist unter anderem nach, dass das
sparsame Zurückschreiben einen Thin-Pool nicht vollständig belegt.

---

## Bekannte Einschränkungen

- **Der vollständige Bare-Metal-Restore (echtes PVE sichern → auf leere Disk
  zurückspielen → booten) sollte einmal in deiner Umgebung durchlaufen werden,
  bevor du dich im Ernstfall darauf verlässt.** Die riskanteste Einzelmechanik —
  der Sparse-Thin-Restore — ist auf echtem LVM nachgewiesen; die Kette als
  Ganzes bestätigt aber erst dein eigener Restore-Test.
- Die Snapshot-Historie von Proxmox wird nicht mitgesichert. Wiederhergestellt
  wird der jeweils aktuelle Stand jedes Gastes. Beim ersten Start räumt ein
  einmaliger Dienst die verwaisten Verweise mit Proxmox' eigenen Mitteln auf.
- Die Zieldisk muss mindestens so groß sein wie die ursprüngliche. Zusätzlicher
  Platz bleibt zunächst ungenutzt.
- Ein Thin-Volume wird in voller logischer Größe **gelesen**. Nicht belegte
  Blöcke liefern Nullen und komprimieren auf fast nichts — die Sicherungsdatei
  bleibt klein, die Lesezeit richtet sich aber nach der logischen Größe.
- Gastagent-Freeze erzeugt Dateisystem-Konsistenz, nicht automatisch
  Anwendungskonsistenz. Datenbanken mit eigenen Anforderungen brauchen weiterhin
  ihr eigenes Sicherungsverfahren.
- Hardwareunterschiede beim Restore (andere Netzwerkkartennamen, anderer
  Controller) werden nicht automatisch aufgelöst.
- LXC ist vollständig implementiert, konnte aber gegen kein reales System
  geprüft werden — auf dem Referenzhost gibt es keine Container.

---

## Dokumentation

- [Das `.pzb`-Format](docs/PZB-FORMAT.md)
- [Abnahmetest für die Wiederherstellung](docs/DISASTER-RECOVERY-TEST.md)
- [CHANGELOG](CHANGELOG.md)

## Lizenz

Siehe [LICENSE](LICENSE).
