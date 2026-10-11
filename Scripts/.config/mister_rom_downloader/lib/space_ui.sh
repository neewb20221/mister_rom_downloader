#!/usr/bin/env bash
# Space Analyzer: ncdu-style lazy disk browser for the MiSTer SD (/media/fat)
set -uo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SP_ROOT="${MISTER_ROOT:-/media/fat}"
declare -a SP_NAME=() SP_PATH=() SP_BYTES=() SP_ISDIR=()
SP_PARENT=""
SP_TOTAL=0
SP_DF_USED=0
SP_DF_SIZE=0
SP_DF_PCT=0

space_df_refresh() {
  local size=0 used=0 pct=0 raw_pct=""
  # df -k: 1=fs 2=1K-blocks 3=Used 4=Avail 5=Use%
  read -r size used raw_pct < <(df -k "${SP_ROOT}" 2>/dev/null | awk 'NR==2 { print $2, $3, $5 }') || true
  pct="${raw_pct%%%}"
  [[ "${size}" =~ ^[0-9]+$ ]] || size=0
  [[ "${used}" =~ ^[0-9]+$ ]] || used=0
  [[ "${pct}" =~ ^[0-9]+$ ]] || pct=0
  SP_DF_SIZE=$((size * 1024))
  SP_DF_USED=$((used * 1024))
  SP_DF_PCT="${pct}"
}

# True if path must never be deleted from this UI
space_delete_blocked() {
  local p="$1"
  local root app
  root="${SP_ROOT%/}"
  app="${APP_DIR%/}"
  p="${p%/}"
  [[ -z "${p}" || "${p}" == "/" ]] && return 0
  [[ "${p}" == "${root}" ]] && return 0
  [[ "${p}" == "${app}" ]] && return 0
  # Never delete the live app tree
  case "${p}" in
    "${app}"/*) return 0 ;;
  esac
  return 1
}

# Soft warning targets (still deletable after 2nd confirm)
space_delete_warn() {
  local p="$1" base
  base="${p##*/}"
  case "${base}" in
    linux|MiSTer|menu.rbf|MiSTer.ini) return 0 ;;
  esac
  case "${p}" in
    */linux|*/linux/*) return 0 ;;
  esac
  return 1
}

space_bar() {
  local bytes="$1" total="$2" width="${3:-22}"
  local filled i bar=""
  (( width < 4 )) && width=4
  (( total < 1 )) && total=1
  (( bytes < 0 )) && bytes=0
  filled=$(( bytes * width / total ))
  (( filled > width )) && filled="${width}"
  (( filled < 0 )) && filled=0
  for ((i=0; i<width; i++)); do
    if (( i < filled )); then bar+="${UI_BAR_ON}"; else bar+="${UI_BAR_OFF}"; fi
  done
  printf '%s' "${bar}"
}

space_pct() {
  local bytes="$1" total="$2" p
  (( total < 1 )) && { printf '0'; return 0; }
  p=$(( bytes * 100 / total ))
  (( p > 100 )) && p=100
  (( p < 0 )) && p=0
  printf '%d' "${p}"
}

# Scan immediate children of dir into SP_* (sorted by size desc).
# Return 0 ok, 1 fail, 2 cancelled.
space_scan_dir() {
  local dir="$1"
  local tmp pid wr=0 line kb path name isdir bytes parent_kb=0
  local -a raw_lines=()
  dir="${dir%/}"
  [[ -d "${dir}" ]] || return 1

  SP_NAME=(); SP_PATH=(); SP_BYTES=(); SP_ISDIR=()
  SP_PARENT="${dir}"
  SP_TOTAL=0

  tmp="$(mktemp "${APP_DIR}/.space_scan_XXXXXX")"
  UI_PROGRESS_ACTIVE=0
  if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
    ui_progress_paint "Space Analyzer" 0 1 "Scanning ${dir}..."
  fi

  # -a: include files at this level; -d 1: do not descend further
  du -ak -d 1 -- "${dir}" > "${tmp}" 2>/dev/null &
  pid=$!
  if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
    ui_wait_pid_abortable "${pid}"
    wr=$?
  else
    wait "${pid}" || wr=1
  fi
  if (( wr == 2 )); then
    rm -f "${tmp}"
    [[ "${UI_ACTIVE:-0}" == "1" ]] && ui_progress_done
    return 2
  fi

  # BusyBox du: "SIZE\tPATH" or "SIZE PATH"
  while read -r kb path || [[ -n "${kb}" ]]; do
    [[ -n "${kb}" && -n "${path}" ]] || continue
    [[ "${kb}" =~ ^[0-9]+$ ]] || continue
    if [[ "${path}" == "${dir}" ]]; then
      parent_kb="${kb}"
      continue
    fi
    # Only direct children
    name="${path##*/}"
    [[ -n "${name}" ]] || continue
    case "${path}" in
      "${dir}/${name}") ;;
      *) continue ;;
    esac
    raw_lines+=("${kb}"$'\t'"${path}")
  done < "${tmp}"
  rm -f "${tmp}"

  if (( ${#raw_lines[@]} > 0 )); then
    tmp="$(mktemp "${APP_DIR}/.space_sort_XXXXXX")"
    printf '%s\n' "${raw_lines[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr > "${tmp}"
    while IFS=$'\t' read -r kb path || [[ -n "${kb}" ]]; do
      [[ -n "${kb}" && -n "${path}" ]] || continue
      name="${path##*/}"
      bytes=$((kb * 1024))
      isdir=0
      [[ -d "${path}" ]] && isdir=1
      SP_NAME+=("${name}")
      SP_PATH+=("${path}")
      SP_BYTES+=("${bytes}")
      SP_ISDIR+=("${isdir}")
      SP_TOTAL=$((SP_TOTAL + bytes))
    done < "${tmp}"
    rm -f "${tmp}"
  fi

  # Prefer sum of children for bar scale; fall back to du parent total
  if (( SP_TOTAL < 1 && parent_kb > 0 )); then
    SP_TOTAL=$((parent_kb * 1024))
  fi

  space_df_refresh
  if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
    ui_progress_done
    ui_drain_keys
  fi
  return 0
}

space_breadcrumb() {
  local p="${SP_PARENT}" root="${SP_ROOT%/}" rel
  if [[ "${p}" == "${root}" ]]; then
    printf 'fat'
    return 0
  fi
  rel="${p#"${root}"/}"
  if [[ "${rel}" == "${p}" ]]; then
    printf '%s' "${p}"
    return 0
  fi
  printf 'fat / %s' "$(printf '%s' "${rel}" | sed 's|/| / |g')"
}

space_row_text() {
  local i="$1" text_w="$2" bar_w=18
  local bytes pct bar sz name suffix pad_name
  (( i < 0 || i >= ${#SP_NAME[@]} )) && { printf '%*s' "${text_w}" ''; return 0; }
  bytes="${SP_BYTES[i]}"
  pct="$(space_pct "${bytes}" "${SP_TOTAL}")"
  bar="$(space_bar "${bytes}" "${SP_TOTAL}" "${bar_w}")"
  if (( bytes < 1048576 )); then
    sz="<1M"
  else
    sz="$(ui_fmt_bytes "${bytes}")"
  fi
  name="${SP_NAME[i]}"
  suffix=""
  (( SP_ISDIR[i] )) && suffix="/"
  # Layout: [bar] pct%  size  name/
  printf -v pad_name '%s%s' "${name}" "${suffix}"
  printf '[%s] %3d%%  %-8s  %s' "${bar}" "${pct}" "${sz}" "${pad_name}"
}

# Delete selected entry. Return 0 deleted, 1 cancelled/blocked, 2 rm cancelled mid-flight.
space_delete_selected() {
  local i="$1"
  local path name bytes sz wr=0 pid del_label
  (( i >= 0 && i < ${#SP_PATH[@]} )) || return 1
  path="${SP_PATH[i]}"
  name="${SP_NAME[i]}"
  bytes="${SP_BYTES[i]}"
  sz="$(ui_fmt_bytes "${bytes}")"

  if space_delete_blocked "${path}"; then
    ui_msgbox "Space Analyzer" "Cannot delete protected path:"$'\n'"${path}"
    return 1
  fi

  del_label="${name}"
  (( SP_ISDIR[i] )) && del_label="${name}/"
  if ! ui_yesno "Delete?" \
    "Delete ${del_label} (${sz})?"$'\n'"This cannot be undone."; then
    return 1
  fi

  local warn_extra=""
  if space_delete_warn "${path}"; then
    warn_extra=$'\n'"WARNING: system / boot-related item."
  fi
  if ! ui_yesno "Confirm Delete" \
    "Permanently delete:"$'\n'"${path}"$'\n'"Size: ${sz}${warn_extra}"$'\n\n'"Yes = delete forever"; then
    return 1
  fi

  UI_PROGRESS_ACTIVE=0
  ui_progress_paint "Space Analyzer" 0 1 "Deleting ${name}..."
  rm -rf -- "${path}" &
  pid=$!
  ui_wait_pid_abortable "${pid}"
  wr=$?
  ui_progress_done
  if (( wr == 2 )); then
    ui_msgbox "Space Analyzer" "Delete cancelled (partial remove possible)."
    return 2
  fi
  if [[ -e "${path}" ]]; then
    ui_msgbox "Space Analyzer" "Delete failed:"$'\n'"${path}"
    return 1
  fi
  return 0
}

space_analyzer_ui() {
  local sel=0 scroll=0 key need_full=1 dirty=1 n=0
  local mx my mw mh list_top list_h text_w i row
  local prev_sel=-1 prev_scroll=-1
  local -a BTN_HOTS=("R" "D")
  local -a BTN_LABELS=("Rescan" "Delete")
  local -a BTN_W=(10 10)
  local btn_row bx focus="list" bsel=0 nb=2
  local prev_focus="" prev_bsel=-1
  local scan_rc=0 hdr bar_sd tip crumb del_label
  local root="${SP_ROOT%/}"

  [[ -d "${root}" ]] || {
    ui_msgbox "Space Analyzer" "SD root not found:"$'\n'"${root}"
    return 1
  }

  SP_PARENT="${root}"
  space_scan_dir "${SP_PARENT}"
  scan_rc=$?
  if (( scan_rc == 2 )); then
    return 0
  fi
  if (( scan_rc != 0 )); then
    ui_msgbox "Space Analyzer" "Scan failed:"$'\n'"${SP_PARENT}"
    return 1
  fi

  if [[ "${UI_DESKTOP_READY:-0}" == "1" && "${UI_NEED_DESKTOP}" != "1" ]]; then
    need_full=0
    dirty=1
    UI_NEED_REPAINT=1
  fi

  while true; do
    if [[ "${UI_NEED_DESKTOP}" == "1" ]]; then
      UI_NEED_DESKTOP=0
      need_full=1
    fi
    if [[ "${UI_NEED_REPAINT}" == "1" ]]; then
      UI_NEED_REPAINT=0
      dirty=1
      prev_focus=""
      prev_sel=-1
      prev_bsel=-1
    fi
    if ui_check_resize; then need_full=1; fi

    if (( need_full )); then
      ui_paint_desktop
      ui_chrome "$(app_title_ver)" \
        "$(ui_fit $((UI_COLS - 8)) "$(ui_hint_nav)  Enter=Open  Del=Delete  R=Rescan")"
      ui_list_panel_geom 2
      mw="${UI_PW}"; mh="${UI_PH}"; mx="${UI_PX}"; my="${UI_PY}"
      ui_box "${mx}" "${my}" "${mw}" "${mh}" "Space Analyzer"
      need_full=0
      dirty=1
      prev_sel=-1
      prev_scroll=-1
      prev_focus=""
      prev_bsel=-1
      ui_hints_ack
    fi

    list_top=$((my + 3))
    list_h=$((mh - 6))
    (( list_h < 3 )) && list_h=3
    text_w=$((mw - 8))
    (( text_w < 20 )) && text_w=20
    n="${#SP_NAME[@]}"
    (( n > 0 && sel >= n )) && sel=$((n - 1))
    (( sel < 0 )) && sel=0
    if (( n < 1 )); then
      scroll=0
    else
      ui_list_snap_page sel scroll "${list_h}" "${n}"
    fi

    # Header: SD usage + breadcrumb
    space_df_refresh
    bar_sd="$(space_bar "${SP_DF_USED}" "${SP_DF_SIZE}" 16)"
    hdr="SD [${bar_sd}] ${SP_DF_PCT}%  $(ui_fmt_bytes "${SP_DF_USED}") / $(ui_fmt_bytes "${SP_DF_SIZE}")"
    crumb="$(space_breadcrumb)"
    printf '\e[%d;%dH%s%-*.*s%s' $((my + 1)) $((mx + 2)) \
      "${UI_MUTED}" $((mw - 4)) $((mw - 4)) "$(ui_fit $((mw - 4)) "${hdr}")" "${UI_RST}"
    printf '\e[%d;%dH%s%-*.*s%s' $((my + 2)) $((mx + 2)) \
      "${UI_PANEL}" $((mw - 4)) $((mw - 4)) "$(ui_fit $((mw - 4)) "${crumb}")" "${UI_RST}"

    if (( dirty )); then
      local dim=0 line sty
      [[ "${focus}" != "list" ]] && dim=1
      if (( prev_scroll == scroll && prev_sel >= 0 && n > 0 )); then
        if (( prev_sel >= scroll && prev_sel < scroll + list_h )); then
          row=$((list_top + prev_sel - scroll))
          line="$(space_row_text "${prev_sel}" "${text_w}")"
          line="$(ui_fit "${text_w}" "${line}")"
          printf '\e[%d;%dH%s%-*.*s%s' "${row}" $((mx + 3)) \
            "${UI_PANEL}" "${text_w}" "${text_w}" "${line}" "${UI_RST}"
        fi
        if (( sel >= scroll && sel < scroll + list_h )); then
          row=$((list_top + sel - scroll))
          line="$(space_row_text "${sel}" "${text_w}")"
          line="$(ui_fit "${text_w}" "${line}")"
          if (( dim )); then sty="${UI_DIMSEL}"; else sty="${UI_SEL}"; fi
          printf '\e[%d;%dH%s%-*.*s%s' "${row}" $((mx + 3)) \
            "${sty}" "${text_w}" "${text_w}" "${line}" "${UI_RST}"
        fi
      else
        for ((i=0; i<list_h; i++)); do
          row=$((list_top + i))
          if (( n < 1 && i == 0 )); then
            printf '\e[%d;%dH%s%-*.*s%s' "${row}" $((mx + 3)) \
              "${UI_MUTED}" "${text_w}" "${text_w}" "$(ui_fit "${text_w}" "(empty)")" "${UI_RST}"
          elif (( scroll + i < n )); then
            line="$(space_row_text $((scroll + i)) "${text_w}")"
            line="$(ui_fit "${text_w}" "${line}")"
            if (( scroll + i == sel )); then
              if (( dim )); then sty="${UI_DIMSEL}"; else sty="${UI_SEL}"; fi
            else
              sty="${UI_PANEL}"
            fi
            printf '\e[%d;%dH%s%-*.*s%s' "${row}" $((mx + 3)) \
              "${sty}" "${text_w}" "${text_w}" "${line}" "${UI_RST}"
          else
            printf '\e[%d;%dH%s%*s%s' "${row}" $((mx + 3)) \
              "${UI_PANEL}" "${text_w}" '' "${UI_RST}"
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
      local s0=0 s1=0
      if [[ "${focus}" == "btns" ]]; then
        (( bsel == 0 )) && s0=1
        (( bsel == 1 )) && s1=1
      fi
      ui_draw_item_row "${bx}" "${bx}" "${btn_row}" "${BTN_W[0]}" 0 \
        "${BTN_HOTS[0]}" "${BTN_LABELS[0]}" "" "${s0}"
      ui_draw_item_row $((bx + 12)) $((bx + 12)) "${btn_row}" "${BTN_W[1]}" 0 \
        "${BTN_HOTS[1]}" "${BTN_LABELS[1]}" "" "${s1}"
      if [[ "${SP_PARENT}" == "${root}" ]]; then
        tip="Here: $(ui_fmt_bytes "${SP_TOTAL}")  Items:${n}  Esc=Exit"
      else
        tip="Here: $(ui_fmt_bytes "${SP_TOTAL}")  Items:${n}  Esc=Up"
      fi
      printf '\e[%d;%dH%s%-*.*s%s' $((my + mh - 2)) $((mx + 2)) \
        "${UI_MUTED}" $((mw - 4)) $((mw - 4)) "$(ui_fit $((mw - 4)) "${tip}")" "${UI_RST}"
      prev_focus="${focus}"
      prev_bsel="${bsel}"
    fi

    if ui_hints_need_refresh; then
      ui_chrome "$(app_title_ver)" \
        "$(ui_fit $((UI_COLS - 8)) "$(ui_hint_nav)  Enter=Open  Del=Delete  R=Rescan")"
      ui_hints_ack
    fi

    key="$(ui_read_key)" || true
    case "${key}" in
      TIMEOUT) continue ;;
      RESIZE) need_full=1; continue ;;
      ESC)
        if [[ "${SP_PARENT}" == "${root}" ]]; then
          UI_NEED_DESKTOP=1
          return 0
        fi
        # Up one level
        SP_PARENT="$(dirname "${SP_PARENT}")"
        [[ -z "${SP_PARENT}" || "${SP_PARENT}" == "/" ]] && SP_PARENT="${root}"
        space_scan_dir "${SP_PARENT}"
        scan_rc=$?
        (( scan_rc == 2 )) && { UI_NEED_DESKTOP=1; return 0; }
        sel=0; scroll=0
        need_full=1
        continue
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
            focus="btns"; bsel=0; dirty=1; prev_focus=""
          fi
          ;;
        LEFT|RIGHT)
          focus="btns"
          [[ "${key}" == "LEFT" ]] && bsel=$((nb - 1)) || bsel=0
          dirty=1; prev_focus=""
          ;;
        ENTER|" ")
          if (( n > 0 && SP_ISDIR[sel] )); then
            SP_PARENT="${SP_PATH[sel]}"
            space_scan_dir "${SP_PARENT}"
            scan_rc=$?
            if (( scan_rc == 2 )); then
              # Stay on parent if cancel mid-child scan — rescan parent
              SP_PARENT="$(dirname "${SP_PARENT}")"
              [[ "${SP_PARENT}" == "/" || -z "${SP_PARENT}" ]] && SP_PARENT="${root}"
              space_scan_dir "${SP_PARENT}" || true
            fi
            sel=0; scroll=0
            need_full=1
          elif (( n > 0 )); then
            ui_msgbox "Space Analyzer" \
              "${SP_PATH[sel]}"$'\n\n'"Size: $(ui_fmt_bytes "${SP_BYTES[sel]}")"$'\n'"(file)"
            need_full=1
          fi
          ;;
        DEL|d|D)
          if (( n > 0 )); then
            space_delete_selected "${sel}"
            space_scan_dir "${SP_PARENT}"
            scan_rc=$?
            (( scan_rc == 2 )) && { UI_NEED_DESKTOP=1; return 0; }
            need_full=1
          fi
          ;;
        r|R)
          space_scan_dir "${SP_PARENT}"
          scan_rc=$?
          (( scan_rc == 2 )) && { UI_NEED_DESKTOP=1; return 0; }
          sel=0; scroll=0
          need_full=1
          ;;
      esac
    else
      case "${key}" in
        UP)
          focus="list"; dirty=1; prev_focus=""
          ;;
        LEFT)
          if (( bsel <= 0 )); then
            focus="list"; prev_focus=""
          else
            bsel=$((bsel - 1))
          fi
          ;;
        RIGHT)
          if (( bsel >= nb - 1 )); then
            focus="list"; prev_focus=""
          else
            bsel=$((bsel + 1))
          fi
          ;;
        DOWN) ;;
        ENTER|" ")
          case "${bsel}" in
            0)
              space_scan_dir "${SP_PARENT}"
              scan_rc=$?
              (( scan_rc == 2 )) && { UI_NEED_DESKTOP=1; return 0; }
              sel=0; scroll=0
              need_full=1
              ;;
            1)
              if (( n > 0 )); then
                space_delete_selected "${sel}"
                space_scan_dir "${SP_PARENT}"
                scan_rc=$?
                (( scan_rc == 2 )) && { UI_NEED_DESKTOP=1; return 0; }
                need_full=1
              fi
              ;;
          esac
          focus="list"; prev_focus=""
          ;;
        r|R)
          space_scan_dir "${SP_PARENT}"
          scan_rc=$?
          (( scan_rc == 2 )) && { UI_NEED_DESKTOP=1; return 0; }
          sel=0; scroll=0
          need_full=1
          focus="list"; prev_focus=""
          ;;
        DEL|d|D)
          if (( n > 0 )); then
            space_delete_selected "${sel}"
            space_scan_dir "${SP_PARENT}"
            scan_rc=$?
            (( scan_rc == 2 )) && { UI_NEED_DESKTOP=1; return 0; }
            need_full=1
          fi
          focus="list"; prev_focus=""
          ;;
      esac
    fi
  done
}
