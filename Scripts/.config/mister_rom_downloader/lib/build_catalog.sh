#!/usr/bin/env bash
# Stage 2: .torrent ? searchable TSV catalog
set -uo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Typical aria2 --show-files block:
#   1|folder/game.nes
#    |131072 (128.0KiB)
# Awk program shared so catalog_one can background the real awk PID (cancel works).
CATALOG_PARSE_AWK='
  BEGIN { idx=""; path="" }
  /^ *=+/ { next }
  /^idx\|/ { next }
  /^[ \t]*[0-9]+\|/ {
    line=$0
    sub(/^[ \t]+/, "", line)
    split(line, p, "|")
    idx=p[1]
    path=p[2]
    gsub(/^[ \t]+|[ \t]+$/, "", idx)
    gsub(/^[ \t]+|[ \t]+$/, "", path)
    sub(/^\.\//, "", path)
    next
  }
  /^[ \t]*\|/ {
    if (idx == "" || path == "") next
    size_line=$0
    sub(/^[ \t]*\|[ \t]*/, "", size_line)
    split(size_line, s, " ")
    size=s[1]
    gsub(/[^0-9]/, "", size)
    print hash "\t" idx "\t" size "\t" path
    idx=""; path=""
    next
  }
'

parse_show_files() {
  local hash="$1"
  awk -v hash="${hash}" "${CATALOG_PARSE_AWK}"
}

# Run aria2 --show-files with abort support. Return 0 ok, 1 fail, 2 cancelled.
_catalog_show_files() {
  local torrent="$1" raw="$2"
  local pid rc=0 attempt=0

  _run_show() {
    rm -f "${raw}"
    # aria2 wants --show-files=true|false; torrent path is a positional arg.
    # (Old --show-files=$torrent wrote an error stub and looked "successful".)
    "${ARIA2}" --show-files=true "${torrent}" > "${raw}" 2>"${raw}.err" &
    pid=$!
    local wr=0
    if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
      ui_wait_pid_abortable "${pid}"
      wr=$?
    else
      wait "${pid}" || wr=1
    fi
    if (( wr == 2 )); then
      rm -f "${raw}" "${raw}.err"
      return 2
    fi
    rm -f "${raw}.err"
    # Valid listing contains a Files: section / idx|path header
    if [[ -s "${raw}" ]] && grep -qE '^(Files:|idx\|)' "${raw}"; then
      return 0
    fi
    return 1
  }

  _run_show
  rc=$?
  (( rc == 2 )) && return 2
  (( rc == 0 )) && return 0
  return 1
}

# Run a background job with UI cancel. Return 0 ok, 1 fail, 2 cancelled.
_catalog_wait_bg() {
  local pid="$1" wr=0
  [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 1
  if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
    ui_wait_pid_abortable "${pid}"
    wr=$?
  else
    wait "${pid}" || wr=1
    (( wr != 0 )) && wr=1
  fi
  (( wr == 2 )) && return 2
  (( wr == 0 )) && return 0
  return 1
}

# Update progress label during long index sub-steps (keeps bar position).
_catalog_phase_label() {
  local msg="$1"
  [[ "${UI_ACTIVE:-0}" == "1" && "${UI_PROGRESS_ACTIVE:-0}" == "1" ]] || return 0
  printf '\e[%d;%dH%s%-*.*s%s' $((UI_PROGRESS_MY + 2)) $((UI_PROGRESS_MX + 3)) \
    "${UI_PANEL}" $((UI_PROGRESS_MW - 6)) $((UI_PROGRESS_MW - 6)) \
    "$(ui_fit $((UI_PROGRESS_MW - 6)) "${msg}")" "${UI_RST}"
  ui_activity_tick
}

# Rebuild all.tsv from per-hash shards (skips empty / header-only safely).
# Return 0 ok, 2 cancelled.
rebuild_all_tsv_from_shards() {
  local out="${CATALOG_DIR}/all.tsv" tsv base pid wr
  local -a shards=()
  local total cur=0 use_ui=0
  ensure_dirs
  shopt -s nullglob
  for tsv in "${CATALOG_DIR}"/*.tsv; do
    base="${tsv##*/}"
    [[ "${base}" == "all.tsv" ]] && continue
    [[ -s "${tsv}" ]] || continue
    shards+=("${tsv}")
  done
  total=${#shards[@]}
  [[ "${UI_ACTIVE:-0}" == "1" ]] && use_ui=1

  printf '%s\n' "${CATALOG_HEADER}" > "${out}"
  for tsv in "${shards[@]}"; do
    cur=$((cur + 1))
    base="${tsv##*/}"
    if (( use_ui )); then
      if [[ "${UI_PROGRESS_ACTIVE:-0}" != "1" ]]; then
        ui_progress_paint "Build Catalog" "${cur}" "${total}" "Merging ${base}"
      else
        # Keep overall item counts if caller already painted a parent bar
        _catalog_phase_label "Merging ${cur}/${total}: ${base}"
      fi
      if ui_user_wants_abort; then
        return 2
      fi
    fi
    # Large shards: append in background so Esc/B still works
    tail -n +2 "${tsv}" >> "${out}" &
    pid=$!
    _catalog_wait_bg "${pid}"
    wr=$?
    (( wr == 2 )) && return 2
  done
  return 0
}

catalog_one() {
  local torrent="$1"
  local hash base out raw rc pid wr
  base="$(basename "${torrent}" .torrent)"
  hash="${base,,}"
  out="${CATALOG_DIR}/${hash}.tsv"
  raw="${CATALOG_DIR}/${hash}.show.txt"

  # Incremental sync: keep existing shard, do not re-run aria2 --show-files
  if [[ "${CATALOG_SKIP_EXISTING:-0}" == "1" && -s "${out}" ]]; then
    log "catalog exists: ${out}"
    return 0
  fi

  log "indexing ${base} ..."
  _catalog_phase_label "Listing ${base}"
  _catalog_show_files "${torrent}" "${raw}"
  rc=$?
  (( rc == 2 )) && return 2
  (( rc != 0 )) && return 1

  # awk parse of huge --show-files can take minutes — must stay abortable
  _catalog_phase_label "Parsing ${base}"
  rm -f "${out}" "${out}.body"
  # Background the awk process itself (not a bash function) so kill stops it
  awk -v hash="${hash}" "${CATALOG_PARSE_AWK}" "${raw}" > "${out}.body" &
  pid=$!
  _catalog_wait_bg "${pid}"
  wr=$?
  if (( wr == 2 )); then
    rm -f "${out}" "${out}.body"
    return 2
  fi
  if (( wr != 0 )) || [[ ! -s "${out}.body" ]]; then
    rm -f "${out}" "${out}.body" "${CATALOG_DIR}/${hash}.cnt"
    return 1
  fi
  local count
  count="$(wc -l < "${out}.body" | tr -d '[:space:]')"
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  {
    printf '%s\n' "${CATALOG_HEADER}"
    cat "${out}.body"
  } > "${out}"
  rm -f "${out}.body"
  printf '%s\n' "${count}" > "${CATALOG_DIR}/${hash}.cnt"
  log "catalog ${out} (${count} files)"

  # build_all starts with empty all.tsv ? just append (no O(n?) rewrite).
  # Incremental path sets CATALOG_NO_ALL_APPEND=1 and rebuilds all.tsv once.
  if [[ "${CATALOG_NO_ALL_APPEND:-0}" != "1" ]]; then
    _catalog_phase_label "Appending ${base}"
    if [[ -f "${CATALOG_DIR}/all.tsv" ]]; then
      tail -n +2 "${out}" >> "${CATALOG_DIR}/all.tsv" &
      pid=$!
      _catalog_wait_bg "${pid}"
      wr=$?
      (( wr == 2 )) && return 2
    else
      cp -f "${out}" "${CATALOG_DIR}/all.tsv"
    fi
  fi
  return 0
}

# Derive Search folder label from a catalog path (first data row).
_catalog_label_from_path() {
  local path="$1" a b c label="(root)"
  path="${path#./}"
  if [[ -z "${path}" ]]; then
    printf '%s' "(root)"
    return 0
  fi
  if [[ "${path}" != */* ]]; then
    printf '%s' "${path}"
    return 0
  fi
  a="${path%%/*}"; b="${path#*/}"
  if [[ "${b}" == */* ]]; then
    c="${b%%/*}"
    case "${c}" in
      No-Intro|Redump|TOSEC|GoodSets|Non-Redump|No-Intro_*|Unofficial)
        b="${b#*/}"
        if [[ "${b}" == */* ]]; then label="${b%%/*}"; else label="${b%.*}"; fi
        ;;
      *)
        if [[ "${b}" == */* ]]; then label="${c}"; else label="${a}"; fi
        ;;
    esac
  else
    label="${a}"
  fi
  printf '%s' "${label}"
}

# folders.idx: hash<TAB>label<TAB>count ? tiny index for fast Search startup
# O(1) per torrent: path from line 2 only, count from .cnt (no full TSV scan).
# Return 0 ok, 2 cancelled
rebuild_folders_idx() {
  local out="${CATALOG_DIR}/folders.idx" tmp tsv base hash path count label cntf
  local -a shards=()
  local total cur=0 use_ui=0 pid wr
  ensure_dirs
  tmp="$(mktemp)"
  : > "${tmp}"
  shopt -s nullglob
  for tsv in "${CATALOG_DIR}"/*.tsv; do
    base="$(basename "${tsv}")"
    [[ "${base}" == "all.tsv" ]] && continue
    shards+=("${tsv}")
  done
  total=${#shards[@]}
  [[ "${UI_ACTIVE:-0}" == "1" ]] && use_ui=1

  for tsv in "${shards[@]}"; do
    cur=$((cur + 1))
    base="$(basename "${tsv}")"
    hash="${base%.tsv}"
    hash="${hash,,}"
    if (( use_ui )); then
      _catalog_phase_label "Folder index ${cur}/${total}"
      if ui_user_wants_abort; then
        rm -f "${tmp}"
        return 2
      fi
      ui_activity_tick
    fi
    # Fast: only first data row (line 2). Never scan whole shard.
    path="$(awk -F'\t' 'NR==2 { print $4; exit }' "${tsv}" 2>/dev/null || true)"
    cntf="${CATALOG_DIR}/${hash}.cnt"
    count=""
    if [[ -f "${cntf}" ]]; then
      count="$(tr -d '[:space:]' < "${cntf}" 2>/dev/null || true)"
    fi
    if [[ ! "${count}" =~ ^[0-9]+$ ]]; then
      # Fallback once: line count in background (large shards on SD)
      if (( use_ui )); then
        _catalog_phase_label "Counting ${cur}/${total}"
      fi
      wc -l < "${tsv}" > "${tmp}.wc" 2>/dev/null &
      pid=$!
      _catalog_wait_bg "${pid}"
      wr=$?
      if (( wr == 2 )); then
        rm -f "${tmp}" "${tmp}.wc"
        return 2
      fi
      count="$(tr -d '[:space:]' < "${tmp}.wc" 2>/dev/null || true)"
      rm -f "${tmp}.wc"
      [[ "${count}" =~ ^[0-9]+$ ]] || count=1
      (( count > 0 )) && count=$((count - 1))
      printf '%s\n' "${count}" > "${cntf}"
    fi
    label="$(_catalog_label_from_path "${path}")"
    printf '%s\t%s\t%s\n' "${hash}" "${label}" "${count}" >> "${tmp}"
  done

  if [[ ! -s "${tmp}" ]]; then
    : > "${out}"
    rm -f "${tmp}"
    log "folders index: ${out} (0 torrents)"
    return 0
  fi

  # Sort only when needed; never use bash printf|sort pipeline (can hang on MiSTer).
  if (( total <= 1 )); then
    mv -f "${tmp}" "${out}"
  else
    if (( use_ui )); then
      _catalog_phase_label "Sorting folder index (${total})..."
    fi
    LC_ALL=C sort -t $'\t' -k2,2 -k1,1 -o "${tmp}.sorted" "${tmp}" &
    pid=$!
    _catalog_wait_bg "${pid}"
    wr=$?
    if (( wr == 2 )); then
      rm -f "${tmp}" "${tmp}.sorted"
      return 2
    fi
    mv -f "${tmp}.sorted" "${out}"
    rm -f "${tmp}"
  fi
  log "folders index: ${out} (${total} torrents)"
  return 0
}

# Return 0 ok, 1 fail, 2 cancelled by user
build_all() {
  need_aria2 || return 1
  ensure_dirs
  shopt -s nullglob
  local torrents=("${META_DIR}"/*.torrent)
  local total cur t rc use_ui=0 name
  if [[ ${#torrents[@]} -eq 0 ]]; then
    warn "no .torrent in ${META_DIR}; run fetch meta first"
    return 1
  fi

  [[ "${UI_ACTIVE:-0}" == "1" ]] && use_ui=1
  total=${#torrents[@]}
  cur=0
  printf '%s\n' "${CATALOG_HEADER}" > "${CATALOG_DIR}/all.tsv"
  # Fresh progress dialog for catalog stage
  UI_PROGRESS_ACTIVE=0

  for t in "${torrents[@]}"; do
    if (( use_ui )) && ui_user_wants_abort; then
      ui_progress_done
      return 2
    fi
    cur=$((cur + 1))
    name="${t##*/}"
    if (( use_ui )); then
      ui_progress_paint "Build Catalog" "${cur}" "${total}" "Indexing ${name}"
    else
      log "[${cur}/${total}] indexing ${name}"
    fi
    catalog_one "${t}"
    rc=$?
    if (( rc == 2 )); then
      (( use_ui )) && ui_progress_done
      return 2
    fi
    (( rc != 0 )) && warn "catalog failed: ${t}"
  done

  log "global catalog: ${CATALOG_DIR}/all.tsv (${total} torrent(s))"
  if (( use_ui )); then
    ui_progress_paint "Build Catalog" "${total}" "${total}" "Building folder index..."
  fi
  rebuild_folders_idx
  rc=$?
  if (( rc == 2 )); then
    (( use_ui )) && ui_progress_done
    return 2
  fi
  if (( use_ui )); then
    ui_progress_paint "Build Catalog" "${total}" "${total}" "Done"
    ui_progress_done
    ui_drain_keys
  fi
  return 0
}

# Force rebuild of search catalog from existing meta/*.torrent (no magnet re-fetch).
# Skips unusable stubs. Returns 0 ok, 1 fail, 2 cancelled, 3 nothing to index.
reindex_catalog_force() {
  need_aria2 || return 1
  ensure_dirs
  # Drop catalog shards only ? keep .torrent meta + dht.dat
  local f
  shopt -s nullglob
  for f in "${CATALOG_DIR}"/*.tsv; do
    rm -f "${f}"
  done
  rm -f "${CATALOG_DIR}/all.tsv" "${CATALOG_DIR}/folders.idx"

  local -a torrents=()
  for f in "${META_DIR}"/*.torrent; do
    [[ -f "${f}" ]] || continue
    # Prefer shared validator if fetch_meta was sourced
    if [[ "$(type -t torrent_meta_usable 2>/dev/null)" == "function" ]]; then
      torrent_meta_usable "${f}" || continue
    else
      grep -aq '4:info' "${f}" 2>/dev/null || continue
      grep -aq '6:pieces' "${f}" 2>/dev/null || continue
    fi
    torrents+=("${f}")
  done
  if (( ${#torrents[@]} == 0 )); then
    write_empty_catalog 2>/dev/null || printf '%s\n' "${CATALOG_HEADER}" > "${CATALOG_DIR}/all.tsv"
    return 3
  fi

  local total cur t rc use_ui=0 name ok=0
  [[ "${UI_ACTIVE:-0}" == "1" ]] && use_ui=1
  total=${#torrents[@]}
  cur=0
  UI_PROGRESS_ACTIVE=0
  UI_QUIET=1
  printf '%s\n' "${CATALOG_HEADER}" > "${CATALOG_DIR}/all.tsv"

  for t in "${torrents[@]}"; do
    if (( use_ui )) && ui_user_wants_abort; then
      ui_progress_done
      UI_QUIET=0
      return 2
    fi
    cur=$((cur + 1))
    name="${t##*/}"
    if (( use_ui )); then
      ui_progress_paint "Reindex Catalog" "${cur}" "${total}" "Indexing ${name}"
    else
      log "[${cur}/${total}] reindex ${name}"
    fi
    catalog_one "${t}"
    rc=$?
    if (( rc == 2 )); then
      (( use_ui )) && ui_progress_done
      UI_QUIET=0
      return 2
    fi
    (( rc == 0 )) && ok=$((ok + 1))
  done

  if (( use_ui )); then
    ui_progress_paint "Reindex Catalog" "${total}" "${total}" "Building folder index..."
  fi
  rebuild_folders_idx
  rc=$?
  if (( rc == 2 )); then
    (( use_ui )) && ui_progress_done
    UI_QUIET=0
    return 2
  fi
  if (( use_ui )); then
    ui_progress_paint "Reindex Catalog" "${total}" "${total}" "Done (${ok})"
    ui_progress_done
    ui_drain_keys
  fi
  UI_QUIET=0
  (( ok == 0 )) && return 1
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  build_all
fi
