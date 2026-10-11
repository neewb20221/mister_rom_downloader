#!/usr/bin/env bash
# Stage 1: magnet/torrent URI ? .torrent metadata; import .torrent files
set -uo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

_fetch_log() {
  printf '%s/fetch.log' "${META_DIR}"
}

# Full metadata refresh: drop old .torrent + catalog shards (keep dht.dat).
clear_meta_torrent_cache() {
  local f
  shopt -s nullglob
  for f in "${META_DIR}"/*.torrent; do
    rm -f "${f}"
  done
  for f in "${CATALOG_DIR}"/*.tsv "${CATALOG_DIR}"/*.cnt "${CATALOG_DIR}"/*.show.txt; do
    rm -f "${f}"
  done
  rm -f "${CATALOG_DIR}/all.tsv" "${CATALOG_DIR}/folders.idx"
}

write_empty_catalog() {
  ensure_dirs
  printf '%s\n' "${CATALOG_HEADER}" > "${CATALOG_DIR}/all.tsv"
}

# Curated trackers only ? Minerva magnets ship ~38 dead/slow ones that burn the
# whole timeout before a working announce (common on MiSTer/NAT).
BT_TRACKERS=(
  "udp://open.stealth.si:80/announce"
  "udp://tracker.torrent.eu.org:451/announce"
  "udp://exodus.desync.com:6969/announce"
  "udp://open.demonii.com:1337/announce"
  "http://tracker.files.fm:6969/announce"
  "http://tracker.opentrackr.org:1337/announce"
  "https://tracker.nanoha.org:443/announce"
)

# HTTP torrent caches ? much more reliable than magnet?peers on MiSTer
HTTP_META_CACHES=(
  "https://itorrents.org/torrent/%H%.torrent"
  "http://itorrents.org/torrent/%H%.torrent"
  "https://btcache.me/torrent/%h%"
  "http://btcache.me/torrent/%h%"
)

bt_tracker_csv() {
  local IFS=','
  printf '%s' "${BT_TRACKERS[*]}"
}

# Build a clean magnet: infohash + dn + curated trackers only
clean_magnet_uri() {
  local hash="$1" dn="${2:-torrent}" t enc uri
  uri="magnet:?xt=urn:btih:${hash}&dn=${dn}"
  for t in "${BT_TRACKERS[@]}"; do
    enc="$(printf '%s' "${t}" | sed 's/:/%3A/g; s/\//%2F/g')"
    uri="${uri}&tr=${enc}"
  done
  printf '%s' "${uri}"
}

# Kill leftover aria2c from this app (MiSTer has no pgrep)
kill_aria2_orphans() {
  local pids pid
  pids="$(ps 2>/dev/null | grep -F "${ARIA2}" | grep -v grep | awk '{print $1}' || true)"
  for pid in ${pids}; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    kill "${pid}" 2>/dev/null || true
  done
  sleep 0.3
  pids="$(ps 2>/dev/null | grep -F "${ARIA2}" | grep -v grep | awk '{print $1}' || true)"
  for pid in ${pids}; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    kill -9 "${pid}" 2>/dev/null || true
  done
}

# True if .torrent has usable info (not an aria2 incomplete "dynamic metainfo" stub).
torrent_meta_usable() {
  local f="$1"
  [[ -s "${f}" ]] || return 1
  # go.torrent / incomplete magnet stubs ? aria2 errorCode=25 Bencode decoding failed
  if head -c 200 "${f}" 2>/dev/null | grep -q 'dynamic metainfo'; then
    return 1
  fi
  # Real torrents have info dict + pieces; stubs often only have comment/created by.
  grep -aq '4:info' "${f}" 2>/dev/null || return 1
  grep -aq '6:pieces' "${f}" 2>/dev/null || return 1
  return 0
}

# Run aria2 (optionally under timeout) in background; poll UI cancel.
# Return 0=ok, 1=fail, 2=cancelled. Must NOT be called via $(...).
_fetch_aria2_bg() {
  local timeout_sec="$1"
  shift
  local pid wr=0 logf
  logf="$(_fetch_log)"
  if (( timeout_sec > 0 )) && command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_sec}" "${ARIA2}" "$@" >>"${logf}" 2>&1 &
  else
    "${ARIA2}" "$@" >>"${logf}" 2>&1 &
  fi
  pid=$!
  if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
    ui_wait_pid_abortable "${pid}" aria2
    wr=$?
  else
    wait "${pid}" || wr=1
    (( wr != 0 )) && wr=1
  fi
  (( wr == 2 )) && return 2
  (( wr == 0 )) && return 0
  return 1
}

# Fast path: download .torrent by infohash from public caches
# Return 0=hit, 1=miss/fail, 2=cancelled
fetch_meta_http_cache() {
  local hash="$1" dest="$2"
  local hashu tmpl url tmp wr n="${#HTTP_META_CACHES[@]}" i=0 host
  hashu="$(printf '%s' "${hash}" | tr 'a-z' 'A-Z')"
  tmp="${META_DIR}/.http_meta_$$.torrent"
  mkdir -p "${META_DIR}"

  for tmpl in "${HTTP_META_CACHES[@]}"; do
    i=$((i + 1))
    url="${tmpl//%H%/${hashu}}"
    url="${url//%h%/${hash}}"
    rm -f "${tmp}"
    host="${url#*://}"; host="${host%%/*}"
    log "http cache: ${url}"
    if [[ "${UI_ACTIVE:-0}" == "1" && "${UI_PROGRESS_ACTIVE:-0}" == "1" ]]; then
      # Keep bar position; refresh label so UI does not look frozen between items
      printf '\e[%d;%dH%s%-*.*s%s' $((UI_PROGRESS_MY + 2)) $((UI_PROGRESS_MX + 3)) \
        "${UI_PANEL}" $((UI_PROGRESS_MW - 6)) $((UI_PROGRESS_MW - 6)) \
        "$(ui_fit $((UI_PROGRESS_MW - 6)) "HTTP ${i}/${n}: ${host}")" "${UI_RST}"
      ui_activity_tick
    fi
    # follow-torrent=false: otherwise aria2 treats the saved .torrent as a
    # download job and starts pulling game files into meta/
    _fetch_aria2_bg 25 \
      --allow-overwrite=true \
      --auto-file-renaming=false \
      --follow-torrent=false \
      --dir="${META_DIR}" \
      --out=".http_meta_$$.torrent" \
      --max-tries=1 \
      --timeout=12 \
      --connect-timeout=8 \
      --console-log-level=warn \
      --summary-interval=0 \
      --disable-ipv6=true \
      "${url}"
    wr=$?
    (( wr == 2 )) && { rm -f "${tmp}"; return 2; }
    if torrent_meta_usable "${tmp}"; then
      mv -f "${tmp}" "${dest}"
      log "http cache hit ? ${dest}"
      return 0
    fi
    rm -f "${tmp}"
  done
  return 1
}

# Slow path: magnet metadata via peers/trackers/DHT
# Return 0=ok, 1=fail, 2=cancelled
fetch_meta_magnet() {
  local hash="$1" dest="$2" dn="${3:-torrent}"
  local uri wr=0
  uri="$(clean_magnet_uri "${hash}" "${dn}")"
  kill_aria2_orphans

  log "magnet metadata for ${hash} ..."
  if [[ "${UI_ACTIVE:-0}" == "1" && "${UI_PROGRESS_ACTIVE:-0}" == "1" ]]; then
    printf '\e[%d;%dH%s%-*.*s%s' $((UI_PROGRESS_MY + 2)) $((UI_PROGRESS_MX + 3)) \
      "${UI_PANEL}" $((UI_PROGRESS_MW - 6)) $((UI_PROGRESS_MW - 6)) \
      "$(ui_fit $((UI_PROGRESS_MW - 6)) "Magnet/DHT: ${dn}")" "${UI_RST}"
    ui_activity_tick
  fi
  _fetch_aria2_bg 120 \
    --conf-path="${ARIA2_CONF}" \
    --dir="${META_DIR}" \
    --dht-file-path="${META_DIR}/dht.dat" \
    --bt-metadata-only=true \
    --bt-save-metadata=true \
    --bt-load-saved-metadata=true \
    --seed-ratio=0.0 \
    --seed-time=0 \
    --max-upload-limit=0 \
    --bt-stop-timeout=90 \
    --bt-tracker="$(bt_tracker_csv)" \
    --disable-ipv6=true \
    --enable-dht=true \
    --enable-peer-exchange=true \
    --bt-enable-lpd=false \
    --dht-entry-point=router.bittorrent.com:6881 \
    --dht-entry-point=dht.transmissionbt.com:6881 \
    --dht-entry-point=router.utorrent.com:6881 \
    --listen-port=6881-6999 \
    --dht-listen-port=6881-6999 \
    --connect-timeout=10 \
    --timeout=15 \
    --max-tries=2 \
    --console-log-level=notice \
    --summary-interval=0 \
    "${uri}"
  wr=$?
  kill_aria2_orphans
  (( wr == 2 )) && return 2

  if [[ -f "${dest}" ]]; then
    return 0
  fi
  local found
  found="$(find "${META_DIR}" -maxdepth 1 -type f -iname "${hash}.torrent" 2>/dev/null | head -n1 || true)"
  if [[ -n "${found}" && "${found}" != "${dest}" ]]; then
    mv -f "${found}" "${dest}"
    return 0
  fi
  return 1
}

# Return 0=ok, 1=fail, 2=cancelled
fetch_one() {
  local magnet_file="$1"
  local uri hash dest dn wr
  uri="$(read_magnet_uri "${magnet_file}" 2>/dev/null || true)"
  if [[ -z "${uri}" ]]; then
    warn "empty torrent source: ${magnet_file}"
    return 1
  fi
  if [[ "${uri}" != magnet:?* ]]; then
    warn "not a magnet URI in ${magnet_file}"
    return 1
  fi

  hash="$(magnet_hash "${uri}" || true)"
  if [[ -z "${hash}" ]]; then
    hash="$(magnet_basename "${magnet_file}")"
  fi
  hash="${hash,,}"
  dn="$(printf '%s' "${uri}" | sed -n 's/.*[&?]dn=\([^&]*\).*/\1/p')"
  [[ -z "${dn}" ]] && dn="torrent"

  dest="${META_DIR}/${hash}.torrent"
  if torrent_meta_usable "${dest}"; then
    log "metadata exists: ${dest}"
    return 0
  fi
  # Drop incomplete aria2 stubs so we actually re-fetch
  if [[ -f "${dest}" ]]; then
    warn "removing unusable stub meta: ${dest}"
    rm -f "${dest}"
  fi

  mkdir -p "${META_DIR}"
  kill_aria2_orphans

  log "fetching metadata for ${magnet_file##*/} ..."
  fetch_meta_http_cache "${hash}" "${dest}"
  wr=$?
  (( wr == 0 )) && return 0
  (( wr == 2 )) && return 2
  fetch_meta_magnet "${hash}" "${dest}" "${dn}"
  wr=$?
  (( wr == 0 )) && { log "saved ${dest}"; return 0; }
  (( wr == 2 )) && return 2

  warn "metadata not saved for ${magnet_file##*/}"
  return 1
}

# Resolve meta key (infohash / torrent basename) for a source file.
source_meta_key() {
  local f="$1" typ="${2:-}" uri hash base
  if [[ -z "${typ}" ]]; then
    case "${f}" in
      *.torrent|*.TORRENT) typ=file ;;
      *) typ=torrent ;;
    esac
  fi
  if [[ "${typ}" == "file" ]]; then
    base="${f##*/}"
    base="${base%.torrent}"
    base="${base%.TORRENT}"
    printf '%s' "${base}"
    return 0
  fi
  uri="$(read_magnet_uri "${f}" 2>/dev/null || true)"
  hash="$(magnet_hash "${uri}" 2>/dev/null || true)"
  if [[ -z "${hash}" ]]; then
    hash="$(magnet_basename "${f}")"
  fi
  printf '%s' "${hash,,}"
}

# Drop .torrent + catalog shards that are no longer enabled.
prune_disabled_meta() {
  local -A want=()
  local f key base tsv show
  local -a mags=() tors=()
  while IFS= read -r f; do [[ -n "${f}" ]] && mags+=("${f}"); done < <(enabled_magnet_files || true)
  while IFS= read -r f; do [[ -n "${f}" ]] && tors+=("${f}"); done < <(enabled_torrent_files || true)
  for f in "${mags[@]}"; do
    key="$(source_meta_key "${f}" torrent)"
    [[ -n "${key}" ]] && want["${key}"]=1
  done
  for f in "${tors[@]}"; do
    key="$(source_meta_key "${f}" file)"
    [[ -n "${key}" ]] && want["${key}"]=1
  done

  shopt -s nullglob
  for f in "${META_DIR}"/*.torrent; do
    base="${f##*/}"
    base="${base%.torrent}"
    if [[ -z "${want[${base}]+x}" ]]; then
      log "prune disabled meta: ${base}"
      rm -f "${f}"
      tsv="${CATALOG_DIR}/${base}.tsv"
      show="${CATALOG_DIR}/${base}.show.txt"
      rm -f "${tsv}" "${show}" "${CATALOG_DIR}/${base}.cnt"
    fi
  done
  for tsv in "${CATALOG_DIR}"/*.tsv; do
    base="${tsv##*/}"
    [[ "${base}" == "all.tsv" ]] && continue
    base="${base%.tsv}"
    if [[ ! -f "${META_DIR}/${base}.torrent" ]]; then
      log "prune orphan catalog: ${base}"
      rm -f "${tsv}" "${CATALOG_DIR}/${base}.show.txt" "${CATALOG_DIR}/${base}.cnt"
    fi
  done
}

# Incremental: keep meta/catalog for torrents that stay enabled; fetch/index only diffs.
# Returns 0 ok, 1 fail, 2 cancelled.
sync_enabled_metadata() {
  ensure_dirs
  kill_aria2_orphans
  [[ "$(type -t enabled_magnet_files 2>/dev/null)" == "function" ]] \
    || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/torrent_sources.sh"
  [[ "$(type -t catalog_one 2>/dev/null)" == "function" ]] \
    || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_catalog.sh"

  prune_disabled_meta

  local -a mags=() tors=() need_catalog=()
  local f total cur label use_ui=0 failed=0 key dest rc name cat_failed=0
  while IFS= read -r f; do [[ -n "${f}" ]] && mags+=("${f}"); done < <(enabled_magnet_files || true)
  while IFS= read -r f; do [[ -n "${f}" ]] && tors+=("${f}"); done < <(enabled_torrent_files || true)

  total=$(( ${#mags[@]} + ${#tors[@]} ))
  if (( total == 0 )); then
    write_empty_catalog
    rebuild_folders_idx 2>/dev/null || true
    log "no enabled torrent sources ? metadata/catalog cleared"
    return 0
  fi

  need_aria2 || return 1

  [[ "${UI_ACTIVE:-0}" == "1" ]] && use_ui=1
  cur=0
  : >"$(_fetch_log)"

  for f in "${mags[@]}"; do
    if (( use_ui )); then ui_activity_tick; fi
    if (( use_ui )) && ui_user_wants_abort; then
      kill_aria2_orphans
      ui_progress_done
      UI_QUIET=0
      return 2
    fi
    cur=$((cur + 1))
    name="${f##*/}"
    key="$(source_meta_key "${f}" torrent)"
    dest="${META_DIR}/${key}.torrent"
    if torrent_meta_usable "${dest}"; then
      log "skip unchanged: ${name}"
      if [[ ! -s "${CATALOG_DIR}/${key}.tsv" ]]; then
        need_catalog+=("${dest}")
      fi
      if (( use_ui )); then
        ui_progress_paint "Sync Metadata" "${cur}" "${total}" "Keep: ${name}"
      fi
      continue
    fi
    # Broken stub from a previous incomplete fetch ? remove and re-download
    [[ -f "${dest}" ]] && rm -f "${dest}"
    label="Torrent: ${name}"
    if (( use_ui )); then
      ui_progress_paint "Sync Metadata" "${cur}" "${total}" "${label}"
    else
      log "[${cur}/${total}] ${label}"
    fi
    fetch_one "${f}"
    rc=$?
    if (( rc == 2 )); then
      kill_aria2_orphans
      ui_progress_done
      UI_QUIET=0
      return 2
    fi
    if (( rc == 0 )); then
      need_catalog+=("${META_DIR}/${key}.torrent")
    else
      failed=$((failed + 1))
    fi
  done

  for f in "${tors[@]}"; do
    if (( use_ui )); then ui_activity_tick; fi
    if (( use_ui )) && ui_user_wants_abort; then
      kill_aria2_orphans
      ui_progress_done
      UI_QUIET=0
      return 2
    fi
    cur=$((cur + 1))
    name="${f##*/}"
    key="$(source_meta_key "${f}" file)"
    dest="${META_DIR}/${key}.torrent"
    if [[ -f "${dest}" ]] && cmp -s "${f}" "${dest}" 2>/dev/null; then
      log "skip unchanged: ${name}"
      if [[ ! -s "${CATALOG_DIR}/${key}.tsv" ]]; then
        need_catalog+=("${dest}")
      fi
      if (( use_ui )); then
        ui_progress_paint "Sync Metadata" "${cur}" "${total}" "Keep: ${name}"
      fi
      continue
    fi
    label="Torrent file: ${name}"
    if (( use_ui )); then
      ui_progress_paint "Sync Metadata" "${cur}" "${total}" "${label}"
    else
      log "[${cur}/${total}] ${label}"
    fi
    if import_torrent_to_meta "${f}"; then
      need_catalog+=("${dest}")
    else
      failed=$((failed + 1))
    fi
  done

  kill_aria2_orphans
  log "sync: kept/fetched ${total}, new/changed=${#need_catalog[@]}, failed=${failed}"

  # Index only torrents that need a catalog shard; leave unchanged alone.
  CATALOG_SKIP_EXISTING=1
  CATALOG_NO_ALL_APPEND=1
  cur=0
  total=${#need_catalog[@]}
  for f in "${need_catalog[@]}"; do
    [[ -f "${f}" ]] || continue
    if (( use_ui )); then ui_activity_tick; fi
    if (( use_ui )) && ui_user_wants_abort; then
      unset CATALOG_SKIP_EXISTING CATALOG_NO_ALL_APPEND
      ui_progress_done
      UI_QUIET=0
      return 2
    fi
    cur=$((cur + 1))
    name="${f##*/}"
    if (( use_ui )) && (( total > 0 )); then
      ui_progress_paint "Sync Catalog" "${cur}" "${total}" "Indexing ${name}"
    fi
    catalog_one "${f}"
    rc=$?
    if (( rc == 2 )); then
      unset CATALOG_SKIP_EXISTING CATALOG_NO_ALL_APPEND
      (( use_ui )) && ui_progress_done
      UI_QUIET=0
      return 2
    fi
    (( rc != 0 )) && cat_failed=$((cat_failed + 1))
  done
  unset CATALOG_SKIP_EXISTING CATALOG_NO_ALL_APPEND

  if (( use_ui )); then
    ui_progress_paint "Sync Catalog" 0 1 "Merging catalog shards..."
  fi
  rebuild_all_tsv_from_shards
  rc=$?
  if (( rc == 2 )); then
    (( use_ui )) && ui_progress_done
    UI_QUIET=0
    return 2
  fi
  if (( use_ui )); then
    ui_progress_paint "Sync Catalog" 1 1 "Building folder index..."
  fi
  rebuild_folders_idx
  rc=$?
  if (( rc == 2 )); then
    (( use_ui )) && ui_progress_done
    UI_QUIET=0
    return 2
  fi

  if (( use_ui )); then
    ui_progress_done
    ui_drain_keys
  fi
  local src_total=$(( ${#mags[@]} + ${#tors[@]} ))
  # All sources failed and nothing kept usable
  if (( src_total > 0 && failed == src_total )); then
    shopt -s nullglob
    local left=( "${META_DIR}"/*.torrent )
    (( ${#left[@]} == 0 )) && return 1
  fi
  (( cat_failed > 0 && ${#need_catalog[@]} > 0 && cat_failed == ${#need_catalog[@]} )) && return 1
  return 0
}

# Full refresh (clears meta/catalog) unless mode=incremental.
fetch_all() {
  local mode="${1:-full}"
  if [[ "${mode}" == "incremental" ]]; then
    sync_enabled_metadata
    return $?
  fi

  ensure_dirs
  # Full refresh: replace previous metadata/catalog.
  clear_meta_torrent_cache
  kill_aria2_orphans
  [[ "$(type -t enabled_magnet_files 2>/dev/null)" == "function" ]] \
    || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/torrent_sources.sh"

  local -a mags=() tors=()
  local f total cur label use_ui=0 failed=0 rc
  while IFS= read -r f; do [[ -n "${f}" ]] && mags+=("${f}"); done < <(enabled_magnet_files || true)
  while IFS= read -r f; do [[ -n "${f}" ]] && tors+=("${f}"); done < <(enabled_torrent_files || true)

  total=$(( ${#mags[@]} + ${#tors[@]} ))
  if (( total == 0 )); then
    write_empty_catalog
    log "no enabled torrent sources ? metadata/catalog cleared"
    return 0
  fi

  need_aria2 || return 1

  [[ "${UI_ACTIVE:-0}" == "1" ]] && use_ui=1
  cur=0
  : >"$(_fetch_log)"

  for f in "${mags[@]}"; do
    if (( use_ui )); then ui_activity_tick; fi
    if (( use_ui )) && ui_user_wants_abort; then
      kill_aria2_orphans
      ui_progress_done
      UI_QUIET=0
      return 2
    fi
    cur=$((cur + 1))
    label="Torrent: ${f##*/}"
    if (( use_ui )); then
      ui_progress_paint "Update Metadata" "${cur}" "${total}" "${label}"
    else
      log "[${cur}/${total}] ${label}"
    fi
    fetch_one "${f}"
    rc=$?
    if (( rc == 2 )); then
      kill_aria2_orphans
      ui_progress_done
      UI_QUIET=0
      return 2
    fi
    (( rc != 0 )) && failed=$((failed + 1))
  done

  for f in "${tors[@]}"; do
    if (( use_ui )); then ui_activity_tick; fi
    if (( use_ui )) && ui_user_wants_abort; then
      kill_aria2_orphans
      ui_progress_done
      UI_QUIET=0
      return 2
    fi
    cur=$((cur + 1))
    label="Torrent file: ${f##*/}"
    if (( use_ui )); then
      ui_progress_paint "Update Metadata" "${cur}" "${total}" "${label}"
    else
      log "[${cur}/${total}] ${label}"
    fi
    import_torrent_to_meta "${f}" || failed=$((failed + 1))
  done

  kill_aria2_orphans
  log "done: ${#mags[@]} magnet URI(s), ${#tors[@]} .torrent file(s), failed=${failed}"
  if (( use_ui )); then
    ui_progress_done
    ui_drain_keys
  fi
  (( failed == total )) && return 1
  return 0
}

# Mode: full (default, Update Metadata) | incremental (Edit Files flags)
update_metadata_and_catalog() {
  local mode="${1:-full}" rc=0 fr
  local -a tors=()
  UI_QUIET=1

  if [[ "${mode}" == "incremental" ]]; then
    sync_enabled_metadata
    fr=$?
    if (( fr == 2 )); then
      UI_QUIET=0
      [[ "${UI_ACTIVE:-0}" == "1" ]] && ui_msgbox "Sync Metadata" "Cancelled."
      return 2
    fi
    if (( fr != 0 )); then
      UI_QUIET=0
      if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
        ui_msgbox "Sync Metadata" "Some new sources failed. Unchanged torrents were kept."
      fi
    fi
    shopt -s nullglob
    tors=( "${META_DIR}"/*.torrent )
    if (( ${#tors[@]} == 0 )); then
      write_empty_catalog
      UI_QUIET=0
      return 0
    fi
    # User-owned magnet/torrent filenames in magnets/ are left untouched.
    UI_QUIET=0
    return "${fr}"
  fi

  fetch_all full
  fr=$?
  if (( fr == 2 )); then
    UI_QUIET=0
    [[ "${UI_ACTIVE:-0}" == "1" ]] && ui_msgbox "Update Metadata" "Cancelled."
    return 2
  fi
  if (( fr != 0 )); then
    # Fetch failed after clear ? keep catalog empty so UI matches disk.
    write_empty_catalog
    UI_QUIET=0
    if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
      ui_msgbox "Update Metadata" "No metadata downloaded. Check network/trackers or enable sources."
    fi
    return 1
  fi

  shopt -s nullglob
  tors=( "${META_DIR}"/*.torrent )
  if (( ${#tors[@]} == 0 )); then
    write_empty_catalog
    UI_QUIET=0
    return 0
  fi

  [[ "$(type -t build_all 2>/dev/null)" == "function" ]] \
    || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_catalog.sh"

  build_all
  fr=$?
  if (( fr == 2 )); then
    UI_QUIET=0
    [[ "${UI_ACTIVE:-0}" == "1" ]] && ui_msgbox "Build Catalog" "Cancelled."
    return 2
  fi
  if (( fr != 0 )); then
    rc=1
    write_empty_catalog
    if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
      ui_progress_done
      ui_msgbox "Build Catalog" "No .torrent metadata yet. Try Update Metadata again."
      return 1
    fi
  fi
  # User-owned magnet/torrent filenames in magnets/ are left untouched.
  UI_QUIET=0
  return "${rc}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  fetch_all
fi
