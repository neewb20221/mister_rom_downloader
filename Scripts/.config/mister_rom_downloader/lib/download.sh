#!/usr/bin/env bash
# Selective download (no seed / no upload) + place into /games
set -uo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Parse last aria2 summary line from log ? sets DL_* globals
# Example: [#2f4a9b 1.2MiB/4.5MiB(26%) CN:3 SD:2 DL:150KiB ETA:22s]
# Console readout uses \r in-place updates ? split those into lines first.
_dl_parse_aria_log() {
  local logf="$1" line unit mul
  DL_GOT="${2:-0}"
  DL_TOTAL="${3:-0}"
  DL_SPEED=0
  DL_SEEDS=0
  DL_PEERS=0
  DL_ETA=0
  DL_STATUS="connecting"
  [[ -f "${logf}" ]] || return 0
  # Last ~8KiB, CR?LF, last progress / summary line
  line="$(
    tail -c 8192 "${logf}" 2>/dev/null \
      | tr '\r' '\n' \
      | grep -E '\[#[0-9a-fA-F]+| DL:|CN:|SD:|SEED:' \
      | tail -n1 || true
  )"
  [[ -n "${line}" ]] || return 0

  # SIZE/TOTAL
  if [[ "${line}" =~ ([0-9.]+)([KMGT]?i?B)/([0-9.]+)([KMGT]?i?B) ]]; then
    unit="${BASH_REMATCH[2]}"
    case "${unit}" in
      KiB|KB) mul=1024 ;; MiB|MB) mul=1048576 ;; GiB|GB) mul=1073741824 ;; *) mul=1 ;;
    esac
    DL_GOT="$(awk -v n="${BASH_REMATCH[1]}" -v m="${mul}" 'BEGIN{printf "%d", n*m+0.5}')"
    unit="${BASH_REMATCH[4]}"
    case "${unit}" in
      KiB|KB) mul=1024 ;; MiB|MB) mul=1048576 ;; GiB|GB) mul=1073741824 ;; *) mul=1 ;;
    esac
    DL_TOTAL="$(awk -v n="${BASH_REMATCH[3]}" -v m="${mul}" 'BEGIN{printf "%d", n*m+0.5}')"
  fi
  # Speed
  if [[ "${line}" =~ DL:([0-9.]+)([KMGT]?i?B) ]]; then
    unit="${BASH_REMATCH[2]}"
    case "${unit}" in
      KiB|KB) mul=1024 ;; MiB|MB) mul=1048576 ;; GiB|GB) mul=1073741824 ;; *) mul=1 ;;
    esac
    DL_SPEED="$(awk -v n="${BASH_REMATCH[1]}" -v m="${mul}" 'BEGIN{printf "%d", n*m+0.5}')"
  fi
  # Seeds / connections (peers?CN). Some builds use SEED: instead of SD:
  if [[ "${line}" =~ SD:([0-9]+) ]]; then DL_SEEDS="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ SEED:([0-9]+) ]]; then DL_SEEDS="${BASH_REMATCH[1]}"; fi
  if [[ "${line}" =~ CN:([0-9]+) ]]; then DL_PEERS="${BASH_REMATCH[1]}"; fi
  # ETA: 1h2m3s | 2m3s | 45s | 0s
  if [[ "${line}" =~ ETA:([^]\ ]+) ]]; then
    local eta_s="${BASH_REMATCH[1]}" h=0 m=0 s=0
    [[ "${eta_s}" =~ ([0-9]+)h ]] && h="${BASH_REMATCH[1]}"
    [[ "${eta_s}" =~ ([0-9]+)m ]] && m="${BASH_REMATCH[1]}"
    [[ "${eta_s}" =~ ([0-9]+)s ]] && s="${BASH_REMATCH[1]}"
    DL_ETA=$((h * 3600 + m * 60 + s))
  fi
  if (( DL_SPEED > 0 || DL_GOT > 0 )); then
    DL_STATUS="downloading"
  elif (( DL_SEEDS > 0 || DL_PEERS > 0 )); then
    DL_STATUS="connected"
  else
    DL_STATUS="finding peers"
  fi
}

# Download a single file from a .torrent by 1-based index. No seeding.
# Args: hash idx size path target_rel
# Return: 0 ok, 1 fail, 2 cancelled
# Portable file size (BusyBox find has no -printf)
_dl_file_size() {
  local f="$1" n
  [[ -f "${f}" ]] || { printf '0'; return 0; }
  n="$(wc -c < "${f}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "${n}"
}

_dl_find_by_basename() {
  local work="$1" base="$2"
  find "${work}" -type f -name "${base}" 2>/dev/null | head -n1 || true
}

# Remove cancelled / discarded download artifacts for one torrent hash.
_dl_discard_work() {
  local hash="$1" path="${2:-}" base work f
  hash="${hash//$'\r'/}"
  [[ -n "${hash}" ]] || return 0
  work="${INBOX_DIR}/${hash}"
  if [[ -n "${path}" ]]; then
    path="${path#./}"
    base="$(basename "${path}")"
    [[ -n "${base}" ]] && rm -f "${INBOX_DIR}/${base}" 2>/dev/null || true
    [[ -n "${path}" ]] && rm -f "${work}/${path}" 2>/dev/null || true
    [[ -n "${base}" ]] && rm -f "${work}/${base}" 2>/dev/null || true
    if [[ -n "${base}" && -d "${work}" ]]; then
      f="$(_dl_find_by_basename "${work}" "${base}")"
      [[ -n "${f}" ]] && rm -f "${f}" 2>/dev/null || true
    fi
  fi
  # Drop aria2 control files + empty leftovers under this hash work dir
  if [[ -d "${work}" ]]; then
    find "${work}" -type f \( -name '*.aria2' -o -size 0 \) -delete 2>/dev/null || true
    # If only partials remain after cancel, remove whole work tree
    rm -rf "${work}" 2>/dev/null || true
  fi
  rm -f "${INBOX_DIR}/download_${hash}.log" 2>/dev/null || true
}

download_one_rom() {
  local hash="$1" idx="$2" size="${3:-0}" path="$4" target="$5"
  local torrent work src dest dest_dir pid rc=0 got=0 expected label
  local use_ui=0 logf trackers idle_ticks=0 sz base quiet_prev
  local prev_got=0 poll_n=0 instant=0 speed_ema=0
  DL_GOT=0 DL_TOTAL=0 DL_SPEED=0 DL_SEEDS=0 DL_PEERS=0 DL_ETA=0 DL_STATUS=""
  DOWNLOAD_LAST_SRC=""

  # Strip CR from catalog fields (Windows-built TSV / paste)
  hash="${hash//$'\r'/}"
  idx="${idx//$'\r'/}"
  size="${size//$'\r'/}"
  path="${path//$'\r'/}"
  path="${path#./}"

  need_aria2 || return 1
  ensure_dirs
  [[ "$(type -t kill_aria2_orphans 2>/dev/null)" == "function" ]] \
    || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fetch_meta.sh"
  [[ "$(type -t bt_tracker_csv 2>/dev/null)" == "function" ]] \
    || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fetch_meta.sh"

  torrent="${META_DIR}/${hash}.torrent"
  [[ -f "${torrent}" ]] || torrent="$(find "${META_DIR}" -maxdepth 1 -iname "${hash}.torrent" 2>/dev/null | head -n1 || true)"
  [[ -f "${torrent}" ]] || { warn "missing torrent meta for ${hash}"; return 1; }
  # Reject aria2/go.torrent "dynamic metainfo" stubs (cause errorCode=25 Bencode decoding failed)
  if [[ "$(type -t torrent_meta_usable 2>/dev/null)" == "function" ]] \
    && ! torrent_meta_usable "${torrent}"; then
    warn "unusable/stub torrent meta for ${hash}"
    return 1
  fi
  if head -c 120 "${torrent}" 2>/dev/null | grep -q 'dynamic metainfo'; then
    warn "stub torrent meta (dynamic metainfo) for ${hash}"
    return 1
  fi

  # aria2 --select-file wants a positive integer
  [[ "${idx}" =~ ^[0-9]+$ ]] && (( idx >= 1 )) || { warn "bad file index: ${idx}"; return 1; }

  work="${INBOX_DIR}/${hash}"
  mkdir -p "${work}"
  # Empty target = download only; caller places after CRC prompt
  if [[ -n "${target}" ]]; then
    dest="${GAMES_ROOT}/${target}"
    dest_dir="$(dirname "${dest}")"
    mkdir -p "${dest_dir}"
  else
    dest=""
  fi

  [[ "${size}" =~ ^[0-9]+$ ]] || size=0
  expected="${size}"
  (( expected < 1 )) && expected=1
  base="$(basename "${path}")"
  label="${base}"
  [[ "${UI_ACTIVE:-0}" == "1" ]] && use_ui=1

  # Hide log/warn stdout noise over Steel Sky (was black text mid-screen)
  quiet_prev="${UI_QUIET:-0}"
  (( use_ui )) && UI_QUIET=1

  kill_aria2_orphans
  UI_PROGRESS_ACTIVE=0
  # Drop stale aria2 control files that can make the 2nd download exit instantly
  rm -f "${work}/"*.aria2 2>/dev/null || true

  logf="${INBOX_DIR}/download_${hash}.log"
  : > "${logf}"
  trackers="$(bt_tracker_csv)"

  # Trackers + DHT required on MiSTer/NAT. Console readout often silent when
  # stdout is not a TTY ? speed/ETA are measured from on-disk file growth.
  "${ARIA2}" \
    --conf-path="${ARIA2_CONF}" \
    --dir="${work}" \
    --select-file="${idx}" \
    --seed-ratio=0.0 \
    --seed-time=0 \
    --max-upload-limit=1K \
    --bt-max-peers=32 \
    --split=1 \
    --max-connection-per-server=1 \
    --file-allocation=none \
    --bt-remove-unselected-file=true \
    --bt-detach-seed-only=true \
    --bt-tracker="${trackers}" \
    --bt-stop-timeout=0 \
    --dht-file-path="${META_DIR}/dht.dat" \
    --enable-dht=true \
    --enable-peer-exchange=true \
    --bt-enable-lpd=false \
    --dht-entry-point=router.bittorrent.com:6881 \
    --dht-entry-point=dht.transmissionbt.com:6881 \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --console-log-level=notice \
    --summary-interval=1 \
    --show-console-readout=true \
    --quiet=false \
    --log="${logf}" \
    --log-level=notice \
    "${torrent}" >>"${logf}" 2>&1 &
  pid=$!
  printf '[%s] pid=%s file=%s idx=%s\n' "$(date '+%F %T' 2>/dev/null || true)" \
    "${pid}" "${path}" "${idx}" >>"${INBOX_DIR}/download.log"

  # If aria2 died immediately, surface log tail
  sleep 0.2
  if ! kill -0 "${pid}" 2>/dev/null; then
    wait "${pid}" 2>/dev/null || rc=$?
    kill_aria2_orphans
    cat "${logf}" >>"${INBOX_DIR}/download.log" 2>/dev/null || true
    (( use_ui )) && ui_progress_done
    if (( use_ui )); then UI_QUIET=1; else UI_QUIET="${quiet_prev}"; warn "aria2 exited early rc=${rc} for ${path}"; fi
    return 1
  fi

  prev_got=0
  poll_n=0
  speed_ema=0
  while kill -0 "${pid}" 2>/dev/null; do
    if (( use_ui )) && ui_user_wants_abort; then
      kill "${pid}" 2>/dev/null || true
      sleep 0.2
      kill -9 "${pid}" 2>/dev/null || true
      kill_aria2_orphans
      _dl_discard_work "${hash}" "${path}"
      DOWNLOAD_LAST_SRC=""
      ui_progress_done
      UI_QUIET=1
      return 2
    fi

    got=0
    if [[ -f "${work}/${path}" ]]; then
      got="$(_dl_file_size "${work}/${path}")"
    else
      src="$(_dl_find_by_basename "${work}" "${base}")"
      [[ -n "${src}" ]] && got="$(_dl_file_size "${src}")"
    fi
    [[ "${got}" =~ ^[0-9]+$ ]] || got=0

    # Optional peers/seeds from aria2 log (often empty when redirected)
    _dl_parse_aria_log "${logf}" "${got}" "${expected}"
    (( DL_GOT > got )) && got="${DL_GOT}"
    (( DL_TOTAL > expected )) && expected="${DL_TOTAL}"
    (( got > expected )) && expected="${got}"
    (( expected < 1 )) && expected=1

    # Speed/ETA from file growth (~1s window; loop sleeps 0.5s)
    poll_n=$((poll_n + 1))
    if (( poll_n % 2 == 0 )); then
      instant=$((got - prev_got))
      (( instant < 0 )) && instant=0
      if (( speed_ema <= 0 )); then
        speed_ema="${instant}"
      else
        speed_ema=$(( (speed_ema * 3 + instant) / 4 ))
      fi
      prev_got="${got}"
    fi
    DL_SPEED="${speed_ema}"
    if (( DL_SPEED > 0 && expected > got )); then
      DL_ETA=$(( (expected - got) / DL_SPEED ))
    else
      DL_ETA=0
    fi

    if (( got <= 0 && DL_SPEED <= 0 )); then
      idle_ticks=$((idle_ticks + 1))
      DL_STATUS="finding peers"
    else
      idle_ticks=0
      DL_STATUS="downloading"
    fi
    if (( idle_ticks > 30 )); then
      DL_STATUS="waiting for seeds"
    fi

    if (( use_ui )); then
      ui_dl_progress_paint "Download" "${got}" "${expected}" "${label}" \
        "${DL_SPEED}" "${DL_SEEDS}" "${DL_PEERS}" "${DL_ETA}" "${DL_STATUS}"
    else
      ui_activity_tick 2>/dev/null || true
    fi
    sleep 0.5
  done
  wait "${pid}" || rc=$?
  kill_aria2_orphans
  cat "${logf}" >>"${INBOX_DIR}/download.log" 2>/dev/null || true

  src="${work}/${path}"
  if [[ ! -f "${src}" ]]; then
    src="$(_dl_find_by_basename "${work}" "${base}")"
  fi
  if [[ -z "${src}" || ! -f "${src}" ]]; then
    (( use_ui )) && ui_progress_done
    if (( use_ui )); then UI_QUIET=1; else UI_QUIET="${quiet_prev}"; warn "download missing: ${path} (rc=${rc})"; fi
    return 1
  fi

  DOWNLOAD_LAST_SRC="${src}"

  if [[ -z "${target}" ]]; then
    if (( use_ui )); then
      sz="$(_dl_file_size "${src}")"
      [[ "${sz}" =~ ^[0-9]+$ ]] && (( sz > 0 )) || sz="${expected}"
      ui_dl_progress_paint "Download" "${sz}" "${sz}" "${label}" 0 "${DL_SEEDS}" "${DL_PEERS}" 0 "done"
      ui_progress_done
      ui_drain_keys
      # Stay quiet ? caller shows Steel Sky dialogs next
      UI_QUIET=1
    else
      UI_QUIET="${quiet_prev}"
      log "downloaded ? ${src}"
    fi
    return 0
  fi

  mv -f "${src}" "${dest}"
  DOWNLOAD_LAST_SRC="${dest}"

  find "${work}" -type f -size 0 -delete 2>/dev/null || true
  find "${work}" -type d -empty -delete 2>/dev/null || true

  if (( use_ui )); then
    ui_dl_progress_paint "Download" "${expected}" "${expected}" "Saved ? ${target}" \
      0 "${DL_SEEDS}" "${DL_PEERS}" 0 "done"
    ui_progress_done
    ui_drain_keys
    UI_QUIET=1
  else
    UI_QUIET="${quiet_prev}"
  fi
  log "placed ? ${dest}"
  (( rc != 0 )) && [[ ! -f "${dest}" ]] && return 1
  return 0
}

download_queue() {
  need_aria2
  ensure_dirs
  [[ -f "${QUEUE_FILE}" ]] || die "queue missing"
  local rows
  rows=$(($(wc -l < "${QUEUE_FILE}") - 1))
  [[ "${rows}" -gt 0 ]] || die "queue empty"

  local hashes
  hashes="$(tail -n +2 "${QUEUE_FILE}" | awk -F'\t' '$5!=""{print $1}' | sort -u)"
  [[ -n "${hashes}" ]] || die "no items with target path; run map first"

  local hash select_csv torrent work trackers
  [[ "$(type -t bt_tracker_csv 2>/dev/null)" == "function" ]] \
    || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fetch_meta.sh"
  trackers="$(bt_tracker_csv)"

  for hash in ${hashes}; do
    torrent="${META_DIR}/${hash}.torrent"
    [[ -f "${torrent}" ]] || torrent="$(find "${META_DIR}" -maxdepth 1 -iname "${hash}.torrent" | head -n1 || true)"
    [[ -f "${torrent}" ]] || { warn "missing torrent for ${hash}"; continue; }

    select_csv="$(
      awk -F'\t' -v h="${hash}" 'NR>1 && $1==h && $5!=""{printf "%s%s", (n++?",":""), $2}' "${QUEUE_FILE}"
    )"
    [[ -n "${select_csv}" ]] || continue

    work="${INBOX_DIR}/${hash}"
    mkdir -p "${work}"
    log "download ${hash} files: ${select_csv}"

    "${ARIA2}" \
      --conf-path="${ARIA2_CONF}" \
      --dir="${work}" \
      --select-file="${select_csv}" \
      --seed-ratio=0.0 \
      --seed-time=0 \
      --max-upload-limit=1K \
      --bt-max-peers="${ARIA2_BT_MAX_PEERS}" \
      --split="${ARIA2_SPLIT}" \
      --max-connection-per-server=1 \
      --file-allocation=none \
      --bt-remove-unselected-file=true \
      --bt-tracker="${trackers}" \
      --dht-file-path="${META_DIR}/dht.dat" \
      --auto-file-renaming=false \
      --allow-overwrite=true \
      --quiet=true \
      "${torrent}" || warn "aria2 exited non-zero for ${hash}"

    [[ "$(type -t kill_aria2_orphans 2>/dev/null)" == "function" ]] && kill_aria2_orphans
    place_files "${hash}" "${work}"
  done

  log "download stage finished"
}

place_files() {
  local hash="$1"
  local work="$2"
  local h idx size path target src dest dest_dir

  while IFS=$'\t' read -r h idx size path target; do
    [[ "${h}" == "${hash}" ]] || continue
    [[ -n "${target}" ]] || continue

    src="${work}/${path}"
    if [[ ! -f "${src}" ]]; then
      src="$(find "${work}" -type f -name "$(basename "${path}")" | head -n1 || true)"
    fi
    if [[ -z "${src}" || ! -f "${src}" ]]; then
      warn "not found after download: ${path}"
      continue
    fi

    dest="${GAMES_ROOT}/${target}"
    dest_dir="$(dirname "${dest}")"
    mkdir -p "${dest_dir}"
    mv -f "${src}" "${dest}"
    log "placed ? ${dest}"
  done < <(tail -n +2 "${QUEUE_FILE}")

  find "${work}" -type f -size 0 -delete 2>/dev/null || true
  find "${work}" -type d -empty -delete 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  download_queue
fi
