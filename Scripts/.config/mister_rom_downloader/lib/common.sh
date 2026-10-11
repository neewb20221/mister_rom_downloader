#!/usr/bin/env bash
# no set -e: callers (TUI) rely on false ((arith)) / cancel paths
set -uo pipefail

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${_lib_dir}/.." && pwd)"
# shellcheck source=/dev/null
source "${APP_DIR}/config.env"

# Ensure APP_DIR/ARIA2 point at this install even if config was sourced oddly
APP_DIR="$(cd "${_lib_dir}/.." && pwd)"
APP_ID="mister_rom_downloader"
APP_TITLE="MiSTer ROM downloader"
APP_VERSION="1.0.0"
if [[ -f "${APP_DIR}/VERSION" ]]; then
  APP_VERSION="$(tr -d '[:space:]' < "${APP_DIR}/VERSION" 2>/dev/null || true)"
  [[ -n "${APP_VERSION}" ]] || APP_VERSION="1.0.0"
fi
ARIA2="${APP_DIR}/bin/aria2c"
ARIA2_CONF="${APP_DIR}/aria2.conf"
CORES_FILE="${APP_DIR}/cores.txt"
MAGNETS_DIR="${APP_DIR}/magnets"
META_DIR="${APP_DIR}/meta"
CATALOG_DIR="${APP_DIR}/catalog"
SELECTION_DIR="${APP_DIR}/selection"
INBOX_DIR="${APP_DIR}/inbox"
DATS_DIR="${APP_DIR}/dats"
QUEUE_FILE="${SELECTION_DIR}/queue.tsv"
GAMES_ROOT="${MISTER_ROOT:-/media/fat}/games"

# Header / chrome title with version (e.g. "MiSTer ROM DOWNLOADER  v1.0.0")
app_title_ver() {
  printf '%s  v%s' "${APP_TITLE}" "${APP_VERSION}"
}

# UI_QUIET=1 hides log/warn noise so TUI progress is not overwritten
log()  { [[ "${UI_QUIET:-0}" == "1" ]] && return 0; printf '[*] %s\n' "$*"; }
warn() { [[ "${UI_QUIET:-0}" == "1" ]] && return 0; printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

need_aria2() {
  if [[ -f "${ARIA2}" && ! -x "${ARIA2}" ]]; then
    chmod +x "${ARIA2}" 2>/dev/null || true
  fi
  if [[ ! -x "${ARIA2}" ]]; then
    warn "aria2c not found/executable: ${ARIA2}"
    return 1
  fi
  return 0
}

ensure_dirs() {
  mkdir -p \
    "${MAGNETS_DIR}" \
    "${META_DIR}" \
    "${CATALOG_DIR}" \
    "${SELECTION_DIR}" \
    "${INBOX_DIR}" \
    "${DATS_DIR}" \
    "${GAMES_ROOT}"
}

read_magnet_uri() {
  local f="$1"
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { print; exit }
  ' "${f}"
}

magnet_basename() {
  basename "$1" | sed -E 's/\.(magnet|txt|MAGNET|TXT)$//'
}

magnet_hash() {
  local uri="$1"
  if [[ "${uri}" =~ xt=urn:btih:([A-Za-z0-9]+) ]]; then
    local h="${BASH_REMATCH[1]}"
    if [[ "${#h}" -eq 40 ]]; then
      printf '%s\n' "${h,,}"
    else
      printf '%s\n' "${h}"
    fi
  else
    return 1
  fi
}

pause() {
  read -r -p "Press Enter..." _
}
