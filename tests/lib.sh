#!/usr/bin/env bash
# Gemeinsame Hilfen für die Panzerbackup-Testsuite.
set -uo pipefail
TESTS_PASS=0; TESTS_FAIL=0; TESTS_SKIP=0; FAILED_NAMES=()
_c_g=""; _c_r=""; _c_y=""; _c_n=""
if [[ -t 1 ]]; then _c_g=$'\e[32m'; _c_r=$'\e[31m'; _c_y=$'\e[33m'; _c_n=$'\e[0m'; fi

ok()   { printf '  %sPASS%s  %s\n' "$_c_g" "$_c_n" "$1"; TESTS_PASS=$((TESTS_PASS+1)); }
bad()  { printf '  %sFAIL%s  %s%s\n' "$_c_r" "$_c_n" "$1" "${2:+  ($2)}"; TESTS_FAIL=$((TESTS_FAIL+1)); FAILED_NAMES+=("$1"); }
skip() { printf '  %sSKIP%s  %s%s\n' "$_c_y" "$_c_n" "$1" "${2:+  ($2)}"; TESTS_SKIP=$((TESTS_SKIP+1)); }

assert_eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "erwartet '$3', erhalten '$2'"; fi; }
assert_ok()  { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1" "Kommando schlug fehl"; fi; }
assert_nok() { if "${@:2}" >/dev/null 2>&1; then bad "$1" "Kommando war unerwartet erfolgreich"; else ok "$1"; fi; }
assert_grep(){ if grep -qE "$3" <<<"$2"; then ok "$1"; else bad "$1" "Muster '$3' nicht gefunden"; fi; }

summary() {
  echo
  echo "=============================================="
  printf '  %sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
    "$_c_g" "$TESTS_PASS" "$_c_n" "$_c_r" "$TESTS_FAIL" "$_c_n" "$_c_y" "$TESTS_SKIP" "$_c_n"
  echo "=============================================="
  if (( TESTS_FAIL > 0 )); then
    printf '  Fehlgeschlagen:\n'
    printf '    - %s\n' "${FAILED_NAMES[@]}"
    return 1
  fi
  return 0
}

# Extrahiert einen benannten Abschnitt aus panzerbackup.sh, damit einzelne
# Bausteine isoliert getestet werden können.
extract_section() {
  local script="$1" from="$2" to="$3"
  awk -v a="$from" -v b="$to" 'index($0,a)==1{p=1} p{print} p && index($0,b)==1 && NR>1 && index($0,a)!=1{exit}' "$script"
}
