#!/usr/bin/env bash
set -euo pipefail

VERSION="3.0.1"

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
have_tty() { : </dev/tty >/dev/tty 2>/dev/null; }
status_msg() { if [[ "$LANG_CHOICE" == "de" ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Benötigtes Kommando fehlt: $1" "Required command missing: $1"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# =====================[ Status-Tracking ]=====================================
RUN_DIR="${RUN_DIR:-/run/panzerbackup}"
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR" 2>/dev/null || true
STATUS_FILE="${STATUS_FILE:-$RUN_DIR/status}"
PID_FILE="${PID_FILE:-$RUN_DIR/pid}"
START_LOCK_DIR="${START_LOCK_DIR:-$RUN_DIR/start.lock}"
STARTUP_LOG="${STARTUP_LOG:-$RUN_DIR/startup.log}"
WORKER_SCRIPT="${WORKER_SCRIPT:-$RUN_DIR/worker.sh}"
START_TS_FILE="${START_TS_FILE:-$RUN_DIR/start_ts}"
START_LOCK_PID_FILE="${START_LOCK_PID_FILE:-$START_LOCK_DIR/pid}"
QUIESCE_WATCHDOG_PID_FILE="${QUIESCE_WATCHDOG_PID_FILE:-$RUN_DIR/quiesce_watchdog.pid}"
PASSPHRASE_FILE="${PASSPHRASE_FILE:-$RUN_DIR/passphrase}"

# =====================[ Passphrase-Weitergabe ]===============================
# Die Passphrase darf niemals in einer Kommandozeile stehen: /proc/<pid>/cmdline
# ist fuer jeden lokalen Benutzer lesbar, /proc/<pid>/environ dagegen nur fuer
# den Eigentuemer. Sie wird deshalb ueber eine root-only 0600-Datei in $RUN_DIR
# (tmpfs) an gpg uebergeben - weder ueber argv noch ueber eine Shell-Expansion.
write_passphrase_file() {
  local f="$PASSPHRASE_FILE"
  rm -f -- "$f" 2>/dev/null || true
  ( umask 077; : > "$f" ) || return 1
  chmod 600 -- "$f" 2>/dev/null || true
  printf '%s' "$1" > "$f" || return 1
  return 0
}
clear_passphrase_file() { rm -f -- "${PASSPHRASE_FILE:-}" 2>/dev/null || true; }

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

create_start_lock() {
  mkdir "$START_LOCK_DIR" 2>/dev/null || return 1
  if ! printf '%s\n' "$$" > "$START_LOCK_PID_FILE"; then
    rmdir "$START_LOCK_DIR" 2>/dev/null || true
    return 1
  fi
}

acquire_start_lock() {
  local owner="" attempt
  create_start_lock && return 0

  # A concurrent starter may be between mkdir and writing its PID. Give it a
  # brief chance to finish before treating a lock without metadata as stale.
  for (( attempt=0; attempt<5; attempt++ )); do
    if [[ -f "$START_LOCK_PID_FILE" ]]; then
      owner="$(cat "$START_LOCK_PID_FILE" 2>/dev/null || true)"
      break
    fi
    sleep 0.1
  done

  if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
    return 1
  fi

  # Recover locks left empty, malformed, or owned by a process that exited.
  rm -f "$START_LOCK_PID_FILE" || return 1
  rmdir "$START_LOCK_DIR" 2>/dev/null || return 1
  create_start_lock
}

release_start_lock() {
  rm -f "$START_LOCK_PID_FILE"
  rmdir "$START_LOCK_DIR" 2>/dev/null || true
}

get_process_group() {
  local pid="${1:?}"
  ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]'
}

kill_descendants() {
  local parent="${1:?}" sig="${2:?}" child
  while read -r child; do
    [[ -n "$child" ]] || continue
    kill_descendants "$child" "$sig"
    kill "-$sig" "$child" 2>/dev/null || true
  done < <(pgrep -P "$parent" 2>/dev/null || true)
}

signal_process_group_or_tree() {
  local pid="${1:?}" sig="${2:?}" pgid self_pgid
  pgid="$(get_process_group "$pid")"
  self_pgid="$(get_process_group "$$")"

  if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" != "$self_pgid" ]]; then
    kill "-$sig" -- "-$pgid" 2>/dev/null || true
  else
    kill_descendants "$pid" "$sig"
    kill "-$sig" "$pid" 2>/dev/null || true
  fi
}

# =====================[ Anzeige/Performance ]=================================
str_display_width() {
  local s="${1-}" n
  n="$(printf '%s' "$s" | LC_ALL=C.UTF-8 wc -m 2>/dev/null || true)"
  n="${n//[^0-9]/}"
  [[ "$n" =~ ^[0-9]+$ ]] || n="${#s}"
  printf '%s' "$n"
}

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
  local current_disk="${1:-}" choice=""
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
  if have_tty; then
    if [[ "$LANG_CHOICE" == "de" ]]; then
      read -r -p "Ziel-Disk auswählen (1-${#disks[@]}): " choice </dev/tty >/dev/tty || choice=""
    else
      read -r -p "Select target disk (1-${#disks[@]}): " choice </dev/tty >/dev/tty || choice=""
    fi
  else
    die "Keine Eingabe möglich – bitte die Zieldisk mit --target angeben." \
        "No input possible – please name the target disk with --target."
  fi
  [[ "${choice:-}" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#disks[@]} )) || die "Ungültige Auswahl: $choice" "Invalid selection: $choice"

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
    M "  - Prüfe $(basename "$img") ..." "  - Checking $(basename "$img") ..." >&2
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
  has_cmd zstd && return 0
  if [[ "$want" == "on" || "$want" == "auto" ]]; then
    msg "[*] zstd ist nicht installiert." "[*] zstd is not installed."
    if ASK "Soll ich zstd automatisch installieren (apt)?" "Install zstd automatically (apt)?"; then
      need_cmd apt-get
      DEBIAN_FRONTEND=noninteractive apt-get update -y || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y zstd || true
      if ! has_cmd zstd; then
        die "Kompression ist erforderlich, aber zstd konnte nicht installiert werden." "Compression is required, but zstd could not be installed."
      else
        msg "[✓] zstd installiert." "[✓] zstd installed."
      fi
    else
      die "Kompression ist erforderlich, aber zstd fehlt." "Compression is required, but zstd is missing."
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

# Misst die tatsächlich zu erwartende zstd-Kompressionsrate anhand von
# Stichproben der Quell-Disk. Ausgabe: Rate in Promille (1000 = keine Kompression).
sample_compression_permille() {
  local dev="${1:?}" raw="${2:?}"
  local samples="${SPACE_SAMPLE_COUNT:-64}"
  local chunk_mib="${SPACE_SAMPLE_CHUNK_MIB:-8}"
  local chunk tmp step offset got comp raw_total=0 comp_total=0 i

  has_cmd zstd || return 1
  has_cmd stat || return 1
  [[ -r "$dev" ]] || return 1

  chunk=$(( chunk_mib * 1024 * 1024 ))
  (( samples > 0 && chunk > 0 && raw > chunk )) || return 1
  (( samples * chunk > raw )) && samples=$(( raw / chunk ))
  (( samples > 0 )) || return 1

  tmp="$(mktemp "${TMPDIR:-/tmp}/panzerbackup-sample.XXXXXX")" || return 1
  step=$(( (raw - chunk) / samples ))

  for (( i = 0; i < samples; i++ )); do
    offset=$(( step * i ))
    dd if="$dev" of="$tmp" bs="$chunk" count=1 skip="$offset" \
       iflag=skip_bytes,fullblock status=none 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    got="$(stat -c '%s' -- "$tmp" 2>/dev/null || echo 0)"
    [[ "$got" =~ ^[0-9]+$ ]] || got=0
    (( got > 0 )) || continue
    comp="$(zstd -T0 -"${ZSTD_LEVEL:-6}" -q -c -- "$tmp" 2>/dev/null | wc -c || true)"
    [[ "$comp" =~ ^[0-9]+$ ]] || { rm -f -- "$tmp"; return 1; }
    raw_total=$(( raw_total + got ))
    comp_total=$(( comp_total + comp ))
  done
  rm -f -- "$tmp"

  (( raw_total > 0 )) || return 1
  echo $(( (comp_total * 1000 + raw_total - 1) / raw_total ))
}

# Setzt SPACE_RAW_BYTES, SPACE_RATIO_PERMILLE, SPACE_IMAGE_BYTES, SPACE_REQUIRED_BYTES.
# $1 (optional): freier Speicher am Ziel. Passt schon die Rohgröße, entfällt das Sampling.
compute_space_requirements() {
  need_cmd blockdev
  local free_hint="${1:-0}" ratio est

  SPACE_RAW_BYTES="$(blockdev --getsize64 "$DISK")"
  SPACE_RATIO_PERMILLE=""
  SPACE_IMAGE_BYTES="$SPACE_RAW_BYTES"
  msg "[*] Rohgröße der Disk: $(human_bytes "$SPACE_RAW_BYTES")" \
      "[*] Raw disk size: $(human_bytes "$SPACE_RAW_BYTES")"

  if (( free_hint >= SPACE_RAW_BYTES + MIN_FREE_BYTES )); then
    SPACE_REQUIRED_BYTES=$(( SPACE_IMAGE_BYTES + MIN_FREE_BYTES ))
    return 0
  fi

  if [[ "${USE_COMPRESS:-true}" == "true" && "${SPACE_ESTIMATE_MODE:-sample}" == "sample" ]]; then
    msg "[*] Ermittle voraussichtliche Kompressionsrate (Stichproben von $DISK) ..." \
        "[*] Measuring expected compression ratio (sampling $DISK) ..."
    ratio="$(sample_compression_permille "$DISK" "$SPACE_RAW_BYTES" 2>/dev/null || true)"
    # Nicht komprimierbare Daten (z. B. LUKS-Container) liefern knapp über 1000 ‰.
    if [[ "$ratio" =~ ^[0-9]+$ ]] && (( ratio > 1000 )); then
      ratio=1000
    fi
    if [[ "$ratio" =~ ^[0-9]+$ ]] && (( ratio > 0 && ratio <= 1000 )); then
      SPACE_RATIO_PERMILLE="$ratio"
      est=$(( SPACE_RAW_BYTES / 1000 * ratio ))
      est=$(( est + est * SPACE_SAFETY_PERCENT / 100 ))
      (( est > SPACE_RAW_BYTES )) && est="$SPACE_RAW_BYTES"
      SPACE_IMAGE_BYTES="$est"
      msg "[*] Gemessene Kompressionsrate: $(( ratio / 10 ))% der Rohgröße (Sicherheitsaufschlag: ${SPACE_SAFETY_PERCENT}%)" \
          "[*] Measured compression ratio: $(( ratio / 10 ))% of raw size (safety margin: ${SPACE_SAFETY_PERCENT}%)"
    else
      msg "[!] Kompressionsrate nicht messbar – es wird mit der vollen Rohgröße gerechnet." \
          "[!] Compression ratio could not be measured – falling back to full raw size."
    fi
  fi

  SPACE_REQUIRED_BYTES=$(( SPACE_IMAGE_BYTES + MIN_FREE_BYTES ))
}

low_space_abort_or_warn() {
  local de="${1:?}" en="${2:?}"
  if [[ "${ALLOW_LOW_SPACE:-0}" == "1" ]]; then
    msg "[!] $de" "[!] $en"
    msg "[!] --force-space ist aktiv: Backup startet trotzdem und bricht ab, falls der Platz nicht reicht." \
        "[!] --force-space is active: the backup starts anyway and aborts if space runs out."
    return 0
  fi
  msg "    Hinweis: Bei verschlüsselten Disks (LUKS) lässt sich das Roh-Image kaum komprimieren." \
      "    Note: raw images of encrypted disks (LUKS) barely compress at all."
  msg "    Optionen: größeres Backup-Ziel, oder Start erzwingen mit --force-space bzw. ALLOW_LOW_SPACE=1." \
      "    Options: use a larger backup target, or force the start with --force-space / ALLOW_LOW_SPACE=1."
  die "$de" "$en"
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

  # Ein abgebrochener Lauf hinterlässt seine Partitionstabelle und ggf. die
  # Prüfsummendatei, weil beide vor dem Abbild geschrieben werden. Ohne das
  # zugehörige Abbild sind sie wertlos und sammeln sich über Jahre an.
  local meta base ext found
  for meta in "$BACKUP_DIR"/panzer_*.sfdisk "$BACKUP_DIR"/panzer_*.img*.sha256; do
    [[ -f "$meta" ]] || continue
    base="$(basename "$meta")"
    base="${base%.sfdisk}"; base="${base%.img*}"
    # Nur die tatsächlichen Abbildendungen zählen. Ein Muster wie ".img*"
    # würde auch die verwaiste Prüfsummendatei selbst treffen und sie damit
    # für immer am Leben halten.
    found=0
    for ext in .img .img.zst .img.gpg .img.zst.gpg; do
      [[ -f "${BACKUP_DIR}/${base}${ext}" ]] && { found=1; break; }
    done
    (( found )) && continue
    msg "  - Entferne verwaiste Metadaten: $(basename "$meta")" \
        "  - Removing orphaned metadata: $(basename "$meta")"
    rm -f -- "$meta"
  done
  return 0
}

backup_allocated_bytes() {
  local old="${1:?}" old_base old_sfdisk path blocks block_size total=0
  old_base="$(basename "$old")"
  old_sfdisk="${old_base%.img*}.sfdisk"

  for path in "$old" "${old}.sha256" "${BACKUP_DIR}/${old_sfdisk}"; do
    [[ -f "$path" ]] || continue
    read -r blocks block_size < <(stat -c '%b %B' -- "$path") || return 1
    total=$(( total + blocks * block_size ))
  done
  echo "$total"
}

remove_backups_with_metadata() {
  local old old_base old_sfdisk latest_target="" latest_base="" latest_deleted=0
  local -a files=()

  if [[ -L "${BACKUP_DIR}/LATEST_OK" ]]; then
    latest_target="$(readlink -f "${BACKUP_DIR}/LATEST_OK" 2>/dev/null || true)"
    if [[ -n "$latest_target" ]]; then
      latest_base="$(basename "$latest_target")"
    else
      latest_deleted=1
    fi
  fi

  for old in "$@"; do
    [[ -f "$old" ]] || continue
    old_base="$(basename "$old")"
    old_sfdisk="${old_base%.img*}.sfdisk"
    files+=("$old" "${old}.sha256" "${BACKUP_DIR}/${old_sfdisk}")
    [[ "$old_base" == "$latest_base" ]] && latest_deleted=1
  done

  (( ${#files[@]} > 0 )) && rm -f -- "${files[@]}"
  if (( latest_deleted )); then
    rm -f "${BACKUP_DIR}/LATEST_OK" "${BACKUP_DIR}/LATEST_OK.sha256" "${BACKUP_DIR}/LATEST_OK.sfdisk"
  fi
}

cleanup_oldest_backups_until_enough_space() {
  local required free

  free="$(get_free_bytes)"
  msg "[*] Freier Speicher auf Backup-Ziel: $(human_bytes "$free")" \
      "[*] Free space on backup target: $(human_bytes "$free")"

  compute_space_requirements "$free"
  required="$SPACE_REQUIRED_BYTES"

  if [[ -n "$SPACE_RATIO_PERMILLE" ]]; then
    msg "[*] Benötigt (geschätzte Backup-Größe + Reserve): $(human_bytes "$required")" \
        "[*] Required (estimated backup size + reserve): $(human_bytes "$required")"
  else
    msg "[*] Benötigt (Rohgröße Disk + Reserve): $(human_bytes "$required")" \
        "[*] Required (raw disk size + reserve): $(human_bytes "$required")"
  fi

  if (( free >= required )); then
    msg "[✓] Genug Speicherplatz vorhanden." "[✓] Enough free space available."
    return 0
  fi

  [[ "$AUTO_DELETE_OLDEST" == "1" ]] || \
    low_space_abort_or_warn "Zu wenig Speicherplatz auf dem Backup-Ziel und automatisches Löschen ist deaktiviert." \
        "Not enough free space on backup target and automatic deletion is disabled."
  [[ "$AUTO_DELETE_OLDEST" == "1" ]] || return 0
  need_cmd stat

  msg "[!] Zu wenig Speicherplatz. Älteste Backups werden automatisch entfernt..." \
      "[!] Not enough free space. Oldest backups will be deleted automatically..."

  local old old_bytes free_now bytes_needed estimated index=0
  local -a DELETE_BATCH=()
  mapfile -t OLD_BACKUPS < <(list_existing_backups_oldest_first)
  if (( ${#OLD_BACKUPS[@]} == 0 )); then
    low_space_abort_or_warn "Kein altes Backup zum Löschen vorhanden, aber zu wenig Speicherplatz." \
        "No old backup available for deletion, but there is not enough free space."
    return 0
  fi

  free_now="$free"
  while (( free_now < required && index < ${#OLD_BACKUPS[@]} )); do
    bytes_needed=$(( required - free_now ))
    estimated=0
    DELETE_BATCH=()

    while (( index < ${#OLD_BACKUPS[@]} )); do
      old="${OLD_BACKUPS[$index]}"
      index=$(( index + 1 ))
      [[ -f "$old" ]] || continue
      DELETE_BATCH+=("$old")
      old_bytes="$(backup_allocated_bytes "$old" 2>/dev/null || echo 0)"
      [[ "$old_bytes" =~ ^[0-9]+$ ]] || old_bytes=0
      estimated=$(( estimated + old_bytes ))
      (( estimated >= bytes_needed && estimated > 0 )) && break
    done

    (( ${#DELETE_BATCH[@]} > 0 )) || break
    for old in "${DELETE_BATCH[@]}"; do
      msg "  - Lösche altes Backup: $(basename "$old")" \
          "  - Deleting old backup: $(basename "$old")"
    done
    remove_backups_with_metadata "${DELETE_BATCH[@]}"
    free_now="$(get_free_bytes)"
    msg "    → Freier Speicher jetzt: $(human_bytes "$free_now")" \
        "    → Free space now: $(human_bytes "$free_now")"
  done

  if (( free_now >= required )); then
    msg "[✓] Genug Speicherplatz freigeräumt." "[✓] Enough free space has been freed."
    return 0
  fi

  free_now="$(get_free_bytes)"
  low_space_abort_or_warn "Trotz Löschen alter Backups nicht genug Speicher frei. Frei: $(human_bytes "$free_now"), benötigt: $(human_bytes "$required")" \
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

BACKUP_DIR="${BACKUP_DIR_OVERRIDE:-$(detect_backup_dir "$BACKUP_LABEL" || true)}"
[[ -d "${BACKUP_DIR:-}" && -w "${BACKUP_DIR:-}" ]] || die "Backup-Platte mit Label $BACKUP_LABEL nicht gefunden/ nicht schreibbar" "Backup drive with label $BACKUP_LABEL not found / not writable"

BACKUP_DISK="$(get_mount_backing_disk "$BACKUP_DIR" 2>/dev/null || true)"
PROTECTED_DISKS="${BACKUP_DISK:-} ${LIVE_ROOT_DISK:-} ${SCRIPT_SOURCE_DISK:-}"

KEEP="${KEEP:-3}"
MIN_FREE_BYTES="${MIN_FREE_BYTES:-2147483648}"
AUTO_DELETE_OLDEST="${AUTO_DELETE_OLDEST:-1}"
SPACE_ESTIMATE_MODE="${SPACE_ESTIMATE_MODE:-sample}"   # sample | raw
SPACE_SAMPLE_COUNT="${SPACE_SAMPLE_COUNT:-64}"
SPACE_SAMPLE_CHUNK_MIB="${SPACE_SAMPLE_CHUNK_MIB:-8}"
SPACE_SAFETY_PERCENT="${SPACE_SAFETY_PERCENT:-15}"
ALLOW_LOW_SPACE="${ALLOW_LOW_SPACE:-0}"
SPACE_RAW_BYTES=0
SPACE_RATIO_PERMILLE=""
SPACE_IMAGE_BYTES=0
SPACE_REQUIRED_BYTES=0
DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
BACKUP_NAME="${BACKUP_NAME:-}"
IMG_PREFIX=""
COMPRESS_MODE="on"
ZSTD_LEVEL="${ZSTD_LEVEL:-6}"

# --- Proxmox quiesce ---------------------------------------------------------
# Guests are NOT frozen by default.
#
# A full-disk image of a running system is crash-consistent anyway: while "dd"
# runs, the host's own mounted root filesystem keeps being written into the very
# same image. Freezing the guests for the whole copy therefore buys only partial
# consistency -- at the price of stalling every VM on the host for hours.
#
# That price is severe. Inside a frozen guest every write blocks in D state.
# After ~180 s the systemd-journald watchdog fires, journald is killed and
# restarted repeatedly, the journal gets corrupted, and services lose their log
# socket ("Transport endpoint is not connected"). On a Proxmox Backup Server
# guest this kills proxmox-backup-api, which exits *cleanly* -- so its
# Restart=on-failure never brings it back and backups fail silently for days.
#
# Guest consistency belongs at the guest layer: vzdump/PBS freezes each VM for
# about a second and does it correctly. Let this tool image the host instead.
PVE_QUIESCE_MODE="${PVE_QUIESCE_MODE:-off}"        # off | freeze
# Hard upper bound for a freeze. Must stay below journald's 180 s watchdog.
PVE_QUIESCE_MAX_SEC="${PVE_QUIESCE_MAX_SEC:-120}"

# --- PVE-DR (Proxmox Disaster Recovery) -------------------------------------
# Phase 4 implementiert ausschliesslich die lesende Bereitschaftspruefung.
BACKUP_MODE="${BACKUP_MODE:-raw}"          # raw | pve-dr
BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-0}"
PVE_DR_ALLOW_CRASH="${PVE_DR_ALLOW_CRASH:-0}"   # reserviert, ab Phase 5
PVE_DR_QGA_TIMEOUT="${PVE_DR_QGA_TIMEOUT:-5}"
# Klassischer Root-Snapshot: der COW-Bereich faellt nur mit dem an, was waehrend
# der Sicherung auf dem Root-LV ueberschrieben wird. Laeuft er voll, wird der
# Snapshot ungueltig - das kostet die Sicherung, nicht den laufenden Betrieb.
PVE_DR_COW_WARN="${PVE_DR_COW_WARN:-50}"
PVE_DR_COW_EXTEND="${PVE_DR_COW_EXTEND:-70}"
PVE_DR_COW_ABORT="${PVE_DR_COW_ABORT:-90}"
# Thin-Pool: hier trifft eine Erschoepfung die laufenden Gaeste, nicht nur die
# Sicherung. Deshalb liegen die Grenzen deutlich niedriger, Metadaten am
# niedrigsten - ein volles Metadaten-LV setzt den ganzen Pool schreibgeschuetzt.
PVE_DR_POOL_DATA_MAX="${PVE_DR_POOL_DATA_MAX:-80}"
PVE_DR_POOL_META_MAX="${PVE_DR_POOL_META_MAX:-60}"
PVE_DR_POOL_DATA_ABORT="${PVE_DR_POOL_DATA_ABORT:-90}"
PVE_DR_POOL_META_ABORT="${PVE_DR_POOL_META_ABORT:-80}"
PVE_DR_MONITOR_INTERVAL="${PVE_DR_MONITOR_INTERVAL:-5}"
PVE_DR_WATCHDOG_SEC="${PVE_DR_WATCHDOG_SEC:-120}"
PVE_DR_FREEZE_TIMEOUT="${PVE_DR_FREEZE_TIMEOUT:-60}"
PVE_DR_SHUTDOWN_TIMEOUT="${PVE_DR_SHUTDOWN_TIMEOUT:-300}"
PVE_DR_ALLOW_SHUTDOWN="${PVE_DR_ALLOW_SHUTDOWN:-0}"
PVE_DR_SPARSE_BS="${PVE_DR_SPARSE_BS:-1M}"
PVE_DR_MAX_PART_BYTES="${PVE_DR_MAX_PART_BYTES:-8589934592}"
PVE_DR_REBUILD_INITRAMFS="${PVE_DR_REBUILD_INITRAMFS:-auto}"
KEEP_PVE_DR="${KEEP_PVE_DR:-${KEEP:-3}}"
RESTORE_CANDIDATE_OVERRIDE=""

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
LOG_FILE_DEFAULT="${LOG_FILE_OVERRIDE:-${BACKUP_DIR}/panzerbackup.log}"

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
      --zstd-level) ZSTD_LEVEL="${2:-6}"; shift 2 ;;
      --force-space) ALLOW_LOW_SPACE="1"; shift ;;
      --no-space-estimate) SPACE_ESTIMATE_MODE="raw"; shift ;;
      --post) POST_ACTION="${2:-none}"; POST_ACTION_PRESET="1"; shift 2 ;;
      --encrypt) ENCRYPT_MODE="gpg"; shift ;;
      --no-encrypt) ENCRYPT_MODE="off"; shift ;;
      --passfile) ENCRYPT_PASSPHRASE="$(<"$2")"; shift 2 ;;
      --select-backup) SELECT_BACKUP="true"; shift ;;
      --disk) DISK="$2"; shift 2 ;;
      --name) BACKUP_NAME="$2"; shift 2 ;;
      --mode)
        case "${2:-}" in
          raw|pve-dr) BACKUP_MODE="$2" ;;
          *) die "Unbekannter Modus: ${2:-<leer>} (erlaubt: raw, pve-dr)" \
                 "Unknown mode: ${2:-<empty>} (allowed: raw, pve-dr)" ;;
        esac
        shift 2 ;;
      --dry-run) BACKUP_DRY_RUN="1"; shift ;;
      --allow-crash-consistent) PVE_DR_ALLOW_CRASH="1"; shift ;;
      --quiesce) PVE_QUIESCE_MODE="freeze"; shift ;;
      --no-quiesce) PVE_QUIESCE_MODE="off"; shift ;;
      --quiesce-max-sec) PVE_QUIESCE_MAX_SEC="${2:-120}"; shift 2 ;;
      *) die "Unbekannte Backup-Option: $1" "Unknown backup option: $1" ;;
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

  signal_process_group_or_tree "$pid" INT
  sleep 2
  signal_process_group_or_tree "$pid" TERM
  sleep 1
  if ps -p "$pid" >/dev/null 2>&1 || pgrep -P "$pid" >/dev/null 2>&1; then
    signal_process_group_or_tree "$pid" KILL
  fi

  rm -f "$PID_FILE"
  clear_passphrase_file
  if [[ "$LANG_CHOICE" == "de" ]]; then
    set_status "GESTOPPT: Manuell abgebrochen"
  else
    set_status "STOPPED: Aborted manually"
  fi
  resume_orphans
  msg "${R}Vorgang gestoppt.${NC}" "${R}Job stopped.${NC}"
}

# =====================[ PVE-DR: Erkennung & Preflight ]=======================
# Phase 4 ist ausschliesslich lesend: kein Snapshot, kein Freeze, keine
# LVM-Änderung, kein Schreibzugriff auf ein Blockgerät. Jeder externe Aufruf
# ist mit timeout abgesichert, damit ein hängender Storage die Prüfung nicht
# blockiert.

# L gibt einen bereits lokalisierten String zurück (ohne Zeilenumbruch), damit
# Befunde als fertiger Text in den Ergebnisarrays landen können.
L() { if [[ "$LANG_CHOICE" == "de" ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

PB_FAIL_TITLE=(); PB_FAIL_REASON=(); PB_FAIL_FIX=(); PB_FAIL_TECH=()
PB_WARN_TITLE=(); PB_WARN_REASON=()
PB_DETAILS=()

pb_fail()   { PB_FAIL_TITLE+=("$1"); PB_FAIL_REASON+=("$2"); PB_FAIL_FIX+=("$3"); PB_FAIL_TECH+=("${4:-}"); }
pb_warn()   { PB_WARN_TITLE+=("$1"); PB_WARN_REASON+=("$2"); }
pb_detail() { PB_DETAILS+=("$1"); }
pb_reset_findings() { PB_FAIL_TITLE=(); PB_FAIL_REASON=(); PB_FAIL_FIX=(); PB_FAIL_TECH=(); PB_WARN_TITLE=(); PB_WARN_REASON=(); PB_DETAILS=(); }

# Gleitkomma-Vergleich (lvs liefert z. B. "34.12"); leere Werte gelten als 0.
pb_pct_ge() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ exit !((a+0) >= (b+0)) }'; }
pb_pct_fmt() { awk -v a="${1:-}" 'BEGIN{ if (a=="") { print "-" } else { printf "%.1f %%", a+0 } }'; }

# --- Proxmox-Erkennung -------------------------------------------------------
PB_IS_PVE="${PB_IS_PVE:-}"      # setzbar, um die Erkennung in Tests zu überbrücken

# Die Paketdatenbank ist die verlässlichste Quelle: sie antwortet auch dann,
# wenn pvedaemon oder pmxcfs nicht laufen, und braucht keinen Dienst.
pb_pve_pkg_version() {
  local out
  has_cmd dpkg-query || return 1
  out="$(timeout 10 dpkg-query -W -f='${db:Status-Status} ${Version}' pve-manager 2>/dev/null || true)"
  [[ "$out" == "installed "* ]] || return 1
  out="${out#installed }"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

pve_is_host() {
  if [[ -z "$PB_IS_PVE" ]]; then
    PB_IS_PVE=0
    if pb_pve_pkg_version >/dev/null 2>&1; then
      PB_IS_PVE=1
    elif [[ -d /etc/pve ]] && { has_cmd qm || has_cmd pct; }; then
      PB_IS_PVE=1
    fi
  fi
  [[ "$PB_IS_PVE" == "1" ]]
}

# Die Gastkonfigurationen liegen im Proxmox-Konfigurationsdateisystem (pmxcfs).
# Ist es nicht eingehängt, gäbe es scheinbar null Gäste - das muss auffallen.
pve_pmxcfs_ok() {
  local fs
  fs="$(timeout 10 findmnt -no FSTYPE /etc/pve 2>/dev/null || true)"
  [[ "$fs" == fuse* ]] && return 0
  [[ -d /etc/pve/qemu-server || -d /etc/pve/lxc ]] && return 0
  return 1
}

pve_config_guest_count() {
  local d
  [[ "${1:-qemu}" == "lxc" ]] && d=/etc/pve/lxc || d=/etc/pve/qemu-server
  [[ -d "$d" ]] || { printf '0'; return 0; }
  printf '%s' "$(find "$d" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l)"
}

pve_version_string() {
  local v
  v="$(pb_pve_pkg_version 2>/dev/null || true)"
  if [[ -z "$v" ]] && has_cmd pveversion; then
    v="$(timeout 15 pveversion 2>/dev/null | head -n1 || true)"
    v="${v#pve-manager/}"
  fi
  v="${v%%/*}"
  [[ -n "$v" ]] || v="?"
  printf '%s' "$v"
}

# --- Gerät -> Disk (Ergänzung zu get_mount_backing_disk, das einen Pfad will)
# Geprüft auf einem echten LVM-auf-LUKS-System: "lsblk -rno PKNAME" liefert für
# Device-Mapper-Geräte (lvm, crypt) eine leere Ausgabe, ein PKNAME-Aufstieg
# bricht dort also sofort ab. Der inverse Gerätebaum (lsblk -s) läuft dagegen
# über alle Schichten und ist die Methode, die detect_system_disk bereits nutzt.
dev_to_disk() {
  local dev="${1:?}" out
  [[ -e "$dev" ]] || return 1
  out="$(timeout 15 lsblk -rpnso NAME,TYPE "$dev" 2>/dev/null \
         | awk '$2=="disk"{last=$1} END{if (last!="") print last}' || true)"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

# Alle Schichten zwischen einem Gerät und seiner Disk, je Zeile "typ|name".
dev_layer_stack() {
  timeout 15 lsblk -rpnso NAME,TYPE "${1:?}" 2>/dev/null | awk 'NF>=2{print $2"|"$1}' || true
}

# Mountpunkt eines Blockgeräts im Host-Namespace.
# findmnt --source löst alle Namensformen auf (/dev/<vg>/<lv>, /dev/mapper/...,
# /dev/dm-N) - real geprüft. Als zweite, namensunabhängige Quelle dient der
# Vergleich der Gerätenummern gegen /proc/self/mountinfo; damit ist die Auflösung
# von keiner Namenskonvention und von keinem festen Pfad abhängig.
pve_resolve_mountpoint() {
  local dev="${1:?}" mp mm maj min
  [[ -e "$dev" ]] || return 1
  mp="$(timeout 10 findmnt -rno TARGET --source "$dev" 2>/dev/null | head -n1 || true)"
  [[ -n "$mp" ]] && { printf '%s' "$mp"; return 0; }
  mm="$(stat -Lc '%t:%T' "$dev" 2>/dev/null || true)"
  [[ "$mm" =~ ^[0-9a-fA-F]+:[0-9a-fA-F]+$ ]] || return 1
  maj=$(( 16#${mm%%:*} )); min=$(( 16#${mm##*:} ))
  mp="$(awk -v want="${maj}:${min}" '$3==want{print $5; exit}' /proc/self/mountinfo 2>/dev/null || true)"
  [[ -n "$mp" ]] || return 1
  printf '%s' "$mp"
}

# --- LVM-Inventar ------------------------------------------------------------
# Feldindizes: 0 vg 1 lv 2 attr 3 size 4 pool 5 data% 6 meta% 7 origin 8 path 9 dm_path
PB_LV_ROWS=()
pb_lv_get() { local -a f=(); IFS='|' read -r -a f <<< "$1"; printf '%s' "${f[$2]:-}"; }

pve_lvm_load() {
  has_cmd lvs || return 1
  mapfile -t PB_LV_ROWS < <(
    timeout 30 lvs -a --noheadings --units b --nosuffix --separator '|' \
      -o vg_name,lv_name,lv_attr,lv_size,pool_lv,data_percent,metadata_percent,origin,lv_path,lv_dm_path \
      2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*|[[:space:]]*/|/g' || true
  )
  (( ${#PB_LV_ROWS[@]} > 0 ))
}

pve_lv_row() {   # $1=vg $2=lv -> Zeile oder leer
  local row
  (( ${#PB_LV_ROWS[@]} )) || return 1
  for row in "${PB_LV_ROWS[@]}"; do
    [[ "$(pb_lv_get "$row" 0)" == "$1" && "$(pb_lv_get "$row" 1)" == "$2" ]] || continue
    printf '%s' "$row"; return 0
  done
  return 1
}

# --- Layout ------------------------------------------------------------------
PB_VG=""; PB_ROOT_LV=""; PB_ROOT_SIZE=0; PB_ROOT_DEV=""
PB_THINPOOL=""; PB_POOL_SIZE=0; PB_POOL_DATA=""; PB_POOL_META=""
PB_PV=""; PB_DISK=""; PB_DISK_SIZE=0; PB_PTTYPE=""
PB_VG_SIZE=0; PB_VG_FREE=0
PB_SWAP_LV=""; PB_SWAP_SIZE=0; PB_SWAP_UUID=""

pve_layout_detect() {
  local src real row lp dp attr='' pvcount

  src="$(timeout 10 findmnt -no SOURCE / 2>/dev/null || true)"
  real="$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")"
  if [[ -z "$real" ]]; then
    pb_fail "$(L 'Root-Dateisystem'          'Root filesystem')" \
            "$(L 'Das Quellgerät von / konnte nicht ermittelt werden.' 'The source device of / could not be determined.')" \
            "$(L 'Bitte die Ausgabe von "findmnt -no SOURCE /" prüfen.' 'Please check the output of "findmnt -no SOURCE /".')" \
            "findmnt -no SOURCE / -> '${src}'"
    return 1
  fi

  for row in "${PB_LV_ROWS[@]}"; do
    lp="$(pb_lv_get "$row" 8)"; dp="$(pb_lv_get "$row" 9)"
    if [[ -n "$lp" && "$(readlink -f "$lp" 2>/dev/null || true)" == "$real" ]] \
    || [[ -n "$dp" && "$(readlink -f "$dp" 2>/dev/null || true)" == "$real" ]]; then
      PB_VG="$(pb_lv_get "$row" 0)"; PB_ROOT_LV="$(pb_lv_get "$row" 1)"
      PB_ROOT_SIZE="$(pb_lv_get "$row" 3)"; PB_ROOT_DEV="$lp"
      attr="$(pb_lv_get "$row" 2)"
      break
    fi
  done

  if [[ -z "$PB_VG" ]]; then
    pb_fail "$(L 'Root liegt nicht auf einem LVM-Volume' 'Root is not on an LVM volume')" \
            "$(L 'PVE-DR sichert das Root-Dateisystem aus einem LVM-Snapshot. Dieses System bootet aber nicht von einem Logical Volume (z. B. ZFS-, BTRFS- oder Plain-Partition-Root).' 'PVE-DR takes the root filesystem from an LVM snapshot. This system does not boot from a logical volume (for example ZFS, BTRFS or a plain partition root).')" \
            "$(L 'Für dieses Layout bitte das klassische RAW-Backup verwenden. Es sichert die gesamte Systemdisk unabhängig vom Dateisystem.' 'Use the classic RAW backup for this layout. It images the whole system disk regardless of the filesystem.')" \
            "root source: ${real}"
    return 1
  fi

  if [[ "${attr:0:1}" != "-" ]]; then
    pb_warn "$(L "Root-LV hat einen unerwarteten Typ (${attr})" "Root LV has an unexpected type (${attr})")" \
            "$(L 'Erwartet wird ein klassisches lineares LV. Der Snapshot-Plan geht davon aus.' 'A classic linear LV is expected. The snapshot plan assumes this.')"
  fi

  # VG-Kennzahlen
  local vgrow
  vgrow="$(timeout 20 vgs --noheadings --units b --nosuffix --separator '|' \
             -o vg_size,vg_free,pv_count "$PB_VG" 2>/dev/null \
           | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*|[[:space:]]*/|/g' || true)"
  PB_VG_SIZE="$(pb_lv_get "$vgrow" 0)"; PB_VG_FREE="$(pb_lv_get "$vgrow" 1)"
  pvcount="$(pb_lv_get "$vgrow" 2)"
  [[ "$PB_VG_SIZE" =~ ^[0-9]+$ ]] || PB_VG_SIZE=0
  [[ "$PB_VG_FREE" =~ ^[0-9]+$ ]] || PB_VG_FREE=0

  if [[ "$pvcount" =~ ^[0-9]+$ ]] && (( pvcount > 1 )); then
    pb_fail "$(L "Volume-Group ${PB_VG} liegt auf mehreren Datenträgern" "Volume group ${PB_VG} spans several disks")" \
            "$(L 'PVE-DR rekonstruiert beim Restore genau eine Systemdisk. Eine VG über mehrere Datenträger kann dabei nicht zuverlässig wiederhergestellt werden.' 'PVE-DR reconstructs exactly one system disk during restore. A VG spanning several disks cannot be restored reliably.')" \
            "$(L 'Für dieses Layout bitte das klassische RAW-Backup je Datenträger verwenden.' 'Use the classic RAW backup per disk for this layout.')" \
            "vgs -o pv_count ${PB_VG} = ${pvcount}"
  fi

  PB_PV="$(timeout 20 pvs --noheadings -o pv_name --select "vg_name=${PB_VG}" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
  if [[ -n "$PB_PV" ]]; then
    PB_DISK="$(dev_to_disk "$PB_PV" 2>/dev/null || true)"
    if [[ -n "$PB_DISK" ]]; then
      PB_DISK_SIZE="$(timeout 10 blockdev --getsize64 "$PB_DISK" 2>/dev/null || echo 0)"
      PB_PTTYPE="$(timeout 10 lsblk -rno PTTYPE "$PB_DISK" 2>/dev/null | head -n1 || true)"
    fi

    # Zwischen dem physischen Volume und der Disk darf nur eine Partition
    # liegen. Verschlüsselung, Software-RAID oder Multipath dazwischen kann der
    # Restore in Version 1 nicht nachbauen - dann lieber ehrlich absagen.
    local ltype lname foreign=""
    while IFS='|' read -r ltype lname; do
      [[ -n "$ltype" ]] || continue
      case "$ltype" in
        part|disk) ;;
        *) foreign+="${lname} (${ltype}) " ;;
      esac
    done < <(dev_layer_stack "$PB_PV")
    if [[ -n "$foreign" ]]; then
      pb_fail "$(L 'Zwischenschicht auf dem Systemdatenträger' 'Extra layer on the system disk')" \
              "$(L "Zwischen dem Datenträger und der Proxmox-Speicherstruktur liegt noch eine weitere Schicht (${foreign%% }). Die Disaster-Recovery-Sicherung kann diese Schicht beim Wiederherstellen nicht selbst neu aufbauen." "There is an additional layer between the disk and the Proxmox storage structure (${foreign%% }). The disaster recovery restore cannot rebuild that layer.")" \
              "$(L 'Für solche Systeme das klassische RAW-Backup verwenden: es sichert den Datenträger vollständig als Rohabbild, einschließlich dieser Schicht.' 'Use the classic RAW backup for such systems: it images the whole disk including that layer.')" \
              "pv=${PB_PV} stack: ${foreign%% }"
    fi
  fi
  if [[ -z "$PB_DISK" ]]; then
    pb_fail "$(L 'Systemdisk nicht eindeutig bestimmbar' 'System disk could not be determined')" \
            "$(L 'Der Datenträger hinter der Volume-Group konnte nicht ermittelt werden.' 'The disk behind the volume group could not be determined.')" \
            "$(L 'Bitte die Ausgaben von "pvs" und "lsblk" prüfen und zurückmelden.' 'Please check and report the output of "pvs" and "lsblk".')" \
            "pv='${PB_PV}'"
  fi

  # Thin-Pools und Swap der VG einsammeln
  local pools=() name
  for row in "${PB_LV_ROWS[@]}"; do
    [[ "$(pb_lv_get "$row" 0)" == "$PB_VG" ]] || continue
    name="$(pb_lv_get "$row" 1)"; attr="$(pb_lv_get "$row" 2)"
    [[ "${name:0:1}" == "[" ]] && continue
    case "${attr:0:1}" in
      t) pools+=("$name") ;;
    esac
    if [[ -z "$PB_SWAP_LV" && -n "$(pb_lv_get "$row" 8)" ]]; then
      if [[ "$(timeout 5 blkid -o value -s TYPE "$(pb_lv_get "$row" 8)" 2>/dev/null || true)" == "swap" ]]; then
        PB_SWAP_LV="$name"; PB_SWAP_SIZE="$(pb_lv_get "$row" 3)"
        PB_SWAP_UUID="$(timeout 5 blkid -o value -s UUID "$(pb_lv_get "$row" 8)" 2>/dev/null || true)"
      fi
    fi
  done

  if (( ${#pools[@]} == 1 )); then
    PB_THINPOOL="${pools[0]}"
  elif (( ${#pools[@]} > 1 )); then
    PB_THINPOOL=""     # Entscheidung fällt später anhand der Gastvolumes
    pb_detail "$(L "Mehrere Thin-Pools in ${PB_VG}: ${pools[*]}" "Multiple thin pools in ${PB_VG}: ${pools[*]}")"
  fi

  if [[ -n "$PB_THINPOOL" ]]; then
    local prow
    prow="$(pve_lv_row "$PB_VG" "$PB_THINPOOL" || true)"
    PB_POOL_SIZE="$(pb_lv_get "$prow" 3)"
    PB_POOL_DATA="$(pb_lv_get "$prow" 5)"
    PB_POOL_META="$(pb_lv_get "$prow" 6)"
  fi
  return 0
}

# --- Boot-Methode ------------------------------------------------------------
PB_BOOT_METHOD=""; PB_BOOT_DETAIL=""; PB_ESP=""; PB_ESP_MP=""; PB_BIOSBOOT=""
# GUIDs nach der GPT-Spezifikation - stabiler als jeder Mountpfad.
PB_GUID_ESP="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
PB_GUID_BIOSBOOT="21686148-6449-6e6f-744e-656564454649"

pve_boot_detect() {
  local esps=()
  [[ -n "${PB_DISK:-}" ]] && mapfile -t esps < <(
    timeout 15 lsblk -rno PATH,PARTTYPE "$PB_DISK" 2>/dev/null \
      | awk -v g="$PB_GUID_ESP" 'tolower($2)==g{print $1}' || true)
  PB_ESP="${esps[0]:-}"
  (( ${#esps[@]} > 1 )) && pb_detail "$(L "Mehrere EFI-Partitionen: ${esps[*]}" "Multiple EFI partitions: ${esps[*]}")"

  # Der Mountpunkt der EFI-Partition wird aufgelöst, nicht angenommen.
  [[ -n "$PB_ESP" ]] && PB_ESP_MP="$(pve_resolve_mountpoint "$PB_ESP" 2>/dev/null || true)"

  PB_BIOSBOOT="$( [[ -n "${PB_DISK:-}" ]] && timeout 15 lsblk -rno PATH,PARTTYPE "$PB_DISK" 2>/dev/null \
      | awk -v g="$PB_GUID_BIOSBOOT" 'tolower($2)==g{print $1; exit}' || true)"

  if [[ -s /etc/kernel/proxmox-boot-uuids ]]; then
    PB_BOOT_METHOD="proxmox-boot-tool"
    if has_cmd proxmox-boot-tool; then
      PB_BOOT_DETAIL="$(timeout 20 proxmox-boot-tool status 2>&1 | tr '\n' ';' || true)"
      case "$PB_BOOT_DETAIL" in
        *systemd-boot*) PB_BOOT_METHOD="proxmox-boot-tool (systemd-boot)" ;;
        *grub*)         PB_BOOT_METHOD="proxmox-boot-tool (grub)" ;;
      esac
    fi
    PB_BOOT_DETAIL="${PB_BOOT_DETAIL}uuids=$(tr '\n' ',' < /etc/kernel/proxmox-boot-uuids 2>/dev/null || true)"
  elif [[ -d /sys/firmware/efi ]]; then
    # Erst am aufgelösten Mountpunkt nachsehen, nicht unter einem festen Pfad.
    if [[ -n "$PB_ESP_MP" ]]; then
      PB_BOOT_DETAIL="esp mounted at ${PB_ESP_MP}"
      if   [[ -d "$PB_ESP_MP/EFI/systemd" ]]; then PB_BOOT_METHOD="UEFI + systemd-boot"
      elif [[ -d "$PB_ESP_MP/EFI/proxmox" ]]; then PB_BOOT_METHOD="UEFI + GRUB (proxmox)"
      elif [[ -d "$PB_ESP_MP/EFI/debian"  ]]; then PB_BOOT_METHOD="UEFI + GRUB (debian)"
      elif [[ -d "$PB_ESP_MP/EFI"         ]]; then PB_BOOT_METHOD="UEFI + GRUB"
      else
        # Eingehängt, aber der Inhalt ist nicht lesbar - das ist etwas anderes
        # als "nicht eingehängt" und darf nicht so gemeldet werden.
        PB_BOOT_METHOD="UEFI"
        PB_BOOT_DETAIL="${PB_BOOT_DETAIL} (Inhalt nicht lesbar)"
        pb_warn "$(L 'Startbereich nicht einsehbar' 'Boot area not inspectable')" \
                "$(L 'Die EFI-Partition ist eingehängt, ihr Inhalt ließ sich aber nicht lesen. Läuft die Prüfung ohne Administratorrechte? Der Startbereich wird in jedem Fall vollständig gesichert.' 'The EFI partition is mounted but its content could not be read. Is the check running without administrator rights? The boot area is captured completely in any case.')"
      fi
    elif [[ -n "$PB_ESP" ]]; then
      PB_BOOT_METHOD="UEFI"
      PB_BOOT_DETAIL="esp ${PB_ESP} not mounted"
      pb_warn "$(L 'EFI-Partition ist nicht eingehängt' 'EFI partition is not mounted')" \
              "$(L 'Der Startbereich wird trotzdem vollständig gesichert; die genaue Startvariante lässt sich so aber nicht bestimmen.' 'The boot area is still captured completely, but the exact boot variant cannot be determined this way.')"
    fi
  elif [[ -n "$PB_BIOSBOOT" ]]; then
    PB_BOOT_METHOD="Legacy BIOS + GRUB"; PB_BOOT_DETAIL="bios-boot: $PB_BIOSBOOT"
  fi

  if [[ -z "$PB_BOOT_METHOD" ]]; then
    pb_fail "$(L 'Startverfahren nicht erkannt' 'Boot method not recognised')" \
            "$(L 'Es ließ sich nicht feststellen, wie dieses System startet. Ohne diese Information könnte eine Wiederherstellung ein nicht startfähiges System hinterlassen.' 'It could not be determined how this system boots. Without that information a restore could leave a system that does not start.')" \
            "$(L 'Bitte die Diagnose aus den erweiterten Optionen exportieren und melden. Bis dahin bleibt das klassische RAW-Backup der sichere Weg - es sichert den Startbereich unverändert mit.' 'Please export the diagnostics from the advanced options and report them. Until then the classic RAW backup is the safe route - it captures the boot area unchanged.')" \
            "disk=${PB_DISK:-?} esp=${PB_ESP:-none} biosboot=${PB_BIOSBOOT:-none} efi_dir=$( [[ -d /sys/firmware/efi ]] && echo yes || echo no)"
  fi
}

# --- Storage-Konfiguration ---------------------------------------------------
declare -A PB_ST_TYPE=() PB_ST_VG=() PB_ST_POOL=() PB_ST_PATH=() PB_ST_CONTENT=()
pve_storage_load() {
  local cfgfile="${PB_STORAGE_CFG:-/etc/pve/storage.cfg}" cur="" line key val
  [[ -r "$cfgfile" ]] || return 1
  while IFS= read -r line; do
    if [[ "$line" =~ ^([a-z]+):[[:space:]]*([A-Za-z0-9._+-]+)[[:space:]]*$ ]]; then
      cur="${BASH_REMATCH[2]}"; PB_ST_TYPE["$cur"]="${BASH_REMATCH[1]}"; continue
    fi
    [[ -n "$cur" ]] || continue
    [[ "$line" =~ ^[[:space:]]+([a-z_]+)[[:space:]]+(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    case "$key" in
      vgname)   PB_ST_VG["$cur"]="$val" ;;
      thinpool) PB_ST_POOL["$cur"]="$val" ;;
      path)     PB_ST_PATH["$cur"]="$val" ;;
      content)  PB_ST_CONTENT["$cur"]="$val" ;;
    esac
  done < "$cfgfile"
  return 0
}

# Liegt ein Pfad auf dem Root-LV? (K10: Directory-Storage über dem Root-LV)
# Achtung: der Pfad stammt aus storage.cfg und kann auf einer nicht mehr
# erreichbaren Netzfreigabe liegen. Ohne Timeout würde die Prüfung dort hängen.
pb_path_on_root_lv() {
  local p="${1:?}" src
  src="$(timeout 10 findmnt -no SOURCE --target "$p" 2>/dev/null || true)"
  [[ -n "$src" ]] || return 1
  [[ "$(readlink -f "$src" 2>/dev/null || true)" == "$(readlink -f "${PB_ROOT_DEV:-/nonexistent}" 2>/dev/null || true)" ]]
}

# --- Gäste ------------------------------------------------------------------
PB_GUESTS=()        # "type|id|status"
PB_VOLUMES=()       # "type|id|key|vg|lv|lvtype|size|allocated"
PB_QM_OK=1; PB_PCT_OK=1

pve_guests_load() {
  PB_GUESTS=()
  local id st out
  if has_cmd qm; then
    if out="$(timeout 30 qm list 2>/dev/null)"; then
      while read -r id st; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        PB_GUESTS+=("qemu|$id|${st:-unknown}")
      done < <(printf '%s\n' "$out" | awk 'NR>1{print $1" "$3}')
    else
      PB_QM_OK=0
    fi
  fi
  if has_cmd pct; then
    if out="$(timeout 30 pct list 2>/dev/null)"; then
      while read -r id st; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        PB_GUESTS+=("lxc|$id|${st:-unknown}")
      done < <(printf '%s\n' "$out" | awk 'NR>1{print $1" "$2}')
    else
      PB_PCT_OK=0
    fi
  fi
}

pve_guest_config_text() {
  local t="$1" id="$2"
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  if [[ "$t" == "qemu" ]]; then timeout 20 qm  config "$id" 2>/dev/null
  else                          timeout 20 pct config "$id" 2>/dev/null; fi
}

# Gibt "key|volid|extra" je Datenträger-Eintrag aus (CD-ROMs übersprungen).
pve_parse_volume_lines() {
  local t="$1" cfg="$2" line key val volid extra
  while IFS= read -r line; do
    key="${line%%:*}"; val="${line#*: }"
    [[ "$key" == "$line" ]] && continue
    if [[ "$t" == "qemu" ]]; then
      [[ "$key" =~ ^(ide[0-3]|sata[0-5]|scsi([0-9]|[12][0-9]|30)|virtio([0-9]|1[0-5])|efidisk0|tpmstate0|unused[0-9]+)$ ]] || continue
    else
      [[ "$key" =~ ^(rootfs|mp[0-9]+|unused[0-9]+)$ ]] || continue
    fi
    volid="${val%%,*}"; extra="${val#*,}"; [[ "$extra" == "$val" ]] && extra=""
    [[ "$extra" == *"media=cdrom"* ]] && continue
    [[ "$volid" == "none" || -z "$volid" ]] && continue
    printf '%s|%s|%s\n' "$key" "$volid" "$extra"
  done <<< "$cfg"
}

# "ok|vg|lv" oder "unsupported|<grund>|<detail>"
pve_volume_classify() {
  local volid="$1" storage rest sttype stvg
  if [[ "${volid:0:1}" == "/" ]]; then
    printf 'unsupported|bindmount|%s' "$volid"; return 0
  fi
  if [[ "$volid" != *:* ]]; then
    printf 'unsupported|unparsable|%s' "$volid"; return 0
  fi
  storage="${volid%%:*}"; rest="${volid#*:}"
  sttype="${PB_ST_TYPE[$storage]:-}"
  if [[ -z "$sttype" ]]; then
    printf 'unsupported|unknown-storage|%s' "$storage"; return 0
  fi
  case "$sttype" in
    lvmthin|lvm)
      stvg="${PB_ST_VG[$storage]:-}"
      if [[ "$stvg" != "$PB_VG" ]]; then
        printf 'unsupported|other-vg|%s' "${stvg:-?}"; return 0
      fi
      printf 'ok|%s|%s' "$stvg" "$rest"; return 0 ;;
    dir)
      if pb_path_on_root_lv "${PB_ST_PATH[$storage]:-/nonexistent}"; then
        printf 'unsupported|dir-on-root|%s' "$storage"; return 0
      fi
      printf 'unsupported|dir-external|%s' "$storage"; return 0 ;;
    *)
      printf 'unsupported|storage-type|%s:%s' "$storage" "$sttype"; return 0 ;;
  esac
}

# --- Quiesce-Fähigkeit ------------------------------------------------------
# Der Wert von "agent:" kennt mehrere Schreibweisen: "1", "0",
# "enabled=1,fstrim_cloned_disks=1", "1,fstrim_cloned_disks=1".
pb_qemu_agent_enabled() {
  local val part
  val="$(grep -m1 -E '^agent:' <<< "${1:-}" || true)"
  [[ -n "$val" ]] || return 1
  val="${val#agent:}"; val="${val# }"
  while IFS= read -r part; do
    part="${part// /}"
    case "$part" in
      1|enabled=1) return 0 ;;
      0|enabled=0) return 1 ;;
    esac
  done < <(printf '%s\n' "${val//,/$'\n'}")
  return 1
}

# Proxmox kennt zusätzlich "freeze-fs-on-backup=0" (auch als "freeze-fs=0"
# geschrieben). Damit hat der Betreiber das Anhalten der Dateisysteme für diese
# VM bewusst abgeschaltet - meist, weil der Gast das nicht verträgt. Panzerbackup
# darf sich darüber nicht stillschweigend hinwegsetzen.
pb_qemu_fsfreeze_disabled() {
  local val part
  val="$(grep -m1 -E '^agent:' <<< "${1:-}" || true)"
  [[ -n "$val" ]] || return 1
  val="${val#agent:}"; val="${val# }"
  while IFS= read -r part; do
    part="${part// /}"
    case "$part" in
      freeze-fs=0|freeze-fs-on-backup=0) return 0 ;;
    esac
  done < <(printf '%s\n' "${val//,/$'\n'}")
  return 1
}

# "ok" | "agent-disabled" | "timeout" | "unreachable"
pve_qga_probe() {
  local vmid="$1" cfg="$2" rc=0
  pb_qemu_agent_enabled "$cfg" || { printf 'agent-disabled'; return 0; }
  timeout "${PVE_DR_QGA_TIMEOUT:-5}" qm agent "$vmid" ping >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0)   printf 'ok' ;;
    124) printf 'timeout' ;;
    *)   printf 'unreachable' ;;
  esac
}

pve_dr_check_guests() {
  local g t id st line key volid extra cls status reason detail cfg
  local vg lv row size alloc lvtype qga volcount pools_used=()

  PB_VOLUMES=(); PB_GUEST_REPORT=()

  if (( PB_QM_OK == 0 )); then
    pb_fail "$(L 'Liste der virtuellen Maschinen nicht lesbar' 'List of virtual machines not readable')" \
            "$(L "Proxmox hat die Liste der virtuellen Maschinen nicht geliefert. Auf diesem Host liegen $(pve_config_guest_count qemu) VM-Konfigurationen - eine Sicherung würde sie stillschweigend auslassen." "Proxmox did not return the list of virtual machines. This host has $(pve_config_guest_count qemu) VM configurations - a backup would silently skip them.")" \
            "$(L 'Bitte prüfen, ob die Proxmox-Dienste laufen (systemctl status pvedaemon pve-cluster), und die Prüfung wiederholen.' 'Please check that the Proxmox services are running (systemctl status pvedaemon pve-cluster) and run the check again.')" \
            "qm list failed"
  fi
  if (( PB_PCT_OK == 0 )); then
    pb_fail "$(L 'Liste der Container nicht lesbar' 'List of containers not readable')" \
            "$(L "Proxmox hat die Liste der Container nicht geliefert. Auf diesem Host liegen $(pve_config_guest_count lxc) Container-Konfigurationen - eine Sicherung würde sie stillschweigend auslassen." "Proxmox did not return the list of containers. This host has $(pve_config_guest_count lxc) container configurations - a backup would silently skip them.")" \
            "$(L 'Bitte prüfen, ob die Proxmox-Dienste laufen (systemctl status pvedaemon pve-cluster), und die Prüfung wiederholen.' 'Please check that the Proxmox services are running (systemctl status pvedaemon pve-cluster) and run the check again.')" \
            "pct list failed"
  fi

  for g in ${PB_GUESTS[@]+"${PB_GUESTS[@]}"}; do
    IFS='|' read -r t id st <<< "$g"
    volcount=0; qga="-"

    # Eine unlesbare Konfiguration darf nicht als "null Datenträger" durchgehen.
    cfg="$(pve_guest_config_text "$t" "$id" || true)"
    if [[ -z "$cfg" ]]; then
      pb_fail "$(L "Konfiguration von $( [[ $t == lxc ]] && echo "Container" || echo "VM" ) ${id} nicht lesbar" "Configuration of $( [[ $t == lxc ]] && echo "container" || echo "VM" ) ${id} not readable")" \
              "$(L "Proxmox hat die Konfiguration nicht geliefert. Es lässt sich daher nicht feststellen, welche Datenträger zu diesem Gast gehören - eine Sicherung könnte unvollständig sein, ohne es zu merken." "Proxmox did not return the configuration. It is therefore impossible to tell which disks belong to this guest - a backup could be incomplete without noticing.")" \
              "$(L 'Bitte prüfen, ob die Proxmox-Dienste laufen, und die Prüfung wiederholen.' 'Please check that the Proxmox services are running and run the check again.')" \
              "${t}/${id}: config unreadable"
      PB_GUEST_REPORT+=("$t|$id|$st|unbekannt|0")
      continue
    fi

    if [[ "$st" == "running" && "$t" == "qemu" ]]; then
      qga="$(pve_qga_probe "$id" "$cfg")"
      if [[ "$qga" == "ok" ]] && pb_qemu_fsfreeze_disabled "$cfg"; then
        # Mit ausdrücklich erlaubtem Herunterfahren ist dieser Gast kein
        # Abbruchgrund: der Lauf stoppt ihn für die Momentaufnahme kontrolliert
        # und startet ihn danach wieder (siehe pve_dr_snapshot_one_guest).
        if [[ "${PVE_DR_ALLOW_SHUTDOWN:-0}" == "1" ]]; then
          qga="freeze-aus/stop"
          pb_warn "$(L "VM ${id} wird für die Sicherung heruntergefahren" "VM ${id} will be shut down for the backup")" \
                  "$(L "Für diese VM ist das Anhalten der Dateisysteme abgeschaltet (Option freeze-fs-on-backup=0). Da das Herunterfahren von Gästen ausdrücklich erlaubt wurde (PVE_DR_ALLOW_SHUTDOWN=1), fährt der Lauf diese VM kontrolliert herunter, legt die Momentaufnahme an und startet sie danach wieder. Für die Dauer dieses Vorgangs ist sie nicht verfügbar." "For this VM, pausing the filesystems is disabled (option freeze-fs-on-backup=0). Since shutting down guests was explicitly permitted (PVE_DR_ALLOW_SHUTDOWN=1), the run shuts this VM down in a controlled way, takes the snapshot and starts it again afterwards. It is unavailable for the duration of that step.")"
        else
          qga="freeze-aus"
          pb_fail "$(L "VM ${id} kann nicht konsistent gesichert werden" "VM ${id} cannot be backed up consistently")" \
                  "$(L "Für diese VM ist das Anhalten der Dateisysteme ausdrücklich abgeschaltet (Option freeze-fs-on-backup=0). Der Gastagent ist zwar erreichbar, darf die Dateisysteme aber nicht kurz anhalten - die Sicherung wäre nur so konsistent wie nach einem Stromausfall." "For this VM, pausing the filesystems is explicitly disabled (option freeze-fs-on-backup=0). The guest agent is reachable but must not pause the filesystems - the backup would only be as consistent as after a power cut.")" \
                  "$(L "Entweder die Option in der VM-Konfiguration wieder aktivieren (Optionen -> QEMU Guest Agent -> Freeze-FS-on-Backup), oder die VM für die Sicherung stoppen. Wurde sie bewusst abgeschaltet, weil der Gast das Anhalten nicht verträgt, ist diese VM für das Disaster-Recovery-Verfahren nicht geeignet." "Either re-enable the option in the VM configuration (Options -> QEMU Guest Agent -> Freeze-FS-on-Backup), or stop the VM for the backup. If it was disabled deliberately because the guest cannot tolerate the pause, this VM is not suitable for the disaster recovery procedure.")" \
                  "vmid=${id} agent has freeze-fs-on-backup=0"
        fi
      fi
      case "$qga" in
        ok) : ;;
        freeze-aus|freeze-aus/stop) : ;;
        agent-disabled)
          pb_fail "$(L "VM ${id} kann nicht konsistent gesichert werden" "VM ${id} cannot be backed up consistently")" \
                  "$(L "Der QEMU-Gastagent ist für diese VM nicht aktiviert. Ohne ihn lässt sich das Dateisystem im Gast für die Momentaufnahme nicht kurz anhalten." "The QEMU guest agent is not enabled for this VM. Without it the guest filesystem cannot be paused briefly for the snapshot.")" \
                  "$(L "In der VM-Konfiguration den Gastagenten aktivieren (Optionen -> QEMU Guest Agent), im Gast das Paket qemu-guest-agent installieren und starten, danach die Prüfung wiederholen. Alternativ die VM stoppen." "Enable the guest agent in the VM options, install and start qemu-guest-agent inside the guest, then run the check again. Alternatively stop the VM.")" \
                  "vmid=${id} agent not enabled in config" ;;
        timeout)
          pb_fail "$(L "VM ${id} kann nicht konsistent gesichert werden" "VM ${id} cannot be backed up consistently")" \
                  "$(L "Der QEMU-Gastagent antwortet nicht." "The QEMU guest agent does not respond.")" \
                  "$(L "Im Gast prüfen, ob der Dienst qemu-guest-agent läuft (systemctl status qemu-guest-agent), und ihn starten. Danach die Prüfung wiederholen. Alternativ die VM stoppen." "Check inside the guest whether qemu-guest-agent is running (systemctl status qemu-guest-agent) and start it, then run the check again. Alternatively stop the VM.")" \
                  "vmid=${id} QGA timeout after ${PVE_DR_QGA_TIMEOUT:-5}s" ;;
        *)
          pb_fail "$(L "VM ${id} kann nicht konsistent gesichert werden" "VM ${id} cannot be backed up consistently")" \
                  "$(L "Der QEMU-Gastagent ist nicht erreichbar." "The QEMU guest agent is unreachable.")" \
                  "$(L "Im Gast das Paket qemu-guest-agent installieren und starten, danach die Prüfung wiederholen. Alternativ die VM stoppen." "Install and start qemu-guest-agent inside the guest, then run the check again. Alternatively stop the VM.")" \
                  "vmid=${id} qm agent ping failed" ;;
      esac
    elif [[ "$st" == "running" ]]; then
      qga="fsfreeze"
    fi

    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      IFS='|' read -r key volid extra <<< "$line"
      cls="$(pve_volume_classify "$volid")"
      IFS='|' read -r status reason detail <<< "$cls"

      if [[ "$status" != "ok" ]]; then
        case "$reason" in
          bindmount)
            pb_fail "$(L "$( [[ $t == lxc ]] && echo CT || echo VM ) ${id} enthält einen externen Datenbereich" "$( [[ $t == lxc ]] && echo CT || echo VM ) ${id} contains an external data area")" \
                    "$(L "Der Eintrag ${key} verweist direkt auf ein Verzeichnis des Hosts (${detail}). Ein solcher Bereich liegt außerhalb der gesicherten Systemstruktur und wäre nach einer Wiederherstellung leer." "Entry ${key} points directly at a host directory (${detail}). Such an area lies outside the captured system structure and would be empty after a restore.")" \
                    "$(L "Diesen Bereich aus dem Gast entfernen oder getrennt sichern. Solange er eingebunden ist, kann PVE-DR keine vollständige Sicherung zusagen." "Remove this area from the guest or back it up separately. While it is attached, PVE-DR cannot promise a complete backup.")" \
                    "${t}/${id} ${key}: bind mount ${detail}" ;;
          dir-on-root)
            if [[ "$st" == "running" ]]; then
              pb_fail "$(L "$( [[ $t == lxc ]] && echo CT || echo VM ) ${id} liegt auf einem Verzeichnis-Speicher" "$( [[ $t == lxc ]] && echo CT || echo VM ) ${id} is stored on a directory storage")" \
                      "$(L "Der Datenträger ${key} liegt im Speicher '${detail}', der Teil des Systemdatenträgers ist. Er wird zwar mitgesichert, aber ohne die kurze Anhaltephase - der Gast läuft währenddessen weiter." "Disk ${key} is on storage '${detail}', which is part of the system disk. It is captured, but without the brief pause - the guest keeps running meanwhile.")" \
                      "$(L "Den Datenträger auf den Speicher local-lvm verschieben (Hardware -> Datenträger verschieben) oder den Gast für die Sicherung stoppen." "Move the disk to the local-lvm storage (Hardware -> Move disk) or stop the guest for the backup.")" \
                      "${t}/${id} ${key}: dir storage '${detail}' on root LV"
            else
              pb_detail "$(L "${t}/${id} ${key}: Verzeichnis-Speicher '${detail}' auf dem Root-LV, Gast gestoppt - im Root-Abbild enthalten" "${t}/${id} ${key}: directory storage '${detail}' on root LV, guest stopped - contained in the root image")"
            fi ;;
          *)
            pb_fail "$(L "$( [[ $t == lxc ]] && echo CT || echo VM ) ${id} nutzt einen nicht unterstützten Speicher" "$( [[ $t == lxc ]] && echo CT || echo VM ) ${id} uses an unsupported storage")" \
                    "$(L "Der Datenträger ${key} liegt auf '${detail}'. PVE-DR sichert derzeit nur Datenträger, die auf demselben LVM-Verbund wie das Proxmox-System liegen." "Disk ${key} is on '${detail}'. PVE-DR currently only captures disks on the same LVM group as the Proxmox system.")" \
                    "$(L "Den Datenträger auf den lokalen LVM-Speicher verschieben oder diesen Bereich getrennt sichern. Für eine reine Abbildsicherung des Systemdatenträgers steht weiterhin das klassische RAW-Backup zur Verfügung." "Move the disk to the local LVM storage or back this area up separately. The classic RAW backup remains available for a plain image of the system disk.")" \
                    "${t}/${id} ${key}: ${reason} ${detail}" ;;
        esac
        continue
      fi

      vg="$reason"; lv="$detail"
      row="$(pve_lv_row "$vg" "$lv" || true)"
      if [[ -z "$row" ]]; then
        pb_fail "$(L "Datenträger von $( [[ $t == lxc ]] && echo CT || echo VM ) ${id} nicht auffindbar" "Disk of $( [[ $t == lxc ]] && echo CT || echo VM ) ${id} not found")" \
                "$(L "Der in der Konfiguration eingetragene Datenträger ${vg}/${lv} existiert auf diesem System nicht." "The disk ${vg}/${lv} referenced in the configuration does not exist on this system.")" \
                "$(L "Die Gastkonfiguration prüfen und verwaiste Einträge entfernen." "Check the guest configuration and remove stale entries.")" \
                "${t}/${id} ${key}: ${vg}/${lv} not in lvs"
        continue
      fi
      size="$(pb_lv_get "$row" 3)"; [[ "$size" =~ ^[0-9]+$ ]] || size=0
      if [[ "$(pb_lv_get "$row" 2)" == V* ]]; then
        lvtype="thin"
        local dp; dp="$(pb_lv_get "$row" 5)"
        alloc="$(awk -v s="$size" -v p="${dp:-100}" 'BEGIN{printf "%d", s*(p+0)/100}')"
        local pl; pl="$(pb_lv_get "$row" 4)"
        [[ -n "$pl" ]] && pools_used+=("$pl")
      else
        lvtype="thick"; alloc="$size"
      fi
      PB_VOLUMES+=("$t|$id|$key|$vg|$lv|$lvtype|$size|$alloc")
      volcount=$(( volcount + 1 ))
    done < <(pve_parse_volume_lines "$t" "$cfg")

    # Laufende Container: jedes eigene Volume (rootfs und alle Mountpoints) muss
    # sich am Host wiederfinden lassen, sonst kann es nicht kurz angehalten und
    # damit nicht konsistent gesichert werden.
    if [[ "$t" == "lxc" && "$st" == "running" ]]; then
      local ctv cvt cvi cvk cvg cvl mp cand missing=""
      for ctv in ${PB_VOLUMES[@]+"${PB_VOLUMES[@]}"}; do
        IFS='|' read -r cvt cvi cvk cvg cvl _ _ _ <<< "$ctv"
        [[ "$cvt" == "lxc" && "$cvi" == "$id" ]] || continue
        mp=""
        for cand in "/dev/${cvg}/${cvl}" "/dev/mapper/${cvg//-/--}-${cvl//-/--}"; do
          mp="$(pve_resolve_mountpoint "$cand" 2>/dev/null || true)"
          [[ -n "$mp" ]] && break
        done
        if [[ -n "$mp" ]]; then
          pb_detail "$(L "CT ${id} ${cvk} am Host eingehängt unter ${mp}" "CT ${id} ${cvk} mounted on the host at ${mp}")"
        else
          missing+="${cvk} "
        fi
      done
      if [[ -n "$missing" ]]; then
        qga="unklar"
        pb_fail "$(L "CT ${id} kann nicht konsistent gesichert werden" "CT ${id} cannot be backed up consistently")" \
                "$(L "Der Datenbereich ${missing%% } dieses Containers ist auf dem Host nicht auffindbar. Ohne diesen Bezug lässt er sich für die Momentaufnahme nicht kurz anhalten, und die Sicherung wäre nur so konsistent wie nach einem Stromausfall." "The data area ${missing%% } of this container could not be located on the host. Without it the area cannot be paused briefly for the snapshot, and the backup would only be as consistent as after a power cut.")" \
                "$(L "Den Container kurz stoppen und die Prüfung wiederholen - gestoppte Container werden ohne Anhalten sauber gesichert. Bleibt die Meldung, bitte den Diagnosebericht aus den erweiterten Optionen exportieren." "Stop the container briefly and run the check again - stopped containers are captured cleanly without pausing. If the message persists, export the diagnostics report from the advanced options.")" \
                "ctid=${id} no host mount for: ${missing%% }"
      fi
    fi

    PB_GUEST_REPORT+=("$t|$id|$st|$qga|$volcount")
  done

  # Mehrere Thin-Pools in Benutzung? (V1 unterstützt genau einen)
  if (( ${#pools_used[@]} > 0 )); then
    local uniq uniq_flat
    uniq="$(printf '%s\n' "${pools_used[@]}" | sort -u)"
    uniq_flat="$(printf '%s' "$uniq" | tr '\n' ' ')"
    if (( $(printf '%s\n' "$uniq" | wc -l) > 1 )); then
      pb_fail "$(L 'Mehrere Speicherpools in Benutzung' 'Several storage pools in use')" \
              "$(L "Die Gäste liegen auf mehr als einem Thin-Pool. PVE-DR unterstützt derzeit genau einen." "The guests are spread over more than one thin pool. PVE-DR currently supports exactly one.")" \
              "$(L 'Die Gastdatenträger auf einen gemeinsamen Pool zusammenführen oder das klassische RAW-Backup verwenden.' 'Consolidate the guest disks onto a single pool or use the classic RAW backup.')" \
              "pools: ${uniq_flat}"
    elif [[ -z "$PB_THINPOOL" ]]; then
      PB_THINPOOL="$uniq"
      local prow; prow="$(pve_lv_row "$PB_VG" "$PB_THINPOOL" || true)"
      PB_POOL_SIZE="$(pb_lv_get "$prow" 3)"
      PB_POOL_DATA="$(pb_lv_get "$prow" 5)"
      PB_POOL_META="$(pb_lv_get "$prow" 6)"
    fi
  fi
}

# --- COW-Planung für klassische Snapshots -----------------------------------
PB_COW_ROOT=0; PB_COW_TOTAL=0; PB_COW_RESERVE=0; PB_COW_BUDGET=0
pve_cow_plan() {
  local gib=$((1024*1024*1024)) want reserve budget vg lv lvtype size extra=0 v w

  (( PB_VG_FREE > 0 )) || {
    pb_fail "$(L 'Freier Platz in der Volume-Group nicht ermittelbar' 'Free space in the volume group is unknown')" \
            "$(L 'Ohne diese Angabe lässt sich der Root-Snapshot nicht sicher planen.' 'Without this value the root snapshot cannot be planned safely.')" \
            "$(L 'Bitte die Ausgabe von "vgs" zurückmelden.' 'Please report the output of "vgs".')"
    return 1
  }

  reserve=$(( PB_VG_FREE / 10 )); (( reserve < gib )) && reserve=$gib
  budget=$(( PB_VG_FREE - reserve )); (( budget < 0 )) && budget=0
  PB_COW_RESERVE="$reserve"; PB_COW_BUDGET="$budget"

  want=$(( PB_ROOT_SIZE / 10 ))
  (( want < 4*gib )) && want=$(( 4*gib ))
  (( want > PB_ROOT_SIZE )) && want="$PB_ROOT_SIZE"
  PB_COW_ROOT="$want"

  # Dicke (nicht-thin) Gastvolumes brauchen ebenfalls je einen klassischen COW.
  for v in ${PB_VOLUMES[@]+"${PB_VOLUMES[@]}"}; do
    IFS='|' read -r _ _ _ vg lv lvtype size _ <<< "$v"
    [[ "$lvtype" == "thick" ]] || continue
    w=$(( size / 10 )); (( w < gib )) && w=$gib
    extra=$(( extra + w ))
  done
  PB_COW_TOTAL=$(( PB_COW_ROOT + extra ))

  if (( PB_COW_TOTAL > budget )); then
    # proportional verkleinern, aber nie unter 2 GiB für den Root-Snapshot
    if (( budget >= 2*gib )); then
      PB_COW_ROOT=$(( budget * PB_COW_ROOT / PB_COW_TOTAL ))
      (( PB_COW_ROOT < 2*gib )) && PB_COW_ROOT=$(( 2*gib ))
      PB_COW_TOTAL="$budget"
      pb_warn "$(L 'Snapshot-Reserve ist knapp' 'Snapshot reserve is tight')" \
              "$(L "Der geplante Snapshot-Speicher wurde auf den verfügbaren Platz in ${PB_VG} verkleinert." "The planned snapshot space was reduced to the space available in ${PB_VG}.")"
    else
      pb_fail "$(L 'Zu wenig freier Platz in der Volume-Group' 'Not enough free space in the volume group')" \
              "$(L "Für den Snapshot des Systems werden mindestens 2 GiB freier Platz in ${PB_VG} benötigt; verfügbar sind $(human_bytes "$PB_VG_FREE")." "The system snapshot needs at least 2 GiB of free space in ${PB_VG}; only $(human_bytes "$PB_VG_FREE") are available.")" \
              "$(L "Platz freigeben, z. B. den Thin-Pool verkleinern oder ein nicht benötigtes Logical Volume entfernen. Danach die Prüfung wiederholen." "Free up space, for example by shrinking the thin pool or removing an unused logical volume, then run the check again.")" \
              "vg_free=${PB_VG_FREE} reserve=${reserve} budget=${budget}"
      return 1
    fi
  fi
  return 0
}

# --- Thin-Pool-Gesundheit ----------------------------------------------------
pve_thinpool_health() {
  [[ -n "$PB_THINPOOL" ]] || return 0
  if pb_pct_ge "$PB_POOL_DATA" "$PVE_DR_POOL_DATA_MAX"; then
    pb_fail "$(L 'Thin-Pool ist zu voll' 'Thin pool is too full')" \
            "$(L "Der Speicherpool ${PB_VG}/${PB_THINPOOL} ist zu $(pb_pct_fmt "$PB_POOL_DATA") belegt. Snapshots würden ihn weiter füllen; läuft er voll, verlieren alle laufenden VMs und Container den Zugriff auf ihre Datenträger." "The storage pool ${PB_VG}/${PB_THINPOOL} is $(pb_pct_fmt "$PB_POOL_DATA") full. Snapshots would fill it further; if it runs full, every running VM and container loses access to its disks.")" \
            "$(L 'Platz im Pool schaffen (nicht benötigte Datenträger oder alte Snapshots entfernen) oder den Pool vergrößern. Danach die Prüfung wiederholen.' 'Free space in the pool (remove unused disks or old snapshots) or enlarge the pool, then run the check again.')" \
            "data_percent=${PB_POOL_DATA} limit=${PVE_DR_POOL_DATA_MAX}"
  fi
  if pb_pct_ge "$PB_POOL_META" "$PVE_DR_POOL_META_MAX"; then
    pb_fail "$(L 'Verwaltungsbereich des Thin-Pools ist zu voll' 'Thin pool metadata is too full')" \
            "$(L "Der Verwaltungsbereich von ${PB_VG}/${PB_THINPOOL} ist zu $(pb_pct_fmt "$PB_POOL_META") belegt. Jeder zusätzliche Snapshot verbraucht davon; läuft er voll, wird der gesamte Pool schreibgeschützt und lässt sich nur offline reparieren." "The metadata area of ${PB_VG}/${PB_THINPOOL} is $(pb_pct_fmt "$PB_POOL_META") full. Every additional snapshot consumes metadata; if it runs full, the whole pool becomes read-only and can only be repaired offline.")" \
            "$(L "Verwaltungsbereich vergrößern: lvextend --poolmetadatasize +512M ${PB_VG}/${PB_THINPOOL}" "Enlarge the metadata area: lvextend --poolmetadatasize +512M ${PB_VG}/${PB_THINPOOL}")" \
            "metadata_percent=${PB_POOL_META} limit=${PVE_DR_POOL_META_MAX}"
  fi
}

# --- Platzbedarf -------------------------------------------------------------
PB_EST_READ=0; PB_EST_WRITE=0; PB_EST_RATIO=""; PB_TARGET_FREE=0
pve_dr_estimate_space() {
  local v vg lv lvtype size alloc ratio r_permille=0 gib=$((1024*1024*1024))

  PB_EST_READ=0; PB_EST_WRITE=0

  if [[ "${SPACE_ESTIMATE_MODE:-sample}" == "sample" && -r "${PB_ROOT_DEV:-}" ]] && (( PB_ROOT_SIZE > 0 )); then
    r_permille="$(sample_compression_permille "$PB_ROOT_DEV" "$PB_ROOT_SIZE" 2>/dev/null || true)"
  fi
  if [[ "$r_permille" =~ ^[0-9]+$ ]] && (( r_permille > 0 && r_permille <= 1000 )); then
    PB_EST_RATIO="$r_permille"
  else
    PB_EST_RATIO=""; r_permille=1000
  fi

  # Root-LV: klassisch, vollständig allokiert -> volle Größe lesen und rechnen
  PB_EST_READ=$(( PB_EST_READ + PB_ROOT_SIZE ))
  PB_EST_WRITE=$(( PB_EST_WRITE + PB_ROOT_SIZE / 1000 * r_permille ))

  # Gastvolumes: gelesen wird die volle logische Größe (K6), geschrieben nur
  # der belegte Anteil. Die Kompressionsrate der Gastdaten wird konservativ auf
  # höchstens 35 % Ersparnis gedeckelt - Gastdaten komprimieren schlechter als
  # ein frisch installiertes Root-Dateisystem.
  local guest_permille="$r_permille"; (( guest_permille < 350 )) && guest_permille=350
  for v in ${PB_VOLUMES[@]+"${PB_VOLUMES[@]}"}; do
    IFS='|' read -r _ _ _ vg lv lvtype size alloc <<< "$v"
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    [[ "$alloc" =~ ^[0-9]+$ ]] || alloc="$size"
    PB_EST_READ=$(( PB_EST_READ + size ))
    PB_EST_WRITE=$(( PB_EST_WRITE + alloc / 1000 * guest_permille ))
  done

  # Bootbereiche und Konfiguration: kleine, aber reale Fixposten
  PB_EST_WRITE=$(( PB_EST_WRITE + 2 * gib ))
  PB_EST_WRITE=$(( PB_EST_WRITE + PB_EST_WRITE * ${SPACE_SAFETY_PERCENT:-15} / 100 ))

  PB_TARGET_FREE="$(get_free_bytes 2>/dev/null || echo 0)"
  [[ "$PB_TARGET_FREE" =~ ^[0-9]+$ ]] || PB_TARGET_FREE=0

  local required=$(( PB_EST_WRITE + ${MIN_FREE_BYTES:-0} ))
  if (( PB_TARGET_FREE < required )); then
    pb_fail "$(L 'Zu wenig Platz auf dem Backup-Ziel' 'Not enough space on the backup target')" \
            "$(L "Auf ${BACKUP_DIR} sind $(human_bytes "$PB_TARGET_FREE") frei, benötigt werden voraussichtlich $(human_bytes "$required")." "${BACKUP_DIR} has $(human_bytes "$PB_TARGET_FREE") free, but about $(human_bytes "$required") are needed.")" \
            "$(L 'Ältere Sicherungen entfernen oder ein größeres Backup-Medium verwenden. Die Schätzung enthält bereits eine Sicherheitsreserve.' 'Remove older backups or use a larger backup medium. The estimate already includes a safety margin.')" \
            "free=${PB_TARGET_FREE} required=${required}"
  fi
}
# --- Diagnosebericht ---------------------------------------------------------
# Sensible Werte werden entfernt, BEVOR etwas geschrieben wird - der Benutzer
# soll den Bericht weitergeben können, ohne ihn selbst durchsehen zu müssen.
# Der private Schlüsselbereich von Proxmox (/etc/pve/priv) wird nie gelesen.
pb_redact() {
  # storage.cfg trennt Schlüssel und Wert mit Leerzeichen ("password geheim"),
  # Gastkonfigurationen mit Doppelpunkt ("cipassword: geheim") - beide Formen
  # müssen erfasst werden. Private Schlüssel werden als ganzer Block entfernt,
  # nicht nur ihre erste Zeile.
  sed -E \
    -e '/-----BEGIN[^-]*PRIVATE KEY-----/,/-----END[^-]*PRIVATE KEY-----/c\<entfernt: privater Schlüssel>' \
    -e 's/^([[:space:]]*(cipassword|password|passwd|secret|token|smbpass|keyring|encryption-key|master-pubkey|shared-key|sharedkey|sshkeys|ssh-public-keys|wgkey|privatekey|private-key|auth|apitoken|api-token)([[:space:]]*[:=][[:space:]]*|[[:space:]]+)).*/\1<entfernt>/I' \
    -e 's/(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+)[[:space:]]+[A-Za-z0-9+/=]{16,}/\1 <entfernt>/g' \
    -e 's/([?\&](password|token|secret)=)[^\&[:space:]]+/\1<entfernt>/Ig'
}

pb_diag_run() {
  local title="$1"; shift
  printf '\n===== %s =====\n' "$title"
  command -v "$1" >/dev/null 2>&1 || { printf '(Kommando nicht vorhanden: %s)\n' "$1"; return 0; }
  local out rc=0
  out="$(timeout "${PB_DIAG_TIMEOUT:-25}" "$@" 2>&1)" || rc=$?
  printf '%s\n' "$out" | pb_redact
  (( rc == 0 )) || printf '(Rückgabewert %s)\n' "$rc"
  return 0
}

pb_diag_file() {
  local title="$1" path="$2"
  printf '\n===== %s =====\n' "$title"
  [[ -r "$path" ]] || { printf '(nicht lesbar: %s)\n' "$path"; return 0; }
  timeout 15 cat -- "$path" 2>/dev/null | pb_redact
  return 0
}

pve_dr_diag_export() {
  local out host ts g t id st
  host="$(hostname -s 2>/dev/null || echo host)"
  ts="$(date +'%Y-%m-%d_%H-%M-%S')"
  out="${PB_DIAG_FILE:-${BACKUP_DIR}/panzerbackup-diagnose_${host}_${ts}.txt}"

  if ! ( umask 077; : > "$out" ) 2>/dev/null; then
    msg "[!] Diagnosebericht konnte nicht angelegt werden: $out" \
        "[!] Could not create the diagnostics report: $out"
    return 1
  fi
  chmod 600 -- "$out" 2>/dev/null || true

  {
    echo "Panzerbackup Diagnosebericht"
    echo "Skriptversion: ${VERSION}"
    echo "Erzeugt:       $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Host:          ${host}"
    echo
    echo "Kennwörter, Schlüssel und Cloud-Init-Zugangsdaten wurden automatisch"
    echo "entfernt. Der private Bereich /etc/pve/priv wird nicht gelesen."

    pb_diag_run "lsblk"            lsblk -b -o NAME,PATH,TYPE,SIZE,FSTYPE,PARTTYPE,PARTUUID,UUID,MOUNTPOINT
    pb_diag_run "findmnt"          findmnt -a
    pb_diag_run "blkid"            blkid
    pb_diag_run "pvs"              pvs  --units b --nosuffix -o pv_name,vg_name,pv_size,pv_free,pv_uuid
    pb_diag_run "vgs"              vgs  --units b --nosuffix -o vg_name,vg_size,vg_free,pv_count,vg_uuid
    pb_diag_run "lvs"              lvs -a --units b --nosuffix \
                                     -o vg_name,lv_name,lv_attr,lv_size,data_percent,metadata_percent,pool_lv,origin,lv_path,lv_dm_path,lv_tags
    if [[ -n "${PB_DISK:-}" ]]; then
      pb_diag_run "Gerätestapel"   lsblk -rpnso NAME,TYPE,FSTYPE "$PB_DISK"
      pb_diag_run "sfdisk -d"      sfdisk -d "$PB_DISK"
    fi
    pb_diag_run "pveversion"       pveversion -v
    pb_diag_run "pvesm status"     pvesm status
    pb_diag_file "storage.cfg"     /etc/pve/storage.cfg
    pb_diag_file "fstab"           /etc/fstab
    pb_diag_file "proxmox-boot-uuids" /etc/kernel/proxmox-boot-uuids
    pb_diag_run "proxmox-boot-tool" proxmox-boot-tool status
    pb_diag_run "qm list"          qm list
    pb_diag_run "pct list"         pct list

    printf '\n===== Cluster =====\n'
    if [[ -e /etc/pve/corosync.conf ]]; then echo "corosync.conf vorhanden (Inhalt nicht exportiert)"
    else echo "kein Cluster"; fi

    for g in ${PB_GUESTS[@]+"${PB_GUESTS[@]}"}; do
      IFS='|' read -r t id st <<< "$g"
      if [[ "$t" == "qemu" ]]; then pb_diag_run "qm config ${id} (${st})"  qm  config "$id"
      else                          pb_diag_run "pct config ${id} (${st})" pct config "$id"; fi
    done

    printf '\n===== Preflight-Bericht =====\n'
    pve_dr_report_summary  2>&1 || true
    pve_dr_report_details  2>&1 || true
  } >> "$out" 2>&1

  printf '%s' "$out"
}

# --- Abgleich: jedes Logical Volume muss zugeordnet sein ---------------------
# Die Gastkonfiguration allein reicht nicht als Inventar. Auf einem echten Host
# liegen im selben Pool zusätzlich Zustandsabbilder von VM-Snapshots
# (vm-<id>-state-<name>) und die LVM-Snapshots selbst (snap_...), die in keiner
# aktuellen Konfiguration auftauchen. Wer nur die Konfiguration liest, übersieht
# sie - und meldet eine Sicherung als vollständig, die es nicht ist. Deshalb ist
# die Liste der Logical Volumes die Wahrheit, und alles darin muss zugeordnet
# werden können.
declare -A PB_STVOL=()
PB_LV_UNKNOWN=(); PB_LV_SNAPSHOTS=(); PB_LV_EXTRA=()
PB_EXTRA_BYTES=0

pve_storage_volume_map() {
  local st vol vmid line
  has_cmd pvesm || return 1
  for st in "${!PB_ST_TYPE[@]}"; do
    case "${PB_ST_TYPE[$st]}" in lvm|lvmthin) ;; *) continue ;; esac
    [[ "${PB_ST_VG[$st]:-}" == "$PB_VG" ]] || continue
    while read -r line; do
      vol="${line%%|*}"; vmid="${line##*|}"
      [[ -n "$vol" ]] || continue
      PB_STVOL["${vol#*:}"]="$vmid"
    done < <(timeout 30 pvesm list "$st" 2>/dev/null \
             | awk 'NR>1 && NF>=5 {print $1"|"$NF}' || true)
  done
  return 0
}

pve_dr_reconcile_inventory() {
  local row name attr origin size known v vt vi vk vg lv

  pve_storage_volume_map || pb_warn \
    "$(L 'Speicherinhalt nicht abrufbar' 'Storage content not available')" \
    "$(L 'Die Liste der vorhandenen Datenträger ließ sich nicht abrufen; die Zuordnung stützt sich dann allein auf die Gastkonfigurationen.' 'The list of existing volumes could not be retrieved; attribution then relies on the guest configurations alone.')"

  for row in ${PB_LV_ROWS[@]+"${PB_LV_ROWS[@]}"}; do
    [[ "$(pb_lv_get "$row" 0)" == "$PB_VG" ]] || continue
    name="$(pb_lv_get "$row" 1)"; attr="$(pb_lv_get "$row" 2)"
    size="$(pb_lv_get "$row" 3)"; origin="$(pb_lv_get "$row" 7)"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    known=0

    # interne Bestandteile des Thin-Pools
    [[ "${name:0:1}" == "[" ]] && continue
    [[ "${attr:0:1}" == "t" ]] && continue
    [[ "$name" == "$PB_ROOT_LV" || "$name" == "${PB_SWAP_LV:-}" ]] && continue

    # LVM-Snapshot (eigener oder von Proxmox angelegter)
    if [[ "${attr:0:1}" == "s" || -n "$origin" ]]; then
      PB_LV_SNAPSHOTS+=("${name}${origin:+ ← $origin}")
      continue
    fi

    # in einer aktuellen Gastkonfiguration referenziert?
    for v in ${PB_VOLUMES[@]+"${PB_VOLUMES[@]}"}; do
      IFS='|' read -r vt vi vk vg lv _ _ _ <<< "$v"
      [[ "$vg" == "$PB_VG" && "$lv" == "$name" ]] && { known=1; break; }
    done
    (( known )) && continue

    # vom Speicher verwaltet, aber in keiner aktuellen Konfiguration
    # (typisch: Zustandsabbilder von VM-Snapshots)
    if [[ -n "${PB_STVOL[$name]:-}" ]]; then
      PB_LV_EXTRA+=("$name (VM ${PB_STVOL[$name]}, $(human_bytes "$size"))")
      PB_EXTRA_BYTES=$(( PB_EXTRA_BYTES + size ))
      continue
    fi

    PB_LV_UNKNOWN+=("$name ($(human_bytes "$size"), attr=${attr})")
  done

  if (( ${#PB_LV_UNKNOWN[@]} > 0 )); then
    pb_fail "$(L 'Nicht zuordenbare Datenbereiche gefunden' 'Unattributable data areas found')" \
            "$(L "Auf diesem System liegen ${#PB_LV_UNKNOWN[@]} Datenbereiche, die zu keinem bekannten Zweck und zu keinem Gast gehören. Solange nicht feststeht, was sie enthalten, kann Panzerbackup keine vollständige Sicherung zusagen." "This system holds ${#PB_LV_UNKNOWN[@]} data areas that belong to no known purpose and to no guest. As long as it is unclear what they contain, Panzerbackup cannot promise a complete backup.")" \
            "$(L 'Den Diagnosebericht aus den erweiterten Optionen exportieren und melden - dann lässt sich klären, ob diese Bereiche mitgesichert werden müssen.' 'Export the diagnostics report from the advanced options and report it, so it can be clarified whether these areas need to be included.')" \
            "unattributed LVs: ${PB_LV_UNKNOWN[*]}"
  fi

  if (( ${#PB_LV_SNAPSHOTS[@]} > 0 || ${#PB_LV_EXTRA[@]} > 0 )); then
    pb_warn "$(L 'Vorhandene Sicherungspunkte werden nicht mitgesichert' 'Existing restore points are not included')" \
            "$(L "Auf diesem Host existieren ${#PB_LV_SNAPSHOTS[@]} Sicherungspunkte von Gästen und ${#PB_LV_EXTRA[@]} zugehörige Zustandsabbilder ($(human_bytes "${PB_EXTRA_BYTES:-0}")). Die Sicherung enthält den jeweils aktuellen Stand jedes Gastes. Die Sicherungspunkte selbst stehen nach einer Wiederherstellung nicht mehr zur Verfügung." "This host has ${#PB_LV_SNAPSHOTS[@]} guest restore points and ${#PB_LV_EXTRA[@]} associated state images ($(human_bytes "${PB_EXTRA_BYTES:-0}")). The backup contains the current state of each guest. The restore points themselves will not be available after a restore.")"
  fi
}

# --- Orchestrierung ----------------------------------------------------------
# Die Teilprüfungen melden Befunde über pb_fail und geben bei einem Abbruch
# ungleich 0 zurück. Das "|| true" verschluckt hier keinen Fehler: der Befund
# ist bereits erfasst und führt am Ende zu NICHT BEREIT.
pve_dr_preflight() {
  pb_reset_findings

  if ! pve_is_host; then
    pb_fail "$(L 'Kein Proxmox VE erkannt' 'No Proxmox VE detected')" \
            "$(L 'Dieses System ist kein Proxmox-VE-Host. Die Disaster-Recovery-Sicherung setzt Proxmox voraus.' 'This system is not a Proxmox VE host. The disaster recovery backup requires Proxmox.')" \
            "$(L 'Auf einem normalen Linux-System das klassische RAW-Backup verwenden.' 'Use the classic RAW backup on an ordinary Linux system.')" \
            "pveversion/qm/pct or /etc/pve missing"
    return 1
  fi

  if [[ "$(id -u 2>/dev/null || echo 1)" != "0" ]]; then
    pb_fail "$(L 'Prüfung ohne Administratorrechte' 'Check without administrator rights')" \
            "$(L 'Ohne Administratorrechte lassen sich Speicherstruktur und Gastkonfigurationen nicht vollständig lesen. Das Ergebnis wäre unvollständig und damit irreführend.' 'Without administrator rights the storage layout and guest configurations cannot be read completely. The result would be incomplete and therefore misleading.')" \
            "$(L 'Die Prüfung mit sudo starten: sudo ./panzerbackup.sh' 'Start the check with sudo: sudo ./panzerbackup.sh')" \
            "euid=$(id -u 2>/dev/null || echo '?')"
    return 1
  fi

  local c
  for c in lvs vgs pvs findmnt lsblk blockdev; do
    has_cmd "$c" && continue
    pb_fail "$(L "Benötigtes Programm fehlt: ${c}" "Required program missing: ${c}")" \
            "$(L 'Ohne dieses Programm lässt sich die Speicherstruktur nicht auslesen.' 'Without this program the storage layout cannot be read.')" \
            "$(L "Nachinstallieren, z. B. mit: apt install lvm2 util-linux" "Install it, for example: apt install lvm2 util-linux")"
  done

  if ! pve_lvm_load; then
    pb_fail "$(L 'LVM-Struktur nicht lesbar' 'LVM layout not readable')" \
            "$(L 'Die Liste der Logical Volumes konnte nicht gelesen werden.' 'The list of logical volumes could not be read.')" \
            "$(L 'Bitte "lvs -a" als root ausführen und die Ausgabe zurückmelden.' 'Please run "lvs -a" as root and report the output.')"
    return 1
  fi

  if ! pve_pmxcfs_ok; then
    pb_fail "$(L 'Proxmox-Konfiguration nicht verfügbar' 'Proxmox configuration not available')" \
            "$(L 'Das Konfigurationsdateisystem von Proxmox (/etc/pve) ist nicht eingehängt. Ohne es lässt sich nicht feststellen, welche VMs und Container es gibt - eine Sicherung könnte sie stillschweigend auslassen.' 'The Proxmox configuration filesystem (/etc/pve) is not mounted. Without it there is no way to tell which VMs and containers exist - a backup could silently skip them.')" \
            "$(L 'Den Dienst starten: systemctl start pve-cluster, danach die Prüfung wiederholen.' 'Start the service: systemctl start pve-cluster, then run the check again.')" \
            "/etc/pve not a pmxcfs mount"
  fi

  pve_layout_detect || true
  [[ -n "$PB_VG" ]] || return 1
  pve_boot_detect || true
  pve_storage_load || pb_warn "$(L 'Speicherkonfiguration nicht lesbar' 'Storage configuration not readable')" \
                              "$(L '/etc/pve/storage.cfg konnte nicht gelesen werden.' '/etc/pve/storage.cfg could not be read.')"
  pve_guests_load
  pve_dr_check_guests
  pve_dr_reconcile_inventory
  pve_cow_plan || true
  pve_thinpool_health
  pve_dr_estimate_space

  if [[ -e /etc/pve/corosync.conf ]]; then
    pb_warn "$(L 'Dieser Host ist Teil eines Clusters' 'This host is part of a cluster')" \
            "$(L 'Die Sicherung ist möglich. Das Zurückspielen eines einzelnen Knotens in ein bestehendes Cluster erfordert aber zusätzliche Handgriffe an der Cluster-Konfiguration.' 'The backup works. Restoring a single node into an existing cluster does however require extra steps in the cluster configuration.')"
  fi

  (( ${#PB_FAIL_TITLE[@]} == 0 ))
}

# --- Ebene 1: Zusammenfassung ------------------------------------------------
pve_dr_report_summary() {
  local gib=$((1024*1024*1024)) i n_vm=0 n_ct=0 n_gp=0 g t
  local ok_sys="n" ok_snap="n" ok_pool="n" ok_target="n"

  for g in ${PB_GUEST_REPORT[@]+"${PB_GUEST_REPORT[@]}"}; do
    t="${g%%|*}"
    if [[ "$t" == "qemu" ]]; then n_vm=$(( n_vm + 1 )); else n_ct=$(( n_ct + 1 )); fi
  done
  for i in ${PB_FAIL_TECH[@]+"${PB_FAIL_TECH[@]}"}; do
    case "$i" in vmid=*|ctid=*|qemu/*|lxc/*) n_gp=$(( n_gp + 1 )) ;; esac
  done

  [[ -n "$PB_VG" && -n "$PB_DISK" && -n "$PB_BOOT_METHOD" ]] && ok_sys="y"
  (( PB_COW_ROOT >= 2*gib )) && ok_snap="y"
  ok_pool="y"
  if [[ -n "$PB_THINPOOL" ]]; then
    pb_pct_ge "$PB_POOL_DATA" "$PVE_DR_POOL_DATA_MAX" && ok_pool="n"
    pb_pct_ge "$PB_POOL_META" "$PVE_DR_POOL_META_MAX" && ok_pool="n"
  fi
  (( PB_TARGET_FREE >= PB_EST_WRITE + ${MIN_FREE_BYTES:-0} )) && ok_target="y"

  local YES NO
  YES="$(L 'ausreichend' 'sufficient')"; NO="$(L 'nicht ausreichend' 'insufficient')"

  echo "=========================================="
  M "Proxmox Disaster-Recovery Prüfung" "Proxmox disaster recovery check"
  echo "=========================================="
  echo
  if [[ "$ok_sys" == "y" ]]; then
    printf '  %-22s %s\n' "$(L 'System:' 'System:')"        "$(L 'unterstützt' 'supported') (Proxmox VE $(pve_version_string))"
  else
    printf '  %-22s %s\n' "$(L 'System:' 'System:')"        "$(L 'nicht unterstützt' 'not supported')"
  fi
  # Ohne erkanntes Layout wurden die uebrigen Punkte gar nicht geprueft -
  # sie hier als "nicht ausreichend" zu zeigen waere schlicht falsch.
  if [[ -n "${PB_VG:-}" ]]; then
    printf '  %-22s %s\n' "$(L 'Virtuelle Maschinen:' 'Virtual machines:')" "$n_vm $(L 'geprüft' 'checked')"
    printf '  %-22s %s\n' "$(L 'Container:' 'Containers:')"   "$n_ct $(L 'geprüft' 'checked')"
    printf '  %-22s %s\n' "$(L 'Momentaufnahme:' 'Snapshot:')" "$( [[ "$ok_snap" == y ]] && L 'möglich' 'possible' || L 'nicht möglich' 'not possible')"
    printf '  %-22s %s\n' "$(L 'Speicherpool:' 'Storage pool:')" "$( [[ "$ok_pool" == y ]] && echo "$YES" || echo "$NO")"
    printf '  %-22s %s\n' "$(L 'Backup-Ziel:' 'Backup target:')" "$( [[ "$ok_target" == y ]] && echo "$YES" || echo "$NO") ($(human_bytes "$PB_TARGET_FREE") $(L 'frei' 'free'))"
  fi
  echo

  if (( ${#PB_FAIL_TITLE[@]} == 0 )); then
    M "${G}Ergebnis: BEREIT${NC}" "${G}Result: READY${NC}"
    echo
    M "Dieses System kann mit dem Proxmox-Disaster-Recovery-Verfahren" \
      "This system can be backed up with the Proxmox disaster recovery"
    M "gesichert werden." "procedure."
  else
    M "${R}Ergebnis: NICHT BEREIT${NC}" "${R}Result: NOT READY${NC}"
    echo
    if (( ${#PB_FAIL_TITLE[@]} == 1 )); then
      M "Es wurde 1 Problem gefunden:" "One problem was found:"
    else
      M "Es wurden ${#PB_FAIL_TITLE[@]} Probleme gefunden:" "${#PB_FAIL_TITLE[@]} problems were found:"
    fi
    echo
    for (( i=0; i<${#PB_FAIL_TITLE[@]}; i++ )); do
      echo "  - ${PB_FAIL_TITLE[$i]}"
    done
  fi

  if (( ${#PB_WARN_TITLE[@]} > 0 )); then
    echo
    for (( i=0; i<${#PB_WARN_TITLE[@]}; i++ )); do
      echo "  ${Y}$(L 'Hinweis' 'Note'):${NC} ${PB_WARN_TITLE[$i]}"
    done
  fi
  echo
}

# --- Ebene 2: technische Details ---------------------------------------------
pve_dr_report_details() {
  local i g t id st q vc v vg lv lvtype size alloc vt vi vk

  echo "=========================================="
  M "Technische Details" "Technical details"
  echo "=========================================="
  echo
  if [[ -z "${PB_VG:-}" ]]; then
    M "Die Speicherstruktur konnte nicht ausgewertet werden – es gibt keine" \
      "The storage layout could not be evaluated, so there is no layout"
    M "Layout-Daten anzuzeigen." "data to show."
    pve_dr_report_findings
    return 0
  fi
  M "-- System --" "-- System --"
  printf '  %-18s %s\n' "Proxmox VE"   "$(pve_version_string)"
  printf '  %-18s %s\n' "Systemdisk"   "${PB_DISK:-?} ($(human_bytes "${PB_DISK_SIZE:-0}"), ${PB_PTTYPE:-?})"
  printf '  %-18s %s\n' "Boot"         "${PB_BOOT_METHOD:-?}${PB_ESP:+  ESP=$PB_ESP}"
  [[ -n "${PB_BOOT_DETAIL:-}" ]] && printf '  %-18s %s\n' "" "${PB_BOOT_DETAIL}"
  printf '  %-18s %s\n' "Volume-Group" "${PB_VG:-?}  size=$(human_bytes "${PB_VG_SIZE:-0}")  free=$(human_bytes "${PB_VG_FREE:-0}")"
  printf '  %-18s %s\n' "PV"           "${PB_PV:-?}"
  printf '  %-18s %s\n' "Root-LV"      "${PB_VG:-?}/${PB_ROOT_LV:-?}  $(human_bytes "${PB_ROOT_SIZE:-0}")"
  if [[ -n "${PB_SWAP_LV:-}" ]]; then
    printf '  %-18s %s\n' "Swap-LV"    "${PB_VG}/${PB_SWAP_LV}  $(human_bytes "${PB_SWAP_SIZE:-0}")  UUID=${PB_SWAP_UUID:-?}"
    printf '  %-18s %s\n' ""           "$(L '(wird nicht gesichert, beim Restore mit dieser UUID neu erzeugt)' '(not backed up, recreated with this UUID on restore)')"
  fi
  if [[ -n "${PB_THINPOOL:-}" ]]; then
    printf '  %-18s %s\n' "Thin-Pool"  "${PB_VG}/${PB_THINPOOL}  $(human_bytes "${PB_POOL_SIZE:-0}")"
    printf '  %-18s %s\n' ""           "data_percent=$(pb_pct_fmt "$PB_POOL_DATA")  (Limit ${PVE_DR_POOL_DATA_MAX} %)"
    printf '  %-18s %s\n' ""           "metadata_percent=$(pb_pct_fmt "$PB_POOL_META")  (Limit ${PVE_DR_POOL_META_MAX} %)"
  fi
  echo
  M "-- Snapshot-Planung (klassischer COW) --" "-- Snapshot plan (classic COW) --"
  printf '  %-18s %s\n' "VG free"      "$(human_bytes "${PB_VG_FREE:-0}")"
  printf '  %-18s %s\n' "Reserve"      "$(human_bytes "${PB_COW_RESERVE:-0}")"
  printf '  %-18s %s\n' "Budget"       "$(human_bytes "${PB_COW_BUDGET:-0}")"
  printf '  %-18s %s\n' "COW root"     "$(human_bytes "${PB_COW_ROOT:-0}")"
  printf '  %-18s %s\n' "COW gesamt"   "$(human_bytes "${PB_COW_TOTAL:-0}")"
  printf '  %-18s %s\n' "Schwellen"    "warn ${PVE_DR_COW_WARN} % / extend ${PVE_DR_COW_EXTEND} % / abort ${PVE_DR_COW_ABORT} %"
  printf '  %-18s %s\n' "Root-Freeze"  "$(L 'nein - dm-suspend, crash-consistent-journaled (K1)' 'no - dm-suspend, crash-consistent-journaled (K1)')"
  echo
  M "-- Speicher (storage.cfg) --" "-- Storage (storage.cfg) --"
  if (( ${#PB_ST_TYPE[@]} == 0 )); then
    echo "  $(L '(nicht gelesen)' '(not read)')"
  else
    local sname sattr
    for sname in "${!PB_ST_TYPE[@]}"; do
      sattr=""
      [[ -n "${PB_ST_VG[$sname]:-}" ]]      && sattr+="vgname=${PB_ST_VG[$sname]} "
      [[ -n "${PB_ST_POOL[$sname]:-}" ]]    && sattr+="thinpool=${PB_ST_POOL[$sname]} "
      [[ -n "${PB_ST_PATH[$sname]:-}" ]]    && sattr+="path=${PB_ST_PATH[$sname]} "
      [[ -n "${PB_ST_CONTENT[$sname]:-}" ]] && sattr+="content=${PB_ST_CONTENT[$sname]}"
      printf '  %-16s %-10s %s\n' "$sname" "${PB_ST_TYPE[$sname]}" "$sattr"
    done
  fi
  echo
  M "-- Gäste --" "-- Guests --"
  if (( ${#PB_GUEST_REPORT[@]} == 0 )); then
    echo "  $(L '(keine)' '(none)')"
  else
    for g in ${PB_GUEST_REPORT[@]+"${PB_GUEST_REPORT[@]}"}; do
      IFS='|' read -r t id st q vc <<< "$g"
      printf '  %-4s %-6s %-10s quiesce=%-16s %s\n' \
        "$( [[ "$t" == lxc ]] && echo CT || echo VM )" "$id" "$st" "$q" \
        "$vc $(L 'Volume(s)' 'volume(s)')"
      for v in ${PB_VOLUMES[@]+"${PB_VOLUMES[@]}"}; do
        IFS='|' read -r vt vi vk vg lv lvtype size alloc <<< "$v"
        [[ "$vt" == "$t" && "$vi" == "$id" ]] || continue
        printf '         %-10s %s/%s  %-5s logical=%-12s allocated=%s\n' \
          "$vk" "$vg" "$lv" "$lvtype" "$(human_bytes "$size")" "$(human_bytes "$alloc")"
      done
    done
  fi
  echo
  M "-- Abgleich der Datenbereiche --" "-- Data area reconciliation --"
  printf '  %-26s %s\n' "$(L 'Gastdatenträger' 'Guest volumes')"       "${#PB_VOLUMES[@]}"
  printf '  %-26s %s\n' "$(L 'Sicherungspunkte (LVM)' 'Restore points (LVM)')" "${#PB_LV_SNAPSHOTS[@]}"
  printf '  %-26s %s\n' "$(L 'Zustandsabbilder' 'State images')"       "${#PB_LV_EXTRA[@]} ($(human_bytes "${PB_EXTRA_BYTES:-0}"))"
  for i in ${PB_LV_EXTRA[@]+"${PB_LV_EXTRA[@]}"};   do echo "      $(L 'Zustand:' 'state:  ') $i"; done
  printf '  %-26s %s\n' "$(L 'Nicht zuordenbar' 'Unattributable')"     "${#PB_LV_UNKNOWN[@]}"
  for i in ${PB_LV_UNKNOWN[@]+"${PB_LV_UNKNOWN[@]}"}; do echo "      $(L 'unklar: ' 'unknown:') $i"; done

  echo
  M "-- Platzbedarf --" "-- Space --"
  printf '  %-26s %s\n' "$(L 'Zu lesen (logisch)' 'To read (logical)')"  "$(human_bytes "${PB_EST_READ:-0}")"
  printf '  %-26s %s\n' "$(L 'Geschätzt zu schreiben' 'Estimated to write')" "$(human_bytes "${PB_EST_WRITE:-0}")"
  if [[ -n "${PB_EST_RATIO:-}" ]]; then
    printf '  %-26s %s\n' "$(L 'Kompressionsrate' 'Compression ratio')" "$(( PB_EST_RATIO / 10 )) % $(L '(gemessen am Root-LV)' '(measured on the root LV)')"
  else
    printf '  %-26s %s\n' "$(L 'Kompressionsrate' 'Compression ratio')" "$(L 'nicht messbar - volle Rohgröße angesetzt' 'not measurable - full raw size assumed')"
  fi
  printf '  %-26s %s\n' "$(L 'Backup-Ziel frei' 'Backup target free')" "$(human_bytes "${PB_TARGET_FREE:-0}")"
  printf '  %-26s %s\n' "$(L 'Sicherheitsaufschlag' 'Safety margin')" "${SPACE_SAFETY_PERCENT:-15} %"
  echo "  $(L 'Hinweis: Thin-Volumes werden in voller logischer Größe gelesen; nicht' 'Note: thin volumes are read at full logical size; unallocated')"
  echo "  $(L 'belegte Blöcke liefern Nullen und komprimieren auf nahezu nichts (K6).' 'blocks return zeroes and compress to almost nothing (K6).')"

  if (( ${#PB_DETAILS[@]} > 0 )); then
    echo
    M "-- Beobachtungen --" "-- Observations --"
    for i in ${PB_DETAILS[@]+"${PB_DETAILS[@]}"}; do echo "  $i"; done
  fi

  pve_dr_report_findings
}

pve_dr_report_findings() {
  local i
  if (( ${#PB_FAIL_TITLE[@]} > 0 )); then
    echo
    M "-- Befunde --" "-- Findings --"
    for (( i=0; i<${#PB_FAIL_TITLE[@]}; i++ )); do
      echo
      echo "  ${R}[$((i+1))] ${PB_FAIL_TITLE[$i]}${NC}"
      echo "      $(L 'Grund:'  'Reason:')"
      echo "        ${PB_FAIL_REASON[$i]}"
      echo "      $(L 'Lösung:' 'Fix:')"
      echo "        ${PB_FAIL_FIX[$i]}"
      [[ -n "${PB_FAIL_TECH[$i]}" ]] && {
        echo "      $(L 'Technisch:' 'Technical:')"
        echo "        ${PB_FAIL_TECH[$i]}"
      }
    done
  fi
  if (( ${#PB_WARN_TITLE[@]} > 0 )); then
    echo
    M "-- Hinweise --" "-- Notes --"
    for (( i=0; i<${#PB_WARN_TITLE[@]}; i++ )); do
      echo
      echo "  ${Y}${PB_WARN_TITLE[$i]}${NC}"
      echo "    ${PB_WARN_REASON[$i]}"
    done
  fi
  echo
}

# --- Einstieg ----------------------------------------------------------------
# $1: "cli"  -> Zusammenfassung und Details ausgeben (für Protokolle)
#     "menu" -> Zusammenfassung, Details auf Wunsch
pve_dr_dry_run() {
  local view="${1:-cli}" ans rc=0

  msg "[*] Prüfe dieses System – es wird nichts verändert ..." \
      "[*] Checking this system – nothing will be modified ..."
  if is_running; then
    msg "[!] Achtung: Es läuft gerade ein Panzerbackup-Vorgang. Die Werte können sich noch ändern." \
        "[!] Note: a Panzerbackup job is currently running. The values may still change."
  fi
  echo

  pve_dr_preflight || rc=1

  { clear 2>/dev/null || printf '\033c'; } || true
  pve_dr_report_summary

  if [[ "$view" == "cli" ]]; then
    pve_dr_report_details
  elif [[ -t 0 && -t 1 ]]; then
    if [[ "$LANG_CHOICE" == "de" ]]; then
      read -rp "[D] Technische Details anzeigen   [Enter] Zurück: " ans || true
    else
      read -rp "[D] Show technical details   [Enter] Back: " ans || true
    fi
    if [[ "${ans:-}" =~ ^[Dd]$ ]]; then
      { clear 2>/dev/null || printf '\033c'; } || true
      pve_dr_report_details
      if [[ "$LANG_CHOICE" == "de" ]]; then read -rp "Drücke Enter um zurückzukehren..." _ || true
      else read -rp "Press Enter to return..." _ || true; fi
    fi
  fi
  return "$rc"
}

run_diag_export() {
  local f
  msg "[*] Sammle Diagnoseinformationen – das dauert einen Moment ..." \
      "[*] Collecting diagnostics – this takes a moment ..."
  if pve_is_host; then
    pve_dr_preflight >/dev/null 2>&1 || true
  fi
  f="$(pve_dr_diag_export || true)"
  if [[ -n "$f" && -f "$f" ]]; then
    echo
    msg "[✓] Diagnosebericht geschrieben:" "[✓] Diagnostics report written:"
    echo "    $f"
    msg "    Kennwörter, Schlüssel und Cloud-Init-Zugangsdaten wurden entfernt." \
        "    Passwords, keys and cloud-init credentials have been removed."
    return 0
  fi
  msg "[!] Diagnosebericht konnte nicht erstellt werden." "[!] Could not create the diagnostics report."
  return 1
}

# =====================[ PVE-DR: Hintergrundlauf ]=============================
# Für die Sicherung startet sich das Skript als eingefrorene Kopie selbst neu.
# So steht dem Hintergrundprozess die vollständige Bibliothek zur Verfügung,
# ohne den Code ein zweites Mal vorzuhalten, und eine Bearbeitung der Quelle
# während des Laufs kann ihm nichts anhaben.
pve_dr_backup_background() {
  local runner="${RUN_DIR}/panzerbackup-run.sh"
  cp -f "$SCRIPT_PATH" "$runner" || return 1
  chmod 700 "$runner"
  : > "$STARTUP_LOG"
  env -i \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME="/root" LC_ALL="C" LANG="C" \
    LANG_CHOICE="$LANG_CHOICE" PB_INTERNAL="1" \
    RUN_DIR="$RUN_DIR" BACKUP_DIR_OVERRIDE="$BACKUP_DIR" DISK_OVERRIDE="$DISK" \
    BACKUP_NAME="${BACKUP_NAME:-}" DATE="$DATE" \
    ENCRYPT_MODE="$ENCRYPT_MODE" PASSPHRASE_FILE="$PASSPHRASE_FILE" \
    ZSTD_LEVEL="$ZSTD_LEVEL" KEEP="$KEEP" KEEP_PVE_DR="$KEEP_PVE_DR" \
    POST_ACTION="$POST_ACTION" PVE_DR_ALLOW_SHUTDOWN="$PVE_DR_ALLOW_SHUTDOWN" \
    LOG_FILE_OVERRIDE="$LOG_FILE_DEFAULT" \
    nohup setsid bash "$runner" __pve-dr-worker >> "$STARTUP_LOG" 2>&1 &
  local wpid=$!
  echo "$wpid" > "$PID_FILE"
  sleep 2
  if ! (ps -p "$wpid" >/dev/null 2>&1 || pgrep -P "$wpid" >/dev/null 2>&1); then
    set_status "$( [[ "$LANG_CHOICE" == de ]] && echo "FEHLER: Start fehlgeschlagen – siehe $STARTUP_LOG" || echo "ERROR: start failed – see $STARTUP_LOG" )"
    msg "⚠️  Der Sicherungsvorgang konnte nicht gestartet werden." "⚠️  The backup job could not be started."
    [[ -s "$STARTUP_LOG" ]] && cat "$STARTUP_LOG"
    return 1
  fi
  return 0
}

pve_dr_backup_start() {
  if ! acquire_start_lock; then
    if is_running; then
      msg "Es läuft bereits ein Vorgang!" "A job is already running!"
      msg "Aktueller Status: $(get_status)" "Current status: $(get_status)"
      return 1
    fi
    die "Der Start ist gesperrt. Falls nichts läuft: sudo rm -rf '$START_LOCK_DIR'" \
        "Startup is locked. If nothing is running: sudo rm -rf '$START_LOCK_DIR'"
  fi
  trap 'release_start_lock' EXIT
  if is_running; then
    release_start_lock; trap - EXIT
    msg "Es läuft bereits ein Vorgang!" "A job is already running!"; return 1
  fi

  local c
  for c in lvcreate lvremove lvs vgs pvs sfdisk dd sha256sum zstd; do need_cmd "$c"; done
  clear_passphrase_file
  if [[ "$ENCRYPT_MODE" == "gpg" ]]; then
    need_cmd gpg
    write_passphrase_file "$ENCRYPT_PASSPHRASE" || \
      die "Passphrase konnte nicht sicher übergeben werden." "Could not hand over the passphrase securely."
  fi
  ENCRYPT_PASSPHRASE=""

  clear_status_for_new_run; mark_run_started
  set_status "$(status_msg "BACKUP: Wird gestartet..." "BACKUP: Starting...")"
  msg "" ""
  msg "Starte die Proxmox-Sicherung im Hintergrund ..." "Starting the Proxmox backup in the background ..."
  pve_dr_backup_background || { release_start_lock; trap - EXIT; return 1; }
  release_start_lock; trap - EXIT
  sleep 1
  msg "✓ Die Sicherung läuft." "✓ The backup is running."
  msg "  Fortschritt: Menüpunkt 'Status / Fortschritt' oder '$0 status'" \
      "  Progress: menu item 'Status / progress' or '$0 status'"
  return 0
}

# =====================[ Backup-Dispatch ]=====================================
backup_dispatch() {
  case "${BACKUP_MODE:-raw}" in
    raw)
      if [[ "${BACKUP_DRY_RUN:-0}" == "1" ]]; then
        die "Ein Dry-Run ist derzeit nur für --mode pve-dr verfügbar." \
            "A dry run is currently only available for --mode pve-dr."
      fi
      do_backup ;;
    pve-dr)
      if [[ "${BACKUP_DRY_RUN:-0}" == "1" ]]; then
        pve_dr_dry_run cli
      else
        pve_dr_backup_start
      fi ;;
    *)
      die "Unbekannter Backup-Modus: ${BACKUP_MODE}" "Unknown backup mode: ${BACKUP_MODE}" ;;
  esac
}

# =====================[ .pzb-Container ]======================================
# Ein PVE-DR-Backup ist EINE Datei. Innen liegt ein sequentieller Strom aus
# benannten Bestandteilen; außen ist es dieselbe Pipeline wie beim RAW-Modus:
#
#   pzb_stream | zstd | [gpg] > panzer_<host>_<zeit>.pzb
#
# Aufbau des Stroms (alle Kopfzeilen sind reiner ASCII-Text, Tab-getrennt):
#
#   PZB1\n
#   FORMAT<TAB>panzerbackup-pve-dr<TAB>1\n
#   \n
#   MEMBER<TAB>pfad<TAB>bytes<TAB>modus\n
#   <exakt "bytes" Rohbytes>
#   ENDMEMBER<TAB>sha256\n
#   ... weitere Bestandteile ...
#   END<TAB>anzahl<TAB>gesamtbytes\n
#
# Warum so:
#  - Die Größe jedes Bestandteils steht VOR seinem Inhalt. Ein Leser weiß damit
#    immer, wie weit er lesen muss - ohne Index, ohne Rückwärtssprung, ohne
#    Zwischendatei. Deshalb ist Sichern und Wiederherstellen je ein einziger
#    Durchlauf, und es wird nie doppelter Speicher gebraucht.
#  - Die Prüfsumme steht NACH dem Inhalt, weil sie vorher nicht bekannt ist.
#    Jeder Bestandteil ist damit einzeln prüfbar.
#  - Das Manifest ist der erste Bestandteil und enthält alles, was der Restore
#    zum Planen braucht. Es muss also nicht erst der ganze Strom gelesen werden.
#  - Die END-Zeile ist Pflicht: eine abgeschnittene Datei fällt sofort auf.
#  - Gelesen wird ausschließlich mit dd, head, awk und sha256sum. Auf einem
#    Live-System ist damit nichts nachzuinstallieren.

PZB_MAGIC="PZB1"
PZB_FORMAT="panzerbackup-pve-dr"
PZB_FORMAT_VERSION=1

# --- Schreiben ---------------------------------------------------------------
PZB_MEMBER_COUNT=0
PZB_TOTAL_BYTES=0
PZB_SUMS=""        # sammelt "sha256  pfad" für SHA256SUMS

pzb_w_header() {
  printf '%s\n' "$PZB_MAGIC"
  printf 'FORMAT\t%s\t%s\n' "$PZB_FORMAT" "$PZB_FORMAT_VERSION"
  printf '\n'
  PZB_MEMBER_COUNT=0; PZB_TOTAL_BYTES=0; PZB_SUMS=""
}

pzb_valid_member_path() {
  local p="${1-}"
  [[ -n "$p" ]] || return 1
  [[ "$p" != /* ]] || return 1
  [[ "$p" != *..* ]] || return 1
  [[ "$p" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  (( ${#p} <= 200 )) || return 1
  return 0
}

# Schreibt einen Bestandteil, dessen Inhalt auf stdin steht.
# $1 Pfad im Container, $2 exakte Bytezahl, $3 Modus (optional)
# Die Prüfsumme wird im selben Durchlauf über eine FIFO berechnet - ohne
# zweiten Lesevorgang und ohne Zwischendatei.
pzb_w_member_stream() {
  local path="${1:?}" size="${2:?}" mode="${3:-0644}"
  local base fh fc hashfile countfile hpid cpid sum copied rc=0
  pzb_valid_member_path "$path" || { echo "pzb: ungültiger Pfad: $path" >&2; return 1; }
  [[ "$size" =~ ^[0-9]+$ ]] || { echo "pzb: ungültige Größe: $size" >&2; return 1; }

  base="$(mktemp -u "${PZB_TMPDIR:-$RUN_DIR}/pzb-w.XXXXXX")"
  fh="${base}.h"; fc="${base}.c"; hashfile="${base}.sha"; countfile="${base}.cnt"
  mkfifo -m 600 "$fh" "$fc" || return 1

  ( sha256sum -b < "$fh" | cut -d' ' -f1 > "$hashfile" ) &
  hpid=$!
  ( wc -c < "$fc" | tr -d ' ' > "$countfile" ) &
  cpid=$!

  printf 'MEMBER\t%s\t%s\t%s\n' "$path" "$size" "$mode"
  # tee schreibt den Inhalt auf stdout (den Containerstrom) und zusätzlich in
  # beide FIFOs. Prüfsumme und Bytezahl entstehen so im selben Durchlauf.
  head -c "$size" | tee "$fh" "$fc" || rc=1
  wait "$hpid" || true
  wait "$cpid" || true
  rm -f "$fh" "$fc"

  sum="$(cat "$hashfile" 2>/dev/null || true)"
  copied="$(cat "$countfile" 2>/dev/null || true)"
  rm -f "$hashfile" "$countfile"

  if (( rc != 0 )) || [[ "$copied" != "$size" ]]; then
    echo "pzb: $path unvollständig (${copied:-0} von $size Bytes)" >&2
    return 1
  fi
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "pzb: Prüfsumme fehlgeschlagen: $path" >&2; return 1; }

  printf 'ENDMEMBER\t%s\n' "$sum"
  PZB_MEMBER_COUNT=$(( PZB_MEMBER_COUNT + 1 ))
  PZB_TOTAL_BYTES=$(( PZB_TOTAL_BYTES + size ))
  PZB_SUMS+="${sum}  ${path}"$'\n'
  return 0
}

# Bestandteil aus einer vorhandenen Datei
pzb_w_member_file() {
  local path="${1:?}" src="${2:?}" mode="${3:-0644}" size
  [[ -r "$src" ]] || { echo "pzb: nicht lesbar: $src" >&2; return 1; }
  size="$(stat -Lc '%s' "$src")" || return 1
  pzb_w_member_stream "$path" "$size" "$mode" < "$src"
}

# WICHTIG: pzb_w_member_stream führt Zähler und Prüfsummenliste in Variablen.
# Ein Aufruf über eine Pipe ("cmd | pzb_w_member_stream") würde die Funktion in
# einer Subshell ausführen; die Buchführung ginge verloren und die END-Zeile
# sowie SHA256SUMS wären unvollständig. Alle Aufrufe leiten stdin deshalb um,
# statt zu pipen.

# Bestandteil aus einem Blockgerät (Größe wird vom Gerät genommen)
pzb_w_member_device() {
  local path="${1:?}" dev="${2:?}" size
  [[ -b "$dev" || -f "$dev" ]] || { echo "pzb: kein Gerät: $dev" >&2; return 1; }
  if [[ -b "$dev" ]]; then size="$(blockdev --getsize64 "$dev")"
  else size="$(stat -Lc '%s' "$dev")"; fi
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || { echo "pzb: Größe unbekannt: $dev" >&2; return 1; }
  pzb_w_member_stream "$path" "$size" 0600 < <(dd if="$dev" bs=4M iflag=fullblock status=none)
}

# Kurzer Bestandteil direkt aus einer Zeichenkette
pzb_w_member_text() {
  local path="${1:?}" text="${2-}"
  pzb_w_member_stream "$path" "${#text}" 0644 < <(printf '%s' "$text")
}

pzb_w_end() {
  printf 'END\t%s\t%s\n' "$PZB_MEMBER_COUNT" "$PZB_TOTAL_BYTES"
}

# --- Lesen -------------------------------------------------------------------
# Der Leser arbeitet rein sequentiell auf stdin. bash liest Kopfzeilen
# byteweise, dd/head übernehmen danach exakt die angekündigte Menge - beides
# auf derselben Pipe, ohne Vorauslesen.
PZB_R_PATH=""; PZB_R_SIZE=0; PZB_R_MODE=""
PZB_R_COUNT=0; PZB_R_TOTAL=0

pzb_r_open() {
  local line fmt ver
  IFS= read -r line || { echo "pzb: Datei ist leer" >&2; return 1; }
  [[ "$line" == "$PZB_MAGIC" ]] || { echo "pzb: keine Panzerbackup-Datei (Kennung '$line')" >&2; return 1; }
  IFS=$'\t' read -r line fmt ver || { echo "pzb: Kopf unvollständig" >&2; return 1; }
  [[ "$line" == "FORMAT" ]] || { echo "pzb: Kopf unvollständig" >&2; return 1; }
  [[ "$fmt" == "$PZB_FORMAT" ]] || { echo "pzb: unbekanntes Format '$fmt'" >&2; return 1; }
  [[ "$ver" =~ ^[0-9]+$ ]] || { echo "pzb: unlesbare Formatversion" >&2; return 1; }
  if (( ver > PZB_FORMAT_VERSION )); then
    echo "pzb: Diese Sicherung wurde mit einer neueren Panzerbackup-Version erstellt (Format $ver, unterstützt wird bis $PZB_FORMAT_VERSION)." >&2
    return 1
  fi
  IFS= read -r line || true      # Leerzeile
  PZB_R_COUNT=0; PZB_R_TOTAL=0
  return 0
}

# Liest die nächste Kopfzeile. 0 = Bestandteil folgt, 2 = END erreicht, 1 = Fehler
pzb_r_next() {
  local kind a b c
  IFS=$'\t' read -r kind a b c || { echo "pzb: Datei endet unerwartet (kein Abschluss)" >&2; return 1; }
  case "$kind" in
    MEMBER)
      pzb_valid_member_path "$a" || { echo "pzb: unzulässiger Pfad im Container" >&2; return 1; }
      [[ "$b" =~ ^[0-9]+$ ]] || { echo "pzb: unlesbare Größenangabe" >&2; return 1; }
      PZB_R_PATH="$a"; PZB_R_SIZE="$b"; PZB_R_MODE="${c:-0644}"; return 0 ;;
    END)
      PZB_R_COUNT="${a:-0}"; PZB_R_TOTAL="${b:-0}"; return 2 ;;
    *) echo "pzb: unerwarteter Satz '${kind:-<leer>}'" >&2; return 1 ;;
  esac
}

# Gibt den Inhalt des aktuellen Bestandteils auf stdout aus und prüft die
# Prüfsumme. $1 (optional): Datei, in die die tatsächliche Prüfsumme geschrieben wird.
pzb_r_member() {
  local outsum="${1:-}" base fh fc hashfile countfile hpid cpid got copied line sum rc=0
  base="$(mktemp -u "${PZB_TMPDIR:-$RUN_DIR}/pzb-r.XXXXXX")"
  fh="${base}.h"; fc="${base}.c"; hashfile="${base}.sha"; countfile="${base}.cnt"
  mkfifo -m 600 "$fh" "$fc" || return 1
  ( sha256sum -b < "$fh" | cut -d' ' -f1 > "$hashfile" ) &
  hpid=$!
  ( wc -c < "$fc" | tr -d ' ' > "$countfile" ) &
  cpid=$!

  head -c "$PZB_R_SIZE" | tee "$fh" "$fc" || rc=1
  wait "$hpid" || true
  wait "$cpid" || true
  rm -f "$fh" "$fc"
  got="$(cat "$hashfile" 2>/dev/null || true)"
  copied="$(cat "$countfile" 2>/dev/null || true)"
  rm -f "$hashfile" "$countfile"
  [[ -n "$outsum" ]] && printf '%s' "$got" > "$outsum"

  if (( rc != 0 )) || [[ "$copied" != "$PZB_R_SIZE" ]]; then
    echo "pzb: ${PZB_R_PATH} abgeschnitten (${copied:-0} von $PZB_R_SIZE Bytes)" >&2
    return 1
  fi
  IFS=$'\t' read -r line sum || { echo "pzb: Abschluss von ${PZB_R_PATH} fehlt" >&2; return 1; }
  [[ "$line" == "ENDMEMBER" ]] || { echo "pzb: Abschluss von ${PZB_R_PATH} fehlt" >&2; return 1; }
  if [[ "$got" != "$sum" ]]; then
    echo "pzb: ${PZB_R_PATH} ist beschädigt (Prüfsumme weicht ab)" >&2; return 1
  fi
  return 0
}

# Überspringt den aktuellen Bestandteil, prüft aber weiterhin die Prüfsumme.
pzb_r_skip() { pzb_r_member >/dev/null; }

# =====================[ PVE-DR: Snapshot-Engine ]=============================
# Der Kern von Panzerbackup 3: Gäste werden nur für Sekunden angehalten, der
# Snapshot entsteht sofort, danach läuft der Gast weiter - und erst dann wird in
# Ruhe gelesen. Kein Gast bleibt für die Dauer des Backups eingefroren.

PB_RUN_ID=""; PB_SNAP_TAG=""; PB_RUN_STATE=""
PB_SNAPSHOTS=()        # "vg|lv|snapname|kind|role|guest|key|size|alloc"
PB_FROZEN_VMS=(); PB_SHUTDOWN_VMS=(); PB_FROZEN_CTS=(); PB_CT_FSFROZEN=()
PB_ABORT_FILE=""; PB_COW_LV=""

pve_run_id_new() {
  local rnd
  rnd="$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 6 || true)"
  [[ -n "$rnd" ]] || rnd="$$"
  PB_RUN_ID="$(date +%Y%m%d%H%M%S)_${rnd}"
  PB_SNAP_TAG="pbdr_run_${PB_RUN_ID}"
  PB_RUN_STATE="${RUN_DIR}/pbdr_${PB_RUN_ID}.state"
  PB_ABORT_FILE="${RUN_DIR}/pbdr_${PB_RUN_ID}.abort"
  ( umask 077; printf 'pid=%s\nstarted=%s\ntag=%s\n' "$$" "$(date +%s)" "$PB_SNAP_TAG" > "$PB_RUN_STATE" ) || return 1
  return 0
}

# LV-Namen dürfen 127 Zeichen nicht überschreiten; der Ursprungsname wird
# gekürzt, die Kennung des Laufs bleibt vollständig erhalten.
pve_snap_name() {
  local lv="${1:?}" base="pbdr_${PB_RUN_ID}_" max=127 room
  lv="${lv//[^A-Za-z0-9_.+-]/_}"
  room=$(( max - ${#base} ))
  (( room < 8 )) && room=8
  (( ${#lv} > room )) && lv="${lv:0:room}"
  printf '%s%s' "$base" "$lv"
}

pve_dr_abort_requested() { [[ -f "${PB_ABORT_FILE:-/nonexistent}" ]]; }
pve_dr_abort_reason()    { cat "${PB_ABORT_FILE:-/nonexistent}" 2>/dev/null || true; }
pve_dr_request_abort()   { ( umask 077; printf '%s\n' "${1:-unbekannt}" > "$PB_ABORT_FILE" ) 2>/dev/null || true; }

# --- Snapshots ---------------------------------------------------------------
# Erzeugt einen Snapshot und trägt ihn SOFORT in die Laufzeitliste ein - vor
# jeder weiteren Nutzung, damit ein Absturz dazwischen nichts zurücklässt.
pve_snap_create() {
  local vg="${1:?}" lv="${2:?}" kind="${3:?}" role="${4:-}" guest="${5:-}" key="${6:-}"
  local snap out rc=0 size alloc row cow

  snap="$(pve_snap_name "$lv")"
  row="$(pve_lv_row "$vg" "$lv" || true)"
  size="$(pb_lv_get "$row" 3)"; [[ "$size" =~ ^[0-9]+$ ]] || size=0
  alloc="$size"

  printf 'snapshot\t%s/%s\t%s\n' "$vg" "$snap" "$(date +%s)" >> "$PB_RUN_STATE" 2>/dev/null || true

  if [[ "$kind" == "thin" ]]; then
    local dp; dp="$(pb_lv_get "$row" 5)"
    alloc="$(awk -v s="$size" -v p="${dp:-100}" 'BEGIN{printf "%d", s*(p+0)/100}')"
    out="$(timeout 120 lvcreate --snapshot --name "$snap" --addtag "$PB_SNAP_TAG" \
             "${vg}/${lv}" 2>&1)" || rc=$?
    if (( rc == 0 )); then
      # Thin-Snapshots werden mit gesetztem Aktivierungs-Skip angelegt und
      # müssen ausdrücklich aktiviert werden, sonst gibt es kein Gerät zum Lesen.
      timeout 60 lvchange -ay -K "${vg}/${snap}" >/dev/null 2>&1 || rc=$?
    fi
  else
    cow="${7:?COW-Größe fehlt}"
    out="$(timeout 300 lvcreate --snapshot --name "$snap" --size "${cow}b" \
             --addtag "$PB_SNAP_TAG" "${vg}/${lv}" 2>&1)" || rc=$?
    PB_COW_LV="${vg}/${snap}"
  fi

  if (( rc != 0 )); then
    pbdr_log "FEHLER: Snapshot ${vg}/${lv} fehlgeschlagen: ${out}" "ERROR: snapshot ${vg}/${lv} failed: ${out}"
    return 1
  fi
  PB_SNAPSHOTS+=("${vg}|${lv}|${snap}|${kind}|${role}|${guest}|${key}|${size}|${alloc}")
  pbdr_log "Snapshot angelegt: ${vg}/${snap}" "snapshot created: ${vg}/${snap}"
  return 0
}

# Entfernt ausschließlich Snapshots mit dem Tag DIESES Laufs. Es wird nie ein
# Namensmuster verwendet - ein PVE-eigener snap_vm-... kann so nicht getroffen
# werden, auch wenn die Laufzeitdatei verlorengegangen ist.
pve_snap_cleanup_run() {
  local tag="${1:-$PB_SNAP_TAG}" vg lv n=0
  [[ -n "$tag" ]] || return 0
  has_cmd lvs || return 0
  while read -r vg lv; do
    [[ -n "$vg" && -n "$lv" ]] || continue
    if timeout 120 lvremove -f "${vg}/${lv}" >/dev/null 2>&1; then
      n=$(( n + 1 ))
      pbdr_log "Snapshot entfernt: ${vg}/${lv}" "snapshot removed: ${vg}/${lv}"
    else
      pbdr_log "WARNUNG: Snapshot ${vg}/${lv} ließ sich nicht entfernen" \
               "WARNING: could not remove snapshot ${vg}/${lv}"
    fi
  done < <(timeout 60 lvs --noheadings -o vg_name,lv_name --select "lv_tags=${tag}" 2>/dev/null \
           | awk 'NF>=2{print $1" "$2}' || true)
  PB_SNAPSHOTS=()
  [[ -n "${PB_RUN_STATE:-}" ]] && rm -f "$PB_RUN_STATE"
  return 0
}

# Räumt Snapshots früherer Läufe auf, deren Prozess nicht mehr lebt.
pve_snap_cleanup_orphans() {
  local tag pid state n=0
  has_cmd lvs || return 0
  while read -r tag; do
    [[ "$tag" =~ ^pbdr_run_[0-9]{14}_[a-z0-9]+$ ]] || continue
    [[ "$tag" == "${PB_SNAP_TAG:-}" ]] && continue
    state="${RUN_DIR}/pbdr_${tag#pbdr_run_}.state"
    pid=""
    [[ -f "$state" ]] && pid="$(awk -F= '$1=="pid"{print $2; exit}' "$state" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      continue   # ein anderer Lauf ist noch aktiv
    fi
    msg "[*] Entferne Snapshots eines abgebrochenen Laufs (${tag}) ..." \
        "[*] Removing snapshots of an aborted run (${tag}) ..."
    pve_snap_cleanup_run "$tag"
    rm -f "$state"
    n=$(( n + 1 ))
  done < <(timeout 60 lvs --noheadings -o lv_tags 2>/dev/null \
           | tr ',' '\n' | tr -d ' ' | grep '^pbdr_run_' | sort -u || true)
  return 0
}

# --- Gäste anhalten und freigeben --------------------------------------------
pve_qemu_freeze() {
  local id="${1:?}" rc=0
  timeout "${PVE_DR_FREEZE_TIMEOUT:-60}" qm agent "$id" fsfreeze-freeze >/dev/null 2>&1 || rc=$?
  (( rc == 0 )) || return 1
  PB_FROZEN_VMS+=("$id")
  return 0
}

pve_qemu_thaw() {
  local id="${1:?}" rc=0 keep=()
  timeout "${PVE_DR_FREEZE_TIMEOUT:-60}" qm agent "$id" fsfreeze-thaw >/dev/null 2>&1 || rc=$?
  for v in ${PB_FROZEN_VMS[@]+"${PB_FROZEN_VMS[@]}"}; do
    [[ "$v" == "$id" ]] || keep+=("$v")
  done
  PB_FROZEN_VMS=(${keep[@]+"${keep[@]}"})
  return "$rc"
}

# Container: der cgroup-Freezer hält die Prozesse an, das Dateisystem hängt aber
# am Host-Kernel. Deshalb zusätzlich sync und FIFREEZE je Volume - erst damit
# ist der Snapshot dateisystemkonsistent und nicht nur absturzkonsistent.
pve_ct_freeze() {
  local id="${1:?}"; shift
  local mps=("$@") mp rc=0
  timeout 60 pct freeze "$id" >/dev/null 2>&1 || return 1
  PB_FROZEN_CTS+=("$id")
  sync
  for mp in ${mps[@]+"${mps[@]}"}; do
    [[ -n "$mp" ]] || continue
    if timeout 60 fsfreeze -f "$mp" >/dev/null 2>&1; then
      PB_CT_FSFROZEN+=("${id}|${mp}")
    else
      rc=1
      pbdr_log "FEHLER: Dateisystem ${mp} (CT ${id}) ließ sich nicht anhalten" \
               "ERROR: could not freeze filesystem ${mp} (CT ${id})"
      break
    fi
  done
  return "$rc"
}

pve_ct_thaw() {
  local id="${1:?}" entry cid mp keep=() rc=0
  for entry in ${PB_CT_FSFROZEN[@]+"${PB_CT_FSFROZEN[@]}"}; do
    cid="${entry%%|*}"; mp="${entry#*|}"
    if [[ "$cid" == "$id" ]]; then
      timeout 60 fsfreeze -u "$mp" >/dev/null 2>&1 || rc=1
    else
      keep+=("$entry")
    fi
  done
  PB_CT_FSFROZEN=(${keep[@]+"${keep[@]}"})
  timeout 60 pct unfreeze "$id" >/dev/null 2>&1 || rc=1
  keep=()
  for cid in ${PB_FROZEN_CTS[@]+"${PB_FROZEN_CTS[@]}"}; do
    [[ "$cid" == "$id" ]] || keep+=("$cid")
  done
  PB_FROZEN_CTS=(${keep[@]+"${keep[@]}"})
  return "$rc"
}

# Notfallfreigabe: gibt alles frei, was dieser Lauf angehalten hat.
pve_release_all_guests() {
  local v entry cid mp
  for entry in ${PB_CT_FSFROZEN[@]+"${PB_CT_FSFROZEN[@]}"}; do
    mp="${entry#*|}"; timeout 30 fsfreeze -u "$mp" >/dev/null 2>&1 || true
  done
  PB_CT_FSFROZEN=()
  for cid in ${PB_FROZEN_CTS[@]+"${PB_FROZEN_CTS[@]}"}; do
    timeout 30 pct unfreeze "$cid" >/dev/null 2>&1 || true
  done
  PB_FROZEN_CTS=()
  for v in ${PB_FROZEN_VMS[@]+"${PB_FROZEN_VMS[@]}"}; do
    timeout 30 qm agent "$v" fsfreeze-thaw >/dev/null 2>&1 || true
  done
  PB_FROZEN_VMS=()
  for v in ${PB_SHUTDOWN_VMS[@]+"${PB_SHUTDOWN_VMS[@]}"}; do
    pbdr_log "Starte VM ${v} wieder" "restarting VM ${v}"
    timeout 120 qm start "$v" >/dev/null 2>&1 || \
      pbdr_log "WARNUNG: VM ${v} konnte nicht gestartet werden" "WARNING: could not start VM ${v}"
  done
  PB_SHUTDOWN_VMS=()
  return 0
}

# --- Watchdog ----------------------------------------------------------------
# Läuft in einer eigenen Session. Ein Prozessgruppen-Kill, der den Worker
# trifft, nimmt ihn nicht mit. Er gibt nach Ablauf bedingungslos frei.
pve_watchdog_arm() {
  local secs="${1:-${PVE_DR_WATCHDOG_SEC:-120}}" vms="${2:-}" cts="${3:-}"
  [[ -n "${vms}${cts}" ]] || return 0
  pve_watchdog_disarm
  setsid nohup bash -c '
    echo $$ > "$4" 2>/dev/null || true
    sleep "$1"
    for vm in $2; do qm agent "$vm" fsfreeze-thaw >/dev/null 2>&1 || true; done
    for ct in $3; do
      while read -r mp; do [ -n "$mp" ] && fsfreeze -u "$mp" >/dev/null 2>&1 || true
      done < <(findmnt -rno TARGET 2>/dev/null | grep "/lxc/${ct}/" || true)
      pct unfreeze "$ct" >/dev/null 2>&1 || true
    done
    command -v logger >/dev/null 2>&1 && \
      logger -t panzerbackup "PVE-DR watchdog: Gaeste nach ${1}s bedingungslos freigegeben"
  ' _ "$secs" "$vms" "$cts" "${RUN_DIR}/pbdr_watchdog.pid" >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

pve_watchdog_disarm() {
  local f="${RUN_DIR}/pbdr_watchdog.pid" wpid
  [[ -f "$f" ]] || return 0
  wpid="$(cat "$f" 2>/dev/null || true)"
  [[ "$wpid" =~ ^[0-9]+$ ]] && kill "$wpid" >/dev/null 2>&1 || true
  rm -f "$f"
  return 0
}

# --- Überwachung von COW und Thin-Pool ---------------------------------------
# Ein voller Thin-Pool trifft die laufenden Gäste, nicht nur die Sicherung.
# Deshalb überwacht ein eigener Prozess durchgehend und fordert den Abbruch an,
# bevor es kritisch wird.
pve_monitor_start() {
  local worker="$$"
  pve_monitor_stop
  setsid nohup bash -c '
    vg="$1"; pool="$2"; cowlv="$3"; abort="$4"; worker="$5"; pidf="$6"
    dmax="$7"; mmax="$8"; cowabort="$9"; cowext="${10}"; cowwarn="${11}"; iv="${12}"
    echo $$ > "$pidf" 2>/dev/null || true
    ge() { awk -v a="${1:-0}" -v b="${2:-0}" "BEGIN{exit !((a+0)>=(b+0))}"; }
    while :; do
      sleep "$iv"
      kill -0 "$worker" 2>/dev/null || exit 0
      [ -f "$abort" ] && exit 0
      if [ -n "$pool" ]; then
        set -- $(lvs --noheadings --nosuffix -o data_percent,metadata_percent "$vg/$pool" 2>/dev/null)
        d="${1:-0}"; m="${2:-0}"
        if ge "$d" "$dmax"; then
          printf "Speicherpool zu voll (%s %%)\n" "$d" > "$abort"; kill -TERM "$worker" 2>/dev/null; exit 0
        fi
        if ge "$m" "$mmax"; then
          printf "Verwaltungsbereich des Speicherpools zu voll (%s %%)\n" "$m" > "$abort"; kill -TERM "$worker" 2>/dev/null; exit 0
        fi
      fi
      if [ -n "$cowlv" ]; then
        c=$(lvs --noheadings --nosuffix -o data_percent "$cowlv" 2>/dev/null | tr -d " ")
        [ -z "$c" ] && continue
        if ge "$c" "$cowabort"; then
          printf "Snapshot-Bereich fast voll (%s %%)\n" "$c" > "$abort"; kill -TERM "$worker" 2>/dev/null; exit 0
        fi
        if ge "$c" "$cowext"; then
          lvextend -L +25%LV "$cowlv" >/dev/null 2>&1 || true
        fi
      fi
    done
  ' _ "$PB_VG" "${PB_THINPOOL:-}" "${PB_COW_LV:-}" "$PB_ABORT_FILE" "$worker" \
    "${RUN_DIR}/pbdr_monitor.pid" "$PVE_DR_POOL_DATA_ABORT" "$PVE_DR_POOL_META_ABORT" \
    "$PVE_DR_COW_ABORT" "$PVE_DR_COW_EXTEND" "$PVE_DR_COW_WARN" "${PVE_DR_MONITOR_INTERVAL:-5}" \
    >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

pve_monitor_stop() {
  local f="${RUN_DIR}/pbdr_monitor.pid" mpid
  [[ -f "$f" ]] || return 0
  mpid="$(cat "$f" 2>/dev/null || true)"
  [[ "$mpid" =~ ^[0-9]+$ ]] && kill "$mpid" >/dev/null 2>&1 || true
  rm -f "$f"
  return 0
}

# =====================[ PVE-DR: Manifest und Metadaten ]======================
# manifest.tsv ist die maßgebliche Quelle für den Restore: zeilenweise,
# Tab-getrennt, mit reinem bash lesbar. Auf einem Live-System muss nichts
# nachinstalliert werden - insbesondere kein jq.
PB_STAGE=""            # Ablage für kleine Metadaten-Dateien
PB_PART_MEMBERS=()     # "member|quelle|bytes"
PB_DISK_GAP_BYTES=0

pbdr_log() {
  local de="${1:?}" en="${2:-$1}"
  local line; line="$(date '+%Y-%m-%d %H:%M:%S')  $( [[ "$LANG_CHOICE" == "de" ]] && printf '%s' "$de" || printf '%s' "$en" )"
  printf '%s\n' "$line"
  [[ -n "${PB_STAGE:-}" && -d "${PB_STAGE:-}" ]] && printf '%s\n' "$line" >> "${PB_STAGE}/backup.log" 2>/dev/null || true
  return 0
}

pbdr_stage_init() {
  PB_STAGE="${RUN_DIR}/pbdr_stage_${PB_RUN_ID}"
  rm -rf "$PB_STAGE"
  ( umask 077; mkdir -p "$PB_STAGE/hardware" "$PB_STAGE/disk" "$PB_STAGE/config" ) || return 1
  : > "$PB_STAGE/backup.log"
  return 0
}
pbdr_stage_clean() { [[ -n "${PB_STAGE:-}" ]] && rm -rf "$PB_STAGE"; return 0; }

pb_tsv_safe() { printf '%s' "${1-}" | tr -d '\t\n' ; }

# --- Hardware- und Konfigurationsabzüge --------------------------------------
pbdr_collect_hardware() {
  local h="$PB_STAGE/hardware"
  timeout 30 lsblk -b -O --json    > "$h/lsblk.json"      2>/dev/null || \
  timeout 30 lsblk -b -o NAME,PATH,TYPE,SIZE,FSTYPE,PARTTYPE,PARTUUID,UUID,MOUNTPOINT > "$h/lsblk.txt" 2>/dev/null || true
  timeout 30 blkid                 > "$h/blkid.txt"       2>/dev/null || true
  timeout 30 pvs  --units b --nosuffix -o pv_name,vg_name,pv_size,pv_free,pv_uuid > "$h/pvs.txt" 2>/dev/null || true
  timeout 30 vgs  --units b --nosuffix -o vg_name,vg_size,vg_free,vg_extent_size,vg_uuid > "$h/vgs.txt" 2>/dev/null || true
  timeout 30 lvs -a --units b --nosuffix \
      -o vg_name,lv_name,lv_attr,lv_size,data_percent,metadata_percent,pool_lv,origin,lv_uuid > "$h/lvs.txt" 2>/dev/null || true
  timeout 60 vgcfgbackup -f "$h/vgcfg-${PB_VG}.txt" "$PB_VG" >/dev/null 2>&1 || true
  timeout 30 pveversion -v         > "$h/pveversion.txt"  2>/dev/null || true
  [[ -r /etc/pve/storage.cfg ]] && pb_redact < /etc/pve/storage.cfg > "$h/storage.cfg" 2>/dev/null || true
  timeout 30 proxmox-boot-tool status > "$h/proxmox-boot.txt" 2>&1 || true
  [[ -r /etc/kernel/proxmox-boot-uuids ]] && cp -a /etc/kernel/proxmox-boot-uuids "$h/proxmox-boot-uuids" 2>/dev/null || true
  timeout 30 findmnt -a            > "$h/findmnt.txt"     2>/dev/null || true
  timeout 30 ip -o link            > "$h/ip-link.txt"     2>/dev/null || true
  timeout 30 lscpu                 > "$h/lscpu.txt"       2>/dev/null || true
  timeout 30 dmidecode -t system   > "$h/dmi.txt"         2>/dev/null || true
  return 0
}

# /etc/pve ist ein FUSE-Dateisystem; die Inhalte werden gelesen, nicht das
# Dateisystem kopiert. Der private Schlüsselbereich bleibt ausgespart, damit
# ein unverschlüsseltes Backup keine Zugangsdaten preisgibt.
pbdr_collect_config() {
  local c="$PB_STAGE/config" p
  ( umask 077; mkdir -p "$c" ) || return 1
  if [[ -d /etc/pve ]]; then
    ( cd / && timeout 300 tar --warning=no-file-changed --exclude='etc/pve/priv' \
        -cf "$c/etc-pve.tar" etc/pve 2>/dev/null ) || true
  fi
  local -a want=() have=()
  want=(etc/network etc/hosts etc/hostname etc/fstab etc/resolv.conf
        etc/default/grub etc/kernel etc/systemd/network etc/modprobe.d
        etc/lvm/lvm.conf etc/vzdump.conf)
  for p in "${want[@]}"; do [[ -e "/$p" ]] && have+=("$p"); done
  (( ${#have[@]} )) && ( cd / && timeout 120 tar -cf "$c/etc-system.tar" "${have[@]}" 2>/dev/null ) || true
  return 0
}

# --- Partitionen und Startbereich --------------------------------------------
# Der Startbereich vor der ersten Partition enthält den MBR-Bootcode, die
# GPT und bei BIOS-Installationen den Kern des Bootloaders. sfdisk sichert
# davon nichts, also wird er als Rohabbild mitgenommen.
pbdr_collect_disk() {
  local d="$PB_STAGE/disk" first n dev role size
  local base; base="$(basename "$PB_DISK")"

  timeout 60 sfdisk -d "$PB_DISK" > "$d/${base}.sfdisk" 2>/dev/null || {
    pbdr_log "FEHLER: Partitionstabelle von ${PB_DISK} nicht lesbar" \
             "ERROR: cannot read partition table of ${PB_DISK}"; return 1; }

  first="$(awk -F'start=' '/start=/{split($2,a,","); gsub(/ /,"",a[1]); if (a[1] ~ /^[0-9]+$/ && (m=="" || a[1]+0 < m+0)) m=a[1]} END{print m+0}' "$d/${base}.sfdisk")"
  [[ "$first" =~ ^[0-9]+$ ]] && (( first > 0 )) || first=2048
  PB_DISK_GAP_BYTES=$(( first * 512 ))
  timeout 120 dd if="$PB_DISK" of="$d/${base}.gap.img" bs=512 count="$first" \
      status=none 2>/dev/null || return 1

  # Jede Partition außer dem physischen Volume wird als Rohabbild gesichert.
  # Damit sind ESP, /boot und ein BIOS-Boot-Bereich erfasst, ohne dass ihre
  # Rolle erraten werden muss.
  PB_PART_MEMBERS=()
  while read -r dev; do
    [[ -n "$dev" && -b "$dev" ]] || continue
    [[ "$dev" == "$PB_PV" ]] && continue
    n="${dev##*[!0-9]}"; [[ "$n" =~ ^[0-9]+$ ]] || n="0"
    size="$(timeout 20 blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
    (( size > 0 )) || continue
    if (( size > ${PVE_DR_MAX_PART_BYTES:-8589934592} )); then
      pbdr_log "FEHLER: Partition ${dev} ist zu groß für die Startbereichssicherung (${size} B)" \
               "ERROR: partition ${dev} too large for boot-area capture (${size} B)"
      return 1
    fi
    role="$(timeout 20 blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
    PB_PART_MEMBERS+=("parts/part-${n}.img|${dev}|${size}|${role:-unknown}|$(timeout 20 blkid -o value -s UUID "$dev" 2>/dev/null || true)|$(timeout 20 blkid -o value -s PARTUUID "$dev" 2>/dev/null || true)")
  done < <(timeout 30 lsblk -rnpo NAME,TYPE "$PB_DISK" 2>/dev/null | awk '$2=="part"{print $1}' || true)
  return 0
}

# --- Manifest ----------------------------------------------------------------
pbdr_write_manifest() {
  local f="$PB_STAGE/manifest.tsv" s vg lv snap kind role guest key size alloc
  {
    printf '#panzerbackup-pve-dr\tformat_version=%s\n' "$PZB_FORMAT_VERSION"
    printf 'META\tcreated\t%s\n'        "$(date -Is)"
    printf 'META\tcreated_epoch\t%s\n'  "$(date +%s)"
    printf 'META\thostname\t%s\n'       "$(pb_tsv_safe "$(hostname -s 2>/dev/null || echo pve)")"
    printf 'META\tpve_version\t%s\n'    "$(pb_tsv_safe "$(pve_version_string)")"
    printf 'META\tpanzerbackup\t%s\n'   "$VERSION"
    printf 'META\trun_id\t%s\n'         "$PB_RUN_ID"
    printf 'META\tcluster\t%s\n'        "$( [[ -e /etc/pve/corosync.conf ]] && echo true || echo false )"
    printf 'META\tencrypted\t%s\n'      "$( [[ "$ENCRYPT_MODE" == gpg ]] && echo true || echo false )"
    printf 'META\tconsistency\t%s\n'    "strict"
    printf 'BOOT\t%s\t%s\t%s\t%s\t%s\n' \
      "$(pb_tsv_safe "${PB_BOOT_METHOD:-unknown}")" "$(pb_tsv_safe "${PB_ESP:-}")" \
      "$(pb_tsv_safe "$(timeout 20 blkid -o value -s UUID "${PB_ESP:-/nonexistent}" 2>/dev/null || true)")" \
      "$(pb_tsv_safe "${PB_BIOSBOOT:-}")" "$(pb_tsv_safe "${PB_BOOT_DETAIL:-}")"
    printf 'DISK\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(pb_tsv_safe "$PB_DISK")" "$PB_DISK_SIZE" "$(pb_tsv_safe "${PB_PTTYPE:-gpt}")" \
      "disk/$(basename "$PB_DISK").sfdisk" "disk/$(basename "$PB_DISK").gap.img" "$PB_DISK_GAP_BYTES"
    local pm member src bytes fstype uuid partuuid
    for pm in ${PB_PART_MEMBERS[@]+"${PB_PART_MEMBERS[@]}"}; do
      IFS='|' read -r member src bytes fstype uuid partuuid <<< "$pm"
      printf 'PART\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(pb_tsv_safe "$src")" "$bytes" "$(pb_tsv_safe "$fstype")" \
        "$(pb_tsv_safe "$uuid")" "$(pb_tsv_safe "$partuuid")" "$(pb_tsv_safe "$member")"
    done
    printf 'PVPART\t%s\t%s\n' "$(pb_tsv_safe "$PB_PV")" "$(pb_tsv_safe "${PB_PV##*[!0-9]}")"
    printf 'VG\t%s\t%s\t%s\t%s\n' "$(pb_tsv_safe "$PB_VG")" "$PB_VG_SIZE" "$PB_VG_FREE" \
      "$(timeout 20 vgs --noheadings --units b --nosuffix -o vg_extent_size "$PB_VG" 2>/dev/null | tr -d ' ' || echo 4194304)"
    if [[ -n "${PB_THINPOOL:-}" ]]; then
      printf 'POOL\t%s\t%s\t%s\t%s\t%s\n' "$(pb_tsv_safe "$PB_THINPOOL")" "$PB_POOL_SIZE" \
        "$(timeout 20 lvs --noheadings --units b --nosuffix -o chunk_size "${PB_VG}/${PB_THINPOOL}" 2>/dev/null | tr -d ' ' || echo 0)" \
        "$(pb_tsv_safe "${PB_POOL_DATA:-}")" "$(pb_tsv_safe "${PB_POOL_META:-}")"
    fi
    [[ -n "${PB_SWAP_LV:-}" ]] && printf 'SWAP\t%s\t%s\t%s\t%s\n' \
      "$(pb_tsv_safe "$PB_VG")" "$(pb_tsv_safe "$PB_SWAP_LV")" "${PB_SWAP_SIZE:-0}" "$(pb_tsv_safe "${PB_SWAP_UUID:-}")"
    for s in ${PB_SNAPSHOTS[@]+"${PB_SNAPSHOTS[@]}"}; do
      IFS='|' read -r vg lv snap kind role guest key size alloc <<< "$s"
      printf 'VOL\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(pb_tsv_safe "$role")" "$(pb_tsv_safe "$vg")" "$(pb_tsv_safe "$lv")" \
        "$(pb_tsv_safe "$kind")" "$size" "$alloc" "$(pb_tsv_safe "${PB_THINPOOL:-}")" \
        "$(pb_tsv_safe "$guest")" "$(pb_tsv_safe "$key")" \
        "volumes/vol_$(pb_tsv_safe "${vg}__${lv}").img" "$(pb_tsv_safe "$snap")"
    done
    local g t id st q vc
    for g in ${PB_GUEST_REPORT[@]+"${PB_GUEST_REPORT[@]}"}; do
      IFS='|' read -r t id st q vc <<< "$g"
      printf 'GUEST\t%s\t%s\t%s\t%s\t%s\n' "$t" "$id" "$(pb_tsv_safe "$st")" "$(pb_tsv_safe "$q")" "$vc"
    done
    printf 'CONFIG\tconfig/etc-pve.tar\tconfig/etc-system.tar\n'
    printf 'ENDMANIFEST\n'
  } > "$f" || return 1
  pbdr_manifest_json > "$PB_STAGE/manifest.json" || return 1
  return 0
}

# Dieselben Angaben noch einmal als JSON - für Menschen und externe Werkzeuge.
# Der Restore verwendet ausschließlich die TSV-Fassung.
pbdr_json_esc() { printf '%s' "${1-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'; }
pbdr_manifest_json() {
  local s vg lv snap kind role guest key size alloc first=1 g t id st q vc
  printf '{\n  "format": "%s",\n  "format_version": %s,\n' "$PZB_FORMAT" "$PZB_FORMAT_VERSION"
  printf '  "created": "%s",\n'   "$(date -Is)"
  printf '  "hostname": "%s",\n'  "$(pbdr_json_esc "$(hostname -s 2>/dev/null || echo pve)")"
  printf '  "pve_version": "%s",\n' "$(pbdr_json_esc "$(pve_version_string)")"
  printf '  "panzerbackup": "%s",\n' "$VERSION"
  printf '  "encrypted": %s,\n'   "$( [[ "$ENCRYPT_MODE" == gpg ]] && echo true || echo false )"
  printf '  "consistency": "strict",\n'
  printf '  "boot_method": "%s",\n' "$(pbdr_json_esc "${PB_BOOT_METHOD:-unknown}")"
  printf '  "source_disk": "%s",\n' "$(pbdr_json_esc "$PB_DISK")"
  printf '  "source_disk_size": %s,\n' "${PB_DISK_SIZE:-0}"
  printf '  "partition_table_type": "%s",\n' "$(pbdr_json_esc "${PB_PTTYPE:-gpt}")"
  printf '  "vg": "%s",\n' "$(pbdr_json_esc "$PB_VG")"
  printf '  "root_lv": "%s",\n' "$(pbdr_json_esc "$PB_ROOT_LV")"
  printf '  "thinpool": "%s",\n' "$(pbdr_json_esc "${PB_THINPOOL:-}")"
  printf '  "volumes": ['
  for s in ${PB_SNAPSHOTS[@]+"${PB_SNAPSHOTS[@]}"}; do
    IFS='|' read -r vg lv snap kind role guest key size alloc <<< "$s"
    (( first )) && { printf '\n'; first=0; } || printf ',\n'
    printf '    {"role":"%s","vg":"%s","lv":"%s","type":"%s","size":%s,"allocated":%s,"guest":"%s","key":"%s","member":"volumes/vol_%s.img"}' \
      "$(pbdr_json_esc "$role")" "$(pbdr_json_esc "$vg")" "$(pbdr_json_esc "$lv")" \
      "$(pbdr_json_esc "$kind")" "$size" "$alloc" "$(pbdr_json_esc "$guest")" \
      "$(pbdr_json_esc "$key")" "$(pbdr_json_esc "${vg}__${lv}")"
  done
  (( first )) || printf '\n  '
  printf '],\n  "guests": ['
  first=1
  for g in ${PB_GUEST_REPORT[@]+"${PB_GUEST_REPORT[@]}"}; do
    IFS='|' read -r t id st q vc <<< "$g"
    (( first )) && { printf '\n'; first=0; } || printf ',\n'
    printf '    {"type":"%s","id":%s,"status":"%s","quiesce":"%s","volumes":%s}' \
      "$t" "$id" "$(pbdr_json_esc "$st")" "$(pbdr_json_esc "$q")" "${vc:-0}"
  done
  (( first )) || printf '\n  '
  printf ']\n}\n'
}

# =====================[ PVE-DR: Sicherungslauf ]==============================
PB_FINAL=""; PB_PART=""; PB_CLEANUP_DONE=0

pve_dr_cleanup() {
  (( PB_CLEANUP_DONE )) && return 0
  PB_CLEANUP_DONE=1
  pve_monitor_stop
  pve_release_all_guests
  pve_watchdog_disarm
  pve_snap_cleanup_run
  pbdr_stage_clean
  [[ -n "${PB_PART:-}" && -f "${PB_PART:-}" ]] && rm -f "$PB_PART"
  clear_passphrase_file
  return 0
}

pve_dr_fail() {
  local de="${1:?}" en="${2:-$1}"
  pbdr_log "FEHLER: $de" "ERROR: $en"
  set_status "$( [[ "$LANG_CHOICE" == de ]] && echo "FEHLER: $de" || echo "ERROR: $en" )"
  pve_dr_cleanup
  return 1
}

# --- Gäste anhalten und Snapshots erzeugen -----------------------------------
pb_guest_volumes_of() {
  local t="${1:?}" id="${2:?}" v vt vi vk vg lv kind
  for v in ${PB_VOLUMES[@]+"${PB_VOLUMES[@]}"}; do
    IFS='|' read -r vt vi vk vg lv kind _ _ <<< "$v"
    [[ "$vt" == "$t" && "$vi" == "$id" ]] || continue
    printf '%s|%s|%s|%s\n' "$vg" "$lv" "$kind" "$vk"
  done
}

pb_ct_mountpoints_of() {
  local id="${1:?}" line vg lv kind key mp
  while IFS='|' read -r vg lv kind key; do
    [[ -n "$lv" ]] || continue
    for cand in "/dev/${vg}/${lv}" "/dev/mapper/${vg//-/--}-${lv//-/--}"; do
      mp="$(pve_resolve_mountpoint "$cand" 2>/dev/null || true)"
      [[ -n "$mp" ]] && { printf '%s\n' "$mp"; break; }
    done
  done < <(pb_guest_volumes_of lxc "$id")
}

pve_dr_snapshot_one_guest() {
  local t="${1:?}" id="${2:?}" st="${3:?}"
  local vg lv kind key rc=0 mps=() mp restart=0

  if [[ "$st" != "running" ]]; then
    while IFS='|' read -r vg lv kind key; do
      [[ -n "$lv" ]] || continue
      pve_snap_create "$vg" "$lv" "$kind" "guest" "${t}/${id}" "$key" || return 1
    done < <(pb_guest_volumes_of "$t" "$id")
    return 0
  fi

  if [[ "$t" == "qemu" ]]; then
    local cfg; cfg="$(pve_guest_config_text qemu "$id" || true)"
    if pb_qemu_fsfreeze_disabled "$cfg"; then
      # Kein stiller Ersatz durch suspend: entweder der Benutzer hat einem
      # kontrollierten Herunterfahren ausdrücklich zugestimmt, oder der Lauf
      # scheitert. Ein "suspend" hält nur die CPU an, nicht die Dateisysteme.
      if [[ "${PVE_DR_ALLOW_SHUTDOWN:-0}" != "1" ]]; then
        pve_dr_fail "VM ${id} darf nicht angehalten werden (freeze-fs-on-backup=0) und ein Herunterfahren wurde nicht erlaubt." \
                    "VM ${id} must not be paused (freeze-fs-on-backup=0) and shutdown was not permitted."
        return 1
      fi
      pbdr_log "VM ${id}: fahre kontrolliert herunter (ausdrücklich erlaubt)" \
               "VM ${id}: shutting down in a controlled way (explicitly permitted)"
      timeout "${PVE_DR_SHUTDOWN_TIMEOUT:-300}" qm shutdown "$id" --timeout "${PVE_DR_SHUTDOWN_TIMEOUT:-300}" >/dev/null 2>&1 || rc=$?
      local waited=0
      while (( waited < ${PVE_DR_SHUTDOWN_TIMEOUT:-300} )); do
        [[ "$(timeout 20 qm status "$id" 2>/dev/null | awk '{print $2}')" == "stopped" ]] && break
        sleep 2; waited=$(( waited + 2 ))
      done
      if [[ "$(timeout 20 qm status "$id" 2>/dev/null | awk '{print $2}')" != "stopped" ]]; then
        pve_dr_fail "VM ${id} ließ sich nicht herunterfahren." "VM ${id} could not be shut down."
        return 1
      fi
      PB_SHUTDOWN_VMS+=("$id"); restart=1
    else
      pve_watchdog_arm "${PVE_DR_WATCHDOG_SEC:-120}" "$id" ""
      if ! pve_qemu_freeze "$id"; then
        pve_watchdog_disarm
        pve_dr_fail "VM ${id} ließ sich nicht anhalten (Gastagent)." "VM ${id} could not be frozen (guest agent)."
        return 1
      fi
      pbdr_log "VM ${id}: Dateisysteme angehalten" "VM ${id}: filesystems frozen"
    fi
  else
    mapfile -t mps < <(pb_ct_mountpoints_of "$id")
    pve_watchdog_arm "${PVE_DR_WATCHDOG_SEC:-120}" "" "$id"
    if ! pve_ct_freeze "$id" ${mps[@]+"${mps[@]}"}; then
      pve_ct_thaw "$id" || true
      pve_watchdog_disarm
      pve_dr_fail "Container ${id} ließ sich nicht anhalten." "Container ${id} could not be frozen."
      return 1
    fi
    pbdr_log "CT ${id}: angehalten (${#mps[@]} Datenbereiche)" "CT ${id}: frozen (${#mps[@]} data areas)"
  fi

  while IFS='|' read -r vg lv kind key; do
    [[ -n "$lv" ]] || continue
    pve_snap_create "$vg" "$lv" "$kind" "guest" "${t}/${id}" "$key" || { rc=1; break; }
  done < <(pb_guest_volumes_of "$t" "$id")

  # Freigeben passiert IMMER und sofort - auch wenn ein Snapshot scheiterte.
  if [[ "$t" == "qemu" ]]; then
    if (( restart )); then
      pbdr_log "VM ${id}: starte wieder" "VM ${id}: starting again"
      timeout 300 qm start "$id" >/dev/null 2>&1 || \
        pbdr_log "WARNUNG: VM ${id} startete nicht" "WARNING: VM ${id} did not start"
      local keep=() v
      for v in ${PB_SHUTDOWN_VMS[@]+"${PB_SHUTDOWN_VMS[@]}"}; do [[ "$v" == "$id" ]] || keep+=("$v"); done
      PB_SHUTDOWN_VMS=(${keep[@]+"${keep[@]}"})
    else
      pve_qemu_thaw "$id" || pbdr_log "WARNUNG: Thaw von VM ${id} meldete einen Fehler" \
                                      "WARNING: thawing VM ${id} reported an error"
      pbdr_log "VM ${id}: freigegeben" "VM ${id}: released"
    fi
  else
    pve_ct_thaw "$id" || pbdr_log "WARNUNG: Freigabe von CT ${id} meldete einen Fehler" \
                                  "WARNING: releasing CT ${id} reported an error"
    pbdr_log "CT ${id}: freigegeben" "CT ${id}: released"
  fi
  pve_watchdog_disarm
  (( rc == 0 )) || { pve_dr_fail "Snapshot für ${t}/${id} fehlgeschlagen." "Snapshot for ${t}/${id} failed."; return 1; }
  return 0
}

pve_dr_make_snapshots() {
  local g t id st q vc
  set_status "$(status_msg "BACKUP: Erzeuge Momentaufnahme des Systems..." "BACKUP: Creating system snapshot...")"
  pve_snap_create "$PB_VG" "$PB_ROOT_LV" "classic" "host-root" "" "" "$PB_COW_ROOT" || {
    pve_dr_fail "Momentaufnahme des Systemdatenträgers fehlgeschlagen." \
                "Snapshot of the system volume failed."; return 1; }
  pve_monitor_start

  for g in ${PB_GUEST_REPORT[@]+"${PB_GUEST_REPORT[@]}"}; do
    IFS='|' read -r t id st q vc <<< "$g"
    (( vc > 0 )) || continue
    set_status "$(status_msg "BACKUP: Momentaufnahme ${t}/${id}..." "BACKUP: Snapshot ${t}/${id}...")"
    pve_dr_snapshot_one_guest "$t" "$id" "$st" || return 1
    pve_dr_abort_requested && { pve_dr_fail "Abbruch: $(pve_dr_abort_reason)" "Aborted: $(pve_dr_abort_reason)"; return 1; }
  done
  pbdr_log "Alle Momentaufnahmen erstellt, alle Gäste laufen wieder" \
           "all snapshots created, all guests running again"
  return 0
}

# --- Datenstrom schreiben -----------------------------------------------------
pbdr_stream_body() {
  local s vg lv snap kind role guest key size alloc pm member src bytes f base
  base="$(basename "$PB_DISK")"
  pzb_w_header
  # Reihenfolge ist Absicht: erst der Plan, dann Partitionstabelle und
  # Startbereich, dann die kleinen Metadaten - und erst danach alles Große.
  # Der Restore kann damit Partitionen anlegen, bevor die Abbilder kommen, und
  # muss nichts zwischenspeichern, was groß ist.
  pzb_w_member_file  manifest.tsv  "$PB_STAGE/manifest.tsv"  || return 1
  pzb_w_member_file  manifest.json "$PB_STAGE/manifest.json" || return 1
  pzb_w_member_file  "disk/${base}.sfdisk"  "$PB_STAGE/disk/${base}.sfdisk"  || return 1
  pzb_w_member_file  "disk/${base}.gap.img" "$PB_STAGE/disk/${base}.gap.img" || return 1
  for f in "$PB_STAGE"/hardware/*; do
    [[ -f "$f" ]] || continue
    pzb_w_member_file "hardware/$(basename "$f")" "$f" || return 1
  done
  for f in "$PB_STAGE"/config/*; do
    [[ -f "$f" ]] || continue
    pzb_w_member_file "config/$(basename "$f")" "$f" || return 1
  done
  for pm in ${PB_PART_MEMBERS[@]+"${PB_PART_MEMBERS[@]}"}; do
    IFS='|' read -r member src bytes _ _ _ <<< "$pm"
    pve_dr_abort_requested && { echo "pzb: Abbruch angefordert" >&2; return 1; }
    pzb_w_member_device "$member" "$src" || return 1
  done
  for s in ${PB_SNAPSHOTS[@]+"${PB_SNAPSHOTS[@]}"}; do
    IFS='|' read -r vg lv snap kind role guest key size alloc <<< "$s"
    pve_dr_abort_requested && { echo "pzb: Abbruch angefordert" >&2; return 1; }
    pzb_w_member_device "volumes/vol_${vg}__${lv}.img" "/dev/${vg}/${snap}" || return 1
  done
  pzb_w_member_file logs/backup.log "$PB_STAGE/backup.log" || true
  pzb_w_member_text  SHA256SUMS "$PZB_SUMS" || return 1
  pzb_w_end
  return 0
}

pve_dr_write_bundle() {
  local rc=0 st
  set_status "$(status_msg "BACKUP: Schreibe Sicherungsdatei..." "BACKUP: Writing backup file...")"
  set -o pipefail
  if [[ "$ENCRYPT_MODE" == "gpg" ]]; then
    pbdr_stream_body \
      | zstd -T0 -"${ZSTD_LEVEL:-6}" -q \
      | gpg --batch --yes --symmetric --cipher-algo AES256 \
            --pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE" \
      > "$PB_PART" || rc=$?
  else
    pbdr_stream_body \
      | zstd -T0 -"${ZSTD_LEVEL:-6}" -q \
      > "$PB_PART" || rc=$?
  fi
  set +o pipefail
  if (( rc != 0 )); then
    if pve_dr_abort_requested; then
      pve_dr_fail "Sicherung abgebrochen: $(pve_dr_abort_reason)" "Backup aborted: $(pve_dr_abort_reason)"
    else
      pve_dr_fail "Schreiben der Sicherungsdatei fehlgeschlagen (RC=$rc)." "Writing the backup file failed (RC=$rc)."
    fi
    return 1
  fi
  st="$(stat -c '%s' "$PB_PART" 2>/dev/null || echo 0)"
  (( st > 0 )) || { pve_dr_fail "Die Sicherungsdatei ist leer." "The backup file is empty."; return 1; }
  pbdr_log "Sicherungsdatei geschrieben: $(human_bytes "$st")" "backup file written: $(human_bytes "$st")"
  return 0
}

# --- Gesamtlauf ---------------------------------------------------------------
pve_dr_backup_run() {
  local name sha
  trap 'pve_dr_cleanup; exit 143' TERM
  trap 'pve_dr_cleanup; exit 130' INT
  trap 'pve_dr_cleanup; exit 129' HUP

  pve_run_id_new || { msg "[!] Laufkennung konnte nicht angelegt werden." "[!] Could not create run id."; return 1; }
  pve_snap_cleanup_orphans
  pbdr_stage_init || return 1

  set_status "$(status_msg "BACKUP: Prüfe das System..." "BACKUP: Checking the system...")"
  if ! pve_dr_preflight; then
    pve_dr_report_summary
    pve_dr_fail "Das System ist für die Proxmox-Sicherung nicht bereit." \
                "The system is not ready for the Proxmox backup."
    return 1
  fi

  name="${BACKUP_NAME:-$(hostname -s 2>/dev/null || echo pve)}"
  name="${name//[^[:alnum:]_-]/}"; [[ -n "$name" ]] || name="pve"
  PB_FINAL="${BACKUP_DIR}/panzer_${name}_${DATE}.pzb"
  PB_PART="${PB_FINAL}.part"
  rm -f "$PB_PART"

  set_status "$(status_msg "BACKUP: Sammle Systeminformationen..." "BACKUP: Collecting system information...")"
  pbdr_collect_hardware
  pbdr_collect_config
  pbdr_collect_disk || { pve_dr_fail "Startbereich konnte nicht gesichert werden." "Could not capture the boot area."; return 1; }

  pve_dr_make_snapshots || return 1
  pbdr_write_manifest || { pve_dr_fail "Manifest konnte nicht geschrieben werden." "Could not write the manifest."; return 1; }
  pve_dr_write_bundle || return 1

  set_status "$(status_msg "BACKUP: Prüfe die Sicherungsdatei..." "BACKUP: Verifying the backup file...")"
  pve_monitor_stop
  pve_snap_cleanup_run

  if ! pzb_verify_file "$PB_PART" quiet; then
    pve_dr_fail "Die geschriebene Sicherungsdatei ist nicht vollständig lesbar." \
                "The backup file that was written is not fully readable."
    return 1
  fi

  sha="$(sha256sum -b "$PB_PART" | cut -d' ' -f1)"
  mv -f "$PB_PART" "$PB_FINAL" || { pve_dr_fail "Umbenennen fehlgeschlagen." "Rename failed."; return 1; }
  printf '%s  %s\n' "$sha" "$(basename "$PB_FINAL")" > "${PB_FINAL}.sha256"
  PB_PART=""
  sync

  ln -sfn "$(basename "$PB_FINAL")"        "${BACKUP_DIR}/LATEST_OK"
  ln -sfn "$(basename "$PB_FINAL").sha256" "${BACKUP_DIR}/LATEST_OK.sha256"
  pbdr_retention

  pbdr_log "Sicherung erfolgreich: $(basename "$PB_FINAL")" "backup successful: $(basename "$PB_FINAL")"
  set_status "$(status_msg "BACKUP: Erfolgreich abgeschlossen - $(basename "$PB_FINAL")" "BACKUP: Completed successfully - $(basename "$PB_FINAL")")"
  pve_dr_cleanup
  return 0
}

# --- Aufbewahrung -------------------------------------------------------------
# RAW-Abbilder und PVE-DR-Sicherungen werden getrennt gezählt, damit eine Serie
# des einen Typs nicht die letzte Sicherung des anderen verdrängt.
pbdr_retention() {
  local nkeep="${KEEP_PVE_DR:-${KEEP:-3}}" n=0 old
  mapfile -t _pzb < <(ls -1t "$BACKUP_DIR"/panzer_*.pzb 2>/dev/null || true)
  (( ${#_pzb[@]} > nkeep )) || return 0
  for old in "${_pzb[@]:$nkeep}"; do
    [[ -f "$old" ]] || continue
    pbdr_log "Entferne alte Sicherung: $(basename "$old")" "removing old backup: $(basename "$old")"
    rm -f -- "$old" "${old}.sha256"
    n=$(( n + 1 ))
  done
  if [[ -L "${BACKUP_DIR}/LATEST_OK" ]] && [[ ! -e "${BACKUP_DIR}/LATEST_OK" ]]; then
    rm -f "${BACKUP_DIR}/LATEST_OK" "${BACKUP_DIR}/LATEST_OK.sha256"
  fi
  return 0
}

# =====================[ .pzb lesen: Prüfen und Wiederherstellen ]=============
# Eine .pzb-Datei ist außen genauso aufgebaut wie ein RAW-Abbild: zstd, davor
# optional gpg. Welche der beiden Hüllen vorliegt, wird an den ersten Bytes
# erkannt - der Benutzer muss nichts angeben.
PZB_ENC=0

pzb_file_is_encrypted() {
  local f="${1:?}" magic
  magic="$(head -c 4 -- "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)"
  [[ "$magic" == 28b52ffd* ]] && return 1     # zstd -> unverschlüsselt
  return 0
}

# Gibt den entpackten Containerstrom auf stdout aus.
pzb_decode() {
  local f="${1:?}"
  if (( PZB_ENC )); then
    gpg --batch --yes --decrypt --pinentry-mode loopback \
        --passphrase-file "$PASSPHRASE_FILE" -- "$f" 2>/dev/null | zstd -dc
  else
    zstd -dc -- "$f"
  fi
}

# Fragt die Passphrase, falls die Datei verschlüsselt ist.
pzb_prepare_read() {
  local f="${1:?}"
  PZB_ENC=0
  pzb_file_is_encrypted "$f" && PZB_ENC=1
  (( PZB_ENC )) || return 0
  need_cmd gpg
  if [[ -z "${ENCRYPT_PASSPHRASE:-}" && ! -s "${PASSPHRASE_FILE:-/nonexistent}" ]]; then
    if [[ -t 0 && -t 1 ]]; then
      if [[ "$LANG_CHOICE" == "de" ]]; then read -rsp "Passphrase für diese Sicherung: " ENCRYPT_PASSPHRASE; echo
      else read -rsp "Passphrase for this backup: " ENCRYPT_PASSPHRASE; echo; fi
    else
      die "Diese Sicherung ist verschlüsselt; bitte --passfile angeben." \
          "This backup is encrypted; please supply --passfile."
    fi
  fi
  if [[ -n "${ENCRYPT_PASSPHRASE:-}" ]]; then
    write_passphrase_file "$ENCRYPT_PASSPHRASE" || return 1
    ENCRYPT_PASSPHRASE=""
  fi
  return 0
}

# --- Manifest lesen (nur der erste Bestandteil) -------------------------------
PB_MF=""      # Datei mit dem gelesenen manifest.tsv
pzb_read_manifest() {
  local f="${1:?}" rc=0
  PB_MF="${RUN_DIR}/pzb_manifest.$$"
  rm -f "$PB_MF"
  # Der Plan steht als erster Bestandteil im Strom. Sobald er gelesen ist, wird
  # die Leitung geschlossen - es wird also nicht die ganze Datei gelesen.
  {
    pzb_r_open || exit 1
    pzb_r_next || exit 1
    [[ "$PZB_R_PATH" == "manifest.tsv" ]] || { echo "pzb: Manifest fehlt an erster Stelle" >&2; exit 1; }
    pzb_r_member > "$PB_MF" || exit 1
  } < <(pzb_decode "$f") || rc=$?
  (( rc == 0 )) || { rm -f "$PB_MF"; PB_MF=""; return 1; }
  [[ -s "$PB_MF" ]] || { rm -f "$PB_MF"; PB_MF=""; return 1; }
  head -n1 "$PB_MF" | grep -q '^#panzerbackup-pve-dr' || {
    echo "pzb: Manifest ist unbrauchbar" >&2; rm -f "$PB_MF"; PB_MF=""; return 1; }
  return 0
}

mf_meta()  { awk -F'\t' -v k="$2" '$1=="META" && $2==k {print $3; exit}' "$1"; }
mf_rows()  { awk -F'\t' -v t="$2" '$1==t' "$1"; }

# --- Prüfen -------------------------------------------------------------------
pzb_verify_file() {
  local f="${1:?}" quiet="${2:-}" rc=0 n=0 bad=0 tmp got want path
  tmp="${RUN_DIR}/pzb_verify.$$"; rm -rf "$tmp"; ( umask 077; mkdir -p "$tmp" )

  {
    pzb_r_open || exit 1
    while :; do
      pzb_r_next; local r=$?
      (( r == 2 )) && break
      (( r == 0 )) || exit 1
      if [[ "$PZB_R_PATH" == "SHA256SUMS" ]]; then
        printf '%s\n' "$PZB_R_SIZE" >> "$tmp/sizes"
        pzb_r_member > "$tmp/SHA256SUMS" || exit 1
      else
        printf '%s\n' "$PZB_R_SIZE" >> "$tmp/sizes"
        pzb_r_member "$tmp/sha.one" > /dev/null || exit 1
        printf '%s  %s\n' "$(cat "$tmp/sha.one")" "$PZB_R_PATH" >> "$tmp/computed"
      fi
    done
    printf '%s\t%s\n' "$PZB_R_COUNT" "$PZB_R_TOTAL" > "$tmp/count"
  } < <(pzb_decode "$f") || rc=$?

  if (( rc != 0 )); then rm -rf "$tmp"; return 1; fi
  [[ -s "$tmp/SHA256SUMS" ]] || { [[ "$quiet" == quiet ]] || msg "[!] Die Prüfsummenliste fehlt in der Sicherung." "[!] The checksum list is missing from the backup."; rm -rf "$tmp"; return 1; }
  n="$(wc -l < "$tmp/computed" 2>/dev/null || echo 0)"
  local decl_count decl_total
  IFS=$'\t' read -r decl_count decl_total < "$tmp/count" 2>/dev/null || true
  local sum_bytes
  sum_bytes="$(awk '{t+=$1} END{printf "%d", t+0}' "$tmp/sizes" 2>/dev/null || echo 0)"
  if [[ "$decl_total" =~ ^[0-9]+$ ]] && (( decl_total > 0 && sum_bytes > 0 && decl_total != sum_bytes )); then
    [[ "$quiet" == quiet ]] || msg "  [!] Die Sicherung nennt $(human_bytes "$decl_total"), gelesen wurden $(human_bytes "$sum_bytes")." \
                                   "  [!] The backup declares $(human_bytes "$decl_total"), $(human_bytes "$sum_bytes") were read."
    rm -rf "$tmp"; return 1
  fi
  if [[ "$decl_count" =~ ^[0-9]+$ ]] && (( decl_count != n + 1 )); then
    [[ "$quiet" == quiet ]] || msg "  [!] Die Sicherung nennt ${decl_count} Bestandteile, gelesen wurden $(( n + 1 ))." \
                                   "  [!] The backup declares ${decl_count} components, $(( n + 1 )) were read."
    rm -rf "$tmp"; return 1
  fi

  # Jede in SHA256SUMS aufgeführte Datei muss im Strom vorgekommen sein und
  # denselben Hash haben.
  while read -r want path; do
    [[ -n "$path" ]] || continue
    got="$(awk -v p="$path" '$2==p{print $1; exit}' "$tmp/computed")"
    if [[ -z "$got" ]]; then bad=$(( bad + 1 ))
      [[ "$quiet" == quiet ]] || msg "  [!] fehlt in der Sicherung: $path" "  [!] missing from the backup: $path"
    elif [[ "$got" != "$want" ]]; then bad=$(( bad + 1 ))
      [[ "$quiet" == quiet ]] || msg "  [!] Prüfsumme weicht ab: $path" "  [!] checksum mismatch: $path"
    fi
  done < "$tmp/SHA256SUMS"

  rm -rf "$tmp"
  (( bad == 0 )) || return 1
  [[ "$quiet" == quiet ]] || msg "[✓] ${n} Bestandteile geprüft." "[✓] ${n} components verified."
  return 0
}

# --- Wiederherstellen ---------------------------------------------------------
# Nullbereiche dürfen einen Thin-Datenträger nicht belegen: dd springt mit
# conv=sparse über vollständig leere Blöcke hinweg, statt sie zu schreiben.
# Auf einem frisch angelegten (und verworfenen) Thin-Volume bleibt der Bereich
# damit unbelegt.
pzb_write_sparse() {
  local target="${1:?}" bs="${PVE_DR_SPARSE_BS:-1M}"
  dd of="$target" bs="$bs" conv=sparse,fsync iflag=fullblock status=none
}
pzb_write_plain() {
  local target="${1:?}"
  dd of="$target" bs=4M conv=fsync iflag=fullblock status=none
}

pbdr_restore_plan() {
  local mf="${1:?}"
  PB_R_DISK="$(mf_rows "$mf" DISK | awk -F'\t' '{print $2; exit}')"
  PB_R_DISKSIZE="$(mf_rows "$mf" DISK | awk -F'\t' '{print $3; exit}')"
  PB_R_VG="$(mf_rows "$mf" VG | awk -F'\t' '{print $2; exit}')"
  PB_R_POOL="$(mf_rows "$mf" POOL | awk -F'\t' '{print $2; exit}')"
  PB_R_POOLSIZE="$(mf_rows "$mf" POOL | awk -F'\t' '{print $3; exit}')"
  PB_R_BOOT="$(mf_rows "$mf" BOOT | awk -F'\t' '{print $2; exit}')"
  PB_R_HOST="$(mf_meta "$mf" hostname)"
  PB_R_PVE="$(mf_meta "$mf" pve_version)"
  PB_R_CREATED="$(mf_meta "$mf" created)"
  [[ -n "$PB_R_DISK" && -n "$PB_R_VG" ]] || return 1
  return 0
}

pbdr_restore_show_plan() {
  local mf="${1:?}" target="${2:-}" role vg lv kind size alloc pool guest key member snap n=0 total=0
  echo "=========================================="
  M "  Wiederherstellungsplan" "  Restore plan"
  echo "=========================================="
  printf '  %-22s %s\n' "$(L 'Gesichert am:' 'Backed up:')"   "$PB_R_CREATED"
  printf '  %-22s %s\n' "$(L 'Ursprungssystem:' 'Source system:')" "${PB_R_HOST} (Proxmox VE ${PB_R_PVE})"
  printf '  %-22s %s\n' "$(L 'Ursprungsdisk:' 'Source disk:')" "${PB_R_DISK} ($(human_bytes "${PB_R_DISKSIZE:-0}"))"
  printf '  %-22s %s\n' "$(L 'Zieldisk:' 'Target disk:')"      "${target:-?}"
  printf '  %-22s %s\n' "$(L 'Startverfahren:' 'Boot method:')" "${PB_R_BOOT}"
  printf '  %-22s %s\n' "Volume-Group"                          "${PB_R_VG}"
  [[ -n "$PB_R_POOL" ]] && printf '  %-22s %s\n' "$(L 'Speicherpool:' 'Storage pool:')" "${PB_R_POOL} ($(human_bytes "${PB_R_POOLSIZE:-0}"))"
  echo
  M "  Wiederhergestellt werden:" "  Will be restored:"
  while IFS=$'\t' read -r _ role vg lv kind size alloc pool guest key member snap; do
    [[ -n "$lv" ]] || continue
    printf '    %-12s %-26s %-6s %s\n' "${guest:-host}" "${vg}/${lv}" "$kind" "$(human_bytes "${size:-0}")"
    n=$(( n + 1 )); total=$(( total + size ))
  done < <(mf_rows "$mf" VOL)
  echo
  printf '  %-22s %s\n' "$(L 'Datenträger gesamt:' 'Volumes in total:')" "$n ($(human_bytes "$total"))"
  local g t id st
  n=0; while IFS=$'\t' read -r _ t id st _ _; do n=$(( n + 1 )); done < <(mf_rows "$mf" GUEST)
  printf '  %-22s %s\n' "$(L 'Gäste:' 'Guests:')" "$n"
  echo
}

# --- Wiederherstellung ausführen ---------------------------------------------
PB_R_PREPARED=0; PB_R_TARGET=""; PB_R_TMP=""

pb_part_path() {                     # Disk + Nummer -> Partitionspfad
  local d="${1:?}" n="${2:?}"
  [[ "$d" =~ [0-9]$ ]] && printf '%sp%s' "$d" "$n" || printf '%s%s' "$d" "$n"
}

pbdr_restore_prepare_disk() {
  local mf="$PB_MF" target="$PB_R_TARGET" base pvnum pvdev vg pool poolsize
  local role lv kind size alloc guest key member snap ext

  (( PB_R_PREPARED )) && return 0
  set_status "$(status_msg "RESTORE: Lege Partitionen an..." "RESTORE: Creating partitions...")"

  # Startbereich zuerst: er enthält MBR-Bootcode und die GPT. Danach schreibt
  # sfdisk die Partitionstabelle verbindlich neu, ohne den Bootcode zu berühren.
  if [[ -s "$PB_R_TMP/gap.img" ]]; then
    dd if="$PB_R_TMP/gap.img" of="$target" bs=512 conv=fsync status=none || return 1
  fi
  [[ -s "$PB_R_TMP/table.sfdisk" ]] || { msg "[!] Partitionstabelle fehlt in der Sicherung." "[!] Partition table missing from the backup."; return 1; }
  timeout 120 sfdisk --force "$target" < "$PB_R_TMP/table.sfdisk" >/dev/null 2>&1 || {
    msg "[!] Partitionstabelle konnte nicht geschrieben werden." "[!] Could not write the partition table."; return 1; }
  timeout 60 partprobe "$target" >/dev/null 2>&1 || timeout 60 blockdev --rereadpt "$target" >/dev/null 2>&1 || true
  udevadm settle --timeout=30 >/dev/null 2>&1 || sleep 2

  pvnum="$(mf_rows "$mf" PVPART | awk -F'\t' '{print $3; exit}')"
  [[ "$pvnum" =~ ^[0-9]+$ ]] || { msg "[!] Die Sicherung nennt keine LVM-Partition." "[!] The backup does not name an LVM partition."; return 1; }
  pvdev="$(pb_part_path "$target" "$pvnum")"
  [[ -b "$pvdev" ]] || { msg "[!] Partition $pvdev wurde nicht angelegt." "[!] Partition $pvdev was not created."; return 1; }

  set_status "$(status_msg "RESTORE: Baue Speicherstruktur auf..." "RESTORE: Building the storage layout...")"
  vg="$PB_R_VG"
  timeout 120 pvcreate -ff -y "$pvdev" >/dev/null 2>&1 || { msg "[!] pvcreate fehlgeschlagen." "[!] pvcreate failed."; return 1; }
  ext="$(mf_rows "$mf" VG | awk -F'\t' '{print $5; exit}')"; [[ "$ext" =~ ^[0-9]+$ ]] || ext=4194304
  timeout 120 vgcreate -s "${ext}b" "$vg" "$pvdev" >/dev/null 2>&1 || { msg "[!] vgcreate fehlgeschlagen." "[!] vgcreate failed."; return 1; }

  # Klassische Volumes (Systemdatenträger) zuerst, dann der Speicherpool, dann
  # die Gast-Datenträger darin.
  while IFS=$'\t' read -r _ role _ lv kind size alloc pool guest key member snap; do
    [[ "$kind" == "classic" ]] || continue
    timeout 120 lvcreate -y -L "${size}b" -n "$lv" "$vg" >/dev/null 2>&1 || {
      msg "[!] Konnte $vg/$lv nicht anlegen." "[!] Could not create $vg/$lv."; return 1; }
  done < <(mf_rows "$mf" VOL)

  local swlv swsize swuuid
  read -r _ _ swlv swsize swuuid < <(mf_rows "$mf" SWAP | head -1) 2>/dev/null || true
  if [[ -n "${swlv:-}" && "${swsize:-0}" =~ ^[0-9]+$ ]] && (( swsize > 0 )); then
    if timeout 120 lvcreate -y -L "${swsize}b" -n "$swlv" "$vg" >/dev/null 2>&1; then
      if [[ -n "${swuuid:-}" ]]; then timeout 60 mkswap -U "$swuuid" "/dev/$vg/$swlv" >/dev/null 2>&1 || timeout 60 mkswap "/dev/$vg/$swlv" >/dev/null 2>&1 || true
      else timeout 60 mkswap "/dev/$vg/$swlv" >/dev/null 2>&1 || true; fi
    fi
  fi

  pool="$PB_R_POOL"; poolsize="$PB_R_POOLSIZE"
  if [[ -n "$pool" && "${poolsize:-0}" =~ ^[0-9]+$ ]] && (( poolsize > 0 )); then
    timeout 300 lvcreate -y --type thin-pool -L "${poolsize}b" -n "$pool" "$vg" >/dev/null 2>&1 || {
      msg "[!] Speicherpool konnte nicht angelegt werden." "[!] Could not create the storage pool."; return 1; }
  fi
  while IFS=$'\t' read -r _ role _ lv kind size alloc _ guest key member snap; do
    [[ "$kind" == "thin" ]] || continue
    timeout 120 lvcreate -y -V "${size}b" --thinpool "$pool" -n "$lv" "$vg" >/dev/null 2>&1 || {
      msg "[!] Konnte $vg/$lv nicht anlegen." "[!] Could not create $vg/$lv."; return 1; }
    # Frisch angelegte Thin-Volumes sind leer; blkdiscard stellt das auch dann
    # sicher, wenn der Pool Blöcke wiederverwendet.
    timeout 300 blkdiscard "/dev/$vg/$lv" >/dev/null 2>&1 || true
  done < <(mf_rows "$mf" VOL)

  PB_R_PREPARED=1
  return 0
}

pbdr_restore_apply_member() {
  local mf="$PB_MF" path="$PZB_R_PATH" target="$PB_R_TARGET"
  local n dev role vg lv kind size alloc pool guest key member snap

  case "$path" in
    manifest.tsv|manifest.json|hardware/*|logs/*)
        pzb_r_skip; return $? ;;
    disk/*.sfdisk)   pzb_r_member > "$PB_R_TMP/table.sfdisk"; return $? ;;
    disk/*.gap.img)  pzb_r_member > "$PB_R_TMP/gap.img";      return $? ;;
    config/*)
        pzb_r_member > "$PB_R_TMP/$(basename "$path")" || return 1
        chmod "${PZB_R_MODE:-0600}" "$PB_R_TMP/$(basename "$path")" 2>/dev/null || true
        return 0 ;;
    SHA256SUMS)      pzb_r_member > "$PB_R_TMP/SHA256SUMS";   return $? ;;
    parts/part-*.img)
        pbdr_restore_prepare_disk || return 1
        n="${path##*part-}"; n="${n%%.img}"
        dev="$(pb_part_path "$target" "$n")"
        [[ -b "$dev" ]] || { msg "[!] Zielpartition $dev fehlt." "[!] Target partition $dev is missing."; return 1; }
        set_status "$(status_msg "RESTORE: Schreibe Startbereich ($n)..." "RESTORE: Writing boot area ($n)...")"
        pzb_r_member | pzb_write_plain "$dev"; return "${PIPESTATUS[0]}" ;;
    volumes/vol_*.img)
        pbdr_restore_prepare_disk || return 1
        while IFS=$'\t' read -r _ role vg lv kind size alloc pool guest key member snap; do
          [[ "$member" == "$path" ]] || continue
          [[ -b "/dev/$vg/$lv" ]] || { msg "[!] Zielvolume /dev/$vg/$lv fehlt." "[!] Target volume /dev/$vg/$lv is missing."; return 1; }
          set_status "$(status_msg "RESTORE: Schreibe ${vg}/${lv}..." "RESTORE: Writing ${vg}/${lv}...")"
          if [[ "$kind" == "thin" ]]; then
            pzb_r_member | pzb_write_sparse "/dev/$vg/$lv"; return "${PIPESTATUS[0]}"
          else
            pzb_r_member | pzb_write_plain  "/dev/$vg/$lv"; return "${PIPESTATUS[0]}"
          fi
        done < <(mf_rows "$mf" VOL)
        msg "[!] Unbekannter Datenträger im Archiv: $path" "[!] Unknown volume in the archive: $path"
        return 1 ;;
    *)  pzb_r_skip; return $? ;;
  esac
}

# --- Startfähigkeit wiederherstellen ------------------------------------------
PB_R_ROOTMNT="/mnt/panzerbackup-restore"

pbdr_restore_umount_all() {
  local m
  for m in /sys/firmware/efi/efivars /run /sys /proc /dev/pts /dev boot/efi boot ""; do
    umount -lf "${PB_R_ROOTMNT}/${m}" >/dev/null 2>&1 || true
  done
  umount -lf "$PB_R_ROOTMNT" >/dev/null 2>&1 || true
  return 0
}

# Der wiederhergestellte Systemdatenträger bringt seine eigene /etc/fstab mit.
# Die Einhängepunkte werden daraus übernommen, statt sie zu erraten - die
# UUIDs sind durch die rohen Partitionsabbilder unverändert erhalten.
pbdr_restore_mount_system() {
  local mf="$PB_MF" vg="$PB_R_VG" rootlv dev mp fstype rest uuid
  rootlv="$(mf_rows "$mf" VOL | awk -F'\t' '$2=="host-root"{print $4; exit}')"
  [[ -n "$rootlv" ]] || return 1
  mkdir -p "$PB_R_ROOTMNT"
  mount "/dev/$vg/$rootlv" "$PB_R_ROOTMNT" 2>/dev/null || {
    msg "[!] Das wiederhergestellte System ließ sich nicht einhängen." \
        "[!] The restored system could not be mounted."; return 1; }

  if [[ -r "$PB_R_ROOTMNT/etc/fstab" ]]; then
    while read -r dev mp fstype rest; do
      [[ "${dev:0:1}" == "#" || -z "$mp" ]] && continue
      case "$mp" in /boot|/boot/efi) ;; *) continue ;; esac
      case "$dev" in
        UUID=*)     uuid="${dev#UUID=}"; dev="$(blkid -U "$uuid" 2>/dev/null || true)" ;;
        PARTUUID=*) uuid="${dev#PARTUUID=}"; dev="$(blkid -t "PARTUUID=$uuid" -o device 2>/dev/null | head -1 || true)" ;;
      esac
      [[ -b "${dev:-}" ]] || continue
      mkdir -p "${PB_R_ROOTMNT}${mp}"
      mount "$dev" "${PB_R_ROOTMNT}${mp}" 2>/dev/null || \
        msg "[!] ${mp} konnte nicht eingehängt werden." "[!] Could not mount ${mp}."
    done < "$PB_R_ROOTMNT/etc/fstab"
  fi

  mount --bind /dev     "${PB_R_ROOTMNT}/dev"  2>/dev/null || true
  mount --bind /dev/pts "${PB_R_ROOTMNT}/dev/pts" 2>/dev/null || true
  mount -t proc  proc   "${PB_R_ROOTMNT}/proc" 2>/dev/null || true
  mount -t sysfs sysfs  "${PB_R_ROOTMNT}/sys"  2>/dev/null || true
  mount -t tmpfs tmpfs  "${PB_R_ROOTMNT}/run"  2>/dev/null || true
  if [[ -d /sys/firmware/efi/efivars ]]; then
    mkdir -p "${PB_R_ROOTMNT}/sys/firmware/efi/efivars"
    mount --bind /sys/firmware/efi/efivars "${PB_R_ROOTMNT}/sys/firmware/efi/efivars" 2>/dev/null || true
  fi
  return 0
}

# Es wird ausschließlich das Verfahren angewandt, das im Manifest steht - kein
# pauschales grub-install, das eine proxmox-boot-tool-Installation zerstören würde.
pbdr_restore_boot() {
  local method="$PB_R_BOOT" target="$PB_R_TARGET" rc=0 out
  set_status "$(status_msg "RESTORE: Stelle Startfähigkeit her..." "RESTORE: Restoring bootability...")"
  msg "[*] Startverfahren laut Sicherung: ${method}" "[*] Boot method from the backup: ${method}"

  case "$method" in
    proxmox-boot-tool*)
      out="$(chroot "$PB_R_ROOTMNT" /bin/bash -c 'proxmox-boot-tool refresh' 2>&1)" || rc=$?
      if (( rc != 0 )); then
        msg "[!] proxmox-boot-tool refresh meldete einen Fehler; versuche Neuinitialisierung." \
            "[!] proxmox-boot-tool refresh reported an error; trying re-initialisation."
        chroot "$PB_R_ROOTMNT" /bin/bash -c '
          while read -r u; do [ -n "$u" ] && proxmox-boot-tool init "/dev/disk/by-uuid/$u" || true
          done < /etc/kernel/proxmox-boot-uuids' >/dev/null 2>&1 || rc=1
      else rc=0; fi ;;
    "UEFI + systemd-boot")
      chroot "$PB_R_ROOTMNT" /bin/bash -c 'bootctl install' >/dev/null 2>&1 || rc=$? ;;
    UEFI*)
      chroot "$PB_R_ROOTMNT" /bin/bash -c \
        'grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=proxmox --recheck && update-grub' \
        >/dev/null 2>&1 || rc=$? ;;
    "Legacy BIOS"*)
      chroot "$PB_R_ROOTMNT" /bin/bash -c \
        "grub-install --target=i386-pc --recheck '$target' && update-grub" >/dev/null 2>&1 || rc=$? ;;
    *)
      msg "[!] Unbekanntes Startverfahren – die Startfähigkeit wurde nicht angepasst." \
          "[!] Unknown boot method – bootability was not adjusted."
      return 1 ;;
  esac

  if [[ "${PVE_DR_REBUILD_INITRAMFS:-auto}" != "no" ]]; then
    chroot "$PB_R_ROOTMNT" /bin/bash -c 'update-initramfs -u -k all' >/dev/null 2>&1 || \
      msg "[!] initramfs konnte nicht neu erzeugt werden." "[!] Could not rebuild the initramfs."
  fi
  (( rc == 0 )) || msg "[!] Die Startvorbereitung meldete einen Fehler (RC=$rc)." \
                       "[!] Boot preparation reported an error (RC=$rc)."
  return "$rc"
}

# Version 1 sichert die Snapshot-Historie nicht mit. Damit im wiederhergestellten
# System keine Verweise auf fehlende Sicherungspunkte zurückbleiben, räumt
# Proxmox sie beim ersten Start mit seinen eigenen Mitteln auf - kein Eingriff
# in die Konfigurationsdatenbank von außen.
pbdr_restore_install_snapshot_cleanup() {
  local d="$PB_R_ROOTMNT/usr/local/sbin" u="$PB_R_ROOTMNT/etc/systemd/system"
  mkdir -p "$d" "$u" || return 1
  cat > "$d/panzerbackup-firstboot.sh" <<'FBEOF'
#!/bin/bash
# Von Panzerbackup beim Wiederherstellen eingerichtet. Entfernt einmalig die
# Verweise auf Sicherungspunkte, deren Daten nicht Teil der Wiederherstellung
# waren, und deaktiviert sich danach selbst.
set -u
log() { logger -t panzerbackup-firstboot "$*"; echo "$*"; }
for i in $(qm list 2>/dev/null | awk 'NR>1{print $1}'); do
  for s in $(qm listsnapshot "$i" 2>/dev/null | awk '{print $2}' | grep -v '^current$' || true); do
    log "entferne Sicherungspunkt $s von VM $i"
    qm delsnapshot "$i" "$s" --force 1 >/dev/null 2>&1 || log "VM $i: $s nicht entfernbar"
  done
done
for i in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
  for s in $(pct listsnapshot "$i" 2>/dev/null | awk '{print $2}' | grep -v '^current$' || true); do
    log "entferne Sicherungspunkt $s von CT $i"
    pct delsnapshot "$i" "$s" --force 1 >/dev/null 2>&1 || log "CT $i: $s nicht entfernbar"
  done
done
systemctl disable panzerbackup-firstboot.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/panzerbackup-firstboot.service
rm -f /usr/local/sbin/panzerbackup-firstboot.sh
exit 0
FBEOF
  chmod 0700 "$d/panzerbackup-firstboot.sh"
  cat > "$u/panzerbackup-firstboot.service" <<'FBUEOF'
[Unit]
Description=Panzerbackup: Aufraeumen nach der Wiederherstellung
After=pve-guests.service pvedaemon.service
Wants=pvedaemon.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/panzerbackup-firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
FBUEOF
  mkdir -p "$u/multi-user.target.wants"
  ln -sfn ../panzerbackup-firstboot.service "$u/multi-user.target.wants/panzerbackup-firstboot.service"
  return 0
}

pbdr_restore_validate() {
  local mf="$PB_MF" vg="$PB_R_VG" ok=1 n=0 miss=0 role lv kind size
  msg "" ""
  echo "=========================================="
  M "  Prüfung nach der Wiederherstellung" "  Post-restore check"
  echo "=========================================="
  while IFS=$'\t' read -r _ role _ lv kind size _ _ _ _ _ _; do
    [[ -n "$lv" ]] || continue
    n=$(( n + 1 ))
    if [[ -b "/dev/$vg/$lv" ]]; then :; else miss=$(( miss + 1 )); ok=0
      msg "  [!] fehlt: ${vg}/${lv}" "  [!] missing: ${vg}/${lv}"; fi
  done < <(mf_rows "$mf" VOL)
  printf '  %-30s %s\n' "$(L 'Datenträger wiederhergestellt:' 'Volumes restored:')" "$(( n - miss )) / $n"
  if [[ -r "$PB_R_ROOTMNT/etc/pve" || -d "$PB_R_ROOTMNT/var/lib/pve-cluster" ]]; then
    printf '  %-30s %s\n' "Proxmox-Konfiguration:" "$(L 'vorhanden' 'present')"
  else
    printf '  %-30s %s\n' "Proxmox-Konfiguration:" "$(L 'NICHT gefunden' 'NOT found')"; ok=0
  fi
  local g t id st
  n=0; while IFS=$'\t' read -r _ t id st _ _; do n=$(( n + 1 )); done < <(mf_rows "$mf" GUEST)
  printf '  %-30s %s\n' "$(L 'Gäste laut Sicherung:' 'Guests per backup:')" "$n"
  echo
  (( ok )) || return 1
  return 0
}

# --- Gesamtablauf der Wiederherstellung ---------------------------------------
restore_pve_dr() {
  local file="${1:?}" target="" rc=0 tsize

  need_cmd zstd; need_cmd sfdisk; need_cmd lvcreate; need_cmd vgcreate; need_cmd pvcreate
  need_cmd dd; need_cmd sha256sum

  pzb_prepare_read "$file" || return 1
  msg "[*] Lese den Wiederherstellungsplan ..." "[*] Reading the restore plan ..."
  pzb_read_manifest "$file" || {
    die "Die Sicherungsdatei konnte nicht gelesen werden. Ist die Passphrase richtig?" \
        "The backup file could not be read. Is the passphrase correct?"; }
  pbdr_restore_plan "$PB_MF" || die "Das Manifest ist unvollständig." "The manifest is incomplete."

  if [[ -n "${TARGET_DISK:-}" ]]; then
    target="$TARGET_DISK"; [[ -b "$target" ]] || die "Ziel-Disk nicht gefunden: $target" "Target disk not found: $target"
  elif [[ "${RESTORE_DRY_RUN:-}" == "--dry-run" ]] && ! have_tty; then
    target=""
  else
    target="$(select_target_disk "${RUNNING_SYSTEM_DISK:-}")"
  fi
  if [[ -n "$target" ]]; then
    [[ -b "$target" ]] || die "Keine gültige Zieldisk gewählt." "No valid target disk selected."
    disk_is_protected "$target" && die "Die Zieldisk ist geschützt: $target" "The target disk is protected: $target"
  elif [[ "${RESTORE_DRY_RUN:-}" != "--dry-run" ]]; then
    die "Keine gültige Zieldisk gewählt." "No valid target disk selected."
  fi
  PB_R_TARGET="$target"

  tsize="$( [[ -n "$target" ]] && blockdev --getsize64 "$target" 2>/dev/null || echo 0 )"
  if [[ -n "$target" ]] && (( tsize < PB_R_DISKSIZE )); then
    die "Die Zieldisk ist zu klein: $(human_bytes "$tsize") vorhanden, $(human_bytes "$PB_R_DISKSIZE") werden benötigt. Es wurde nichts verändert." \
        "The target disk is too small: $(human_bytes "$tsize") available, $(human_bytes "$PB_R_DISKSIZE") required. Nothing was changed."
  fi

  { clear 2>/dev/null || printf '\033c'; } || true
  pbdr_restore_show_plan "$PB_MF" "$target"
  if [[ -n "$target" ]] && (( tsize > PB_R_DISKSIZE )); then
    msg "  Hinweis: Die Zieldisk ist größer als die ursprüngliche. Der zusätzliche" \
        "  Note: the target disk is larger than the original. The extra space"
    msg "  Platz bleibt zunächst ungenutzt und kann später vergrößert werden." \
        "  stays unused for now and can be grown later."
    echo
  fi

  if [[ "${RESTORE_DRY_RUN:-}" == "--dry-run" ]]; then
    msg "[DRY-RUN] Es wurde nichts geschrieben." "[DRY-RUN] Nothing was written."
    rm -f "$PB_MF"; return 0
  fi

  M "⚠️  ALLE DATEN auf $target werden überschrieben!" "⚠️  ALL DATA on $target will be overwritten!"
  ASK "Wiederherstellung wirklich starten?" "Really start the restore?" || {
    msg "Abbruch." "Aborted."; rm -f "$PB_MF"; return 3; }

  clear_status_for_new_run; mark_run_started
  PB_R_TMP="${RUN_DIR}/pzb_restore.$$"; rm -rf "$PB_R_TMP"; ( umask 077; mkdir -p "$PB_R_TMP" )
  PB_R_PREPARED=0
  trap 'pbdr_restore_umount_all; rm -rf "$PB_R_TMP"; clear_passphrase_file' EXIT INT TERM HUP

  set_status "$(status_msg "RESTORE: Läuft..." "RESTORE: Running...")"
  {
    pzb_r_open || exit 1
    while :; do
      pzb_r_next; r=$?
      (( r == 2 )) && break
      (( r == 0 )) || exit 1
      pbdr_restore_apply_member || exit 1
    done
  } < <(pzb_decode "$file") || rc=$?

  if (( rc != 0 )); then
    set_status "$(status_msg "FEHLER: Wiederherstellung abgebrochen" "ERROR: restore aborted")"
    msg "❌ Die Wiederherstellung wurde abgebrochen. Das Ziel ist unvollständig." \
        "❌ The restore was aborted. The target is incomplete."
    pbdr_restore_umount_all; rm -rf "$PB_R_TMP"; clear_passphrase_file; trap - EXIT INT TERM HUP
    return 1
  fi

  sync
  if pbdr_restore_mount_system; then
    pbdr_restore_boot || true
    pbdr_restore_install_snapshot_cleanup || \
      msg "[!] Die Nachbereitung konnte nicht eingerichtet werden." "[!] Could not set up the post-restore step."
    pbdr_restore_validate || rc=1
    sync; pbdr_restore_umount_all
  else
    msg "[!] Das wiederhergestellte System ließ sich nicht prüfen." "[!] The restored system could not be checked."
    rc=1
  fi

  rm -rf "$PB_R_TMP"; rm -f "$PB_MF"; clear_passphrase_file; trap - EXIT INT TERM HUP

  if (( rc == 0 )); then
    set_status "$(status_msg "RESTORE: Erfolgreich abgeschlossen" "RESTORE: Completed successfully")"
    echo
    M "✅ Die Wiederherstellung ist abgeschlossen." "✅ The restore is complete."
    M "   Beim ersten Start räumt Proxmox nicht mitgesicherte Sicherungspunkte auf." \
      "   On first boot Proxmox cleans up restore points that were not backed up."
    M "   Jetzt das Live-Medium entfernen und von ${target} starten." \
      "   Now remove the live medium and boot from ${target}."
  else
    set_status "$(status_msg "RESTORE: Mit Warnungen abgeschlossen" "RESTORE: Completed with warnings")"
    M "⚠️  Die Wiederherstellung ist durchgelaufen, die Prüfung meldet aber Auffälligkeiten." \
      "⚠️  The restore finished, but the check reports problems."
  fi
  return "$rc"
}

# --- Formaterkennung ----------------------------------------------------------
# Der Benutzer wählt nur eine Sicherung; das Format wird an der Datei erkannt.
restore_detect_format() {
  local f="${1:?}"
  [[ -f "$f" ]] || { printf 'unknown'; return 1; }
  case "$f" in
    *.pzb) printf 'pve-dr'; return 0 ;;
    *.img|*.img.zst|*.img.gpg|*.img.zst.gpg) printf 'raw'; return 0 ;;
  esac
  printf 'unknown'; return 1
}

list_candidate_backups_all() {
  local dir="${1:?}"
  ls -1t "$dir"/panzer_*.pzb \
         "$dir"/panzer_*.img.zst.gpg "$dir"/panzer_*.img.gpg \
         "$dir"/panzer_*.img.zst "$dir"/panzer_*.img 2>/dev/null || true
}

select_backup_any() {
  local dir="${1:?}" backups=() i=1 b kind label
  mapfile -t backups < <(list_candidate_backups_all "$dir")
  (( ${#backups[@]} > 0 )) || die "Keine Sicherungen gefunden" "No backups found"
  msg "[*] Verfügbare Sicherungen:" "[*] Available backups:" >&2
  for b in "${backups[@]}"; do
    kind="$(restore_detect_format "$b" || true)"
    case "$kind" in
      pve-dr) label="$(L 'Proxmox Disaster-Recovery' 'Proxmox disaster recovery')" ;;
      raw)    label="$(L 'Klassisches RAW-Abbild'    'Classic RAW image')" ;;
      *)      label="?" ;;
    esac
    printf '  %d) %s\n      %s   %s   %s\n' "$i" "$(basename "$b")" "$label" \
      "$(date -r "$b" '+%d.%m.%Y %H:%M' 2>/dev/null || echo '')" \
      "$(du -h "$b" 2>/dev/null | cut -f1)" >&2
    ((i++))
  done
  echo >&2
  local choice
  if [[ "$LANG_CHOICE" == "de" ]]; then read -r -p "Sicherung auswählen (1-${#backups[@]}): " choice </dev/tty >/dev/tty
  else read -r -p "Select backup (1-${#backups[@]}): " choice </dev/tty >/dev/tty; fi
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#backups[@]} )) || die "Ungültige Auswahl" "Invalid selection"
  printf '%s' "${backups[$((choice-1))]}"
}

find_latest_any_format() {
  local dir="${1:?}" t
  if [[ -L "$dir/LATEST_OK" ]]; then
    t="$(readlink -f "$dir/LATEST_OK" 2>/dev/null || true)"
    [[ -f "$t" ]] && { printf '%s' "$t"; return 0; }
  fi
  list_candidate_backups_all "$dir" | head -n1
}

# --- Einstieg: ein Menüpunkt, zwei Engines ------------------------------------
restore_dispatch() {
  local cand kind
  if [[ "${SELECT_BACKUP:-}" == "true" ]]; then
    cand="$(select_backup_any "$BACKUP_DIR")"
  else
    cand="$(find_latest_any_format "$BACKUP_DIR")"
  fi
  [[ -n "${cand:-}" && -f "$cand" ]] || die "Keine gültige Sicherung gefunden" "No valid backup found"
  kind="$(restore_detect_format "$cand" || true)"
  msg "[✓] Gewählt: $(basename "$cand")" "[✓] Selected: $(basename "$cand")"
  case "$kind" in
    pve-dr) restore_pve_dr "$cand" ;;
    raw)    RESTORE_CANDIDATE_OVERRIDE="$cand"; do_restore ;;
    *)      die "Unbekanntes Sicherungsformat: $(basename "$cand")" "Unknown backup format: $(basename "$cand")" ;;
  esac
}

# --- Prüfen: ein Menüpunkt, zwei Engines --------------------------------------
verify_dispatch() {
  local cand kind rc=0
  if [[ "${SELECT_BACKUP:-}" == "true" ]]; then
    cand="$(select_backup_any "$BACKUP_DIR")"
  else
    cand="$(find_latest_any_format "$BACKUP_DIR")"
  fi
  [[ -n "${cand:-}" && -f "$cand" ]] || die "Keine Sicherung gefunden" "No backup found"
  kind="$(restore_detect_format "$cand" || true)"
  msg "=== $(date) | Prüfe $(basename "$cand") ===" "=== $(date) | Verifying $(basename "$cand") ==="
  case "$kind" in
    raw)
      ( cd "$BACKUP_DIR" && sha256sum -c "$(basename "$cand").sha256" ) || rc=1 ;;
    pve-dr)
      if [[ -f "${cand}.sha256" ]]; then
        msg "[*] Prüfe die Datei als Ganzes ..." "[*] Checking the file as a whole ..."
        ( cd "$BACKUP_DIR" && sha256sum -c "$(basename "$cand").sha256" >/dev/null ) || {
          msg "❌ Die Datei stimmt nicht mit ihrer Prüfsumme überein." "❌ The file does not match its checksum."; return 1; }
      fi
      pzb_prepare_read "$cand" || return 1
      msg "[*] Prüfe jeden Bestandteil ..." "[*] Checking every component ..."
      pzb_verify_file "$cand" || rc=1
      clear_passphrase_file ;;
    *) die "Unbekanntes Format" "Unknown format" ;;
  esac
  if (( rc == 0 )); then
    echo
    M "✅ Die Sicherung ist strukturell vollständig und byteweise unversehrt." \
      "✅ The backup is structurally complete and byte-for-byte intact."
    M "   Ob das wiederhergestellte System startet, bestätigt erst ein Restore-Test." \
      "   Whether the restored system boots is only confirmed by a restore test."
  else
    M "❌ Die Prüfung ist fehlgeschlagen. Diese Sicherung ist nicht verlässlich." \
      "❌ The check failed. This backup is not reliable."
  fi
  return "$rc"
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

VERSION="3.0.1"
set -E
trap 'rc=$?; if [[ "${LANG_CHOICE:-de}" == "de" ]]; then set_status "FEHLER: Backup abgebrochen (RC=$rc)"; else set_status "ERROR: Backup aborted (RC=$rc)"; fi; echo "ERROR (Backup Worker) line $LINENO: $BASH_COMMAND (RC=$rc)"; exit $rc' ERR

export LC_ALL=C
: "${PATH:=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

set_status() { echo "$1" > "$STATUS_FILE"; }
msg() { if [[ "${LANG_CHOICE:-de}" == "de" ]]; then echo "$1"; else echo "$2"; fi; }
status_msg() { if [[ "${LANG_CHOICE:-de}" == "de" ]]; then echo "$1"; else echo "$2"; fi; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
clear_passphrase_file() { rm -f -- "${PASSPHRASE_FILE:-}" 2>/dev/null || true; }

ACTIVE_CHILD_PID=""
ABORT_REQUESTED=false

kill_descendants_worker() {
  local parent="${1:?}" sig="${2:?}" child
  while read -r child; do
    [[ -n "$child" ]] || continue
    kill_descendants_worker "$child" "$sig"
    kill "-$sig" "$child" 2>/dev/null || true
  done < <(pgrep -P "$parent" 2>/dev/null || true)
}

stop_active_child() {
  local sig="${1:?}"
  [[ -n "${ACTIVE_CHILD_PID:-}" ]] || return 0
  kill_descendants_worker "$ACTIVE_CHILD_PID" "$sig"
  kill "-$sig" "$ACTIVE_CHILD_PID" 2>/dev/null || true
}

run_active() {
  "$@" &
  ACTIVE_CHILD_PID=$!
  set +e
  wait "$ACTIVE_CHILD_PID"
  local rc=$?
  set -e
  ACTIVE_CHILD_PID=""
  return "$rc"
}

abort_worker() {
  local sig="${1:-TERM}" rc=143
  [[ "$sig" == "INT" ]] && rc=130
  trap - INT TERM HUP ERR
  ABORT_REQUESTED=true
  set_status "$(status_msg "GESTOPPT: Manuell abgebrochen" "STOPPED: Aborted manually")"
  msg "[!] Abbruchsignal empfangen - beende aktive Backup-Prozesse ..." \
      "[!] Abort signal received - stopping active backup processes ..."
  stop_active_child TERM
  sleep 1
  stop_active_child KILL
  clear_passphrase_file
  rm -f "$PID_FILE"
  exit "$rc"
}

trap 'abort_worker INT' INT
trap 'abort_worker TERM' TERM
trap 'abort_worker HUP' HUP

run_inhibited() {
  local why="${1:?}"; shift
  if has_cmd systemd-inhibit; then
    systemd-inhibit --what=handle-lid-switch:sleep:idle --why="$why" "$@"
  else
    "$@"
  fi
}

post_action_worker() {
  case "${POST_ACTION:-none}" in
    reboot)
      set_status "$(status_msg "BACKUP: Erfolgreich abgeschlossen - Neustart in 5 Sekunden ..." "BACKUP: Completed successfully - rebooting in 5 seconds ...")"
      msg "[*] Neustart in 5 Sekunden ..." "[*] Rebooting in 5 seconds ..."
      sleep 5
      systemctl reboot
      ;;
    shutdown)
      set_status "$(status_msg "BACKUP: Erfolgreich abgeschlossen - Shutdown in 5 Sekunden ..." "BACKUP: Completed successfully - shutting down in 5 seconds ...")"
      msg "[*] Shutdown in 5 Sekunden ..." "[*] Shutting down in 5 seconds ..."
      sleep 5
      systemctl poweroff
      ;;
    none|"")
      ;;
    *)
      msg "[!] Unbekannte Post-Action ignoriert: ${POST_ACTION}" "[!] Unknown post-action ignored: ${POST_ACTION}"
      ;;
  esac
}

remove_backups_with_metadata_worker() {
  local old old_base old_sfdisk latest_target="" latest_base="" latest_deleted=0
  local -a files=()

  if [[ -L "${BACKUP_DIR}/LATEST_OK" ]]; then
    latest_target="$(readlink -f "${BACKUP_DIR}/LATEST_OK" 2>/dev/null || true)"
    if [[ -n "$latest_target" ]]; then
      latest_base="$(basename "$latest_target")"
    else
      latest_deleted=1
    fi
  fi

  for old in "$@"; do
    [[ -f "$old" ]] || continue
    old_base="$(basename "$old")"
    old_sfdisk="${old_base%.img*}.sfdisk"
    files+=("$old" "${old}.sha256" "${BACKUP_DIR}/${old_sfdisk}")
    [[ "$old_base" == "$latest_base" ]] && latest_deleted=1
  done

  (( ${#files[@]} > 0 )) && rm -f -- "${files[@]}"
  if (( latest_deleted )); then
    rm -f "${BACKUP_DIR}/LATEST_OK" "${BACKUP_DIR}/LATEST_OK.sha256" "${BACKUP_DIR}/LATEST_OK.sfdisk"
  fi
}

# The QEMU guest agent has no freeze timeout of its own: a guest stays frozen
# until somebody calls thaw. If this worker is killed (SIGKILL, host reboot,
# closed console) the guests would stay frozen forever. So arm a watchdog that
# thaws unconditionally, in its own session (setsid) so that a process-group
# kill aimed at the worker cannot take it down with it.
arm_quiesce_watchdog() {
  local max="$1" frozen="$2" suspended="$3" cts="$4"
  [[ -n "${frozen}${suspended}${cts}" ]] || return 0

  setsid nohup bash -c '
    echo $$ > "$5" 2>/dev/null || true
    sleep "$1"
    for vm in $2; do qm agent "$vm" fsfreeze-thaw >/dev/null 2>&1 || true; done
    for vm in $3; do qm resume "$vm"            >/dev/null 2>&1 || true; done
    for ct in $4; do pct unfreeze "$ct"         >/dev/null 2>&1 || true; done
    command -v logger >/dev/null 2>&1 && \
      logger -t panzerbackup "quiesce watchdog: released freeze after ${1}s"
  ' _ "$max" "$frozen" "$suspended" "$cts" "$QUIESCE_WATCHDOG_PID_FILE" \
    >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

disarm_quiesce_watchdog() {
  local wpid
  [[ -f "$QUIESCE_WATCHDOG_PID_FILE" ]] || return 0
  wpid="$(cat "$QUIESCE_WATCHDOG_PID_FILE" 2>/dev/null || true)"
  if [[ "$wpid" =~ ^[0-9]+$ ]]; then
    kill "$wpid" >/dev/null 2>&1 || true
  fi
  rm -f "$QUIESCE_WATCHDOG_PID_FILE"
}

pve_quiesce_start() {
  FROZEN_QM=(); SUSPENDED_QM=(); RUN_CT=(); RUN_QM=()

  if [[ "${PVE_QUIESCE_MODE:-off}" != "freeze" ]]; then
    if has_cmd qm || has_cmd pct; then
      msg "[*] Proxmox erkannt – Quiesce ist aus, das Abbild wird crash-konsistent." \
          "[*] Proxmox detected – quiesce is off, the image will be crash-consistent."
      msg "    Gastkonsistenz liefert vzdump/PBS (~1 s Freeze je VM). Erzwingen: --quiesce" \
          "    Use vzdump/PBS for guest consistency (~1 s freeze per VM). Force with: --quiesce"
    fi
    return 0
  fi

  if ! has_cmd qm && ! has_cmd pct; then return 0; fi
  set_status "$(status_msg "BACKUP: Proxmox VMs/CTs werden pausiert..." "BACKUP: Pausing Proxmox VMs/CTs...")"
  msg "[*] Proxmox erkannt – beginne Quiesce" "[*] Proxmox detected – starting quiesce"
  msg "    ! Freeze wird nach ${PVE_QUIESCE_MAX_SEC}s zwangsweise geloest – alles danach" \
      "    ! the freeze is released after ${PVE_QUIESCE_MAX_SEC}s no matter what – anything"
  msg "    ! kopierte ist crash-konsistent. Ein voller dd-Lauf dauert laenger." \
      "    ! copied after that is crash-consistent. A full dd run takes longer."

  if has_cmd qm; then
    mapfile -t RUN_QM < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}')
    for vm in "${RUN_QM[@]:-}"; do
      [[ -n "$vm" ]] || continue
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
      [[ -n "$ct" ]] || continue
      msg "  - CT $ct: freeze" "  - CT $ct: freeze"
      pct freeze "$ct" >/dev/null 2>&1 || true
    done
  fi

  arm_quiesce_watchdog "$PVE_QUIESCE_MAX_SEC" \
    "${FROZEN_QM[*]:-}" "${SUSPENDED_QM[*]:-}" "${RUN_CT[*]:-}"
  trap 'pve_quiesce_end' EXIT
}

pve_quiesce_end() {
  disarm_quiesce_watchdog
  set_status "$(status_msg "BACKUP: VMs/CTs werden fortgesetzt..." "BACKUP: Resuming VMs/CTs...")"
  if has_cmd qm; then
    for vm in "${FROZEN_QM[@]:-}"; do
      [[ -n "$vm" ]] || continue
      msg "  - VM $vm: fsfreeze-thaw" "  - VM $vm: fsfreeze-thaw"
      qm agent "$vm" fsfreeze-thaw >/dev/null 2>&1 || true
    done
    for vm in "${SUSPENDED_QM[@]:-}"; do
      [[ -n "$vm" ]] || continue
      msg "  - VM $vm: resume" "  - VM $vm: resume"
      qm resume "$vm" >/dev/null 2>&1 || true
    done
  fi
  if has_cmd pct; then
    for ct in "${RUN_CT[@]:-}"; do
      [[ -n "$ct" ]] || continue
      msg "  - CT $ct: unfreeze" "  - CT $ct: unfreeze"
      pct unfreeze "$ct" >/dev/null 2>&1 || true
    done
  fi
  if [[ "${ABORT_REQUESTED:-false}" == "true" ]]; then
    set_status "$(status_msg "GESTOPPT: Manuell abgebrochen" "STOPPED: Aborted manually")"
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
    if run_active run_inhibited "Panzerbackup läuft / Panzerbackup running" \
      bash -c '
        set -o pipefail
        dd if="$1" bs=64M status=progress \
        | zstd -T0 -"$2" -q \
        | gpg --batch --yes --symmetric --cipher-algo AES256 \
              --pinentry-mode loopback --passphrase-file "$5" \
        | tee "$3" \
        | sha256sum -b \
        | awk -v n="$6" "{print \$1 \"  \" n}" > "$4"
      ' pb-stream "$DISK" "$ZSTD_LEVEL" "$TEMP_FILE" "$TEMP_SHA" \
        "$PASSPHRASE_FILE" "$(basename "$FINAL_FILE")"; then
      :
    else
      rc=$?
      set_status "$(status_msg "FEHLER: Backup-Stream fehlgeschlagen (RC=$rc)" "ERROR: Backup stream failed (RC=$rc)")"
      msg "❌ Backup fehlgeschlagen: Schreib-/Stream-Fehler (RC=$rc)" "❌ Backup failed: write/stream error (RC=$rc)"
      clear_passphrase_file
      rm -f "$TEMP_FILE" "$TEMP_SHA" "${BACKUP_DIR}/${IMG_PREFIX}.sfdisk" "$PID_FILE"
      exit "$rc"
    fi
  elif [[ "$USE_COMPRESS" == "true" ]]; then
    msg "[*] dd | zstd | tee | sha256sum …" "[*] dd | zstd | tee | sha256sum …"
    set_status "$(status_msg "BACKUP: dd | zstd läuft..." "BACKUP: dd | zstd running...")"
    if run_active run_inhibited "Panzerbackup läuft / Panzerbackup running" \
      bash -c '
        set -o pipefail
        dd if="$1" bs=64M status=progress \
        | zstd -T0 -"$2" -q \
        | tee "$3" \
        | sha256sum -b \
        | awk -v n="$5" "{print \$1 \"  \" n}" > "$4"
      ' pb-stream "$DISK" "$ZSTD_LEVEL" "$TEMP_FILE" "$TEMP_SHA" \
        "$(basename "$FINAL_FILE")"; then
      :
    else
      rc=$?
      set_status "$(status_msg "FEHLER: Backup-Stream fehlgeschlagen (RC=$rc)" "ERROR: Backup stream failed (RC=$rc)")"
      msg "❌ Backup fehlgeschlagen: Schreib-/Stream-Fehler (RC=$rc)" "❌ Backup failed: write/stream error (RC=$rc)"
      clear_passphrase_file
      rm -f "$TEMP_FILE" "$TEMP_SHA" "${BACKUP_DIR}/${IMG_PREFIX}.sfdisk" "$PID_FILE"
      exit "$rc"
    fi
  else
    die "Interner Fehler: Kompression ist deaktiviert." "Internal error: compression is disabled."
  fi
  set +o pipefail
  clear_passphrase_file

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
    clear_passphrase_file
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
    done
    remove_backups_with_metadata_worker "${ALL[@]:$KEEP}"
  fi

  echo "=========================================="
  echo "Backup Worker Ende: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  rm -f "$PID_FILE"

  post_action_worker
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
    PASSPHRASE_FILE="$PASSPHRASE_FILE" ZSTD_LEVEL="$ZSTD_LEVEL" \
    POST_ACTION="$POST_ACTION" \
    STATUS_FILE="$STATUS_FILE" PID_FILE="$PID_FILE" \
    LOG_FILE="$LOG_FILE_DEFAULT" KEEP="$KEEP" \
    PVE_QUIESCE_MODE="$PVE_QUIESCE_MODE" \
    PVE_QUIESCE_MAX_SEC="$PVE_QUIESCE_MAX_SEC" \
    QUIESCE_WATCHDOG_PID_FILE="$QUIESCE_WATCHDOG_PID_FILE" \
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
  if ! acquire_start_lock; then
    if is_running; then
      msg "Ein Backup läuft bereits!" "A backup is already running!"
      msg "Aktueller Status: $(get_status)" "Current status: $(get_status)"
      return 1
    fi
    die "Backup-Start ist bereits gesperrt. Falls kein Backup läuft: sudo rm -f '$START_LOCK_PID_FILE'; sudo rmdir '$START_LOCK_DIR'" \
        "Backup startup is already locked. If no backup is running: sudo rm -f '$START_LOCK_PID_FILE'; sudo rmdir '$START_LOCK_DIR'"
  fi
  trap 'release_start_lock' EXIT

  if is_running; then
    release_start_lock
    trap - EXIT
    msg "Ein Backup läuft bereits!" "A backup is already running!"
    msg "Aktueller Status: $(get_status)" "Current status: $(get_status)"
    return 1
  fi

  need_cmd dd; need_cmd sha256sum; need_cmd sfdisk; need_cmd blockdev; need_cmd df
  ensure_zstd_if_needed "$COMPRESS_MODE"
  clear_passphrase_file

  local default_name backup_name
  default_name="$(hostname -s 2>/dev/null || echo 'system')"
  backup_name="$(prompt_backup_name "$default_name")"
  IMG_PREFIX="panzer_${backup_name}_${DATE}"

  msg "→ Backup-Name: $backup_name" "→ Backup name: $backup_name"

  USE_COMPRESS="true"

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

  if [[ "$ENCRYPT_MODE" == "gpg" ]]; then
    write_passphrase_file "$ENCRYPT_PASSPHRASE" || \
      die "Passphrase konnte nicht sicher an den Worker übergeben werden ($PASSPHRASE_FILE)" \
          "Could not hand the passphrase to the worker securely ($PASSPHRASE_FILE)"
  fi
  ENCRYPT_PASSPHRASE=""

  do_backup_background
  release_start_lock
  trap - EXIT

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
  local restore_disk="${DISK:-}" dry_no_target=0
  if [[ -n "${TARGET_DISK:-}" ]]; then
    restore_disk="$TARGET_DISK"; [[ -b "$restore_disk" ]] || die "Angegebene Ziel-Disk nicht gefunden: $restore_disk" "Target disk not found: $restore_disk"
  elif [[ "$RESTORE_DRY_RUN" == "--dry-run" ]] && ! have_tty; then
    dry_no_target=1; restore_disk=""
  elif [[ "${SELECT_DISK:-}" == "true" || "$LIVE_ENV" -eq 1 || -z "$restore_disk" ]]; then
    restore_disk="$(select_target_disk "${RUNNING_SYSTEM_DISK:-}")"
  fi
  if (( dry_no_target == 0 )); then
    [[ -b "$restore_disk" ]] || die "Keine gültige Restore-Zieldisk gewählt" "No valid restore target disk selected"
  fi
  if [[ -n "$restore_disk" ]] && disk_is_protected "$restore_disk"; then
    die "Restore-Ziel ist geschützt (Live-USB, Backup-Medium oder Skript-Quelle): $restore_disk" "Restore target is protected (live USB, backup medium or script source): $restore_disk"
  fi

  clear_status_for_new_run
  mark_run_started
  set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: Initialisiere..." || echo "RESTORE: Initializing..." )"

  msg "=== $(date) | Starte Restore ${RESTORE_DRY_RUN:+(Dry-Run)} auf $restore_disk ===" \
      "=== $(date) | Starting restore ${RESTORE_DRY_RUN:+(dry-run)} to $restore_disk ==="

  local CANDIDATE
  if [[ -n "${RESTORE_CANDIDATE_OVERRIDE:-}" ]]; then
    CANDIDATE="$RESTORE_CANDIDATE_OVERRIDE"
  elif [[ "${SELECT_BACKUP:-}" == "true" ]]; then
    CANDIDATE="$(select_backup_file "$BACKUP_DIR")"
  else
    CANDIDATE="$(find_latest_valid "$BACKUP_DIR" || true)"
  fi
  [[ -n "${CANDIDATE:-}" && -f "$CANDIDATE" ]] || die "Kein gültiges Backup gefunden" "No valid backup found"
  msg "[✓] Verwende: $(basename "$CANDIDATE")" "[✓] Using: $(basename "$CANDIDATE")"
  set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: Verwende $(basename "$CANDIDATE")" || echo "RESTORE: Using $(basename "$CANDIDATE")" )"

  if [[ "$RESTORE_DRY_RUN" == "--dry-run" ]]; then
    set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: Dry-Run abgeschlossen" || echo "RESTORE: Dry-run completed" )"
    if [[ -n "$restore_disk" ]]; then
      msg "[DRY-RUN] Würde $(basename "$CANDIDATE") auf $restore_disk schreiben." \
          "[DRY-RUN] Would write $(basename "$CANDIDATE") to $restore_disk."
    else
      msg "[DRY-RUN] Würde $(basename "$CANDIDATE") auf eine noch zu wählende Zieldisk schreiben." \
          "[DRY-RUN] Would write $(basename "$CANDIDATE") to a target disk yet to be chosen."
      msg "[DRY-RUN] Es wurde nichts verändert." "[DRY-RUN] Nothing was changed."
    fi
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
    write_passphrase_file "$ENCRYPT_PASSPHRASE" || \
      die "Passphrase konnte nicht sicher übergeben werden ($PASSPHRASE_FILE)" \
          "Could not hand over the passphrase securely ($PASSPHRASE_FILE)"
    ENCRYPT_PASSPHRASE=""
    trap 'clear_passphrase_file' EXIT INT TERM HUP
    if [[ "$CANDIDATE" == *.zst.gpg ]]; then
      msg "[*] gpg -d | zstd -d | dd …" "[*] gpg -d | zstd -d | dd …"
      set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: gpg | zstd | dd läuft..." || echo "RESTORE: gpg | zstd | dd running..." )"
      run_inhibited "Panzer-RESTORE läuft / running" \
        bash -c '
          set -o pipefail
          gpg --batch --yes --decrypt --pinentry-mode loopback \
              --passphrase-file "$3" "$1" \
          | zstd -d -q \
          | dd of="$2" bs=64M status=progress conv=fsync
        ' pb-restore "$CANDIDATE" "$restore_disk" "$PASSPHRASE_FILE"
    else
      msg "[*] gpg -d | dd …" "[*] gpg -d | dd …"
      set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: gpg | dd läuft..." || echo "RESTORE: gpg | dd running..." )"
      run_inhibited "Panzer-RESTORE läuft / running" \
        bash -c '
          set -o pipefail
          gpg --batch --yes --decrypt --pinentry-mode loopback \
              --passphrase-file "$3" "$1" \
          | dd of="$2" bs=64M status=progress conv=fsync
        ' pb-restore "$CANDIDATE" "$restore_disk" "$PASSPHRASE_FILE"
    fi
    clear_passphrase_file
    trap - EXIT INT TERM HUP
  elif [[ "$CANDIDATE" == *.zst ]]; then
    need_cmd zstd
    msg "[*] zstd -d | dd …" "[*] zstd -d | dd …"
    set_status "$( [[ "$LANG_CHOICE" == "de" ]] && echo "RESTORE: zstd | dd läuft..." || echo "RESTORE: zstd | dd running..." )"
    run_inhibited "Panzer-RESTORE läuft / running" \
      bash -c '
        set -o pipefail
        zstd -d -q "$1" | dd of="$2" bs=64M status=progress conv=fsync
      ' pb-restore "$CANDIDATE" "$restore_disk"
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
  local cols banner_inner title_len pad_left pad_right hbar i
  cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  title_len="$(str_display_width "$banner_title")"
  banner_inner=$(( title_len + 18 ))
  (( banner_inner > cols - 6 )) && banner_inner=$(( cols - 6 ))
  (( banner_inner < title_len + 4 )) && banner_inner=$(( title_len + 4 ))
  pad_left=$(( (banner_inner - title_len) / 2 ))
  pad_right=$(( banner_inner - title_len - pad_left ))
  hbar=""; for (( i=0; i<banner_inner; i++ )); do hbar+="═"; done
  printf '\n'
  printf '╔%s╗\n' "$hbar"
  printf '║%*s%s%*s║\n' "$pad_left" '' "$banner_title" "$pad_right" ''
  printf '╚%s╝\n' "$hbar"
  printf '\n'
  local sysline
  if pve_is_host; then
    sysline="$(L 'Proxmox VE erkannt' 'Proxmox VE detected') ($(pve_version_string))"
  else
    sysline="$(L 'Linux' 'Linux')"
  fi
  if [[ "$LANG_CHOICE" == "de" ]]; then
    echo "System:      ${sysline}"
    echo "Systemdisk:  ${DISK}"
    echo "Backup-Ziel: ${BACKUP_DIR}"
  else
    echo "System:      ${sysline}"
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
    echo "1) Backup erstellen"
    echo "2) Backup wiederherstellen"
    echo "3) Backup prüfen"
    echo "4) Status / Fortschritt"
    echo "5) Log anzeigen"
    echo ""
    is_running && echo "S) Laufenden Vorgang stoppen"
    echo "E) Erweiterte Optionen"
    echo "0) Beenden"
    echo ""
  else
    echo "1) Create backup"
    echo "2) Restore backup"
    echo "3) Check backup"
    echo "4) Status / progress"
    echo "5) View log"
    echo ""
    is_running && echo "S) Stop running job"
    echo "E) Advanced options"
    echo "0) Exit"
    echo ""
  fi
}

# =====================[ Menü: Backup ]========================================
pause_enter() {
  if [[ "$LANG_CHOICE" == "de" ]]; then read -rp "Drücke Enter um fortzufahren..." _ || true
  else read -rp "Press Enter to continue..." _ || true; fi
}

start_raw_backup_interactive() {
  COMPRESS_MODE="on"
  BACKUP_MODE="raw"
  BACKUP_DRY_RUN="0"
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
  do_backup
}

start_pve_dr_backup_interactive() {
  BACKUP_MODE="pve-dr"; BACKUP_DRY_RUN="0"; BACKUP_NAME=""
  if [[ -t 0 && -t 1 ]]; then
    if [[ "$LANG_CHOICE" == "de" ]]; then
      read -rp "Name der Sicherung [Standard: $(hostname -s)]: " BACKUP_NAME
    else
      read -rp "Backup name [default: $(hostname -s)]: " BACKUP_NAME
    fi
    prompt_post_action "Backup"
    prompt_encryption
  fi
  pve_dr_backup_start || true
  BACKUP_MODE="raw"
  pause_enter
}

menu_backup() {
  local ch
  if ! pve_is_host; then
    start_raw_backup_interactive
    return 0
  fi
  while true; do
    { clear 2>/dev/null || printf '\033c'; } || true
    echo "=========================================="
    M "  Backup erstellen" "  Create backup"
    echo "=========================================="
    echo ""
    M "Proxmox VE wurde erkannt." "Proxmox VE was detected."
    echo ""
    if [[ "$LANG_CHOICE" == "de" ]]; then
      echo "1) Proxmox Disaster-Recovery Backup"
      echo "   Konsistente Sicherung des ganzen Hosts inkl. VMs/CTs."
      echo "   VMs werden nur Sekunden angehalten. Ergebnis: eine .pzb-Datei."
      echo ""
      echo "2) Klassisches RAW-Backup"
      echo "   Sichert die komplette Systemdisk als Rohabbild."
      echo ""
      echo "3) Nur prüfen, ob Proxmox gesichert werden kann"
      echo "   Verändert nichts."
      echo ""
      echo "0) Zurück"
      echo ""
      read -rp "Auswahl (1/2/3/0): " ch || return 0
    else
      echo "1) Proxmox disaster recovery backup"
      echo "   Consistent backup of the whole host incl. VMs/CTs."
      echo "   VMs are paused for seconds only. Result: one .pzb file."
      echo ""
      echo "2) Classic RAW backup"
      echo "   Images the whole system disk."
      echo ""
      echo "3) Only check whether Proxmox can be backed up"
      echo "   Changes nothing."
      echo ""
      echo "0) Back"
      echo ""
      read -rp "Choice (1/2/3/0): " ch || return 0
    fi
    case "${ch:-}" in
      1) start_pve_dr_backup_interactive; return 0 ;;
      2) start_raw_backup_interactive; return 0 ;;
      3) BACKUP_MODE="pve-dr"; BACKUP_DRY_RUN="1"
         pve_dr_dry_run menu || true
         BACKUP_MODE="raw"; BACKUP_DRY_RUN="0" ;;
      0) return 0 ;;
      *) M "Ungültige Auswahl" "Invalid selection"; sleep 1 ;;
    esac
  done
}

# =====================[ Menü: Erweiterte Optionen ]===========================
menu_advanced() {
  local ch
  while true; do
    { clear 2>/dev/null || printf '\033c'; } || true
    echo "=========================================="
    M "  Erweiterte Optionen" "  Advanced options"
    echo "=========================================="
    echo ""
    if [[ "$LANG_CHOICE" == "de" ]]; then
      echo "1) Proxmox-Bereitschaft prüfen (technischer Bericht)"
      echo "2) Restore: nur prüfen (Dry-Run, kein Schreiben)"
      echo "3) Restore: mit Disk-Auswahl"
      echo "4) Restore: Backup selbst auswählen"
      echo "5) Laufenden Vorgang stoppen"
      echo "6) Eingefrorene Proxmox-Gäste freigeben"
      echo "7) Diagnosebericht exportieren (Kennwörter werden entfernt)"
      echo "0) Zurück"
      echo ""
      read -rp "Auswahl (0-7): " ch || return 0
    else
      echo "1) Check Proxmox readiness (technical report)"
      echo "2) Restore: check only (dry run, no write)"
      echo "3) Restore: with disk selection"
      echo "4) Restore: pick the backup yourself"
      echo "5) Stop running job"
      echo "6) Release frozen Proxmox guests"
      echo "7) Export diagnostics report (passwords are removed)"
      echo "0) Back"
      echo ""
      read -rp "Choice (0-7): " ch || return 0
    fi
    case "${ch:-}" in
      1)
        if pve_is_host; then
          BACKUP_MODE="pve-dr"; BACKUP_DRY_RUN="1"
          { clear 2>/dev/null || printf '\033c'; } || true
          pve_dr_dry_run cli || true
          BACKUP_MODE="raw"; BACKUP_DRY_RUN="0"
        else
          M "Kein Proxmox VE auf diesem System erkannt." "No Proxmox VE detected on this system."
        fi
        pause_enter ;;
      2) RESTORE_DRY_RUN="--dry-run"; SELECT_BACKUP="true"
         restore_dispatch || true
         RESTORE_DRY_RUN=""; SELECT_BACKUP=""; RESTORE_CANDIDATE_OVERRIDE=""; pause_enter ;;
      3) SELECT_DISK="true"; SELECT_BACKUP="true"
         [[ -z "${POST_ACTION_PRESET:-}" ]] && prompt_post_action "Restore"
         restore_dispatch || true
         SELECT_DISK=""; SELECT_BACKUP=""; RESTORE_CANDIDATE_OVERRIDE=""; pause_enter ;;
      4) SELECT_BACKUP="true"
         [[ -z "${POST_ACTION_PRESET:-}" ]] && prompt_post_action "Restore"
         restore_dispatch || true
         SELECT_BACKUP=""; RESTORE_CANDIDATE_OVERRIDE=""; pause_enter ;;
      5) do_stop; pause_enter ;;
      6) msg "[*] Gebe eingefrorene Gäste frei ..." "[*] Releasing frozen guests ..."
         resume_orphans; pause_enter ;;
      7) run_diag_export; pause_enter ;;
      0) return 0 ;;
      *) M "Ungültige Auswahl" "Invalid selection"; sleep 1 ;;
    esac
  done
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
  $0 backup  [--mode raw|pve-dr] [--dry-run] [--name NAME] [--compress] [--zstd-level N] [--encrypt|--no-encrypt] [--passfile FILE] [--post reboot|shutdown|none] [--select-backup] [--disk /dev/XYZ] [--force-space] [--no-space-estimate] [--quiesce] [--quiesce-max-sec N]
  $0 restore [--dry-run] [--select-disk] [--target /dev/sdX] [--post reboot|shutdown|none] [--passfile FILE] [--select-backup] [--disk /dev/XYZ]
  $0 verify
  $0 diag                     # Diagnosebericht (sensible Werte werden entfernt)
  $0 status
  $0 log    [--lines N] [--file PATH]
  $0 stop
  $0         # interaktives Menü

Backup-Modi:
  --mode raw       Standard: komplette Systemdisk als Rohabbild (dd|zstd|gpg).
  --mode pve-dr    Proxmox Disaster Recovery. Sichert den
                   Host aus LVM-Momentaufnahmen: Gäste werden nur Sekunden
                   angehalten. Ergebnis ist EINE Datei:
                     panzer_<name>_<zeit>.pzb
                   Darin liegen Manifest, Partitionstabelle, Startbereich,
                   Systemdatenträger, alle Gast-Datenträger, Konfiguration und
                   Prüfsummen. Wiederhergestellt wird sie mit demselben Skript
                   von einem Live-System aus.
                     $0 backup --mode pve-dr             # sichern
                     $0 backup --mode pve-dr --dry-run   # nur prüfen, ändert nichts

Environment:
  MIN_FREE_BYTES=2147483648
  AUTO_DELETE_OLDEST=1
  SPACE_ESTIMATE_MODE=sample     # sample = Kompression messen, raw = Rohgröße verlangen
  SPACE_SAMPLE_COUNT=64          # Anzahl Stichproben
  SPACE_SAMPLE_CHUNK_MIB=8       # Größe je Stichprobe in MiB
  SPACE_SAFETY_PERCENT=15        # Sicherheitsaufschlag auf die Schätzung
  ALLOW_LOW_SPACE=0              # 1 = Backup trotz zu wenig Platz starten
  LIVE_LOG_LINES=20
  LOG_VIEW_LINES_DEFAULT=100
  MENU_REFRESH_SECONDS=2
  PVE_DR_QGA_TIMEOUT=5            # Sekunden für den Guest-Agent-Test
  PVE_DR_POOL_DATA_MAX=80         # Preflight FAIL ab dieser Thin-Pool-Belegung
  PVE_DR_POOL_META_MAX=60         # Preflight FAIL ab dieser Metadaten-Belegung
  PVE_DR_COW_WARN=50 / _EXTEND=70 / _ABORT=90   # Snapshot-Schwellen (ab Phase 5)

USAGE
  else
cat <<USAGE
Detected:
  System disk:  ${DISK:-<live/select manually>}
  Backup dir:   $BACKUP_DIR
  Live system:  $([[ "$LIVE_ENV" -eq 1 ]] && echo yes || echo no)

Usage:
  $0 backup  [--mode raw|pve-dr] [--dry-run] [--name NAME] [--compress] [--zstd-level N] [--encrypt|--no-encrypt] [--passfile FILE] [--post reboot|shutdown|none] [--select-backup] [--disk /dev/XYZ] [--force-space] [--no-space-estimate] [--quiesce] [--quiesce-max-sec N]
  $0 restore [--dry-run] [--select-disk] [--target /dev/sdX] [--post reboot|shutdown|none] [--passfile FILE] [--select-backup] [--disk /dev/XYZ]
  $0 verify
  $0 diag                     # diagnostics report (sensitive values are removed)
  $0 status
  $0 log    [--lines N] [--file PATH]
  $0 stop
  $0         # interactive menu

Backup modes:
  --mode raw       Default: image the whole system disk (dd|zstd|gpg).
  --mode pve-dr    Proxmox disaster recovery (release candidate). Backs the host
                   up from LVM snapshots: guests are paused for seconds only.
                   The result is ONE file:
                     panzer_<name>_<time>.pzb
                   It contains the manifest, partition table, boot area, system
                   volume, all guest volumes, configuration and checksums, and is
                   restored with this same script from a live system.
                     $0 backup --mode pve-dr             # back up
                     $0 backup --mode pve-dr --dry-run   # check only, changes nothing

Environment:
  MIN_FREE_BYTES=2147483648
  AUTO_DELETE_OLDEST=1
  SPACE_ESTIMATE_MODE=sample     # sample = measure compression, raw = require raw size
  SPACE_SAMPLE_COUNT=64          # number of samples
  SPACE_SAMPLE_CHUNK_MIB=8       # size per sample in MiB
  SPACE_SAFETY_PERCENT=15        # safety margin on top of the estimate
  ALLOW_LOW_SPACE=0              # 1 = start backup despite insufficient space
  LIVE_LOG_LINES=20
  LOG_VIEW_LINES_DEFAULT=100
  MENU_REFRESH_SECONDS=2
  PVE_DR_QGA_TIMEOUT=5            # seconds for the guest agent probe
  PVE_DR_POOL_DATA_MAX=80         # preflight FAIL at this thin pool usage
  PVE_DR_POOL_META_MAX=60         # preflight FAIL at this metadata usage
  PVE_DR_COW_WARN=50 / _EXTEND=70 / _ABORT=90   # snapshot thresholds (phase 5)

USAGE
  fi
}

# =====================[ Entry / CLI ]=========================================
if [[ $# -gt 0 ]]; then
  PB_EXIT_RC=0
  case "$1" in
    backup)
      shift; parse_backup_flags "$@" >/dev/null
      # Eine reine Pruefung fragt weder nach Post-Action noch nach einer Passphrase.
      if [[ -t 0 && -t 1 && "$BACKUP_DRY_RUN" != "1" && "$BACKUP_MODE" == "raw" ]]; then
        [[ -z "${POST_ACTION_PRESET:-}" ]] && prompt_post_action "Backup"
        if [[ "${ENCRYPT_MODE}" == "off" && -z "${ENCRYPT_PASSPHRASE:-}" ]]; then prompt_encryption; fi
      fi
      backup_dispatch || PB_EXIT_RC=$? ;;
    restore)
      shift; parse_restore_flags "$@" >/dev/null
      if [[ -t 0 && -t 1 && -z "${POST_ACTION_PRESET:-}" ]]; then
        prompt_post_action "Restore"
      fi
      restore_dispatch || PB_EXIT_RC=$? ;;
    __pve-dr-worker)
      # interner Einstiegspunkt des Hintergrundlaufs - nicht für den Benutzer.
      # pve_dr_backup_start startet eine eingefrorene Kopie des Skripts hiermit.
      exec >> "$LOG_FILE_DEFAULT" 2>&1
      echo "=========================================="
      echo "PVE-DR Worker Start: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "=========================================="
      pve_dr_backup_run || PB_EXIT_RC=1
      rm -f "$PID_FILE"
      echo "PVE-DR Worker Ende: $(date '+%Y-%m-%d %H:%M:%S')  RC=$PB_EXIT_RC"
      (( PB_EXIT_RC == 0 )) && post_action_maybe "Backup"
      ;;
    diag) run_diag_export || PB_EXIT_RC=1 ;;
    verify) verify_dispatch || PB_EXIT_RC=1 ;;
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
  exit "$PB_EXIT_RC"
fi

# =====================[ Interactive Menu ]====================================
while true; do
  show_menu
  if [[ "$LANG_CHOICE" == "en" ]]; then
    read -rp "Choice (1-5, E, 0): " choice || { echo "No input (EOF) — exiting."; exit 0; }
  else
    read -rp "Auswahl (1-5, E, 0): " choice || { echo "Keine Eingabe erkannt (EOF) – beende."; exit 0; }
  fi

  case "${choice:-}" in
    1) menu_backup ;;
    2)
      SELECT_BACKUP="true"
      if [[ -t 0 && -t 1 && -z "${POST_ACTION_PRESET:-}" ]]; then prompt_post_action "Restore"; fi
      restore_dispatch || true
      SELECT_BACKUP=""; RESTORE_CANDIDATE_OVERRIDE=""
      pause_enter ;;
    3)
      { clear 2>/dev/null || printf '\033c'; } || true
      SELECT_BACKUP="true"
      verify_dispatch || true
      SELECT_BACKUP=""
      pause_enter ;;
    4) show_status ;;
    5) view_log ;;
    E|e) menu_advanced ;;
    S|s) do_stop; pause_enter ;;
    0) exit 0 ;;
    *)
      if [[ "$LANG_CHOICE" == "de" ]]; then echo "Ungültige Auswahl"; else echo "Invalid selection"; fi
      sleep 1 ;;
  esac
done
