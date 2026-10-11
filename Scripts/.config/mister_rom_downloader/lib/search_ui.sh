#!/usr/bin/env bash
# Search / Filter UI: catalog tree + Filter buttons + download on file Enter
set -uo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

meta_is_empty() {
  shopt -s nullglob
  local t=( "${META_DIR}"/*.torrent )
  (( ${#t[@]} == 0 ))
}

catalog_is_empty() {
  shopt -s nullglob
  local f
  for f in "${CATALOG_DIR}"/*.tsv; do
    [[ -f "${f}" ]] || continue
    [[ "$(basename "${f}")" == "all.tsv" ]] && continue
    return 1
  done
  [[ -f "${CATALOG_DIR}/folders.idx" ]] && return 1
  return 0
}

dats_are_empty() {
  shopt -s nullglob
  local f real=0
  for f in "${DATS_DIR}"/*.dat "${DATS_DIR}"/*.DAT; do
    [[ -f "${f}" ]] || continue
    real=1
    break
  done
  (( real == 0 ))
}

search_pipeline_meta() {
  update_metadata_and_catalog
}

search_ensure_data() {
  local no_catalog=0 no_dats=0
  if meta_is_empty || catalog_is_empty; then no_catalog=1; fi
  if dats_are_empty; then no_dats=1; fi

  # Fresh install: source lists ship, but catalog + DAT bodies are not pre-downloaded
  if (( no_catalog && no_dats )); then
    ui_msgbox "Search" \
      "No torrent catalog and no DAT database yet."$'\n'$'\n'"Torrent source lists and DAT source lists are in the package, but metadata/catalog and .dat files must be downloaded first."$'\n'$'\n'"Next prompts can update them, or use Torrent Files / DAT Files from the main menu."
  fi

  if (( no_catalog )); then
    if ui_yesno "Update Metadata?" \
      "Torrent metadata/catalog is empty. Update from torrents/ now?"; then
      search_pipeline_meta || true
    fi
    if catalog_is_empty; then
      ui_msgbox "Search" "No catalog data. Returning to menu."$'\n'"Use Torrent Files → Update Metadata first."
      return 1
    fi
  fi
  if dats_are_empty; then
    if ui_yesno "Update DAT Files?" \
      "No DAT files found. Download MiSTer Organize DATs now?"$'\n'"(Needed to match/place ROMs; Search can work without them.)"; then
      update_enabled_dats
      case "$?" in
        0|3) ui_msgbox "DAT Files" "Update finished: ${DAT_UPDATE_OK:-0} saved" ;;
        *) ui_msgbox "DAT Files" "Update failed. Check dats/download.log" ;;
      esac
    fi
  fi
  # Ensure tiny folder index exists (no need to load all.tsv into bash)
  if [[ ! -s "${CATALOG_DIR}/folders.idx" ]]; then
    local _idx_rc=0
    UI_BUSY_SOFT=0
    ui_busy_show "Search" "Building folder index..."
    [[ "$(type -t rebuild_folders_idx 2>/dev/null)" == "function" ]] \
      || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_catalog.sh"
    rebuild_folders_idx || _idx_rc=$?
    ui_busy_done
    if (( _idx_rc == 2 )); then
      ui_msgbox "Search" "Cancelled - folder index incomplete."
      return 1
    fi
  fi
  return 0
}

# SEARCH_EXPANDED[hash]=1 ? open. Children from .tsv / filter cache (not bash strings).
declare -A SEARCH_EXPANDED=()
declare -A SEARCH_HASH_LABEL=()
declare -A SEARCH_HASH_COUNT=()  # hash -> file count (from folders.idx or filter)
declare -A SEARCH_CHILDREN=()   # small filter blobs only (avoid for huge sets)
declare -a SEARCH_FOLDER_ORDER=()
declare -a SEARCH_FILE_HASH=() SEARCH_FILE_IDX=() SEARCH_FILE_SIZE=() SEARCH_FILE_PATH=()
declare -a SEARCH_VIEW=() SEARCH_VIEW_REF=() SEARCH_VIEW_TOP=()
# Non-empty while a Filter query is active ? expand must NOT reload full .tsv
SEARCH_FILTER_Q=""
SEARCH_STAT_FOLDERS=0
SEARCH_STAT_FILES=0
SEARCH_MARQUEE_OFF=0
SEARCH_MARQUEE_SEL=-1
# Inline expand into tree only up to this many rows; larger -> paged browser
SEARCH_EXPAND_INLINE_MAX=400
SEARCH_CHILD_CACHE_DIR=""

search_path_top_folder_set() {
  local path="$1" a b c
  path="${path#./}"
  SEARCH_TOP_FOLDER="(root)"
  [[ -z "${path}" ]] && return 0
  if [[ "${path}" != */* ]]; then SEARCH_TOP_FOLDER="${path}"; return 0; fi
  a="${path%%/*}"; b="${path#*/}"
  if [[ "${b}" == */* ]]; then
    c="${b%%/*}"
    case "${c}" in
      No-Intro|Redump|TOSEC|GoodSets|Non-Redump|No-Intro_*|Unofficial)
        b="${b#*/}"
        if [[ "${b}" == */* ]]; then SEARCH_TOP_FOLDER="${b%%/*}"
        else SEARCH_TOP_FOLDER="${b%.*}"; fi
        return 0
        ;;
    esac
    if [[ "${b}" == */* ]]; then SEARCH_TOP_FOLDER="${c}"; return 0; fi
  fi
  SEARCH_TOP_FOLDER="${a}"
}

search_load_folders_idx() {
  SEARCH_FOLDER_ORDER=()
  SEARCH_HASH_LABEL=()
  SEARCH_HASH_COUNT=()
  SEARCH_CHILDREN=()
  local hash label count tsv nlines n=0
  [[ -f "${CATALOG_DIR}/folders.idx" ]] || return 0
  while IFS=$'\t' read -r hash label count || [[ -n "${hash}" ]]; do
    hash="${hash%$'\r'}"; label="${label%$'\r'}"; count="${count%$'\r'}"
    [[ -z "${hash}" || "${hash}" == \#* ]] && continue
    n=$((n + 1))
    if (( n % 40 == 0 )) && [[ "${UI_ACTIVE:-0}" == "1" ]]; then
      ui_activity_tick
    fi
    SEARCH_FOLDER_ORDER+=("${hash}")
    SEARCH_HASH_LABEL["${hash}"]="${label:-(torrent)}"
    # Strip spaces; CRLF used to zero-out counts (regex failed on trailing CR)
    count="${count//[[:space:]]/}"
    if [[ "${count}" =~ ^[0-9]+$ ]]; then
      SEARCH_HASH_COUNT["${hash}"]="${count}"
    else
      # Fallback: data lines in per-torrent tsv (minus header)
      tsv="${CATALOG_DIR}/${hash}.tsv"
      nlines=0
      if [[ -f "${tsv}" ]]; then
        nlines="$(wc -l < "${tsv}" 2>/dev/null | tr -d '[:space:]')"
        [[ "${nlines}" =~ ^[0-9]+$ ]] || nlines=0
        (( nlines > 0 )) && nlines=$((nlines - 1))
      fi
      SEARCH_HASH_COUNT["${hash}"]="${nlines}"
    fi
  done < "${CATALOG_DIR}/folders.idx"
}

search_child_cache_dir() {
  SEARCH_CHILD_CACHE_DIR="${CATALOG_DIR}/.child_cache"
  mkdir -p "${SEARCH_CHILD_CACHE_DIR}" 2>/dev/null || true
}

# Sets SEARCH_CHILD_SRC (file) and SEARCH_CHILD_SKIP (1=skip tsv header).
search_child_src_set() {
  local h="$1"
  SEARCH_CHILD_SRC=""
  SEARCH_CHILD_SKIP=0
  if [[ -n "${SEARCH_FILTER_Q}" ]]; then
    search_child_cache_dir
    SEARCH_CHILD_SRC="${SEARCH_CHILD_CACHE_DIR}/${h}.tsv"
    SEARCH_CHILD_SKIP=0
  else
    SEARCH_CHILD_SRC="${CATALOG_DIR}/${h}.tsv"
    SEARCH_CHILD_SKIP=1
  fi
}

search_children_ready() {
  local h="$1"
  # Prefer file sources (no huge bash strings)
  if [[ -n "${SEARCH_FILTER_Q}" ]]; then
    search_child_cache_dir
    [[ -s "${SEARCH_CHILD_CACHE_DIR}/${h}.tsv" ]] && return 0
  else
    [[ -f "${CATALOG_DIR}/${h}.tsv" ]] && return 0
  fi
  # Legacy small filter blob
  local blob line
  blob="${SEARCH_CHILDREN[${h}]:-}"
  [[ -n "${blob}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -n "${line}" ]] || continue
    return 0
  done <<< "${blob}"
  return 1
}

search_folder_count() {
  local h="$1" n
  n="${SEARCH_HASH_COUNT[${h}]:-0}"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "${n}"
}

# Ensure per-hash file list is available. Filter hits go to .child_cache via awk (fast).
search_ensure_children() {
  local h="$1" tsv ql out keyf
  tsv="${CATALOG_DIR}/${h}.tsv"
  [[ -f "${tsv}" ]] || return 1
  if [[ -z "${SEARCH_FILTER_Q}" ]]; then
    return 0
  fi
  search_child_cache_dir
  out="${SEARCH_CHILD_CACHE_DIR}/${h}.tsv"
  keyf="${SEARCH_CHILD_CACHE_DIR}/${h}.key"
  if [[ -s "${out}" && -f "${keyf}" && "$(cat "${keyf}" 2>/dev/null)" == "${SEARCH_FILTER_Q}" ]]; then
    return 0
  fi
  ql="${SEARCH_FILTER_Q,,}"
  awk -F'\t' -v q="${ql}" '
    BEGIN { IGNORECASE=1 }
    NR == 1 { next }
    {
      path = $4
      sub(/\r$/, "", path)
      if (index(tolower(path), q)) {
        disp = path
        sub(/^.*\//, "", disp)
        if (disp == "") disp = path
        printf "%s\t%s\t%s\t%s\n", $2, $3, path, disp
      }
    }
  ' "${tsv}" > "${out}.partial" 2>/dev/null || true
  if [[ ! -s "${out}.partial" ]]; then
    rm -f "${out}.partial" "${out}" "${keyf}"
    return 1
  fi
  mv -f "${out}.partial" "${out}"
  printf '%s' "${SEARCH_FILTER_Q}" > "${keyf}"
  # Refresh count from cache for UI (N)
  SEARCH_HASH_COUNT["${h}"]="$(wc -l < "${out}" | tr -d '[:space:]')"
  return 0
}

# Temp arrays filled by _search_load_children_arrays (no mktemp/awk on VFAT).
SEARCH_ADD_V=() SEARCH_ADD_R=() SEARCH_ADD_T=()

# Fill SEARCH_ADD_* with up to SEARCH_EXPAND_INLINE_MAX children.
_search_load_children_arrays() {
  local h="$1" idx size path disp fref n=0 max="${SEARCH_EXPAND_INLINE_MAX}"
  local _hash blob
  SEARCH_ADD_V=() SEARCH_ADD_R=() SEARCH_ADD_T=()

  # Fastest: in-memory filter blob (from search_apply_filter)
  blob="${SEARCH_CHILDREN[${h}]:-}"
  if [[ -n "${blob}" ]]; then
    while IFS=$'\t' read -r idx size path disp || [[ -n "${path:-}" ]]; do
      idx="${idx%$'\r'}"; size="${size%$'\r'}"
      path="${path%$'\r'}"; disp="${disp%$'\r'}"
      [[ -n "${idx}" && -n "${path}" ]] || continue
      [[ -n "${disp}" ]] || disp="${path##*/}"
      fref=${#SEARCH_FILE_HASH[@]}
      SEARCH_FILE_HASH+=("${h}")
      SEARCH_FILE_IDX+=("${idx}")
      SEARCH_FILE_SIZE+=("${size}")
      SEARCH_FILE_PATH+=("${path}")
      SEARCH_ADD_V+=("  ${UI_EL}${UI_BRH} ${disp}")
      SEARCH_ADD_R+=("${fref}")
      SEARCH_ADD_T+=("${h}")
      n=$((n + 1))
      (( n >= max )) && break
    done <<< "${blob}"
    (( ${#SEARCH_ADD_V[@]} > 0 )) && return 0
    return 1
  fi

  search_ensure_children "${h}" || return 1
  search_child_src_set "${h}"
  [[ -s "${SEARCH_CHILD_SRC}" ]] || return 1

  if [[ -n "${SEARCH_FILTER_Q}" ]]; then
    # cache rows: idx size path disp
    while IFS=$'\t' read -r idx size path disp || [[ -n "${path:-}" ]]; do
      idx="${idx%$'\r'}"; size="${size%$'\r'}"
      path="${path%$'\r'}"; disp="${disp%$'\r'}"
      [[ -n "${idx}" && -n "${path}" ]] || continue
      [[ -n "${disp}" ]] || disp="${path##*/}"
      fref=${#SEARCH_FILE_HASH[@]}
      SEARCH_FILE_HASH+=("${h}")
      SEARCH_FILE_IDX+=("${idx}")
      SEARCH_FILE_SIZE+=("${size}")
      SEARCH_FILE_PATH+=("${path}")
      SEARCH_ADD_V+=("  ${UI_EL}${UI_BRH} ${disp}")
      SEARCH_ADD_R+=("${fref}")
      SEARCH_ADD_T+=("${h}")
      n=$((n + 1))
      (( n >= max )) && break
    done < "${SEARCH_CHILD_SRC}"
  else
    # catalog tsv: hash idx size path (+ header) — read directly, no temp file
    {
      IFS= read -r _ || true
      while IFS=$'\t' read -r _hash idx size path || [[ -n "${path:-}" ]]; do
        idx="${idx%$'\r'}"; size="${size%$'\r'}"; path="${path%$'\r'}"
        [[ -n "${idx}" && -n "${path}" ]] || continue
        disp="${path##*/}"
        [[ -n "${disp}" ]] || disp="${path}"
        fref=${#SEARCH_FILE_HASH[@]}
        SEARCH_FILE_HASH+=("${h}")
        SEARCH_FILE_IDX+=("${idx}")
        SEARCH_FILE_SIZE+=("${size}")
        SEARCH_FILE_PATH+=("${path}")
        SEARCH_ADD_V+=("  ${UI_EL}${UI_BRH} ${disp}")
        SEARCH_ADD_R+=("${fref}")
        SEARCH_ADD_T+=("${h}")
        n=$((n + 1))
        (( n >= max )) && break
      done
    } < "${SEARCH_CHILD_SRC}"
  fi
  (( ${#SEARCH_ADD_V[@]} > 0 )) || return 1
  return 0
}

# Append children at end of VIEW (full rebuild).
_search_append_children() {
  local h="$1"
  _search_load_children_arrays "${h}" || return 1
  SEARCH_VIEW+=("${SEARCH_ADD_V[@]}")
  SEARCH_VIEW_REF+=("${SEARCH_ADD_R[@]}")
  SEARCH_VIEW_TOP+=("${SEARCH_ADD_T[@]}")
  return 0
}

# Insert children right after folder row at index $2 (fast single-group expand).
_search_insert_children_at() {
  local h="$1" at="$2"
  local -a head_v head_r head_t tail_v tail_r tail_t
  _search_load_children_arrays "${h}" || return 1
  head_v=("${SEARCH_VIEW[@]:0:$((at + 1))}")
  head_r=("${SEARCH_VIEW_REF[@]:0:$((at + 1))}")
  head_t=("${SEARCH_VIEW_TOP[@]:0:$((at + 1))}")
  tail_v=("${SEARCH_VIEW[@]:$((at + 1))}")
  tail_r=("${SEARCH_VIEW_REF[@]:$((at + 1))}")
  tail_t=("${SEARCH_VIEW_TOP[@]:$((at + 1))}")
  SEARCH_VIEW=("${head_v[@]}" "${SEARCH_ADD_V[@]}" "${tail_v[@]}")
  SEARCH_VIEW_REF=("${head_r[@]}" "${SEARCH_ADD_R[@]}" "${tail_r[@]}")
  SEARCH_VIEW_TOP=("${head_t[@]}" "${SEARCH_ADD_T[@]}" "${tail_t[@]}")
  return 0
}

# Remove inline children of folder $1 starting after its row index $2.
_search_remove_children_at() {
  local h="$1" at="$2" i end
  end=$((at + 1))
  for ((i = at + 1; i < ${#SEARCH_VIEW[@]}; i++)); do
    if [[ "${SEARCH_VIEW_TOP[i]}" == "${h}" && "${SEARCH_VIEW_REF[i]}" != "-1" ]]; then
      end=$((i + 1))
    else
      break
    fi
  done
  (( end > at + 1 )) || return 0
  SEARCH_VIEW=("${SEARCH_VIEW[@]:0:$((at + 1))}" "${SEARCH_VIEW[@]:${end}}")
  SEARCH_VIEW_REF=("${SEARCH_VIEW_REF[@]:0:$((at + 1))}" "${SEARCH_VIEW_REF[@]:${end}}")
  SEARCH_VIEW_TOP=("${SEARCH_VIEW_TOP[@]:0:$((at + 1))}" "${SEARCH_VIEW_TOP[@]:${end}}")
}

search_tree_rebuild_view() {
  SEARCH_VIEW=()
  SEARCH_VIEW_REF=()
  SEARCH_VIEW_TOP=()
  SEARCH_FILE_HASH=() SEARCH_FILE_IDX=() SEARCH_FILE_SIZE=() SEARCH_FILE_PATH=()
  # Model changed ? drop line-diff cache so next paint redraws viewport
  ui_vp_reset 2>/dev/null || true
  local h mark label nchild
  for h in "${SEARCH_FOLDER_ORDER[@]}"; do
    if [[ "${SEARCH_EXPANDED[${h}]:-0}" == "1" ]]; then mark="[-]"; else mark="[+]"; fi
    label="${SEARCH_HASH_LABEL[${h}]:-${h}}"
    # Always show (N) on the group row (collapsed or expanded)
    nchild="${SEARCH_HASH_COUNT[${h}]:-0}"
    [[ "${nchild}" =~ ^[0-9]+$ ]] || nchild=0
    (( nchild > 0 )) && label="${label} (${nchild})"
    SEARCH_VIEW+=("${mark} ${label}/")
    SEARCH_VIEW_REF+=(-1)
    SEARCH_VIEW_TOP+=("${h}")
    [[ "${SEARCH_EXPANDED[${h}]:-0}" == "1" ]] || continue
    # Huge groups are opened via paged browser (never inline 10k+ rows)
    if (( nchild > SEARCH_EXPAND_INLINE_MAX )); then
      SEARCH_EXPANDED["${h}"]=0
      SEARCH_VIEW[$((${#SEARCH_VIEW[@]} - 1))]="[+] ${label}/"
      continue
    fi
    # If expand yields no rows, revert mark to [+] so we never show hollow [-]
    if ! _search_append_children "${h}"; then
      SEARCH_EXPANDED["${h}"]=0
      if (( nchild > 0 )); then
        SEARCH_VIEW[$((${#SEARCH_VIEW[@]} - 1))]="[+] ${SEARCH_HASH_LABEL[${h}]:-${h}} (${nchild})/"
      else
        SEARCH_VIEW[$((${#SEARCH_VIEW[@]} - 1))]="[+] ${SEARCH_HASH_LABEL[${h}]:-${h}}/"
      fi
    fi
  done
  search_update_stats
}

# Filter via awk on all.tsv: summary only (hash/label/count).
# File rows stay out of bash — expand uses search_ensure_children (.child_cache).
search_apply_filter() {
  local q="$1" ql tmp raw sorted awk_pid=0 wr=0 hash label count
  SEARCH_FILTER_Q="${q}"
  SEARCH_EXPANDED=()
  SEARCH_CHILDREN=()
  if [[ -z "${q}" ]]; then
    search_load_folders_idx
    search_tree_rebuild_view
    return 0
  fi
  ql="${q,,}"
  # Enter/OK from the filter OSK must not be seen as Esc/B cancel
  ui_drain_keys
  UI_BUSY_SOFT=1
  ui_busy_show "Filter" "Searching..."
  search_child_cache_dir
  rm -f "${SEARCH_CHILD_CACHE_DIR}"/*.tsv "${SEARCH_CHILD_CACHE_DIR}"/*.key \
    "${SEARCH_CHILD_CACHE_DIR}"/*.partial 2>/dev/null || true

  raw="$(mktemp "${APP_DIR}/.filter_raw_XXXXXX")"
  sorted="$(mktemp "${APP_DIR}/.filter_sort_XXXXXX")"
  # One pass: unique matching torrents + counts + folder labels (no per-row bash load)
  awk -F'\t' -v q="${ql}" '
    BEGIN { IGNORECASE=1; n=0 }
    NR==1 { next }
    {
      path = $4
      sub(/\r$/, "", path)
      if (index(tolower(path), q) == 0) next
      h = $1
      if (!(h in cnt)) {
        order[++n] = h
        # Mirror search_path_top_folder_set()
        p = path
        sub(/^\.\//, "", p)
        lab = "(root)"
        if (p != "") {
          if (index(p, "/") == 0) {
            lab = p
          } else {
            a = p; sub(/\/.*/, "", a)
            b = p; sub(/^[^\/]*\//, "", b)
            if (index(b, "/") > 0) {
              c = b; sub(/\/.*/, "", c)
              if (c ~ /^(No-Intro|Redump|TOSEC|GoodSets|Non-Redump)$/ || c ~ /^No-Intro_/ || c == "Unofficial") {
                sub(/^[^\/]*\//, "", b)
                if (index(b, "/") > 0) { lab = b; sub(/\/.*/, "", lab) }
                else { lab = b; sub(/\.[^.\/]*$/, "", lab) }
              } else if (index(b, "/") > 0) {
                lab = c
              } else {
                lab = a
              }
            } else {
              lab = a
            }
          }
        }
        label[h] = lab
      }
      cnt[h]++
    }
    END {
      for (i = 1; i <= n; i++) {
        h = order[i]
        printf "%s\t%s\t%d\n", h, label[h], cnt[h]
      }
    }
  ' "${CATALOG_DIR}/all.tsv" > "${raw}" 2>/dev/null &
  awk_pid=$!
  if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
    ui_wait_pid_abortable "${awk_pid}"
    wr=$?
    if (( wr == 2 )); then
      rm -f "${raw}" "${sorted}"
      ui_busy_done
      SEARCH_FILTER_Q=""
      search_load_folders_idx
      search_tree_rebuild_view
      UI_NEED_REPAINT=0
      ui_msgbox "Filter" "Cancelled."
      return 0
    fi
  else
    wait "${awk_pid}" 2>/dev/null || true
  fi

  LC_ALL=C sort -t $'\t' -k2,2 "${raw}" > "${sorted}" 2>/dev/null || cp "${raw}" "${sorted}"
  rm -f "${raw}"

  SEARCH_FOLDER_ORDER=()
  SEARCH_HASH_LABEL=()
  SEARCH_HASH_COUNT=()
  SEARCH_CHILDREN=()
  while IFS=$'\t' read -r hash label count || [[ -n "${hash}" ]]; do
    hash="${hash%$'\r'}"; label="${label%$'\r'}"; count="${count%$'\r'}"
    [[ -z "${hash}" ]] && continue
    count="${count//[[:space:]]/}"
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0
    SEARCH_FOLDER_ORDER+=("${hash}")
    SEARCH_HASH_LABEL["${hash}"]="${label:-(torrent)}"
    SEARCH_HASH_COUNT["${hash}"]="${count}"
  done < "${sorted}"
  rm -f "${sorted}"

  # Keep folders collapsed — expand builds .child_cache on demand
  SEARCH_EXPANDED=()
  search_tree_rebuild_view
  ui_busy_done
  ui_drain_keys
  UI_NEED_REPAINT=0
}

# Folders in list + total file hits (folders.idx / filter counts)
search_update_stats() {
  local h n
  SEARCH_STAT_FOLDERS=${#SEARCH_FOLDER_ORDER[@]}
  SEARCH_STAT_FILES=0
  for h in "${SEARCH_FOLDER_ORDER[@]}"; do
    n="$(search_folder_count "${h}")"
    SEARCH_STAT_FILES=$((SEARCH_STAT_FILES + n))
  done
}

# Paged browser for huge groups (never loads 10k+ rows into bash arrays).
search_folder_browser() {
  local h="$1"
  local label total src skip sel=0 scroll=0 key need_full=1 dirty=1
  local mx my mw mh list_top list_h text_w i row
  local idx size path disp line start end
  local -a PAGE_IDX=() PAGE_SIZE=() PAGE_PATH=() PAGE_SHOW=()
  local prev_sel=-1 prev_scroll=-1
  local page_loaded_scroll=-1
  local blank_row=""

  UI_BUSY_SOFT=1
  ui_busy_show "Browse" "Opening file list..."
  search_ensure_children "${h}" || { ui_busy_done; return 1; }
  search_child_src_set "${h}"
  src="${SEARCH_CHILD_SRC}"
  skip="${SEARCH_CHILD_SKIP}"
  if [[ ! -s "${src}" ]]; then
    ui_busy_done
    return 1
  fi
  label="${SEARCH_HASH_LABEL[${h}]:-${h}}"
  total="$(search_folder_count "${h}")"
  if (( total < 1 )); then
    ui_activity_tick
    if [[ "${skip}" == "1" ]]; then
      total=$(($(wc -l < "${src}" | tr -d '[:space:]') - 1))
    else
      total="$(wc -l < "${src}" | tr -d '[:space:]')"
    fi
    [[ "${total}" =~ ^[0-9]+$ ]] || total=0
    (( total < 0 )) && total=0
  fi
  ui_busy_done
  (( total < 1 )) && return 1

  # Pad/truncate once per page load — cursor moves reuse PAGE_SHOW (no ui_fit/subshell).
  _fb_fmt_show() {
    local raw="$1" show
    if (( ${#raw} > text_w )); then
      if (( text_w > 3 )); then
        show="${raw:0:$((text_w - 3))}..."
      else
        show="${raw:0:text_w}"
      fi
    else
      printf -v show '%-*s' "${text_w}" "${raw}"
    fi
    printf '%s' "${show}"
  }

  # Load one viewport page from disk (only when scroll changes — not every cursor move).
  _fb_load_page() {
    local awk_start awk_end raw show
    PAGE_IDX=(); PAGE_SIZE=(); PAGE_PATH=(); PAGE_SHOW=()
    start=$((scroll + 1))
    end=$((scroll + list_h))
    (( end > total )) && end="${total}"
    (( start < 1 )) && start=1
    (( start > total )) && return 0
    printf -v blank_row '%*s' "${text_w}" ''
    if [[ "${skip}" == "1" ]]; then
      awk_start=$((start + 1))  # +header
      awk_end=$((end + 1))
      while IFS=$'\t' read -r _hash idx size path; do
        idx="${idx%$'\r'}"; size="${size%$'\r'}"; path="${path%$'\r'}"
        disp="${path##*/}"
        [[ -n "${disp}" ]] || disp="${path}"
        PAGE_IDX+=("${idx}")
        PAGE_SIZE+=("${size}")
        PAGE_PATH+=("${path}")
        PAGE_SHOW+=("$(_fb_fmt_show " ${disp}")")
      done < <(awk -v s="${awk_start}" -v e="${awk_end}" 'NR>=s && NR<=e { print; } NR>e { exit }' "${src}")
    else
      while IFS=$'\t' read -r idx size path disp; do
        idx="${idx%$'\r'}"; size="${size%$'\r'}"
        path="${path%$'\r'}"; disp="${disp%$'\r'}"
        [[ -n "${disp}" ]] || disp="${path##*/}"
        PAGE_IDX+=("${idx}")
        PAGE_SIZE+=("${size}")
        PAGE_PATH+=("${path}")
        PAGE_SHOW+=("$(_fb_fmt_show " ${disp}")")
      done < <(awk -v s="${start}" -v e="${end}" 'NR>=s && NR<=e { print; } NR>e { exit }' "${src}")
    fi
    page_loaded_scroll="${scroll}"
  }

  _fb_footer() {
    local page_n page_i tip
    page_n=$(( (total + list_h - 1) / list_h ))
    (( page_n < 1 )) && page_n=1
    page_i=$(( scroll / list_h + 1 ))
    tip="${label}  $((sel + 1))/${total}  p.${page_i}/${page_n}  Esc=Back"
    printf '\e[%d;%dH%s%-*.*s%s' $((my + mh - 2)) $((mx + 2)) \
      "${UI_MUTED}" $((mw - 4)) $((mw - 4)) "${tip}" "${UI_RST}"
  }

  # Full page: direct printf (no ui_vp / no command-substitution per row)
  _fb_paint() {
    local i row show sty
    for ((i=0; i<list_h; i++)); do
      row=$((list_top + i))
      if (( i < ${#PAGE_SHOW[@]} )); then
        show="${PAGE_SHOW[i]}"
      else
        show="${blank_row}"
      fi
      if (( scroll + i == sel )); then sty="${UI_SEL}"; else sty="${UI_PANEL}"; fi
      printf '\e[%d;%dH%s%s%s' "${row}" $((mx + 3)) "${sty}" "${show}" "${UI_RST}"
    done
    ui_draw_scrollbar $((mx + mw - 3)) "${list_top}" "${list_h}" "${total}" "${list_h}" "${scroll}"
    _fb_footer
  }

  # Same page: only old+new selection rows — no disk, no subshells
  _fb_paint_sel_only() {
    local pi row show
    if (( prev_sel >= scroll && prev_sel < scroll + list_h )); then
      pi=$((prev_sel - scroll))
      row=$((list_top + pi))
      if (( pi < ${#PAGE_SHOW[@]} )); then show="${PAGE_SHOW[pi]}"; else show="${blank_row}"; fi
      printf '\e[%d;%dH%s%s%s' "${row}" $((mx + 3)) "${UI_PANEL}" "${show}" "${UI_RST}"
    fi
    if (( sel >= scroll && sel < scroll + list_h )); then
      pi=$((sel - scroll))
      row=$((list_top + pi))
      if (( pi < ${#PAGE_SHOW[@]} )); then show="${PAGE_SHOW[pi]}"; else show="${blank_row}"; fi
      printf '\e[%d;%dH%s%s%s' "${row}" $((mx + 3)) "${UI_SEL}" "${show}" "${UI_RST}"
    fi
    _fb_footer
  }

  while true; do
    if [[ "${UI_NEED_DESKTOP}" == "1" ]]; then
      UI_NEED_DESKTOP=0
      need_full=1
    fi
    if ui_check_resize; then need_full=1; fi
    if (( need_full )); then
      ui_paint_desktop
      ui_chrome "$(app_title_ver)" \
        "$(ui_fit $((UI_COLS - 8)) "$(ui_hint_nav)  Enter=Download")"
      ui_list_panel_geom 2
      mw="${UI_PW}"; mh="${UI_PH}"; mx="${UI_PX}"; my="${UI_PY}"
      ui_box "${mx}" "${my}" "${mw}" "${mh}" "Browse Files"
      ui_vp_reset
      need_full=0
      dirty=1
      prev_sel=-1
      prev_scroll=-1
    fi
    list_top=$((my + 2))
    list_h=$((mh - 4))
    (( list_h < 3 )) && list_h=3
    text_w=$((mw - 8))
    (( text_w < 10 )) && text_w=10
    (( sel >= total )) && sel=$((total - 1))
    (( sel < 0 )) && sel=0
    # Page-aligned scroll (same as main Search list)
    ui_list_snap_page sel scroll "${list_h}" "${total}"

    # Reload from disk only when the viewport page changes
    if (( dirty || page_loaded_scroll != scroll )); then
      _fb_load_page
      _fb_paint
      dirty=0
      prev_sel="${sel}"
      prev_scroll="${scroll}"
    elif (( prev_sel != sel )); then
      # Same page: paint only the two selection rows
      _fb_paint_sel_only
      prev_sel="${sel}"
    fi

    key="$(ui_read_key)" || true
    case "${key}" in
      TIMEOUT) ;;
      RESIZE) need_full=1; page_loaded_scroll=-1 ;;
      ESC)
        UI_NEED_DESKTOP=1
        return 0
        ;;
      UP)
        if (( sel > 0 )); then
          ui_coalesce_nav UP
          local _c
          for ((_c=0; _c<UI_COALESCE_N; _c++)); do
            (( sel > 0 )) || break
            ui_list_nav_up sel scroll "${list_h}" "${total}"
          done
        fi
        ;;
      DOWN)
        if (( sel < total - 1 )); then
          ui_coalesce_nav DOWN
          local _c
          for ((_c=0; _c<UI_COALESCE_N; _c++)); do
            (( sel < total - 1 )) || break
            ui_list_nav_down sel scroll "${list_h}" "${total}"
          done
        fi
        ;;
      LEFT)
        if (( scroll > 0 )); then
          scroll=$((scroll - list_h))
          (( scroll < 0 )) && scroll=0
          sel="${scroll}"
        fi
        ;;
      RIGHT)
        if (( scroll + list_h < total )); then
          scroll=$((scroll + list_h))
          sel="${scroll}"
          (( sel >= total )) && sel=$((total - 1))
        fi
        ;;
      ENTER|" ")
        local pi=$((sel - scroll))
        if (( pi >= 0 && pi < ${#PAGE_PATH[@]} )); then
          SEARCH_FILE_HASH=("${h}")
          SEARCH_FILE_IDX=("${PAGE_IDX[pi]}")
          SEARCH_FILE_SIZE=("${PAGE_SIZE[pi]}")
          SEARCH_FILE_PATH=("${PAGE_PATH[pi]}")
          search_download_selected 0
          UI_NEED_DESKTOP=1
          need_full=1
        fi
        ;;
    esac
  done
}

search_collect_tops() {
  SEARCH_ALL_TOPS=("${SEARCH_FOLDER_ORDER[@]}")
}

# Build padded list-row text (no ANSI).
# selected=1 + overflow: cyclic marquee (scroll left).
_search_row_text() {
  local idx="$1" text_w="$2" selected="${3:-0}"
  local raw loop off d
  if (( idx < 0 || idx >= ${#SEARCH_VIEW[@]} )); then
    printf '%*s' "${text_w}" ''
    return 0
  fi
  raw=" ${SEARCH_VIEW[idx]}"
  if (( ${#raw} <= text_w )); then
    printf '%-*s' "${text_w}" "${raw}"
    return 0
  fi
  if (( selected )); then
    loop="${raw}   "
    (( ${#loop} < 1 )) && loop="${raw}"
    off=$(( SEARCH_MARQUEE_OFF % ${#loop} ))
    d="${loop}${loop}"
    printf '%s' "${d:${off}:${text_w}}"
    return 0
  fi
  # Unselected overflow: keep end (filenames) visible
  if (( text_w <= 3 )); then
    printf '%s' "${raw:$((${#raw} - text_w))}"
  else
    printf '...%s' "${raw:$((${#raw} - (text_w - 3)))}"
  fi
}

# Paint one list row via viewport diff cache (batched; caller flushes).
# vp_idx = row offset within viewport (0..tree_h-1)
_search_paint_row() {
  local row="$1" idx="$2" selected="$3" text_w="$4" mx="$5" dim="${6:-0}" vp_idx="${7:--1}"
  local line payload sty
  line="$(_search_row_text "${idx}" "${text_w}" "${selected}")"
  if (( selected )); then
    if (( dim )); then sty="${UI_DIMSEL}"; else sty="${UI_SEL}"; fi
  else
    sty="${UI_PANEL}"
  fi
  payload="${sty}${line}${UI_RST}"
  if (( vp_idx >= 0 )); then
    ui_vp_put "${vp_idx}" "${row}" $((mx + 3)) "${payload}"
  else
    # Direct paint (selection-only path without viewport begin)
    printf '\e[%d;%dH%s' "${row}" $((mx + 3)) "${payload}"
  fi
}

# Enter on file: download first, then CRC/name suggest, ask where to place
search_download_selected() {
  local vref="$1"
  local hash idx size path target src_label msg rc src base suggested crc
  (( vref < 0 )) && return 0
  (( vref >= ${#SEARCH_FILE_HASH[@]} )) && return 0
  hash="${SEARCH_FILE_HASH[vref]}"
  idx="${SEARCH_FILE_IDX[vref]}"
  size="${SEARCH_FILE_SIZE[vref]}"
  path="${SEARCH_FILE_PATH[vref]}"
  base="$(basename "${path}")"

  if ! ui_okcancel "Download" "Download file?"$'\n'"${base}"; then
    return 0
  fi

  # Empty target = leave file in work dir for placement prompt
  download_one_rom "${hash}" "${idx}" "${size}" "${path}" ""
  rc=$?
  case "${rc}" in
    2)
      # download_one_rom already deleted partials
      ui_msgbox "Download" "Cancelled - file discarded."
      return 0
      ;;
    0) ;;
    *)
      _dl_discard_work "${hash}" "${path}"
      # Stub/missing meta is the usual cause after catalog-only sync
      if [[ -f "${META_DIR}/${hash}.torrent" ]] \
        && head -c 200 "${META_DIR}/${hash}.torrent" 2>/dev/null | grep -q 'dynamic metainfo'; then
        ui_msgbox "Download" "No usable torrent metadata for this pack."$'\n'"Update Metadata / sync meta, then retry."
      else
        ui_msgbox "Download" "Failed. Check inbox/download.log"
      fi
      return 0
      ;;
  esac
  src="${DOWNLOAD_LAST_SRC:-}"
  if [[ -z "${src}" || ! -f "${src}" ]]; then
    _dl_discard_work "${hash}" "${path}"
    ui_msgbox "Download" "Downloaded file not found."
    return 0
  fi

  [[ "$(type -t dat_rematch_archive_file 2>/dev/null)" == "function" ]] \
    || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/map_targets.sh"

  suggested=""
  src_label="inbox"
  if [[ "${src,,}" == *.zip ]]; then
    suggested="$(dat_rematch_archive_file "${src}" 2>/dev/null || true)"
    [[ -n "${suggested}" ]] && src_label="DAT CRC (zip)"
  fi
  if [[ -z "${suggested}" ]] && command -v python3 >/dev/null 2>&1; then
    crc="$(python3 - "${src}" <<'PY'
import sys, zlib
try:
    data = open(sys.argv[1], "rb").read()
    print("%08x" % (zlib.crc32(data) & 0xffffffff))
except Exception:
    pass
PY
)"
    if [[ "${crc}" =~ ^[0-9a-fA-F]{8}$ ]]; then
      suggested="$(dat_suggest_by_crc "${crc}" "${base}" 2>/dev/null || true)"
      [[ -n "${suggested}" ]] && src_label="DAT CRC (file)"
    fi
  fi
  if [[ -z "${suggested}" ]]; then
    resolve_download_target "${path}" >/dev/null || true
    suggested="${RESOLVE_TARGET}"
    case "${RESOLVE_SOURCE}" in
      dat) src_label="DAT name" ;;
      ext) src_label="extension" ;;
      *) src_label="default inbox" ;;
    esac
  fi
  target="${suggested:-_Inbox/${base}}"

  msg="File: ${base}"
  msg+=$'\n'"Save to: ${GAMES_ROOT}/${target}"
  msg+=$'\n'"Match: ${src_label}"
  if ! ui_okcancel "Place File" "${msg}"; then
    rm -f "${src}" 2>/dev/null || true
    _dl_discard_work "${hash}" "${path}"
    DOWNLOAD_LAST_SRC=""
    ui_msgbox "Download" "Discarded - not saved."
    return 0
  fi

  mkdir -p "$(dirname "${GAMES_ROOT}/${target}")"
  if mv -f "${src}" "${GAMES_ROOT}/${target}"; then
    # Clear empty work dir after successful place
    _dl_discard_work "${hash}" ""
    DOWNLOAD_LAST_SRC=""
    # CD/VHD zips: offer extract into per-game folder (MiSTer docs); cart/arcade zip kept
    if ! offer_extract_placed_archive "${GAMES_ROOT}/${target}"; then
      ui_msgbox "Download" "Saved:"$'\n'"${GAMES_ROOT}/${target}"
    fi
  else
    ui_msgbox "Download" "Failed to move to:"$'\n'"${GAMES_ROOT}/${target}"
  fi
}

search_ui() {
  if ! search_ensure_data; then
    return 0
  fi

  local query="" sel=0 scroll=0 key need_full=1 dirty=1
  local mx my mw mh tree_top tree_h visible
  # SEARCH_VIEW* / SEARCH_FILE_* are globals ? do not local-shadow (breaks expand)
  local -a SEARCH_ALL_TOPS=()
  local i row text_w
  local prev_sel=-1 prev_scroll=-1
  local focus="list" bsel=0 nb=4 btn_row bx
  local prev_focus="" prev_bsel=-1
  # Hotkey letter == label[0] (D=Discard, not Clear ? avoids clash with Collapse)
  local -a BTN_HOTS=("F" "D" "C" "E")
  local -a BTN_LABELS=("Filter" "Discard" "Collapse" "Expand")
  local -a BTN_W=(12 14 14 14)

  # Loading folders.idx + building view can take a while on large catalogs
  UI_BUSY_SOFT=0
  ui_busy_show "Search" "Loading folder list..."
  SEARCH_EXPANDED=()
  search_apply_filter ""
  ui_busy_done
  UI_NEED_DESKTOP=1

  # panel_dirty: redraw list box chrome. list_dirty: viewport rows only.
  local panel_dirty=0
  if [[ "${UI_DESKTOP_READY:-0}" == "1" && "${UI_NEED_DESKTOP}" != "1" ]]; then
    need_full=0
    panel_dirty=1
  fi

  _mark_panel_dirty() {
    panel_dirty=1
    dirty=1
    prev_sel=-1
    prev_scroll=-1
    prev_focus=""
    prev_bsel=-1
    UI_NEED_REPAINT=0
  }
  # Expand/collapse: refresh list rows only (keep box/buttons/footer)
  _mark_list_dirty() {
    dirty=1
    prev_sel=-1
    prev_scroll=-1
    UI_NEED_REPAINT=0
  }

  _act_filter() {
    if ui_filter_dialog "Filter" "${query}"; then
      query="${UI_INPUT_RESULT}"
      ui_drain_keys
      search_apply_filter "${query}"
      sel=0; scroll=0
    fi
    # OSK clear paints desk over footer ? restore footer + list panel (no desktop wipe)
    ui_chrome_footer \
      "$(ui_fit $((UI_COLS-8)) "$(ui_hint_edit_btns)  Enter=Open/Download")"
    ui_hints_ack
    _mark_panel_dirty
  }
  _act_discard() {
    query=""
    UI_BUSY_SOFT=1
    ui_busy_show "Search" "Loading folder list..."
    search_apply_filter ""
    ui_busy_done
    sel=0; scroll=0
    _mark_panel_dirty
  }
  _act_collapse() {
    local t
    for t in "${SEARCH_FOLDER_ORDER[@]}"; do
      SEARCH_EXPANDED["${t}"]=0
    done
    search_tree_rebuild_view
    sel=0; scroll=0
    _mark_list_dirty
  }
  _act_expand() {
    local t n skipped=0
    search_collect_tops
    # Footer status only - no busy overlay (avoids panel flash)
    ui_chrome_footer "$(ui_fit $((UI_COLS-8)) "Expanding...")"
    for t in "${SEARCH_ALL_TOPS[@]}"; do
      n="$(search_folder_count "${t}")"
      # Skip huge groups here — open them with Enter (paged browser)
      if (( n > SEARCH_EXPAND_INLINE_MAX )); then
        SEARCH_EXPANDED["${t}"]=0
        skipped=$((skipped + 1))
        continue
      fi
      SEARCH_EXPANDED["${t}"]=1
      if ! search_children_ready "${t}"; then
        search_ensure_children "${t}" || SEARCH_EXPANDED["${t}"]=0
      fi
    done
    search_tree_rebuild_view
    ui_chrome_footer \
      "$(ui_fit $((UI_COLS-8)) "$(ui_hint_edit_btns)  Enter=Open/Download")"
    ui_hints_ack
    if (( skipped > 0 )); then
      ui_msgbox "Expand" \
        "Expanded smaller groups."$'\n'"${skipped} large group(s) skipped — open with Enter (paged)."
      UI_NEED_DESKTOP=1
      need_full=1
    fi
    sel=0; scroll=0
    _mark_list_dirty
  }
  _focus_folder_row() {
    # Put folder row at top of viewport so as many children as possible are visible
    local top="$1" i
    [[ -n "${top}" ]] || return 0
    for ((i=0; i<${#SEARCH_VIEW_TOP[@]}; i++)); do
      if [[ "${SEARCH_VIEW_TOP[i]}" == "${top}" && "${SEARCH_VIEW_REF[i]}" == "-1" ]]; then
        sel="${i}"
        scroll="${i}"
        SEARCH_MARQUEE_OFF=0
        SEARCH_MARQUEE_SEL="${sel}"
        return 0
      fi
    done
  }
  _collapse_folder() {
    local top="$1" at="${sel}" label nchild
    [[ -n "${top}" ]] || return 0
    SEARCH_EXPANDED["${top}"]=0
    # Fast path: strip children in place (no full rebuild)
    if [[ "${SEARCH_VIEW_TOP[at]:-}" == "${top}" && "${SEARCH_VIEW_REF[at]:-}" == "-1" ]]; then
      _search_remove_children_at "${top}" "${at}"
      nchild="${SEARCH_HASH_COUNT[${top}]:-0}"
      [[ "${nchild}" =~ ^[0-9]+$ ]] || nchild=0
      label="${SEARCH_HASH_LABEL[${top}]:-${top}}"
      (( nchild > 0 )) && label="${label} (${nchild})"
      SEARCH_VIEW[at]="[+] ${label}/"
      ui_vp_reset 2>/dev/null || true
      _focus_folder_row "${top}"
      _mark_list_dirty
      return 0
    fi
    search_tree_rebuild_view
    _focus_folder_row "${top}"
    _mark_list_dirty
  }
  _toggle_folder_at_sel() {
    local top="${SEARCH_VIEW_TOP[sel]:-}" n label at
    [[ -n "${top}" ]] || return 0
    if [[ "${SEARCH_EXPANDED[${top}]:-0}" == "1" ]]; then
      _collapse_folder "${top}"
      return 0
    fi
    n="${SEARCH_HASH_COUNT[${top}]:-0}"
    [[ "${n}" =~ ^[0-9]+$ ]] || n=0
    # Huge group: paged browser (does not freeze on 10k+ rows)
    if (( n > SEARCH_EXPAND_INLINE_MAX )); then
      ui_chrome_footer "$(ui_fit $((UI_COLS-8)) "Opening ${n} files...")"
      search_folder_browser "${top}" || \
        ui_msgbox "Browse" "No file list for this torrent."
      UI_NEED_DESKTOP=1
      need_full=1
      _mark_panel_dirty
      return 0
    fi
    at="${sel}"
    SEARCH_EXPANDED["${top}"]=1
    if ! _search_insert_children_at "${top}" "${at}"; then
      SEARCH_EXPANDED["${top}"]=0
      if [[ -n "${SEARCH_FILTER_Q}" ]]; then
        ui_msgbox "Search" "No matching files in this torrent."
      else
        ui_msgbox "Search" "No file list for this torrent (missing catalog .tsv)."
      fi
      _mark_list_dirty
      return 0
    fi
    label="${SEARCH_HASH_LABEL[${top}]:-${top}}"
    (( n > 0 )) && label="${label} (${n})"
    SEARCH_VIEW[at]="[-] ${label}/"
    ui_vp_reset 2>/dev/null || true
    _focus_folder_row "${top}"
    _mark_list_dirty
  }

  while true; do
    # Progress/download wiped desktop ? full paint. Soft dialogs ? panel only.
    if [[ "${UI_NEED_DESKTOP}" == "1" ]]; then
      UI_NEED_DESKTOP=0
      UI_NEED_REPAINT=0
      need_full=1
    elif [[ "${UI_NEED_REPAINT}" == "1" ]]; then
      UI_NEED_REPAINT=0
      _mark_panel_dirty
    fi
    if ui_check_resize; then need_full=1; fi

    if (( need_full )); then
      ui_paint_desktop
      ui_chrome "$(app_title_ver)" \
        "$(ui_fit $((UI_COLS-8)) "$(ui_hint_edit_btns)  Enter=Open/Download")"
      ui_list_panel_geom 2
      mw="${UI_PW}"; mh="${UI_PH}"; mx="${UI_PX}"; my="${UI_PY}"
      ui_box "${mx}" "${my}" "${mw}" "${mh}" "Browse Torrents"
      ui_vp_reset
      need_full=0
      panel_dirty=0
      dirty=1
      prev_sel=-1
      prev_scroll=-1
      prev_focus=""
      prev_bsel=-1
      ui_hints_ack
    elif (( panel_dirty )); then
      # Soft: keep desktop/chrome, redraw list panel only
      [[ -n "${mx:-}" ]] || ui_list_panel_geom 2
      mw="${UI_PW:-$mw}"; mh="${UI_PH:-$mh}"
      mx="${UI_PX:-$mx}"; my="${UI_PY:-$my}"
      ui_box "${mx}" "${my}" "${mw}" "${mh}" "Browse Torrents"
      ui_vp_reset
      panel_dirty=0
      dirty=1
      prev_sel=-1
      prev_scroll=-1
      prev_focus=""
      prev_bsel=-1
    fi

    tree_top=$((my + 2))
    tree_h=$((mh - 5))
    (( tree_h < 3 )) && tree_h=3
    visible=${#SEARCH_VIEW[@]}
    (( visible > 0 && sel >= visible )) && sel=$((visible - 1))
    (( visible == 0 )) && sel=0
    if (( visible < 1 )); then
      scroll=0
    elif (( sel < scroll || sel >= scroll + tree_h )); then
      ui_list_snap_page sel scroll "${tree_h}" "${visible}"
    fi

    text_w=$((mw - 8))
    (( text_w < 10 )) && text_w=10

    if (( dirty )); then
      local dim=0
      [[ "${focus}" != "list" ]] && dim=1
      # Selection-only: rewrite 1?2 rows (still fast). Full page: batched + line-diff.
      if (( prev_scroll == scroll && prev_sel >= 0 )); then
        ui_buf_reset
        UI_BUF_HOLD=1
        if (( prev_sel >= scroll && prev_sel < scroll + tree_h )); then
          _search_paint_row $((tree_top + prev_sel - scroll)) "${prev_sel}" 0 "${text_w}" "${mx}" 0 \
            $((prev_sel - scroll))
        fi
        if (( sel >= scroll && sel < scroll + tree_h )); then
          _search_paint_row $((tree_top + sel - scroll)) "${sel}" 1 "${text_w}" "${mx}" "${dim}" \
            $((sel - scroll))
        fi
        UI_BUF_HOLD=0
        ui_vp_flush
      else
        ui_vp_begin "${tree_top}" "${tree_h}" $((mx + 3)) "${text_w}"
        UI_BUF_HOLD=1
        for ((i=0; i<tree_h; i++)); do
          row=$((tree_top + i))
          if (( scroll + i < visible )); then
            if (( scroll + i == sel )); then
              _search_paint_row "${row}" $((scroll + i)) 1 "${text_w}" "${mx}" "${dim}" "${i}"
            else
              _search_paint_row "${row}" $((scroll + i)) 0 "${text_w}" "${mx}" 0 "${i}"
            fi
          else
            _search_paint_row "${row}" -1 0 "${text_w}" "${mx}" 0 "${i}"
          fi
        done
        ui_draw_scrollbar $((mx + mw - 3)) "${tree_top}" "${tree_h}" "${visible}" "${tree_h}" "${scroll}"
        UI_BUF_HOLD=0
        ui_vp_flush
      fi
      dirty=0
      prev_sel="${sel}"
      prev_scroll="${scroll}"
    fi

    btn_row=$((my + mh - 3))
    bx=$((mx + 2))
    if [[ "${prev_focus}" != "${focus}" || "${prev_bsel}" != "${bsel}" ]]; then
      local s0=0 s1=0 s2=0 s3=0
      if [[ "${focus}" == "btns" ]]; then
        (( bsel == 0 )) && s0=1
        (( bsel == 1 )) && s1=1
        (( bsel == 2 )) && s2=1
        (( bsel == 3 )) && s3=1
      fi
      # Batch all 4 buttons + status into one tty write
      ui_buf_reset
      UI_BUF_HOLD=1
      ui_draw_item_row "${bx}" "${bx}" "${btn_row}" "${BTN_W[0]}" 0 \
        "${BTN_HOTS[0]}" "${BTN_LABELS[0]}" "" "${s0}"
      ui_draw_item_row $((bx + 13)) $((bx + 13)) "${btn_row}" "${BTN_W[1]}" 0 \
        "${BTN_HOTS[1]}" "${BTN_LABELS[1]}" "" "${s1}"
      ui_draw_item_row $((bx + 28)) $((bx + 28)) "${btn_row}" "${BTN_W[2]}" 0 \
        "${BTN_HOTS[2]}" "${BTN_LABELS[2]}" "" "${s2}"
      ui_draw_item_row $((bx + 43)) $((bx + 43)) "${btn_row}" "${BTN_W[3]}" 0 \
        "${BTN_HOTS[3]}" "${BTN_LABELS[3]}" "" "${s3}"
      local hint="Folders:${SEARCH_STAT_FOLDERS}  Files:${SEARCH_STAT_FILES}"
      [[ -n "${query}" ]] && hint+="  [${query}]"
      ui_goto $((my + mh - 2)) $((mx + 3))
      UI_BUF+="${UI_MUTED}$(printf '%-*.*s' $((mw-6)) $((mw-6)) "$(ui_fit $((mw-6)) "${hint}")")${UI_RST}"
      UI_BUF_HOLD=0
      ui_buf_flush
      prev_focus="${focus}"
      prev_bsel="${bsel}"
    fi

    if ui_hints_need_refresh; then
      # Footer text only ? no desktop/box redraw
      ui_chrome_footer \
        "$(ui_fit $((UI_COLS-8)) "$(ui_hint_edit_btns)  Enter=Open/Download")"
      ui_hints_ack
    fi

    key="$(ui_read_key)" || true
    case "${key}" in
      TIMEOUT)
        # Marquee: scroll long selected row leftward
        if [[ "${focus}" == "list" ]] && (( visible > 0 && sel < visible )); then
          local _raw=" ${SEARCH_VIEW[sel]}"
          if (( ${#_raw} > text_w )); then
            if (( SEARCH_MARQUEE_SEL != sel )); then
              SEARCH_MARQUEE_SEL="${sel}"
              SEARCH_MARQUEE_OFF=0
            else
              SEARCH_MARQUEE_OFF=$((SEARCH_MARQUEE_OFF + 1))
            fi
            if (( sel >= scroll && sel < scroll + tree_h )); then
              local _vp=$((sel - scroll))
              UI_VP_LINE[_vp]=""
              ui_vp_begin "${tree_top}" "${tree_h}" $((mx + 3)) "${text_w}"
              UI_BUF_HOLD=1
              _search_paint_row $((tree_top + _vp)) "${sel}" 1 "${text_w}" "${mx}" 0 "${_vp}"
              UI_BUF_HOLD=0
              ui_vp_flush
            fi
          fi
        fi
        continue
        ;;
      RESIZE) need_full=1; continue ;;
      ESC)
        UI_NEED_DESKTOP=1
        return 0
        ;;
    esac

    if [[ "${focus}" == "list" ]]; then
      case "${key}" in
        UP)
          if (( sel > 0 )); then
            local _c
            ui_coalesce_nav UP
            for ((_c=0; _c<UI_COALESCE_N; _c++)); do
              (( sel > 0 )) || break
              ui_list_nav_up sel scroll "${tree_h}" "${visible}"
            done
            SEARCH_MARQUEE_OFF=0
            SEARCH_MARQUEE_SEL="${sel}"
            dirty=1
          fi
          ;;
        DOWN)
          if (( visible > 0 && sel < visible - 1 )); then
            local _c
            ui_coalesce_nav DOWN
            for ((_c=0; _c<UI_COALESCE_N; _c++)); do
              (( sel < visible - 1 )) || break
              ui_list_nav_down sel scroll "${tree_h}" "${visible}"
            done
            SEARCH_MARQUEE_OFF=0
            SEARCH_MARQUEE_SEL="${sel}"
            dirty=1
          else
            focus="btns"; bsel=0; dirty=1
          fi
          ;;
        LEFT)
          # Collapse open folder (folder row or any child under it)
          if (( visible > 0 && sel < visible )); then
            local top="${SEARCH_VIEW_TOP[sel]:-}"
            if [[ -n "${top}" && "${SEARCH_EXPANDED[${top}]:-0}" == "1" ]]; then
              _collapse_folder "${top}"
            else
              focus="btns"; bsel=$((nb - 1)); prev_focus=""; dirty=1
            fi
          else
            focus="btns"; bsel=$((nb - 1)); prev_focus=""; dirty=1
          fi
          ;;
        RIGHT)
          focus="btns"; bsel=0; prev_focus=""; dirty=1
          ;;
        ENTER|" ")
          if (( visible > 0 && sel < visible )); then
            local vref="${SEARCH_VIEW_REF[sel]}"
            if [[ "${vref}" == "-1" ]]; then
              _toggle_folder_at_sel
            elif [[ "${vref}" =~ ^[0-9]+$ ]]; then
              search_download_selected "${vref}"
              # download progress wiped desktop
              UI_NEED_DESKTOP=1
              need_full=1
            fi
          fi
          ;;
        f|F|/|x|X) _act_filter ;;
        d|D) _act_discard ;;
        c|C) _act_collapse ;;
        e|E) _act_expand ;;
      esac
    else
      case "${key}" in
        UP)
          focus="list"
          prev_focus=""; dirty=1
          ;;
        LEFT)
          ui_coalesce_nav LEFT
          local _c
          for ((_c=0; _c<UI_COALESCE_N; _c++)); do
            if (( bsel <= 0 )); then focus="list"; prev_focus=""; break
            else bsel=$((bsel - 1)); fi
          done
          ;;
        RIGHT)
          ui_coalesce_nav RIGHT
          local _c
          for ((_c=0; _c<UI_COALESCE_N; _c++)); do
            if (( bsel >= nb - 1 )); then focus="list"; prev_focus=""; break
            else bsel=$((bsel + 1)); fi
          done
          ;;
        DOWN) ;;
        ENTER|" ")
          case "${bsel}" in
            0) _act_filter ;;
            1) _act_discard ;;
            2) _act_collapse ;;
            3) _act_expand ;;
          esac
          focus="list"
          prev_focus=""
          ;;
        f|F|/|x|X) _act_filter; focus="list"; prev_focus="" ;;
        d|D) _act_discard; focus="list"; prev_focus="" ;;
        c|C) _act_collapse; focus="list"; prev_focus="" ;;
        e|E) _act_expand; focus="list"; prev_focus="" ;;
      esac
    fi
  done
}

magnet_files_menu() {
  while true; do
    local nmag=0 ntor=0
    shopt -s nullglob
    local m=( "${MAGNETS_DIR}"/*.magnet "${MAGNETS_DIR}"/*.MAGNET "${MAGNETS_DIR}"/*.txt "${MAGNETS_DIR}"/*.TXT )
    local t=( "${MAGNETS_DIR}"/*.torrent "${MAGNETS_DIR}"/*.TORRENT )
    nmag=${#m[@]}; ntor=${#t[@]}

    local -a items=(
      "U|Update Metadata|Fetch torrent metadata (${nmag}+${ntor})"
      "E|Edit Torrent Files|Enable/disable torrent sources"
      "R|Reindex Catalog|Rebuild search index from saved .torrent meta (no re-download)"
      "B|Back|"
    )
    if ! ui_setup_menu "$(app_title_ver)" "Torrent Files" "Torrent Files" "${items[@]}"; then
      return 0
    fi
    case "${UI_MENU_RESULT}" in
      0)
        update_metadata_and_catalog
        case "$?" in
          0) ui_msgbox "Update Metadata" "Finished" ;;
          2) ;;
          *) ;;
        esac
        ;;
      1)
        edit_torrent_magnet_files || true
        if [[ "${SRC_EDIT_CHANGED:-0}" == "1" ]]; then
          # Only fetch/index newly enabled; keep meta for torrents that stayed on
          update_metadata_and_catalog incremental
          case "$?" in
            0) ui_msgbox "Sync Metadata" "Sources changed ? only new/removed torrents updated" ;;
            1) ui_msgbox "Sync Metadata" "Partial sync ? unchanged torrents kept" ;;
          esac
        fi
        ;;
      2)
        [[ "$(type -t reindex_catalog_force 2>/dev/null)" == "function" ]] \
          || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_catalog.sh"
        [[ "$(type -t torrent_meta_usable 2>/dev/null)" == "function" ]] \
          || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fetch_meta.sh"
        reindex_catalog_force
        case "$?" in
          0) ui_msgbox "Reindex Catalog" "Search index rebuilt from saved metadata." ;;
          2) ui_msgbox "Reindex Catalog" "Cancelled." ;;
          3) ui_msgbox "Reindex Catalog" "No usable .torrent metadata to index." ;;
          *) ui_msgbox "Reindex Catalog" "Reindex failed ? check meta/*.torrent" ;;
        esac
        ;;
      3) return 0 ;;
    esac
  done
}
