#!/usr/bin/env bash
# Options / maintenance: clear torrents, DATs, temp files
set -uo pipefail

options_stop_workers() {
  # Stop app aria2 so files are not locked mid-wipe
  killall aria2c 2>/dev/null || true
  if [[ -x "${ARIA2}" ]]; then
    killall "$(basename "${ARIA2}")" 2>/dev/null || true
  fi
  sleep 0.2
}

# Remove file/dir; increment OPTIONS_REMOVED
options_rm() {
  local p="$1"
  [[ -e "${p}" || -L "${p}" ]] || return 0
  rm -rf "${p}" 2>/dev/null || true
  OPTIONS_REMOVED=$((OPTIONS_REMOVED + 1))
}

options_rm_glob() {
  local f
  shopt -s nullglob
  for f in "$@"; do
    options_rm "${f}"
  done
}

# 1) magnets + meta torrents + catalog index (+ download queue)
options_clear_torrents_and_db() {
  local f base
  OPTIONS_REMOVED=0
  options_stop_workers
  ensure_dirs

  shopt -s nullglob
  for f in "${MAGNETS_DIR}"/*; do
    [[ -f "${f}" || -L "${f}" ]] || continue
    base="$(basename "${f}")"
    case "${base}" in
      README.md|README.MD|readme.md|.gitkeep) continue ;;
    esac
    options_rm "${f}"
  done

  for f in "${META_DIR}"/*; do
    [[ -e "${f}" ]] || continue
    base="$(basename "${f}")"
    case "${base}" in
      dht.dat|README.md|README.MD|readme.md|.gitkeep) continue ;;
    esac
    options_rm "${f}"
  done

  for f in "${CATALOG_DIR}"/*; do
    [[ -e "${f}" ]] || continue
    base="$(basename "${f}")"
    case "${base}" in
      README.md|README.MD|readme.md|.gitkeep) continue ;;
    esac
    options_rm "${f}"
  done

  options_rm "${QUEUE_FILE}"
  options_rm_glob "${SELECTION_DIR}"/*.tsv "${SELECTION_DIR}"/*.tmp

  if declare -F write_empty_catalog >/dev/null 2>&1; then
    write_empty_catalog
  fi
}

# 2) downloaded .dat + entry/cache stamps (keep dat_sources.conf)
options_clear_dats_and_db() {
  local f base
  OPTIONS_REMOVED=0
  options_stop_workers
  ensure_dirs

  shopt -s nullglob
  for f in "${DATS_DIR}"/* "${DATS_DIR}"/.*; do
    [[ -e "${f}" ]] || continue
    base="$(basename "${f}")"
    case "${base}" in
      .|..|README.md|README.MD|readme.md|.gitkeep) continue ;;
    esac
    # Keep nothing else under dats/ - conf lives in APP_DIR
    options_rm "${f}"
  done
}

# 3) incomplete downloads, caches, logs, inbox work trees
options_clear_temp_files() {
  local f
  OPTIONS_REMOVED=0
  options_stop_workers
  ensure_dirs

  shopt -s nullglob
  options_rm_glob \
    "${DATS_DIR}"/*.partial \
    "${DATS_DIR}"/*.partial.aria2 \
    "${DATS_DIR}"/*.aria2 \
    "${DATS_DIR}"/.gh_list_cache \
    "${DATS_DIR}"/.gh_list_key \
    "${DATS_DIR}"/.gh_list_cache.partial \
    "${DATS_DIR}"/.api_* \
    "${DATS_DIR}"/download.log \
    "${DATS_DIR}"/aria_test* \
    "${META_DIR}"/.http_meta_* \
    "${META_DIR}"/*.tmp \
    "${META_DIR}"/*.partial \
    "${META_DIR}"/*.aria2 \
    "${META_DIR}"/fetch.log \
    "${INBOX_DIR}"/*.log \
    "${INBOX_DIR}"/*.aria2 \
    "${INBOX_DIR}"/*.partial \
    "${APP_DIR}"/*.tmp \
    "${APP_DIR}"/ui_stderr.log

  # Inbox work directories from cancelled downloads
  for f in "${INBOX_DIR}"/*; do
    [[ -e "${f}" ]] || continue
    options_rm "${f}"
  done

  # Stray aria2 control files under games (best-effort, shallow)
  if [[ -d "${GAMES_ROOT}" ]]; then
    find "${GAMES_ROOT}" -maxdepth 3 \( -name '*.aria2' -o -name '*.partial' \) -type f -delete 2>/dev/null || true
  fi
}

options_confirm_and_run() {
  local title="$1" warn="$2" action="$3"
  local n pid rc=0
  if ! ui_okcancel "${title}" "${warn}"; then
    return 1
  fi
  if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
    ui_progress_paint "${title}" 0 1 "Working..."
    "${action}" &
    pid=$!
    ui_wait_pid_abortable "${pid}"
    rc=$?
    if (( rc == 2 )); then
      ui_progress_done
      ui_msgbox "${title}" "Cancelled."
      return 2
    fi
    ui_progress_done
  else
    "${action}" || rc=$?
  fi
  n="${OPTIONS_REMOVED:-0}"
  if (( rc != 0 )); then
    ui_msgbox "${title}" "Finished with errors. Removed ${n} item(s)."
    return 1
  fi
  ui_msgbox "${title}" "Done. Removed ${n} item(s)."
  return 0
}

options_menu() {
  ensure_dirs
  while true; do
    local -a items=(
      "C|Clear Torrents + DB|Delete magnets/torrents, meta and catalog"
      "|Clear DAT Files + DB|Delete downloaded .dat files and DAT cache"
      "|Clear Temp Files|Partials, inbox, caches, logs"
      "B|Back|"
    )
    if ! ui_setup_menu \
      "$(app_title_ver)" \
      "Maintenance" \
      "Options" \
      "${items[@]}"; then
      return 0
    fi
    case "${UI_MENU_RESULT}" in
      0)
        options_confirm_and_run "Clear Torrents + DB" \
          "WARNING: This deletes ALL magnet/torrent files in magnets/, all meta/*.torrent, and the whole catalog index. Downloaded games on the SD are NOT deleted. Continue?" \
          options_clear_torrents_and_db || true
        ;;
      1)
        options_confirm_and_run "Clear DAT Files + DB" \
          "WARNING: This deletes ALL downloaded .dat files and DAT entry cache under dats/. Source settings in dat_sources.conf are kept. Continue?" \
          options_clear_dats_and_db || true
        ;;
      2)
        options_confirm_and_run "Clear Temp Files" \
          "Delete temporary/incomplete files: .partial, .aria2, inbox work dirs, DAT/GitHub caches and logs. Continue?" \
          options_clear_temp_files || true
        ;;
      3) return 0 ;;
    esac
  done
}
