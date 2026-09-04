#!/usr/bin/env bash
# Praxistest der LVM-Mechanismen, auf denen PVE-DR beruht.
#
#   sudo ./tests/requires-root/lvm-thin.sh
#
# Arbeitet ausschließlich auf zwei Loop-Dateien in einem temporären Verzeichnis
# und einer eigens angelegten Volume-Group mit eindeutigem Namen. Es wird kein
# vorhandenes Gerät, kein vorhandenes LV und keine vorhandene VG angefasst.
# Am Ende wird alles wieder abgeräumt.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"

(( EUID == 0 )) || { echo "Dieser Test braucht root: sudo $0" >&2; exit 2; }
for c in losetup lvcreate lvremove lvs vgcreate vgremove pvcreate pvremove blkdiscard; do
  command -v "$c" >/dev/null 2>&1 || { echo "Fehlt: $c (apt install lvm2)" >&2; exit 2; }
done

VG="pbtest$$"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pb-lvm.XXXXXX")"
LOOP=""
cleanup() {
  echo; echo "Räume auf ..."
  lvremove -f "$VG" >/dev/null 2>&1 || true
  vgremove -f "$VG" >/dev/null 2>&1 || true
  [[ -n "$LOOP" ]] && { pvremove -ff -y "$LOOP" >/dev/null 2>&1 || true; losetup -d "$LOOP" >/dev/null 2>&1 || true; }
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== Aufbau der Testumgebung =="
truncate -s 4G "$WORK/disk.img"
LOOP="$(losetup --find --show "$WORK/disk.img")" || { echo "losetup fehlgeschlagen"; exit 2; }
assert_ok "Loop-Gerät angelegt ($LOOP)" test -b "$LOOP"
assert_ok "physisches Volume angelegt"  pvcreate -ff -y "$LOOP"
assert_ok "Volume-Group $VG angelegt"   vgcreate "$VG" "$LOOP"

echo; echo "== Klassischer Snapshot und COW-Verhalten =="
assert_ok "klassisches LV angelegt"     lvcreate -y -L 1G -n root "$VG"
mkfs.ext4 -q -F "/dev/$VG/root" >/dev/null 2>&1
mkdir -p "$WORK/mnt" && mount "/dev/$VG/root" "$WORK/mnt"
dd if=/dev/urandom of="$WORK/mnt/before.bin" bs=1M count=64 status=none; sync
SHA_BEFORE="$(sha256sum "$WORK/mnt/before.bin" | cut -d' ' -f1)"

assert_ok "Snapshot mit Tag angelegt" \
  lvcreate --snapshot --name pbdr_test_root --size 512M --addtag pbdr_run_testtag "$VG/root"
assert_eq "Snapshot trägt den Tag" \
  "$(lvs --noheadings -o lv_name --select 'lv_tags=pbdr_run_testtag' "$VG" | tr -d ' ')" "pbdr_test_root"

# Schreiben auf dem Original darf den Snapshot nicht verändern - das ist der
# Kern des Verfahrens: der Gast läuft weiter, gesichert wird der alte Stand.
dd if=/dev/urandom of="$WORK/mnt/after.bin" bs=1M count=128 status=none
rm -f "$WORK/mnt/before.bin"; sync
mkdir -p "$WORK/snap" && mount -o ro "/dev/$VG/pbdr_test_root" "$WORK/snap" 2>/dev/null
if [[ -f "$WORK/snap/before.bin" ]]; then
  assert_eq "Snapshot zeigt den Stand von vorher" \
    "$(sha256sum "$WORK/snap/before.bin" | cut -d' ' -f1)" "$SHA_BEFORE"
  assert_nok "spätere Änderung ist nicht im Snapshot" test -f "$WORK/snap/after.bin"
else
  bad "Snapshot zeigt den Stand von vorher" "Snapshot nicht lesbar"
fi
cow="$(lvs --noheadings -o data_percent "$VG/pbdr_test_root" | tr -d ' ')"
echo "     COW-Belegung nach 128 MiB Schreiblast: ${cow} %"
assert_ok "COW-Belegung ist messbar" bash -c "[[ '$cow' =~ ^[0-9] ]]"

# Erweitern im laufenden Betrieb - die Reaktion des Monitors auf 70 %
before_size="$(lvs --noheadings --units b --nosuffix -o lv_size "$VG/pbdr_test_root" | tr -d ' ')"
assert_ok "Snapshot lässt sich online erweitern" lvextend -L +128M "$VG/pbdr_test_root"
after_size="$(lvs --noheadings --units b --nosuffix -o lv_size "$VG/pbdr_test_root" | tr -d ' ')"
assert_ok "Snapshot ist danach größer" bash -c "(( $after_size > $before_size ))"

umount "$WORK/snap" 2>/dev/null || true
umount "$WORK/mnt"  2>/dev/null || true

echo; echo "== Cleanup nur über den Tag =="
lvcreate -y -L 64M -n fremder_snapshot_nicht_anfassen "$VG" >/dev/null 2>&1
removed=0
while read -r vg lv; do
  [[ -n "$lv" ]] && { lvremove -f "$vg/$lv" >/dev/null 2>&1 && removed=$((removed+1)); }
done < <(lvs --noheadings -o vg_name,lv_name --select 'lv_tags=pbdr_run_testtag' 2>/dev/null | awk 'NF>=2{print $1" "$2}')
assert_eq  "genau ein getaggter Snapshot entfernt" "$removed" "1"
assert_ok  "fremdes LV wurde NICHT angefasst" lvs "$VG/fremder_snapshot_nicht_anfassen"
lvremove -f "$VG/fremder_snapshot_nicht_anfassen" >/dev/null 2>&1

echo; echo "== Thin-Pool, Thin-Snapshot und sparsames Zurückschreiben =="
modprobe dm_thin_pool >/dev/null 2>&1 || true
if ! lvcreate -y --type thin-pool -L 2G -n pool "$VG" >/dev/null 2>&1; then
  skip "Thin-Pool-Tests" "Thin-Pool konnte nicht angelegt werden (dm_thin_pool / thin-provisioning-tools?)"
else
  ok "Thin-Pool angelegt"
  assert_ok "Thin-Volume (1 GiB logisch) angelegt" lvcreate -y -V 1G --thinpool pool -n thinvol "$VG"
  p0="$(lvs --noheadings -o data_percent "$VG/pool" | tr -d ' ')"
  echo "     Pool-Belegung frisch: ${p0} %"

  # 64 MiB Nutzdaten am Anfang, danach 960 MiB Nullen - genau der Fall, der beim
  # Zurückschreiben einen Thin-Pool sprengen würde.
  dd if=/dev/urandom of="/dev/$VG/thinvol" bs=1M count=64 conv=fsync status=none
  p1="$(lvs --noheadings -o data_percent "$VG/pool" | tr -d ' ')"
  echo "     Pool-Belegung nach 64 MiB Nutzdaten: ${p1} %"
  dd if="/dev/$VG/thinvol" of="$WORK/thin.img" bs=1M status=none
  SRC_SHA="$(sha256sum "$WORK/thin.img" | cut -d' ' -f1)"
  assert_eq "Abbild hat die volle logische Größe" "$(stat -c%s "$WORK/thin.img")" "$((1024*1024*1024))"

  assert_ok "Snapshot des Thin-Volumes" lvcreate --snapshot --name pbdr_test_thin --addtag pbdr_run_testtag "$VG/thinvol"
  assert_ok "Thin-Snapshot aktivierbar (-K)" lvchange -ay -K "$VG/pbdr_test_thin"
  assert_ok "Thin-Snapshot lesbar" dd if="/dev/$VG/pbdr_test_thin" of=/dev/null bs=1M count=64 status=none
  lvremove -f "$VG/pbdr_test_thin" >/dev/null 2>&1

  # Der entscheidende Nachweis: Zurückschreiben darf die Nullbereiche nicht belegen.
  assert_ok "Ziel-Thin-Volume angelegt" lvcreate -y -V 1G --thinpool pool -n restored "$VG"
  blkdiscard "/dev/$VG/restored" >/dev/null 2>&1 || true
  pA="$(lvs --noheadings --units b --nosuffix -o data_percent "$VG/pool" | tr -d ' ')"
  dd if="$WORK/thin.img" of="/dev/$VG/restored" bs=1M conv=sparse,fsync status=none
  pB="$(lvs --noheadings -o data_percent "$VG/pool" | tr -d ' ')"
  echo "     Pool-Belegung vor dem Restore:  ${pA} %"
  echo "     Pool-Belegung nach dem Restore: ${pB} %"
  DST_SHA="$(dd if="/dev/$VG/restored" bs=1M status=none | sha256sum | cut -d' ' -f1)"
  assert_eq "zurückgeschriebene Daten sind identisch" "$DST_SHA" "$SRC_SHA"
  # 1 GiB logisch in einem 2-GiB-Pool wären 50 %; mit Sparse bleiben es ~3 %.
  if awk -v a="$pB" 'BEGIN{exit !(a+0 < 20)}'; then
    ok "Nullbereiche belegen den Pool NICHT (${pB} % statt ~50 %)"
  else
    bad "Nullbereiche belegen den Pool nicht" "Pool bei ${pB} % - conv=sparse hat nicht gewirkt"
  fi

  # Gegenprobe ohne conv=sparse
  assert_ok "Vergleichs-Thin-Volume angelegt" lvcreate -y -V 1G --thinpool pool -n plainwrite "$VG"
  blkdiscard "/dev/$VG/plainwrite" >/dev/null 2>&1 || true
  dd if="$WORK/thin.img" of="/dev/$VG/plainwrite" bs=1M conv=fsync status=none 2>/dev/null || true
  pC="$(lvs --noheadings -o data_percent "$VG/pool" | tr -d ' ')"
  echo "     Pool-Belegung nach dem Schreiben OHNE sparse: ${pC} %"
  if awk -v a="$pC" -v b="$pB" 'BEGIN{exit !((a+0) > (b+0)+10)}'; then
    ok "ohne conv=sparse würde der Pool deutlich stärker belegt"
  else
    bad "Gegenprobe ohne conv=sparse" "kein messbarer Unterschied (${pC} % gegen ${pB} %)"
  fi
  lvremove -f "$VG/plainwrite" "$VG/restored" "$VG/thinvol" >/dev/null 2>&1 || true
fi

summary
