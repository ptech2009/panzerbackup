#!/usr/bin/env bash
set -euo pipefail

VERSION="2.6.1"

# =====[ Sane defaults for env -i + set -u ]===================================
: "${LC_ALL:=C}"; export LC_ALL
: "${LANG:=C}";   export LANG
: "${PATH:=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"; export PATH
: "${HOME:=/root}"; export HOME

# ====== COLORS (nur interaktiv) ==============================================
if [[ -t 1 ]]; then
  R=$'\e[31m'
  G=$'\e[32m'
  Y=$'\e[33m'
  B=$'\e[34m'
  NC=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; NC=""
fi

# =====================[ Language Selection / Sprachwahl ]=====================
LANG_CHOICE="${LANG_CHOICE:-}"

if [[ -z "$LANG_CHOICE" && -t 0 && -t 1 ]]; then
  echo "Bitte Sprache wählen / Please select language:"
  echo "1) Deutsch"
  echo "2) English"
  read -rp "Auswahl / Choice (1/2): " _ch
  case "${_ch:-}" in
    1) LANG_CHOICE="de" ;;
    2) LANG_CHOICE="en" ;;
    *) LANG_CHOICE="en" ;;
  esac
elif [[ -z "$LANG_CHOICE" ]]; then
  LANG_CHOICE="en"
fi

M() {
  if [[ "$LANG_CHOICE" == "de" ]]; then echo -e "$1"; else echo -e "$2"; fi
}
ASK() {
  local qd="$1" qe="$2" ans
  if [[ "$LANG_CHOICE" == "de" ]]; then
    read -r -p "$qd [j/N]: " ans
    [[ "${ans:-}" =~ ^([JjYy])$ ]]
  else
    read -r -p "$qe [y/N]: " ans
    [[ "${ans:-}" =~ ^([YyJj])$ ]]
  fi
}
die() { M "❌ $1" "❌ $2" >&2; exit 1; }
msg() { M "$1" "$2"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Benötigtes Kommando fehlt: $1" "Required command missing: $1"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# =====================[ Status-Tracking ]=====================================
RUN_DIR="${RUN_DIR:-/run/panzerbackup}"
mkdir -p "$RUN_DIR"
STATUS_FILE="${STATUS_FILE:-$RUN_DIR/status}"
PID_FILE="${PID_FILE:-$RUN_DIR/pid}"
STARTUP_LOG="${STARTUP_LOG:-$RUN_DIR/startup.log}"
WORKER_SCRIPT="${WORKER_SCRIPT:-$RUN_DIR/worker.sh}"
START_TS_FILE="${START_TS_FILE:-$RUN_DIR/start_ts}"

set_status() { echo "$1" > "$STATUS_FILE"; }
mark_run_started() { date +%s > "$START_TS_FILE"; }
get_elapsed_seconds() {
  if [[ -f "$START_TS_FILE" ]]; then
    local now start
    now="$(date +%s)"
    start="$(cat "$START_TS_FILE" 2>/dev/null || true)"
    [[ "$start" =~ ^[0-9]+$ ]] || return 1
    echo $(( now - start ))
    return 0
  fi
  return 1
}
format_elapsed() {
  local sec="${1:-0}"
  printf '%02d:%02d:%02d' $((sec/3600)) $(((sec%3600)/60)) $((sec%60))
}
localize_status_text() {
  local s="${1:-}"

  if [[ "$LANG_CHOICE" == "en" ]]; then
    s="${s//Proxmox VMs\/CTs werden pausiert.../Pausing Proxmox VMs\/CTs...}"
    s="${s//VMs\/CTs werden fortgesetzt.../Resuming VMs\/CTs...}"
    s="${s//Erstelle Partitionstabelle.../Creating partition table...}"
    s="${s//Kopiere Disk-Image.../Copying disk image...}"
    s="${s//Räume alte Backups auf.../Cleaning up old backups...}"
    s="${s//Prüfe Checksumme.../Verifying checksum...}"
    s="${s//Verwende /Using }"
    s="${s//Dry-Run abgeschlossen/Dry-run completed}"
    s="${s//Erfolgreich abgeschlossen/Completed successfully}"
    s="${s//Initialisiere.../Initializing...}"
    s="${s//Finalisiere.../Finalizing...}"
    s="${s//Abgebrochen/Aborted}"
    s="${s//FEHLER:/ERROR:}"
    s="${s// läuft.../ running...}"
    s="${s// läuft/ running}"
  else
    s="${s//Pausing Proxmox VMs\/CTs.../Proxmox VMs\/CTs werden pausiert...}"
    s="${s//Resuming VMs\/CTs.../VMs\/CTs werden fortgesetzt...}"
    s="${s//Creating partition table.../Erstelle Partitionstabelle...}"
    s="${s//Copying disk image.../Kopiere Disk-Image...}"
    s="${s//Cleaning up old backups.../Räume alte Backups auf...}"
    s="${s//Verifying checksum.../Prüfe Checksumme...}"
    s="${s//Using /Verwende }"
    s="${s//Dry-run completed/Dry-Run abgeschlossen}"
    s="${s//Completed successfully/Erfolgreich abgeschlossen}"
    s="${s//Initializing.../Initialisiere...}"
    s="${s//Finalizing.../Finalisiere...}"
    s="${s//Aborted/Abgebrochen}"
    s="${s//ERROR:/FEHLER:}"
    s="${s// running.../ läuft...}"
    s="${s// running/ läuft}"
  fi

  echo "$s"
}
get_status() {
  if [[ -s "$STATUS_FILE" ]]; then
    localize_status_text "$(tail -n1 "$STATUS_FILE")"
  else
    [[ "$LANG_CHOICE" == "en" ]] && echo "Initializing..." || echo "Initialisiere..."
  fi
}
get_status_formatted() {
  local s; s="$(get_status)"
  if [[ "$s" == *"FEHLER"* || "$s" == *"ERROR"* || "$s" == *"failed"* || "$s" == *"abgebrochen"* || "$s" == *"aborted"* ]]; then
    echo "${R}${s}${NC}"
  elif [[ "$s" == *"Erfolgreich"* || "$s" == *"completed successfully"* || "$s" == *"Erfolgreich abgeschlossen"* || "$s" == *"Backup completed"* ]]; then
    echo "${G}${s}${NC}"
  elif [[ "$s" == *"BACKUP"* || "$s" == *"RESTORE"* || "$s" == *"dd"* || "$s" == *"zstd"* || "$s" == *"gpg"* || "$s" == *"Finalizing"* || "$s" == *"Finalisiere"* ]]; then
    echo "${Y}${s}${NC}"
  else
    echo "$s"
  fi
}
clear_status_for_new_run() { : > "$STATUS_FILE"; rm -f "$START_TS_FILE"; }

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || { rm -f "$PID_FILE"; return 1; }

  if ps -p "$pid" >/dev/null 2>&1 || pgrep -P "$pid" >/dev/null 2>&1; then
    return 0
  fi
  rm -f "$PID_FILE"
  return 1
}

# =====================[ Anzeige/Performance ]=================================
LIVE_LOG_LINES="${LIVE_LOG_LINES:-20}"
LOG_VIEW_LINES_DEFAULT="${LOG_VIEW_LINES_DEFAULT:-100}"
MENU_REFRESH_SECONDS="${MENU_REFRESH_SECONDS:-2}"

# =====================[ Power inhibit ]=======================================
run_inhibited() {
  local why="${1:?}"; shift
  if has_cmd systemd-inhibit; then
    systemd-inhibit --what=handle-lid-switch:sleep:idle --why="$why" "$@"
  else
    "$@"
  fi
}

# =====================[ Live / Source Detection ]=============================
detect_live_environment() {
  local fstype src
  fstype="$(findmnt -no FSTYPE / 2>/dev/null || true)"
  src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ "$fstype" =~ ^(overlay|squashfs|aufs)$ ]] && return 0
  [[ "$src" =~ (^overlay$|^/dev/loop|casper|live) ]] && return 0
  [[ -d /run/live/medium || -d /cdrom || -f /usr/lib/live/config/0000-root ]] && return 0
  return 1
}

get_mount_backing_disk() {
  local mp="${1:?}"
  local src cur typ pk
  src="$(findmnt -no SOURCE --target "$mp" 2>/dev/null || true)"
  [[ -n "$src" ]] || return 1

  if [[ "$src" =~ ^/dev/ && -b "$src" ]]; then
    cur="$src"
  elif [[ -e "/dev/mapper/$src" ]]; then
    cur="/dev/mapper/$src"
  elif [[ -e "/dev/$src" ]]; then
    cur="/dev/$src"
  else
    return 1
  fi

  for _ in {1..16}; do
    typ="$(lsblk -rno TYPE "$cur" 2>/dev/null || true)"
    [[ "$typ" == "disk" ]] && { echo "$cur"; return 0; }
    pk="$(lsblk -rno PKNAME "$cur" 2>/dev/null || true)"
    [[ -n "$pk" ]] || break
    cur="/dev/$pk"
  done
  return 1
}

# =====================[ Systemdisk-Erkennung ]================================
detect_system_disk() {
  need_cmd lsblk; need_cmd awk
  local root_dev
  root_dev="$(lsblk -rpn -o NAME,MOUNTPOINT | awk '$2=="/"{print $1; exit}')"

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

  if [[ -z "$root_dev" || ! -e "$root_dev" ]]; then
    root_dev="$(lsblk -rpn -o NAME,TYPE,MOUNTPOINT | awk '$2=="part" && $3=="/"{print $1; exit}')"
  fi
  [[ -n "$root_dev" && -e "$root_dev" ]] || { msg "[detect] Root-Gerät unbekannt" "[detect] Root device unknown"; return 1; }

  local topdisk
  topdisk="$(lsblk -rpnso NAME,TYPE -s "$root_dev" 2>/dev/null | awk '$2=="disk"{last=$1} END{if(last) print last}')"
  if [[ -n "$topdisk" && -b "$topdisk" ]]; then echo "$topdisk"; return 0; fi

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

# =====================[ Disk-Auswahl ]========================================
list_available_disks() {
  need_cmd lsblk
  lsblk -dnpo NAME,SIZE,MODEL,TYPE | while IFS= read -r line; do
    if [[ "$line" =~ disk$ ]] && [[ ! "$line" =~ ^/dev/(loop|sr|ram) ]]; then
      local name size model
      name=$(echo "$line" | awk '{print $1}')
      size=$(echo "$line" | awk '{print $2}')
      model=$(echo "$line" | awk '{for(i=3;i<NF;i++) printf "%s ", $i; if(NF>=3) print $NF; else print "Unknown"}')
      [[ -z "$model" || "$model" == " " ]] && model="Unknown"
      echo "$name|$size|$model"
    fi
  done
}

disk_is_protected() {
  local disk="$1" item
  for item in ${PROTECTED_DISKS:-}; do
    [[ "$disk" == "$item" ]] && return 0
  done
  return 1
}

select_target_disk() {
  local current_disk="${1:-}"
  local disks=()
  if [[ "${LIVE_ENV:-0}" -eq 1 ]]; then
    msg "[*] Live-System erkannt – Restore nur auf interne Offline-Zieldisk erlaubt" "[*] Live system detected – restore allowed only to an internal offline target disk" >&2
    echo >&2
  fi
  msg "[*] Verfügbare Disks:" "[*] Available disks:" >&2
  local i=1
  while IFS='|' read -r name size model; do
    local mark=""
    if [[ -n "$current_disk" && "$name" == "$current_disk" ]]; then
      mark="[AKTUELL SYSTEM-DISK / CURRENT SYSTEM DISK]"
    fi
    if [[ -n "${SCRIPT_SOURCE_DISK:-}" && "$name" == "$SCRIPT_SOURCE_DISK" ]]; then
      mark="${mark:+$mark }[SKRIPT LÄUFT VON DIESER DISK / SCRIPT RUNS FROM THIS DISK]"
    fi
    if disk_is_protected "$name"; then
      mark="${mark:+$mark }[GESCHÜTZT / PROTECTED]"
    fi
    if [[ -n "$mark" ]]; then
      echo "  $i) $name ($size) - $model $mark" >&2
    else
      echo "  $i) $name ($size) - $model" >&2
    fi
    disks+=("$name"); ((i++))
  done < <(list_available_disks)
  (( ${#disks[@]} > 0 )) || die "Keine geeigneten Disks gefunden" "No suitable disks found"

  echo >&2
  if [[ "$LANG_CHOICE" == "de" ]]; then
    read -r -p "Ziel-Disk auswählen (1-${#disks[@]}): " choice </dev/tty >/dev/tty
  else
    read -r -p "Select target disk (1-${#disks[@]}): " choice </dev/tty >/dev/tty
  fi
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#disks[@]} )) || die "Ungültige Auswahl: $choice" "Invalid selection: $choice"

  local selected="${disks[$((choice-1))]}"
  if [[ -n "${SCRIPT_SOURCE_DISK:-}" && "$selected" == "$SCRIPT_SOURCE_DISK" ]]; then
    die "Restore auf $selected ist gesperrt: Das Skript läuft von dieser Disk. Bitte von Live-USB oder anderem Medium booten." "Restore to $selected is blocked: the script is running from this disk. Please boot from live USB or another medium."
  fi
  if disk_is_protected "$selected"; then
    die "Die gewählte Disk ist geschützt (Live-USB oder Backup-Medium): $selected" "The selected disk is protected (live USB or backup medium): $selected"
  fi
  if [[ -n "$current_disk" && "$selected" == "$current_disk" ]]; then
    die "Restore auf $selected ist gesperrt: Das aktuell laufende System verwendet diese Disk. Bitte offline von Live-USB booten und erneut versuchen." "Restore to $selected is blocked: the currently running system uses this disk. Please boot offline from live USB and try again."
  fi
  printf '%s
' "$selected"
}

# =====================[ Backup-Ziel ]=========================================
SELECT_BACKUP=""
detect_backup_dir() {
  local label="${1:?}"
  need_cmd lsblk
  local query="${label^^}"

  mapfile -t CANDS < <(
    lsblk -rpn -o NAME,LABEL,MOUNTPOINT,FSTYPE \
    | awk -v Q="$query" 'toupper($2) ~ Q {printf "%s\t%s\t%s\t%s\n",$1,$2,$3,$4}'
  )
  (( ${#CANDS[@]} )) || return 1

  local line dev lab mp fs
  for line in "${CANDS[@]}"; do
    IFS=$'\t' read -r dev lab mp fs <<<"$line"
    if [[ -n "$mp" && -w "$mp" ]]; then
      echo "$mp"
      return 0
    fi
  done

  local pick=1
  if (( ${#CANDS[@]} > 1 )) && [[ -t 0 && -t 1 || -n "${SELECT_BACKUP:-}" ]]; then
    M "[*] Mehrere mögliche Backup-Ziele gefunden (Label enthält: \"$label\"):" \
      "[*] Multiple candidate backup targets found (label contains: \"$label\"):"
    local i=1
    for line in "${CANDS[@]}"; do
      IFS=$'\t' read -r dev lab mp fs <<<"$line"
      printf "  %d) %s  [LABEL=%s FSTYPE=%s]\n" "$i" "$dev" "${lab:-<none>}" "${fs:-?}"
      ((i++))
    done
    if [[ "$LANG_CHOICE" == "de" ]]; then
      read -rp "Backup-Ziel wählen (1-$((i-1))): " pick
    else
      read -rp "Select backup target (1-$((i-1))): " pick
    fi
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<i )) || die "Ungültige Auswahl" "Invalid selection"
  fi

  IFS=$'\t' read -r dev lab mp fs <<<"${CANDS[$((pick-1))]}"
  local safe_lab="${lab//[^[:alnum:]\-_]/_}"; [[ -n "$safe_lab" ]] || safe_lab="panzerbackup"
  local target="/mnt/$safe_lab"
  mkdir -p "$target"

  if mount "$dev" "$target" 2>/dev/null; then echo "$target"; return 0; fi
  if [[ -n "$fs" ]] && mount -t "$fs" "$dev" "$target" 2>/dev/null; then echo "$target"; return 0; fi
  return 1
}

# =====================[ Backup-Name ]=========================================
prompt_backup_name() {
  local default_name="$1"
  if [[ -n "${BACKUP_NAME:-}" ]]; then
    echo "$BACKUP_NAME"
    return 0
  fi

  if [[ -t 0 && -t 1 ]]; then
    echo
    if [[ "$LANG_CHOICE" == "de" ]]; then
      read -rp "Backup-Name eingeben (z.B. 'proxmox-host1') [Standard: $default_name]: " input_name
    else
      read -rp "Enter backup name (e.g. 'proxmox-host1') [Default: $default_name]: " input_name
    fi

    if [[ -z "$input_name" ]]; then
      echo "$default_name"
    else
      local sanitized="${input_name//[^[:alnum:]\-_]/}"
      if [[ "$sanitized" != "$input_name" ]]; then
        M "[!] Name wurde bereinigt: $input_name → $sanitized" \
          "[!] Name was sanitized: $input_name → $sanitized"
      fi
      echo "$sanitized"
    fi
  else
    echo "$default_name"
  fi
}

# =====================[ Latest Backup Finder ]================================
list_candidate_backups() {
  local dir="${1:?}"
  ls -1t \
    "$dir"/panzer_*.img.zst.gpg "$dir"/panzer_*.img.gpg \
    "$dir"/panzer_*.img.zst "$dir"/panzer_*.img 2>/dev/null || true
}

select_backup_file() {
  local dir="${1:?}"
  local backups=()
  local i=1
  mapfile -t backups < <(list_candidate_backups "$dir")
  (( ${#backups[@]} > 0 )) || die "Keine Backup-Dateien gefunden" "No backup files found"

  msg "[*] Verfügbare Backup-Dateien:" "[*] Available backup files:" >&2
  for b in "${backups[@]}"; do
    local tag=""
    [[ -f "${b}.sha256" ]] && tag="[sha256]"
    echo "  $i) $(basename "$b") $tag" >&2
    ((i++))
  done
  echo >&2
  if [[ "$LANG_CHOICE" == "de" ]]; then
    read -r -p "Backup auswählen (1-${#backups[@]}): " choice </dev/tty >/dev/tty
  else
    read -r -p "Select backup (1-${#backups[@]}): " choice </dev/tty >/dev/tty
  fi
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#backups[@]} )) || die "Ungültige Auswahl: $choice" "Invalid selection: $choice"
  printf '%s
' "${backups[$((choice-1))]}"
}

find_latest_valid() {
  local dir="${1:?}"
  if [[ -L "$dir/LATEST_OK" ]]; then
    local t; t="$(readlink -f "$dir/LATEST_OK" || true)"
    [[ -f "$t" ]] && echo "$t" && return 0
  fi
  mapfile -t IMGS < <(ls -1t \
    "$dir"/panzer_*.img.zst.gpg "$dir"/panzer_*.img.gpg \
    "$dir"/panzer_*.img.zst "$dir"/panzer_*.img 2>/dev/null || true)
  for img in "${IMGS[@]:-}"; do
    [[ -f "${img}.sha256" ]] || continue
    M "  - Prüfe $(basename "$img") ..." "  - Checking $(basename "$img") ..."
    ( cd "$dir" && sha256sum -c "$(basename "$img").sha256" >/dev/null ) && { echo "$img"; return 0; }
  done
  return 1
}
find_latest_any() {
  local dir="${1:?}"
  ls -1t "$dir"/panzer_*.img.zst.gpg "$dir"/panzer_*.img.gpg "$dir"/panzer_*.img.zst "$dir"/panzer_*.img 2>/dev/null | head -n1 || true
}

# =====================[ zstd ensure ]=========================================
ensure_zstd_if_needed() {
  local want="$1"
  [[ "$want" == "off" ]] && return 0
  has_cmd zstd && return 0
  if [[ "$want" == "on" || "$want" == "auto" ]]; then
    msg "[*] zstd ist nicht installiert." "[*] zstd is not installed."
    if ASK "Soll ich zstd automatisch installieren (apt)?" "Install zstd automatically (apt)?"; then
      need_cmd apt-get
      DEBIAN_FRONTEND=noninteractive apt-get update -y || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y zstd || true
      if ! has_cmd zstd; then
        [[ "$want" == "on" ]] && die "Kompression gefordert, aber zstd konnte nicht installiert werden." "Compression required, but zstd could not be installed."
        msg "[!] zstd nicht verfügbar – fahre ohne Kompression fort." "[!] zstd not available – continuing without compression."
      else
        msg "[✓] zstd installiert." "[✓] zstd installed."
      fi
    else
      [[ "$want" == "on" ]] && die "Kompression gewünscht, aber zstd fehlt." "Compression requested, but zstd is missing."
      msg "[!] zstd nicht installiert – fahre ohne Kompression fort." "[!] zstd not installed – continuing without compression."
    fi
  fi
}

# =====================[ Platzprüfung ]========================================
get_free_bytes() {
  need_cmd df
  df -PB1 "$BACKUP_DIR" | awk 'NR==2 {print $4}'
}

human_bytes() {
  local n="${1:-0}"
  if has_cmd numfmt; then
    numfmt --to=iec-i --suffix=B "$n"
  else
    echo "${n} bytes"
  fi
}

estimate_required_backup_bytes() {
  need_cmd blockdev
  local raw_size
  raw_size="$(blockdev --getsize64 "$DISK")"
  echo $(( raw_size + MIN_FREE_BYTES ))
}

list_existing_backups_oldest_first() {
  ls -1tr \
    "$BACKUP_DIR"/panzer_*.img \
    "$BACKUP_DIR"/panzer_*.img.zst \
    "$BACKUP_DIR"/panzer_*.img.gpg \
    "$BACKUP_DIR"/panzer_*.img.zst.gpg 2>/dev/null || true
}

cleanup_stale_partial_files() {
  msg "[*] Prüfe auf alte unvollständige Backup-Dateien (*.part) ..." \
      "[*] Checking for stale partial backup files (*.part) ..."
  find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.part" -o -name "*.sha256.part" \) -print 2>/dev/null | while read -r f; do
    [[ -n "$f" ]] || continue
    msg "  - Entferne unvollständige Datei: $(basename "$f")" \
        "  - Removing incomplete file: $(basename "$f")"
    rm -f -- "$f"
  done
}

refresh_latest_ok_links() {
  local newest_valid=""
  newest_valid="$(find_latest_valid "$BACKUP_DIR" || true)"
  if [[ -n "$newest_valid" && -f "$newest_valid" ]]; then
    local base="${newest_valid##*/}"
    local sfdisk_file="${base%.img*}.sfdisk"
    ln -sfn "$base" "${BACKUP_DIR}/LATEST_OK"
    [[ -f "${BACKUP_DIR}/${base}.sha256" ]] && ln -sfn "${base}.sha256" "${BACKUP_DIR}/LATEST_OK.sha256" || rm -f "${BACKUP_DIR}/LATEST_OK.sha256"
    [[ -f "${BACKUP_DIR}/${sfdisk_file}" ]] && ln -sfn "${sfdisk_file}" "${BACKUP_DIR}/LATEST_OK.sfdisk" || rm -f "${BACKUP_DIR}/LATEST_OK.sfdisk"
  else
    rm -f "${BACKUP_DIR}/LATEST_OK" "${BACKUP_DIR}/LATEST_OK.sha256" "${BACKUP_DIR}/LATEST_OK.sfdisk"
  fi
}

remove_backup_with_metadata() {
  local old="${1:?}"
  [[ -f "$old" ]] || return 0
  local old_base old_sfdisk latest_target
  old_base="$(basename "$old")"
  old_sfdisk="${old_base%.img*}.sfdisk"
  latest_target=""
  if [[ -L "${BACKUP_DIR}/LATEST_OK" ]]; then
    latest_target="$(basename "$(readlink -f "${BACKUP_DIR}/LATEST_OK" 2>/dev/null || true)")"
  fi
  rm -f -- "$old" "${old}.sha256" "${BACKUP_DIR}/${old_sfdisk}"
  if [[ "$latest_target" == "$old_base" ]]; then
    refresh_latest_ok_links
  fi
}

cleanup_oldest_backups_until_enough_space() {
  local required free
  required="$(estimate_required_backup_bytes)"
  free="$(get_free_bytes)"

  msg "[*] Freier Speicher auf Backup-Ziel: $(human_bytes "$free")" \
      "[*] Free space on backup target: $(human_bytes "$free")"
  msg "[*] Benötigt (Rohgröße Disk + Reserve): $(human_bytes "$required")" \
      "[*] Required (raw disk size + reserve): $(human_bytes "$required")"

  if (( free >= required )); then
    msg "[✓] Genug Speicherplatz vorhanden." "[✓] Enough free space available."
    return 0
  fi

  [[ "$AUTO_DELETE_OLDEST" == "1" ]] || \
    die "Zu wenig Speicherplatz auf dem Backup-Ziel und automatisches Löschen ist deaktiviert." \
        "Not enough free space on backup target and automatic deletion is disabled."

  msg "[!] Zu wenig Speicherplatz. Älteste Backups werden automatisch entfernt..." \
      "[!] Not enough free space. Oldest backups will be deleted automatically..."

  local old free_now
  mapfile -t OLD_BACKUPS < <(list_existing_backups_oldest_first)
  (( ${#OLD_BACKUPS[@]} > 0 )) || \
    die "Kein altes Backup zum Löschen vorhanden, aber zu wenig Speicherplatz." \
        "No old backup available for deletion, but there is not enough free space."

  for old in "${OLD_BACKUPS[@]}"; do
    [[ -f "$old" ]] || continue
    msg "  - Lösche altes Backup: $(basename "$old")" \
        "  - Deleting old backup: $(basename "$old")"
    remove_backup_with_metadata "$old"
    free_now="$(get_free_bytes)"
    msg "    → Freier Speicher jetzt: $(human_bytes "$free_now")" \
        "    → Free space now: $(human_bytes "$free_now")"
    if (( free_now >= required )); then
      msg "[✓] Genug Speicherplatz freigeräumt." "[✓] Enough free space has been freed."
      return 0
    fi
  done

  free_now="$(get_free_bytes)"
  die "Trotz Löschen alter Backups nicht genug Speicher frei. Frei: $(human_bytes "$free_now"), benötigt: $(human_bytes "$required")" \
      "Still not enough free space after deleting old backups. Free: $(human_bytes "$free_now"), required: $(human_bytes "$required")"
}

# =====================[ Defaults ]============================================
BACKUP_LABEL="${BACKUP_LABEL:-PANZERBACKUP}"
LIVE_ENV=0
LIVE_ROOT_DISK=""
if detect_live_environment; then
  LIVE_ENV=1
  LIVE_ROOT_DISK="$(get_mount_backing_disk / 2>/dev/null || true)"
fi

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
SCRIPT_SOURCE_DISK="$(get_mount_backing_disk "$SCRIPT_PATH" 2>/dev/null || true)"

DISK="${DISK_OVERRIDE:-$(detect_system_disk || true)}"
if [[ -z "${DISK:-}" && "$LIVE_ENV" -eq 0 ]]; then
  die "Konnte Systemdisk nicht ermitteln" "Could not determine system disk"
fi

RUNNING_SYSTEM_DISK="${LIVE_ROOT_DISK:-${DISK:-}}"

BACKUP_DIR="$(detect_backup_dir "$BACKUP_LABEL" || true)"
[[ -d "${BACKUP_DIR:-}" && -w "${BACKUP_DIR:-}" ]] || die "Backup-Platte mit Label $BACKUP_LABEL nicht gefunden/ nicht schreibbar" "Backup drive with label $BACKUP_LABEL not found / not writable"

BACKUP_DISK="$(get_mount_backing_disk "$BACKUP_DIR" 2>/dev/null || true)"
PROTECTED_DISKS="${BACKUP_DISK:-} ${LIVE_ROOT_DISK:-} ${SCRIPT_SOURCE_DISK:-}"

KEEP="${KEEP:-3}"
MIN_FREE_BYTES="${MIN_FREE_BYTES:-2147483648}"
AUTO_DELETE_OLDEST="${AUTO_DELETE_OLDEST:-1}"
DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
BACKUP_NAME="${BACKUP_NAME:-}"
IMG_PREFIX=""
COMPRESS_MODE="auto"
ZSTD_LEVEL="${ZSTD_LEVEL:-6}"
POST_ACTION="none"
POST_ACTION_PRESET=""
TARGET_DISK=""
RESTORE_DRY_RUN=""
SELECT_DISK=""
ENCRYPT_MODE="off"
ENCRYPT_PASSPHRASE=""

USE_COMPRESS=""
FINAL_FILE=""
TEMP_FILE=""
TEMP_SHA=""
LOG_FILE_DEFAULT="${BACKUP_DIR}/panzerbackup.log"

if [[ "$LIVE_ENV" -eq 1 ]]; then
  msg "[*] Live-System erkannt. Restore-Zieldisk wird nicht automatisch aus / ermittelt." "[*] Live system detected. Restore target disk will not be auto-detected from /."
  [[ -n "${LIVE_ROOT_DISK:-}" ]] && msg "[*] Live-USB geschützt: $LIVE_ROOT_DISK" "[*] Live USB protected: $LIVE_ROOT_DISK"
  [[ -n "${BACKUP_DISK:-}" ]] && msg "[*] Backup-Medium geschützt: $BACKUP_DISK" "[*] Backup medium protected: $BACKUP_DISK"
fi
[[ -n "${RUNNING_SYSTEM_DISK:-}" ]] && msg "[*] Laufende System-Disk: $RUNNING_SYSTEM_DISK" "[*] Running system disk: $RUNNING_SYSTEM_DISK"
[[ -n "${SCRIPT_SOURCE_DISK:-}" ]] && msg "[*] Skript-Quelle geschützt: $SCRIPT_SOURCE_DISK" "[*] Script source disk protected: $SCRIPT_SOURCE_DISK"

# =====================[ Prompts ]============================================
prompt_post_action() {
  echo
  if [[ "$LANG_CHOICE" == "de" ]]; then
    echo "Aktion NACH dem ${1:-Vorgang}?"
    echo "1) Nichts tun"; echo "2) Neu starten"; echo "3) Herunterfahren"
    read -rp "Auswahl (1/2/3): " pa
  else
    echo "Action AFTER ${1:-operation}?"
    echo "1) Do nothing"; echo "2) Reboot"; echo "3) Shutdown"
    read -rp "Choice (1/2/3): " pa
  fi
  case "$pa" in
    2) POST_ACTION="reboot" ;;
    3) POST_ACTION="shutdown" ;;
    *) POST_ACTION="none" ;;
  esac
  POST_ACTION_PRESET="1"
  msg "→ Post-Action: $POST_ACTION" "→ Post-action: $POST_ACTION"
}

prompt_encryption() {
  if ASK "Backup verschlüsseln (GnuPG AES-256)?" "Encrypt backup (GnuPG AES-256)?"; then
    need_cmd gpg
    ENCRYPT_MODE="gpg"
    if [[ "$LANG_CHOICE" == "de" ]]; then
      read -rsp "Passphrase: " p1; echo
      read -rsp "Passphrase wiederholen: " p2; echo
    else
      read -rsp "Passphrase: " p1; echo
      read -rsp "Repeat passphrase: " p2; echo
    fi
    [[ "$p1" == "$p2" ]] || die "Passphrasen stimmen nicht überein" "Passphrases do not match"
    ENCRYPT_PASSPHRASE="$p1"; unset p1 p2
    msg "→ Verschlüsselung: aktiv (gpg)" "→ Encryption: enabled (gpg)"
  else
    ENCRYPT_MODE="off"
    msg "→ Verschlüsselung: aus" "→ Encryption: off"
  fi
}

# =====================[ Arg Parser ]=========================================
parse_backup_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      resume-orphans) resume_orphans; exit 0 ;;
      stop) do_stop; exit 0 ;;
      --compress) COMPRESS_MODE="on"; shift ;;
      --no-compress) COMPRESS_MODE="off"; shift ;;
      --zstd-level) ZSTD_LEVEL="${2:-6}"; shift 2 ;;
      --post) POST_ACTION="${2:-none}"; POST_ACTION_PRESET="1"; shift 2 ;;
      --encrypt) ENCRYPT_MODE="gpg"; shift ;;
      --no-encrypt) ENCRYPT_MODE="off"; shift ;;
      --passfile) ENCRYPT_PASSPHRASE="$(<"$2")"; shift 2 ;;
      --select-backup) SELECT_BACKUP="true"; shift ;;
      --disk) DISK="$2"; shift 2 ;;
      --name) BACKUP_NAME="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  printf '%s\0' "$@"
}
parse_restore_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) RESTORE_DRY_RUN="--dry-run"; shift ;;
      --target) TARGET_DISK="$2"; shift 2 ;;
      --select-disk) SELECT_DISK="true"; shift ;;
      --post) POST_ACTION="${2:-none}"; POST_ACTION_PRESET="1"; shift 2 ;;
      --passfile) ENCRYPT_PASSPHRASE="$(<"$2")"; shift 2 ;;
      --select-backup) SELECT_BACKUP="true"; shift ;;
      --disk) DISK="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  printf '%s\0' "$@"
}

# =====================[ Log ]================================================
do_log() {
  local file="${1:-$LOG_FILE_DEFAULT}"
  local lines="${2:-$LOG_VIEW_LINES_DEFAULT}"
  if [[ ! -f "$file" ]]; then
    msg "(Kein Log vorhanden unter $file)" "(No log present at $file)"
    return 1
  fi
  tail -n "$lines" "$file"
}

view_log() {
  { clear 2>/dev/null || printf '\033c'; } || true
  echo "=========================================="
  msg "                Log-Ansicht" "                Log viewer"
  echo "=========================================="
  echo ""
  if [[ ! -f "$LOG_FILE_DEFAULT" ]]; then
    msg "${R}Kein Logfile gefunden: $LOG_FILE_DEFAULT${NC}" "${R}No log file found: $LOG_FILE_DEFAULT${NC}"
  else
    msg "Zeige die letzten ${LOG_VIEW_LINES_DEFAULT} Zeilen von:" "Showing last ${LOG_VIEW_LINES_DEFAULT} lines of:"
    echo "  $LOG_FILE_DEFAULT"
    echo "------------------------------------------"
    tail -n "$LOG_VIEW_LINES_DEFAULT" "$LOG_FILE_DEFAULT"
  fi
  echo "------------------------------------------"
  if [[ "${LANG_CHOICE}" == "en" ]]; then read -rp "Press Enter to return..." _ || true
  else read -rp "Drücke Enter um zurückzukehren..." _ || true; fi
}

# =====================[ Proxmox Resume ]======================================
resume_orphans() {
  if has_cmd qm; then
    while read -r id; do
      [[ -z "$id" ]] && continue
      st="$(qm status "$id" 2>/dev/null | awk '{print $2}' || true)"
      if [[ "$st" == "paused" ]]; then
        msg "  - qm resume $id" "  - qm resume $id"
        qm resume "$id" >/dev/null 2>&1 || true
      fi
      qm agent "$id" fsfreeze-thaw >/dev/null 2>&1 || true
    done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')
  fi
  if has_cmd pct; then
    while read -r ct; do
      [[ -z "$ct" ]] && continue
      msg "  - pct unfreeze $ct" "  - pct unfreeze $ct"
      pct unfreeze "$ct" >/dev/null 2>&1 || true
    done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')
  fi
}

# =====================[ Stop ]================================================
do_stop() {
  if ! is_running; then
    msg "Kein Backup läuft." "No backup is running."
    return 0
  fi
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || { rm -f "$PID_FILE"; msg "PID-Datei leer – nichts zu stoppen." "PID file empty — nothing to stop."; return 0; }

  msg "${Y}Stoppe laufenden Vorgang (PID: $pid) und Kindprozesse...${NC}" \
      "${Y}Stopping running job (PID: $pid) and child processes...${NC}"
  ASK "Wirklich stoppen?" "Really stop?" || { msg "Abbruch." "Aborted."; return 0; }

  pkill -INT  -P "$pid" 2>/dev/null || true
  kill  -INT  "$pid"    2>/dev/null || true
  sleep 2
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill  -TERM "$pid"    2>/dev/null || true
  sleep 1
  if ps -p "$pid" >/dev/null 2>&1 || pgrep -P "$pid" >/dev/null 2>&1; then
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill  -KILL "$pid"    2>/dev/null || true
  fi

  rm -f "$PID_FILE"
  if [[ "$LANG_CHOICE" == "de" ]]; then
    set_status "GESTOPPT: Manuell abgebrochen"
  else
    set_status "STOPPED: Aborted manually"
  fi
  resume_orphans
  msg "${R}Vorgang gestoppt.${NC}" "${R}Job stopped.${NC}"
}

# =====================[ Backup Worker ]=======================================
do_backup_background() {
  if [[ "$LANG_CHOICE" == "de" ]]; then
    set_status "BACKUP: Wird gestartet..."
  else
    set_status "BACKUP: Starting..."
  fi

  cat > "$WORKER_SCRIPT" << 'EOFWORKER'
#!/usr/bin/env bash
set -euo pipefail

VERSION="2.6"
set -E
trap 'rc=$?; if [[ "${LANG_CHOICE:-de}" == "de" ]]; then set_status "FEHLER: Backup abgebrochen (RC=$rc)"; else set_status "ERROR: Backup aborted (RC=$rc)"; fi; echo "ERROR (Backup Worker) line $LINENO: $BASH_COMMAND (RC=$rc)"; exit $rc' ERR

export LC_ALL=C
: "${PATH:=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

set_status() { echo "$1" > "$STATUS_FILE"; }
msg() { if [[ "${LANG_CHOICE:-de}" == "de" ]]; then echo "$1"; else echo "$2"; fi; }
status_msg() { if [[ "${LANG_CHOICE:-de}" == "de" ]]; then echo "$1"; else echo "$2"; fi; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

run_inhibited() {
  local why="${1:?}"; shift
  if has_cmd systemd-inhibit; then
    systemd-inhibit --what=handle-lid-switch:sleep:idle --why="$why" "$@"
  else
    "$@"
  fi
}

find_latest_valid_worker() {
  local dir="${1:?}"
  if [[ -L "$dir/LATEST_OK" ]]; then
    local t
    t="$(readlink -f "$dir/LATEST_OK" || true)"
    [[ -f "$t" ]] && echo "$t" && return 0
  fi
  mapfile -t IMGS < <(ls -1t \
    "$dir"/panzer_*.img.zst.gpg "$dir"/panzer_*.img.gpg \
    "$dir"/panzer_*.img.zst "$dir"/panzer_*.img 2>/dev/null || true)
  for img in "${IMGS[@]:-}"; do
    [[ -f "${img}.sha256" ]] || continue
    ( cd "$dir" && sha256sum -c "$(basename "$img").sha256" >/dev/null 2>&1 ) && { echo "$img"; return 0; }
  done
  return 1
}

refresh_latest_ok_links_worker() {
  local newest_valid=""
  newest_valid="$(find_latest_valid_worker "$BACKUP_DIR" || true)"
  if [[ -n "$newest_valid" && -f "$newest_valid" ]]; then
    local base sfdisk_file
    base="$(basename "$newest_valid")"
    sfdisk_file="${base%.img*}.sfdisk"
    ln -sfn "$base" "${BACKUP_DIR}/LATEST_OK"
    [[ -f "${BACKUP_DIR}/${base}.sha256" ]] && ln -sfn "${base}.sha256" "${BACKUP_DIR}/LATEST_OK.sha256" || rm -f "${BACKUP_DIR}/LATEST_OK.sha256"
    [[ -f "${BACKUP_DIR}/${sfdisk_file}" ]] && ln -sfn "${sfdisk_file}" "${BACKUP_DIR}/LATEST_OK.sfdisk" || rm -f "${BACKUP_DIR}/LATEST_OK.sfdisk"
  else
    rm -f "${BACKUP_DIR}/LATEST_OK" "${BACKUP_DIR}/LATEST_OK.sha256" "${BACKUP_DIR}/LATEST_OK.sfdisk"
  fi
}

remove_backup_with_metadata_worker() {
  local old="${1:?}"
  [[ -f "$old" ]] || return 0
  local old_base old_sfdisk latest_target
  old_base="$(basename "$old")"
  old_sfdisk="${old_base%.img*}.sfdisk"
  latest_target=""
  if [[ -L "${BACKUP_DIR}/LATEST_OK" ]]; then
    latest_target="$(basename "$(readlink -f "${BACKUP_DIR}/LATEST_OK" 2>/dev/null || true)")"
  fi
  rm -f -- "$old" "${old}.sha256" "${BACKUP_DIR}/${old_sfdisk}"
  if [[ "$latest_target" == "$old_base" ]]; then
    refresh_latest_ok_links_worker
  fi
}

pve_quiesce_start() {
  FROZEN_QM=(); SUSPENDED_QM=(); RUN_CT=(); RUN_QM=()
  if ! has_cmd qm && ! has_cmd pct; then return 0; fi
  set_status "$(status_msg "BACKUP: Proxmox VMs/CTs werden pausiert..." "BACKUP: Pausing Proxmox VMs/CTs...")"
  msg "[*] Proxmox erkannt – beginne Quiesce" "[*] Proxmox detected – starting quiesce"

  if has_cmd qm; then
    mapfile -t RUN_QM < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}')
    for vm in "${RUN_QM[@]:-}"; do
      if qm agent "$vm" ping >/dev/null 2>&1; then
        msg "  - VM $vm: QGA ok → fsfreeze-freeze" "  - VM $vm: QGA ok → fsfreeze-freeze"
        if qm agent "$vm" fsfreeze-freeze >/dev/null 2>&1; then
          FROZEN_QM+=("$vm")
        else
          msg "    ! freeze fehlgeschlagen → fallback suspend" "    ! freeze failed → fallback suspend"
          qm suspend "$vm" >/dev/null 2>&1 || true
          SUSPENDED_QM+=("$vm")
        fi
      else
        msg "  - VM $vm: kein QGA → suspend" "  - VM $vm: no QGA → suspend"
        qm suspend "$vm" >/dev/null 2>&1 || true
        SUSPENDED_QM+=("$vm")
      fi
    done
  fi

  if has_cmd pct; then
    mapfile -t RUN_CT < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
    for ct in "${RUN_CT[@]:-}"; do
      msg "  - CT $ct: freeze" "  - CT $ct: freeze"
      pct freeze "$ct" >/dev/null 2>&1 || true
    done
  fi
  trap 'pve_quiesce_end' EXIT
}

pve_quiesce_end() {
  set_status "$(status_msg "BACKUP: VMs/CTs werden fortgesetzt..." "BACKUP: Resuming VMs/CTs...")"
  if has_cmd qm; then
    for vm in "${FROZEN_QM[@]:-}"; do
      msg "  - VM $vm: fsfreeze-thaw" "  - VM $vm: fsfreeze-thaw"
      qm agent "$vm" fsfreeze-thaw >/dev/null 2>&1 || true
    done
    for vm in "${SUSPENDED_QM[@]:-}"; do
      msg "  - VM $vm: resume" "  - VM $vm: resume"
      qm resume "$vm" >/dev/null 2>&1 || true
    done
  fi
  if has_cmd pct; then
    for ct in "${RUN_CT[@]:-}"; do
      msg "  - CT $ct: unfreeze" "  - CT $ct: unfreeze"
      pct unfreeze "$ct" >/dev/null 2>&1 || true
    done
  fi
}

{
  exec >> "$LOG_FILE" 2>&1
  echo "=========================================="
  echo "Backup Worker Start: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="

  set_status "$(status_msg "BACKUP: Initialisiere..." "BACKUP: Initializing...")"
  msg "=== $(date) | Starte Panzer-Backup von $DISK -> $FINAL_FILE" \
      "=== $(date) | Starting panzer-backup from $DISK -> $FINAL_FILE"

  pve_quiesce_start

  set_status "$(status_msg "BACKUP: Erstelle Partitionstabelle..." "BACKUP: Creating partition table...")"
  sfdisk -d "$DISK" > "${BACKUP_DIR}/${IMG_PREFIX}.sfdisk"

  set_status "$(status_msg "BACKUP: Kopiere Disk-Image..." "BACKUP: Copying disk image...")"
  set -o pipefail

  if [[ "$USE_COMPRESS" == "true" && "$ENCRYPT_MODE" == "gpg" ]]; then
    msg "[*] dd | zstd | gpg | tee | sha256sum …" "[*] dd | zstd | gpg | tee | sha256sum …"
    set_status "$(status_msg "BACKUP: dd | zstd | gpg läuft..." "BACKUP: dd | zstd | gpg running...")"
    run_inhibited "Panzerbackup läuft / Panzerbackup running" bash -c '
      dd if='"$DISK"' bs=64M status=progress \
      | zstd -T0 -'"$ZSTD_LEVEL"' -q \
      | gpg --batch --yes --symmetric --cipher-algo AES256 --pinentry-mode loopback --passphrase-fd 3 3<<<"'"$ENCRYPT_PASSPHRASE"'" \
      | tee "'"$TEMP_FILE"'" \
      | sha256sum -b \
      | awk '"'"'{print $1"  '"$(basename "$FINAL_FILE")"'"}'"'"' > "'"$TEMP_SHA"'"
    '
  elif [[ "$USE_COMPRESS" == "true" ]]; then
    msg "[*] dd | zstd | tee | sha256sum …" "[*] dd | zstd | tee | sha256sum …"
    set_status "$(status_msg "BACKUP: dd | zstd läuft..." "BACKUP: dd | zstd running...")"
    run_inhibited "Panzerbackup läuft / Panzerbackup running" bash -c '
      dd if='"$DISK"' bs=64M status=progress \
      | zstd -T0 -'"$ZSTD_LEVEL"' -q \
      | tee "'"$TEMP_FILE"'" \
      | sha256sum -b \
      | awk '"'"'{print $1"  '"$(basename "$FINAL_FILE")"'"}'"'"' > "'"$TEMP_SHA"'"
    '
  elif [[ "$ENCRYPT_MODE" == "gpg" ]]; then
    msg "[*] dd | gpg | tee | sha256sum …" "[*] dd | gpg | tee | sha256sum …"
    set_status "$(status_msg "BACKUP: dd | gpg läuft..." "BACKUP: dd | gpg running...")"
    run_inhibited "Panzerbackup läuft / Panzerbackup running" bash -c '
      dd if='"$DISK"' bs=64M status=progress \
      | gpg --batch --yes --symmetric --cipher-algo AES256 --pinentry-mode loopback --passphrase-fd 3 3<<<"'"$ENCRYPT_PASSPHRASE"'" \
      | tee "'"$TEMP_FILE"'" \
      | sha256sum -b \
      | awk '"'"'{print $1"  '"$(basename "$FINAL_FILE")"'"}'"'"' > "'"$TEMP_SHA"'"
    '
  else
    msg "[*] dd (roh) | tee | sha256sum …" "[*] dd (raw) | tee | sha256sum …"
    set_status "$(status_msg "BACKUP: dd (raw) läuft..." "BACKUP: dd (raw) running...")"
    run_inhibited "Panzerbackup läuft / Panzerbackup running" bash -c '
      dd if='"$DISK"' bs=64M status=progress \
      | tee "'"$TEMP_FILE"'" \
      | sha256sum -b \
      | awk '"'"'{print $1"  '"$(basename "$FINAL_FILE")"'"}'"'"' > "'"$TEMP_SHA"'"
    '
  fi
  set +o pipefail

  set_status "$(status_msg "BACKUP: Finalisiere..." "BACKUP: Finalizing...")"
  sync
  mv -f "$TEMP_FILE" "$FINAL_FILE"
  mv -f "$TEMP_SHA" "${FINAL_FILE}.sha256"

  msg "[✓] Datei: $(du -h "$FINAL_FILE" | cut -f1)   Hash: $(cut -d' ' -f1 "${FINAL_FILE}.sha256")" \
      "[✓] File:  $(du -h "$FINAL_FILE" | cut -f1)   Hash: $(cut -d' ' -f1 "${FINAL_FILE}.sha256")"

  if ( cd "$BACKUP_DIR" && sha256sum -c "$(basename "$FINAL_FILE").sha256" >/dev/null 2>&1 ); then
    ln -sfn "$(basename "$FINAL_FILE")"         "${BACKUP_DIR}/LATEST_OK"
    ln -sfn "$(basename "$FINAL_FILE").sha256"  "${BACKUP_DIR}/LATEST_OK.sha256"
    ln -sfn "${IMG_PREFIX}.sfdisk"              "${BACKUP_DIR}/LATEST_OK.sfdisk"
    set_status "$(status_msg "BACKUP: Erfolgreich abgeschlossen - $(basename "$FINAL_FILE")" "BACKUP: Completed successfully - $(basename "$FINAL_FILE")")"
    msg "✅ Backup erfolgreich abgeschlossen" "✅ Backup completed successfully"
  else
    set_status "$(status_msg "FEHLER: Checksum-Verify fehlgeschlagen" "ERROR: Checksum verify failed")"
    msg "❌ Backup fehlgeschlagen: Checksum-Verify" "❌ Backup failed: checksum verify"
    rm -f "$PID_FILE"
    exit 2
  fi

  set_status "$(status_msg "BACKUP: Räume alte Backups auf..." "BACKUP: Cleaning up old backups...")"
  mapfile -t ALL < <(ls -1t \
    "$BACKUP_DIR"/panzer_*.img "$BACKUP_DIR"/panzer_*.img.zst \
    "$BACKUP_DIR"/panzer_*.img.gpg "$BACKUP_DIR"/panzer_*.img.zst.gpg 2>/dev/null || true)
  if (( ${#ALL[@]} > KEEP )); then
    for old in "${ALL[@]:$KEEP}"; do
      msg "  - Entferne alt: $old" "  - Removing old: $old"
      remove_backup_with_metadata_worker "$old"
    done
    refresh_latest_ok_links_worker
  fi

  echo "=========================================="
  echo "Backup Worker Ende: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  rm -f "$PID_FILE"
}
EOFWORKER

  chmod +x "$WORKER_SCRIPT"
  : > "$STARTUP_LOG"

  env -i \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME="/root" \
    LC_ALL="C" LANG="C" \
    LANG_CHOICE="$LANG_CHOICE" \
    DISK="$DISK" BACKUP_DIR="$BACKUP_DIR" IMG_PREFIX="$IMG_PREFIX" \
    FINAL_FILE="$FINAL_FILE" TEMP_FILE="$TEMP_FILE" TEMP_SHA="$TEMP_SHA" \
    USE_COMPRESS="$USE_COMPRESS" ENCRYPT_MODE="$ENCRYPT_MODE" \
    ENCRYPT_PASSPHRASE="$ENCRYPT_PASSPHRASE" ZSTD_LEVEL="$ZSTD_LEVEL" \
    STATUS_FILE="$STATUS_FILE" PID_FILE="$PID_FILE" \
    LOG_FILE="$LOG_FILE_DEFAULT" KEEP="$KEEP" \
    nohup setsid bash "$WORKER_SCRIPT" >> "$STARTUP_LOG" 2>&1 &

  local worker_pid=$!
  echo "$worker_pid" > "$PID_FILE"

  sleep 2
  if ! (ps -p "$worker_pid" >/dev/null 2>&1 || pgrep -P "$worker_pid" >/dev/null 2>&1); then
    if [[ "$LANG_CHOICE" == "de" ]]; then
      set_status "FEHLER: Worker-Start fehlgeschlagen – siehe $STARTUP_LOG"
    else
      set_status "ERROR: Worker start failed – see $STARTUP_LOG"
    fi
    msg "⚠️  WARNUNG: Worker-Prozess beendet sich sofort!" \
        "⚠️  WARNING: Worker process terminated immediately!"
    msg "   Prüfe: cat $STARTUP_LOG" \
        "   Check: cat $STARTUP_LOG"
    msg "   oder: tail $LOG_FILE_DEFAULT" \
        "   or: tail $LOG_FILE_DEFAULT"
  fi
}

# =====================[ Backup ]==============================================
do_backup() {
  if is_running; then
    msg "Ein Backup läuft bereits!" "A backup is already running!"
    msg "Aktueller Status: $(get_status)" "Current status: $(get_status)"
    return 1
  fi

  need_cmd dd; need_cmd sha256sum; need_cmd sfdisk; need_cmd blockdev; need_cmd df
  ensure_zstd_if_needed "$COMPRESS_MODE"

  local default_name backup_name
  default_name="$(hostname -s 2>/dev/null || echo 'system')"
  backup_name="$(prompt_backup_name "$default_name")"
  IMG_PREFIX="panzer_${backup_name}_${DATE}"

  msg "→ Backup-Name: $backup_name" "→ Backup name: $backup_name"

  USE_COMPRESS="false"
  if [[ "$COMPRESS_MODE" == "on" ]]; then
    USE_COMPRESS="true"
  elif [[ "$COMPRESS_MODE" == "auto" && $(has_cmd zstd && echo yes || echo no) == "yes" ]]; then
    USE_COMPRESS="true"
  fi

  FINAL_FILE="${BACKUP_DIR}/${IMG_PREFIX}.img"
  [[ "$USE_COMPRESS" == "true" ]] && FINAL_FILE="${FINAL_FILE}.zst"
  [[ "$ENCRYPT_MODE" == "gpg" ]] && FINAL_FILE="${FINAL_FILE}.gpg"
  TEMP_FILE="${FINAL_FILE}.part"
  TEMP_SHA="${FINAL_FILE}.sha256.part"

  cleanup_stale_partial_files
  cleanup_oldest_backups_until_enough_space

  clear_status_for_new_run
  mark_run_started
  msg "" ""
  msg "Starte Backup im Hintergrund..." "Starting backup in background..."

  msg "[Debug] Worker wird gestartet mit:" "[Debug] Starting worker with:"
  msg "  - Disk: $DISK" "  - Disk: $DISK"
  msg "  - Ziel: $FINAL_FILE" "  - Target: $FINAL_FILE"
  msg "  - Kompression: $USE_COMPRESS" "  - Compression: $USE_COMPRESS"
  msg "  - Verschlüsselung: $ENCRYPT_MODE" "  - Encryption: $ENCRYPT_MODE"

  do_backup_background

  sleep 2
  if is_running; then
    echo ""
    msg "✓ Backup läuft!" "✓ Backup is running!"
    msg "  Verwende Menüpunkt 'Progress' oder '$0 status' um den Fortschritt zu sehen." \
        "  Use 'Progress' in the menu or '$0 status' to watch progress."
    msg "  Aktueller Status: $(get_status)" "  Current status: $(get_status)"
  else
    echo ""
    msg "⚠️  WARNUNG: Worker wurde beendet oder konnte nicht starten!" \
        "⚠️  WARNING: Worker terminated or could not start!"
    msg "  Prüfe Logs:" "  Check logs:"
    msg "    tail ${LOG_FILE_DEFAULT}" "    tail ${LOG_FILE_DEFAULT}"
    [[ -f "$STARTUP_LOG" ]] && {
      echo ""
      msg "=== Startup-Log ===" "=== Startup log ==="
      cat "$STARTUP_LOG" || true
    }
  fi
  echo ""

  ENCRYPT_PASSPHRASE=""
}

# =====================[ Verify ]==============================================
do_verify() {
  need_cmd sha256sum
  msg "=== $(date) | Prüfe letztes Backup ===" "=== $(date) | Verifying last backup ==="
  local CAND
  CAND="$(find_latest_any "$BACKUP_DIR" || true)"
  [[ -n "${CAND:-}" ]] || die "Keine Backup-Datei gefunden" "No backup file found"
  msg "Datei: $(basename "$CAND") | Größe: $(du -h "$CAND" | cut -f1)" \
      "File:  $(basename "$CAND") | Size:  $(du -h "$CAND" | cut -f1)"
  ( cd "$BACKUP_DIR" && sha256sum -c "$(basename "$CAND").sha256" )
  msg "=== Verify OK ===" "=== Verify OK ==="
}

# =====================[ Restore ]=============================================
do_restore() {
  need_cmd dd; need_cmd sha256sum; need_cmd lsblk; need_cmd mount; need_cmd chroot
  local restore_disk="${DISK:-}"
  if [[ -n "${TARGET_DISK:-}" ]]; then
    restore_disk="$TARGET_DISK"; [[ -b "$restore_disk" ]] || die "Angegebene Ziel-Disk nicht gefunden: $restore_disk" "Target disk not found: $restore_disk"
  elif [[ "${SELECT_DISK:-}" == "true" || "$LIVE_ENV" -eq 1 || -z "$restore_disk" ]]; then
    restore_disk="$(select_target_disk "${RUNNING_SYSTEM_DISK:-}")"
  fi
  [[ -b "$restore_disk" ]] || die "Keine gültige Restore-Zieldisk gewählt" "No valid restore target disk selected"
  if disk_is_protected "$restore_disk"; then
    die "Restore-Ziel ist geschützt (Live-USB, Backup-Medium oder Skript-Quelle): $restore_disk" "Restore target is protected (live USB, backup medium or script source): $restore_disk"
  fi

  clear_status_for_new_run
  mark_run_started
  set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: Initialisiere..." || echo "RESTORE: Initializing..." )"

  msg "=== $(date) | Starte Restore ${RESTORE_DRY_RUN:+(Dry-Run)} auf $restore_disk ===" \
      "=== $(date) | Starting restore ${RESTORE_DRY_RUN:+(dry-run)} to $restore_disk ==="

  local CANDIDATE
  if [[ "${SELECT_BACKUP:-}" == "true" ]]; then
    CANDIDATE="$(select_backup_file "$BACKUP_DIR")"
  else
    CANDIDATE="$(find_latest_valid "$BACKUP_DIR" || true)"
  fi
  [[ -n "${CANDIDATE:-}" && -f "$CANDIDATE" ]] || die "Kein gültiges Backup gefunden" "No valid backup found"
  msg "[✓] Verwende: $(basename "$CANDIDATE")" "[✓] Using: $(basename "$CANDIDATE")"
  set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: Verwende $(basename "$CANDIDATE")" || echo "RESTORE: Using $(basename "$CANDIDATE")" )"

  if [[ "$RESTORE_DRY_RUN" == "--dry-run" ]]; then
    set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: Dry-Run abgeschlossen" || echo "RESTORE: Dry-run completed" )"
    msg "[DRY-RUN] Würde $(basename "$CANDIDATE") auf $restore_disk schreiben." \
        "[DRY-RUN] Would write $(basename "$CANDIDATE") to $restore_disk."
    return 0
  fi

  M "⚠️  ALLE DATEN auf $restore_disk werden überschrieben!" "⚠️  ALL DATA on $restore_disk will be overwritten!"
  ASK "Willst du das Restore wirklich starten?" "Do you really want to start the restore?" || { set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: Abgebrochen" || echo "RESTORE: Aborted" )"; msg "Abbruch." "Aborted."; return 3; }

  set -o pipefail
  set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: Prüfe Checksumme..." || echo "RESTORE: Verifying checksum..." )"
  ( cd "$BACKUP_DIR" && sha256sum -c "$(basename "$CANDIDATE").sha256" >/dev/null ) || die "Checksum-Verify fehlgeschlagen: $(basename "$CANDIDATE")" "Checksum verification failed: $(basename "$CANDIDATE")"

  if [[ "$CANDIDATE" == *.gpg ]]; then
    need_cmd gpg
    if [[ -z "${ENCRYPT_PASSPHRASE:-}" ]]; then
      if [[ "$LANG_CHOICE" == "de" ]]; then
        read -rsp "GPG-Passphrase für Restore: " ENCRYPT_PASSPHRASE; echo
      else
        read -rsp "GPG passphrase for restore: " ENCRYPT_PASSPHRASE; echo
      fi
    fi
    if [[ "$CANDIDATE" == *.zst.gpg ]]; then
      msg "[*] gpg -d | zstd -d | dd …" "[*] gpg -d | zstd -d | dd …"
      set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: gpg | zstd | dd läuft..." || echo "RESTORE: gpg | zstd | dd running..." )"
      run_inhibited "Panzer-RESTORE läuft / running" bash -c \
        'gpg --batch --yes --decrypt --pinentry-mode loopback --passphrase-fd 3 3<<<"'"$ENCRYPT_PASSPHRASE"'" "'"$CANDIDATE"'" \
         | zstd -d -q \
         | dd of="'"$restore_disk"'" bs=64M status=progress conv=fsync'
    else
      msg "[*] gpg -d | dd …" "[*] gpg -d | dd …"
      set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: gpg | dd läuft..." || echo "RESTORE: gpg | dd running..." )"
      run_inhibited "Panzer-RESTORE läuft / running" bash -c \
        'gpg --batch --yes --decrypt --pinentry-mode loopback --passphrase-fd 3 3<<<"'"$ENCRYPT_PASSPHRASE"'" "'"$CANDIDATE"'" \
         | dd of="'"$restore_disk"'" bs=64M status=progress conv=fsync'
    fi
    ENCRYPT_PASSPHRASE=""
  elif [[ "$CANDIDATE" == *.zst ]]; then
    need_cmd zstd
    msg "[*] zstd -d | dd …" "[*] zstd -d | dd …"
    set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: zstd | dd läuft..." || echo "RESTORE: zstd | dd running..." )"
    run_inhibited "Panzer-RESTORE läuft / running" bash -c \
      'zstd -d -q "'"$CANDIDATE"'" \
       | dd of="'"$restore_disk"'" bs=64M status=progress conv=fsync'
  else
    msg "[*] dd (roh) …" "[*] dd (raw) …"
    set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: dd läuft..." || echo "RESTORE: dd running..." )"
    run_inhibited "Panzer-RESTORE läuft / running" dd if="$CANDIDATE" of="$restore_disk" bs=64M status=progress conv=fsync
  fi
  set +o pipefail

  if [[ -n "${DISK:-}" && "$restore_disk" == "$DISK" && "$LIVE_ENV" -eq 0 ]]; then
    msg "[*] Versuche GRUB zu erneuern …" "[*] Attempting GRUB repair …"
    local ROOT_CAND
    ROOT_CAND="$(lsblk -lnpo NAME,TYPE | awk '/lvm/ && /root/{print $1; exit}' || true)"
    if [[ -z "$ROOT_CAND" ]]; then
      ROOT_CAND="$(lsblk -lnpo NAME,FSTYPE,SIZE,TYPE "$restore_disk" | awk '$2 ~ /ext4|xfs/ && $4=="part"{print $1,$3}' | sort -k2 -h | tail -n1 | awk '{print $1}' || true)"
    fi
    if [[ -n "$ROOT_CAND" ]]; then
      local EFI_PART
      EFI_PART="$(lsblk -lnpo NAME,PARTLABEL,PARTTYPE "$restore_disk" | awk '/EFI|EF00|ESP/{print $1; exit}' || true)"
      mkdir -p /mnt/restore
      mount "$ROOT_CAND" /mnt/restore || true
      if [[ -n "${EFI_PART:-}" ]]; then
        mkdir -p /mnt/restore/boot/efi
        mount "$EFI_PART" /mnt/restore/boot/efi || true
      fi
      for d in /dev /proc /sys; do mount --bind "$d" "/mnt/restore${d}"; done
      chroot /mnt/restore bash -c "grub-install $restore_disk || true; update-grub || true"
    else
      msg "[!] Root-Partition nicht sicher erkannt – GRUB-Reparatur übersprungen." "[!] Root partition not reliably detected – skipping GRUB repair."
    fi
  else
    msg "[*] Restore auf anderer Disk – GRUB-Installation übersprungen." "[*] Restore to different disk – skipping GRUB installation."
  fi

  set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: Finalisiere..." || echo "RESTORE: Finalizing..." )"
  msg "[✓] Restore abgeschlossen." "[✓] Restore completed."
  set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: Erfolgreich abgeschlossen" || echo "RESTORE: Completed successfully" )"
  post_action_maybe "restore"
}

# =====================[ Post Action ]=========================================
post_action_maybe() {
  local phase="$1"
  case "$POST_ACTION" in
    reboot)
      msg "[*] Neustart in 5 Sekunden ..." "[*] Rebooting in 5 seconds ..."
      sleep 5; systemctl reboot ;;
    shutdown)
      msg "[*] Shutdown in 5 Sekunden ..." "[*] Shutting down in 5 seconds ..."
      sleep 5; systemctl poweroff ;;
    none|"")
      if [[ -z "${POST_ACTION_PRESET:-}" && -t 0 && -t 1 ]]; then
        echo
        if [[ "$LANG_CHOICE" == "de" ]]; then
          echo "Aktion nach $phase?"; echo "1) Nichts tun"; echo "2) Neu starten"; echo "3) Herunterfahren"
          read -rp "Auswahl (1/2/3): " pa
        else
          echo "Action after $phase?"; echo "1) Do nothing"; echo "2) Reboot"; echo "3) Shutdown"
          read -rp "Choice (1/2/3): " pa
        fi
        case "$pa$phase" in
          2*) systemctl reboot ;;
          3*) systemctl poweroff ;;
          *) : ;;
        esac
      fi
      ;;
  esac
}

# =====================[ Live Status ]=========================================
show_status() {
  { clear 2>/dev/null || printf '\033c'; } || true
  echo "=========================================="
  msg "    Panzerbackup - Live-Status" "    Panzerbackup - Live Status"
  echo "=========================================="
  echo ""

  if ! is_running; then
    msg "Kein Backup läuft aktuell." "No backup is currently running."
    echo ""
    [[ -s "$STATUS_FILE" ]] && msg "Letzter Status: $(get_status_formatted)" "Last status: $(get_status_formatted)"
    echo ""
    if [[ "$LANG_CHOICE" == "de" ]]; then
      read -rp "Drücke Enter um zurückzukehren..." _ || true
    else
      read -rp "Press Enter to return..." _ || true
    fi
    return 0
  fi

  if [[ "$LANG_CHOICE" == "de" ]]; then
    echo "STRG+C zum Beenden der Anzeige (Backup läuft weiter!)"
  else
    echo "CTRL+C to stop viewing (backup keeps running!)"
  fi
  echo ""

  cleanup() { trap - INT TERM; }
  trap cleanup INT TERM

  while is_running; do
    { clear 2>/dev/null || printf '\033c'; } || true
    echo "=========================================="
    msg "    Panzerbackup - Live-Status" "    Panzerbackup - Live Status"
    echo "=========================================="
    echo ""
    if [[ "$LANG_CHOICE" == "de" ]]; then
      echo "STRG+C zum Beenden der Anzeige (Backup läuft weiter!)"
    else
      echo "CTRL+C to stop viewing (backup keeps running!)"
    fi
    echo ""
    msg "Aktueller Status: $(get_status_formatted)" "Current status: $(get_status_formatted)"
    if elapsed="$(get_elapsed_seconds 2>/dev/null)"; then
      msg "Laufzeit: $(format_elapsed "$elapsed")" "Elapsed: $(format_elapsed "$elapsed")"
    fi
    echo "=========================================="
    msg "Log (letzte ${LIVE_LOG_LINES} Zeilen):" "Log (last ${LIVE_LOG_LINES} lines):"
    echo "=========================================="

    if [[ -f "$LOG_FILE_DEFAULT" ]]; then
      tail -n "$LIVE_LOG_LINES" "$LOG_FILE_DEFAULT" 2>/dev/null || msg "(Log noch nicht verfügbar)" "(Log not yet available)"
    else
      msg "(Kein Log vorhanden)" "(No log present)"
    fi

    sleep "$MENU_REFRESH_SECONDS"
  done

  echo ""
  echo "=========================================="
  msg "Backup abgeschlossen!" "Backup finished!"
  msg "Finaler Status: $(get_status_formatted)" "Final status: $(get_status_formatted)"
  echo "=========================================="
  echo ""
  if [[ "$LANG_CHOICE" == "de" ]]; then
    read -rp "Drücke Enter um zurückzukehren..." _ || true
  else
    read -rp "Press Enter to return..." _ || true
  fi
}

# =====================[ Menu ]===============================================
show_menu() {
  { clear 2>/dev/null || printf 'c'; } || true
  local banner_title="▄▅▆ Panzerbackup Manager v${VERSION} ▆▅▄"
  local cols banner_inner title_len pad_left pad_right display_slack
  cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  title_len=${#banner_title}
  display_slack=4
  banner_inner=$(( title_len + 14 + display_slack ))
  (( banner_inner > cols - 6 )) && banner_inner=$(( cols - 6 ))
  (( banner_inner < title_len + 10 + display_slack )) && banner_inner=$(( title_len + 10 + display_slack ))
  pad_left=$(( (banner_inner - title_len) / 2 ))
  pad_right=$(( banner_inner - title_len - pad_left ))
  printf '
'
  printf '╔%*s╗
' "$banner_inner" '' | tr ' ' '═'
  printf '║%*s%s%*s║
' "$pad_left" '' "$banner_title" "$pad_right" ''
  printf '╚%*s╝
' "$banner_inner" '' | tr ' ' '═'
  printf '
'
  if [[ "$LANG_CHOICE" == "de" ]]; then
    echo "Systemdisk:  ${DISK}"
    echo "Backup-Ziel: ${BACKUP_DIR}"
  else
    echo "System disk: ${DISK}"
    echo "Backup dir:  ${BACKUP_DIR}"
  fi
  echo ""

  if is_running; then
    if [[ "$LANG_CHOICE" == "de" ]]; then
      echo "${Y}STATUS: Vorgang läuft!${NC}"
    else
      echo "${Y}STATUS: Operation running!${NC}"
    fi
    echo "        $(get_status_formatted)"
    if elapsed="$(get_elapsed_seconds 2>/dev/null)"; then
      if [[ "$LANG_CHOICE" == "de" ]]; then
        echo "        Laufzeit: $(format_elapsed "$elapsed")"
      else
        echo "        Elapsed: $(format_elapsed "$elapsed")"
      fi
    fi
  else
    if [[ "$LANG_CHOICE" == "de" ]]; then
      echo "${G}STATUS: Bereit${NC}"
    else
      echo "${G}STATUS: Ready${NC}"
    fi
    [[ -s "$STATUS_FILE" ]] && {
      if [[ "$LANG_CHOICE" == "de" ]]; then
        echo "        Letzter Status: $(get_status_formatted)"
      else
        echo "        Last status: $(get_status_formatted)"
      fi
    }
  fi

  echo ""
  if [[ "$LANG_CHOICE" == "de" ]]; then
    echo "1) Backup   - Backup starten (auto-Kompression)"
    echo "2) Restore  - Letztes gültiges Backup wiederherstellen"
    echo "3) Dry-Run  - Restore nur prüfen (kein Schreiben)"
    echo "4) Backup   - Ohne Kompression"
    echo "5) Backup   - Mit Kompression (zstd)"
    echo "6) Restore  - Mit Disk-Auswahl"
    echo "7) Verify   - Letztes Backup prüfen (sha256)"
    echo "8) Progress - Live-Status anzeigen"
    echo "9) Log      - Logfile anzeigen"
    echo "S) Stop     - Laufenden Vorgang abbrechen"
    echo "0) Exit"
    echo ""
  else
    echo "1) Backup   - Start backup (auto-compression)"
    echo "2) Restore  - Restore latest valid backup"
    echo "3) Dry-Run  - Restore verify only (no write)"
    echo "4) Backup   - Without compression"
    echo "5) Backup   - With compression (zstd)"
    echo "6) Restore  - With disk selection"
    echo "7) Verify   - Verify latest backup (sha256)"
    echo "8) Progress - Show live status"
    echo "9) Log      - View log file"
    echo "S) Stop     - Stop running job"
    echo "0) Exit"
    echo ""
  fi
}

# =====================[ Help ]===============================================
print_usage() {
  if [[ "$LANG_CHOICE" == "de" ]]; then
cat <<USAGE
Erkannt:
  Systemdisk:  ${DISK:-<live/bitte wählen>}
  Backup-Ziel: $BACKUP_DIR
  Live-System: $([[ "$LIVE_ENV" -eq 1 ]] && echo ja || echo nein)

Aufruf:
  $0 backup  [--name NAME] [--compress|--no-compress] [--zstd-level N] [--encrypt|--no-encrypt] [--passfile FILE] [--post reboot|shutdown|none] [--select-backup] [--disk /dev/XYZ]
  $0 restore [--dry-run] [--select-disk] [--target /dev/sdX] [--post reboot|shutdown|none] [--passfile FILE] [--select-backup] [--disk /dev/XYZ]
  $0 verify
  $0 status
  $0 log    [--lines N] [--file PATH]
  $0 stop
  $0         # interaktives Menü

Environment:
  MIN_FREE_BYTES=2147483648
  AUTO_DELETE_OLDEST=1
  LIVE_LOG_LINES=20
  LOG_VIEW_LINES_DEFAULT=100
  MENU_REFRESH_SECONDS=2

USAGE
  else
cat <<USAGE
Detected:
  System disk:  ${DISK:-<live/select manually>}
  Backup dir:   $BACKUP_DIR
  Live system:  $([[ "$LIVE_ENV" -eq 1 ]] && echo yes || echo no)

Usage:
  $0 backup  [--name NAME] [--compress|--no-compress] [--zstd-level N] [--encrypt|--no-encrypt] [--passfile FILE] [--post reboot|shutdown|none] [--select-backup] [--disk /dev/XYZ]
  $0 restore [--dry-run] [--select-disk] [--target /dev/sdX] [--post reboot|shutdown|none] [--passfile FILE] [--select-backup] [--disk /dev/XYZ]
  $0 verify
  $0 status
  $0 log    [--lines N] [--file PATH]
  $0 stop
  $0         # interactive menu

Environment:
  MIN_FREE_BYTES=2147483648
  AUTO_DELETE_OLDEST=1
  LIVE_LOG_LINES=20
  LOG_VIEW_LINES_DEFAULT=100
  MENU_REFRESH_SECONDS=2

USAGE
  fi
}

# =====================[ Entry / CLI ]=========================================
if [[ $# -gt 0 ]]; then
  case "$1" in
    backup)
      shift; parse_backup_flags "$@" >/dev/null
      if [[ -t 0 && -t 1 ]]; then
        [[ -z "${POST_ACTION_PRESET:-}" ]] && prompt_post_action "Backup"
        if [[ "${ENCRYPT_MODE}" == "off" && -z "${ENCRYPT_PASSPHRASE:-}" ]]; then prompt_encryption; fi
      fi
      do_backup ;;
    restore)
      shift; parse_restore_flags "$@" >/dev/null
      if [[ -t 0 && -t 1 && -z "${POST_ACTION_PRESET:-}" ]]; then
        prompt_post_action "Restore"
      fi
      do_restore ;;
    verify) do_verify ;;
    status) show_status ;;
    log)
      shift
      LOG_TAIL_LINES="$LOG_VIEW_LINES_DEFAULT"
      LOG_FILE_PATH="$LOG_FILE_DEFAULT"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -n|--lines) LOG_TAIL_LINES="${2:-$LOG_VIEW_LINES_DEFAULT}"; shift 2 ;;
          -f|--file) LOG_FILE_PATH="${2:-$LOG_FILE_DEFAULT}"; shift 2 ;;
          *) break ;;
        esac
      done
      do_log "$LOG_FILE_PATH" "$LOG_TAIL_LINES" ;;
    stop) do_stop ;;
    help|--help|-h) print_usage; exit 0 ;;
    *) print_usage; exit 1 ;;
  esac
  exit 0
fi

# =====================[ Interactive Menu ]====================================
while true; do
  show_menu
  if [[ "$LANG_CHOICE" == "en" ]]; then
    read -rp "Choice (0-9,S): " choice || { echo "No input (EOF) — exiting."; exit 0; }
  else
    read -rp "Auswahl (0-9,S): " choice || { echo "Keine Eingabe erkannt (EOF) – beende."; exit 0; }
  fi

  case "${choice:-}" in
    1)
      COMPRESS_MODE="auto"
      BACKUP_NAME=""
      if [[ -t 0 && -t 1 ]]; then
        if [[ "$LANG_CHOICE" == "de" ]]; then
          read -rp "Backup-Name (z.B. 'proxmox-node1') [Standard: $(hostname -s)]: " BACKUP_NAME
        else
          read -rp "Backup name (e.g., 'proxmox-node1') [Default: $(hostname -s)]: " BACKUP_NAME
        fi
        prompt_post_action "Backup"
        prompt_encryption
      fi
      do_backup ;;
    2)
      if [[ -t 0 && -t 1 && -z "${POST_ACTION_PRESET:-}" ]]; then prompt_post_action "Restore"; fi
      do_restore ;;
    3)
      RESTORE_DRY_RUN="--dry-run"
      if [[ -t 0 && -t 1 && -z "${POST_ACTION_PRESET:-}" ]]; then prompt_post_action "Restore"; fi
      do_restore
      RESTORE_DRY_RUN="" ;;
    4)
      COMPRESS_MODE="off"
      BACKUP_NAME=""
      if [[ -t 0 && -t 1 ]]; then
        if [[ "$LANG_CHOICE" == "de" ]]; then
          read -rp "Backup-Name (z.B. 'proxmox-node1') [Standard: $(hostname -s)]: " BACKUP_NAME
        else
          read -rp "Backup name (e.g., 'proxmox-node1') [Default: $(hostname -s)]: " BACKUP_NAME
        fi
        prompt_post_action "Backup"
        prompt_encryption
      fi
      do_backup ;;
    5)
      COMPRESS_MODE="on"
      BACKUP_NAME=""
      if [[ -t 0 && -t 1 ]]; then
        if [[ "$LANG_CHOICE" == "de" ]]; then
          read -rp "Backup-Name (z.B. 'proxmox-node1') [Standard: $(hostname -s)]: " BACKUP_NAME
        else
          read -rp "Backup name (e.g., 'proxmox-node1') [Default: $(hostname -s)]: " BACKUP_NAME
        fi
        prompt_post_action "Backup"
        prompt_encryption
      fi
      do_backup ;;
    6)
      SELECT_DISK="true"
      if [[ -t 0 && -t 1 && -z "${POST_ACTION_PRESET:-}" ]]; then prompt_post_action "Restore"; fi
      do_restore
      SELECT_DISK="" ;;
    7)
      { clear 2>/dev/null || printf '\033c'; } || true
      do_verify
      if [[ "$LANG_CHOICE" == "en" ]]; then read -rp "Press Enter to continue..." _ || true
      else read -rp "Drücke Enter um fortzufahren..." _ || true; fi ;;
    8) show_status ;;
    9) view_log ;;
    S|s)
      do_stop
      if [[ "$LANG_CHOICE" == "en" ]]; then read -rp "Press Enter to continue..." _ || true
      else read -rp "Drücke Enter um fortzufahren..." _ || true; fi ;;
    0) exit 0 ;;
    *)
      if [[ "$LANG_CHOICE" == "de" ]]; then echo "Ungültige Auswahl"; else echo "Invalid selection"; fi
      sleep 1 ;;
  esac
done
