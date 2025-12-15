#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$ROOT_DIR/data/latest.json"
OUT_MD="$ROOT_DIR/report/report.md"
OUT_HTML="$ROOT_DIR/report/report.html"
ALERT_LOG="$ROOT_DIR/logs/alerts.log"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required. Install: sudo apt install -y jq" >&2
  exit 1
fi

if [[ ! -f "$DATA" ]]; then
  echo "ERROR: $DATA not found. Run scripts/collect.sh first." >&2
  exit 1
fi

ts="$(jq -r '.timestamp' "$DATA")"

cpu_pct="$(jq -r '.cpu.usage_pct' "$DATA")"
cores="$(jq -r '.cpu.cores' "$DATA")"
temp="$(jq -r '.cpu.temp_c // "null"' "$DATA")"
l1="$(jq -r '.load."1m"' "$DATA")"
l5="$(jq -r '.load."5m"' "$DATA")"
l15="$(jq -r '.load."15m"' "$DATA")"

mem_total="$(jq -r '.memory.total_kb' "$DATA")"
mem_used="$(jq -r '.memory.used_kb' "$DATA")"
mem_avail="$(jq -r '.memory.avail_kb' "$DATA")"
mem_pct="$(jq -r '.memory.used_pct' "$DATA")"

disk_fs="$(jq -r '.disk_root.filesystem' "$DATA")"
disk_type="$(jq -r '.disk_root.fstype' "$DATA")"
disk_size="$(jq -r '.disk_root.size_kb' "$DATA")"
disk_used="$(jq -r '.disk_root.used_kb' "$DATA")"
disk_avail="$(jq -r '.disk_root.avail_kb' "$DATA")"
disk_pct="$(jq -r '.disk_root.use_pct' "$DATA")"
disk_mnt="$(jq -r '.disk_root.mount' "$DATA")"

smart="$(jq -r '.disks_smart[]? | "- \(.device): \(.health)"' "$DATA")"
[[ -z "${smart:-}" ]] && smart="- (no SMART info)"

net="$(jq -r '.network[]? | "- \(.iface): RX=\(.rx_bytes)B (\(.rx_packets)p), TX=\(.tx_bytes)B (\(.tx_packets)p)"' "$DATA")"
[[ -z "${net:-}" ]] && net="- (no interfaces)"

alerts_tail="(no alerts yet)"
if [[ -f "$ALERT_LOG" ]]; then
  alerts_tail="$(tail -n 20 "$ALERT_LOG")"
fi

cat > "$OUT_MD" <<EOF
# System Monitor Report

**Generated:** $ts

## CPU
- Usage: **${cpu_pct}%**
- Cores: **${cores}**
- Temperature: **${temp}°C**
- Load Average: **$l1 (1m), $l5 (5m), $l15 (15m)**

## Memory
- Total: ${mem_total} KB
- Used: ${mem_used} KB
- Available: ${mem_avail} KB
- Usage: **${mem_pct}%**

## Disk (Root)
- Mount: $disk_mnt
- Filesystem: $disk_fs ($disk_type)
- Size: ${disk_size} KB
- Used: ${disk_used} KB
- Available: ${disk_avail} KB
- Usage: **${disk_pct}%**

## Disk SMART
$smart

## Network Interfaces
$net

## Recent Alerts (last 20 lines)
\`\`\`
$alerts_tail
\`\`\`
EOF

# Simple HTML conversion (no external deps)
{
  echo "<html><head><meta charset='utf-8'><title>System Monitor Report</title></head><body>"
  echo "<pre>"
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$OUT_MD"
  echo "</pre>"
  echo "</body></html>"
} > "$OUT_HTML"

echo "Wrote:"
echo " - $OUT_MD"
echo " - $OUT_HTML"
