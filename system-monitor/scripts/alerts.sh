#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$ROOT_DIR/data/latest.json"
LOG_DIR="$ROOT_DIR/logs"
LOG="$LOG_DIR/alerts.log"
mkdir -p "$LOG_DIR"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found. Install: sudo apt install -y jq" >&2
  exit 1
fi

if [[ ! -f "$DATA" ]]; then
  echo "ERROR: $DATA not found. Run collect.sh first." >&2
  exit 1
fi

# ---- thresholds (edit anytime) ----
CPU_THRESH=80          # %
MEM_THRESH=80          # %
DISK_THRESH=90         # %
TEMP_THRESH=80         # °C (ignored if null)

ts="$(jq -r '.timestamp' "$DATA")"

cpu="$(jq -r '.cpu.usage_pct' "$DATA")"
mem="$(jq -r '.memory.used_pct' "$DATA")"
disk="$(jq -r '.disk_root.use_pct' "$DATA")"
temp="$(jq -r '.cpu.temp_c // "null"' "$DATA")"

alerts=0

log_alert() {
  local level="$1" msg="$2"
  printf "%s [%s] %s\n" "$ts" "$level" "$msg" | tee -a "$LOG"
}

# CPU
if (( cpu >= CPU_THRESH )); then
  log_alert "WARN" "CPU usage high: ${cpu}% (>= ${CPU_THRESH}%)"
  alerts=$((alerts+1))
fi

# Memory (mem is float, compare via awk)
if awk -v m="$mem" -v t="$MEM_THRESH" 'BEGIN{exit !(m>=t)}'; then
  log_alert "WARN" "Memory usage high: ${mem}% (>= ${MEM_THRESH}%)"
  alerts=$((alerts+1))
fi

# Disk
if (( disk >= DISK_THRESH )); then
  log_alert "WARN" "Disk usage high on /: ${disk}% (>= ${DISK_THRESH}%)"
  alerts=$((alerts+1))
fi

# Temperature (only if not null)
if [[ "$temp" != "null" ]]; then
  if awk -v x="$temp" -v t="$TEMP_THRESH" 'BEGIN{exit !(x>=t)}'; then
    log_alert "WARN" "CPU temperature high: ${temp}°C (>= ${TEMP_THRESH}°C)"
    alerts=$((alerts+1))
  fi
fi

# SMART (informational; NOT_SUPPORTED is OK in VM)
smart_summary="$(jq -r '.disks_smart[]? | "\(.device)=\(.health)"' "$DATA" 2>/dev/null || true)"
if [[ -n "${smart_summary:-}" ]]; then
  while read -r line; do
    [[ -z "$line" ]] && continue
    dev="${line%%=*}"
    health="${line#*=}"
    if [[ "$health" == "FAILED" ]]; then
      log_alert "CRIT" "SMART health FAILED on ${dev}"
      alerts=$((alerts+1))
    fi
  done <<<"$smart_summary"
fi

if (( alerts == 0 )); then
  echo "$ts [OK] No alerts."
fi

exit $alerts
