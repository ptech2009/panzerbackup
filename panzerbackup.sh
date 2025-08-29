#!/usr/bin/env bash
set -euo pipefail

# ===== Hilfsfunktionen =====
msg() { echo -e "$*"; }
ask() { read -r -p "$1 [y/N]: " ans; [[ "${ans:-}" =~ ^[Yy]$ ]]; }
die() { echo "❌ $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Benötigtes Kommando fehlt: $1"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# systemd-inhibit Wrapper (verhindert Sleep/Idle/Lid während kritischer Jobs)
run_inhibited() {
  local why="${1:?}"; shift
  if has_cmd systemd-inhibit; then
    systemd-inhibit --what=handle-lid-switch:sleep:idle --why="$why" "$@"
  else
    "$@"
  fi
}

# ===== Systemdisk-Erkennung (robust: raw parents, LVM/mapper-fähig) =====
detect_system_disk() {
  need_cmd lsblk; need_cmd awk

  # 1) Root-Gerät
  local root_dev
  root_dev="$(lsblk -rpn -o NAME,MOUNTPOINT | awk '$2=="/"{print $1; exit}')"

  # 2) Fallback: findmnt-Quelle auf /dev/* mappen
  if [[ -z "$root_dev" || ! -e "$root_dev" ]]; then
    local src; src="$(findmnt -no SOURCE / || true)"
    if [[ -n "$src" ]]; then
      if [[ "$src" =~ ^/dev/ && -e "$src" ]]; then
        root_dev="$src"
      elif [[ -e "/dev/mapper/$src" ]]; then
        root_dev="/dev/mapper/$src"
      elif [[ "$src" == *-* && -e "/dev/${src%%-*}/${src#*-}" ]]; then
        root_dev="/dev/${src%%-*}/${src#*-}"
      elif [[ -e "/dev/$src" ]]; then
        root_dev="/dev/$src"
      fi
    fi
  fi

  # 3) Fallback: Partition mit "/"
  if [[ -z "$root_dev" || ! -e "$root_dev" ]]; then
    root_dev="$(lsblk -rpn -o NAME,TYPE,MOUNTPOINT | awk '$2=="part" && $3=="/"{print $1; exit}')"
  fi

  [[ -n "$root_dev" && -e "$root_dev" ]] || { msg "[detect] Root-Gerät unbekannt"; return 1; }

  # 4) Eltern-Kette → Top-Level-Disk
  local topdisk
  topdisk="$(lsblk -rpnso NAME,TYPE -s "$root_dev" 2>/dev/null \
            | awk '$2=="disk"{last=$1} END{if(last) print last}')"
  if [[ -n "$topdisk" && -b "$topdisk" ]]; then
    echo "$topdisk"; return 0
  fi

  # 5) Fallback via PKNAME
  local cur="$root_dev"
  for _ in {1..12}; do
    local typ pk
    typ="$(lsblk -rno TYPE "$cur" 2>/dev/null || true)"
    [[ "$typ" == "disk" ]] && { echo "$cur"; return 0; }
    pk="$(lsblk -rno PKNAME "$cur" 2>/dev/null || true)"
    [[ -z "$pk" ]] && break
    cur="/dev/$pk"
  done
  return 1
}

# ===== Geräte/Disks anzeigen & auswählen =====
list_available_disks() {
  need_cmd lsblk
  lsblk -dnpo NAME,SIZE,MODEL,TYPE | while IFS= read -r line; do
    if [[ "$line" =~ disk$ ]] && [[ ! "$line" =~ ^/dev/(loop|sr) ]]; then
      local name size model
      name=$(echo "$line" | awk '{print $1}')
      size=$(echo "$line" | awk '{print $2}')
      model=$(echo "$line" | awk '{for(i=3;i<NF;i++) printf "%s ", $i; if(NF>=3) print $NF; else print "Unknown"}')
      [[ -z "$model" || "$model" == " " ]] && model="Unknown"
      echo "$name|$size|$model"
    fi
  done
}

select_target_disk() {
  local current_disk="${1:-}"
  local disks=()
  echo "[*] Verfügbare Disks:" >&2
  local i=1
  while IFS='|' read -r name size model; do
    if [[ "$name" == "$current_disk" ]]; then
      echo "  $i) $name ($size) - $model [AKTUELL SYSTEM-DISK]" >&2
    else
      echo "  $i) $name ($size) - $model" >&2
    fi
    disks+=("$name"); ((i++))
  done < <(list_available_disks)
  (( ${#disks[@]} > 0 )) || die "Keine geeigneten Disks gefunden"
  if (( ${#disks[@]} == 1 )); then
    echo "[*] Nur eine Disk verfügbar: ${disks[0]}" >&2
    echo "${disks[0]}"; return 0
  fi
  echo >&2
  read -rp "Ziel-Disk auswählen (1-${#disks[@]}): " choice >&2
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#disks[@]} )) || die "Ungültige Auswahl: $choice"
  local selected="${disks[$((choice-1))]}"
  if [[ "$selected" == "$current_disk" ]]; then
    echo "⚠️  Du hast die aktuelle System-Disk ausgewählt!" >&2
    ask "Bist du sicher, dass du das System überschreiben willst?" || die "Abgebrochen"
  fi
  echo "$selected"
}

# === Backup-Ziel finden/mounten (case-insensitive Teilstring, per Device mounten) ===
SELECT_BACKUP=""
detect_backup_dir() {
  local label="${1:?}"
  need_cmd lsblk
  local query="${label^^}"

  # Kandidaten: NAME, LABEL, MOUNTPOINT, FSTYPE (nur Labels, die den String enthalten)
  mapfile -t CANDS < <(
    lsblk -rpn -o NAME,LABEL,MOUNTPOINT,FSTYPE \
    | awk -v Q="$query" 'toupper($2) ~ Q {printf "%s\t%s\t%s\t%s\n",$1,$2,$3,$4}'
  )
  (( ${#CANDS[@]} )) || return 1

  # 1) bereits gemountet & schreibbar?
  local line dev lab mp fs
  for line in "${CANDS[@]}"; do
    IFS=$'\t' read -r dev lab mp fs <<<"$line"
    if [[ -n "$mp" && -w "$mp" ]]; then
      echo "$mp"; return 0
    fi
  done

  # 2) Bei mehreren: Auswahl (wenn interaktiv oder SELECT_BACKUP)
  local pick=1
  if (( ${#CANDS[@]} > 1 )) && [[ -t 0 && -t 1 || -n "${SELECT_BACKUP:-}" ]]; then
    echo "[*] Mehrere mögliche Backup-Ziele gefunden (Label enthält: \"$label\"):" >&2
    local i=1
    for line in "${CANDS[@]}"; do
      IFS=$'\t' read -r dev lab mp fs <<<"$line"
      printf "  %d) %s  [LABEL=%s FSTYPE=%s]\n" "$i" "$dev" "${lab:-<none>}" "${fs:-?}" >&2
      ((i++))
    done
    read -rp "Backup-Ziel wählen (1-$((i-1))): " pick >&2
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<i )) || die "Ungültige Auswahl"
  fi

  # 3) Ausgewählten Kandidaten mounten (per Device, nicht per Label)
  IFS=$'\t' read -r dev lab mp fs <<<"${CANDS[$((pick-1))]}"
  local safe_lab="${lab//[^[:alnum:]\-_]/_}"; [[ -n "$safe_lab" ]] || safe_lab="panzerbackup"
  local target="/mnt/$safe_lab"
  mkdir -p "$target"

  if mount "$dev" "$target" 2>/dev/null; then
    echo "$target"; return 0
  fi
  if [[ -n "$fs" ]] && mount -t "$fs" "$dev" "$target" 2>/dev/null; then
    echo "$target"; return 0
  fi
  return 1
}

rotate_old() {
  local dir="${1:?}"; local keep="${2:?}"
  mapfile -t ALL < <(ls -1t \
    "$dir"/panzer_*.img "$dir"/panzer_*.img.zst \
    "$dir"/panzer_*.img.gpg "$dir"/panzer_*.img.zst.gpg 2>/dev/null || true)
  if (( ${#ALL[@]} > keep )); then
    for old in "${ALL[@]:$keep}"; do
      msg "  - Entferne alt: $old"
      rm -f "$old" "${old}.sha256" "${old%.img*}.sfdisk" 2>/dev/null || true
    done
  fi
}

find_latest_valid() {
  local dir="${1:?}"
  if [[ -L "$dir/LATEST_OK" ]]; then
    local t; t="$(readlink -f "$dir/LATEST_OK" || true)"; [[ -f "$t" ]] && echo "$t" && return 0
  fi
  mapfile -t IMGS < <(ls -1t \
    "$dir"/panzer_*.img.zst.gpg "$dir"/panzer_*.img.gpg \
    "$dir"/panzer_*.img.zst     "$dir"/panzer_*.img 2>/dev/null || true)
  for img in "${IMGS[@]:-}"; do
    [[ -f "${img}.sha256" ]] || continue
    msg "  - Prüfe $(basename "$img") ..."
    ( cd "$dir" && sha256sum -c "$(basename "$img").sha256" >/dev/null ) && { echo "$img"; return 0; }
  done
  return 1
}

find_latest_any() {
  local dir="${1:?}"
  ls -1t "$dir"/panzer_*.img.zst.gpg "$dir"/panzer_*.img.gpg "$dir"/panzer_*.img.zst "$dir"/panzer_*.img 2>/dev/null | head -n1 || true
}

# === zstd ggf. installieren ===
ensure_zstd_if_needed() {
  local want="$1"  # "on"|"auto"|"off"
  if [[ "$want" == "off" ]]; then return 0; fi
  if has_cmd zstd; then return 0; fi
  if [[ "$want" == "on" || "$want" == "auto" ]]; then
    msg "[*] zstd ist nicht installiert."
    if ask "Soll ich zstd automatisch installieren (apt)?"; then
      need_cmd apt-get
      DEBIAN_FRONTEND=noninteractive apt-get update -y || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y zstd || true
      if ! has_cmd zstd; then
        [[ "$want" == "on" ]] && die "Kompression gefordert, aber zstd konnte nicht installiert werden."
        msg "[!] zstd nicht verfügbar – fahre ohne Kompression fort."
      else
        msg "[✓] zstd installiert."
      fi
    else
      [[ "$want" == "on" ]] && die "Kompression gewünscht, aber zstd fehlt."
      msg "[!] zstd nicht installiert – fahre ohne Kompression fort."
    fi
  fi
}

# ===== Proxmox Quiesce (VMs/CTs) – QGA fsfreeze / suspend =====
declare -a RUN_QM RUN_CT FROZEN_QM SUSPENDED_QM

pve_quiesce_start() {
  FROZEN_QM=(); SUSPENDED_QM=()
  if ! has_cmd qm && ! has_cmd pct; then return 0; fi
  msg "[*] Proxmox erkannt – beginne Quiesce"

  if has_cmd qm; then
    mapfile -t RUN_QM < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}')
    for vm in "${RUN_QM[@]:-}"; do
      if qm agent "$vm" ping >/dev/null 2>&1; then
        msg "  - VM $vm: QGA ok → fsfreeze-freeze"
        if qm agent "$vm" fsfreeze-freeze >/dev/null 2>&1; then
          FROZEN_QM+=("$vm")
        else
          msg "    ! freeze fehlgeschlagen → fallback suspend"
          qm suspend "$vm" >/dev/null 2>&1 || true
          SUSPENDED_QM+=("$vm")
        fi
      else
        msg "  - VM $vm: kein QGA → suspend"
        qm suspend "$vm" >/dev/null 2>&1 || true
        SUSPENDED_QM+=("$vm")
      fi
    done
  fi

  if has_cmd pct; then
    mapfile -t RUN_CT < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
    for ct in "${RUN_CT[@]:-}"; do
      msg "  - CT $ct: freeze"
      pct freeze "$ct" >/dev/null 2>&1 || true
    done
  fi

  trap 'pve_quiesce_end' EXIT
}

pve_quiesce_end() {
  if has_cmd qm; then
    for vm in "${FROZEN_QM[@]:-}"; do
      msg "  - VM $vm: fsfreeze-thaw"
      qm agent "$vm" fsfreeze-thaw >/dev/null 2>&1 || true
    done
    for vm in "${SUSPENDED_QM[@]:-}"; do
      msg "  - VM $vm: resume"
      qm resume "$vm" >/dev/null 2>&1 || true
    done
  fi
  if has_cmd pct; then
    for ct in "${RUN_CT[@]:-}"; do
      msg "  - CT $ct: unfreeze"
      pct unfreeze "$ct" >/dev/null 2>&1 || true
    done
  fi
}

# ===== Auto-Detection =====
BACKUP_LABEL="${BACKUP_LABEL:-PANZERBACKUP}"
DISK="${DISK_OVERRIDE:-$(detect_system_disk || true)}"
[[ -b "${DISK:-}" ]] || die "Konnte Systemdisk nicht ermitteln"
SELECT_BACKUP="${SELECT_BACKUP:-""}"
BACKUP_DIR="$(detect_backup_dir "$BACKUP_LABEL" || true)"
[[ -d "${BACKUP_DIR:-}" && -w "$BACKUP_DIR" ]] || die "Backup-Platte mit Label $BACKUP_LABEL nicht gefunden/ nicht schreibbar"

# ===== Defaults / Optionen =====
KEEP="${KEEP:-3}"
DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
IMG_PREFIX="panzer_${DATE}"
COMPRESS_MODE="auto"
ZSTD_LEVEL="${ZSTD_LEVEL:-6}"
POST_ACTION="none"
POST_ACTION_PRESET=""
TARGET_DISK=""
RESTORE_DRY_RUN=""
SELECT_DISK=""
ENCRYPT_MODE="off"
ENCRYPT_PASSPHRASE=""

# ===== Prompts =====
prompt_post_action() {
  echo
  echo "Aktion NACH dem ${1:-Vorgang}?"
  echo "1) Nichts tun"
  echo "2) Neu starten"
  echo "3) Herunterfahren"
  read -rp "Auswahl (1/2/3): " pa
  case "$pa" in
    2) POST_ACTION="reboot" ;;
    3) POST_ACTION="shutdown" ;;
    *) POST_ACTION="none" ;;
  esac
  POST_ACTION_PRESET="1"
  msg "→ Post-Action: $POST_ACTION"
}

prompt_encryption() {
  if ask "Backup verschlüsseln (GnuPG AES-256)?"; then
    need_cmd gpg
    ENCRYPT_MODE="gpg"
    read -rsp "Passphrase: " p1; echo
    read -rsp "Passphrase wiederholen: " p2; echo
    [[ "$p1" == "$p2" ]] || die "Passphrasen stimmen nicht überein"
    ENCRYPT_PASSPHRASE="$p1"; unset p1 p2
    msg "→ Verschlüsselung: aktiv (gpg)"
  else
    ENCRYPT_MODE="off"
    msg "→ Verschlüsselung: aus"
  fi
}

# ===== Argument-Parser =====
parse_backup_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --compress)      COMPRESS_MODE="on"; shift ;;
      --no-compress)   COMPRESS_MODE="off"; shift ;;
      --zstd-level)    ZSTD_LEVEL="${2:-6}"; shift 2 ;;
      --post)          POST_ACTION="${2:-none}"; POST_ACTION_PRESET="1"; shift 2 ;;
      --encrypt)       ENCRYPT_MODE="gpg"; shift ;;
      --no-encrypt)    ENCRYPT_MODE="off"; shift ;;
      --passfile)      ENCRYPT_PASSPHRASE="$(<"$2")"; shift 2 ;;
      --select-backup) SELECT_BACKUP="true"; shift ;;
      --disk)          DISK="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  printf '%s\0' "$@"
}

parse_restore_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)       RESTORE_DRY_RUN="--dry-run"; shift ;;
      --target)        TARGET_DISK="$2"; shift 2 ;;
      --select-disk)   SELECT_DISK="true"; shift ;;
      --post)          POST_ACTION="${2:-none}"; POST_ACTION_PRESET="1"; shift 2 ;;
      --passfile)      ENCRYPT_PASSPHRASE="$(<"$2")"; shift 2 ;;
      --select-backup) SELECT_BACKUP="true"; shift ;;
      --disk)          DISK="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  printf '%s\0' "$@"
}

# ===== Backup =====
do_backup() {
  need_cmd dd; need_cmd sha256sum; need_cmd sfdisk
  ensure_zstd_if_needed "$COMPRESS_MODE"

  local use_compress="false"
  if [[ "$COMPRESS_MODE" == "on" ]]; then use_compress="true"
  elif [[ "$COMPRESS_MODE" == "auto" && $(has_cmd zstd && echo yes || echo no) == "yes" ]]; then use_compress="true"
  fi

  local final_file="${BACKUP_DIR}/${IMG_PREFIX}.img"
  [[ "$use_compress" == "true" ]] && final_file="${final_file}.zst"
  [[ "$ENCRYPT_MODE" == "gpg" ]] && final_file="${final_file}.gpg"
  local temp_file="${final_file}.part"
  local temp_sha="${final_file}.sha256.part"

  msg "=== $(date) | Starte Panzer-Backup von $DISK -> $final_file" | tee -a "$BACKUP_DIR/panzerbackup.log"

  pve_quiesce_start
  sfdisk -d "$DISK" > "${BACKUP_DIR}/${IMG_PREFIX}.sfdisk"

  set -o pipefail
  if [[ "$use_compress" == "true" && "$ENCRYPT_MODE" == "gpg" ]]; then
    msg "[*] dd | zstd | gpg | tee | sha256sum …"
    run_inhibited "Panzerbackup läuft" bash -c '
      dd if='"$DISK"' bs=64M status=progress 2>/dev/null \
      | zstd -T0 -'"$ZSTD_LEVEL"' -q \
      | gpg --batch --yes --symmetric --cipher-algo AES256 --pinentry-mode loopback --passphrase-fd 3 3<<<"'"$ENCRYPT_PASSPHRASE"'" \
      | tee "'"$temp_file"'" \
      | sha256sum -b \
      | awk '"'"'{print $1"  '"$(basename "$final_file")"'"}'"'"' > "'"$temp_sha"'"
    '
  elif [[ "$use_compress" == "true" ]]; then
    msg "[*] dd | zstd | tee | sha256sum …"
    run_inhibited "Panzerbackup läuft" bash -c '
      dd if='"$DISK"' bs=64M status=progress 2>/dev/null \
      | zstd -T0 -'"$ZSTD_LEVEL"' -q \
      | tee "'"$temp_file"'" \
      | sha256sum -b \
      | awk '"'"'{print $1"  '"$(basename "$final_file")"'"}'"'"' > "'"$temp_sha"'"
    '
  elif [[ "$ENCRYPT_MODE" == "gpg" ]]; then
    msg "[*] dd | gpg | tee | sha256sum …"
    run_inhibited "Panzerbackup läuft" bash -c '
      dd if='"$DISK"' bs=64M status=progress 2>/dev/null \
      | gpg --batch --yes --symmetric --cipher-algo AES256 --pinentry-mode loopback --passphrase-fd 3 3<<<"'"$ENCRYPT_PASSPHRASE"'" \
      | tee "'"$temp_file"'" \
      | sha256sum -b \
      | awk '"'"'{print $1"  '"$(basename "$final_file")"'"}'"'"' > "'"$temp_sha"'"
    '
  else
    msg "[*] dd (roh) | tee | sha256sum …"
    run_inhibited "Panzerbackup läuft" bash -c '
      dd if='"$DISK"' bs=64M status=progress 2>/dev/null \
      | tee "'"$temp_file"'" \
      | sha256sum -b \
      | awk '"'"'{print $1"  '"$(basename "$final_file")"'"}'"'"' > "'"$temp_sha"'"
    '
  fi
  set +o pipefail

  sync
  mv -f "$temp_file" "$final_file"
  mv -f "$temp_sha"  "${final_file}.sha256"

  msg "[✓] Datei: $(du -h "$final_file" | cut -f1)   Hash: $(cut -d' ' -f1 "${final_file}.sha256")"

  ln -sfn "$(basename "$final_file")"        "${BACKUP_DIR}/LATEST_OK"
  ln -sfn "$(basename "$final_file").sha256" "${BACKUP_DIR}/LATEST_OK.sha256"
  ln -sfn "panzer_${DATE}.sfdisk"            "${BACKUP_DIR}/LATEST_OK.sfdisk"

  rotate_old "$BACKUP_DIR" "$KEEP"
  msg "=== $(date) | Backup erfolgreich abgeschlossen ==="
  post_action_maybe "backup"

  ENCRYPT_PASSPHRASE=""
}

# ===== Verify =====
do_verify() {
  need_cmd sha256sum
  msg "=== $(date) | Prüfe letztes Backup ==="
  local CAND
  CAND="$(find_latest_any "$BACKUP_DIR" || true)"
  [[ -n "${CAND:-}" ]] || die "Keine Backup-Datei gefunden"
  msg "Datei: $(basename "$CAND") | Größe: $(du -h "$CAND" | cut -f1)"
  ( cd "$BACKUP_DIR" && sha256sum -c "$(basename "$CAND").sha256" )
  msg "=== Verify OK ==="
}

# ===== Restore =====
do_restore() {
  need_cmd dd; need_cmd sha256sum; need_cmd lsblk; need_cmd mount; need_cmd chroot

  local restore_disk="${DISK}"
  if [[ -n "${TARGET_DISK:-}" ]]; then
    restore_disk="$TARGET_DISK"; [[ -b "$restore_disk" ]] || die "Angegebene Ziel-Disk nicht gefunden: $restore_disk"
  elif [[ "${SELECT_DISK:-}" == "true" ]]; then
    restore_disk="$(select_target_disk "$DISK")"
  fi
  msg "=== $(date) | Starte Restore ${RESTORE_DRY_RUN:+(Dry-Run)} auf $restore_disk ==="

  local CANDIDATE; CANDIDATE="$(find_latest_valid "$BACKUP_DIR" || true)" || die "Kein gültiges Backup gefunden"
  msg "[✓] Verwende: $(basename "$CANDIDATE")"

  if [[ "$RESTORE_DRY_RUN" == "--dry-run" ]]; then
    msg "[DRY-RUN] Würde $(basename "$CANDIDATE") auf $restore_disk schreiben."
    return 0
  fi

  msg "⚠️  ALLE DATEN auf $restore_disk werden überschrieben!"
  ask "Willst du das Restore wirklich starten?" || { msg "Abbruch."; return 3; }

  set -o pipefail
  if [[ "$CANDIDATE" == *.gpg ]]; then
    need_cmd gpg
    if [[ -z "${ENCRYPT_PASSPHRASE:-}" ]]; then
      read -rsp "GPG-Passphrase für Restore: " ENCRYPT_PASSPHRASE; echo
    fi
    if [[ "$CANDIDATE" == *.zst.gpg ]]; then
      msg "[*] gpg -d | zstd -d | dd …"
      run_inhibited "Panzer-RESTORE läuft" bash -c \
        'gpg --batch --yes --decrypt --pinentry-mode loopback --passphrase-fd 3 3<<<"'"$ENCRYPT_PASSPHRASE"'" "'"$CANDIDATE"'" \
         | zstd -d -q \
         | dd of="'"$restore_disk"'" bs=64M status=progress conv=fsync'
    else
      msg "[*] gpg -d | dd …"
      run_inhibited "Panzer-RESTORE läuft" bash -c \
        'gpg --batch --yes --decrypt --pinentry-mode loopback --passphrase-fd 3 3<<<"'"$ENCRYPT_PASSPHRASE"'" "'"$CANDIDATE"'" \
         | dd of="'"$restore_disk"'" bs=64M status=progress conv=fsync'
    fi
    ENCRYPT_PASSPHRASE=""
  elif [[ "$CANDIDATE" == *.zst ]]; then
    need_cmd zstd
    msg "[*] zstd -d | dd …"
    run_inhibited "Panzer-RESTORE läuft" bash -c \
      'zstd -d -q "'"$CANDIDATE"'" \
       | dd of="'"$restore_disk"'" bs=64M status=progress conv=fsync'
  else
    msg "[*] dd (roh) …"
    run_inhibited "Panzer-RESTORE läuft" dd if="$CANDIDATE" of="$restore_disk" bs=64M status=progress conv=fsync
  fi
  set +o pipefail

  # Boot-Reparatur nur wenn auf Systemdisk restored
  if [[ "$restore_disk" == "$DISK" ]]; then
    msg "[*] Versuche GRUB zu erneuern …"
    local ROOT_CAND
    ROOT_CAND="$(lsblk -lnpo NAME,TYPE | awk '/lvm/ && /root/{print $1; exit}')"
    if [[ -z "$ROOT_CAND" ]]; then
      ROOT_CAND="$(lsblk -lnpo NAME,FSTYPE,SIZE,TYPE "$restore_disk" | awk '$2 ~ /ext4|xfs/ && $4=="part"{print $1,$3}' | sort -k2 -h | tail -n1 | awk '{print $1}')"
    fi
    if [[ -n "$ROOT_CAND" ]]; then
      local EFI_PART
      EFI_PART="$(lsblk -lnpo NAME,PARTLABEL,PARTTYPE "$restore_disk" | awk '/EFI|EF00|ESP/{print $1; exit}')"
      mkdir -p /mnt/restore
      mount "$ROOT_CAND" /mnt/restore || true
      if [[ -n "${EFI_PART:-}" ]]; then
        mkdir -p /mnt/restore/boot/efi
        mount "$EFI_PART" /mnt/restore/boot/efi || true
      fi
      for d in /dev /proc /sys; do mount --bind "$d" "/mnt/restore${d}"; done
      chroot /mnt/restore bash -c "grub-install $restore_disk || true; update-grub || true"
    else
      msg "[!] Root-Partition nicht sicher erkannt – GRUB-Reparatur übersprungen."
    fi
  else
    msg "[*] Restore auf anderer Disk – GRUB-Installation übersprungen."
  fi

  msg "[✓] Restore abgeschlossen."
  post_action_maybe "restore"
}

# ===== Post-Action =====
post_action_maybe() {
  local phase="$1"
  case "$POST_ACTION" in
    reboot)   msg "[*] Neustart in 5 Sekunden ..."; sleep 5; systemctl reboot ;;
    shutdown) msg "[*] Shutdown in 5 Sekunden ..."; sleep 5; systemctl poweroff ;;
    none|"")
              if [[ -z "${POST_ACTION_PRESET:-}" && -t 0 && -t 1 ]]; then
                echo; echo "Aktion nach $phase?"
                echo "1) Nichts tun"; echo "2) Neu starten"; echo "3) Herunterfahren"
                read -rp "Auswahl (1/2/3): " pa
                case "$pa$phase" in
                  2*) systemctl reboot ;;
                  3*) systemctl poweroff ;;
                  *)  : ;;
                esac
              fi
              ;;
  esac
}

print_usage() {
  cat <<USAGE
Detected:
  Systemdisk:  $DISK
  Backup-Ziel: $BACKUP_DIR

Usage:
  $0 backup  [--compress|--no-compress] [--zstd-level N] [--encrypt|--no-encrypt] [--passfile FILE] [--post reboot|shutdown|none] [--select-backup] [--disk /dev/XYZ]
  $0 restore [--dry-run] [--select-disk] [--target /dev/sdX] [--post reboot|shutdown|none] [--passfile FILE] [--select-backup] [--disk /dev/XYZ]
  $0 verify
  $0                                     # interaktives Menü

Hinweise:
- Proxmox-VMs: QGA → fsfreeze; sonst suspend. CTs: freeze.
- Backup-Ziel: Label case-insensitive **Teilstring** (z.B. "PANZERBACKUP" matcht "panzerbackup-pm").
- Dateien: .img[.zst][.gpg] + .sha256; LATEST_OK Symlink + .sfdisk.
USAGE
}

# ===== Einstieg =====
if [[ $# -gt 0 ]]; then
  case "$1" in
    backup)
      shift; REMAINS=($(parse_backup_flags "$@"))
      if [[ -t 0 && -t 1 ]]; then
        [[ -z "${POST_ACTION_PRESET:-}" ]] && prompt_post_action "Backup"
        if [[ "${ENCRYPT_MODE}" == "off" && -z "${ENCRYPT_PASSPHRASE}" ]]; then prompt_encryption; fi
      fi
      do_backup
      ;;
    restore)
      shift; REMAINS=($(parse_restore_flags "$@"))
      if [[ -t 0 && -t 1 && -z "${POST_ACTION_PRESET:-}" ]]; then
        prompt_post_action "Restore"
      fi
      do_restore
      ;;
    verify)
      do_verify
      ;;
    *)
      print_usage; exit 1 ;;
  esac
else
  echo "Systemdisk erkannt:  $DISK"
  echo "Backup-Ziel:         $BACKUP_DIR"
  echo "1) Backup (auto-Kompression, Inhibit-Schutz)"
  echo "2) Restore letztes gültiges Backup"
  echo "3) Restore (Dry-Run/Prüfung)"
  echo "4) Backup ohne Kompression"
  echo "5) Backup mit Kompression (zstd)"
  echo "6) Restore mit Disk-Auswahl"
  echo "7) Verify letztes Backup"
  read -rp "Auswahl (1/2/3/4/5/6/7): " choice
  case "$choice" in
    1) COMPRESS_MODE="auto";  prompt_post_action "Backup";  prompt_encryption; do_backup ;;
    2)                        prompt_post_action "Restore"; do_restore ;;
    3) RESTORE_DRY_RUN="--dry-run"; prompt_post_action "Restore"; do_restore ;;
    4) COMPRESS_MODE="off";   prompt_post_action "Backup";  prompt_encryption; do_backup ;;
    5) COMPRESS_MODE="on";    prompt_post_action "Backup";  prompt_encryption; do_backup ;;
    6) SELECT_DISK="true";    prompt_post_action "Restore"; do_restore ;;
    7) do_verify ;;
    *) echo "Ungültige Auswahl"; exit 1 ;;
  esac
fi
