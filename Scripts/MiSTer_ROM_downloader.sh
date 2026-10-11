#!/bin/bash
# MiSTer_ROM_downloader.sh - MiSTer Scripts launcher
#
# Install: copy this file + Scripts/.config/mister_rom_downloader/ onto the SD card:
#   /media/fat/Scripts/MiSTer_ROM_downloader.sh
#   /media/fat/Scripts/.config/mister_rom_downloader/
#
# Name case matches other MiSTer_* scripts (e.g. MiSTer_SAM_on.sh).

set -euo pipefail

LOCATION_STR="${LOCATION_STR:-/media/fat}"
APP_DIR="${LOCATION_STR}/Scripts/.config/mister_rom_downloader"
APP_MAIN="${APP_DIR}/mister_rom_downloader.sh"

if [[ ! -f "${APP_MAIN}" ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${HERE}/.config/mister_rom_downloader/mister_rom_downloader.sh" ]]; then
    APP_DIR="${HERE}/.config/mister_rom_downloader"
    APP_MAIN="${APP_DIR}/mister_rom_downloader.sh"
  fi
fi

if [[ ! -f "${APP_MAIN}" ]]; then
  echo "MiSTer_ROM_downloader not found."
  echo "Expected: ${LOCATION_STR}/Scripts/.config/mister_rom_downloader/"
  exit 1
fi

chmod +x "${APP_MAIN}" 2>/dev/null || true
chmod +x "${APP_DIR}/bin/aria2c" 2>/dev/null || true
chmod +x "${APP_DIR}/lib/"*.sh 2>/dev/null || true
exec bash "${APP_MAIN}" "$@"
