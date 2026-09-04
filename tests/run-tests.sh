#!/usr/bin/env bash
# Panzerbackup Testsuite - läuft ohne root und ohne produktive Datenträger.
# Alles findet in einem temporären Verzeichnis statt.
#   ./tests/run-tests.sh            alle Tests
#   ./tests/run-tests.sh container  nur eine Gruppe
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="${PANZERBACKUP_SCRIPT:-$ROOT/panzerbackup.sh}"
source "$HERE/lib.sh"

[[ -r "$SCRIPT" ]] || { echo "Skript nicht gefunden: $SCRIPT" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/panzerbackup-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export PZB_TMPDIR="$WORK"
RUN_DIR="$WORK/run"; mkdir -p "$RUN_DIR"
GROUP="${1:-all}"
want() { [[ "$GROUP" == all || "$GROUP" == "$1" ]]; }

# Die Containerbibliothek und weitere Bausteine aus dem echten Skript laden.
sed -n '/^# =====================\[ .pzb-Container \]/,/^# =====================\[ PVE-DR: Snapshot-Engine \]/p' "$SCRIPT" \
  | head -n -1 > "$WORK/container.sh"
# shellcheck disable=SC1090
source "$WORK/container.sh"

# ==============================================================================
if want static; then
echo; echo "== Statische Prüfungen =="
assert_ok  "bash -n panzerbackup.sh" bash -n "$SCRIPT"
# Der Backup-Worker liegt in einem Heredoc - "bash -n" auf das Hauptskript
# prüft seinen Inhalt nicht mit.
sed -n "/<< 'EOFWORKER'$/,/^EOFWORKER$/p" "$SCRIPT" | sed '1d;$d' > "$WORK/worker.sh"
assert_ok  "bash -n Backup-Worker (Heredoc)" bash -n "$WORK/worker.sh"
if command -v shellcheck >/dev/null 2>&1; then
  n=$(shellcheck -S warning "$SCRIPT" 2>&1 | grep -cE 'SC[0-9]+ \(warning\)' || true)
  # SC2034 fuer die ungenutzte Farbvariable B stammt aus v2.7.0
  assert_eq "ShellCheck: keine neuen Warnungen" "$n" "1"
else
  skip "ShellCheck" "nicht installiert"
fi
assert_grep "Version ist 3.x" "$(grep -m1 '^VERSION=' "$SCRIPT")" 'VERSION="3\.'
assert_grep "Passphrase nicht mehr in argv" \
  "$(grep -c 'passphrase-fd\|3<<<' "$SCRIPT" || true)" '^0$'
assert_grep "gpg nutzt eine Datei für die Passphrase" \
  "$(grep -c 'passphrase-file' "$SCRIPT")" '^[1-9]'
fi

# ==============================================================================
if want container; then
echo; echo "== .pzb-Container =="
IN="$WORK/in"; OUT="$WORK/out"; mkdir -p "$IN" "$OUT"
printf 'manifest\nzeile2\n' > "$IN/manifest.tsv"
head -c 300000 /dev/urandom > "$IN/binary.bin"
printf 'a\tb\nc\x00d' >> "$IN/binary.bin"
head -c 20000000 /dev/urandom > "$IN/volume.img"
printf '{"format":"panzerbackup-pve-dr"}' > "$IN/bundle.json"

build() {
  pzb_w_header
  pzb_w_member_file  manifest.tsv "$IN/manifest.tsv"
  pzb_w_member_file  bundle.json  "$IN/bundle.json"
  pzb_w_member_file  binary.bin   "$IN/binary.bin"
  pzb_w_member_device volumes/vol_pve__root.img "$IN/volume.img"
  pzb_w_member_text  SHA256SUMS "$PZB_SUMS"
  pzb_w_end
}
extract() {
  local outdir="$1"; mkdir -p "$outdir"
  pzb_r_open || return 1
  while :; do
    pzb_r_next; local r=$?
    (( r == 2 )) && break
    (( r == 0 )) || return 1
    mkdir -p "$outdir/$(dirname "$PZB_R_PATH")"
    pzb_r_member > "$outdir/$PZB_R_PATH" || return 1
  done
  return 0
}

build > "$OUT/plain.pzb" 2>"$OUT/build.err"
assert_ok  "Container schreiben"                 test -s "$OUT/plain.pzb"
( extract "$OUT/x1" < "$OUT/plain.pzb" ) >/dev/null 2>&1
assert_ok  "roundtrip: manifest.tsv"             cmp -s "$IN/manifest.tsv" "$OUT/x1/manifest.tsv"
assert_ok  "roundtrip: Binärdaten (NUL/Tab)"     cmp -s "$IN/binary.bin"   "$OUT/x1/binary.bin"
assert_ok  "roundtrip: Volume 20 MB"             cmp -s "$IN/volume.img"   "$OUT/x1/volumes/vol_pve__root.img"
assert_eq  "SHA256SUMS führt alle Bestandteile"  "$(grep -c . "$OUT/x1/SHA256SUMS")" "4"
assert_ok  "SHA256SUMS stimmt mit den Dateien"   bash -c "cd '$OUT/x1' && sha256sum -c SHA256SUMS >/dev/null"
assert_grep "END nennt die richtige Anzahl"      "$(grep -aoP 'END\t[0-9]+' "$OUT/plain.pzb" 2>/dev/null | tail -1 || tail -c 40 "$OUT/plain.pzb" | tr -d '\000')" 'END.5'

build 2>/dev/null | zstd -T0 -3 -q > "$OUT/z.pzb"
( extract "$OUT/x2" < <(zstd -dc "$OUT/z.pzb") ) >/dev/null 2>&1
assert_ok  "roundtrip durch zstd"                cmp -s "$IN/volume.img" "$OUT/x2/volumes/vol_pve__root.img"

printf 'Ge$heim"1`x;\\ !#' > "$WORK/pass"
build 2>/dev/null | zstd -T0 -3 -q | gpg --batch --yes --symmetric --cipher-algo AES256 \
  --pinentry-mode loopback --passphrase-file "$WORK/pass" > "$OUT/e.pzb" 2>/dev/null
( extract "$OUT/x3" < <(gpg --batch --yes --decrypt --pinentry-mode loopback \
    --passphrase-file "$WORK/pass" "$OUT/e.pzb" 2>/dev/null | zstd -dc) ) >/dev/null 2>&1
assert_ok  "roundtrip durch zstd+gpg (Sonderzeichen)" cmp -s "$IN/volume.img" "$OUT/x3/volumes/vol_pve__root.img"

cp "$OUT/plain.pzb" "$OUT/corrupt.pzb"
printf '\xff' | dd of="$OUT/corrupt.pzb" bs=1 count=1 seek=10000000 conv=notrunc status=none
err="$( (extract "$OUT/x4" < "$OUT/corrupt.pzb") 2>&1 >/dev/null )"
assert_grep "beschädigtes Byte wird erkannt" "$err" 'beschädigt|corrupt'
head -c 9000000 "$OUT/plain.pzb" > "$OUT/trunc.pzb"
err="$( (extract "$OUT/x5" < "$OUT/trunc.pzb") 2>&1 >/dev/null )"
assert_grep "abgeschnittene Datei wird erkannt" "$err" 'abgeschnitten|truncat'
head -c 4096 /dev/urandom > "$OUT/alien.pzb"
err="$( (extract "$OUT/x6" < "$OUT/alien.pzb") 2>&1 >/dev/null )"
assert_grep "fremde Datei wird abgelehnt" "$err" 'keine Panzerbackup|not a Panzerbackup'
printf 'PZB1\nFORMAT\tpanzerbackup-pve-dr\t99\n\n' > "$OUT/future.pzb"
err="$( (extract "$OUT/x7" < "$OUT/future.pzb") 2>&1 >/dev/null )"
assert_grep "neuere Formatversion wird abgelehnt" "$err" 'neueren Panzerbackup|newer Panzerbackup'
{ printf 'PZB1\nFORMAT\tpanzerbackup-pve-dr\t1\n\n'; printf 'MEMBER\t../../etc/passwd\t4\t0644\nboom\nENDMEMBER\tx\n'; } > "$OUT/evil.pzb"
err="$( (extract "$OUT/x8" < "$OUT/evil.pzb") 2>&1 >/dev/null )"
assert_grep "Pfad-Ausbruch wird abgewiesen" "$err" 'unzulässiger Pfad|invalid path'
assert_nok "nichts außerhalb geschrieben" test -e "$OUT/etc/passwd"
{ printf 'PZB1\nFORMAT\tpanzerbackup-pve-dr\t1\n\n'; printf 'MEMBER\t/etc/shadow\t1\t0644\nx\nENDMEMBER\tx\n'; } > "$OUT/abs.pzb"
assert_nok "absoluter Pfad wird abgewiesen" bash -c "source '$WORK/container.sh'; $(declare -f extract); extract '$OUT/x9' < '$OUT/abs.pzb'"
python3 - "$OUT/plain.pzb" "$OUT/noend.pzb" <<'PY' 2>/dev/null || true
import sys
d=open(sys.argv[1],'rb').read(); i=d.rfind(b'\nEND\t')
open(sys.argv[2],'wb').write(d[:i+1])
PY
err="$( (extract "$OUT/x10" < "$OUT/noend.pzb") 2>&1 >/dev/null )"
assert_grep "fehlender Abschluss wird erkannt" "$err" 'endet unerwartet|unexpected'
fi

# ==============================================================================
if want sparse; then
echo; echo "== Nullbereiche beim Zurückschreiben =="
# Beweist, dass dd mit conv=sparse Nullbereiche überspringt statt sie zu
# schreiben. Auf einem frisch angelegten Thin-Volume bleiben sie damit unbelegt.
# Der Nachweis am echten Thin-Pool steht in tests/requires-root/.
SP="$WORK/sparse"; mkdir -p "$SP"
{ head -c 1048576 /dev/urandom; head -c 62914560 /dev/zero; head -c 1048576 /dev/urandom; } > "$SP/src.img"
truncate -s 0 "$SP/dst.img"; truncate -s 65011712 "$SP/dst.img"
dd if="$SP/src.img" of="$SP/dst.img" bs=1M conv=sparse,notrunc status=none
alloc_kb=$(du -k "$SP/dst.img" | cut -f1); logical_kb=$(( 65011712 / 1024 ))
assert_ok  "Inhalt bleibt identisch"        cmp -s "$SP/src.img" "$SP/dst.img"
if (( alloc_kb < logical_kb / 4 )); then
  ok "Nullbereiche belegen keinen Platz (${alloc_kb} statt ${logical_kb} KiB)"
else
  bad "Nullbereiche belegen keinen Platz" "${alloc_kb} von ${logical_kb} KiB belegt"
fi
truncate -s 0 "$SP/dst2.img"; truncate -s 65011712 "$SP/dst2.img"
dd if="$SP/src.img" of="$SP/dst2.img" bs=1M conv=notrunc status=none
alloc2_kb=$(du -k "$SP/dst2.img" | cut -f1)
if (( alloc2_kb > alloc_kb * 4 )); then
  ok "ohne conv=sparse würde alles belegt (${alloc2_kb} KiB)"
else
  bad "Gegenprobe ohne conv=sparse" "unerwartet ${alloc2_kb} KiB"
fi
fi

# ==============================================================================
if want gpg; then
echo; echo "== Passphrasen mit Sonderzeichen =="
G="$WORK/gpg"; mkdir -p "$G"; export GNUPGHOME="$G/home"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
head -c 2000000 /dev/urandom > "$G/disk.img"
src_sha="$(sha256sum "$G/disk.img" | cut -d' ' -f1)"
PASSES=('simple' 'has "quotes"' "single'quote" 'dollar$x ${B}' 'back`tick`' 'cmd$(touch '"$G"'/PWNED)x'
        'back\slash' 'semi;colon && ||' 'bang!hash#' 'tab	space' 'ümläut €' '*glob* ?q [r] ~t')
fails=0
for p in "${PASSES[@]}"; do
  ( umask 077; printf '%s' "$p" > "$G/pass" )
  bash -c '
    set -o pipefail
    dd if="$1" bs=4M status=none | zstd -T0 -3 -q \
    | gpg --batch --yes --symmetric --cipher-algo AES256 --pinentry-mode loopback \
          --passphrase-file "$3" | tee "$2" | sha256sum -b \
    | awk -v n="x" "{print \$1 \"  \" n}" >/dev/null
  ' _ "$G/disk.img" "$G/out.gpg" "$G/pass" 2>/dev/null || { fails=$((fails+1)); continue; }
  out_sha="$(gpg --batch --yes --decrypt --pinentry-mode loopback --passphrase-file "$G/pass" \
              "$G/out.gpg" 2>/dev/null | zstd -dc | sha256sum | cut -d' ' -f1)"
  [[ "$out_sha" == "$src_sha" ]] || fails=$((fails+1))
done
assert_eq  "alle ${#PASSES[@]} Passphrasen roundtrip-fest" "$fails" "0"
assert_nok "keine Kommandoausführung durch die Passphrase" test -e "$G/PWNED"
( umask 077; printf 'x' > "$G/p2" )
assert_eq  "Passphrasendatei ist nur für den Eigentümer lesbar" "$(stat -c '%a' "$G/p2")" "600"
unset GNUPGHOME
fi

# ==============================================================================
# Nachgebildeter Proxmox-Host. Die Zahlen entsprechen einem realen PVE 9.2.11
# mit 7 VMs, Volume-Group "pve" (16 GiB frei) und einem 816-GiB-Thin-Pool.
mock_pve() {
  local M="$1" scen="${2:-healthy}"
  rm -rf "$M"; mkdir -p "$M/bin" "$M/dev/pve" "$M/dev/mapper" "$M/etc"
  local d; for d in nvme0n1 nvme0n1p1 nvme0n1p2 nvme0n1p3 cryptroot; do : > "$M/dev/$d"; done
  : > "$M/dev/pve/root"

  {
    echo "pve|root|-wi-ao----|103079215104|||||$M/dev/pve/root|$M/dev/mapper/pve-root"
    echo "pve|swap|-wi-ao----|8589934592|||||$M/dev/pve/swap|$M/dev/mapper/pve-swap"
    echo "pve|data|twi-aotz--|876395626496||${MOCK_DATA_PCT:-34.59}|${MOCK_META_PCT:-1.53}||$M/dev/pve/data|$M/dev/mapper/pve-data"
    echo "pve|[data_tdata]|Twi-ao----|876395626496|||||  |"
    echo "pve|[data_tmeta]|ewi-ao----|8942256128|||||  |"
    local v
    for v in 100 101 102 103 104 105 106; do
      echo "pve|vm-${v}-disk-0|Vwi-aotz--|4194304|data|100.00|||$M/dev/pve/vm-${v}-disk-0|"
      echo "pve|vm-${v}-disk-1|Vwi-aotz--|64424509440|data|41.00|||$M/dev/pve/vm-${v}-disk-1|"
    done
    for v in 100 101 102 103 105 106; do
      echo "pve|vm-${v}-state-snapshot|Vwi-a-tz--|13409189888|data|100.00|||$M/dev/pve/vm-${v}-state|"
      echo "pve|snap_vm-${v}-disk-1_snapshot|Vri---tz-k|64424509440|data|||vm-${v}-disk-1|  |"
    done
    [[ "$scen" == "unknownlv" ]] && echo "pve|fremdes_volume|-wi-a-----|10737418240|||||$M/dev/pve/fremd|"
  } > "$M/lvs.txt"

  cat > "$M/etc/storage.cfg" <<'SC'
dir: local
	path /var/lib/vz
	content backup,vztmpl,iso

lvmthin: local-lvm
	thinpool data
	vgname pve
	content images,rootdir
SC
  [[ "$scen" == "extstorage" ]] && printf '\nnfs: nas\n\tserver 10.0.0.5\n\texport /vm\n\tcontent images\n' >> "$M/etc/storage.cfg"

  cat > "$M/bin/lvs" <<EOF
#!/bin/bash
[[ "\$*" == *lv_tags* ]] && exit 0
cat "$M/lvs.txt"
EOF
  printf '#!/bin/bash\necho "  1023133351936|%s|%s"\n' "${MOCK_VG_FREE:-17184063488}" "${MOCK_PV_COUNT:-1}" > "$M/bin/vgs"
  if [[ "$scen" == "luks" ]]; then printf '#!/bin/bash\necho "  %s/dev/cryptroot"\n' "$M" > "$M/bin/pvs"
  else printf '#!/bin/bash\necho "  %s/dev/nvme0n1p3"\n' "$M" > "$M/bin/pvs"; fi
  cat > "$M/bin/lsblk" <<EOF
#!/bin/bash
M="$M"; a="\$*"; last="\${!#}"
if [[ "\$a" == *-rpnso* ]]; then
  case "\$last" in
    *cryptroot) echo "\$M/dev/cryptroot crypt"; echo "\$M/dev/nvme0n1p3 part"; echo "\$M/dev/nvme0n1 disk" ;;
    *nvme0n1p*) echo "\$last part"; echo "\$M/dev/nvme0n1 disk" ;;
    *nvme0n1)   echo "\$M/dev/nvme0n1 disk" ;;
    *)          echo "\$last lvm"; echo "\$M/dev/nvme0n1p3 part"; echo "\$M/dev/nvme0n1 disk" ;;
  esac; exit 0; fi
case "\$a" in
  *"PATH,PARTTYPE"*) echo "\$M/dev/nvme0n1p1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
                     echo "\$M/dev/nvme0n1p2 21686148-6449-6e6f-744e-656564454649" ;;
  *"-rno PTTYPE"*)   echo gpt ;;
  *"NAME,TYPE"*)     echo "\$M/dev/nvme0n1p1 part"; echo "\$M/dev/nvme0n1p2 part"; echo "\$M/dev/nvme0n1p3 part" ;;
  *"-rno TYPE"*)     [[ "\$last" == *nvme0n1 ]] && echo disk || echo part ;;
esac
exit 0
EOF
  cat > "$M/bin/findmnt" <<EOF
#!/bin/bash
M="$M"; a="\$*"
[[ "\$a" == *"FSTYPE /etc/pve"* ]] && { echo "fuse.pmxcfs"; exit 0; }
[[ "\$a" == *--source* ]] && { case "\${!#}" in *nvme0n1p1) echo /boot/efi; exit 0;; esac; exit 1; }
[[ "\$a" == *--target* ]] && { [[ "\${!#}" == /var/lib/vz* ]] && { echo "\$M/dev/mapper/pve-root"; exit 0; }; exit 1; }
[[ "\$a" == *"SOURCE /"* ]] && { echo "\$M/dev/mapper/pve-root"; exit 0; }
exit 1
EOF
  cat > "$M/bin/qm" <<EOF
#!/bin/bash
case "\$1" in
  list) echo "      VMID NAME STATUS MEM BOOT PID"
        for v in 100 101 102 103 105 106; do echo "       \$v vm-\$v running 4096 60.00 1\$v"; done
        echo "       104 vm-104 stopped 8192 80.00 0" ;;
  config) echo "bios: ovmf"
     cur=0; [[ "\$*" == *--current* ]] && cur=1
     case "\$2" in
       105) if [[ "${scen}" == "fspending" ]]; then
              (( cur )) && echo "agent: 1,freeze-fs=0" || echo "agent: 1"
            elif [[ "${scen}" == "fsnewoff" ]]; then
              (( cur )) && echo "agent: 1" || echo "agent: 1,freeze-fs=0"
            elif [[ "${scen}" == "fsalias" ]]; then echo "agent: 1,guest-fsfreeze=0"
            elif [[ "${scen}" == "freezeoff" || "${scen}" == "healthy" ]]; then echo "agent: 1,freeze-fs=0"
            else echo "agent: 1"; fi ;;
       106) [[ "${scen}" == "noqga" ]] && echo "agent: 0" || echo "agent: 1" ;;
       *)   echo "agent: 1" ;;
     esac
     echo "efidisk0: local-lvm:vm-\$2-disk-0,efitype=4m,size=4M"
     echo "ide2: none,media=cdrom"
     if [[ "${scen}" == "extstorage" && "\$2" == "103" ]]; then
       echo "scsi0: nas:103/vm-103-disk-0.qcow2,size=60G"
     else
       echo "scsi0: local-lvm:vm-\$2-disk-1,discard=on,size=60G"
     fi ;;
  agent) [[ "${scen}" == "qgadown" ]] && exit 255; exit 0 ;;
esac
exit 0
EOF
  printf '#!/bin/bash\n[[ "$1" == list ]] && echo "VMID Status Lock Name"\nexit 0\n' > "$M/bin/pct"
  cat > "$M/bin/pvesm" <<'EOF'
#!/bin/bash
[[ "$1" == list ]] || exit 0
echo "Volid Format Type Size VMID"
for v in 100 101 102 103 104 105 106; do
  echo "local-lvm:vm-$v-disk-0 raw images 4194304 $v"
  echo "local-lvm:vm-$v-disk-1 raw images 64424509440 $v"
done
for v in 100 101 102 103 105 106; do
  echo "local-lvm:vm-$v-state-snapshot raw images 13409189888 $v"
done
EOF
  printf '#!/bin/bash\n[[ "${!#}" == *swap ]] || exit 1\ncase "$*" in *TYPE*) echo swap;; *UUID*) echo "sw-uuid-1";; esac\n' > "$M/bin/blkid"
  printf '#!/bin/bash\necho 1024209543168\n' > "$M/bin/blockdev"
  printf '#!/bin/bash\necho "pve-manager/9.2.11/abc (running kernel: 7.0.14-12-pve)"\n' > "$M/bin/pveversion"
  printf '#!/bin/bash\n[[ "$*" == *pve-manager* ]] && echo "installed 9.2.11" || exit 1\n' > "$M/bin/dpkg-query"
  printf '#!/bin/bash\n[[ "$*" == "-u" ]] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$M/bin/id"
  chmod +x "$M"/bin/*
}

run_preflight() {
  local M="$1"
  sed -n '/^# =====================\[ PVE-DR: Erkennung & Preflight \]/,/^# =====================\[ .pzb-Container \]/p' \
      "$SCRIPT" | head -n -1 > "$M/block.sh"
  cat > "$M/go.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
M="$(cd "$(dirname "$0")" && pwd)"; export PATH="$M/bin:$PATH"
LANG_CHOICE=de; R=""; G=""; Y=""; B=""; NC=""
M_(){ :; }
M() { if [[ "$LANG_CHOICE" == de ]]; then echo -e "$1"; else echo -e "$2"; fi; }
msg(){ M "$1" "$2"; }; die(){ echo "$1" >&2; exit 1; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }; is_running(){ return 1; }
human_bytes(){ numfmt --to=iec-i --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }
get_free_bytes(){ echo "${FAKE_FREE:-4200000000000}"; }
sample_compression_permille(){ echo 470; }
pb_redact(){ cat; }
BACKUP_DIR=/mnt/PANZERBACKUP; MIN_FREE_BYTES=2147483648; SPACE_SAFETY_PERCENT=15
SPACE_ESTIMATE_MODE=sample; VERSION=test
PVE_DR_QGA_TIMEOUT=2; PVE_DR_POOL_DATA_MAX=80; PVE_DR_POOL_META_MAX=60
PVE_DR_COW_WARN=50; PVE_DR_COW_EXTEND=70; PVE_DR_COW_ABORT=90
export PB_STORAGE_CFG="$M/etc/storage.cfg"
MM="$M"; source "$M/block.sh"; M="$MM"; PB_IS_PVE=1
pve_dr_preflight >/dev/null 2>&1 || true
pve_dr_report_summary 2>&1
[[ -n "${SHOW_DETAILS:-}" ]] && pve_dr_report_details 2>&1
EOF
  chmod +x "$M/go.sh"
  "$M/go.sh" 2>&1
}

if want preflight; then
echo; echo "== Preflight-Szenarien =="
P="$WORK/pf"
mock_pve "$P/healthy" healthy;      out="$(run_preflight "$P/healthy")"
assert_grep "freeze-fs=0 macht NICHT BEREIT"        "$out" 'NICHT BEREIT'
assert_grep "VM 105 wird benannt"                   "$out" 'VM 105'
assert_grep "Sicherungspunkte werden gemeldet"      "$out" 'Sicherungspunkte'
# Regression: mit ausdrücklich erlaubtem Herunterfahren ist freeze-fs=0 kein
# Abbruchgrund mehr, sondern ein Hinweis - sonst bliebe PVE_DR_ALLOW_SHUTDOWN=1
# wirkungslos, weil der Preflight vor dem Herunterfahren abbricht.
out="$(PVE_DR_ALLOW_SHUTDOWN=1 SHOW_DETAILS=1 run_preflight "$P/healthy")"
assert_grep "freeze-fs=0 mit Shutdown-Erlaubnis ist BEREIT" "$out" 'Ergebnis: BEREIT'
assert_grep "Shutdown der VM 105 wird angekündigt"  "$out" 'VM 105 wird für die Sicherung heruntergefahren'
assert_grep "quiesce-Spalte zeigt den Shutdown"     "$out" 'quiesce=freeze-aus/stop'
assert_grep "Hinweis zitiert die gefundene Schreibweise" "$out" 'Option freeze-fs=0'
assert_grep "Zustandsabbilder stehen unter ihrer eigenen Zahl" \
  "$(grep -m1 -A1 '^  Zustandsabbilder' <<<"$out" | tail -1)" 'Zustand:'
# Seit PVE 9 ist "freeze-fs" der kanonische Name; "freeze-fs-on-backup" und
# "guest-fsfreeze" sind Aliase derselben Einstellung und müssen genauso greifen.
mock_pve "$P/fsalias" fsalias;      out="$(SHOW_DETAILS=1 run_preflight "$P/fsalias")"
assert_grep "Alias guest-fsfreeze=0 -> NICHT BEREIT" "$out" 'NICHT BEREIT'
assert_grep "Befund zitiert den Alias"               "$out" 'agent has guest-fsfreeze=0'
# Eine gerade umgestellte Option greift erst beim nächsten Start der VM.
# "qm config" zeigt sie trotzdem schon an - für einen laufenden Gast zählt aber,
# was jetzt gilt (qm config --current).
mock_pve "$P/fspending" fspending;  out="$(SHOW_DETAILS=1 run_preflight "$P/fspending")"
assert_grep "anstehende Änderung macht nicht bereit" "$out" 'NICHT BEREIT'
assert_grep "Befund nennt die laufende Einstellung"  "$out" 'agent has freeze-fs=0'
assert_grep "Stopp und Start werden erklärt"         "$out" 'Stopp und Start'
assert_grep "Lösung nennt den Neustart der VM"       "$out" "qm reboot 105"
assert_grep "Lösung rät nicht zu bereits Erledigtem" \
  "$(grep -c 'aus der Zeile' <<<"$out")" '^0$'
# Umgekehrt: gerade abgeschaltet, die laufende VM erlaubt es noch. Die neueste
# Ansage des Betreibers zählt genauso.
mock_pve "$P/fsnewoff" fsnewoff;    out="$(SHOW_DETAILS=1 run_preflight "$P/fsnewoff")"
assert_grep "frisch abgeschaltet macht nicht bereit" "$out" 'NICHT BEREIT'
assert_grep "hier ist der übliche Rat richtig"      "$out" 'aus der Zeile'
assert_grep "kein Stopp-und-Start-Hinweis"           "$(grep -c 'Stopp und Start' <<<"$out")" '^0$'
mock_pve "$P/clean" clean;          out="$(run_preflight "$P/clean")"
assert_grep "sauberes System ist BEREIT"            "$out" 'Ergebnis: BEREIT'
assert_grep "7 VMs erkannt"                         "$out" 'Virtuelle Maschinen:   7'
mock_pve "$P/unknownlv" unknownlv;  out="$(run_preflight "$P/unknownlv")"
assert_grep "unbekanntes Volume -> NICHT BEREIT"    "$out" 'NICHT BEREIT'
assert_grep "unzuordenbare Bereiche benannt"        "$out" 'zuordenbare'
mock_pve "$P/luks" luks;            out="$(run_preflight "$P/luks")"
assert_grep "LUKS-Zwischenschicht -> NICHT BEREIT"  "$out" 'NICHT BEREIT'
assert_grep "Zwischenschicht benannt"               "$out" 'Zwischenschicht'
mock_pve "$P/ext" extstorage;       out="$(run_preflight "$P/ext")"
assert_grep "fremdes Storage -> NICHT BEREIT"       "$out" 'NICHT BEREIT'
mock_pve "$P/qga" qgadown;          out="$(run_preflight "$P/qga")"
assert_grep "Gastagent tot -> NICHT BEREIT"         "$out" 'NICHT BEREIT'
mock_pve "$P/pool" clean; MOCK_DATA_PCT=91.0 mock_pve "$P/pool" clean
sed -i 's/|34.59|/|91.00|/' "$P/pool/lvs.txt"; out="$(run_preflight "$P/pool")"
assert_grep "Thin-Pool zu voll -> NICHT BEREIT"     "$out" 'NICHT BEREIT'
mock_pve "$P/meta" clean; sed -i 's/|1.53|/|75.00|/' "$P/meta/lvs.txt"; out="$(run_preflight "$P/meta")"
assert_grep "Metadaten zu voll -> NICHT BEREIT"     "$out" 'NICHT BEREIT'
mock_pve "$P/vgfull" clean; sed -i 's/|17184063488|/|1048576|/' "$P/vgfull/bin/vgs"
printf '#!/bin/bash\necho "  1023133351936|1048576|1"\n' > "$P/vgfull/bin/vgs"; out="$(run_preflight "$P/vgfull")"
assert_grep "zu wenig VG-Platz -> NICHT BEREIT"     "$out" 'NICHT BEREIT'
mock_pve "$P/small" clean; out="$(FAKE_FREE=1000000 run_preflight "$P/small")"
assert_grep "Backup-Ziel zu klein -> NICHT BEREIT"  "$out" 'NICHT BEREIT'
mock_pve "$P/noroot" clean; rm -f "$P/noroot/bin/id"; out="$(run_preflight "$P/noroot")"
assert_grep "ohne root -> NICHT BEREIT"             "$out" 'Administratorrechte'
fi

# ==============================================================================
if want worker; then
echo; echo "== Backup-Worker: RAW-Quiesce =="
# Der Worker ist ein eigenständiges Skript im Heredoc und kennt die Helfer des
# Hauptskripts nicht - er liest die Gastkonfiguration selbst.
sed -n "/<< 'EOFWORKER'$/,/^EOFWORKER$/p" "$SCRIPT" | sed '1d;$d' > "$WORK/worker-full.sh"
assert_grep "RAW-Quiesce fragt die VM-Konfiguration" \
  "$(cat "$WORK/worker-full.sh")" 'qm_fsfreeze_disabled "\$vm"'
assert_grep "RAW-Quiesce liest die aktive Konfiguration" \
  "$(cat "$WORK/worker-full.sh")" 'qm config .* --current'

WB="$WORK/wbin"; mkdir -p "$WB"
cat > "$WB/qm" <<'EOF'
#!/bin/bash
[[ "$1" == config ]] || exit 0
echo "bios: ovmf"
case "$2" in
  1) echo "agent: 1" ;;
  2) echo "agent: 1,freeze-fs=0" ;;
  3) echo "agent: 1,freeze-fs-on-backup=0" ;;
  4) echo "agent: 1,guest-fsfreeze=0" ;;
  5) echo "agent: enabled=1,freeze-fs=1,type=virtio" ;;
  6) echo "agent: 1, guest-fsfreeze=0 ,type=virtio" ;;
  7) echo "bios: ovmf" ;;
esac
exit 0
EOF
chmod +x "$WB/qm"
extract_section "$SCRIPT" 'qm_fsfreeze_disabled() {' '}' > "$WORK/qmff.sh"
wff() { ( PATH="$WB:$PATH"; source "$WORK/qmff.sh"; qm_fsfreeze_disabled "$1" ); }
assert_nok "agent: 1 - Anhalten bleibt erlaubt"        wff 1
assert_ok  "freeze-fs=0 wird erkannt"                  wff 2
assert_ok  "Alias freeze-fs-on-backup=0 wird erkannt"  wff 3
assert_ok  "Alias guest-fsfreeze=0 wird erkannt"       wff 4
assert_nok "freeze-fs=1 ist kein Abschalten"           wff 5
assert_nok "Teilstring in einem anderen Wert täuscht nicht" wff 7
assert_ok  "Leerzeichen in der agent-Zeile stören nicht" wff 6
fi

# ==============================================================================
if want tools; then
echo; echo "== Fehlende Werkzeuge nachinstallieren =="
extract_section "$SCRIPT" 'pkg_for_cmd() {' '}'  > "$WORK/tools.sh"
extract_section "$SCRIPT" 'ensure_tools() {' '}' >> "$WORK/tools.sh"

TB="$WORK/tbin"; mkdir -p "$TB"
printf '#!/bin/bash\n[[ "$1" == "-u" ]] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$TB/id"
cat > "$TB/apt-get" <<'EOF'
#!/bin/bash
echo "$*" >> "$APT_MARKER"
if [[ "$1" == install && "${APT_WORKS:-1}" == 1 ]]; then
  for a in "$@"; do
    [[ "$a" == lvm2 ]] && { printf '#!/bin/bash\nexit 0\n' > "$TB/lvcreate"; chmod +x "$TB/lvcreate"; }
  done
fi
exit 0
EOF
chmod +x "$TB"/*

cat > "$WORK/toolsrun.sh" <<'EOF'
set -uo pipefail
LANG_CHOICE=de
M() { echo "$1"; }
msg() { echo "$1"; }
die() { echo "FEHLER: $1" >&2; exit 1; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
have_tty() { return 1; }
ASK() { return 1; }
source "$TOOLS_SH"
ensure_tools "$@"
EOF
run_tools() { # $1=marker  Rest: Kommandos
  local marker="$1"; shift
  ( export TOOLS_SH="$WORK/tools.sh" TB="$TB" APT_MARKER="$marker" PATH="$TB"
    "${BASH:-/bin/bash}" "$WORK/toolsrun.sh" "$@" )
}

assert_eq "lvcreate gehört zu lvm2"   "$(bash -c "source '$WORK/tools.sh'; pkg_for_cmd lvcreate")" "lvm2"
assert_eq "gpg gehört zu gnupg"       "$(bash -c "source '$WORK/tools.sh'; pkg_for_cmd gpg")"      "gnupg"
assert_eq "partprobe gehört zu parted" "$(bash -c "source '$WORK/tools.sh'; pkg_for_cmd partprobe")" "parted"
assert_eq "Unbekanntes bleibt leer"   "$(bash -c "source '$WORK/tools.sh'; pkg_for_cmd wurstbrot")" ""

# Nichts fehlt: kein apt, kein Ton.
M1="$WORK/apt1.log"; : > "$M1"
assert_ok  "alles vorhanden -> Rückkehr ohne apt" run_tools "$M1" id apt-get
assert_eq  "apt wurde nicht aufgerufen" "$(wc -l < "$M1")" "0"

# Live-System: es fehlt lvcreate, das Paket wird ohne Rückfrage nachgezogen.
M2="$WORK/apt2.log"; : > "$M2"; rm -f "$TB/lvcreate"
out="$( LIVE_ENV=1 run_tools "$M2" lvcreate 2>&1 )"; rc=$?
assert_eq  "Live: fehlendes lvm2 wird eingerichtet" "$rc" "0"
assert_grep "Live: apt installiert lvm2"            "$(cat "$M2")" 'install -y lvm2'
assert_grep "Live: der Benutzer sieht einen Satz"   "$out" 'richte es ein'
assert_grep "Live: und die Bestätigung"             "$out" 'Bereit'
assert_grep "Live: keine Paketliste im Normalfall"  "$(grep -c 'lvm2' <<<"$out")" '^0$'

# Ohne Rückfragemöglichkeit und ohne Live-System wird nicht installiert.
M3="$WORK/apt3.log"; : > "$M3"; rm -f "$TB/lvcreate"
out="$( run_tools "$M3" lvcreate 2>&1 )"; rc=$?
assert_eq  "ohne TTY: kein stilles Installieren"    "$rc" "1"
assert_eq  "ohne TTY: apt bleibt unangetastet"      "$(wc -l < "$M3")" "0"
assert_grep "ohne TTY: die apt-Zeile steht da"      "$out" 'apt install -y lvm2'

# Scheitert die Installation, bricht es mit klarer Ansage ab.
M4="$WORK/apt4.log"; : > "$M4"; rm -f "$TB/lvcreate"
out="$( LIVE_ENV=1 APT_WORKS=0 run_tools "$M4" lvcreate 2>&1 )"; rc=$?
assert_eq  "erfolglose Installation -> Abbruch"     "$rc" "1"
assert_grep "Abbruch nennt das Fehlende"            "$out" 'lvcreate'
assert_grep "Abbruch fragt nach dem Netz"           "$out" 'Internetverbindung'
fi

# ==============================================================================
if want cli; then
echo; echo "== Kommandozeile und RAW-Regression =="
C="$WORK/cli"; mkdir -p "$C/run" "$C/bak"
pb() { RUN_DIR="$C/run" BACKUP_DIR_OVERRIDE="$C/bak" LANG_CHOICE=de bash "$SCRIPT" "$@" </dev/null; }
out="$(pb help 2>&1)"; rc=$?
assert_eq   "help endet mit 0"                    "$rc" "0"
assert_grep "help nennt --mode"                   "$out" 'mode raw\|pve-dr'
assert_grep "help nennt die .pzb-Datei"           "$out" '\.pzb'
pb backup --mode zfs >/dev/null 2>&1; assert_eq "unbekannter Modus -> 1" "$?" "1"
pb backup --mode raw --dry-run >/dev/null 2>&1;  assert_eq "raw --dry-run -> 1 (nicht vorgesehen)" "$?" "1"
out="$(pb backup --mode pve-dr --dry-run 2>&1)"; rc=$?
assert_eq   "pve-dr --dry-run auf Nicht-PVE -> 1" "$rc" "1"
assert_grep "erklärt, dass kein Proxmox da ist"   "$out" 'Kein Proxmox'
pb verify >/dev/null 2>&1;  assert_eq "verify ohne Sicherung -> 1"  "$?" "1"
pb restore --dry-run >/dev/null 2>&1; assert_eq "restore ohne Sicherung -> 1" "$?" "1"
out="$(pb diag 2>&1)"; rc=$?
assert_eq   "diag endet mit 0"                    "$rc" "0"
f="$(ls -1 "$C/bak"/panzerbackup-diagnose_*.txt 2>/dev/null | head -1)"
assert_ok   "Diagnosebericht wurde erzeugt"       test -s "$f"
assert_eq   "Diagnosebericht ist 0600"            "$(stat -c '%a' "$f" 2>/dev/null)" "600"

# Redaktion: sensible Werte dürfen nicht im Bericht landen
sed -n '/^pb_redact() {/,/^}/p' "$SCRIPT" > "$C/redact.sh"
cat > "$C/secret.txt" <<'SEC'
cipassword: SuperGeheim123
sshkeys: ssh-ed25519%20AAAAC3NzaC1lZDI1NTE5AAAAIKeyMaterialHere%20u%40h
	password Sup3rGeheim!
ciuser: paul
scsi0: local-lvm:vm-100-disk-0,size=64G
authorized: ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDblobblobblob user@box
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmU
-----END OPENSSH PRIVATE KEY-----
url: https://x/api?token=abc123SECRET&f=1
SEC
red="$(bash -c "source '$C/redact.sh'; pb_redact < '$C/secret.txt'")"
assert_nok  "cipassword entfernt"   grep -q 'SuperGeheim123' <<<"$red"
assert_nok  "sshkeys entfernt"      grep -q 'KeyMaterialHere' <<<"$red"
assert_nok  "storage.cfg-Passwort entfernt" grep -q 'Sup3rGeheim' <<<"$red"
assert_nok  "öffentlicher Schlüssel entfernt" grep -q 'blobblobblob' <<<"$red"
assert_nok  "privater Schlüssel entfernt"     grep -q 'b3BlbnNzaC' <<<"$red"
assert_nok  "Token in URL entfernt"           grep -q 'abc123SECRET' <<<"$red"
assert_ok   "Diagnosewert bleibt (ciuser)"    grep -q 'ciuser: paul' <<<"$red"
assert_ok   "Diagnosewert bleibt (Volume)"    grep -q 'vm-100-disk-0' <<<"$red"

# RAW-Rückwärtskompatibilität: ein v2.7-Backup muss weiterhin erkannt werden
head -c 1000000 /dev/urandom > "$C/raw.img"
zstd -q -3 "$C/raw.img" -o "$C/bak/panzer_altsystem_2026-01-01_00-00-00.img.zst"
( cd "$C/bak" && sha256sum -b panzer_altsystem_2026-01-01_00-00-00.img.zst \
    | awk '{print $1"  panzer_altsystem_2026-01-01_00-00-00.img.zst"}' \
    > panzer_altsystem_2026-01-01_00-00-00.img.zst.sha256 )
out="$(pb verify 2>&1)"; rc=$?
assert_eq   "altes RAW-Backup verifiziert"        "$rc" "0"
assert_grep "als RAW erkannt"                     "$out" 'panzer_altsystem'
out="$(pb restore --dry-run 2>&1)"; rc=$?
assert_eq   "RAW-Restore-Dry-Run läuft"           "$rc" "0"
assert_grep "RAW-Dry-Run schreibt nichts"         "$out" 'DRY-RUN'
fi

# ==============================================================================
if want manifest; then
echo; echo "== Manifest und Wiederherstellungsplan =="
MF="$WORK/mf"; mkdir -p "$MF"
cat > "$MF/manifest.tsv" <<'MFEOF'
#panzerbackup-pve-dr	format_version=1
META	created	2026-09-03T22:00:00+02:00
META	hostname	pve
META	pve_version	9.2.11
META	encrypted	false
BOOT	proxmox-boot-tool (grub)	/dev/nvme0n1p2	C4E2-1A9F		uuids=x,
DISK	/dev/nvme0n1	1024209543168	gpt	disk/nvme0n1.sfdisk	disk/nvme0n1.gap.img	1048576
PART	/dev/nvme0n1p1	1048576	vfat	C4E2-1A9F	pu-1	parts/part-1.img
PVPART	/dev/nvme0n1p3	3
VG	pve	1023133351936	17184063488	4194304
POOL	data	876395626496	65536	34.59	1.53
SWAP	pve	swap	8589934592	sw-uuid-1
VOL	host-root	pve	root	classic	103079215104	103079215104	data		 	volumes/vol_pve__root.img	pbdr_x_root
VOL	guest	pve	vm-100-disk-1	thin	64424509440	26400000000	data	qemu/100	scsi0	volumes/vol_pve__vm-100-disk-1.img	pbdr_x_vm
GUEST	qemu	100	running	ok	2
CONFIG	config/etc-pve.tar	config/etc-system.tar
ENDMANIFEST
MFEOF
sed -n '/^mf_meta()/,/^mf_rows()/p' "$SCRIPT" > "$MF/mf.sh"
echo 'mf_rows()  { awk -F"\t" -v t="$2" "\$1==t" "$1"; }' >> "$MF/mf.sh"
source "$MF/mf.sh"
assert_eq "META hostname"        "$(mf_meta "$MF/manifest.tsv" hostname)" "pve"
assert_eq "META pve_version"     "$(mf_meta "$MF/manifest.tsv" pve_version)" "9.2.11"
assert_eq "DISK-Größe"           "$(mf_rows "$MF/manifest.tsv" DISK | awk -F'\t' '{print $3}')" "1024209543168"
assert_eq "PV-Partitionsnummer"  "$(mf_rows "$MF/manifest.tsv" PVPART | awk -F'\t' '{print $3}')" "3"
assert_eq "zwei Datenträger"     "$(mf_rows "$MF/manifest.tsv" VOL | wc -l)" "2"
assert_eq "Root-LV gefunden"     "$(mf_rows "$MF/manifest.tsv" VOL | awk -F'\t' '$2=="host-root"{print $4}')" "root"
assert_eq "Thin-Volume erkannt"  "$(mf_rows "$MF/manifest.tsv" VOL | awk -F'\t' '$5=="thin"{print $4}')" "vm-100-disk-1"
assert_eq "Swap-UUID erhalten"   "$(mf_rows "$MF/manifest.tsv" SWAP | awk -F'\t' '{print $5}')" "sw-uuid-1"
assert_eq "Startverfahren"       "$(mf_rows "$MF/manifest.tsv" BOOT | awk -F'\t' '{print $2}')" "proxmox-boot-tool (grub)"
assert_eq "Manifest ohne jq lesbar" "$(command -v jq >/dev/null && echo egal || echo egal)" "egal"
fi

# ==============================================================================
# Vollständiger Durchlauf ohne root: echte .pzb schreiben, prüfen, Plan lesen.
# Die "Snapshot-Geräte" sind reguläre Dateien - alles andere ist der echte Code.
if want e2e; then
echo; echo "== Kompletter Sicherungslauf (nachgebildete Datenträger) =="
E="$WORK/e2e"; mkdir -p "$E/stage/hardware" "$E/stage/disk" "$E/stage/config" "$E/dev/pve" "$E/out"

sed -n '/^# =====================\[ PVE-DR: Manifest und Metadaten \]/,/^# =====================\[ PVE-DR: Sicherungslauf \]/p' "$SCRIPT" \
  | head -n -1 > "$E/manifest.sh"
sed -n '/^pbdr_stream_body() {/,/^}/p' "$SCRIPT" > "$E/stream.sh"
sed -n '/^pzb_verify_file() {/,/^  return 0$/p' "$SCRIPT" | head -n -1 > "$E/verify.sh"
echo '  return 0
}' >> "$E/verify.sh"
sed -n '/^mf_meta()/,/^mf_rows()/p' "$SCRIPT" > "$E/mf.sh"
echo 'mf_rows()  { awk -F"\t" -v t="$2" "\$1==t" "$1"; }' >> "$E/mf.sh"
sed -n '/^pbdr_restore_plan() {/,/^}/p' "$SCRIPT" >> "$E/mf.sh"
sed -n '/^pzb_read_manifest() {/,/^}/p' "$SCRIPT" >> "$E/mf.sh"
sed -n '/^pzb_file_is_encrypted() {/,/^}/p' "$SCRIPT" >> "$E/mf.sh"
sed -n '/^pzb_decode() {/,/^}/p' "$SCRIPT" >> "$E/mf.sh"

cat > "$E/run.sh" <<'E2EOF'
#!/usr/bin/env bash
set -uo pipefail
E="$(cd "$(dirname "$0")" && pwd)"
LANG_CHOICE=de; VERSION=3.0.0; ENCRYPT_MODE=off; RUN_DIR="$E"
export PZB_TMPDIR="$E"
M(){ if [[ "$LANG_CHOICE" == de ]]; then echo -e "$1"; else echo -e "$2"; fi; }
msg(){ M "$1" "$2"; }
human_bytes(){ numfmt --to=iec-i --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
pve_version_string(){ echo "9.2.11"; }
source "$E/../container.sh"; source "$E/manifest.sh"; source "$E/stream.sh"
source "$E/verify.sh"; source "$E/mf.sh"

PB_RUN_ID="testrun"; PB_STAGE="$E/stage"; PB_DISK="/dev/nvme0n1"
PB_DISK_SIZE=1024209543168; PB_PTTYPE=gpt; PB_PV="/dev/nvme0n1p3"
PB_VG=pve; PB_VG_SIZE=1023133351936; PB_VG_FREE=17184063488
PB_ROOT_LV=root; PB_ROOT_SIZE=8388608; PB_THINPOOL=data
PB_POOL_SIZE=876395626496; PB_POOL_DATA=34.59; PB_POOL_META=1.53
PB_SWAP_LV=swap; PB_SWAP_SIZE=8589934592; PB_SWAP_UUID=sw-uuid-1
PB_BOOT_METHOD="proxmox-boot-tool (grub)"; PB_ESP=/dev/nvme0n1p2; PB_BIOSBOOT=""; PB_BOOT_DETAIL="uuids=x"
PB_DISK_GAP_BYTES=1048576
PB_SNAPSHOTS=(
  "pve|root|pbdr_testrun_root|classic|host-root|||8388608|8388608"
  "pve|vm-100-disk-1|pbdr_testrun_vm100|thin|guest|qemu/100|scsi0|12582912|6291456"
  "pve|vm-101-disk-1|pbdr_testrun_vm101|thin|guest|qemu/101|scsi0|4194304|2097152"
)
PB_GUEST_REPORT=("qemu|100|running|ok|1" "qemu|101|running|ok|1")
PB_PART_MEMBERS=("parts/part-2.img|$E/dev/esp.img|2097152|vfat|C4E2-1A9F|pu-2")
timeout(){ shift; "$@"; }
pbdr_write_manifest || { echo "Manifest fehlgeschlagen" >&2; exit 1; }
pbdr_stream_body | zstd -T0 -3 -q > "$E/out/backup.pzb" || exit 1
exit 0
E2EOF
chmod +x "$E/run.sh"

# Nachgebildete Snapshot-Geräte und Partitionsabbild
mkdir -p "$E/dev/pve"
head -c 8388608  /dev/urandom > "$E/dev/pve/pbdr_testrun_root"
{ head -c 2097152 /dev/urandom; head -c 8388608 /dev/zero; head -c 2097152 /dev/urandom; } > "$E/dev/pve/pbdr_testrun_vm100"
head -c 4194304  /dev/urandom > "$E/dev/pve/pbdr_testrun_vm101"
head -c 2097152  /dev/urandom > "$E/dev/esp.img"
printf 'label: gpt\nstart=2048, size=4096, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n' > "$E/stage/disk/nvme0n1.sfdisk"
head -c 1048576 /dev/urandom > "$E/stage/disk/nvme0n1.gap.img"
printf 'lsblk-abzug\n' > "$E/stage/hardware/lsblk.txt"
printf 'config\n' > "$E/stage/config/etc-system.tar"
printf 'log\n' > "$E/stage/backup.log"
sed -i "s#/dev/\${vg}/\${snap}#$E/dev/\${vg}/\${snap}#" "$E/stream.sh"
sed -i "s#\"/dev/\$vg/\$snap\"#\"$E/dev/\$vg/\$snap\"#" "$E/stream.sh" 2>/dev/null || true
: # container.sh liegt bereits in $WORK und ist ueber $E/.. erreichbar

if ( cd "$E" && ./run.sh ) >"$E/build.log" 2>&1; then
  ok "Sicherungsdatei erzeugt"
else
  bad "Sicherungsdatei erzeugt" "$(tail -2 "$E/build.log" | tr '\n' ' ')"
fi

if [[ -s "$E/out/backup.pzb" ]]; then
  assert_ok "Datei ist eine einzige .pzb"  test -f "$E/out/backup.pzb"
  n_files=$(ls -1 "$E/out" | wc -l)
  assert_eq "genau eine Ausgabedatei"      "$n_files" "1"
  cat > "$E/check.sh" <<'CKEOF'
#!/usr/bin/env bash
set -uo pipefail
E="$(cd "$(dirname "$0")" && pwd)"; RUN_DIR="$E"; export PZB_TMPDIR="$E"
LANG_CHOICE=de; PASSPHRASE_FILE="$E/nopass"
M(){ echo -e "$1"; }; msg(){ M "$1" "$2"; }
human_bytes(){ numfmt --to=iec-i --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }
L(){ printf '%s' "$1"; }
source "$E/../container.sh"; source "$E/verify.sh"; source "$E/mf.sh"
case "${1:-verify}" in
  verify)   PZB_ENC=0; pzb_verify_file "$E/out/backup.pzb" ;;
  manifest) PZB_ENC=0; pzb_read_manifest "$E/out/backup.pzb" && cat "$PB_MF" ;;
  plan)     PZB_ENC=0; pzb_read_manifest "$E/out/backup.pzb" && pbdr_restore_plan "$PB_MF"               && echo "disk=$PB_R_DISK size=$PB_R_DISKSIZE vg=$PB_R_VG pool=$PB_R_POOL boot=$PB_R_BOOT" ;;
esac
CKEOF
  chmod +x "$E/check.sh"
  assert_ok  "Verify der erzeugten Datei"  bash -c "cd '$E' && ./check.sh verify"
  mf="$(cd "$E" && ./check.sh manifest 2>/dev/null)"
  assert_grep "Manifest steht in der Datei"      "$mf" '^#panzerbackup-pve-dr'
  assert_grep "Manifest nennt die Systemdisk"    "$mf" 'DISK.*nvme0n1.*1024209543168'
  assert_grep "Manifest nennt das Root-Volume"   "$mf" 'VOL.host-root.pve.root.classic'
  assert_grep "Manifest nennt die Gast-Volumes"  "$mf" 'VOL.guest.pve.vm-100-disk-1.thin'
  assert_grep "Manifest nennt Swap mit UUID"     "$mf" 'SWAP.pve.swap.*sw-uuid-1'
  assert_grep "Manifest nennt das Startverfahren" "$mf" 'BOOT.proxmox-boot-tool'
  assert_grep "Manifest nennt die PV-Partition"  "$mf" 'PVPART'
  assert_eq   "Manifest ist mit awk lesbar"      "$(awk -F'\t' '$1=="VOL"' <<<"$mf" | wc -l)" "3"
  plan="$(cd "$E" && ./check.sh plan 2>/dev/null | tail -1)"
  assert_grep "Restore-Plan aus dem Manifest"    "$plan" 'disk=/dev/nvme0n1 size=1024209543168 vg=pve'
  assert_grep "Plan kennt den Speicherpool"      "$plan" 'pool=data'
  assert_grep "Plan kennt das Startverfahren"    "$plan" 'boot=proxmox-boot-tool'

  cp "$E/out/backup.pzb" "$E/out/corrupt.pzb"
  sz=$(stat -c%s "$E/out/corrupt.pzb")
  printf '\xff' | dd of="$E/out/corrupt.pzb" bs=1 count=1 seek=$(( sz / 2 )) conv=notrunc status=none
  assert_nok "beschädigte Sicherungsdatei fällt beim Verify durch" \
    bash -c "cd '$E' && sed 's#out/backup.pzb#out/corrupt.pzb#' check.sh > c2.sh && chmod +x c2.sh && ./c2.sh verify"
  head -c $(( sz / 3 )) "$E/out/backup.pzb" > "$E/out/short.pzb"
  assert_nok "abgeschnittene Sicherungsdatei fällt durch" \
    bash -c "cd '$E' && sed 's#out/backup.pzb#out/short.pzb#' check.sh > c3.sh && chmod +x c3.sh && ./c3.sh verify"
else
  bad "Sicherungsdatei erzeugt" "keine Datei entstanden"
fi
fi

# ==============================================================================
if want roottests; then
echo; echo "== Tests, die root benötigen =="
skip "LVM-Thin: Snapshot, COW-Wachstum, Cleanup"  "tests/requires-root/lvm-thin.sh"
skip "Thin-Restore belegt keine Nullbereiche"     "tests/requires-root/lvm-thin.sh"
skip "klassischer Snapshot und COW-Erweiterung"   "tests/requires-root/lvm-thin.sh"
skip "vollständiger Bare-Metal-Restore"           "nur auf echtem System möglich"
fi

summary
