#!/usr/bin/env bash
set -euo pipefail

# =====[ Sane defaults for env -i + set -u ]===================================
: "${LC_ALL:=C}"; export LC_ALL
: "${LANG:=C}";   export LANG
: "${PATH:=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"; export PATH
: "${HOME:=/root}"; export HOME

# =====================[ Language Selection / Sprachwahl ]=====================
# Optional: preset via environment, e.g. LANG_CHOICE=en
LANG_CHOICE="${LANG_CHOICE:-}"

if [[ -z "$LANG_CHOICE" && -t 0 && -t 1 ]]; then
  echo "Bitte Sprache wählen / Please select language:"
  echo "1) Deutsch"
  echo "2) English"
  read -rp "Auswahl / Choice (1/2): " _ch
  case "${_ch:-}" in
    1) LANG_CHOICE="de" ;;
    2) LANG_CHOICE="en" ;;
    *) LANG_CHOICE="en" ;;  # Default English
  esac
elif [[ -z "$LANG_CHOICE" ]]; then
  LANG_CHOICE="en"
fi

# Simple i18n helpers
M() { # print message in chosen language: M "DE" "EN"
  if [[ "$LANG_CHOICE" == "de" ]]; then echo -e "$1"; else echo -e "$2"; fi
}
ASK() { # ask yes/no; returns 0 if yes: ASK "DE question" "EN question"
  local qd="$1" qe="$2" ans
  if [[ "$LANG_CHOICE" == "de" ]]; then
    read -r -p "$qd [j/N]: " ans; [[ "${ans:-}" =~ ^([JjYy])$ ]]
  else
    read -r -p "$qe [y/N]: " ans; [[ "${ans:-}" =~ ^([YyJj])$ ]]
  fi
}
die() { M "❌ $1" "❌ $2" >&2; exit 1; }          # die "DE" "EN"
msg() { M "$1" "$2"; }                            # msg "DE" "EN"
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Benötigtes Kommando fehlt: $1" "Required command missing: $1"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# =====================[ Status-Tracking (wie BorgBase Manager) ]==============
RUN_DIR="${RUN_DIR:-/run/panzerbackup}"
mkdir -p "$RUN_DIR"
STATUS_FILE="${STATUS_FILE:-$RUN_DIR/status}"
PID_FILE="${PID_FILE:-$RUN_DIR/pid}"
STARTUP_LOG="${STARTUP_LOG:-$RUN_DIR/startup.log}"
WORKER_SCRIPT="${WORKER_SCRIPT:-$RUN_DIR/worker.sh}"


set_status() { echo "$1" > "$STATUS_FILE"; }
get_status() { 
  [[ -s "$STATUS_FILE" ]] && cat "$STATUS_FILE" || {
    [[ "$LANG_CHOICE" == "en" ]] && echo "Initializing..." || echo "Initialisiere..."
  }
}
clear_status() { rm -f "$STATUS_FILE"; }

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || { rm -f "$PID_FILE"; return 1; }
  if ps -p "$pid" >/dev/null 2>&1; then
    return 0
  fi
  rm -f "$PID_FILE"
  return 1
}

# =====================[ Power inhibit / Schlaf verhindern ]==================
run_inhibited() {
  local why="${1:?}"; shift
  if has_cmd systemd-inhibit; then
    systemd-inhibit --what=handle-lid-switch:sleep:idle --why="$why" "$@"
  else
    "$@"
  fi
}

# =====================[ Systemdisk-Erkennung (LVM/mapper) ]==================
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

# =====================[ Disks anzeigen/auswählen ]===========================
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
  msg "[*] Verfügbare Disks:" "[*] Available disks:"
  local i=1
  while IFS='|' read -r name size model; do
    if [[ "$name" == "$current_disk" ]]; then
      M "  $i) $name ($size) - $model [AKTUELL SYSTEM-DISK]" \
        "  $i) $name ($size) - $model [CURRENT SYSTEM DISK]"
    else
      echo "  $i) $name ($size) - $model"
    fi
    disks+=("$name"); ((i++))
  done < <(list_available_disks)
  (( ${#disks[@]} > 0 )) || die "Keine geeigneten Disks gefunden" "No suitable disks found"

  if (( ${#disks[@]} == 1 )); then
    M "[*] Nur eine Disk verfügbar: ${disks[0]}" "[*] Only one disk available: ${disks[0]}"
    echo "${disks[0]}"; return 0
  fi

  echo
  if [[ "$LANG_CHOICE" == "de" ]]; then
    read -rp "Ziel-Disk auswählen (1-${#disks[@]}): " choice
  else
    read -rp "Select target disk (1-${#disks[@]}): " choice
  fi
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#disks[@]} )) || die "Ungültige Auswahl: $choice" "Invalid selection: $choice"

  local selected="${disks[$((choice-1))]}"
  if [[ "$selected" == "$current_disk" ]]; then
    M "⚠️  Du hast die aktuelle System-Disk ausgewählt!" "⚠️  You selected the current system disk!"
    ASK "Bist du sicher, dass du das System überschreiben willst?" "Are you sure you want to overwrite the system?" || die "Abgebrochen" "Aborted"
  fi
  echo "$selected"
}

# ============[ Backup-Ziel finden/mounten (Label-Teilstring, CI) ]===========
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
      echo "$mp"; return 0
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

# =====================[ Backup-Name Prompt ]=================================
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
      # Sanitize input: nur alphanumerisch, Bindestrich, Unterstrich
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

rotate_old() {
  local dir="${1:?}"; local keep="${2:?}"
  mapfile -t ALL < <(ls -1t \
    "$dir"/panzer_*.img "$dir"/panzer_*.img.zst \
    "$dir"/panzer_*.img.gpg "$dir"/panzer_*.img.zst.gpg 2>/dev/null || true)
  if (( ${#ALL[@]} > keep )); then
    for old in "${ALL[@]:$keep}"; do
      M "  - Entferne alt: $old" "  - Removing old: $old"
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
    M "  - Prüfe $(basename "$img") ..." "  - Checking $(basename "$img") ..."
    ( cd "$dir" && sha256sum -c "$(basename "$img").sha256" >/dev/null ) && { echo "$img"; return 0; }
  done
  return 1
}
find_latest_any() { local dir="${1:?}"; ls -1t "$dir"/panzer_*.img.zst.gpg "$dir"/panzer_*.img.gpg "$dir"/panzer_*.img.zst "$dir"/panzer_*.img 2>/dev/null | head -n1 || true; }

# =====================[ zstd ensure ]========================================
ensure_zstd_if_needed() {
  local want="$1"  # on|auto|off
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

# =====================[ Proxmox Quiesce (VM/CT) ]============================
declare -a RUN_QM RUN_CT FROZEN_QM SUSPENDED_QM
pve_quiesce_start() {
  FROZEN_QM=(); SUSPENDED_QM=()
  if ! has_cmd qm && ! has_cmd pct; then return 0; fi
  set_status "BACKUP: Proxmox VMs/CTs werden pausiert..."
  msg "[*] Proxmox erkannt – beginne Quiesce" "[*] Proxmox detected – starting quiesce"

  if has_cmd qm; then
    mapfile -t RUN_QM < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}')
    for vm in "${RUN_QM[@]:-}"; do
      if qm agent "$vm" ping >/dev/null 2>&1; then
        msg "  - VM $vm: QGA ok → fsfreeze-freeze" "  - VM $vm: QGA ok → fsfreeze-freeze"
        if qm agent "$vm" fsfreeze-freeze >/dev/null 2>&1; then
          FROZEN_QM+=("$vm")
        else
          msg "    ! freeze fehlgeschlagen → fallback suspend" "    ! freeze failed → falling back to suspend"
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
  set_status "BACKUP: VMs/CTs werden fortgesetzt..."
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

# =====================[ Auto-Detection / Defaults ]==========================
BACKUP_LABEL="${BACKUP_LABEL:-PANZERBACKUP}"
DISK="${DISK_OVERRIDE:-$(detect_system_disk || true)}"
[[ -b "${DISK:-}" ]] || die "Konnte Systemdisk nicht ermitteln" "Could not determine system disk"
SELECT_BACKUP="${SELECT_BACKUP:-""}"
BACKUP_DIR="$(detect_backup_dir "$BACKUP_LABEL" || true)"
[[ -d "${BACKUP_DIR:-}" && -w "$BACKUP_DIR" ]] || die "Backup-Platte mit Label $BACKUP_LABEL nicht gefunden/ nicht schreibbar" "Backup drive with label $BACKUP_LABEL not found / not writable"

KEEP="${KEEP:-3}"
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

# Globale Worker-Variablen
USE_COMPRESS=""
FINAL_FILE=""
TEMP_FILE=""
TEMP_SHA=""
LOG_FILE_DEFAULT="${BACKUP_DIR}/panzerbackup.log"

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
  if ASK "Backup verschlüsseln (GnuPG AES-256)?" "Encrypt backup (GnuPG AES-256)?" ; then
    need_cmd gpg
    ENCRYPT_MODE="gpg"
    if [[ "$LANG_CHOICE" == "de" ]]; then
      read -rsp "Passphrase: " p1; echo
      read -rsp "Passphrase wiederholen: " p2; echo
      [[ "$p1" == "$p2" ]] || die "Passphrasen stimmen nicht überein" "Passphrases do not match"
    else
      read -rsp "Passphrase: " p1; echo
      read -rsp "Repeat passphrase: " p2; echo
      [[ "$p1" == "$p2" ]] || die "Passphrases do not match" "Passphrases do not match"
    fi
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
    resume-orphans)
      resume_orphans
      exit 0 ;;
    stop)
      if is_running; then
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        msg "Sende SIGINT an PID $pid ..." "Sending SIGINT to PID $pid ..."
        kill -INT "$pid" 2>/dev/null || true
        sleep 2
      fi
      resume_orphans
      clear_status
      rm -f "$PID_FILE"
      msg "Gestoppt." "Stopped."
      exit 0 ;;

      --compress)      COMPRESS_MODE="on"; shift ;;
      --no-compress)   COMPRESS_MODE="off"; shift ;;
      --zstd-level)    ZSTD_LEVEL="${2:-6}"; shift 2 ;;
      --post)          POST_ACTION="${2:-none}"; POST_ACTION_PRESET="1"; shift 2 ;;
      --encrypt)       ENCRYPT_MODE="gpg"; shift ;;
      --no-encrypt)    ENCRYPT_MODE="off"; shift ;;
      --passfile)      ENCRYPT_PASSPHRASE="$(<"$2")"; shift 2 ;;
      --select-backup) SELECT_BACKUP="true"; shift ;;
      --disk)          DISK="$2"; shift 2 ;;
      --name)          BACKUP_NAME="$2"; shift 2 ;;
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

# =====================[ Backup Worker (Hintergrund) ]=======================
do_backup_background() {
  set_status "BACKUP: Wird gestartet..."
  
  # Worker-Skript erstellen
  cat > "$WORKER_SCRIPT" << 'EOFWORKER'
#!/usr/bin/env bash
set -euo pipefail
set -E
trap 'rc=$?; echo "FEHLER (Backup Worker) in Zeile $LINENO: $BASH_COMMAND (RC=$rc)"; exit $rc' ERR

# Erwartete Variablen via env:
# DISK BACKUP_DIR IMG_PREFIX FINAL_FILE TEMP_FILE TEMP_SHA USE_COMPRESS ENCRYPT_MODE ENCRYPT_PASSPHRASE ZSTD_LEVEL
# STATUS_FILE PID_FILE LOG_FILE KEEP LANG_CHOICE

export LC_ALL=C
: "${PATH:=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

set_status() { echo "$1" > "$STATUS_FILE"; }
msg() { if [[ "${LANG_CHOICE:-de}" == "de" ]]; then echo "$1"; else echo "$2"; fi; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

run_inhibited() {
  local why="${1:?}"; shift
  if has_cmd systemd-inhibit; then
    systemd-inhibit --what=handle-lid-switch:sleep:idle --why="$why" "$@"
  else
    "$@"
  fi
}

pve_quiesce_start() {
  FROZEN_QM=(); SUSPENDED_QM=(); RUN_CT=()
  if ! has_cmd qm && ! has_cmd pct; then return 0; fi
  set_status "BACKUP: Proxmox VMs/CTs werden pausiert..."
  msg "[*] Proxmox erkannt – beginne Quiesce" "[*] Proxmox detected – starting quiesce"

  if has_cmd qm; then
    mapfile -t RUN_QM < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}')
    for vm in "${RUN_QM[@]:-}"; do
      if qm agent "$vm" ping >/dev/null 2>&1; then
        msg "  - VM $vm: QGA ok → fsfreeze-freeze" "  - VM $vm: QGA ok → fsfreeze-freeze"
        if qm agent "$vm" fsfreeze-freeze >/dev/null 2>&1; then
          FROZEN_QM+=("$vm")
        else
          msg "    ! freeze fehlgeschlagen → fallback suspend" "    ! freeze failed → falling back to suspend"
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
  set_status "BACKUP: VMs/CTs werden fortgesetzt..."
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

  set_status "BACKUP: Initialisiere..."
  msg "=== $(date) | Starte Panzer-Backup von $DISK -> $FINAL_FILE" \
      "=== $(date) | Starting panzer-backup from $DISK -> $FINAL_FILE"

  pve_quiesce_start
  
  set_status "BACKUP: Erstelle Partitionstabelle..."
  sfdisk -d "$DISK" > "${BACKUP_DIR}/${IMG_PREFIX}.sfdisk"

  set_status "BACKUP: Kopiere Disk-Image..."
  set -o pipefail
  
  if [[ "$USE_COMPRESS" == "true" && "$ENCRYPT_MODE" == "gpg" ]]; then
    msg "[*] dd | zstd | gpg | tee | sha256sum …" "[*] dd | zstd | gpg | tee | sha256sum …"
    set_status "BACKUP: dd | zstd | gpg läuft..."
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
    set_status "BACKUP: dd | zstd läuft..."
    run_inhibited "Panzerbackup läuft / Panzerbackup running" bash -c '
      dd if='"$DISK"' bs=64M status=progress \
      | zstd -T0 -'"$ZSTD_LEVEL"' -q \
      | tee "'"$TEMP_FILE"'" \
      | sha256sum -b \
      | awk '"'"'{print $1"  '"$(basename "$FINAL_FILE")"'"}'"'"' > "'"$TEMP_SHA"'"
    '
  elif [[ "$ENCRYPT_MODE" == "gpg" ]]; then
    msg "[*] dd | gpg | tee | sha256sum …" "[*] dd | gpg | tee | sha256sum …"
    set_status "BACKUP: dd | gpg läuft..."
    run_inhibited "Panzerbackup läuft / Panzerbackup running" bash -c '
      dd if='"$DISK"' bs=64M status=progress \
      | gpg --batch --yes --symmetric --cipher-algo AES256 --pinentry-mode loopback --passphrase-fd 3 3<<<"'"$ENCRYPT_PASSPHRASE"'" \
      | tee "'"$TEMP_FILE"'" \
      | sha256sum -b \
      | awk '"'"'{print $1"  '"$(basename "$FINAL_FILE")"'"}'"'"' > "'"$TEMP_SHA"'"
    '
  else
    msg "[*] dd (roh) | tee | sha256sum …" "[*] dd (raw) | tee | sha256sum …"
    set_status "BACKUP: dd (raw) läuft..."
    run_inhibited "Panzerbackup läuft / Panzerbackup running" bash -c '
      dd if='"$DISK"' bs=64M status=progress \
      | tee "'"$TEMP_FILE"'" \
      | sha256sum -b \
      | awk '"'"'{print $1"  '"$(basename "$FINAL_FILE")"'"}'"'"' > "'"$TEMP_SHA"'"
    '
  fi
  set +o pipefail

  set_status "BACKUP: Finalisiere..."
  sync
  mv -f "$TEMP_FILE" "$FINAL_FILE"
  mv -f "$TEMP_SHA" "${FINAL_FILE}.sha256"

  msg "[✓] Datei: $(du -h "$FINAL_FILE" | cut -f1)   Hash: $(cut -d' ' -f1 "${FINAL_FILE}.sha256")" \
      "[✓] File:  $(du -h "$FINAL_FILE" | cut -f1)   Hash: $(cut -d' ' -f1 "${FINAL_FILE}.sha256")"

  ln -sfn "$(basename "$FINAL_FILE")" "${BACKUP_DIR}/LATEST_OK"
  ln -sfn "$(basename "$FINAL_FILE").sha256" "${BACKUP_DIR}/LATEST_OK.sha256"
  ln -sfn "${IMG_PREFIX}.sfdisk" "${BACKUP_DIR}/LATEST_OK.sfdisk"

  set_status "BACKUP: Räume alte Backups auf..."
  mapfile -t ALL < <(ls -1t \
    "$BACKUP_DIR"/panzer_*.img "$BACKUP_DIR"/panzer_*.img.zst \
    "$BACKUP_DIR"/panzer_*.img.gpg "$BACKUP_DIR"/panzer_*.img.zst.gpg 2>/dev/null || true)
  if (( ${#ALL[@]} > KEEP )); then
    for old in "${ALL[@]:$KEEP}"; do
      msg "  - Entferne alt: $old" "  - Removing old: $old"
      rm -f "$old" "${old}.sha256" "${old%.img*}.sfdisk" 2>/dev/null || true
    done
  fi
  
  set_status "BACKUP: Abgeschlossen - $(basename "$FINAL_FILE")"
  msg "=== $(date) | Backup erfolgreich abgeschlossen ===" "=== $(date) | Backup completed successfully ==="
  
  echo "=========================================="
  echo "Backup Worker Ende: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  rm -f "$PID_FILE"
}
EOFWORKER

  chmod +x "$WORKER_SCRIPT"
  
  # Temporäres Startup-Log für Debugging
  local startup_log=""$STARTUP_LOG""
  : > "$startup_log"
  
  # Worker im Hintergrund starten (explizite, minimale Umgebung)
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
  echo $worker_pid > "$PID_FILE"
  
  # Kurz warten und prüfen ob Worker noch läuft
  sleep 2
  if ! ps -p $worker_pid >/dev/null 2>&1; then
    set_status "FEHLER: Worker-Start fehlgeschlagen – siehe $startup_log"
    msg "⚠️  WARNUNG: Worker-Prozess beendet sich sofort!" \
        "⚠️  WARNING: Worker process terminated immediately!"
    msg "   Prüfe: cat $startup_log" \
        "   Check: cat $startup_log"
    msg "   oder: tail $LOG_FILE_DEFAULT" \
        "   or: tail $LOG_FILE_DEFAULT"
  fi
}

# =====================[ Backup (Starter) ]====================================
do_backup() {
  if is_running; then
    msg "Ein Backup läuft bereits!" "A backup is already running!"
    msg "Aktueller Status: $(get_status)" "Current status: $(get_status)"
    return 1
  fi
  
  need_cmd dd; need_cmd sha256sum; need_cmd sfdisk
  ensure_zstd_if_needed "$COMPRESS_MODE"

  # Backup-Name ermitteln
  local default_name="$(hostname -s 2>/dev/null || echo 'system')"
  local backup_name="$(prompt_backup_name "$default_name")"
  IMG_PREFIX="panzer_${backup_name}_${DATE}"
  
  msg "→ Backup-Name: $backup_name" "→ Backup name: $backup_name"

  USE_COMPRESS="false"
  if [[ "$COMPRESS_MODE" == "on" ]]; then USE_COMPRESS="true"
  elif [[ "$COMPRESS_MODE" == "auto" && $(has_cmd zstd && echo yes || echo no) == "yes" ]]; then USE_COMPRESS="true"
  fi

  FINAL_FILE="${BACKUP_DIR}/${IMG_PREFIX}.img"
  [[ "$USE_COMPRESS" == "true" ]] && FINAL_FILE="${FINAL_FILE}.zst"
  [[ "$ENCRYPT_MODE" == "gpg" ]] && FINAL_FILE="${FINAL_FILE}.gpg"
  TEMP_FILE="${FINAL_FILE}.part"
  TEMP_SHA="${FINAL_FILE}.sha256.part"

  clear_status
  msg "" ""
  msg "Starte Backup im Hintergrund..." "Starting backup in background..."
  
  # Debug-Info
  msg "[Debug] Worker wird gestartet mit:" "[Debug] Starting worker with:"
  msg "  - Disk: $DISK" "  - Disk: $DISK"
  msg "  - Ziel: $FINAL_FILE" "  - Target: $FINAL_FILE"
  msg "  - Kompression: $USE_COMPRESS" "  - Compression: $USE_COMPRESS"
  msg "  - Verschlüsselung: $ENCRYPT_MODE" "  - Encryption: $ENCRYPT_MODE"
  
  do_backup_background
  
  # Prüfe ob Worker läuft
  sleep 2
  if is_running; then
    echo ""
    msg "✓ Backup läuft!" "✓ Backup is running!"
    msg "  Verwende './$(basename "$0") status' um den Fortschritt zu sehen." \
        "  Use './$(basename "$0") status' to watch progress."
    msg "  Aktueller Status: $(get_status)" "  Current status: $(get_status)"
  else
    echo ""
    msg "⚠️  WARNUNG: Worker wurde beendet oder konnte nicht starten!" \
        "⚠️  WARNING: Worker terminated or could not start!"
    msg "  Prüfe Logs:" "  Check logs:"
    
    msg "    tail ${LOG_FILE_DEFAULT}" "    tail ${LOG_FILE_DEFAULT}"
    [[ -f ""$STARTUP_LOG"" ]] && {
      echo ""
      msg "=== Startup-Log ===" "=== Startup log ==="
      cat "$STARTUP_LOG" || true
    }
  fi
  echo ""
  
  ENCRYPT_PASSPHRASE=""
}

# =====================[ Verify ]=============================================
do_verify() {
  need_cmd sha256sum
  msg "=== $(date) | Prüfe letztes Backup ===" "=== $(date) | Verifying last backup ==="
  local CAND; CAND="$(find_latest_any "$BACKUP_DIR" || true)"
  [[ -n "${CAND:-}" ]] || die "Keine Backup-Datei gefunden" "No backup file found"
  msg "Datei: $(basename "$CAND") | Größe: $(du -h "$CAND" | cut -f1)" \
      "File:  $(basename "$CAND") | Size:  $(du -h "$CAND" | cut -f1)"
  ( cd "$BACKUP_DIR" && sha256sum -c "$(basename "$CAND").sha256" )
  msg "=== Verify OK ===" "=== Verify OK ==="
}

# =====================[ Restore ]============================================
do_restore() {
  need_cmd dd; need_cmd sha256sum; need_cmd lsblk; need_cmd mount; need_cmd chroot
  local restore_disk="${DISK}"
  if [[ -n "${TARGET_DISK:-}" ]]; then
    restore_disk="$TARGET_DISK"; [[ -b "$restore_disk" ]] || die "Angegebene Ziel-Disk nicht gefunden: $restore_disk" "Target disk not found: $restore_disk"
  elif [[ "${SELECT_DISK:-}" == "true" ]]; then
    restore_disk="$(select_target_disk "$DISK")"
  fi
  msg "=== $(date) | Starte Restore ${RESTORE_DRY_RUN:+(Dry-Run)} auf $restore_disk ===" \
      "=== $(date) | Starting restore ${RESTORE_DRY_RUN:+(dry-run)} to $restore_disk ==="

  local CANDIDATE; CANDIDATE="$(find_latest_valid "$BACKUP_DIR" || true)" || die "Kein gültiges Backup gefunden" "No valid backup found"
  msg "[✓] Verwende: $(basename "$CANDIDATE")" "[✓] Using: $(basename "$CANDIDATE")"

  if [[ "$RESTORE_DRY_RUN" == "--dry-run" ]]; then
    msg "[DRY-RUN] Würde $(basename "$CANDIDATE") auf $restore_disk schreiben." \
        "[DRY-RUN] Would write $(basename "$CANDIDATE") to $restore_disk."
    return 0
  fi

  M "⚠️  ALLE DATEN auf $restore_disk werden überschrieben!" "⚠️  ALL DATA on $restore_disk will be overwritten!"
  ASK "Willst du das Restore wirklich starten?" "Do you really want to start the restore?" || { msg "Abbruch." "Aborted."; return 3; }

  set -o pipefail
  if [[ "$CANDIDATE" == *.gpg ]]; then
    need_cmd gpg
    if [[ -z "${ENCRYPT_PASSPHRASE:-}" ]]; then
      if [[ "$LANG_CHOICE" == "de" ]]; then read -rsp "GPG-Passphrase für Restore: " ENCRYPT_PASSPHRASE; echo
      else read -rsp "GPG passphrase for restore: " ENCRYPT_PASSPHRASE; echo; fi
    fi
    if [[ "$CANDIDATE" == *.zst.gpg ]]; then
      msg "[*] gpg -d | zstd -d | dd …" "[*] gpg -d | zstd -d | dd …"
      run_inhibited "Panzer-RESTORE läuft / running" bash -c \
        'gpg --batch --yes --decrypt --pinentry-mode loopback --passphrase-fd 3 3<<<"'"$ENCRYPT_PASSPHRASE"'" "'"$CANDIDATE"'" \
         | zstd -d -q \
         | dd of="'"$restore_disk"'" bs=64M status=progress conv=fsync'
    else
      msg "[*] gpg -d | dd …" "[*] gpg -d | dd …"
      run_inhibited "Panzer-RESTORE läuft / running" bash -c \
        'gpg --batch --yes --decrypt --pinentry-mode loopback --passphrase-fd 3 3<<<"'"$ENCRYPT_PASSPHRASE"'" "'"$CANDIDATE"'" \
         | dd of="'"$restore_disk"'" bs=64M status=progress conv=fsync'
    fi
    ENCRYPT_PASSPHRASE=""
  elif [[ "$CANDIDATE" == *.zst ]]; then
    need_cmd zstd
    msg "[*] zstd -d | dd …" "[*] zstd -d | dd …"
    run_inhibited "Panzer-RESTORE läuft / running" bash -c \
      'zstd -d -q "'"$CANDIDATE"'" \
       | dd of="'"$restore_disk"'" bs=64M status=progress conv=fsync'
  else
    msg "[*] dd (roh) …" "[*] dd (raw) …"
    run_inhibited "Panzer-RESTORE läuft / running" dd if="$CANDIDATE" of="$restore_disk" bs=64M status=progress conv=fsync
  fi
  set +o pipefail

  if [[ "$restore_disk" == "$DISK" ]]; then
    msg "[*] Versuche GRUB zu erneuern …" "[*] Attempting GRUB repair …"
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
      msg "[!] Root-Partition nicht sicher erkannt – GRUB-Reparatur übersprungen." "[!] Root partition not reliably detected – skipping GRUB repair."
    fi
  else
    msg "[*] Restore auf anderer Disk – GRUB-Installation übersprungen." "[*] Restore to different disk – skipping GRUB installation."
  fi

  msg "[✓] Restore abgeschlossen." "[✓] Restore completed."
  post_action_maybe "restore"
}

# =====================[ Post-Action ]========================================
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
          *)  : ;;
        esac
      fi
      ;;
  esac
}

# =====================[ Systemd Summary (optional) ]=========================
systemd_summary() {
  command -v systemctl >/dev/null 2>&1 || return 0
  echo "------------------------------------------"
  msg "Systemd-Übersicht:" "Systemd summary:"
  local svc="panzerbackup.service" tim="panzerbackup.timer"
  local svc_state tim_state tim_enabled
  svc_state="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
  tim_state="$(systemctl is-active "$tim" 2>/dev/null || echo unknown)"
  tim_enabled="$(systemctl is-enabled "$tim" 2>/dev/null || echo unknown)"
  msg "  Service: ${svc} → ${svc_state}" "  Service: ${svc} → ${svc_state}"
  msg "  Timer:   ${tim} → ${tim_state} / ${tim_enabled}" "  Timer:   ${tim} → ${tim_state} / ${tim_enabled}"
  local timers_line
  timers_line="$(systemctl list-timers --all | awk '/panzerbackup\.timer/ {print}' || true)"
  if [[ -n "$timers_line" ]]; then
    # Columns: NEXT LEFT LAST PASSED UNIT ACTIVATES
    awk -v L="$LANG_CHOICE" '
      /panzerbackup\.timer/ {
        next_time=$1 " " $2; last_time=$4 " " $5;
        if (L=="de") {
          printf("  Nächster Lauf: %s | Letzter Lauf: %s\n", next_time, last_time);
        } else {
          printf("  Next run: %s | Last run: %s\n", next_time, last_time);
        }
      }
    ' <<<"$timers_line"
  fi
}

# =====================[ Live Status anzeigen (wie BorgBase) ]================
show_status() {
  { clear 2>/dev/null || printf '\033c'; } || true
  echo "=========================================="
  msg "    Panzerbackup - Live-Status" "    Panzerbackup - Live Status"
  echo "=========================================="
  echo ""

  if ! is_running; then
    msg "Kein Backup läuft aktuell." "No backup is currently running."
    echo ""
    [[ -f "$STATUS_FILE" ]] && msg "Letzter Status: $(cat "$STATUS_FILE")" "Last status: $(cat "$STATUS_FILE")"
    echo ""
    systemd_summary
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
    msg "Aktueller Status: $(get_status)" "Current status: $(get_status)"
    echo "=========================================="
    msg "Log (letzte 50 Zeilen):" "Log (last 50 lines):"
    echo "=========================================="

    local logfile="${LOG_FILE_DEFAULT}"
    if [[ -f "$logfile" ]]; then
      tail -n 50 "$logfile" 2>/dev/null || msg "(Log noch nicht verfügbar)" "(Log not yet available)"
    else
      msg "(Kein Log vorhanden)" "(No log present)"
    fi

    sleep 2
  done

  echo ""
  echo "=========================================="
  msg "Backup abgeschlossen!" "Backup finished!"
  msg "Finaler Status: $(get_status)" "Final status: $(get_status)"
  echo "=========================================="
  echo ""
  systemd_summary
  echo ""
  if [[ "$LANG_CHOICE" == "de" ]]; then 
    read -rp "Drücke Enter um zurückzukehren..." _ || true
  else 
    read -rp "Press Enter to return..." _ || true
  fi
}

# =====================[ Usage / Hilfe ]======================================
print_usage() {
  if [[ "$LANG_CHOICE" == "de" ]]; then
cat <<USAGE
Erkannt:
  Systemdisk:  $DISK
  Backup-Ziel: $BACKUP_DIR

Aufruf:
  $0 backup  [--name NAME] [--compress|--no-compress] [--zstd-level N] [--encrypt|--no-encrypt] [--passfile FILE] [--post reboot|shutdown|none] [--select-backup] [--disk /dev/XYZ]
  $0 restore [--dry-run] [--select-disk] [--target /dev/sdX] [--post reboot|shutdown|none] [--passfile FILE] [--select-backup] [--disk /dev/XYZ]
  $0 verify
  $0 status  # Live-Status + systemd-Zusammenfassung
  $0         # interaktives Menü

Hinweise:
- --name NAME: Benutzerdefinierter Backup-Name (z.B. 'proxmox-host1'). Standard: Hostname
- Proxmox-VMs: QGA → fsfreeze; sonst suspend. CTs: freeze.
- Backup-Ziel: Label case-insensitive **Teilstring** (z.B. "PANZERBACKUP" matcht "panzerbackup-pm").
- Dateien: panzer_NAME_DATUM.img[.zst][.gpg] + .sha256; LATEST_OK Symlink + .sfdisk.
- Status-Tracking: Während eines Backups mit '$0 status' den Fortschritt verfolgen.
- Systemd: Falls eingerichtet, zeigt 'status' auch Timer/Service-Infos.

Beispiele:
  $0 backup --name pve-node1 --compress --encrypt
  $0 backup --name homeserver --no-encrypt --post shutdown
  BACKUP_NAME=proxmox1 $0 backup --compress
  $0 status
USAGE
  else
cat <<USAGE
Detected:
  System disk:  $DISK
  Backup dir:   $BACKUP_DIR

Usage:
  $0 backup  [--name NAME] [--compress|--no-compress] [--zstd-level N] [--encrypt|--no-encrypt] [--passfile FILE] [--post reboot|shutdown|none] [--select-backup] [--disk /dev/XYZ]
  $0 restore [--dry-run] [--select-disk] [--target /dev/sdX] [--post reboot|shutdown|none] [--passfile FILE] [--select-backup] [--disk /dev/XYZ]
  $0 verify
  $0 status  # Live status + systemd summary
  $0         # interactive menu

Notes:
- --name NAME: Custom backup name (e.g., 'proxmox-host1'). Default: hostname
- Proxmox VMs: QGA → fsfreeze; otherwise suspend. CTs: freeze.
- Backup target: label case-insensitive **substring** (e.g., "PANZERBACKUP" matches "panzerbackup-pm").
- Files: panzer_NAME_DATE.img[.zst][.gpg] + .sha256; LATEST_OK symlink + .sfdisk.
- Status tracking: Use '$0 status' during a run; also shows systemd summary if units exist.

Examples:
  $0 backup --name pve-node1 --compress --encrypt
  $0 backup --name homeserver --no-encrypt --post shutdown
  BACKUP_NAME=proxmox1 $0 backup --compress
  $0 status
USAGE
  fi
}


resume_orphans() {
  # Resume paused QEMU VMs
  if has_cmd qm; then
    while read -r id; do
      [[ -z "$id" ]] && continue
      st="$(qm status "$id" 2>/dev/null | awk '{print $2}')"
      if [[ "$st" == "paused" ]]; then
        msg "  - qm resume $id" "  - qm resume $id"
        qm resume "$id" >/dev/null 2>&1 || true
      fi
      # Try to thaw filesystems via QGA (harmless if unsupported)
      qm agent "$id" fsfreeze-thaw >/dev/null 2>&1 || true
    done < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')
  fi
  # Unfreeze any LXC containers
  if has_cmd pct; then
    while read -r ct; do
      [[ -z "$ct" ]] && continue
      msg "  - pct unfreeze $ct" "  - pct unfreeze $ct"
      pct unfreeze "$ct" >/dev/null 2>&1 || true
    done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')
  fi
}

# =====================[ Entry / Menü ]=======================================
if [[ $# -gt 0 ]]; then
  case "$1" in
    backup)
      shift; REMAINS=($(parse_backup_flags "$@"))
      if [[ -t 0 && -t 1 ]]; then
        [[ -z "${POST_ACTION_PRESET:-}" ]] && prompt_post_action "Backup"
        if [[ "${ENCRYPT_MODE}" == "off" && -z "${ENCRYPT_PASSPHRASE:-}" ]]; then prompt_encryption; fi
      fi
      do_backup ;;
    restore)
      shift; REMAINS=($(parse_restore_flags "$@"))
      if [[ -t 0 && -t 1 && -z "${POST_ACTION_PRESET:-}" ]]; then
        prompt_post_action "Restore"
      fi
      do_restore ;;
    verify)
      do_verify ;;
    status)
      show_status ;;
    help|--help|-h)
      print_usage; exit 0 ;;
    *)
      print_usage; exit 1 ;;
  esac
else
  if [[ "$LANG_CHOICE" == "de" ]]; then
    echo "Systemdisk erkannt:  $DISK"
    echo "Backup-Ziel:         $BACKUP_DIR"
    echo "1) Backup (auto-Kompression, Inhibit-Schutz)"
    echo "2) Restore letztes gültiges Backup"
    echo "3) Restore (Dry-Run/Prüfung)"
    echo "4) Backup ohne Kompression"
    echo "5) Backup mit Kompression (zstd)"
    echo "6) Restore mit Disk-Auswahl"
    echo "7) Verify letztes Backup"
    echo "8) Status anzeigen (Live-Fortschritt)"
    read -rp "Auswahl (1-8): " choice
  else
    echo "System disk: $DISK"
    echo "Backup dir:  $BACKUP_DIR"
    echo "1) Backup (auto-compression, inhibit-protection)"
    echo "2) Restore latest valid backup"
    echo "3) Restore (dry-run / verify only)"
    echo "4) Backup without compression"
    echo "5) Backup with compression (zstd)"
    echo "6) Restore with disk selection"
    echo "7) Verify latest backup"
    echo "8) Show status (live progress)"
    read -rp "Choice (1-8): " choice
  fi
  case "$choice" in
    1) COMPRESS_MODE="auto";  
       if [[ "$LANG_CHOICE" == "de" ]]; then
         read -rp "Backup-Name (z.B. 'proxmox-node1') [Standard: $(hostname -s)]: " BACKUP_NAME
       else
         read -rp "Backup name (e.g., 'proxmox-node1') [Default: $(hostname -s)]: " BACKUP_NAME
       fi
       prompt_post_action "Backup";  prompt_encryption; do_backup ;;
    2)                        prompt_post_action "Restore"; do_restore ;;
    3) RESTORE_DRY_RUN="--dry-run"; prompt_post_action "Restore"; do_restore ;;
    4) COMPRESS_MODE="off";   
       if [[ "$LANG_CHOICE" == "de" ]]; then
         read -rp "Backup-Name (z.B. 'proxmox-node1') [Standard: $(hostname -s)]: " BACKUP_NAME
       else
         read -rp "Backup name (e.g., 'proxmox-node1') [Default: $(hostname -s)]: " BACKUP_NAME
       fi
       prompt_post_action "Backup";  prompt_encryption; do_backup ;;
    5) COMPRESS_MODE="on";    
       if [[ "$LANG_CHOICE" == "de" ]]; then
         read -rp "Backup-Name (z.B. 'proxmox-node1') [Standard: $(hostname -s)]: " BACKUP_NAME
       else
         read -rp "Backup name (e.g., 'proxmox-node1') [Default: $(hostname -s)]: " BACKUP_NAME
       fi
       prompt_post_action "Backup";  prompt_encryption; do_backup ;;
    6) SELECT_DISK="true";    prompt_post_action "Restore"; do_restore ;;
    7) do_verify ;;
    8) show_status ;;
    *) if [[ "$LANG_CHOICE" == "de" ]]; then echo "Ungültige Auswahl"; else echo "Invalid selection"; fi; exit 1 ;;
  esac
fi
