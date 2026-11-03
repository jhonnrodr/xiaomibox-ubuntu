#!/usr/bin/env bash
# Read-only: collects hardware facts from the box over ADB. Changes nothing on the device.
# Usage: ./scripts/collect-device-info.sh <box-ip>
set -euo pipefail

readonly BOX_IP="${1:?Usage: $0 <box-ip>}"
readonly ADB_PORT="${ADB_PORT:-5555}"
readonly OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/docs/device-info"
readonly OUT_FILE="${OUT_DIR}/$(date +%Y%m%d-%H%M%S).txt"

command -v adb >/dev/null || { echo "adb missing: brew install --cask android-platform-tools" >&2; exit 1; }

adb connect "${BOX_IP}:${ADB_PORT}"
adb -s "${BOX_IP}:${ADB_PORT}" wait-for-device

mkdir -p "${OUT_DIR}"

section() { printf '\n===== %s =====\n' "$1"; }
run() { adb -s "${BOX_IP}:${ADB_PORT}" shell "$1" 2>&1 || echo "(failed: $1)"; }

{
  section "props"
  for p in ro.product.model ro.product.device ro.product.board ro.board.platform \
           ro.build.fingerprint ro.build.version.release ro.product.cpu.abilist \
           ro.boot.flash.locked ro.boot.verifiedbootstate ro.boot.vbmeta.device_state \
           ro.hardware ro.soc.model; do
    printf '%s=%s\n' "$p" "$(run "getprop $p" | tr -d '\r')"
  done
  section "device-tree model";  run "cat /proc/device-tree/model; echo"
  section "cpuinfo";            run "cat /proc/cpuinfo"
  section "meminfo";            run "head -3 /proc/meminfo"
  section "storage";            run "cat /proc/partitions"
  section "wifi/bt (sdio ids)"; run 'for d in /sys/bus/sdio/devices/*; do echo "$d vendor=$(cat $d/vendor 2>/dev/null) device=$(cat $d/device 2>/dev/null)"; done'
  section "usb devices";        run 'for d in /sys/bus/usb/devices/*; do [ -f $d/idVendor ] && echo "$d $(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/product 2>/dev/null)"; done'
  section "kernel modules";     run "cat /proc/modules"
  section "kernel";             run "uname -a"
  section "net interfaces";     run "ls /sys/class/net"
} > "${OUT_FILE}"

echo "Saved: ${OUT_FILE}"
