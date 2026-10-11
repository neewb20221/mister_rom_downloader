#!/usr/bin/env bash
# Resolve ROM ? games/<platform>/... via DAT, then extension, else _Inbox
set -uo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Extension ? MiSTer games/ folder (lowercase keys)
ext_to_core() {
  local ext="${1,,}"
  case "${ext}" in
    nes|fds|unf|unif) printf 'NES' ;;
    smc|sfc|fig|swc) printf 'SNES' ;;
    n64|z64|v64) printf 'N64' ;;
    gb|gbc) printf 'GAMEBOY' ;;
    gba) printf 'GBA' ;;
    md|gen|smd) printf 'Genesis' ;;
    sms|gg) printf 'SMS' ;;
    pce|sgx) printf 'TGFX16' ;;
    cue|chd|iso|pbp|mdf) printf 'PSX' ;;
    neo) printf 'NeoGeo' ;;
    a26) printf 'ATARI2600' ;;
    a78) printf 'ATARI7800' ;;
    a52) printf 'ATARI5200' ;;
    col) printf 'Coleco' ;;
    ws|wsc) printf 'WonderSwan' ;;
    lnk|lyx) printf 'Lynx' ;;
    vec) printf 'VEC' ;;
    int) printf 'Intellivision' ;;
    d64|t64|prg) printf 'C64' ;;
    adf|ipf) printf 'Amiga' ;;
    tap|tzx|z80|sna) printf 'Spectrum' ;;
    *) return 1 ;;
  esac
}

# Guess platform folder from DAT filename (MiSTer_Console.dat ? often multi)
dat_platform_hint() {
  local dat="$1" base
  base="$(basename "${dat}")"
  base="${base%.*}"
  case "${base,,}" in
    *arcade*) printf 'ARCADE' ;;
    *console_cd*|*cd_chd*) printf 'PSX' ;;
    *computer*) printf 'AO486' ;;
    *) printf '' ;;
  esac
}

# From DAT line number of a rom hit ? nearest preceding game/machine name=
_dat_game_name_near_line() {
  local dat="$1" ln="$2" start
  [[ "${ln}" =~ ^[0-9]+$ ]] || return 1
  start=$((ln > 40 ? ln - 40 : 1))
  sed -n "${start},${ln}p" "${dat}" \
    | grep -i -E '<(game|machine)[^>]*name=' \
    | tail -n1 \
    | sed -E 's/.*name="([^"]+)".*/\1/'
}

# Match rom name= in DAT; supports exact name and archive-stem (zip inner name).
# Tries: exact basename, then stem.*, then stem (no ext) ? for Game.zip ? Game.nes in DAT.
_dat_find_game_for_rom_name() {
  local dat="$1" rom_name="$2"
  local name_esc ln suggest stem stem_esc ext
  name_esc="$(printf '%s' "${rom_name}" | sed 's/[.[\*^$()+?{|]/\\&/g')"

  ln="$(grep -i -n -E "rom[^>]*name=\"${name_esc}\"" "${dat}" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  if [[ -n "${ln}" ]]; then
    suggest="$(_dat_game_name_near_line "${dat}" "${ln}")"
    [[ -n "${suggest}" ]] && { printf '%s\n' "${suggest}"; return 0; }
  fi

  # Archive (or any file): match DAT rom by stem ignore extension
  # e.g. "Super Mario Bros. (USA).zip" ? rom name="Super Mario Bros. (USA).nes"
  ext="${rom_name##*.}"
  if [[ "${rom_name}" == *.* && "${ext}" != "${rom_name}" ]]; then
    case "${ext,,}" in
      zip|7z|rar|gz|xz|zst|tgz)
        stem="${rom_name%.*}"
        stem_esc="$(printf '%s' "${stem}" | sed 's/[.[\*^$()+?{|]/\\&/g')"
        ln="$(grep -i -n -E "rom[^>]*name=\"${stem_esc}\.[^\"]+\"" "${dat}" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
        if [[ -z "${ln}" ]]; then
          ln="$(grep -i -n -E "rom[^>]*name=\"${stem_esc}\"" "${dat}" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
        fi
        if [[ -n "${ln}" ]]; then
          suggest="$(_dat_game_name_near_line "${dat}" "${ln}")"
          [[ -n "${suggest}" ]] && { printf '%s\n' "${suggest}"; return 0; }
        fi
        ;;
    esac
  fi
  return 1
}

_dat_format_target() {
  local base="$1" suggest="$2" plat="$3" dir
  # MiSTer Organize DATs often use games\\Core\\... paths
  suggest="${suggest//\\//}"
  suggest="${suggest#./}"
  case "${suggest}" in
    [Gg]ames/*) suggest="${suggest#*/}" ;;
  esac
  if [[ "${suggest}" == */* ]]; then
    dir="$(dirname "${suggest}")"
    printf '%s/%s\n' "${dir}" "${base}"
  elif [[ -n "${suggest}" ]]; then
    if [[ -n "${plat}" ]]; then
      printf '%s/%s/%s\n' "${plat}" "${suggest}" "${base}"
    else
      printf '%s/%s\n' "${suggest}" "${base}"
    fi
  else
    return 1
  fi
}

# Look up basename in enabled DAT files. Prints relative path under games/.
# For .zip/.7z/? matches DAT by the name inside (stem), not the archive extension.
dat_suggest_for_basename() {
  local base="$1"
  local dat suggest="" plat=""
  local -a dats=()

  if declare -F enabled_dat_files >/dev/null 2>&1; then
    while IFS= read -r dat; do
      [[ -n "${dat}" ]] && dats+=("${dat}")
    done < <(enabled_dat_files || true)
  fi
  if [[ ${#dats[@]} -eq 0 ]]; then
    shopt -s nullglob
    dats=("${DATS_DIR}"/*.dat "${DATS_DIR}"/*.DAT)
  fi
  [[ ${#dats[@]} -gt 0 ]] || return 1

  for dat in "${dats[@]}"; do
    [[ -f "${dat}" ]] || continue
    suggest="$(_dat_find_game_for_rom_name "${dat}" "${base}" || true)"
    [[ -n "${suggest}" ]] || continue
    plat="$(dat_platform_hint "${dat}")"
    _dat_format_target "${base}" "${suggest}" "${plat}"
    return 0
  done
  return 1
}


# First CRC-32 of a file inside a zip (No-Intro: usually one ROM per zip).
archive_inner_crc() {
  local f="$1" crc=""
  [[ -f "${f}" ]] || return 1
  case "${f,,}" in
    *.zip)
      if command -v python3 >/dev/null 2>&1; then
        crc="$(python3 - "${f}" <<'PY'
import sys, zipfile
try:
    z = zipfile.ZipFile(sys.argv[1])
    for i in z.infolist():
        if i.is_dir():
            continue
        print("%08x" % (i.CRC & 0xffffffff))
        break
except Exception:
    pass
PY
)"
      fi
      if [[ -z "${crc}" ]] && command -v unzip >/dev/null 2>&1; then
        crc="$(unzip -Z -v "${f}" 2>/dev/null | awk '/CRC32/{c=$2} END{if(c) print tolower(c)}' || true)"
      fi
      ;;
    *) return 1 ;;
  esac
  [[ "${crc}" =~ ^[0-9a-fA-F]{8}$ ]] || return 1
  printf '%s\n' "${crc,,}"
}

# Look up crc="XXXXXXXX" in DATs. $2 = basename to keep as filename in target.
dat_suggest_by_crc() {
  local crc="$1" base="${2:-}"
  local dat ln suggest plat rom_name
  local -a dats=()
  crc="${crc,,}"
  crc="${crc#0x}"
  [[ "${crc}" =~ ^[0-9a-f]{8}$ ]] || return 1

  if declare -F enabled_dat_files >/dev/null 2>&1; then
    while IFS= read -r dat; do
      [[ -n "${dat}" ]] && dats+=("${dat}")
    done < <(enabled_dat_files || true)
  fi
  if [[ ${#dats[@]} -eq 0 ]]; then
    shopt -s nullglob
    dats=("${DATS_DIR}"/*.dat "${DATS_DIR}"/*.DAT)
  fi
  [[ ${#dats[@]} -gt 0 ]] || return 1

  for dat in "${dats[@]}"; do
    [[ -f "${dat}" ]] || continue
    ln="$(grep -i -n -m1 -E "crc=\"${crc}\"" "${dat}" 2>/dev/null | cut -d: -f1 || true)"
    [[ -n "${ln}" ]] || continue
    rom_name="$(sed -n "${ln}p" "${dat}" | sed -nE 's/.*name="([^"]+)".*/\1/p' | head -n1)"
    suggest="$(_dat_game_name_near_line "${dat}" "${ln}" || true)"
    if [[ "${rom_name}" == *[\\/]* ]]; then
      suggest="${rom_name}"
    fi
    [[ -n "${suggest}" ]] || continue
    [[ -n "${base}" ]] || base="$(basename "${rom_name}")"
    plat="$(dat_platform_hint "${dat}")"
    _dat_format_target "${base}" "${suggest}" "${plat}"
    return 0
  done
  return 1
}

# After zip is on disk: rematch DAT by inner file CRC.
dat_rematch_archive_file() {
  local file="$1" base crc suggested
  base="$(basename "${file}")"
  crc="$(archive_inner_crc "${file}" 2>/dev/null || true)"
  [[ -n "${crc}" ]] || return 1
  suggested="$(dat_suggest_by_crc "${crc}" "${base}" 2>/dev/null || true)"
  [[ -n "${suggested}" ]] || return 1
  printf '%s\n' "${suggested}"
}

# Games/ folders where CD/VHD content must not stay inside zip (MiSTer docs).
_mister_cd_vhd_core_folder() {
  local core="$1"
  case "${core,,}" in
    psx|megacd|saturn|neogeo-cd|cdi|pcecd|tgfx16-cd|pcenginecd|ao486) return 0 ;;
    *) return 1 ;;
  esac
}

# True if zip listing looks like CD/VHD payload (cue/bin/iso/chd/vhd/...).
_archive_zip_has_cd_vhd_payload() {
  local file="$1" listing
  [[ -f "${file}" ]] || return 1
  listing="$(unzip -Z -1 "${file}" 2>/dev/null || unzip -l "${file}" 2>/dev/null || true)"
  [[ -n "${listing}" ]] || return 1
  printf '%s\n' "${listing}" | grep -qiE '\.(cue|bin|iso|img|toc|gdi|chd|vhd|vdi|vmdk)(/|$|\s)'
}

# Return 0 if this placed zip should get an extract offer.
archive_needs_extract_for_mister() {
  local file="$1" core rel
  [[ -f "${file}" ]] || return 1
  case "${file,,}" in
    *.zip) ;;
    *) return 1 ;;
  esac
  # Prefer content inspection (works even if placed under _Inbox)
  if _archive_zip_has_cd_vhd_payload "${file}"; then
    return 0
  fi
  # Fallback: destination under a known CD/VHD core folder
  if [[ "${file}" == "${GAMES_ROOT}/"* ]]; then
    rel="${file#"${GAMES_ROOT}/"}"
    core="${rel%%/*}"
    _mister_cd_vhd_core_folder "${core}" && return 0
  fi
  return 1
}

# Uncompressed payload size from zip listing (last summary line of unzip -l).
_archive_zip_uncompressed_bytes() {
  local file="$1" n
  n="$(unzip -l "${file}" 2>/dev/null | tail -n1 | awk '{print $1}')"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  if (( n < 1 )); then
    n="$(wc -c < "${file}" 2>/dev/null | tr -d '[:space:]')"
    [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  fi
  printf '%s' "${n}"
}

# Approx bytes written under dir (KiB * 1024; BusyBox-friendly).
_archive_dir_bytes() {
  local dir="$1" n
  [[ -d "${dir}" ]] || { printf '0'; return 0; }
  n="$(du -sk "${dir}" 2>/dev/null | awk '{print $1}')"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$((n * 1024))"
}

# Run unzip with download-style byte progress (size / speed / ETA). Cancel = Esc/B.
# Returns 0 ok, 1 fail, 2 cancelled.
_archive_unzip_with_progress() {
  local file="$1" dest_dir="$2" label="$3"
  local total got prev_got=0 speed_ema=0 eta=0 poll_n=0 pid rc=0 instant
  local use_ui=0

  total="$(_archive_zip_uncompressed_bytes "${file}")"
  (( total < 1 )) && total=1

  if [[ "$(type -t ui_dl_progress_paint 2>/dev/null)" == "function" ]]; then
    use_ui=1
  fi

  unzip -o "${file}" -d "${dest_dir}" >/dev/null 2>&1 &
  pid=$!

  while kill -0 "${pid}" 2>/dev/null; do
    if (( use_ui )) && ui_user_wants_abort 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      (( use_ui )) && ui_progress_done
      return 2
    fi
    got="$(_archive_dir_bytes "${dest_dir}")"
    [[ "${got}" =~ ^[0-9]+$ ]] || got=0
    (( got > total )) && total="${got}"

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
    if (( speed_ema > 0 && total > got )); then
      eta=$(( (total - got) / speed_ema ))
    else
      eta=0
    fi

    if (( use_ui )); then
      # seeds="-" hides torrent seed/peer line in ui_dl_progress_paint
      ui_dl_progress_paint "Extract" "${got}" "${total}" "${label}" \
        "${speed_ema}" "-" "-" "${eta}" "extracting"
    fi
    sleep 0.5
  done
  wait "${pid}" || rc=$?

  got="$(_archive_dir_bytes "${dest_dir}")"
  [[ "${got}" =~ ^[0-9]+$ ]] || got=0
  (( got > total )) && total="${got}"
  if (( use_ui )); then
    ui_dl_progress_paint "Extract" "${total}" "${total}" "${label}" \
      0 "-" "-" 0 "done"
    ui_progress_done
    ui_drain_keys 2>/dev/null || true
  fi
  (( rc == 0 )) && return 0
  return 1
}

# After Place: offer extract for CD/VHD zips into games/<core>/<stem>/, then delete zip.
# Returns 0 if handled (asked / extracted / skipped with message), 1 if not applicable.
offer_extract_placed_archive() {
  local file="$1" base stem dest_dir msg rc
  [[ -f "${file}" ]] || return 1
  archive_needs_extract_for_mister "${file}" || return 1

  if ! command -v unzip >/dev/null 2>&1; then
    ui_msgbox "Extract" \
      "Saved:"$'\n'"${file}"$'\n\n'"CD/VHD zip should be extracted, but unzip is not available."
    return 0
  fi

  base="$(basename "${file}")"
  stem="${base%.*}"
  [[ -n "${stem}" ]] || stem="${base}"
  dest_dir="$(dirname "${file}")/${stem}"

  msg="CD/VHD images must not stay zipped on MiSTer."
  msg+=$'\n\n'"Archive: ${base}"
  msg+=$'\n'"Extract to: ${dest_dir}/"
  msg+=$'\n\n'"Extract and delete the zip?"
  if ! ui_okcancel "Extract" "${msg}"; then
    ui_msgbox "Download" "Saved (zip kept):"$'\n'"${file}"
    return 0
  fi

  mkdir -p "${dest_dir}" 2>/dev/null || true
  _archive_unzip_with_progress "${file}" "${dest_dir}" "${base}"
  rc=$?
  case "${rc}" in
    0)
      rm -f "${file}" 2>/dev/null || true
      ui_msgbox "Extract" \
        "Extracted to:"$'\n'"${dest_dir}/"$'\n\n'"Zip removed."
      ;;
    2)
      ui_msgbox "Extract" \
        "Cancelled - zip kept."$'\n'"${file}"$'\n'"Partial files may remain in:"$'\n'"${dest_dir}/"
      ;;
    *)
      ui_msgbox "Extract" \
        "Extract failed (zip kept)."$'\n'"${file}"$'\n'"Tried: ${dest_dir}/"
      ;;
  esac
  return 0
}

# Resolve full relative target under GAMES_ROOT for a torrent file path.
# Sets: RESOLVE_TARGET (rel), RESOLVE_SOURCE (dat|ext|inbox), RESOLVE_ABS
resolve_download_target() {
  local path="$1"
  local base ext core suggested
  base="$(basename "${path}")"
  RESOLVE_TARGET=""
  RESOLVE_SOURCE=""
  RESOLVE_ABS=""

  suggested="$(dat_suggest_for_basename "${base}" 2>/dev/null || true)"
  if [[ -n "${suggested}" ]]; then
    RESOLVE_TARGET="${suggested}"
    RESOLVE_SOURCE="dat"
  else
    ext="${base##*.}"
    if [[ "${base}" == *.* ]] && core="$(ext_to_core "${ext}")"; then
      RESOLVE_TARGET="${core}/${base}"
      RESOLVE_SOURCE="ext"
    else
      RESOLVE_TARGET="_Inbox/${base}"
      RESOLVE_SOURCE="inbox"
    fi
  fi
  RESOLVE_ABS="${GAMES_ROOT}/${RESOLVE_TARGET}"
  printf '%s\n' "${RESOLVE_TARGET}"
}

manual_core_for() {
  local path="$1"
  local base core
  base="$(basename "${path}")"
  echo
  log "File: ${path}"
  if [[ -f "${CORES_FILE}" ]]; then
    log "Common cores (or type any folder under games/):"
    head -n 40 "${CORES_FILE}" | paste - - - - 2>/dev/null || cat "${CORES_FILE}"
  fi
  read -r -p "Core folder [NES]: " core
  core="${core:-NES}"
  printf '%s/%s\n' "${core}" "${base}"
}

map_queue() {
  ensure_dirs
  [[ -f "${QUEUE_FILE}" ]] || die "queue empty"
  local tmp
  tmp="$(mktemp)"
  local header
  header="$(head -n1 "${QUEUE_FILE}")"
  printf '%s\n' "${header}" > "${tmp}"

  local hash idx size path target base suggested ans
  while IFS=$'\t' read -r hash idx size path target; do
    [[ "${hash}" == "hash" ]] && continue
    [[ -n "${hash}" ]] || continue
    if [[ -n "${target}" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "${hash}" "${idx}" "${size}" "${path}" "${target}" >> "${tmp}"
      continue
    fi
    base="$(basename "${path}")"
    suggested="$(dat_suggest_for_basename "${base}" || true)"
    if [[ -z "${suggested}" ]]; then
      resolve_download_target "${path}" >/dev/null || true
      suggested="${RESOLVE_TARGET}"
    fi
    if [[ -n "${suggested}" ]]; then
      log "suggest: ${base} ? ${suggested}"
      read -r -p "Accept? [Y/n/edit]: " ans || true
      ans="${ans:-Y}"
      case "${ans}" in
        n|N) target="$(manual_core_for "${path}")" ;;
        e|E|edit|EDIT)
          read -r -p "target relative to games/: " target
          ;;
        *) target="${suggested}" ;;
      esac
    else
      warn "no DAT/ext hit for ${base}"
      target="$(manual_core_for "${path}")"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${hash}" "${idx}" "${size}" "${path}" "${target}" >> "${tmp}"
  done < "${QUEUE_FILE}"

  mv "${tmp}" "${QUEUE_FILE}"
  log "targets saved in ${QUEUE_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  map_queue
fi
