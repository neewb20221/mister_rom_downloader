#!/usr/bin/env bash
# DAT source settings + update from GitHub / URL
set -uo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DAT_SOURCES_CONF="${APP_DIR}/dat_sources.conf"
DAT_SOURCES_DEFAULTS="${APP_DIR}/dat_sources.defaults.conf"
GITHUB_API="https://api.github.com"
GITHUB_RAW="https://raw.githubusercontent.com"

ensure_dat_sources_conf() {
  ensure_dirs
  if [[ ! -f "${DAT_SOURCES_CONF}" ]]; then
    if [[ -f "${DAT_SOURCES_DEFAULTS}" ]]; then
      cp "${DAT_SOURCES_DEFAULTS}" "${DAT_SOURCES_CONF}"
    else
      die "missing ${DAT_SOURCES_CONF}"
    fi
  fi
  # Repair section headers corrupted by old BusyBox awk gsub(/[\[\]]/)
  if grep -qE '^\[\[+' "${DAT_SOURCES_CONF}" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk '
      /^\[/ {
        line=$0
        gsub(/[][]/, "", line)
        print "[" line "]"
        next
      }
      { print }
    ' "${DAT_SOURCES_CONF}" > "${tmp}"
    mv "${tmp}" "${DAT_SOURCES_CONF}"
  fi
}

dat_source_ids() {
  ensure_dat_sources_conf
  awk '
    /^\[/ {
      line=$0
      gsub(/[][]/, "", line)
      if (line != "") print line
    }
  ' "${DAT_SOURCES_CONF}"
}

dat_get() {
  local id="$1" key="$2"
  ensure_dat_sources_conf
  awk -v id="${id}" -v key="${key}" '
    BEGIN { insec=0 }
    /^\[/ {
      line=$0
      gsub(/[][]/, "", line)
      insec = (line == id)
      next
    }
    insec && index($0, key "=") == 1 {
      sub("^[^=]*=", "")
      gsub(/\r/, "")
      print
      exit
    }
  ' "${DAT_SOURCES_CONF}"
}

dat_set() {
  local id="$1" key="$2" val="$3"
  ensure_dat_sources_conf
  local tmp
  tmp="$(mktemp)"
  # Portable bracket strip: gsub(/[][]/, ...) ? NOT /[\[\]]/ (BusyBox corrupts headers)
  awk -v id="${id}" -v key="${key}" -v val="${val}" '
    BEGIN { insec=0; done=0 }
    /^\[/ {
      if (insec && !done) { print key "=" val; done=1 }
      line=$0
      gsub(/[][]/, "", line)
      insec = (line == id)
      print "[" line "]"
      next
    }
    insec && index($0, key "=") == 1 {
      print key "=" val
      done=1
      next
    }
    { print }
    END {
      if (insec && !done) print key "=" val
    }
  ' "${DAT_SOURCES_CONF}" > "${tmp}"
  mv "${tmp}" "${DAT_SOURCES_CONF}"
}

# File-backed GitHub folder cache (bash $(...) subshells cannot keep RAM globals).
dat_gh_list_clear() {
  rm -f "${DATS_DIR}/.gh_list_cache" "${DATS_DIR}/.gh_list_key" \
    "${DATS_DIR}/.gh_list_cache.partial" 2>/dev/null || true
}

dat_gh_list_ensure() {
  local repo="$1" branch="$2" dir="$3"
  local key="${repo}|${branch}|${dir}" api_url cache keyf rc=0
  mkdir -p "${DATS_DIR}"
  cache="${DATS_DIR}/.gh_list_cache"
  keyf="${DATS_DIR}/.gh_list_key"
  if [[ -s "${cache}" && -f "${keyf}" && "$(cat "${keyf}" 2>/dev/null)" == "${key}" ]]; then
    return 0
  fi
  api_url="${GITHUB_API}/repos/${repo}/contents/${dir}?ref=${branch}"
  http_get "${api_url}" "${cache}.partial"
  rc=$?
  if (( rc != 0 )); then
    rm -f "${cache}.partial"
    return "${rc}"
  fi
  mv -f "${cache}.partial" "${cache}"
  printf '%s' "${key}" > "${keyf}"
  return 0
}

# Prefer aria2 (working CA). Skip curl SSL verify fail loops on MiSTer.
# Return 0 ok, 1 fail, 2 cancelled (when UI_ACTIVE).
http_get() {
  local url="$1" out="$2" logf="${DATS_DIR}/download.log" rc=0 pid wr=0
  mkdir -p "${DATS_DIR}" "$(dirname "${out}")"
  if [[ -x "${ARIA2}" ]]; then
    "${ARIA2}" --allow-overwrite=true --auto-file-renaming=false \
      --follow-torrent=false --follow-metalink=false \
      --dir="$(dirname "${out}")" --out="$(basename "${out}")" \
      --max-connection-per-server=4 --split=4 --min-split-size=1M \
      --max-tries=5 --timeout=120 --connect-timeout=20 \
      --console-log-level=error --summary-interval=0 --quiet=true \
      --disable-ipv6=true \
      "${url}" >>"${logf}" 2>&1 &
    pid=$!
    if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
      ui_wait_pid_abortable "${pid}" aria2
      wr=$?
      (( wr == 2 )) && return 2
      if (( wr == 0 )) && [[ -s "${out}" ]]; then return 0; fi
    else
      wait "${pid}" || rc=$?
      [[ ${rc} -eq 0 && -s "${out}" ]] && return 0
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -kfsSL --connect-timeout 20 --max-time 600 -o "${out}" "${url}" >>"${logf}" 2>&1 &
    pid=$!
    if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
      ui_wait_pid_abortable "${pid}"
      wr=$?
      (( wr == 2 )) && return 2
      if (( wr == 0 )) && [[ -s "${out}" ]]; then return 0; fi
    else
      wait "${pid}" || rc=$?
      [[ ${rc} -eq 0 && -s "${out}" ]] && return 0
    fi
  fi
  warn "need curl or aria2c to download DAT files"
  return 1
}

http_get_stdout() {
  local url="$1" tmp
  mkdir -p "${DATS_DIR}"
  tmp="$(mktemp "${DATS_DIR}/.api_XXXXXX")"
  if http_get "${url}" "${tmp}" && [[ -s "${tmp}" ]]; then
    cat "${tmp}"
    rm -f "${tmp}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# Sets DAT_RESOLVE_DL + DAT_RESOLVE_NAME + DAT_RESOLVE_SIZE (file cache, no subshell).
# GitHub contents JSON is often one line - never use greedy sed .*name.* on the whole file.
resolve_github_prefix_set() {
  local repo="$1" branch="$2" dir="$3" prefix="$4"
  local name size enc_path line cand cand_size
  DAT_RESOLVE_DL=""
  DAT_RESOLVE_NAME=""
  DAT_RESOLVE_SIZE=""
  dat_gh_list_ensure "${repo}" "${branch}" "${dir}" || return 1
  name=""
  size=""
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    cand="$(printf '%s' "${line}" | sed -n 's/.*"name":[[:space:]]*"\([^"]*\)".*/\1/p')"
    [[ -n "${cand}" ]] || continue
    printf '%s' "${cand}" | grep -Fq "${prefix}" || continue
    printf '%s' "${cand}" | grep -Eq '\.dat$' || continue
    cand_size="$(printf '%s' "${line}" | sed -n 's/.*"size":[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    if [[ -z "${name}" || "${cand}" > "${name}" ]]; then
      name="${cand}"
      size="${cand_size}"
    fi
  done < <(tr '{' '\n' < "${DATS_DIR}/.gh_list_cache")
  [[ -n "${name}" ]] || return 1
  DAT_RESOLVE_SIZE="${size}"
  enc_path="$(printf '%s' "${dir}/${name}" | sed 's/ /%20/g')"
  DAT_RESOLVE_DL="${GITHUB_RAW}/${repo}/${branch}/${enc_path}"
  DAT_RESOLVE_NAME="${name}"
  return 0
}
# Returns: 0=updated, 1=failed, 3=unchanged (already up to date)
update_one_source() {
  local id="$1"
  local enabled mode local_name url repo branch dir prefix dl remote tmp dest local_sz rc=0
  enabled="$(dat_get "${id}" enabled)"
  [[ "${enabled}" == "1" ]] || { warn "[${id}] disabled - skip"; return 3; }

  mode="$(dat_get "${id}" mode)"
  local_name="$(dat_get "${id}" local)"
  [[ -n "${local_name}" ]] || die "[${id}] missing local="

  dest="${DATS_DIR}/${local_name}"
  tmp="${dest}.partial"
  mkdir -p "${DATS_DIR}"
  rm -f "${tmp}"

  case "${mode}" in
    url)
      url="$(dat_get "${id}" url)"
      [[ -n "${url}" ]] || die "[${id}] mode=url but url= empty"
      log "[${id}] download ${url}"
      http_get "${url}" "${tmp}"
      rc=$?
      (( rc == 2 )) && { rm -f "${tmp}"; return 2; }
      (( rc != 0 )) && { rm -f "${tmp}"; return 1; }
      ;;
    github_prefix)
      repo="$(dat_get "${id}" repo)"
      branch="$(dat_get "${id}" branch)"
      dir="$(dat_get "${id}" dir)"
      prefix="$(dat_get "${id}" prefix)"
      branch="${branch:-main}"
      dir="${dir:-DatRoot}"
      [[ -n "${repo}" && -n "${prefix}" ]] || die "[${id}] github_prefix needs repo= and prefix="
      log "[${id}] resolve ${repo}/${dir} prefix='${prefix}'"
      if ! resolve_github_prefix_set "${repo}" "${branch}" "${dir}" "${prefix}"; then
        warn "[${id}] no matching .dat on GitHub"
        return 1
      fi
      dl="${DAT_RESOLVE_DL}"
      remote="${DAT_RESOLVE_NAME}"
      log "[${id}] remote=${remote} size=${DAT_RESOLVE_SIZE:-?}"
      # Skip download when local size already matches GitHub listing
      if [[ -f "${dest}" && -n "${DAT_RESOLVE_SIZE}" && "${DAT_RESOLVE_SIZE}" =~ ^[0-9]+$ ]]; then
        local_sz="$(wc -c < "${dest}" 2>/dev/null | tr -d ' ')"
        if [[ "${local_sz}" == "${DAT_RESOLVE_SIZE}" ]]; then
          log "[${id}] unchanged (size ${local_sz})"
          return 3
        fi
      fi
      http_get "${dl}" "${tmp}"
      rc=$?
      (( rc == 2 )) && { rm -f "${tmp}"; return 2; }
      (( rc != 0 )) && { rm -f "${tmp}"; return 1; }
      ;;
    *)
      die "[${id}] unknown mode=${mode}"
      ;;
  esac

  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    return 1
  fi
  if ! head -c 200 "${tmp}" | grep -qiE 'xml|clrmamepro|datafile|game |rom '; then
    warn "[${id}] file does not look like a DAT - keeping anyway"
  fi
  if [[ -f "${dest}" ]] && cmp -s "${tmp}" "${dest}"; then
    rm -f "${tmp}"
    log "[${id}] unchanged"
    return 3
  fi
  mv -f "${tmp}" "${dest}"
  log "[${id}] updated -> ${dest}"
  return 0
}

enabled_dat_files() {
  ensure_dat_sources_conf
  local id local_name path
  for id in $(dat_source_ids); do
    [[ "$(dat_get "${id}" enabled)" == "1" ]] || continue
    local_name="$(dat_get "${id}" local)"
    path="${DATS_DIR}/${local_name}"
    [[ -f "${path}" ]] && printf '%s\n' "${path}"
  done
}

github_list_dat_names() {
  local repo="$1" branch="$2" dir="$3"
  local api_url list
  api_url="${GITHUB_API}/repos/${repo}/contents/${dir}?ref=${branch}"
  list="$(http_get_stdout "${api_url}")" || return 1
  printf '%s\n' "${list}" \
    | grep -oE '"name":[[:space:]]*"[^"]+"' \
    | sed -n 's/.*"\([^"]*\)".*/\1/p' \
    | grep -Ei '\.dat$' \
    | sort -u
}

parse_dat_internet_source() {
  local s="$1"
  PARSE_KIND="" PARSE_REPO="" PARSE_BRANCH="main" PARSE_DIR="DatRoot"
  PARSE_FILE="" PARSE_URL="" PARSE_PREFIX=""
  s="$(printf '%s' "${s}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ "${s}" =~ ^https?://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$ ]]; then
    PARSE_KIND=url
    PARSE_URL="${s}"
    PARSE_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    PARSE_BRANCH="${BASH_REMATCH[3]}"
    PARSE_FILE="$(basename "${BASH_REMATCH[4]}")"
    return 0
  fi
  if [[ "${s}" =~ ^https?://github\.com/([^/]+)/([^/]+)/tree/([^/]+)/(.*)$ ]]; then
    PARSE_KIND=github_dir
    PARSE_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    PARSE_BRANCH="${BASH_REMATCH[3]}"
    PARSE_DIR="${BASH_REMATCH[4]}"
    PARSE_DIR="${PARSE_DIR%/}"
    return 0
  fi
  if [[ "${s}" =~ ^https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$ ]]; then
    PARSE_KIND=github_file
    PARSE_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    PARSE_BRANCH="${BASH_REMATCH[3]}"
    PARSE_FILE="$(basename "${BASH_REMATCH[4]}")"
    PARSE_DIR="$(dirname "${BASH_REMATCH[4]}")"
    [[ "${PARSE_DIR}" == "." ]] && PARSE_DIR=""
    PARSE_URL="${GITHUB_RAW}/${PARSE_REPO}/${PARSE_BRANCH}/$(printf '%s' "${BASH_REMATCH[4]}" | sed 's/ /%20/g')"
    return 0
  fi
  if [[ "${s}" =~ ^https?:// ]]; then
    PARSE_KIND=url
    PARSE_URL="${s}"
    PARSE_FILE="$(basename "${s%%\?*}")"
    return 0
  fi
  if [[ "${s}" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(/.*)?$ ]]; then
    PARSE_KIND=github_dir
    PARSE_REPO="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]-}"
    rest="${rest#/}"
    if [[ -n "${rest}" ]]; then
      if [[ "${rest}" == */* ]]; then
        PARSE_BRANCH="${rest%%/*}"
        PARSE_DIR="${rest#*/}"
      else
        PARSE_DIR="${rest}"
      fi
    fi
    return 0
  fi
  return 1
}

dat_source_display_url() {
  local id="$1" mode repo branch dir prefix url
  mode="$(dat_get "${id}" mode)"
  case "${mode}" in
    url)
      url="$(dat_get "${id}" url)"
      printf '%s' "${url}"
      ;;
    github_prefix)
      repo="$(dat_get "${id}" repo)"
      branch="$(dat_get "${id}" branch)"; branch="${branch:-main}"
      dir="$(dat_get "${id}" dir)"; dir="${dir:-DatRoot}"
      prefix="$(dat_get "${id}" prefix)"
      if [[ -n "${repo}" ]]; then
        printf 'https://github.com/%s/tree/%s/%s' "${repo}" "${branch}" "${dir}"
      else
        printf ''
      fi
      ;;
    *)
      printf '%s' "${mode}"
      ;;
  esac
}

dat_id_from_name() {
  local n="$1"
  n="$(printf '%s' "${n}" | sed -E 's/\.[Dd][Aa][Tt]$//; s/[^A-Za-z0-9]+/_/g; s/^_+|_+$//g; s/_+/_/g')"
  n="${n,,}"
  [[ -n "${n}" ]] || n="dat_source"
  printf '%s' "${n}"
}

dat_append_section() {
  local id="$1" name="$2" mode="$3"
  shift 3
  ensure_dat_sources_conf
  {
    echo
    echo "[${id}]"
    echo "enabled=1"
    echo "name=${name}"
    echo "mode=${mode}"
    local kv
    for kv in "$@"; do
      echo "${kv}"
    done
  } >> "${DAT_SOURCES_CONF}"
}

dat_move_source() {
  local id="$1" dir="$2"
  ensure_dat_sources_conf
  local -a ids=()
  local i pos=-1 x
  while IFS= read -r x; do [[ -n "${x}" ]] && ids+=("${x}"); done < <(dat_source_ids)
  for ((i=0; i<${#ids[@]}; i++)); do
    [[ "${ids[i]}" == "${id}" ]] && pos="${i}"
  done
  (( pos >= 0 )) || return 1
  local swap
  if [[ "${dir}" == "up" ]]; then
    (( pos == 0 )) && return 0
    swap=$((pos - 1))
  else
    (( pos >= ${#ids[@]} - 1 )) && return 0
    swap=$((pos + 1))
  fi
  local tmp a="${ids[pos]}" b="${ids[swap]}"
  ids[pos]="${b}"; ids[swap]="${a}"

  tmp="$(mktemp)"
  local sid
  for sid in "${ids[@]}"; do
    awk -v id="${sid}" '
      BEGIN { insec=0 }
      /^\[/ {
        line=$0
        gsub(/[][]/, "", line)
        insec = (line == id)
        if (insec) print "[" line "]"
        next
      }
      insec { print }
    ' "${DAT_SOURCES_CONF}" >> "${tmp}"
    echo >> "${tmp}"
  done
  {
    awk '/^\[/{exit} {print}' "${DAT_SOURCES_CONF}"
    cat "${tmp}"
  } > "${tmp}.2"
  mv "${tmp}.2" "${DAT_SOURCES_CONF}"
  rm -f "${tmp}"
}

dat_download_with_progress() {
  local id="$1" cur="$2" total="$3"
  local label local_name dest sz=""
  label="$(dat_get "${id}" name)"
  label="${label:-$id}"
  local_name="$(dat_get "${id}" local)"
  if [[ -n "${local_name}" ]]; then
    dest="${DATS_DIR}/${local_name}"
    # Show approximate size hint from previous file if present
    if [[ -f "${dest}" ]]; then
      sz="$(wc -c < "${dest}" 2>/dev/null | tr -d ' ')"
      if [[ "${sz}" =~ ^[0-9]+$ ]] && (( sz > 0 )); then
        if (( sz >= 1048576 )); then
          label+=" (~$((sz / 1048576)) MB)"
        else
          label+=" (~$((sz / 1024)) KB)"
        fi
      fi
    fi
  fi
  if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
    ui_progress_paint "DAT Download" "${cur}" "${total}" "${label}"
  else
    log "[${cur}/${total}] ${label}"
  fi
  update_one_source "${id}"
}

clear_downloaded_dat_files() {
  local f
  shopt -s nullglob
  for f in "${DATS_DIR}"/*.dat "${DATS_DIR}"/*.DAT; do
    rm -f "${f}"
  done
  rm -f "${DATS_DIR}/.entry_count" "${DATS_DIR}/.entry_stamp"
}

update_enabled_dats() {
  ensure_dat_sources_conf
  local -a ids=() upd_names=() same_names=() fail_names=()
  local id n i updated=0 same=0 fail=0 label msg rc
  UI_QUIET=1
  UI_PROGRESS_ACTIVE=0
  dat_gh_list_clear
  # Keep previous .dat files until each download succeeds (update_one_source replaces via .partial).
  rm -f "${DATS_DIR}/.entry_count" "${DATS_DIR}/.entry_stamp"
  for id in $(dat_source_ids); do
    if [[ "$(dat_get "${id}" enabled)" == "1" ]]; then
      ids+=("${id}")
    fi
  done
  n="${#ids[@]}"
  if [[ "${n}" -eq 0 ]]; then
    DAT_UPDATE_OK=0
    DAT_UPDATE_FAIL=0
    DAT_UPDATE_SAME=0
    DAT_UPDATE_MSG="No DAT sources enabled."
    UI_QUIET=0
    return 3
  fi
  # Warm GitHub folder cache once (same DatRoot for all default sources)
  if [[ "$(dat_get "${ids[0]}" mode)" == "github_prefix" ]]; then
    dat_gh_list_ensure \
      "$(dat_get "${ids[0]}" repo)" \
      "$(dat_get "${ids[0]}" branch)" \
      "$(dat_get "${ids[0]}" dir)" || true
  fi
  for ((i=0; i<n; i++)); do
    if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
      ui_activity_tick
      if ui_user_wants_abort; then
        ui_progress_done
        dat_gh_list_clear
        UI_QUIET=0
        DAT_UPDATE_MSG="Cancelled: ${updated} updated, ${same} unchanged, ${fail} failed."
        return 2
      fi
    fi
    label="$(dat_get "${ids[i]}" name)"
    label="${label:-${ids[i]}}"
    rc=0
    dat_download_with_progress "${ids[i]}" $((i + 1)) "${n}" || rc=$?
    case "${rc}" in
      0)
        updated=$((updated + 1))
        upd_names+=("${label}")
        ;;
      2)
        ui_progress_done
        dat_gh_list_clear
        UI_QUIET=0
        DAT_UPDATE_MSG="Cancelled: ${updated} updated, ${same} unchanged, ${fail} failed."
        return 2
        ;;
      3)
        same=$((same + 1))
        same_names+=("${label}")
        ;;
      *)
        fail=$((fail + 1))
        fail_names+=("${label}")
        ;;
    esac
  done
  msg="Updated ${updated}  Unchanged ${same}"
  (( fail > 0 )) && msg+="  Failed ${fail}"
  if (( ${#upd_names[@]} > 0 )); then
    msg+=$'\n'"Updated: $(IFS=', '; echo "${upd_names[*]}")"
  fi
  if (( ${#same_names[@]} > 0 )); then
    msg+=$'\n'"Unchanged: $(IFS=', '; echo "${same_names[*]}")"
  fi
  if (( ${#fail_names[@]} > 0 )); then
    msg+=$'\n'"Fail: $(IFS=', '; echo "${fail_names[*]}")"
  fi
  DAT_UPDATE_MSG="${msg}"
  if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
    ui_progress_paint "DAT Download" "${n}" "${n}" "Done: ${updated} updated, ${same} unchanged, ${fail} failed"
    ui_progress_done
    ui_drain_keys
  fi
  DAT_UPDATE_OK="${updated}"
  DAT_UPDATE_SAME="${same}"
  DAT_UPDATE_FAIL="${fail}"
  rm -f "${DATS_DIR}/.entry_count" "${DATS_DIR}/.entry_stamp"
  dat_gh_list_clear
  UI_QUIET=0
  (( fail == n )) && return 1
  return 0
}
dat_add_from_internet() {
  local raw="$1"
  parse_dat_internet_source "${raw}" || { ui_msgbox "Add DAT" "Cannot parse source URL/path"; return 1; }

  local names=() name id local_name prefix repo branch dir file url
  repo="${PARSE_REPO}"; branch="${PARSE_BRANCH}"; dir="${PARSE_DIR}"
  file="${PARSE_FILE}"; url="${PARSE_URL}"

  case "${PARSE_KIND}" in
    github_dir)
      if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
        ui_progress_paint "Add DAT Source" 0 1 "Listing GitHub folder..."
      fi
      while IFS= read -r name; do
        [[ -n "${name}" ]] && names+=("${name}")
      done < <(github_list_dat_names "${repo}" "${branch}" "${dir}")
      (( ${#names[@]} > 0 )) || { ui_msgbox "Add DAT" "No .dat files found in folder"; return 1; }
      local i total="${#names[@]}"
      for ((i=0; i<total; i++)); do
        if [[ "${UI_ACTIVE:-0}" == "1" ]] && ui_user_wants_abort; then
          ui_progress_done
          ui_msgbox "Add DAT" "Cancelled after ${i}/${total}."
          return 2
        fi
        name="${names[i]}"
        local_name="$(printf '%s' "${name}" | sed -E 's/ \([0-9]+\)\.[Dd][Aa][Tt]$/.dat/')"
        [[ "${local_name}" == *.dat || "${local_name}" == *.DAT ]] || local_name="${name}"
        id="$(dat_id_from_name "${local_name}")"
        while dat_source_ids | grep -qx "${id}"; do id="${id}_x"; done
        prefix="$(printf '%s' "${name}" | sed -E 's/ \([0-9]+\)\.[Dd][Aa][Tt]$//')"
        prefix="${prefix} ("
        dat_append_section "${id}" "${local_name%.dat}" github_prefix \
          "repo=${repo}" "branch=${branch}" "dir=${dir}" "prefix=${prefix}" "local=${local_name}"
        if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
          ui_progress_paint "Add DAT Source" $((i + 1)) "${total}" "Download ${name}"
        fi
        update_one_source "${id}" || warn "download failed: ${name}"
      done
      ui_msgbox "Add DAT" "Added ${#names[@]} DAT file(s) from folder"
      ;;
    github_file|url)
      [[ -n "${file}" ]] || file="download.dat"
      local_name="$(printf '%s' "${file}" | sed -E 's/ \([0-9]+\)\.[Dd][Aa][Tt]$/.dat/')"
      id="$(dat_id_from_name "${local_name}")"
      while dat_source_ids | grep -qx "${id}"; do id="${id}_x"; done
      if [[ "${PARSE_KIND}" == "github_file" ]]; then
        prefix="$(printf '%s' "${file}" | sed -E 's/ \([0-9]+\)\.[Dd][Aa][Tt]$//')"
        prefix="${prefix} ("
        dat_append_section "${id}" "${local_name%.dat}" github_prefix \
          "repo=${repo}" "branch=${branch}" "dir=${dir}" "prefix=${prefix}" "local=${local_name}"
      else
        dat_append_section "${id}" "${local_name%.dat}" url \
          "url=${url}" "local=${local_name}"
      fi
      if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
        ui_progress_paint "Add DAT Source" 1 1 "Downloading ${local_name}"
      fi
      update_one_source "${id}" || { ui_msgbox "Add DAT" "Download failed"; return 1; }
      ui_msgbox "Add DAT" "Added ${local_name}"
      ;;
    *)
      ui_msgbox "Add DAT" "Unsupported source kind"
      return 1
      ;;
  esac
  return 0
}

dat_edit_source_internet() {
  local id="$1" cur new
  cur="$(dat_source_display_url "${id}")"
  # Always prefill with current internet source (never empty if conf is valid)
  if [[ -z "${cur}" ]]; then
    cur="https://github.com/MiSTerOrganize/MiSTer_Organize/tree/main/DatRoot"
  fi
  if ! ui_input_box "Edit DAT Source" "Edit internet source URL for this DAT:" "${cur}"; then
    return 1
  fi
  new="${UI_INPUT_RESULT}"
  [[ -n "${new}" ]] || return 1
  parse_dat_internet_source "${new}" || { ui_msgbox "Edit" "Cannot parse source"; return 1; }

  local local_name prefix
  local_name="$(dat_get "${id}" local)"
  case "${PARSE_KIND}" in
    github_dir)
      dat_set "${id}" mode github_prefix
      dat_set "${id}" repo "${PARSE_REPO}"
      dat_set "${id}" branch "${PARSE_BRANCH}"
      dat_set "${id}" dir "${PARSE_DIR}"
      ;;
    github_file)
      dat_set "${id}" mode github_prefix
      dat_set "${id}" repo "${PARSE_REPO}"
      dat_set "${id}" branch "${PARSE_BRANCH}"
      dat_set "${id}" dir "${PARSE_DIR}"
      prefix="$(printf '%s' "${PARSE_FILE}" | sed -E 's/ \([0-9]+\)\.[Dd][Aa][Tt]$//')"
      dat_set "${id}" prefix "${prefix} ("
      local_name="$(printf '%s' "${PARSE_FILE}" | sed -E 's/ \([0-9]+\)\.[Dd][Aa][Tt]$/.dat/')"
      dat_set "${id}" local "${local_name}"
      ;;
    url)
      dat_set "${id}" mode url
      dat_set "${id}" url "${PARSE_URL}"
      [[ -n "${PARSE_FILE}" ]] && dat_set "${id}" local "${PARSE_FILE}"
      ;;
  esac

  if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
    ui_progress_paint "Update DAT" 1 1 "$(dat_get "${id}" name)"
  fi
  update_one_source "${id}" || { ui_msgbox "Edit" "Download failed"; return 1; }
  ui_msgbox "Edit" "Source updated and downloaded"
  return 0
}

dat_edit_files_ui() {
  ensure_dat_sources_conf
  local -a ids=() names=() flags=()
  local -a BTN_HOTS=("A" "N" "E" "+" "U" "D")
  local -a BTN_LABELS=("All" "None" "Edit" "Add" "Up" "Down")
  local -a BTN_W=(8 8 8 8 6 8)
  local -a BTN_X=(0 9 18 27 36 43)
  local id sel=0 scroll=0 key need_full=1 dirty=1
  local mx my mw mh list_top list_h n i row mark line
  local btn_row bx focus="list" bsel=0 nb=6 prev_focus="" prev_sel=-1 prev_bsel=-1 prev_scroll=-1
  local snap_before="" sel_n=0
  DAT_EDIT_CHANGED=0

  _dat_save_flags() {
    local i
    for ((i=0; i<${#ids[@]}; i++)); do
      dat_set "${ids[i]}" enabled "${flags[i]}"
    done
  }
  _dat_flags_snapshot() {
    local i s=""
    for ((i=0; i<${#flags[@]}; i++)); do s+="${flags[i]}"; done
    printf '%s' "${s}"
  }
  _dat_count_selected() {
    local c=0 i
    for ((i=0; i<${#flags[@]}; i++)); do
      [[ "${flags[i]}" == "1" ]] && c=$((c + 1))
    done
    printf '%d' "${c}"
  }
  _dat_set_all_flags() {
    local en="$1" i
    for ((i=0; i<${#flags[@]}; i++)); do
      flags[i]="${en}"
    done
  }

  _dat_reload_edit_arrays() {
    ids=(); names=(); flags=()
    while IFS= read -r id; do
      [[ -n "${id}" ]] || continue
      ids+=("${id}")
      names+=("$(dat_get "${id}" name)")
      flags+=("$(dat_get "${id}" enabled)")
    done < <(dat_source_ids)
  }
  _dat_act_all() {
    _dat_set_all_flags 1
    dirty=1; prev_scroll=-1; prev_focus=""; prev_bsel=-1
  }
  _dat_act_none() {
    _dat_set_all_flags 0
    dirty=1; prev_scroll=-1; prev_focus=""; prev_bsel=-1
  }
  _dat_act_edit() {
    (( n > 0 )) || return 0
    _dat_save_flags
    dat_edit_source_internet "${ids[sel]}" || true
    _dat_reload_edit_arrays
    snap_before="$(_dat_flags_snapshot)"
    soft_panel=1
  }
  _dat_act_up() {
    (( n > 0 )) || return 0
    _dat_save_flags
    dat_move_source "${ids[sel]}" up || true
    _dat_reload_edit_arrays
    n="${#ids[@]}"
    snap_before="$(_dat_flags_snapshot)"
    (( sel > 0 )) && sel=$((sel - 1))
    soft_panel=1
    dirty=1
    prev_scroll=-1
    prev_sel=-1
    prev_focus=""
  }
  _dat_act_down() {
    (( n > 0 )) || return 0
    _dat_save_flags
    dat_move_source "${ids[sel]}" down || true
    _dat_reload_edit_arrays
    n="${#ids[@]}"
    snap_before="$(_dat_flags_snapshot)"
    (( sel < n - 1 )) && sel=$((sel + 1))
    soft_panel=1
    dirty=1
    prev_scroll=-1
    prev_sel=-1
    prev_focus=""
  }
  _dat_act_add() {
    _dat_save_flags
    if ui_input_box "Add DAT Source" "New GitHub folder/file URL or direct .dat URL:" ""; then
      [[ -n "${UI_INPUT_RESULT}" ]] || { soft_panel=1; return 0; }
      dat_add_from_internet "${UI_INPUT_RESULT}" || true
      _dat_reload_edit_arrays
      snap_before="$(_dat_flags_snapshot)"
    fi
    soft_panel=1
  }

  _dat_reload_edit_arrays
  snap_before="$(_dat_flags_snapshot)"
  DAT_EDIT_CHANGED=0

  local soft_panel=0
  if [[ "${UI_DESKTOP_READY:-0}" == "1" && "${UI_NEED_DESKTOP}" != "1" ]]; then
    need_full=0
    soft_panel=1
  fi
  while true; do
    if [[ "${UI_NEED_DESKTOP}" == "1" ]]; then
      UI_NEED_DESKTOP=0
      UI_NEED_REPAINT=0
      need_full=1
      soft_panel=0
    elif [[ "${UI_NEED_REPAINT}" == "1" ]]; then
      UI_NEED_REPAINT=0
      soft_panel=1
    fi
    if ui_check_resize; then need_full=1; soft_panel=0; fi
    n="${#ids[@]}"
    list_h="${n}"
    (( list_h < 1 )) && list_h=1
    (( list_h > UI_ROWS - 14 )) && list_h=$((UI_ROWS - 14))
    mh=$(( list_h + 7 ))
    (( mh < 10 )) && mh=10
    (( mh > UI_ROWS - 6 )) && mh=$((UI_ROWS - 6))
    ui_list_panel_geom 2
    mw="${UI_PW}"
    mx="${UI_PX}"
    my=$(( (UI_ROWS - mh) / 2 ))
    (( my < 4 )) && my=4

    if (( need_full || soft_panel )); then
      if (( need_full )); then
        ui_paint_desktop
        ui_chrome "$(app_title_ver)" "$(ui_fit $((UI_COLS-8)) "$(ui_hint_edit_btns)  Up/Down=Priority")"
      fi
      ui_box "${mx}" "${my}" "${mw}" "${mh}" "Edit DAT Files"
      prev_focus=""; prev_sel=-1; prev_bsel=-1; prev_scroll=-1
      dirty=1
      need_full=0
      soft_panel=0
      ui_hints_ack
    fi

    list_top=$((my + 2))
    (( n > 0 && sel >= n )) && sel=$((n - 1))
    (( sel < 0 )) && sel=0
    if (( n < 1 )); then
      scroll=0
    elif (( sel < scroll || sel >= scroll + list_h )); then
      ui_list_snap_page sel scroll "${list_h}" "${n}"
    fi

    if (( dirty )); then
      local dim=0
      [[ "${focus}" != "list" ]] && dim=1
      if (( prev_scroll == scroll && prev_sel >= 0 )); then
        if (( prev_sel >= scroll && prev_sel < scroll + list_h )); then
          row=$((list_top + prev_sel - scroll))
          line=""
          if (( prev_sel < n )); then
            if [[ "${flags[prev_sel]}" == "1" ]]; then mark="[X]"; else mark="[ ]"; fi
            line="$(printf '%2d. %s %s' $((prev_sel + 1)) "${mark}" "${names[prev_sel]:-${ids[prev_sel]}}")"
            line="$(ui_fit_path $((mw-4)) " ${line}")"
          fi
          printf '\e[%d;%dH%s%-*.*s%s' "${row}" $((mx+2)) "${UI_PANEL}" $((mw-4)) $((mw-4)) "${line}" "${UI_RST}"
        fi
        if (( n > 0 && sel >= scroll && sel < scroll + list_h )); then
          row=$((list_top + sel - scroll))
          if [[ "${flags[sel]}" == "1" ]]; then mark="[X]"; else mark="[ ]"; fi
          line="$(printf '%2d. %s %s' $((sel + 1)) "${mark}" "${names[sel]:-${ids[sel]}}")"
          line="$(ui_fit_path $((mw-4)) " ${line}")"
          printf '\e[%d;%dH' "${row}" $((mx+2))
          if (( dim )); then
            printf '%s%-*.*s%s' "${UI_DIMSEL}" $((mw-4)) $((mw-4)) "${line}" "${UI_RST}"
          else
            printf '%s%-*.*s%s' "${UI_SEL}" $((mw-4)) $((mw-4)) "${line}" "${UI_RST}"
          fi
        fi
      else
        for ((i=0; i<list_h; i++)); do
          row=$((list_top + i))
          line=""
          if (( scroll + i < n )); then
            if [[ "${flags[scroll + i]}" == "1" ]]; then mark="[X]"; else mark="[ ]"; fi
            line="$(printf '%2d. %s %s' $((scroll + i + 1)) "${mark}" "${names[scroll + i]:-${ids[scroll + i]}}")"
            line="$(ui_fit_path $((mw-4)) " ${line}")"
          fi
          printf '\e[%d;%dH' "${row}" $((mx+2))
          if (( n > 0 && scroll + i == sel )); then
            if (( dim )); then
              printf '%s%-*.*s%s' "${UI_DIMSEL}" $((mw-4)) $((mw-4)) "${line}" "${UI_RST}"
            else
              printf '%s%-*.*s%s' "${UI_SEL}" $((mw-4)) $((mw-4)) "${line}" "${UI_RST}"
            fi
          else
            printf '%s%-*.*s%s' "${UI_PANEL}" $((mw-4)) $((mw-4)) "${line}" "${UI_RST}"
          fi
        done
        ui_draw_scrollbar $((mx + mw - 3)) "${list_top}" "${list_h}" "${n}" "${list_h}" "${scroll}"
      fi
      dirty=0
      prev_sel="${sel}"
      prev_scroll="${scroll}"
    fi

    btn_row=$((my + mh - 3))
    bx=$((mx + 2))
    if [[ "${prev_focus}" != "${focus}" || "${prev_bsel}" != "${bsel}" ]]; then
      local bi selb
      for ((bi=0; bi<nb; bi++)); do
        selb=0
        [[ "${focus}" == "btns" && "${bsel}" -eq "${bi}" ]] && selb=1
        ui_draw_item_row $((bx + BTN_X[bi])) $((bx + BTN_X[bi])) "${btn_row}" "${BTN_W[bi]}" 0 \
          "${BTN_HOTS[bi]}" "${BTN_LABELS[bi]}" "" "${selb}"
      done
      sel_n="$(_dat_count_selected)"
      printf '\e[%d;%dH%s%-*.*s%s' $((my+mh-2)) $((mx+2)) \
        "${UI_MUTED}" $((mw-4)) $((mw-4)) \
        "$(ui_fit $((mw-4)) "Selected:${sel_n}/${n}  Up/Down=Priority")" "${UI_RST}"
      prev_focus="${focus}"; prev_bsel="${bsel}"
    fi

    if ui_hints_need_refresh; then
      ui_chrome "$(app_title_ver)" "$(ui_fit $((UI_COLS-8)) "$(ui_hint_edit_btns)  Up/Down=Priority")"
      ui_hints_ack
    fi

    key="$(ui_read_key)" || true
    case "${key}" in
      TIMEOUT) continue ;;
      RESIZE) need_full=1; continue ;;
      ESC)
        if [[ "$(_dat_flags_snapshot)" != "${snap_before}" ]]; then
          _dat_save_flags
          DAT_EDIT_CHANGED=1
        fi
        return 0
        ;;
    esac

    if [[ "${focus}" == "list" ]]; then
      case "${key}" in
        UP)
          if (( sel > 0 )); then
            ui_list_nav_up sel scroll "${list_h}" "${n}"
            dirty=1
          fi
          ;;
        DOWN)
          if (( n > 0 && sel < n - 1 )); then
            ui_list_nav_down sel scroll "${list_h}" "${n}"
            dirty=1
          else
            focus="btns"; bsel=0; dirty=1
          fi
          ;;
        LEFT|RIGHT)
          focus="btns"
          [[ "${key}" == "LEFT" ]] && bsel=$((nb - 1)) || bsel=0
          prev_focus=""; dirty=1
          ;;
        " "|ENTER)
          if (( n > 0 )); then
            if [[ "${flags[sel]}" == "1" ]]; then flags[sel]=0; else flags[sel]=1; fi
            dirty=1; prev_sel=-1; prev_focus=""; prev_bsel=-1
          fi
          ;;
        a|A) _dat_act_all ;;
        n|N) _dat_act_none ;;
        e|E) _dat_act_edit ;;
        u|U) _dat_act_up ;;
        d|D|-|_) _dat_act_down ;;
        +|=) _dat_act_add ;;
      esac
    else
      case "${key}" in
        UP)
          focus="list"
          prev_focus=""; dirty=1
          ;;
        LEFT)
          if (( bsel <= 0 )); then
            focus="list"
            prev_focus=""
          else
            bsel=$((bsel - 1))
          fi
          ;;
        RIGHT)
          if (( bsel >= nb - 1 )); then
            focus="list"
            prev_focus=""
          else
            bsel=$((bsel + 1))
          fi
          ;;
        DOWN) ;;
        ENTER|" ")
          case "${bsel}" in
            0) _dat_act_all ;;
            1) _dat_act_none ;;
            2) _dat_act_edit ;;
            3) _dat_act_add ;;
            4) _dat_act_up ;;
            5) _dat_act_down ;;
          esac
          focus="list"
          prev_focus=""
          ;;
        a|A) _dat_act_all; focus="list"; prev_focus="" ;;
        n|N) _dat_act_none; focus="list"; prev_focus="" ;;
        e|E) _dat_act_edit; focus="list"; prev_focus="" ;;
        u|U) _dat_act_up; focus="list"; prev_focus="" ;;
        d|D|-|_) _dat_act_down; focus="list"; prev_focus="" ;;
        +|=) _dat_act_add; focus="list"; prev_focus="" ;;
      esac
    fi
  done
}

dat_settings_menu() {
  ensure_dat_sources_conf
  while true; do
    local -a items=(
      "U|Update All|Download latest enabled DAT files"
      "E|Edit Files|Flags, Add, Edit source, Priority"
      "B|Back|"
    )
    if ! ui_setup_menu \
      "$(app_title_ver)" \
      "DAT Files" \
      "DAT Files" \
      "${items[@]}"; then
      return 0
    fi
    case "${UI_MENU_RESULT}" in
      0)
        update_enabled_dats
        case "$?" in
          0) ui_msgbox "DAT Files" "${DAT_UPDATE_MSG:-Update finished.}" ;;
          2) ui_msgbox "DAT Files" "${DAT_UPDATE_MSG:-Update cancelled.}" ;;
          3) ui_msgbox "DAT Files" "No DAT sources enabled - nothing to download." ;;
          *) ui_msgbox "DAT Files" "${DAT_UPDATE_MSG:-Update failed.}"$'\n'"See dats/download.log" ;;
        esac
        ;;
      1)
        dat_edit_files_ui || true
        if [[ "${DAT_EDIT_CHANGED:-0}" == "1" ]]; then
          update_enabled_dats
          case "$?" in
            0) ui_msgbox "DAT Files" "Flags saved"$'\n'"${DAT_UPDATE_MSG:-DATs refreshed}" ;;
            2) ui_msgbox "DAT Files" "Update cancelled." ;;
            3) ui_msgbox "DAT Files" "Flags saved ? no sources enabled, DAT folder cleared." ;;
          esac
        fi
        ;;
      2) return 0 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  dat_settings_menu
fi
