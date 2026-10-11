#!/usr/bin/env bash
# MiSTer ROM DOWNLOADER ? Steel Sky style TUI
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/ui.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/fetch_meta.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/build_catalog.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/browse.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/map_targets.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/download.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/dat_sources.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/torrent_sources.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/search_ui.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/options.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/space_ui.sh"

pause() { ui_pause; }

main_status_line() {
  # Torrent Files = source magnets/.torrent in magnets/
  # Metadata Entries = file paths indexed from torrent metadata (catalog)
  # DAT Entries = <rom> records inside downloaded .dat files (cached)
  local torrents=0 meta_entries=0 dat_entries=0
  local f n cache stamp cur
  shopt -s nullglob
  local s=(
    "${MAGNETS_DIR}"/*.magnet "${MAGNETS_DIR}"/*.MAGNET
    "${MAGNETS_DIR}"/*.txt "${MAGNETS_DIR}"/*.TXT
    "${MAGNETS_DIR}"/*.torrent "${MAGNETS_DIR}"/*.TORRENT
  )
  torrents=${#s[@]}
  if [[ -f "${CATALOG_DIR}/all.tsv" ]]; then
    meta_entries=$(($(wc -l < "${CATALOG_DIR}/all.tsv") - 1))
    (( meta_entries < 0 )) && meta_entries=0
  fi

  cache="${DATS_DIR}/.entry_count"
  stamp="${DATS_DIR}/.entry_stamp"
  cur="$(ls -1 "${DATS_DIR}"/*.dat "${DATS_DIR}"/*.DAT 2>/dev/null | cksum 2>/dev/null | awk '{print $1$2}')"
  if [[ -n "${cur}" && -f "${cache}" && -f "${stamp}" && "$(cat "${stamp}" 2>/dev/null)" == "${cur}" ]]; then
    dat_entries="$(cat "${cache}" 2>/dev/null || echo 0)"
  else
    dat_entries=0
    for f in "${DATS_DIR}"/*.dat "${DATS_DIR}"/*.DAT; do
      [[ -f "${f}" ]] || continue
      n="$(grep -cE '<rom[ >/]' "${f}" 2>/dev/null || true)"
      [[ "${n}" =~ ^[0-9]+$ ]] || n=0
      if (( n == 0 )); then
        n="$(grep -cE '<game[ >/]|<machine[ >/]' "${f}" 2>/dev/null || true)"
        [[ "${n}" =~ ^[0-9]+$ ]] || n=0
      fi
      dat_entries=$((dat_entries + n))
    done
    if [[ -n "${cur}" ]]; then
      printf '%s\n' "${dat_entries}" > "${cache}"
      printf '%s\n' "${cur}" > "${stamp}"
    fi
  fi
  [[ "${dat_entries}" =~ ^[0-9]+$ ]] || dat_entries=0

  printf 'Torrent Files:%s  Metadata Entries:%s  DAT Entries:%s' \
    "${torrents}" "${meta_entries}" "${dat_entries}"
}

main_menu() {
  ensure_dirs
  ensure_dat_sources_conf

  local st
  st="$(main_status_line)"

  local -a items=(
    "S|Search|Find ROMs in torrent file trees"
    "T|Torrent Files|Update metadata / manage torrents"
    "D|DAT Files|Update / enable / paths"
    "A|Space Analyzer|See what fills the SD card"
    "O|Options|Clear torrents, DATs, temp files"
    "E|Exit|"
  )

  if ! ui_setup_menu \
    "$(app_title_ver)" \
    "${st}" \
    "Setup Menu" \
    "${items[@]}"; then
    return 1
  fi

  case "${UI_MENU_RESULT}" in
    0) search_ui || true ;;
    1) magnet_files_menu || true ;;
    2) dat_settings_menu || true ;;
    3) space_analyzer_ui || true ;;
    4) options_menu || true ;;
    5) return 1 ;;
  esac
  return 0
}

ui_init
while main_menu; do
  :
done
# EXIT trap (ui_exit_cleanup) kills children + restores TTY ? same as Ctrl+C
exit 0
