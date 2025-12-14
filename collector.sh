#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$ROOT_DIR/data"
OUT="$DATA_DIR/latest.json"
mkdir -p "$DATA_DIR"

have() { command -v "$1" >/dev/null 2>&1; }
iso_ts() { date -Iseconds; }

# ---------------- CPU usage (1s sample from /proc/stat) ----------------
read_cpu() { awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat; }

cpu_usage_pct() {
  local a b
  a="$(read_cpu)"
  sleep 1
  b="$(read_cpu)"

  read -r u1 n1 s1 i1 io1 irq1 sirq1 st1 <<<"$a"
  read -r u2 n2 s2 i2 io2 irq2 sirq2 st2 <<<"$b"

  local idle1=$((i1 + io1))
  local idle2=$((i2 + io2))
  local non1=$((u1 + n1 + s1 + irq1 + sirq1 + st1))
  local non2=$((u2 + n2 + s2 + irq2 + sirq2 + st2))

  local total1=$((idle1 + non1))
  local total2=$((idle2 + non2))

  local totald=$((total2 - total1))
  local idled=$((idle2 - idle1))

  if (( totald <= 0 )); then
    echo 0
  else
    echo $(( (100 * (totald - idled)) / totald ))
  fi
}

CPU_PCT="$(cpu_usage_pct)"
CORES="$(nproc 2>/dev/null || echo 0)"
LOAD1="$(awk '{print $1}' /proc/loadavg)"
LOAD5="$(awk '{print $2}' /proc/loadavg)"
LOAD15="$(awk '{print $3}' /proc/loadavg)"
UPTIME_S="$(awk '{print int($1)}' /proc/uptime)"

# ---------------- CPU temperature (best-effort; may be null in VM) ----------------
CPU_TEMP="null"

if ls /sys/class/thermal/thermal_zone*/temp >/dev/null 2>&1; then
  z="$(
    for f in /sys/class/thermal/thermal_zone*/temp; do
      [[ -e "$f" ]] && cat "$f" && break
    done
  )"
  if [[ -n "${z:-}" ]]; then
    CPU_TEMP="$(awk -v v="$z" 'BEGIN{printf "%.1f", v/1000}')"
  fi
elif have sensors; then
  t="$(sensors 2>/dev/null | awk '
    /°C/ {
      for (i=1;i<=NF;i++) if ($i ~ /°C/) {
        gsub(/[+°C]/,"",$i); print $i; exit
      }
    }')"
  [[ -n "${t:-}" ]] && CPU_TEMP="$t"
fi

# ---------------- Memory ----------------
MEM_TOTAL_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
MEM_AVAIL_KB="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))
MEM_USED_PCT="$(awk -v u="$MEM_USED_KB" -v t="$MEM_TOTAL_KB" 'BEGIN{printf "%.1f", (u*100)/t}')"

# ---------------- Disk usage (root mount) ----------------
DF_LINE="$(df -PT / | awk 'NR==2{print}')"
ROOT_FS="$(awk '{print $1}' <<<"$DF_LINE")"
ROOT_TYPE="$(awk '{print $2}' <<<"$DF_LINE")"
ROOT_SIZE_KB="$(awk '{print $3}' <<<"$DF_LINE")"
ROOT_USED_KB="$(awk '{print $4}' <<<"$DF_LINE")"
ROOT_AVAIL_KB="$(awk '{print $5}' <<<"$DF_LINE")"
ROOT_USE_PCT="$(awk '{gsub(/%/,"",$6); print $6}' <<<"$DF_LINE")"
ROOT_MNT="$(awk '{print $7}' <<<"$DF_LINE")"

# ---------------- Ensure jq exists ----------------
if ! have jq; then
  echo "ERROR: jq is required. Install it with: sudo apt update && sudo apt install -y jq" >&2
  exit 1
fi

# ---------------- SMART status (best-effort; often NOT_SUPPORTED in VMs) ----------------
SMART='[]'
if have lsblk; then
  while read -r dev; do
    [[ -z "$dev" ]] && continue
    health="unavailable"

    if have smartctl; then
      out="$(smartctl -H "$dev" 2>/dev/null || true)"
      if [[ -z "$out" ]] && have sudo; then
        out="$(sudo -n smartctl -H "$dev" 2>/dev/null || true)"
      fi

      # Correct parsing:
      # - VirtualBox disks often say SMART support is unavailable or "command failed"
      # - We only mark FAILED if smartctl explicitly reports overall-health FAILED
      if grep -qi "SMART support is: Unavailable" <<<"$out"; then
        health="NOT_SUPPORTED"
      elif grep -qi "SMART overall-health self-assessment test result: PASSED" <<<"$out"; then
        health="PASSED"
      elif grep -qi "SMART overall-health self-assessment test result: FAILED" <<<"$out"; then
        health="FAILED"
      else
        health="UNKNOWN"
      fi
    fi

    SMART="$(jq -c --arg d "$dev" --arg h "$health" '. + [{"device":$d,"health":$h}]' <<<"$SMART")"
  done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
fi

# ---------------- Network stats (/proc/net/dev) ----------------
NET='[]'
while read -r line; do
  iface="$(awk '{gsub(/:/,"",$1); print $1}' <<<"$line")"
  rx_bytes="$(awk '{print $2}' <<<"$line")"
  rx_pkts="$(awk '{print $3}' <<<"$line")"
  tx_bytes="$(awk '{print $10}' <<<"$line")"
  tx_pkts="$(awk '{print $11}' <<<"$line")"

  NET="$(jq -c --arg i "$iface" \
        --argjson rxb "$rx_bytes" --argjson rxp "$rx_pkts" \
        --argjson txb "$tx_bytes" --argjson txp "$tx_pkts" \
        '. + [{"iface":$i,"rx_bytes":$rxb,"rx_packets":$rxp,"tx_bytes":$txb,"tx_packets":$txp}]' <<<"$NET")"
done < <(awk 'NR>2 {print}' /proc/net/dev)

# ---------------- GPU (optional) ----------------
GPU='[]'
if have nvidia-smi; then
  while IFS=',' read -r name util memutil temp; do
    name="$(echo "$name" | xargs)"
    util="$(echo "$util" | xargs)"
    memutil="$(echo "$memutil" | xargs)"
    temp="$(echo "$temp" | xargs)"

    GPU="$(jq -c --arg n "$name" \
          --argjson u "$util" --argjson mu "$memutil" --argjson t "$temp" \
          '. + [{"name":$n,"util_gpu_pct":$u,"util_mem_pct":$mu,"temp_c":$t}]' <<<"$GPU")"
  done < <(nvidia-smi --query-gpu=name,utilization.gpu,utilization.memory,temperature.gpu \
           --format=csv,noheader,nounits 2>/dev/null || true)
fi

# ---------------- Write JSON ----------------
jq -n \
  --arg timestamp "$(iso_ts)" \
  --argjson cpu_usage_pct "$CPU_PCT" \
  --argjson cores "$CORES" \
  --argjson load1 "$LOAD1" \
  --argjson load5 "$LOAD5" \
  --argjson load15 "$LOAD15" \
  --argjson uptime_seconds "$UPTIME_S" \
  --arg cpu_temp "$CPU_TEMP" \
  --argjson mem_total_kb "$MEM_TOTAL_KB" \
  --argjson mem_used_kb "$MEM_USED_KB" \
  --argjson mem_avail_kb "$MEM_AVAIL_KB" \
  --arg mem_used_pct "$MEM_USED_PCT" \
  --arg root_fs "$ROOT_FS" \
  --arg root_type "$ROOT_TYPE" \
  --argjson root_size_kb "$ROOT_SIZE_KB" \
  --argjson root_used_kb "$ROOT_USED_KB" \
  --argjson root_avail_kb "$ROOT_AVAIL_KB" \
  --argjson root_use_pct "$ROOT_USE_PCT" \
  --arg root_mount "$ROOT_MNT" \
  --argjson disks_smart "$SMART" \
  --argjson network "$NET" \
  --argjson gpu "$GPU" \
  '
  {
    timestamp: $timestamp,
    cpu: {
      usage_pct: $cpu_usage_pct,
      cores: $cores,
      temp_c: (if $cpu_temp == "null" then null else ($cpu_temp|tonumber) end)
    },
    load: { "1m": $load1, "5m": $load5, "15m": $load15 },
    uptime_seconds: $uptime_seconds,
    memory: {
      total_kb: $mem_total_kb,
      used_kb: $mem_used_kb,
      avail_kb: $mem_avail_kb,
      used_pct: ($mem_used_pct|tonumber)
    },
    disk_root: {
      filesystem: $root_fs,
      fstype: $root_type,
      size_kb: $root_size_kb,
      used_kb: $root_used_kb,
      avail_kb: $root_avail_kb,
      use_pct: $root_use_pct,
      mount: $root_mount
    },
    disks_smart: $disks_smart,
    network: $network,
    gpu: $gpu
  }
  ' > "$OUT"

echo "Wrote: $OUT"
