#!/usr/bin/env bash
# Stage 3: search catalog + queue
set -uo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_queue() {
  ensure_dirs
  if [[ ! -f "${QUEUE_FILE}" ]]; then
    printf 'hash\tindex\tsize\tpath\ttarget\n' > "${QUEUE_FILE}"
  fi
}

search_catalog() {
  local q="${1:-}"
  local cat="${CATALOG_DIR}/all.tsv"
  [[ -f "${cat}" ]] || die "catalog missing; run build catalog first"
  if [[ -z "${q}" ]]; then
    read -r -p "Search (substring, empty=all): " q || true
  fi
  if [[ -z "${q}" ]]; then
    tail -n +2 "${cat}" | less -S
  else
    awk -F'\t' -v q="${q}" 'NR==1{next} tolower($4) ~ tolower(q) { printf "%4d  [%s] idx=%s  %s  %s\n", NR-1, $1, $2, $3, $4 }' "${cat}" | less -S
  fi
}

select_into_queue() {
  ensure_queue
  local cat="${CATALOG_DIR}/all.tsv"
  [[ -f "${cat}" ]] || die "catalog missing; run build catalog first"

  local q
  read -r -p "Filter (substring): " q || true
  local tmp
  tmp="$(mktemp)"
  if [[ -n "${q}" ]]; then
    awk -F'\t' -v q="${q}" 'NR>1 && tolower($4) ~ tolower(q) {print}' "${cat}" > "${tmp}"
  else
    tail -n +2 "${cat}" > "${tmp}"
  fi

  local n
  n="$(wc -l < "${tmp}")"
  if [[ "${n}" -eq 0 ]]; then
    warn "no matches"
    rm -f "${tmp}"
    return 0
  fi

  log "${n} match(es). Showing first 50:"
  nl -ba "${tmp}" | head -n 50
  [[ "${n}" -gt 50 ]] && log "... (${n} total; refine filter if needed)"

  local picks
  read -r -p "Add line numbers (e.g. 1 3 5-8), or 'all': " picks
  [[ -n "${picks}" ]] || { rm -f "${tmp}"; return 0; }

  local -a idxs=()
  if [[ "${picks}" == "all" ]]; then
    idxs=($(seq 1 "${n}"))
  else
    for tok in ${picks}; do
      if [[ "${tok}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        idxs+=($(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"))
      elif [[ "${tok}" =~ ^[0-9]+$ ]]; then
        idxs+=("${tok}")
      fi
    done
  fi

  local line i added=0 h idx
  for i in "${idxs[@]}"; do
    line="$(sed -n "${i}p" "${tmp}" || true)"
    [[ -n "${line}" ]] || continue
    h="$(printf '%s\n' "${line}" | cut -f1)"
    idx="$(printf '%s\n' "${line}" | cut -f2)"
    if awk -F'\t' -v h="${h}" -v idx="${idx}" 'NR>1 && $1==h && $2==idx {found=1} END{exit !found}' "${QUEUE_FILE}"; then
      continue
    fi
    printf '%s\t\n' "${line}" >> "${QUEUE_FILE}"
    added=$((added + 1))
  done
  rm -f "${tmp}"
  log "added ${added} item(s) ? ${QUEUE_FILE}"
}

show_queue() {
  ensure_queue
  if [[ "$(wc -l < "${QUEUE_FILE}")" -le 1 ]]; then
    log "queue empty"
    return 0
  fi
  column -t -s $'\t' "${QUEUE_FILE}" 2>/dev/null | less -S || less -S "${QUEUE_FILE}"
}

clear_queue() {
  ensure_queue
  printf 'hash\tindex\tsize\tpath\ttarget\n' > "${QUEUE_FILE}"
  log "queue cleared"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-search}"
  case "${cmd}" in
    search) shift; search_catalog "${1:-}" ;;
    select) select_into_queue ;;
    queue) show_queue ;;
    clear) clear_queue ;;
    *) die "usage: browse.sh {search|select|queue|clear}" ;;
  esac
fi
