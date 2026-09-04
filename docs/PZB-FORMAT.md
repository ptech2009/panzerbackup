# Das `.pzb`-Format

Ein PVE-DR-Backup ist **eine Datei**. Von außen ist sie genauso aufgebaut wie
ein klassisches RAW-Abbild: ein zstd-Strom, davor optional eine GPG-Hülle.

```
panzer_<name>_<zeitstempel>.pzb          =  zstd( container )
panzer_<name>_<zeitstempel>.pzb          =  gpg( zstd( container ) )   [verschlüsselt]
panzer_<name>_<zeitstempel>.pzb.sha256   =  Prüfsumme der ganzen Datei
```

Ob eine Datei verschlüsselt ist, erkennt Panzerbackup an den ersten vier Bytes
(zstd beginnt mit `28 B5 2F FD`). Der Benutzer muss nichts angeben.

## Aufbau des Containers

Alle Kopfzeilen sind reiner ASCII-Text, die Felder mit Tab getrennt. Dazwischen
liegen die Rohdaten.

```
PZB1
FORMAT<TAB>panzerbackup-pve-dr<TAB>1
<Leerzeile>

MEMBER<TAB>manifest.tsv<TAB>1842<TAB>0644
<1842 Rohbytes>
ENDMEMBER<TAB><sha256 der 1842 Bytes>

MEMBER<TAB>volumes/vol_pve__root.img<TAB>103079215104<TAB>0600
<103079215104 Rohbytes>
ENDMEMBER<TAB><sha256>

...

END<TAB><Anzahl Bestandteile><TAB><Summe aller Bytes>
```

### Warum so

| Eigenschaft | Grund |
|---|---|
| Größe steht **vor** dem Inhalt | Der Leser weiß immer, wie weit zu lesen ist. Sichern und Wiederherstellen brauchen je einen einzigen Durchlauf, keinen Index, keinen Rückwärtssprung und **keinen doppelten Speicher**. |
| Prüfsumme steht **nach** dem Inhalt | Sie ist vorher nicht bekannt. Jeder Bestandteil bleibt einzeln prüfbar. |
| `manifest.tsv` ist der **erste** Bestandteil | Der Restore kann planen, ohne die ganze Datei zu lesen. |
| `END` ist Pflicht | Eine abgebrochene Sicherung fällt sofort auf. |
| Nur `dd`, `head`, `awk`, `sha256sum` nötig | Auf einem Live-System ist nichts nachzuinstallieren. |

Kein tar: dessen Kopf verlangt die Größe **vor** dem Inhalt, was bei
komprimierten Bestandteilen eine Zwischendatei erzwungen hätte, und Volumes über
8 GiB brauchen eine GNU-Sondercodierung.

## Reihenfolge der Bestandteile

Die Reihenfolge ist Absicht: Der Restore kann Partitionen anlegen, bevor die
großen Abbilder ankommen, und muss nichts Großes zwischenspeichern.

```
 1  manifest.tsv                 der vollständige Plan
 2  manifest.json                derselbe Inhalt für Menschen und Werkzeuge
 3  disk/<disk>.sfdisk           Partitionstabelle inklusive PARTUUIDs
 4  disk/<disk>.gap.img          Sektor 0 bis Beginn der ersten Partition
 5  hardware/*                   lsblk, blkid, pvs, vgs, lvs, vgcfgbackup, ...
 6  config/etc-pve.tar           Inhalt von /etc/pve (ohne /etc/pve/priv)
    config/etc-system.tar        Netz, fstab, kernel, grub, lvm.conf, ...
 7  parts/part-N.img             jede Partition außer dem LVM-Datenträger
 8  volumes/vol_<vg>__<lv>.img   Systemdatenträger, dann alle Gast-Datenträger
 9  logs/backup.log
10  SHA256SUMS                   Prüfsummen aller vorherigen Bestandteile
```

## manifest.tsv

Zeilenweise, Tab-getrennt, erste Spalte ist der Satztyp. Mit reinem `bash` und
`awk` lesbar — **`jq` wird nicht gebraucht**, denn auf einem Live-Medium im
Katastrophenfall ist es vielleicht nicht da.

```
#panzerbackup-pve-dr	format_version=1
META	created	2026-09-03T22:00:00+02:00
META	hostname	pve
META	pve_version	9.2.11
META	encrypted	false
META	consistency	strict
BOOT	<verfahren>	<esp-gerät>	<esp-uuid>	<bios-boot-gerät>	<details>
DISK	<gerät>	<bytes>	<gpt|dos>	<sfdisk-member>	<gap-member>	<gap-bytes>
PART	<gerät>	<bytes>	<fstype>	<uuid>	<partuuid>	<member>
PVPART	<gerät>	<partitionsnummer>
VG	<name>	<größe>	<frei>	<extent-größe>
POOL	<name>	<größe>	<chunk>	<data%>	<meta%>
SWAP	<vg>	<lv>	<größe>	<uuid>
VOL	<rolle>	<vg>	<lv>	<classic|thin>	<größe>	<belegt>	<pool>	<gast>	<key>	<member>	<snapshot>
GUEST	<qemu|lxc>	<id>	<status>	<quiesce-verfahren>	<anzahl volumes>
CONFIG	config/etc-pve.tar	config/etc-system.tar
ENDMANIFEST
```

`format_version` wird bei jeder inkompatiblen Änderung erhöht. Eine ältere
Panzerbackup-Version lehnt eine neuere Datei mit einer klaren Meldung ab, statt
sie halb zu lesen.

## Von Hand auslesen

Sollte das Skript einmal nicht verfügbar sein, lässt sich der Container mit
Bordmitteln öffnen:

```bash
zstd -dc panzer_pve_2026-09-03_220000.pzb | head -c 4096 | strings | head -40
```

Die `MEMBER`-Zeilen nennen Name und Byteanzahl jedes Bestandteils; mit
`dd skip=… count=…` lässt sich jeder davon einzeln herausschneiden.
