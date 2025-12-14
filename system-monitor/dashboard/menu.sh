#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$ROOT_DIR/data/latest.json"
COLLECT="$ROOT_DIR/scripts/collect.sh"
ALERTS="$ROOT_DIR/scripts/alerts.sh"
LOG="$ROOT_DIR/logs/alerts.log"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need dialog
need jq

# Use dialog max size
max="$(dialog --print-maxsize 2>&1 | awk -F'[:, ]+' '/MaxSize/ {print $2" "$3}')"
ROWS="$(awk '{print $1}' <<<"$max")"
COLS="$(awk '{print $2}' <<<"$max")"

# Comfortable sizes inside max
BOX_H=$(( ROWS - 6 ))
BOX_W=$(( COLS - 10 ))
MENU_H=$(( ROWS - 14 ))
(( MENU_H < 10 )) && MENU_H=10

get() { jq -r "$1" "$DATA"; }
msg() { dialog --title "$1" --msgbox "$2" "$BOX_H" "$BOX_W"; }

ensure_data() {
  [[ -f "$DATA" ]] || "$COLLECT" >/dev/null
}
ensure_data

while true; do
  choice="$(
    dialog --clear --title "System Monitor" \
      --menu "Select:" "$BOX_H" "$BOX_W" "$MENU_H" \
      1 "Refresh metrics (collect.sh)" \
      2 "CPU status" \
      3 "Memory status" \
      4 "Disk status" \
      5 "Network status" \
      6 "Show alerts log" \
      7 "Run alerts now" \
      0 "Exit" \
      --stdout
  )" || { clear; exit 0; }

  case "$choice" in
    1)
      "$COLLECT" >/dev/null
      msg "Refreshed" "Updated:\n$DATA"
      ;;
    2)
      ts="$(get '.timestamp')"
      cpu="$(get '.cpu.usage_pct')"
      cores="$(get '.cpu.cores')"
      temp="$(get '.cpu.temp_c // "null"')"
      l1="$(get '.load."1m"')"
      l5="$(get '.load."5m"')"
      l15="$(get '.load."15m"')"
      msg "CPU" "Time: $ts\n\nCPU usage: ${cpu}%\nCores: $cores\nTemp: ${temp}°C\n\nLoad avg:\n  1m:  $l1\n  5m:  $l5\n  15m: $l15"
      ;;
    3)
      ts="$(get '.timestamp')"
      total="$(get '.memory.total_kb')"
      used="$(get '.memory.used_kb')"
      avail="$(get '.memory.avail_kb')"
      pct="$(get '.memory.used_pct')"
      msg "Memory" "Time: $ts\n\nTotal: ${total} KB\nUsed:  ${used} KB\nAvail: ${avail} KB\nUsed%: ${pct}%"
      ;;
    4)
      ts="$(get '.timestamp')"
      fs="$(get '.disk_root.filesystem')"
      type="$(get '.disk_root.fstype')"
      size="$(get '.disk_root.size_kb')"
      used="$(get '.disk_root.used_kb')"
      avail="$(get '.disk_root.avail_kb')"
      pct="$(get '.disk_root.use_pct')"
      mnt="$(get '.disk_root.mount')"
      smart="$(jq -r '.disks_smart[]? | "  \(.device): \(.health)"' "$DATA" | sed '/^$/d' || true)"
      [[ -z "${smart:-}" ]] && smart="  (no SMART info)"
      msg "Disk" "Time: $ts\n\nMount: $mnt\nFS: $fs ($type)\nSize:  ${size} KB\nUsed:  ${used} KB\nAvail: ${avail} KB\nUse%:  ${pct}%\n\nSMART:\n$smart"
      ;;
    5)
      ts="$(get '.timestamp')"
      net="$(jq -r '.network[]? | "\(.iface): RX=\(.rx_bytes)B (\(.rx_packets)p)  TX=\(.tx_bytes)B (\(.tx_packets)p)"' "$DATA")"
      [[ -z "${net:-}" ]] && net="(no interfaces)"
      msg "Network" "Time: $ts\n\n$net"
      ;;
    6)
      if [[ -f "$LOG" ]]; then
        tail -n 200 "$LOG" | dialog --title "alerts.log (last 200 lines)" --textbox /dev/stdin "$BOX_H" "$BOX_W"
      else
        msg "Alerts" "No alerts yet."
      fi
      ;;
    7)
      set +e
      out="$("$ALERTS" 2>&1)"
      code=$?
      set -e
      msg "Alerts (exit=$code)" "$out"
      ;;
    0)
      clear
      exit 0
      ;;
  esac
done
