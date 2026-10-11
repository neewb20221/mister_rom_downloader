#!/usr/bin/env bash
# Magnet + torrent source flags (files in magnets/)
set -uo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

TORRENT_SOURCES_CONF="${APP_DIR}/torrent_sources.conf"

ensure_torrent_sources_conf() {
  ensure_dirs
  [[ -f "${TORRENT_SOURCES_CONF}" ]] || : > "${TORRENT_SOURCES_CONF}"
}

declare -A SRC_EN_MAP=()

load_enabled_map() {
  SRC_EN_MAP=()
  ensure_torrent_sources_conf
  local line k v
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" == *"="* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    [[ -n "${k}" ]] || continue
    [[ "${v}" == "0" ]] && SRC_EN_MAP["${k}"]=0 || SRC_EN_MAP["${k}"]=1
  done < "${TORRENT_SOURCES_CONF}"
}

# Fast load: bash globs + no external basename/find/sort forks per file
load_source_list() {
  SRC_PATHS=() SRC_NAMES=() SRC_TYPES=() SRC_FLAGS=()
  ensure_dirs
  load_enabled_map

  local -a files=()
  local f base en typ
  shopt -s nullglob
  files=(
    "${MAGNETS_DIR}"/*.magnet "${MAGNETS_DIR}"/*.MAGNET
    "${MAGNETS_DIR}"/*.txt "${MAGNETS_DIR}"/*.TXT
    "${MAGNETS_DIR}"/*.torrent "${MAGNETS_DIR}"/*.TORRENT
  )
  # Sort names via printf|sort once (not per-file tools)
  if (( ${#files[@]} == 0 )); then
    return 0
  fi
  while IFS= read -r f; do
    [[ -n "${f}" && -f "${f}" ]] || continue
    base="${f##*/}"
    [[ "${base}" == README.md ]] && continue
    case "${base}" in
      *.magnet|*.MAGNET|*.txt|*.TXT) typ=torrent ;;
      *.torrent|*.TORRENT) typ=file ;;
      *) continue ;;
    esac
    if [[ -n "${SRC_EN_MAP[${base}]+x}" ]]; then
      en="${SRC_EN_MAP[${base}]}"
    else
      en=1
    fi
    SRC_PATHS+=("${f}")
    SRC_NAMES+=("${base}")
    SRC_TYPES+=("${typ}")
    SRC_FLAGS+=("${en}")
  done < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort -u)
}

save_source_flags() {
  ensure_torrent_sources_conf
  local tmp i
  tmp="$(mktemp)"
  {
    echo "# torrent_sources.conf ? basename=0|1"
    for ((i=0; i<${#SRC_NAMES[@]}; i++)); do
      printf '%s=%s\n' "${SRC_NAMES[i]}" "${SRC_FLAGS[i]}"
    done
  } > "${tmp}"
  mv "${tmp}" "${TORRENT_SOURCES_CONF}"
}

enabled_magnet_files() {
  load_source_list
  local i
  for ((i=0; i<${#SRC_PATHS[@]}; i++)); do
    [[ "${SRC_FLAGS[i]}" == "1" ]] || continue
    [[ "${SRC_TYPES[i]}" == "torrent" ]] || continue
    printf '%s\n' "${SRC_PATHS[i]}"
  done
}

enabled_torrent_files() {
  load_source_list
  local i
  for ((i=0; i<${#SRC_PATHS[@]}; i++)); do
    [[ "${SRC_FLAGS[i]}" == "1" ]] || continue
    [[ "${SRC_TYPES[i]}" == "file" ]] || continue
    printf '%s\n' "${SRC_PATHS[i]}"
  done
}

import_torrent_to_meta() {
  local src="$1"
  local base dest
  base="${src##*/}"
  base="${base%.torrent}"
  base="${base%.TORRENT}"
  dest="${META_DIR}/${base}.torrent"
  mkdir -p "${META_DIR}"
  if [[ -f "${dest}" ]] && cmp -s "${src}" "${dest}" 2>/dev/null; then
    log "torrent meta exists: ${dest}"
    return 0
  fi
  cp -f "${src}" "${dest}"
  log "imported torrent ? ${dest}"
}

source_flags_snapshot() {
  local i s=""
  for ((i=0; i<${#SRC_FLAGS[@]}; i++)); do
    s+="${SRC_FLAGS[i]}"
  done
  printf '%s' "${s}"
}

source_set_all_flags() {
  local en="$1" i
  for ((i=0; i<${#SRC_FLAGS[@]}; i++)); do
    SRC_FLAGS[i]="${en}"
  done
}


# Edit list with bottom buttons (pad-friendly) + scrollbar
edit_torrent_magnet_files() {
  local n

  UI_BUSY_SOFT=1
  ui_busy_show "Torrent Files" "Loading torrent file list..."
  load_source_list
  n="${#SRC_NAMES[@]}"
  ui_busy_done

  if (( n == 0 )); then
    ui_msgbox "Torrent Files" "No .magnet / .txt / .torrent files in torrents folder"
    SRC_EDIT_CHANGED=0
    return 0
  fi

  local snap_before sel=0 scroll=0 key need_full=1 dirty=1
  # Soft enter if Steel Sky already painted
  if [[ "${UI_DESKTOP_READY:-0}" == "1" && "${UI_NEED_DESKTOP}" != "1" ]]; then
    need_full=0
  fi
  local mx my mw mh list_top list_h i row
  local filter="" show_n idx
  local focus="list" bsel=0 nb=3
  local btn_row bx
  local prev_sel=-1 prev_scroll=-1
  local prev_focus="" prev_bsel=-1
  local dim=0 tw=0
  local -a BTN_HOTS=("A" "N" "F")
  local -a BTN_LABELS=("All" "None" "Filter")
  local -a BTN_W=(10 12 14)

  snap_before="$(source_flags_snapshot)"
  SRC_EDIT_CHANGED=0

  local -a VIEW=()
  local -a VIEW_DISP=()
  _rebuild_view() {
    VIEW=()
    VIEW_DISP=()
    local i ql="" nl
    if [[ -z "${filter}" ]]; then
      for ((i=0; i<n; i++)); do VIEW+=("${i}"); done
    else
      ql="${filter,,}"
      for ((i=0; i<n; i++)); do
        nl="${SRC_NAMES[i],,}"
        [[ "${nl}" == *"${ql}"* ]] || continue
        VIEW+=("${i}")
      done
    fi
  }
  _rebuild_view

  # Fit one row inline (no subshell) ? critical for snappy cursor
  _paint_src_row() {
    local row="$1" vidx="$2" selected="$3" dimr="$4"
    local line="" idx mark typ raw
    if (( vidx >= 0 && vidx < show_n )); then
      if [[ -z "${VIEW_DISP[vidx]+x}" || -z "${VIEW_DISP[vidx]}" ]]; then
        idx="${VIEW[vidx]}"
        if [[ "${SRC_FLAGS[idx]}" == "1" ]]; then mark="[X]"; else mark="[ ]"; fi
        typ="${SRC_TYPES[idx]}"
        raw=" ${mark} ${typ}: ${SRC_NAMES[idx]}"
        if (( ${#raw} <= tw )); then
          line="${raw}"
        elif (( tw <= 3 )); then
          line="${raw:$((${#raw} - tw))}"
        else
          line="...${raw:$((${#raw} - (tw - 3)))}"
        fi
        VIEW_DISP[vidx]="${line}"
      else
        line="${VIEW_DISP[vidx]}"
      fi
    fi
    printf '\e[%d;%dH' "${row}" $((mx+2))
    if (( selected )); then
      if (( dimr )); then
        printf '%s%-*.*s%s' "${UI_DIMSEL}" "${tw}" "${tw}" "${line}" "${UI_RST}"
      else
        printf '%s%-*.*s%s' "${UI_SEL}" "${tw}" "${tw}" "${line}" "${UI_RST}"
      fi
    else
      printf '%s%-*.*s%s' "${UI_PANEL}" "${tw}" "${tw}" "${line}" "${UI_RST}"
    fi
  }

  _count_selected() {
    local c=0 i
    for ((i=0; i<n; i++)); do
      [[ "${SRC_FLAGS[i]}" == "1" ]] && c=$((c + 1))
    done
    printf '%d' "${c}"
  }

  _paint_buttons() {
    btn_row=$((my + mh - 3))
    bx=$((mx + 2))
    local s0=0 s1=0 s2=0 sel_n
    if [[ "${focus}" == "btns" ]]; then
      (( bsel == 0 )) && s0=1
      (( bsel == 1 )) && s1=1
      (( bsel == 2 )) && s2=1
    fi
    ui_draw_item_row "${bx}" "${bx}" "${btn_row}" "${BTN_W[0]}" 0 \
      "${BTN_HOTS[0]}" "${BTN_LABELS[0]}" "" "${s0}"
    ui_draw_item_row $((bx + 12)) $((bx + 12)) "${btn_row}" "${BTN_W[1]}" 0 \
      "${BTN_HOTS[1]}" "${BTN_LABELS[1]}" "" "${s1}"
    ui_draw_item_row $((bx + 26)) $((bx + 26)) "${btn_row}" "${BTN_W[2]}" 0 \
      "${BTN_HOTS[2]}" "${BTN_LABELS[2]}" "" "${s2}"
    sel_n="$(_count_selected)"
    printf '\e[%d;%dH%s%-*.*s%s' $((my+mh-2)) $((mx+2)) \
      "${UI_MUTED}" $((mw-4)) $((mw-4)) \
      "Selected:${sel_n}/${n}  Esc=Save+Back" "${UI_RST}"
  }

  _act_all() {
    source_set_all_flags 1
    VIEW_DISP=()
    dirty=1; prev_scroll=-1; prev_focus=""; prev_bsel=-1
  }
  _act_none() {
    source_set_all_flags 0
    VIEW_DISP=()
    dirty=1; prev_scroll=-1; prev_focus=""; prev_bsel=-1
  }
  local panel_dirty=0
  if (( need_full == 0 )); then
    panel_dirty=1
  fi
  _mark_src_panel_dirty() {
    panel_dirty=1
    dirty=1
    prev_sel=-1
    prev_scroll=-1
    prev_focus=""
    prev_bsel=-1
    VIEW_DISP=()
    UI_NEED_REPAINT=0
  }

  _act_filter() {
    if ui_filter_dialog "Filter Torrent Files" "${filter}"; then
      filter="${UI_INPUT_RESULT}"
      UI_BUSY_SOFT=1
      ui_busy_show "Filter" "Applying filter..."
      _rebuild_view
      ui_busy_done
      sel=0; scroll=0
      ui_chrome_footer \
        "$(ui_fit $((UI_COLS-8)) "$(ui_hint_edit_btns)$(ui_hint_list_extra)  Esc=Save")"
      _mark_src_panel_dirty
    else
      _mark_src_panel_dirty
    fi
  }

  while true; do
    if [[ "${UI_NEED_DESKTOP}" == "1" ]]; then
      UI_NEED_DESKTOP=0
      UI_NEED_REPAINT=0
      need_full=1
    elif [[ "${UI_NEED_REPAINT}" == "1" ]]; then
      UI_NEED_REPAINT=0
      _mark_src_panel_dirty
    fi
    if ui_check_resize; then need_full=1; fi
    show_n="${#VIEW[@]}"

    if (( need_full )); then
      ui_paint_desktop
      ui_chrome "$(app_title_ver)" \
        "$(ui_fit $((UI_COLS-8)) "$(ui_hint_edit_btns)$(ui_hint_list_extra)  Esc=Save")"
      ui_list_panel_geom 2
      mw="${UI_PW}"; mh="${UI_PH}"; mx="${UI_PX}"; my="${UI_PY}"
      ui_box "${mx}" "${my}" "${mw}" "${mh}" "Edit Torrent Files"
      dirty=1
      need_full=0
      panel_dirty=0
      prev_sel=-1
      prev_scroll=-1
      prev_focus=""
      prev_bsel=-1
      VIEW_DISP=()
      ui_hints_ack
    elif (( panel_dirty )); then
      [[ -n "${mx:-}" ]] || ui_list_panel_geom 2
      mw="${UI_PW:-$mw}"; mh="${UI_PH:-$mh}"
      mx="${UI_PX:-$mx}"; my="${UI_PY:-$my}"
      ui_box "${mx}" "${my}" "${mw}" "${mh}" "Edit Torrent Files"
      panel_dirty=0
      dirty=1
      prev_sel=-1
      prev_scroll=-1
      prev_focus=""
      prev_bsel=-1
      VIEW_DISP=()
    fi

    list_top=$((my + 2))
    list_h=$((mh - 5))
    (( list_h < 3 )) && list_h=3
    tw=$((mw - 6))
    (( tw < 8 )) && tw=8
    (( show_n > 0 && sel >= show_n )) && sel=$((show_n - 1))
    (( sel < 0 )) && sel=0
    if (( show_n < 1 )); then
      scroll=0
    elif (( sel < scroll || sel >= scroll + list_h )); then
      ui_list_snap_page sel scroll "${list_h}" "${show_n}"
    fi

    if (( dirty )); then
      dim=0
      [[ "${focus}" != "list" ]] && dim=1
      if (( prev_scroll == scroll && prev_sel >= 0 )); then
        if (( prev_sel >= scroll && prev_sel < scroll + list_h )); then
          _paint_src_row $((list_top + prev_sel - scroll)) "${prev_sel}" 0 0
        fi
        if (( show_n > 0 && sel >= scroll && sel < scroll + list_h )); then
          _paint_src_row $((list_top + sel - scroll)) "${sel}" 1 "${dim}"
        fi
      else
        for ((i=0; i<list_h; i++)); do
          if (( scroll + i < show_n && scroll + i == sel )); then
            _paint_src_row $((list_top + i)) $((scroll + i)) 1 "${dim}"
          elif (( scroll + i < show_n )); then
            _paint_src_row $((list_top + i)) $((scroll + i)) 0 0
          else
            _paint_src_row $((list_top + i)) -1 0 0
          fi
        done
        ui_draw_scrollbar $((mx + mw - 3)) "${list_top}" "${list_h}" "${show_n}" "${list_h}" "${scroll}"
      fi
      dirty=0
      prev_sel="${sel}"
      prev_scroll="${scroll}"
    fi

    if [[ "${prev_focus}" != "${focus}" || "${prev_bsel}" != "${bsel}" ]]; then
      _paint_buttons
      prev_focus="${focus}"
      prev_bsel="${bsel}"
    fi

    if ui_hints_need_refresh; then
      ui_chrome "$(app_title_ver)" \
        "$(ui_fit $((UI_COLS-8)) "$(ui_hint_edit_btns)$(ui_hint_list_extra)  Esc=Save")"
      ui_hints_ack
    fi

    key="$(ui_read_key)" || true
    case "${key}" in
      TIMEOUT) continue ;;
      RESIZE) need_full=1; continue ;;
      ESC)
        save_source_flags
        if [[ "$(source_flags_snapshot)" != "${snap_before}" ]]; then
          SRC_EDIT_CHANGED=1
        fi
        UI_NEED_DESKTOP=1
        return 0
        ;;
    esac

    if [[ "${focus}" == "list" ]]; then
      case "${key}" in
        UP)
          if (( sel > 0 )); then
            ui_list_nav_up sel scroll "${list_h}" "${show_n}"
            dirty=1
          fi
          ;;
        DOWN)
          if (( show_n > 0 && sel < show_n - 1 )); then
            ui_list_nav_down sel scroll "${list_h}" "${show_n}"
            dirty=1
          else
            focus="btns"; bsel=0; dirty=1
          fi
          ;;
        LEFT|RIGHT)
          focus="btns"
          [[ "${key}" == "LEFT" ]] && bsel=$((nb - 1)) || bsel=0
          dirty=1
          ;;
        " "|ENTER)
          if (( show_n > 0 )); then
            idx="${VIEW[sel]}"
            if [[ "${SRC_FLAGS[idx]}" == "1" ]]; then SRC_FLAGS[idx]=0; else SRC_FLAGS[idx]=1; fi
            VIEW_DISP[sel]=""
            dirty=1; prev_scroll=-1; prev_focus=""; prev_bsel=-1
          fi
          ;;
        a|A) _act_all ;;
        n|N) _act_none ;;
        f|F|/|x|X) _act_filter ;;
      esac
    else
      case "${key}" in
        UP) focus="list"; dirty=1 ;;
        LEFT)
          if (( bsel <= 0 )); then focus="list"; else bsel=$((bsel - 1)); fi
          ;;
        RIGHT)
          if (( bsel >= nb - 1 )); then focus="list"; else bsel=$((bsel + 1)); fi
          ;;
        ENTER|" ")
          case "${bsel}" in
            0) _act_all ;;
            1) _act_none ;;
            2) _act_filter ;;
          esac
          focus="list"
          dirty=1
          ;;
        a|A) _act_all; focus="list"; dirty=1 ;;
        n|N) _act_none; focus="list"; dirty=1 ;;
        f|F|/|x|X) _act_filter; focus="list"; dirty=1 ;;
      esac
    fi
  done
}


