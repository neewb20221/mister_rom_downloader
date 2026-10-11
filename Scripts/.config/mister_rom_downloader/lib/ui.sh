#!/usr/bin/env bash
# Steel Sky / RNC installer TUI for MiSTer
# Colors & pseudographics matched to classic DOS setup screens.
# Perf: full paint once, dirty-redraw selection; SIGWINCH resize.

# Desktop: solid gray (no ? ? MiSTer font often missing it).
UI_DESK=$'\e[47;30m'
UI_DESK_CH=' '                 # solid fill (safe on MiSTer console font)
UI_PANEL=$'\e[44;37m'
UI_BORDER=$'\e[1;37;44m'
UI_BTN=$'\e[47;30m'
UI_BTN_HOT=$'\e[47;31;1m'
UI_SEL=$'\e[0;30;47m'
UI_SEL_HOT=$'\e[1;31;47m'
UI_DIMSEL=$'\e[1;37;46m'       # selected row while focus is on buttons
UI_OSK_SEL=$'\e[1;37;41m'      # OSK cursor: white on red (must differ from UI_BTN)
UI_ARROW=$'\e[1;31;44m'
UI_VALUE=$'\e[0;30;47m'
UI_MUTED=$'\e[1;36;44m'
UI_SHADOW=$'\e[40m'
UI_INPUT=$'\e[0;30;47m'
UI_RST=$'\e[0m'

# Double-strip look using ASCII (safe with large Terminus fonts that lack ???)
# Looks like:  #========#  /  |......|  /  #========#
UI_TL='#' UI_TR='#' UI_BL='#' UI_BR='#'
UI_H='='  UI_V='|'
UI_AL='<' UI_AR='>'
UI_TEE='+' UI_EL='+' UI_BRH='-'
UI_BAR_ON='='
UI_BAR_OFF='.'
# Classic CLI activity spinner (same |/-\\ idiom used across MiSTer shell scripts)
UI_SPIN_FRAMES='|/-\'
UI_SPIN_I=0

ui_spin_char() {
  local ch
  ch="${UI_SPIN_FRAMES:$((UI_SPIN_I % ${#UI_SPIN_FRAMES})):1}"
  UI_SPIN_I=$((UI_SPIN_I + 1))
  printf '%s' "${ch}"
}
UI_FONT_SET=0
UI_FONT_PREV=""

UI_COLS=80
UI_ROWS=24
UI_ACTIVE=0
UI_RESIZE=0
UI_BUF=""
UI_INPUT_MODE="keyboard"   # keyboard | pad (default keyboard)
UI_OSK_MODE="edit"         # edit | filter
UI_OSK_FOCUS="text"        # text | keys ? Enter applies in text; Down enters OSK
UI_HINT_MODE=""            # last painted hint mode
# Cached solid desk line (rebuilt when COLS change) ? avoids O(rows*cols) rebuild
UI_DESK_LINE=""
UI_DESK_LINE_COLS=0
# Viewport line-diff cache: skip rewrite when payload unchanged
declare -a UI_VP_LINE=()
UI_VP_Y=0
UI_VP_H=0
UI_VP_X=0
UI_VP_W=0

# Hold Back/Esc ~10s (key-repeat) = force quit (same as Ctrl+C)
UI_ESC_HOLD_START=0
UI_ESC_HOLD_LAST=0

ui_note_input() {
  case "$1" in
    UP|DOWN|LEFT|RIGHT) UI_INPUT_MODE="pad" ;;
    BACKSPACE|DEL) UI_INPUT_MODE="keyboard" ;;
    ENTER|ESC|" "|TIMEOUT|RESIZE) ;; # leave mode unchanged
    [[:print:]]) UI_INPUT_MODE="keyboard" ;;
  esac
}

ui_esc_hold_reset() {
  UI_ESC_HOLD_START=0
  UI_ESC_HOLD_LAST=0
}

# Bare Esc/B: first edge = Back; keep holding (repeats) ~10s = force quit.
# Repeats are swallowed (TIMEOUT) so menus are not spammed.
# Prints token to stdout: ESC | TIMEOUT  (or shuts down).
ui_esc_hold_on_esc() {
  local now="${SECONDS:-0}"
  # Gap >1s ? new press
  if (( UI_ESC_HOLD_START == 0 || now - UI_ESC_HOLD_LAST > 1 )); then
    UI_ESC_HOLD_START="${now}"
    UI_ESC_HOLD_LAST="${now}"
    ui_note_input ESC
    echo ESC
    return 0
  fi
  UI_ESC_HOLD_LAST="${now}"
  if (( now - UI_ESC_HOLD_START >= 10 )); then
    ui_shutdown 130
  fi
  echo TIMEOUT
  return 0
}

ui_hints_need_refresh() {
  [[ "${UI_HINT_MODE}" != "${UI_INPUT_MODE}" ]]
}

ui_hints_ack() {
  UI_HINT_MODE="${UI_INPUT_MODE}"
}

ui_hint_nav() {
  if [[ "${UI_INPUT_MODE}" == "pad" ]]; then
    printf '%s' "D-Pad Move  A=Select  B=Back  Hold B 10s=Quit"
  else
    printf '%s' "Up/Down Move  Enter=OK  Esc=Back  Hold Esc 10s=Quit"
  fi
}

ui_hint_list_extra() {
  if [[ "${UI_INPUT_MODE}" == "pad" ]]; then
    printf '%s' "  X=Filter"
  else
    printf '%s' "  F=Filter  /=Filter"
  fi
}

ui_hint_edit_btns() {
  if [[ "${UI_INPUT_MODE}" == "pad" ]]; then
    printf '%s' "D-Pad  L/R=Buttons  A=OK  B=Back"
  else
    printf '%s' "Left/Right=Buttons  Enter=OK  Esc=Back"
  fi
}

ui_buf_reset() { UI_BUF=""; }
ui_buf_flush() { printf '%s' "${UI_BUF}"; UI_BUF=""; }

ui_on_winch() { UI_RESIZE=1; }

# Read live tty geometry. Prefer stty ? tput often caches and stays wrong after SSH resize.
ui_tty_size() {
  local sz="" rows cols
  UI_TTY_ROWS=""; UI_TTY_COLS=""
  # Quiet: stty/tty noise was leaking onto the TUI as black text
  if [[ -c /dev/tty ]]; then
    sz="$(stty size </dev/tty 2>/dev/null)" || sz=""
  fi
  if [[ -z "${sz}" ]]; then
    sz="$(stty size 2>/dev/null)" || sz=""
  fi
  rows="${sz%% *}"
  cols="${sz##* }"
  if [[ "${rows}" =~ ^[0-9]+$ && "${cols}" =~ ^[0-9]+$ ]]; then
    UI_TTY_ROWS="${rows}"
    UI_TTY_COLS="${cols}"
    return 0
  fi
  return 1
}

ui_detect_size() {
  local c l
  if ui_tty_size; then
    l="${UI_TTY_ROWS}"
    c="${UI_TTY_COLS}"
  else
    # Avoid feeding tput previously exported (possibly stale) COLUMNS/LINES
    c="$(COLUMNS= LINES= tput cols 2>/dev/null || true)"
    l="$(COLUMNS= LINES= tput lines 2>/dev/null || true)"
  fi
  [[ "${c}" =~ ^[0-9]+$ ]] || c="${COLUMNS:-80}"
  [[ "${l}" =~ ^[0-9]+$ ]] || l="${LINES:-24}"
  UI_COLS="${c}"; UI_ROWS="${l}"
  if (( UI_COLS < 40 )); then UI_COLS=40; fi
  if (( UI_ROWS < 16 )); then UI_ROWS=16; fi
  export COLUMNS="${UI_COLS}" LINES="${UI_ROWS}"
}

UI_RESIZE_TICK=0

ui_check_resize() {
  # WINCH flag + idle poll (some SSH clients skip reliable WINCH delivery).
  local oc="${UI_COLS}" or="${UI_ROWS}" force="${1:-0}"
  if [[ "${UI_RESIZE}" -eq 1 || "${force}" == "1" ]]; then
    UI_RESIZE=0
    ui_detect_size
    if [[ "${UI_COLS}" -ne "${oc}" || "${UI_ROWS}" -ne "${or}" ]]; then
      return 0
    fi
  fi
  return 1
}

# Call from TIMEOUT branches ? polls size ~every 3s while idle
ui_idle_resize_tick() {
  UI_RESIZE_TICK=$((UI_RESIZE_TICK + 1))
  if (( UI_RESIZE_TICK >= 10 )); then
    UI_RESIZE_TICK=0
    ui_check_resize 1
    return $?
  fi
  return 1
}

ui_goto() { UI_BUF+="$(printf '\e[%d;%dH' "$1" "$2")"; }
# Fast pad: one printf, no per-char loop
ui_spaces() {
  local n="$1"
  (( n > 0 )) || return 0
  printf '%*s' "${n}" ''
}

# Invalidate viewport diff cache (call on full panel rebuild / resize / filter)
ui_vp_reset() {
  UI_VP_LINE=()
  UI_VP_Y=0
  UI_VP_H=0
  UI_VP_X=0
  UI_VP_W=0
}

# Begin a viewport region (absolute screen rows y .. y+h-1)
ui_vp_begin() {
  local y="$1" h="$2" x="${3:-1}" w="${4:-0}"
  if [[ "${y}" != "${UI_VP_Y}" || "${h}" != "${UI_VP_H}" || "${x}" != "${UI_VP_X}" || "${w}" != "${UI_VP_W}" ]]; then
    UI_VP_LINE=()
    UI_VP_Y="${y}"
    UI_VP_H="${h}"
    UI_VP_X="${x}"
    UI_VP_W="${w}"
  fi
  ui_buf_reset
}

# Queue one viewport line if content changed. idx = 0..h-1
# payload = full ANSI string WITHOUT cursor position (colors+text+reset)
ui_vp_put() {
  local idx="$1" row="$2" col="$3" payload="$4"
  if [[ "${UI_VP_LINE[idx]:-}" == "${payload}" ]]; then
    return 0
  fi
  UI_VP_LINE[idx]="${payload}"
  ui_goto "${row}" "${col}"
  UI_BUF+="${payload}"
}

ui_vp_flush() { ui_buf_flush; }

# Truncate string to max visible width (ASCII-safe for MiSTer console)
ui_fit() {
  local max="$1" s="${2:-}"
  (( max < 1 )) && return 0
  if (( ${#s} > max )); then
    if (( max > 3 )); then
      printf '%s' "${s:0:$((max-3))}..."
    else
      printf '%s' "${s:0:max}"
    fi
  else
    printf '%s' "${s}"
  fi
}

# Prefer keeping the end of a path (filename) when truncating
ui_fit_path() {
  local max="$1" s="${2:-}"
  (( max < 1 )) && return 0
  if (( ${#s} <= max )); then
    printf '%s' "${s}"
    return 0
  fi
  if (( max <= 3 )); then
    printf '%s' "${s:$(( ${#s} - max ))}"
    return 0
  fi
  printf '...%s' "${s:$(( ${#s} - (max - 3) ))}"
}

# Near full-width panel geometry for path/list screens.
# Sets: UI_PX UI_PY UI_PW UI_PH
ui_list_panel_geom() {
  local margin="${1:-2}"
  ui_detect_size
  UI_PW=$((UI_COLS - margin))
  (( UI_PW < 40 )) && UI_PW=40
  (( UI_PW > UI_COLS - 2 )) && UI_PW=$((UI_COLS - 2))
  UI_PH=$((UI_ROWS - 8))
  (( UI_PH < 12 )) && UI_PH=12
  (( UI_PH > UI_ROWS - 6 )) && UI_PH=$((UI_ROWS - 6))
  UI_PX=$(( (UI_COLS - UI_PW) / 2 + 1 ))
  (( UI_PX < 2 )) && UI_PX=2
  UI_PY=4
  (( UI_PY + UI_PH > UI_ROWS - 3 )) && UI_PY=$((UI_ROWS - UI_PH - 3))
  (( UI_PY < 4 )) && UI_PY=4
}

# Discard buffered keypresses (prevents auto-closing dialogs after long ops)
ui_drain_keys() {
  local k
  UI_KEY_PUSHBACK=""
  while IFS= read -rsn1 -t 0.01 k; do :; done || true
}

# One-slot key pushback (set when coalesce peeks a different key)
UI_KEY_PUSHBACK=""
# After ui_coalesce_nav DIR ? how many identical nav keys were consumed (>=1)
UI_COALESCE_N=1
# Soft dialogs / overlays: parent should redraw its panel (not wipe desktop)
UI_NEED_REPAINT=0
# Hard wipe happened (progress/busy): parent must ui_paint_desktop
UI_NEED_DESKTOP=0
# 1 after first desktop paint this session ? menus can soft-enter
UI_DESKTOP_READY=0

# Non-blocking key poll (~1ms). Echoes key token or "" if none.
ui_try_key() {
  local k="" rest=""
  if [[ -n "${UI_KEY_PUSHBACK}" ]]; then
    k="${UI_KEY_PUSHBACK}"
    UI_KEY_PUSHBACK=""
    printf '%s\n' "${k}"
    return 0
  fi
  if ! IFS= read -rsn1 -t 0.001 k; then
    printf '\n'
    return 1
  fi
  if [[ "${k}" == $'\x13' || "${k}" == $'\x11' ]]; then
    ui_tty_raw
    printf '\n'
    return 1
  fi
  if [[ "${k}" == $'\x1b' ]]; then
    rest=""
    IFS= read -rsn1 -t 0.04 rest || true
    if [[ "${rest}" == "[" ]]; then
      IFS= read -rsn1 -t 0.04 rest || true
      case "${rest}" in
        A) printf 'UP\n'; return 0 ;;
        B) printf 'DOWN\n'; return 0 ;;
        C) printf 'RIGHT\n'; return 0 ;;
        D) printf 'LEFT\n'; return 0 ;;
        3)
          IFS= read -rsn1 -t 0.04 rest || true
          printf 'DEL\n'; return 0
          ;;
      esac
    fi
    printf 'ESC\n'
    return 0
  fi
  if [[ "${k}" == $'\x7f' || "${k}" == $'\b' ]]; then
    printf 'BACKSPACE\n'
    return 0
  fi
  if [[ "${k}" == "" || "${k}" == $'\n' || "${k}" == $'\r' ]]; then
    printf 'ENTER\n'
    return 0
  fi
  printf '%s\n' "${k}"
  return 0
}

# After receiving UP/DOWN/LEFT/RIGHT: swallow identical queued repeats (held key).
# Sets UI_COALESCE_N. Different peeked key goes to UI_KEY_PUSHBACK.
ui_coalesce_nav() {
  local dir="$1" n=1 k
  UI_COALESCE_N=1
  while (( n < 48 )); do
    k="$(ui_try_key)" || break
    [[ -z "${k}" ]] && break
    if [[ "${k}" == "${dir}" ]]; then
      n=$((n + 1))
      UI_COALESCE_N="${n}"
    else
      UI_KEY_PUSHBACK="${k}"
      break
    fi
  done
}

# Scrollbar at column x, rows y..y+h-1 for scroll window
# total=items, visible=page size, scroll=top index
# Appends into UI_BUF when UI_BUF_ACTIVE=1, else paints immediately.
ui_draw_scrollbar() {
  local x="$1" y="$2" h="$3" total="$4" visible="$5" scroll="$6"
  local i thumb_h thumb_y track_ch='|' thumb_ch='#' buf_own=0
  (( h < 2 )) && return 0
  if [[ -z "${UI_BUF}" && "${UI_BUF_HOLD:-0}" != "1" ]]; then
    ui_buf_reset
    buf_own=1
  fi
  if (( total <= visible || total < 1 )); then
    for ((i=0; i<h; i++)); do
      ui_goto $((y+i)) "${x}"
      UI_BUF+="${UI_MUTED}${track_ch}${UI_RST}"
    done
    (( buf_own )) && ui_buf_flush
    return 0
  fi
  thumb_h=$(( h * visible / total ))
  (( thumb_h < 1 )) && thumb_h=1
  (( thumb_h > h )) && thumb_h="${h}"
  thumb_y=$(( (h - thumb_h) * scroll / (total - visible) ))
  (( thumb_y < 0 )) && thumb_y=0
  (( thumb_y > h - thumb_h )) && thumb_y=$((h - thumb_h))
  for ((i=0; i<h; i++)); do
    ui_goto $((y+i)) "${x}"
    if (( i >= thumb_y && i < thumb_y + thumb_h )); then
      UI_BUF+="${UI_SEL}${thumb_ch}${UI_RST}"
    else
      UI_BUF+="${UI_MUTED}${track_ch}${UI_RST}"
    fi
  done
  (( buf_own )) && ui_buf_flush
}


ui_hline() {
  # ASCII-only UI_H ? expand via printf pad (no per-char loop, no tr on UTF-8)
  local n="$1" out
  (( n > 0 )) || return 0
  printf -v out '%*s' "${n}" ''
  printf '%s' "${out// /${UI_H}}"
}

ui_fill_line() {
  local n="$1" ch="${2:- }" out
  (( n > 0 )) || return 0
  printf -v out '%*s' "${n}" ''
  if [[ "${ch}" == " " ]]; then
    printf '%s' "${out}"
  else
    printf '%s' "${out// /${ch}}"
  fi
}

# Ensure UI_DESK_LINE matches current width
ui_desk_line_ensure() {
  if [[ "${UI_DESK_LINE_COLS}" != "${UI_COLS}" || -z "${UI_DESK_LINE}" ]]; then
    UI_DESK_LINE="$(ui_fill_line "${UI_COLS}" "${UI_DESK_CH}")"
    UI_DESK_LINE_COLS="${UI_COLS}"
  fi
}

ui_try_big_font() {
  # Best-effort larger console font (needs real VC + setfont).
  local f ttydev=""
  local -a candidates=()
  UI_FONT_SET=0
  UI_FONT_PREV=""
  command -v setfont >/dev/null 2>&1 || return 0

  ttydev="$(tty 2>/dev/null || true)"
  [[ -z "${ttydev}" || "${ttydev}" == "not a tty" ]] && ttydev="/dev/tty"

  # Bundled font first (if present), then system paths
  [[ -n "${APP_DIR:-}" ]] && candidates+=(
    "${APP_DIR}/fonts/ter-v32b.psf.gz"
    "${APP_DIR}/fonts/ter-v28b.psf.gz"
    "${APP_DIR}/fonts/ter-v24b.psf.gz"
    "${APP_DIR}/fonts/Lat15-TerminusBold32x16.psf.gz"
    "${APP_DIR}/fonts/Lat15-TerminusBold28x14.psf.gz"
  )
  candidates+=(
    /usr/share/consolefonts/Lat15-TerminusBold32x16.psf.gz
    /usr/share/consolefonts/Lat15-TerminusBold28x14.psf.gz
    /usr/share/consolefonts/Lat15-TerminusBold24x12.psf.gz
    /usr/share/consolefonts/Lat15-TerminusBold22x11.psf.gz
    /usr/share/consolefonts/Lat15-TerminusBold20x10.psf.gz
    /usr/share/consolefonts/ter-v32b.psf.gz
    /usr/share/consolefonts/ter-v28b.psf.gz
    /usr/share/consolefonts/ter-v24b.psf.gz
    /usr/share/kbd/consolefonts/Lat15-TerminusBold32x16.psf.gz
    /usr/share/kbd/consolefonts/ter-v32b.psf.gz
    /usr/share/kbd/consolefonts/ter-v28b.psf.gz
    /lib/kbd/consolefonts/Lat15-TerminusBold32x16.psf.gz
    /lib/kbd/consolefonts/ter-v32b.psf.gz
    /lib/kbd/consolefonts/ter-v28b.psf.gz
  )

  for f in "${candidates[@]}"; do
    [[ -f "${f}" ]] || continue
    if setfont -C "${ttydev}" "${f}" 2>/dev/null || setfont "${f}" 2>/dev/null; then
      UI_FONT_SET=1
      UI_FONT_PREV="${f}"
      return 0
    fi
  done
  return 0
}

ui_restore_font() {
  if [[ "${UI_FONT_SET}" -eq 1 ]]; then
    # default font restore (best effort)
    setfont 2>/dev/null || true
    UI_FONT_SET=0
  fi
}

# Kill all descendants of this shell (aria2, helpers), then app-scoped aria2 leftovers.
ui_kill_children() {
  local -a tree=()
  local -A is_desc=()
  local pid ppid f line j changed=1

  is_desc[$$]=1
  # Collect full descendant tree before killing (reparenting would lose grandchildren).
  while (( changed )); do
    changed=0
    for f in /proc/[0-9]*/stat; do
      [[ -r "${f}" ]] || continue
      line="$(cat "${f}" 2>/dev/null)" || continue
      # pid (comm) state ppid ...
      if [[ "${line}" =~ ^([0-9]+)[[:space:]]+\((.*)\)[[:space:]]+[A-Za-z][[:space:]]+([0-9]+) ]]; then
        pid="${BASH_REMATCH[1]}"
        ppid="${BASH_REMATCH[3]}"
      else
        continue
      fi
      [[ "${pid}" == "$$" ]] && continue
      [[ -n "${is_desc[${pid}]:-}" ]] && continue
      if [[ -n "${is_desc[${ppid}]:-}" ]]; then
        is_desc[${pid}]=1
        tree+=("${pid}")
        changed=1
      fi
    done
  done

  for j in $(jobs -p 2>/dev/null); do
    [[ "${j}" =~ ^[0-9]+$ ]] || continue
    [[ -n "${is_desc[${j}]:-}" ]] && continue
    tree+=("${j}")
    is_desc[${j}]=1
  done

  for pid in "${tree[@]}"; do
    kill -TERM "${pid}" 2>/dev/null || true
  done
  sleep 0.2
  for pid in "${tree[@]}"; do
    kill -9 "${pid}" 2>/dev/null || true
  done

  if [[ "$(type -t kill_aria2_orphans 2>/dev/null)" == "function" ]]; then
    kill_aria2_orphans
  fi
}

# TTY mode for TUI: no echo, non-canonical, no XON/XOFF (Ctrl+S freeze).
ui_tty_raw() {
  stty -echo -icanon -ixon -ixoff min 1 time 0 2>/dev/null \
    || stty -echo -icanon -ixon -ixoff 2>/dev/null \
    || stty -echo -ixon 2>/dev/null \
    || true
}

# Normal exit + signal path: kill children, restore TTY.
ui_exit_cleanup() {
  if [[ "${UI_SHUTTING_DOWN:-0}" == "1" ]]; then
    return 0
  fi
  UI_SHUTTING_DOWN=1
  trap - EXIT INT TERM HUP WINCH
  ui_kill_children
  ui_cleanup
}

# Ctrl+C / TERM / HUP: restore TTY, kill children, exit.
ui_shutdown() {
  local code="${1:-130}"
  if [[ "${UI_SHUTTING_DOWN:-0}" == "1" ]]; then
    exit "${code}"
  fi
  ui_exit_cleanup
  exit "${code}"
}

ui_init() {
  # Hide tool/stty/aria2 noise from the TUI (was black text over Steel Sky)
  UI_STDERR_REDIRECTED=0
  UI_SHUTTING_DOWN=0
  if [[ -n "${APP_DIR:-}" ]]; then
    mkdir -p "${APP_DIR}" 2>/dev/null || true
    exec 3>&2
    exec 2>>"${APP_DIR}/ui_stderr.log"
    UI_STDERR_REDIRECTED=1
  fi
  ui_try_big_font
  ui_detect_size
  UI_ACTIVE=1
  UI_RESIZE=0
  UI_QUIET=0
  UI_BUF_HOLD=0
  UI_DESKTOP_READY=0
  stty sane 2>/dev/null || true
  printf '\e[?25l\e[?7l' 2>/dev/null || true
  ui_tty_raw
  shopt -s checkwinsize 2>/dev/null || true
  # EXIT also kills children (same as Ctrl+C), then restores TTY
  trap 'ui_exit_cleanup' EXIT
  trap 'ui_shutdown 130' INT
  trap 'ui_shutdown 143' TERM
  trap 'ui_shutdown 129' HUP
  trap 'ui_on_winch' WINCH
  return 0
}

ui_cleanup() {
  if [[ "${UI_ACTIVE}" -eq 1 ]]; then
    UI_ACTIVE=0
    UI_DESKTOP_READY=0
    printf '\e[?7h\e[?25h\e[0m\e[2J\e[H' 2>/dev/null || true
    stty echo icanon ixon 2>/dev/null || true
    stty sane 2>/dev/null || true
    ui_restore_font
  fi
  if [[ "${UI_STDERR_REDIRECTED:-0}" == "1" ]]; then
    exec 2>&3
    exec 3>&-
    UI_STDERR_REDIRECTED=0
  fi
}

ui_cleanup_soft() {
  printf '\e[?7h\e[?25h\e[0m' 2>/dev/null || true
  stty echo 2>/dev/null || true
}

ui_resume() {
  UI_ACTIVE=1
  printf '\e[?25l\e[?7l' 2>/dev/null || true
  ui_tty_raw
}

ui_paint_desktop() {
  local r
  ui_detect_size
  ui_desk_line_ensure
  ui_vp_reset
  ui_buf_reset
  UI_BUF+=$'\e[0m\e[2J\e[H'"${UI_DESK}"
  for ((r=1; r<=UI_ROWS; r++)); do
    UI_BUF+="${UI_DESK_LINE}"
    (( r < UI_ROWS )) && UI_BUF+=$'\n'
  done
  UI_BUF+="${UI_RST}"
  ui_buf_flush
  UI_DESKTOP_READY=1
}

ui_box() {
  local x="$1" y="$2" w="$3" h="$4" title="${5:-}"
  local i inner tpad tlen fill topbot
  inner=$((w - 2))
  fill="$(ui_spaces "${w}")"
  topbot="$(ui_hline "${inner}")"
  # Keep title inside border
  if [[ -n "${title}" ]] && (( ${#title} + 4 >= inner )); then
    title="$(ui_fit $((inner - 4)) "${title}")"
  fi

  ui_buf_reset
  # solid black drop shadow (right + bottom)
  for ((i=1; i<=h; i++)); do
    ui_goto $((y+i)) $((x+2))
    UI_BUF+="${UI_SHADOW}$(ui_spaces "${w}")"
  done
  UI_BUF+="${UI_RST}"

  for ((i=0; i<h; i++)); do
    ui_goto $((y+i)) "${x}"
    UI_BUF+="${UI_PANEL}${fill}"
  done

  ui_goto "${y}" "${x}"
  UI_BUF+="${UI_BORDER}${UI_TL}"
  if [[ -n "${title}" ]]; then
    tlen=${#title}
    if (( tlen + 4 < inner )); then
      tpad=$(( (inner - tlen - 2) / 2 ))
      UI_BUF+="$(ui_hline "${tpad}") ${title} $(ui_hline $((inner - tpad - tlen - 2)))"
    else
      UI_BUF+="${topbot}"
    fi
  else
    UI_BUF+="${topbot}"
  fi
  UI_BUF+="${UI_TR}${UI_RST}"

  for ((i=1; i<h-1; i++)); do
    ui_goto $((y+i)) "${x}"
    UI_BUF+="${UI_BORDER}${UI_V}"
    ui_goto $((y+i)) $((x+w-1))
    UI_BUF+="${UI_V}${UI_RST}"
  done

  ui_goto $((y+h-1)) "${x}"
  UI_BUF+="${UI_BORDER}${UI_BL}${topbot}${UI_BR}${UI_RST}"
  ui_buf_flush
}

ui_center_text() {
  local y="$1" text="$2" color="${3:-$UI_BORDER}" maxw="${4:-0}"
  local x
  if (( maxw > 0 )); then
    text="$(ui_fit "${maxw}" "${text}")"
  fi
  x=$(( (UI_COLS - ${#text}) / 2 + 1 ))
  (( x < 1 )) && x=1
  printf '\e[%d;%dH%s%s%s' "${y}" "${x}" "${color}" "${text}" "${UI_RST}"
}

ui_chrome() {
  local header="$1" footer="$2"
  local hw=$((UI_COLS - 4)) hx=2
  ui_box "${hx}" 1 "${hw}" 3
  ui_center_text 2 "${header}" "${UI_BORDER}" $((hw - 4))
  ui_box "${hx}" $((UI_ROWS - 2)) "${hw}" 3
  ui_center_text $((UI_ROWS - 1)) "${footer}" "${UI_BORDER}" $((hw - 4))
}

# Rewrite footer text only (no box/desktop redraw) ? for hint-mode flips
ui_chrome_footer() {
  local footer="$1"
  local hw=$((UI_COLS - 4))
  ui_center_text $((UI_ROWS - 1)) "${footer}" "${UI_BORDER}" $((hw - 4))
}

# Print message wrapped into box at (x,y) with max width/lines; clips overflow.
# Handles embedded newlines (otherwise \n resets cursor to column 1 ? text "flies left").
ui_print_wrapped() {
  local x="$1" y="$2" w="$3" max_lines="$4" color="$5" msg="$6"
  local line rest chunk n=0 para
  # Normalize CR; split paragraphs on newline
  msg="${msg//$'\r'/}"
  while IFS= read -r para || [[ -n "${para}" ]]; do
    rest="${para}"
    while (( n < max_lines )); do
      if (( ${#rest} <= w )); then
        chunk="${rest}"
        rest=""
      else
        chunk="${rest:0:w}"
        rest="${rest:w}"
      fi
      printf '\e[%d;%dH%s%-*.*s%s' $((y + n)) "${x}" \
        "${color}" "${w}" "${w}" "${chunk}" "${UI_RST}"
      n=$((n + 1))
      [[ -z "${rest}" ]] && break
    done
    (( n >= max_lines )) && break
  done <<< "${msg}"
  while (( n < max_lines )); do
    printf '\e[%d;%dH%s%-*.*s%s' $((y + n)) "${x}" \
      "${color}" "${w}" "${w}" "" "${UI_RST}"
    n=$((n + 1))
  done
}

# Page-mode list navigation (bash 4.3+ namerefs).
# Down at page bottom ? next page, cursor at top.
# Up at page top ? previous page, cursor at bottom.
ui_list_nav_down() {
  local -n _sel=$1 _scroll=$2
  local page=$3 total=$4
  (( total < 1 )) && return 0
  if (( _sel >= total - 1 )); then return 0; fi
  if (( _sel >= _scroll + page - 1 )); then
    # bottom of page ? next page, cursor at page start
    _scroll=$((_scroll + page))
    (( _scroll >= total )) && _scroll=$((total - 1))
    _sel=${_scroll}
  else
    _sel=$((_sel + 1))
  fi
}

ui_list_nav_up() {
  local -n _sel=$1 _scroll=$2
  local page=$3 total=$4
  if (( _sel <= 0 )); then return 0; fi
  if (( _sel <= _scroll )); then
    # top of page ? previous page, cursor at page bottom
    _scroll=$((_scroll - page))
    (( _scroll < 0 )) && _scroll=0
    _sel=$((_scroll + page - 1))
    (( _sel >= total )) && _sel=$((total - 1))
  else
    _sel=$((_sel - 1))
  fi
}

# Keep sel visible with page-aligned scroll (after jump/filter/resize)
ui_list_snap_page() {
  local -n _sel=$1 _scroll=$2
  local page=$3 total=$4
  (( total < 1 )) && { _sel=0; _scroll=0; return 0; }
  (( _sel < 0 )) && _sel=0
  (( _sel >= total )) && _sel=$((total - 1))
  if (( page < 1 )); then page=1; fi
  _scroll=$(( (_sel / page) * page ))
  (( _scroll >= total )) && _scroll=$((total - 1))
}

# Map typed char to US-QWERTY Latin so English hotkeys work on RU/UA layouts.
ui_latin_key() {
  local k="$1"
  case "${k}" in
    [A-Za-z0-9]) printf '%s' "${k,,}"; return 0 ;;
    # Russian JCUKEN (Windows) -> QWERTY
    й|Й) printf q ;;
    ц|Ц) printf w ;;
    у|У) printf e ;;
    к|К) printf r ;;
    е|Е) printf t ;;
    н|Н) printf y ;;
    г|Г) printf u ;;
    ш|Ш) printf i ;;
    щ|Щ) printf o ;;
    з|З) printf p ;;
    ф|Ф) printf a ;;
    ы|Ы) printf s ;;
    в|В) printf d ;;
    а|А) printf f ;;
    п|П) printf g ;;
    р|Р) printf h ;;
    о|О) printf j ;;
    л|Л) printf k ;;
    д|Д) printf l ;;
    я|Я) printf z ;;
    ч|Ч) printf x ;;
    с|С) printf c ;;
    м|М) printf v ;;
    и|И) printf b ;;
    т|Т) printf n ;;
    ь|Ь) printf m ;;
    # Ukrainian extras on similar positions
    і|І) printf s ;;
    ї|Ї) printf x ;;
    є|Є) printf "'" ;;
    *) printf '%s' "${k}" ;;
  esac
}

# Pick hotkey letter from label: 1st free letter, else 2nd, 3rd... Sets HOTS/HOTIDX/HOTSL.
# Uses LABELS[0..n) already filled. Optional preferred HOTS[i] if still free + present in label.
ui_menu_assign_hotkeys() {
  local n="$1"
  local -A used=()
  local i j c cl label pref pref_l found
  for ((i=0; i<n; i++)); do
    HOTIDX[i]=0
    HOTSL[i]=""
    label="${LABELS[i]}"
    pref="${HOTS[i]:-}"
    found=0
    # 1) Preferred explicit letter if it appears in label and is free
    if [[ "${pref}" =~ ^[A-Za-z]$ ]]; then
      pref_l="${pref,,}"
      if [[ -z "${used[${pref_l}]+x}" ]]; then
        for ((j=0; j<${#label}; j++)); do
          c="${label:j:1}"
          [[ "${c,,}" == "${pref_l}" ]] || continue
          HOTS[i]="${pref^^}"
          HOTIDX[i]="${j}"
          HOTSL[i]="${pref_l}"
          used["${pref_l}"]=1
          found=1
          break
        done
      fi
    fi
    (( found )) && continue
    # 2) First free A-Z letter in label (left to right)
    for ((j=0; j<${#label}; j++)); do
      c="${label:j:1}"
      [[ "${c}" =~ [A-Za-z] ]] || continue
      cl="${c,,}"
      [[ -n "${used[${cl}]+x}" ]] && continue
      HOTS[i]="${c^^}"
      HOTIDX[i]="${j}"
      HOTSL[i]="${cl}"
      used["${cl}"]=1
      found=1
      break
    done
    if (( ! found )); then
      # Fallback: keep digit/symbol preference or first char
      if [[ "${pref}" =~ ^[0-9]$ ]]; then
        HOTS[i]="${pref}"
        HOTIDX[i]=0
        HOTSL[i]="${pref}"
      else
        HOTS[i]="$(printf '%s' "${label:0:1}" | tr 'a-z' 'A-Z')"
        HOTIDX[i]=0
        HOTSL[i]="$(printf '%s' "${label:0:1}" | tr 'A-Z' 'a-z')"
      fi
    fi
  done
}

# Draw menu/button row. Hot letter highlighted in-place (10th arg = index, optional).
ui_draw_item_row() {
  local bx="$1" vx="$2" row="$3" btn_w="$4" val_w="$5"
  local hot="$6" label="$7" value="$8" selected="$9"
  local hot_idx="${10-}"
  local hot_l pre rest pad body j c hot_l_raw

  if [[ -z "${hot_idx}" || ! "${hot_idx}" =~ ^[0-9]+$ ]]; then
    hot_idx=""
    hot_l_raw="$(printf '%s' "${hot:0:1}" | tr 'A-Z' 'a-z')"
    if [[ -n "${hot_l_raw}" ]]; then
      for ((j=0; j<${#label}; j++)); do
        c="${label:j:1}"
        [[ "${c,,}" == "${hot_l_raw}" ]] || continue
        hot_idx="${j}"
        break
      done
    fi
    [[ -z "${hot_idx}" ]] && hot_idx=0
  fi
  (( hot_idx < 0 )) && hot_idx=0
  (( hot_idx >= ${#label} )) && hot_idx=0

  pre="${label:0:${hot_idx}}"
  hot_l="$(printf '%s' "${label:${hot_idx}:1}" | tr 'a-z' 'A-Z')"
  rest="${label:$((hot_idx + 1))}"
  body="${pre}${hot_l}${rest}"
  if (( ${#body} > btn_w - 4 )); then
    body="$(ui_fit $((btn_w - 4)) "${body}")"
    # After fit, keep highlight on first char if index was cut away
    if (( hot_idx >= ${#body} )); then
      pre=""
      hot_l="${body:0:1}"
      rest="${body:1}"
    else
      pre="${body:0:${hot_idx}}"
      hot_l="${body:${hot_idx}:1}"
      rest="${body:$((hot_idx + 1))}"
    fi
  fi
  pad=$(( btn_w - 4 - ${#pre} - ${#hot_l} - ${#rest} ))
  (( pad < 0 )) && pad=0

  if [[ "${UI_BUF_HOLD:-0}" != "1" ]]; then
    ui_buf_reset
  fi
  ui_goto "${row}" "${bx}"
  if [[ "${selected}" == "1" ]]; then
    UI_BUF+="${UI_SEL}${UI_AL} ${UI_SEL}${pre}${UI_SEL_HOT}${hot_l}${UI_SEL}${rest}"
    UI_BUF+="$(ui_spaces "${pad}")"
    UI_BUF+=" ${UI_AR}${UI_RST}"
  else
    UI_BUF+="${UI_BTN}  ${UI_BTN}${pre}${UI_BTN_HOT}${hot_l}${UI_BTN}${rest}"
    UI_BUF+="$(ui_spaces "${pad}")"
    UI_BUF+="  ${UI_RST}"
  fi

  if [[ -n "${value}" || "${val_w}" -gt 0 ]]; then
    local vshow vw=$((val_w - 2)) off loop d
    (( vw < 1 )) && vw=1
    if [[ "${selected}" == "1" ]] && (( ${#value} > vw )); then
      loop="${value}   "
      off=$(( ${UI_MENU_MARQUEE_OFF:-0} % ${#loop} ))
      d="${loop}${loop}"
      vshow="${d:${off}:${vw}}"
    elif (( ${#value} > vw )); then
      vshow="$(ui_fit "${vw}" "${value}")"
    else
      vshow="$(printf '%-*s' "${vw}" "${value}")"
    fi
    ui_goto "${row}" "${vx}"
    UI_BUF+="${UI_PANEL}= ${UI_VALUE}${vshow}${UI_RST}"
  fi
  if [[ "${UI_BUF_HOLD:-0}" != "1" ]]; then
    ui_buf_flush
  fi
}

ui_read_key() {
  local k="" rest="" oc or
  # Safety: never leave a held paint buffer across input waits
  UI_BUF_HOLD=0
  # Honour one-slot pushback from ui_coalesce_nav
  if [[ -n "${UI_KEY_PUSHBACK}" ]]; then
    k="${UI_KEY_PUSHBACK}"
    UI_KEY_PUSHBACK=""
    case "${k}" in
      UP|DOWN|LEFT|RIGHT|ESC|ENTER|DEL|BACKSPACE|RESIZE|TIMEOUT) ui_note_input "${k}"; echo "${k}"; return 0 ;;
      *) printf '%s\n' "${k}"; ui_note_input "${k}"; return 0 ;;
    esac
  fi
  # Idle timeout ~0.3s: keeps CPU low on MiSTer; still responsive enough for UI
  if ! IFS= read -rsn1 -t 0.3 k; then
    oc="${UI_COLS}"; or="${UI_ROWS}"
    if [[ "${UI_RESIZE}" -eq 1 ]]; then
      UI_RESIZE=0
      ui_detect_size
      echo RESIZE
      return 0
    fi
    # Rare stty poll (~every 3s) for SSH clients that miss WINCH
    UI_RESIZE_TICK=$((UI_RESIZE_TICK + 1))
    if (( UI_RESIZE_TICK >= 10 )); then
      UI_RESIZE_TICK=0
      ui_detect_size
      if [[ "${UI_COLS}" -ne "${oc}" || "${UI_ROWS}" -ne "${or}" ]]; then
        echo RESIZE
        return 0
      fi
    fi
    echo TIMEOUT
    return 0
  fi
  UI_RESIZE_TICK=0
  # XOFF/XON (Ctrl+S/Q) ? classic "frozen TUI"; drop + ensure flow control off
  if [[ "${k}" == $'\x13' || "${k}" == $'\x11' ]]; then
    ui_tty_raw
    echo TIMEOUT
    return 0
  fi
  if [[ "${k}" == $'\x1b' ]]; then
    rest=""
    # Short CSI wait (was 0.25s ? rapid Esc flood looked like a hard freeze)
    IFS= read -rsn1 -t 0.08 rest || true
    if [[ "${rest}" == "[" ]]; then
      IFS= read -rsn1 -t 0.08 rest || true
      case "${rest}" in
        A) ui_esc_hold_reset; ui_note_input UP; echo UP; return 0 ;;
        B) ui_esc_hold_reset; ui_note_input DOWN; echo DOWN; return 0 ;;
        C) ui_esc_hold_reset; ui_note_input RIGHT; echo RIGHT; return 0 ;;
        D) ui_esc_hold_reset; ui_note_input LEFT; echo LEFT; return 0 ;;
        3)
          IFS= read -rsn1 -t 0.08 rest || true
          ui_esc_hold_reset
          ui_note_input DEL; echo DEL; return 0
          ;;
      esac
    fi
    ui_esc_hold_on_esc
    return 0
  fi
  if [[ "${k}" == $'\x7f' || "${k}" == $'\b' ]]; then
    ui_esc_hold_reset
    ui_note_input BACKSPACE; echo BACKSPACE; return 0
  fi
  if [[ "${k}" == "" || "${k}" == $'\n' || "${k}" == $'\r' ]]; then
    ui_esc_hold_reset
    ui_note_input ENTER; echo ENTER; return 0
  fi
  # English hotkeys regardless of keyboard layout (RU/UA -> QWERTY Latin)
  if [[ "${#k}" -eq 1 ]]; then
    local lat
    lat="$(ui_latin_key "${k}")"
    if [[ "${lat}" =~ ^[a-z0-9]$ ]]; then
      k="${lat}"
    fi
  fi
  ui_esc_hold_reset
  printf '%s\n' "${k}"
  ui_note_input "${k}"
}

# Non-blocking abort check for long ops (poll loops / between steps).
# Esc or pad B -> Yes/No warning. Return 0 = user confirmed cancel.
# Leftover Enter/arrows from a just-closed dialog must NOT trigger abort.
ui_user_wants_abort() {
  local k rest=""
  # 50ms window — usable from sleep-poll loops (indexing / download / extract)
  if ! IFS= read -rsn1 -t 0.05 k 2>/dev/null; then
    return 1
  fi
  # Drop buffered noise (Enter after OK, printable hotkeys, etc.)
  if [[ "${k}" != $'\x1b' && "${k}" != "b" && "${k}" != "B" ]]; then
    return 1
  fi
  if [[ "${k}" == $'\x1b' ]]; then
    # Longer CSI wait: slow USB/SSH often delivers "[" >80ms after Esc.
    # Bare Esc with a late "[" used to false-trigger "Stop this operation?".
    rest=""
    IFS= read -rsn1 -t 0.2 rest 2>/dev/null || true
    if [[ -n "${rest}" ]]; then
      if [[ "${rest}" == "[" ]]; then
        # Consume CSI final byte(s); never abort on arrows / Delete
        IFS= read -rsn1 -t 0.08 rest 2>/dev/null || true
        while [[ "${rest}" =~ ^[0-9\;]$ ]]; do
          IFS= read -rsn1 -t 0.08 rest 2>/dev/null || true
        done
        return 1
      fi
      # ESC + other (SS3 / Alt-key) — not a cancel request
      return 1
    fi
  fi
  ui_note_input "${k}"
  ui_esc_hold_reset
  if ui_yesno "Cancel?" \
    "Stop this operation?"$'\n'"Unfinished work may be discarded."; then
    return 0
  fi
  # Declined: force progress/busy chrome to redraw on next paint
  UI_PROGRESS_ACTIVE=0
  UI_NEED_REPAINT=1
  UI_NEED_DESKTOP=1
  return 1
}

# Refresh progress/busy footer with elapsed seconds (visible keep-alive).
ui_activity_tick() {
  local el tip
  if [[ "${UI_PROGRESS_ACTIVE:-0}" == "1" ]]; then
    el=$(( SECONDS - ${UI_PROGRESS_T0:-SECONDS} ))
    (( el < 0 )) && el=0
    tip="Working ${el}s... Esc/B=Cancel"
    printf '\e[%d;%dH%s%-*.*s%s' $((UI_PROGRESS_MY + 7)) $((UI_PROGRESS_MX + 3)) \
      "${UI_MUTED}" $((UI_PROGRESS_MW - 6)) $((UI_PROGRESS_MW - 6)) "${tip}" "${UI_RST}"
  elif [[ "${UI_BUSY_SHOWN:-0}" == "1" ]]; then
    el=$(( SECONDS - ${UI_BUSY_T0:-SECONDS} ))
    (( el < 0 )) && el=0
    tip="Esc/B = Cancel  (${el}s)"
    printf '\e[%d;%dH%s%-*.*s%s' $((UI_BUSY_MY + UI_BUSY_MH - 2)) $((UI_BUSY_MX + 3)) \
      "${UI_MUTED}" $((UI_BUSY_MW - 6)) $((UI_BUSY_MW - 6)) "${tip}" "${UI_RST}"
  fi
}

# Kept for call sites; activity line is updated by ui_activity_tick.
ui_progress_spin_tick() { ui_activity_tick; }
ui_busy_tick() { ui_activity_tick; }

# Wait for background PID. Return 0=ok, 1=fail, 2=user cancelled.
# IMPORTANT: call as `ui_wait_pid_abortable "$pid"; rc=$?` — never via $(...)
# Optional 2nd arg "aria2": also kill_aria2_orphans on cancel (fetch/download only).
ui_wait_pid_abortable() {
  local pid="$1" mode="${2:-}" rc=0 c
  [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 1
  # Drop keys left over from the dialog that started this long op (Enter/OK etc.)
  [[ "${UI_ACTIVE:-0}" == "1" ]] && ui_drain_keys
  while kill -0 "${pid}" 2>/dev/null; do
    ui_activity_tick
    if [[ "${UI_ACTIVE:-0}" == "1" ]] && ui_user_wants_abort; then
      kill "${pid}" 2>/dev/null || true
      # Best-effort: children of this PID (timeout→aria2, pipelines, etc.)
      for c in $(ps 2>/dev/null | awk -v p="${pid}" '$1 != p && $2 == p { print $1 }'); do
        [[ "${c}" =~ ^[0-9]+$ ]] && kill "${c}" 2>/dev/null || true
      done
      sleep 0.1
      kill -9 "${pid}" 2>/dev/null || true
      if [[ "${mode}" == "aria2" && "$(type -t kill_aria2_orphans 2>/dev/null)" == "function" ]]; then
        kill_aria2_orphans
      fi
      wait "${pid}" 2>/dev/null || true
      return 2
    fi
    sleep 0.2
  done
  wait "${pid}" || rc=$?
  (( rc == 0 )) && return 0
  return 1
}

# Run command in background with cancel + activity timer. Return 0/1/2.
# Usage: ui_run_abortable [aria2] -- cmd args...
ui_run_abortable() {
  local mode="" pid wr=0
  if [[ "${1:-}" == "aria2" ]]; then
    mode="aria2"
    shift
  fi
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  (("$#" >= 1)) || return 1
  "$@" &
  pid=$!
  if [[ "${UI_ACTIVE:-0}" == "1" ]]; then
    ui_wait_pid_abortable "${pid}" "${mode}"
    wr=$?
  else
    wait "${pid}" || wr=1
    (( wr != 0 )) && wr=1
  fi
  (( wr == 2 )) && return 2
  (( wr == 0 )) && return 0
  return 1
}

ui_setup_menu() {
  local header="$1" footer="$2" panel_title="$3"
  shift 3
  local -a items=("$@")
  local n="${#items[@]}"
  local sel=0 prev=-1 key i need_full=1 soft_enter=0
  local mx my mw mh btn_w val_w bx vx row
  local -a HOTS=() LABELS=() VALUES=() HOTSL=() HOTIDX=()
  local hot label value
  local longest_val=0 longest_lab=0
  (( n >= 1 )) || return 1
  UI_MENU_MARQUEE_OFF=0

  for ((i=0; i<n; i++)); do
    IFS='|' read -r hot label value <<<"${items[i]}"
    HOTS[i]="${hot}"; LABELS[i]="${label}"; VALUES[i]="${value}"
    (( ${#label} > longest_lab )) && longest_lab=${#label}
    (( ${#value} > longest_val )) && longest_val=${#value}
  done
  # Prefer 1st letter; on clash within this menu use 2nd/3rd... and highlight that char
  ui_menu_assign_hotkeys "${n}"

  # Re-enter over existing Steel Sky: soft panel (no desktop wipe)
  if [[ "${UI_NEED_DESKTOP}" == "1" ]]; then
    UI_NEED_DESKTOP=0
    UI_NEED_REPAINT=0
    need_full=1
  elif [[ "${UI_DESKTOP_READY:-0}" == "1" ]]; then
    need_full=0
    soft_enter=1
    UI_NEED_REPAINT=0
  fi

  while true; do
    local soft_panel=0
    if (( soft_enter )); then
      soft_enter=0
      soft_panel=1
    fi
    if [[ "${UI_NEED_DESKTOP}" == "1" ]]; then
      UI_NEED_DESKTOP=0
      UI_NEED_REPAINT=0
      need_full=1
    elif [[ "${UI_NEED_REPAINT}" == "1" ]]; then
      UI_NEED_REPAINT=0
      soft_panel=1
    fi
    if ui_check_resize; then need_full=1; fi

    if (( need_full || soft_panel )); then
      if (( need_full )); then
        ui_paint_desktop
      fi
      ui_chrome "${header}" "${footer}"

      # Widen for labels + hints; cap to terminal
      local max_w=$(( longest_lab + longest_val + 28 ))
      (( max_w < 62 )) && max_w=62
      (( max_w > UI_COLS - 4 )) && max_w=$((UI_COLS - 4))
      (( max_w < 40 )) && max_w=40
      mw="${max_w}"
      mh=$(( n * 2 + 5 ))
      if (( mh > UI_ROWS - 10 )); then mh=$((UI_ROWS - 10)); fi
      if (( mh < n + 4 )); then mh=$((n + 4)); fi
      mx=$(( (UI_COLS - mw) / 2 + 1 ))
      my=$(( (UI_ROWS - mh) / 2 ))
      if (( my < 5 )); then my=5; fi
      if (( my + mh > UI_ROWS - 3 )); then my=$((UI_ROWS - 3 - mh)); fi
      (( my < 4 )) && my=4

      ui_box "${mx}" "${my}" "${mw}" "${mh}" "${panel_title}"

      btn_w=$(( longest_lab + 8 ))
      (( btn_w < 18 )) && btn_w=18
      (( btn_w > mw / 2 - 2 )) && btn_w=$((mw / 2 - 2))
      (( btn_w < 14 )) && btn_w=14
      val_w=$((mw - btn_w - 10))
      (( val_w < 10 )) && val_w=10
      bx=$((mx + 3)); vx=$((bx + btn_w + 3))

      ui_buf_reset
      UI_BUF_HOLD=1
      for ((i=0; i<n; i++)); do
        row=$((my + 2 + i * 2))
        (( row >= my + mh - 2 )) && break
        ui_draw_item_row "${bx}" "${vx}" "${row}" "${btn_w}" "${val_w}" \
          "${HOTS[i]}" "${LABELS[i]}" "${VALUES[i]}" "$([[ $i -eq $sel ]] && echo 1 || echo 0)" \
          "${HOTIDX[i]}"
      done
      ui_goto $((my + mh - 2)) $((mx + 3))
      UI_BUF+="${UI_MUTED}$(printf '%-*.*s' $((mw-6)) $((mw-6)) "$(ui_fit $((mw-6)) "$(ui_hint_nav)")")${UI_RST}"
      UI_BUF_HOLD=0
      ui_buf_flush
      prev="${sel}"; need_full=0
      ui_hints_ack
    elif (( prev != sel )); then
      # Selection-only: rewrite 2 rows, one tty flush
      UI_MENU_MARQUEE_OFF=0
      ui_buf_reset
      UI_BUF_HOLD=1
      row=$((my + 2 + prev * 2))
      (( row < my + mh - 2 )) && ui_draw_item_row "${bx}" "${vx}" "${row}" "${btn_w}" "${val_w}" \
        "${HOTS[prev]}" "${LABELS[prev]}" "${VALUES[prev]}" 0 "${HOTIDX[prev]}"
      row=$((my + 2 + sel * 2))
      (( row < my + mh - 2 )) && ui_draw_item_row "${bx}" "${vx}" "${row}" "${btn_w}" "${val_w}" \
        "${HOTS[sel]}" "${LABELS[sel]}" "${VALUES[sel]}" 1 "${HOTIDX[sel]}"
      UI_BUF_HOLD=0
      ui_buf_flush
      prev="${sel}"
    fi

    if ui_hints_need_refresh; then
      # Hint line only ? no chrome/desktop
      printf '\e[%d;%dH%s%-*.*s%s' $((my+mh-2)) $((mx+3)) \
        "${UI_MUTED}" $((mw-6)) $((mw-6)) \
        "$(ui_fit $((mw-6)) "$(ui_hint_nav)")" "${UI_RST}"
      ui_hints_ack
    fi

    key="$(ui_read_key)" || true
    case "${key}" in
      TIMEOUT)
        # Marquee long value hint on the selected row
        if (( ${#VALUES[sel]} > val_w - 2 )); then
          UI_MENU_MARQUEE_OFF=$((UI_MENU_MARQUEE_OFF + 1))
          row=$((my + 2 + sel * 2))
          if (( row < my + mh - 2 )); then
            ui_draw_item_row "${bx}" "${vx}" "${row}" "${btn_w}" "${val_w}" \
              "${HOTS[sel]}" "${LABELS[sel]}" "${VALUES[sel]}" 1 "${HOTIDX[sel]}"
          fi
        fi
        continue
        ;;
      RESIZE) need_full=1; continue ;;
      UP)
        ui_coalesce_nav UP
        local _c
        for ((_c=0; _c<UI_COALESCE_N; _c++)); do
          sel=$(( (sel - 1 + n) % n ))
        done
        UI_MENU_MARQUEE_OFF=0
        ;;
      DOWN)
        ui_coalesce_nav DOWN
        local _c
        for ((_c=0; _c<UI_COALESCE_N; _c++)); do
          sel=$(( (sel + 1) % n ))
        done
        UI_MENU_MARQUEE_OFF=0
        ;;
      ENTER) UI_MENU_RESULT="${sel}"; return 0 ;;
      ESC) return 1 ;;
      *)
        # Assigned hot letter (layout already normalized in ui_read_key)
        if [[ "${#key}" -eq 1 ]]; then
          local ch num
          ch="$(ui_latin_key "${key}")"
          for ((i=0; i<n; i++)); do
            if [[ "${ch}" == "${HOTSL[i]}" ]]; then
              UI_MENU_RESULT="${i}"
              return 0
            fi
          done
          if [[ "${ch}" =~ ^[0-9]$ ]]; then
            num=$((10#${ch}))
            (( num >= 1 && num <= n )) && { UI_MENU_RESULT=$((num-1)); return 0; }
            (( num == 0 )) && { UI_MENU_RESULT=$((n-1)); return 0; }
          fi
        fi
        ;;
    esac
  done
}

# Small centered Yes/No dialog ? soft overlay (no desktop wipe); parent repaints after
ui_yesno() {
  local title="$1" msg="$2"
  local sel=0 prev=-1 key mw=54 mh=10 mx my need_full=1
  local _rc=1
  ui_drain_keys
  while true; do
    if ui_check_resize; then need_full=1; fi
    if (( need_full )); then
      ui_detect_size
      # Soft: draw on top of parent ? no ui_paint_desktop / chrome
      mw=54; (( mw > UI_COLS - 6 )) && mw=$((UI_COLS - 6))
      mh=10
      mx=$(( (UI_COLS - mw) / 2 + 1 ))
      my=$(( (UI_ROWS - mh) / 2 ))
      (( my < 3 )) && my=3
      ui_box "${mx}" "${my}" "${mw}" "${mh}" "${title}"
      ui_print_wrapped $((mx+3)) $((my+2)) $((mw-6)) 3 "${UI_PANEL}" "${msg}"
      prev=-1
      need_full=0
    fi
    if (( prev != sel )); then
      ui_buf_reset
      UI_BUF_HOLD=1
      ui_draw_item_row $((mx+4)) $((mx+4)) $((my+6)) 12 0 "Y" "Yes" "" "$([[ $sel -eq 0 ]] && echo 1 || echo 0)"
      ui_draw_item_row $((mx+20)) $((mx+20)) $((my+6)) 12 0 "N" "No" "" "$([[ $sel -eq 1 ]] && echo 1 || echo 0)"
      UI_BUF_HOLD=0
      ui_buf_flush
      prev="${sel}"
    fi
    key="$(ui_read_key)" || true
    case "${key}" in
      TIMEOUT) continue ;;
      RESIZE) need_full=1; continue ;;
      LEFT|UP) sel=0 ;;
      RIGHT|DOWN) sel=1 ;;
      ENTER) (( sel == 0 )) && _rc=0 || _rc=1; break ;;
      y|Y) _rc=0; break ;;
      n|N|ESC) _rc=1; break ;;
    esac
  done
  UI_NEED_REPAINT=1
  return "${_rc}"
}

# OK / Cancel dialog (first letters O / C). Soft overlay. Return 0=OK, 1=Cancel.
ui_okcancel() {
  local title="$1" msg="$2"
  local sel=0 prev=-1 key mw=58 mh=12 mx my need_full=1 tw lines
  local _rc=1
  ui_drain_keys
  while true; do
    if ui_check_resize; then need_full=1; fi
    if (( need_full )); then
      ui_detect_size
      mw=58; (( mw > UI_COLS - 6 )) && mw=$((UI_COLS - 6))
      tw=$((mw - 6))
      # Count wrapped lines including embedded newlines
      lines=0
      local para rest
      msg="${msg//$'\r'/}"
      while IFS= read -r para || [[ -n "${para}" ]]; do
        rest="${para}"
        (( lines++ ))
        while (( ${#rest} > tw )); do
          rest="${rest:tw}"
          (( lines++ ))
        done
      done <<< "${msg}"
      (( lines < 1 )) && lines=1
      (( lines > 6 )) && lines=6
      mh=$((lines + 7))
      (( mh < 11 )) && mh=11
      mx=$(( (UI_COLS - mw) / 2 + 1 ))
      my=$(( (UI_ROWS - mh) / 2 ))
      (( my < 3 )) && my=3
      ui_box "${mx}" "${my}" "${mw}" "${mh}" "${title}"
      ui_print_wrapped $((mx+3)) $((my+2)) "${tw}" "${lines}" "${UI_PANEL}" "${msg}"
      prev=-1
      need_full=0
    fi
    if (( prev != sel )); then
      ui_buf_reset
      UI_BUF_HOLD=1
      ui_draw_item_row $((mx+4)) $((mx+4)) $((my+mh-4)) 12 0 "O" "OK" "" "$([[ $sel -eq 0 ]] && echo 1 || echo 0)"
      ui_draw_item_row $((mx+20)) $((mx+20)) $((my+mh-4)) 14 0 "C" "Cancel" "" "$([[ $sel -eq 1 ]] && echo 1 || echo 0)"
      UI_BUF_HOLD=0
      ui_buf_flush
      prev="${sel}"
    fi
    key="$(ui_read_key)" || true
    case "${key}" in
      TIMEOUT) continue ;;
      RESIZE) need_full=1; continue ;;
      LEFT|UP) sel=0 ;;
      RIGHT|DOWN) sel=1 ;;
      ENTER) (( sel == 0 )) && _rc=0 || _rc=1; break ;;
      o|O|y|Y) _rc=0; break ;;
      c|C|n|N|ESC) _rc=1; break ;;
    esac
  done
  UI_NEED_REPAINT=1
  return "${_rc}"
}

# Progress dialog: ui_progress_paint title cur total label
# First paint draws chrome+box; later paints only update label/bar (no flicker).
UI_PROGRESS_ACTIVE=0
UI_PROGRESS_MX=0
UI_PROGRESS_MY=0
UI_PROGRESS_MW=58
UI_PROGRESS_MH=10
UI_PROGRESS_W=42

ui_progress_paint() {
  local title="$1" cur="$2" total="$3" label="${4:-}"
  local pct filled i bar
  UI_QUIET=1
  ui_detect_size
  (( total < 1 )) && total=1
  (( cur < 0 )) && cur=0
  (( cur > total )) && cur="${total}"
  pct=$(( cur * 100 / total ))

  if [[ "${UI_PROGRESS_ACTIVE}" != "1" ]]; then
    UI_PROGRESS_MW=58
    (( UI_PROGRESS_MW > UI_COLS - 6 )) && UI_PROGRESS_MW=$((UI_COLS - 6))
    UI_PROGRESS_W=$((UI_PROGRESS_MW - 14))
    (( UI_PROGRESS_W < 10 )) && UI_PROGRESS_W=10
    UI_PROGRESS_MX=$(( (UI_COLS - UI_PROGRESS_MW) / 2 + 1 ))
    UI_PROGRESS_MY=$(( (UI_ROWS - UI_PROGRESS_MH) / 2 ))
    (( UI_PROGRESS_MY < 4 )) && UI_PROGRESS_MY=4
    ui_paint_desktop
    UI_NEED_DESKTOP=1
    ui_chrome "$(app_title_ver)" "Please Wait"
    ui_box "${UI_PROGRESS_MX}" "${UI_PROGRESS_MY}" "${UI_PROGRESS_MW}" "${UI_PROGRESS_MH}" "${title}"
    UI_PROGRESS_ACTIVE=1
    UI_PROGRESS_T0="${SECONDS}"
  fi

  filled=$(( cur * UI_PROGRESS_W / total ))
  bar=""
  for ((i=0; i<UI_PROGRESS_W; i++)); do
    if (( i < filled )); then bar+="${UI_BAR_ON}"; else bar+="${UI_BAR_OFF}"; fi
  done
  printf '\e[%d;%dH%s%-*.*s%s' $((UI_PROGRESS_MY+2)) $((UI_PROGRESS_MX+3)) \
    "${UI_PANEL}" $((UI_PROGRESS_MW-6)) $((UI_PROGRESS_MW-6)) "$(ui_fit $((UI_PROGRESS_MW-6)) "${label}")" "${UI_RST}"
  printf '\e[%d;%dH%s[%-*.*s]%s %s%3d%%%s' $((UI_PROGRESS_MY+4)) $((UI_PROGRESS_MX+3)) \
    "${UI_BORDER}" "${UI_PROGRESS_W}" "${UI_PROGRESS_W}" "${bar}" "${UI_RST}" \
    "${UI_VALUE}" "${pct}" "${UI_RST}"
  printf '\e[%d;%dH%s%-*.*s%s' $((UI_PROGRESS_MY+6)) $((UI_PROGRESS_MX+3)) \
    "${UI_MUTED}" $((UI_PROGRESS_MW-6)) $((UI_PROGRESS_MW-6)) \
    "$(ui_fit $((UI_PROGRESS_MW-6)) "Item ${cur} of ${total}")" "${UI_RST}"
  ui_activity_tick
}

ui_progress_done() {
  # Keep UI_QUIET as caller left it ? do not dump logs onto Steel Sky
  if [[ "${UI_PROGRESS_ACTIVE}" == "1" ]]; then
    UI_NEED_DESKTOP=1
  fi
  UI_PROGRESS_ACTIVE=0
}

# Human-readable byte size
ui_fmt_bytes() {
  local n="${1:-0}"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  if (( n >= 1073741824 )); then
    awk -v n="${n}" 'BEGIN{printf "%.2f GiB", n/1073741824}'
  elif (( n >= 1048576 )); then
    awk -v n="${n}" 'BEGIN{printf "%.2f MiB", n/1048576}'
  elif (( n >= 1024 )); then
    awk -v n="${n}" 'BEGIN{printf "%.1f KiB", n/1024}'
  else
    printf '%d B' "${n}"
  fi
}

ui_fmt_speed() {
  local n="${1:-0}"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  printf '%s/s' "$(ui_fmt_bytes "${n}")"
}

ui_fmt_eta() {
  local sec="${1:-0}"
  [[ "${sec}" =~ ^[0-9]+$ ]] || sec=0
  (( sec < 1 )) && { printf -- '--'; return 0; }
  if (( sec >= 3600 )); then
    printf '%dh%02dm' $((sec / 3600)) $(((sec % 3600) / 60))
  elif (( sec >= 60 )); then
    printf '%dm%02ds' $((sec / 60)) $((sec % 60))
  else
    printf '%ds' "${sec}"
  fi
}

# Torrent download progress: title, got, total, name, speed_bps, seeds, peers, eta_sec, status
ui_dl_progress_paint() {
  local title="$1" cur="$2" total="$3" label="${4:-}"
  local speed="${5:-0}" seeds="${6:-0}" peers="${7:-0}" eta="${8:-}" status="${9:-}"
  local pct filled i bar line left
  UI_QUIET=1
  ui_detect_size
  (( total < 1 )) && total=1
  (( cur < 0 )) && cur=0
  (( cur > total )) && cur="${total}"
  pct=$(( cur * 100 / total ))
  left=$(( total - cur ))
  (( left < 0 )) && left=0

  if [[ "${UI_PROGRESS_ACTIVE}" != "1" ]]; then
    UI_PROGRESS_MW=64
    (( UI_PROGRESS_MW > UI_COLS - 4 )) && UI_PROGRESS_MW=$((UI_COLS - 4))
    UI_PROGRESS_MH=14
    UI_PROGRESS_W=$((UI_PROGRESS_MW - 14))
    (( UI_PROGRESS_W < 10 )) && UI_PROGRESS_W=10
    UI_PROGRESS_MX=$(( (UI_COLS - UI_PROGRESS_MW) / 2 + 1 ))
    UI_PROGRESS_MY=$(( (UI_ROWS - UI_PROGRESS_MH) / 2 ))
    (( UI_PROGRESS_MY < 3 )) && UI_PROGRESS_MY=3
    ui_paint_desktop
    UI_NEED_DESKTOP=1
    case "${title}" in
      Extract) ui_chrome "$(app_title_ver)" "Extracting" ;;
      *) ui_chrome "$(app_title_ver)" "Downloading" ;;
    esac
    ui_box "${UI_PROGRESS_MX}" "${UI_PROGRESS_MY}" "${UI_PROGRESS_MW}" "${UI_PROGRESS_MH}" "${title}"
    UI_PROGRESS_ACTIVE=1
  fi

  filled=$(( cur * UI_PROGRESS_W / total ))
  bar=""
  for ((i=0; i<UI_PROGRESS_W; i++)); do
    if (( i < filled )); then bar+="${UI_BAR_ON}"; else bar+="${UI_BAR_OFF}"; fi
  done

  printf '\e[%d;%dH%s%-*.*s%s' $((UI_PROGRESS_MY+2)) $((UI_PROGRESS_MX+3)) \
    "${UI_PANEL}" $((UI_PROGRESS_MW-6)) $((UI_PROGRESS_MW-6)) \
    "$(ui_fit $((UI_PROGRESS_MW-6)) "${label}")" "${UI_RST}"
  printf '\e[%d;%dH%s[%-*.*s]%s %s%3d%%%s' $((UI_PROGRESS_MY+4)) $((UI_PROGRESS_MX+3)) \
    "${UI_BORDER}" "${UI_PROGRESS_W}" "${UI_PROGRESS_W}" "${bar}" "${UI_RST}" \
    "${UI_VALUE}" "${pct}" "${UI_RST}"

  line="Got $(ui_fmt_bytes "${cur}")  /  $(ui_fmt_bytes "${total}")   Left $(ui_fmt_bytes "${left}")"
  printf '\e[%d;%dH%s%-*.*s%s' $((UI_PROGRESS_MY+6)) $((UI_PROGRESS_MX+3)) \
    "${UI_PANEL}" $((UI_PROGRESS_MW-6)) $((UI_PROGRESS_MW-6)) \
    "$(ui_fit $((UI_PROGRESS_MW-6)) "${line}")" "${UI_RST}"

  line="Speed $(ui_fmt_speed "${speed}")   ETA $(ui_fmt_eta "${eta}")"
  printf '\e[%d;%dH%s%-*.*s%s' $((UI_PROGRESS_MY+7)) $((UI_PROGRESS_MX+3)) \
    "${UI_PANEL}" $((UI_PROGRESS_MW-6)) $((UI_PROGRESS_MW-6)) \
    "$(ui_fit $((UI_PROGRESS_MW-6)) "${line}")" "${UI_RST}"

  if [[ "${seeds}" == "-" ]]; then
    # Extract / non-torrent byte progress (no seed/peer stats)
    line="${status:-working}"
  else
    line="Seeds ${seeds}   Peers ${peers}"
    [[ -n "${status}" ]] && line+="   [${status}]"
  fi
  printf '\e[%d;%dH%s%-*.*s%s' $((UI_PROGRESS_MY+8)) $((UI_PROGRESS_MX+3)) \
    "${UI_PANEL}" $((UI_PROGRESS_MW-6)) $((UI_PROGRESS_MW-6)) \
    "$(ui_fit $((UI_PROGRESS_MW-6)) "${line}")" "${UI_RST}"

  printf '\e[%d;%dH%s%-*.*s%s' $((UI_PROGRESS_MY+10)) $((UI_PROGRESS_MX+3)) \
    "${UI_MUTED}" $((UI_PROGRESS_MW-6)) $((UI_PROGRESS_MW-6)) \
    "Esc/B = Cancel" "${UI_RST}"
}

# Lightweight please-wait box. UI_BUSY_SOFT=1 skips full desktop wipe (less flicker).
UI_BUSY_SOFT=0
UI_BUSY_SHOWN=0
UI_BUSY_MX=0
UI_BUSY_MY=0
UI_BUSY_MW=52
UI_BUSY_MH=8

ui_busy_show() {
  local title="${1:-Please Wait}" msg="${2:-Working...}"
  local mw=52 mh=8 mx my
  UI_QUIET=1
  ui_detect_size
  mw=52; (( mw > UI_COLS - 6 )) && mw=$((UI_COLS - 6))
  mx=$(( (UI_COLS - mw) / 2 + 1 ))
  my=$(( (UI_ROWS - mh) / 2 ))
  (( my < 4 )) && my=4
  UI_BUSY_MX="${mx}"
  UI_BUSY_MY="${my}"
  UI_BUSY_MW="${mw}"
  UI_BUSY_MH="${mh}"
  if [[ "${UI_BUSY_SOFT}" != "1" ]]; then
    ui_paint_desktop
    UI_NEED_DESKTOP=1
    ui_chrome "$(app_title_ver)" "Please Wait"
  fi
  ui_box "${mx}" "${my}" "${mw}" "${mh}" "${title}"
  ui_print_wrapped $((mx+3)) $((my+2)) $((mw-6)) 3 "${UI_PANEL}" "${msg}"
  UI_BUSY_SHOWN=1
  UI_BUSY_T0="${SECONDS}"
  ui_activity_tick
}

ui_busy_done() {
  UI_BUSY_SHOWN=0
  # Soft busy: parent soft-redraws its panel. Hard busy already set UI_NEED_DESKTOP.
  if [[ "${UI_BUSY_SOFT}" == "1" ]]; then
    UI_NEED_REPAINT=1
  else
    UI_NEED_DESKTOP=1
  fi
  UI_BUSY_SOFT=0
}

ui_osk_clear_overlay() {
  ui_osk_geom
  local r fill
  fill="$(ui_fill_line "${UI_COLS}" "${UI_DESK_CH}")"
  for ((r=UI_OSK_OY - 1; r<UI_OSK_OY+UI_OSK_OH+1 && r<=UI_ROWS; r++)); do
    (( r < 1 )) && continue
    printf '\e[%d;%dH%s%s%s' "${r}" 1 "${UI_DESK}" "${fill}" "${UI_RST}"
  done
}

# ?? Shared on-screen keyboard (physical KB + gamepad) ?????????????????
# Overlay at bottom of screen; does NOT wipe the parent window.
# State: UI_OSK_TEXT, UI_OSK_EVENT (none|changed|ok|cancel)
UI_OSK_TEXT=""
UI_OSK_EVENT="none"
UI_OSK_KR=0
UI_OSK_KC=0
UI_OSK_SHIFT=0
UI_OSK_KEYS=()
UI_OSK_OX=0
UI_OSK_OY=0
UI_OSK_OW=0
UI_OSK_OH=9

ui_osk_rebuild_keys() {
  UI_OSK_KEYS=()
  if (( UI_OSK_SHIFT == 0 )); then
    UI_OSK_KEYS+=(1 2 3 4 5 6 7 8 9 0)
    UI_OSK_KEYS+=(q w e r t y u i o p)
    UI_OSK_KEYS+=(a s d f g h j k l _)
    UI_OSK_KEYS+=(z x c v b n m . / :)
  else
    UI_OSK_KEYS+=(1 2 3 4 5 6 7 8 9 0)
    UI_OSK_KEYS+=(Q W E R T Y U I O P)
    UI_OSK_KEYS+=(A S D F G H J K L _)
    UI_OSK_KEYS+=(Z X C V B N M @ = ?)
  fi
  UI_OSK_KEYS+=("SPC" "BKSP" "Aa" "OK")
  if [[ "${UI_OSK_MODE}" == "filter" ]]; then
    UI_OSK_KEYS+=("DISCARD")
  else
    UI_OSK_KEYS+=("ESC")
  fi
}

ui_osk_reset() {
  UI_OSK_TEXT="${1:-}"
  UI_OSK_EVENT="none"
  UI_OSK_KR=0
  UI_OSK_KC=0
  UI_OSK_PREV_KR=-1
  UI_OSK_PREV_KC=-1
  UI_OSK_SHIFT=0
  UI_OSK_NAVIGATED=0
  UI_OSK_FOCUS="text"
  ui_osk_rebuild_keys
}

# Geometry: full-width strip above footer chrome
ui_osk_geom() {
  ui_detect_size
  UI_OSK_OH=9
  UI_OSK_OW=$((UI_COLS - 2))
  (( UI_OSK_OW < 40 )) && UI_OSK_OW=40
  UI_OSK_OX=2
  UI_OSK_OY=$((UI_ROWS - UI_OSK_OH - 3))
  (( UI_OSK_OY < 5 )) && UI_OSK_OY=5
}

# Paint one OSK cell (r=0..3 letter rows, r=4 action row)
ui_osk_paint_cell() {
  local r="$1" c="$2" selected="$3"
  local xx yy label cell_w idx
  if (( r < 4 )); then
    cell_w=$(( (UI_OSK_OW - 6) / 10 )); (( cell_w < 3 )) && cell_w=3
    idx=$((r * 10 + c))
    xx=$((UI_OSK_OX + 3 + c * cell_w))
    yy=$((UI_OSK_OY + 3 + r))
    (( yy >= UI_OSK_OY + UI_OSK_OH - 1 )) && return 0
  else
    cell_w=$(( (UI_OSK_OW - 6) / 5 )); (( cell_w < 7 )) && cell_w=7
    idx=$((40 + c))
    xx=$((UI_OSK_OX + 3 + c * cell_w))
    yy=$((UI_OSK_OY + 7))
    (( yy >= UI_ROWS - 2 )) && return 0
  fi
  if (( selected )); then
    label="[${UI_OSK_KEYS[idx]}]"
    printf '\e[%d;%dH%s%-*.*s%s' "${yy}" "${xx}" "${UI_OSK_SEL}" "${cell_w}" "${cell_w}" "${label}" "${UI_RST}"
  else
    label=" ${UI_OSK_KEYS[idx]}"
    printf '\e[%d;%dH%s%-*.*s%s' "${yy}" "${xx}" "${UI_BTN}" "${cell_w}" "${cell_w}" "${label}" "${UI_RST}"
  fi
}

ui_osk_paint_text() {
  local show
  show="${UI_OSK_TEXT}"
  if (( ${#show} + 1 > UI_OSK_OW - 6 )); then
    show="${show:$(( ${#show} - (UI_OSK_OW - 7) ))}"
  fi
  printf '\e[%d;%dH%s%-*.*s%s' $((UI_OSK_OY+1)) $((UI_OSK_OX+3)) \
    "${UI_INPUT}" $((UI_OSK_OW-6)) $((UI_OSK_OW-6)) "${show}_" "${UI_RST}"
}

# Move highlight without redrawing the whole keyboard (no blink)
ui_osk_paint_cursor() {
  if (( UI_OSK_PREV_KR >= 0 && UI_OSK_PREV_KC >= 0 )); then
    if [[ "${UI_OSK_PREV_KR}" -ne "${UI_OSK_KR}" || "${UI_OSK_PREV_KC}" -ne "${UI_OSK_KC}" ]]; then
      ui_osk_paint_cell "${UI_OSK_PREV_KR}" "${UI_OSK_PREV_KC}" 0
    fi
  fi
  ui_osk_paint_cell "${UI_OSK_KR}" "${UI_OSK_KC}" 1
  UI_OSK_PREV_KR="${UI_OSK_KR}"
  UI_OSK_PREV_KC="${UI_OSK_KC}"
}

ui_osk_paint() {
  local title="${1:-Type}"
  local i r c sel_on=0
  ui_osk_geom
  ui_box "${UI_OSK_OX}" "${UI_OSK_OY}" "${UI_OSK_OW}" "${UI_OSK_OH}" "${title}"
  ui_osk_paint_text
  [[ "${UI_OSK_FOCUS}" == "keys" ]] && sel_on=1
  for ((i=0; i<40; i++)); do
    r=$((i / 10)); c=$((i % 10))
    if (( sel_on && UI_OSK_KR == r && UI_OSK_KC == c )); then
      ui_osk_paint_cell "${r}" "${c}" 1
    else
      ui_osk_paint_cell "${r}" "${c}" 0
    fi
  done
  for ((i=0; i<5; i++)); do
    if (( sel_on && UI_OSK_KR == 4 && UI_OSK_KC == i )); then
      ui_osk_paint_cell 4 "${i}" 1
    else
      ui_osk_paint_cell 4 "${i}" 0
    fi
  done
  if (( sel_on )); then
    UI_OSK_PREV_KR="${UI_OSK_KR}"
    UI_OSK_PREV_KC="${UI_OSK_KC}"
  else
    UI_OSK_PREV_KR=-1
    UI_OSK_PREV_KC=-1
  fi
}

ui_osk_press_idx() {
  local idx="$1" ch
  ch="${UI_OSK_KEYS[idx]}"
  case "${ch}" in
    SPC) UI_OSK_TEXT+=" "; UI_OSK_EVENT="changed" ;;
    BKSP)
      if [[ -n "${UI_OSK_TEXT}" ]]; then
        UI_OSK_TEXT="${UI_OSK_TEXT:0:${#UI_OSK_TEXT}-1}"
        UI_OSK_EVENT="changed"
      else
        UI_OSK_EVENT="none"
      fi
      ;;
    Aa) UI_OSK_SHIFT=$((1 - UI_OSK_SHIFT)); ui_osk_rebuild_keys; UI_OSK_EVENT="layout" ;;
    OK) UI_OSK_EVENT="ok" ;;
    ESC)
      # Esc always cancels (never backspace). Use BKSP key / Backspace for delete.
      UI_OSK_EVENT="cancel"
      ;;
    DISCARD) UI_OSK_TEXT=""; UI_OSK_EVENT="discard" ;;
    *) UI_OSK_TEXT+="${ch}"; UI_OSK_EVENT="changed" ;;
  esac
}

# Feed one ui_read_key token into OSK. Sets UI_OSK_EVENT.
# Focus "text": typing edits field, Enter=OK/Apply, Down=enter on-screen keys.
# Focus "keys": arrows move highlight, Enter presses key, Up from top row ? text.
ui_osk_feed() {
  local key="$1" idx
  UI_OSK_EVENT="none"
  case "${key}" in
    TIMEOUT|RESIZE) return 0 ;;
    ESC)
      UI_OSK_EVENT="cancel"
      ;;
    UP)
      if [[ "${UI_OSK_FOCUS}" == "text" ]]; then
        UI_OSK_EVENT="none"
        return 0
      fi
      if (( UI_OSK_KR <= 0 )); then
        UI_OSK_FOCUS="text"
        UI_OSK_PREV_KR=-1
        UI_OSK_PREV_KC=-1
        UI_OSK_EVENT="layout"
        return 0
      fi
      UI_OSK_KR=$((UI_OSK_KR - 1))
      (( UI_OSK_KR < 4 && UI_OSK_KC > 9 )) && UI_OSK_KC=9
      (( UI_OSK_KR == 4 && UI_OSK_KC > 4 )) && UI_OSK_KC=4
      UI_OSK_NAVIGATED=1
      UI_OSK_EVENT="redraw"
      ;;
    DOWN)
      if [[ "${UI_OSK_FOCUS}" == "text" ]]; then
        UI_OSK_FOCUS="keys"
        UI_OSK_KR=0
        UI_OSK_KC=0
        UI_OSK_NAVIGATED=1
        UI_OSK_EVENT="layout"
        return 0
      fi
      if (( UI_OSK_KR < 4 )); then
        UI_OSK_KR=$((UI_OSK_KR + 1))
        if (( UI_OSK_KR == 4 )); then
          UI_OSK_KC=$(( UI_OSK_KC * 4 / 9 ))
          (( UI_OSK_KC > 4 )) && UI_OSK_KC=4
        fi
      fi
      UI_OSK_NAVIGATED=1
      UI_OSK_EVENT="redraw"
      ;;
    LEFT)
      if [[ "${UI_OSK_FOCUS}" != "keys" ]]; then
        UI_OSK_EVENT="none"
        return 0
      fi
      if (( UI_OSK_KC > 0 )); then UI_OSK_KC=$((UI_OSK_KC - 1))
      elif (( UI_OSK_KR > 0 )); then
        UI_OSK_KR=$((UI_OSK_KR - 1))
        (( UI_OSK_KR == 4 )) && UI_OSK_KC=4 || UI_OSK_KC=9
      fi
      UI_OSK_NAVIGATED=1
      UI_OSK_EVENT="redraw"
      ;;
    RIGHT)
      if [[ "${UI_OSK_FOCUS}" != "keys" ]]; then
        UI_OSK_EVENT="none"
        return 0
      fi
      if (( UI_OSK_KR == 4 )); then
        (( UI_OSK_KC < 4 )) && UI_OSK_KC=$((UI_OSK_KC + 1))
      else
        if (( UI_OSK_KC < 9 )); then UI_OSK_KC=$((UI_OSK_KC + 1))
        elif (( UI_OSK_KR < 4 )); then UI_OSK_KR=$((UI_OSK_KR + 1)); UI_OSK_KC=0
        fi
      fi
      UI_OSK_NAVIGATED=1
      UI_OSK_EVENT="redraw"
      ;;
    ENTER)
      if [[ "${UI_OSK_FOCUS}" != "keys" ]]; then
        # Physical Enter while typing ? apply / OK
        UI_OSK_EVENT="ok"
        return 0
      fi
      if (( UI_OSK_KR < 4 )); then idx=$((UI_OSK_KR * 10 + UI_OSK_KC)); else idx=$((40 + UI_OSK_KC)); fi
      ui_osk_press_idx "${idx}"
      ;;
    " ")
      if [[ "${UI_OSK_FOCUS}" != "keys" ]]; then
        UI_OSK_TEXT+=" "
        UI_OSK_EVENT="changed"
        return 0
      fi
      if (( UI_OSK_KR < 4 )); then idx=$((UI_OSK_KR * 10 + UI_OSK_KC)); else idx=$((40 + UI_OSK_KC)); fi
      ui_osk_press_idx "${idx}"
      ;;
    BACKSPACE|DEL)
      if [[ -n "${UI_OSK_TEXT}" ]]; then
        UI_OSK_TEXT="${UI_OSK_TEXT:0:${#UI_OSK_TEXT}-1}"
        UI_OSK_EVENT="changed"
      fi
      ;;
    [[:print:]])
      if [[ "${#key}" -eq 1 ]]; then
        UI_OSK_TEXT+="${key}"
        # Stay in text mode so Enter still means Apply
        UI_OSK_FOCUS="text"
        UI_OSK_EVENT="changed"
      fi
      ;;
  esac
}

# Text edit overlay (URL etc). Sets UI_INPUT_RESULT. Return 0=OK, 1=Cancel.
ui_input_box() {
  local title="$1" prompt="$2" initial="${3:-}"
  local key osk_dirty=1
  local prev_mode="${UI_OSK_MODE}"
  UI_INPUT_RESULT=""
  UI_OSK_MODE="edit"
  ui_drain_keys
  ui_osk_reset "${initial}"

  while true; do
    if ui_check_resize; then osk_dirty=1; fi
    if (( osk_dirty )); then
      ui_osk_geom
      printf '\e[%d;%dH%s%-*.*s%s' $((UI_OSK_OY - 1)) "${UI_OSK_OX}" \
        "${UI_MUTED}" $((UI_OSK_OW)) $((UI_OSK_OW)) \
        "$(ui_fit "${UI_OSK_OW}" " ${prompt}  |  Enter=OK  Down=Keyboard  Esc=Cancel")" "${UI_RST}"
      ui_osk_paint "${title}"
      osk_dirty=0
    fi
    key="$(ui_read_key)" || true
    [[ "${key}" == "TIMEOUT" ]] && continue
    [[ "${key}" == "RESIZE" ]] && { osk_dirty=1; continue; }
    ui_osk_feed "${key}"
    case "${UI_OSK_EVENT}" in
      redraw) ui_osk_paint_cursor ;;
      changed) ui_osk_paint_text ;;
      layout) osk_dirty=1 ;;
      ok)
        UI_INPUT_RESULT="${UI_OSK_TEXT}"
        ui_osk_clear_overlay
        UI_OSK_MODE="${prev_mode}"
        UI_NEED_REPAINT=1
        return 0
        ;;
      cancel)
        ui_osk_clear_overlay
        UI_OSK_MODE="${prev_mode}"
        UI_NEED_REPAINT=1
        return 1
        ;;
    esac
  done
}

# Filter overlay: OK=apply, DISCARD=clear+apply, Esc=close without change.
ui_filter_dialog() {
  local title="$1" initial="$2"
  local key osk_dirty=1 prev_mode="${UI_OSK_MODE}"
  UI_INPUT_RESULT="${initial}"
  UI_OSK_MODE="filter"
  ui_drain_keys
  ui_osk_reset "${initial}"

  while true; do
    if ui_check_resize; then osk_dirty=1; fi
    if (( osk_dirty )); then
      ui_osk_geom
      printf '\e[%d;%dH%s%-*.*s%s' $((UI_OSK_OY - 1)) "${UI_OSK_OX}" \
        "${UI_MUTED}" $((UI_OSK_OW)) $((UI_OSK_OW)) \
        "$(ui_fit "${UI_OSK_OW}" " Enter=Search  Down=Keyboard  OK=Apply  DISCARD=Clear  Esc=Cancel")" "${UI_RST}"
      ui_osk_paint "${title}"
      osk_dirty=0
    fi
    key="$(ui_read_key)" || true
    [[ "${key}" == "TIMEOUT" ]] && continue
    [[ "${key}" == "RESIZE" ]] && { osk_dirty=1; continue; }
    ui_osk_feed "${key}"
    case "${UI_OSK_EVENT}" in
      redraw) ui_osk_paint_cursor ;;
      changed) ui_osk_paint_text ;;
      layout) osk_dirty=1 ;;
      ok)
        UI_INPUT_RESULT="${UI_OSK_TEXT}"
        ui_osk_clear_overlay
        UI_OSK_MODE="${prev_mode}"
        UI_NEED_REPAINT=1
        ui_drain_keys
        return 0
        ;;
      discard)
        UI_INPUT_RESULT=""
        ui_osk_clear_overlay
        UI_OSK_MODE="${prev_mode}"
        UI_NEED_REPAINT=1
        ui_drain_keys
        return 0
        ;;
      cancel)
        ui_osk_clear_overlay
        UI_OSK_MODE="${prev_mode}"
        UI_NEED_REPAINT=1
        ui_drain_keys
        return 1
        ;;
    esac
  done
}

ui_msgbox() {
  local title="$1" msg="$2" mw mh mx my key tw lines para rest
  # Soft overlay ? keep parent under the box (parent soft-repaints via UI_NEED_REPAINT)
  ui_drain_keys
  ui_detect_size
  mw=$((UI_COLS - 10)); (( mw > 60 )) && mw=60
  (( mw < 40 )) && mw=$((UI_COLS - 4))
  tw=$((mw - 6))
  # height fits wrapped message incl. newlines (max 6 lines) + chrome
  lines=0
  msg="${msg//$'\r'/}"
  while IFS= read -r para || [[ -n "${para}" ]]; do
    rest="${para}"
    (( lines++ ))
    while (( ${#rest} > tw )); do
      rest="${rest:tw}"
      (( lines++ ))
    done
  done <<< "${msg}"
  (( lines < 1 )) && lines=1
  (( lines > 6 )) && lines=6
  mh=$(( lines + 6 ))
  mx=$(( (UI_COLS - mw) / 2 + 1 ))
  my=$(( (UI_ROWS - mh) / 2 ))
  (( my < 3 )) && my=3
  ui_box "${mx}" "${my}" "${mw}" "${mh}" "${title}"
  ui_print_wrapped $((mx+3)) $((my+2)) "${tw}" "${lines}" "${UI_PANEL}" "${msg}"
  printf '\e[%d;%dH%s%-*.*s%s' $((my+mh-2)) $((mx+3)) \
    "${UI_VALUE}" "${tw}" "${tw}" "[ Press Enter ]" "${UI_RST}"
  while true; do
    key="$(ui_read_key)" || true
    case "${key}" in
      TIMEOUT) continue ;;
      RESIZE)
        ui_detect_size
        continue
        ;;
      ENTER|ESC|q|Q) break ;;
    esac
  done
  ui_drain_keys
  UI_NEED_REPAINT=1
}

ui_run() {
  local title="$1"; shift
  local rc=0
  ui_cleanup_soft
  printf '\e[0m\e[2J\e[H'
  printf '%s\n\n' "=== ${title} ==="
  "$@" && rc=0 || rc=$?
  echo
  if (( rc == 0 )); then read -r -p "Done. Press Enter..." _
  else read -r -p "Finished with errors (${rc}). Press Enter..." _; fi
  ui_resume
  return "${rc}"
}

ui_pause() {
  if [[ "${UI_ACTIVE}" -eq 1 ]]; then ui_msgbox "Notice" "Press Enter to continue"
  else read -r -p "Press Enter..." _; fi
}
