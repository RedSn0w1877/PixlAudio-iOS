#!/usr/bin/env bash
# TEMPORARY (ci-speed measurements): every 10 s, the load average, swap and memory counters and the executables using
# the most CPU or memory (aggregated by name), appended to <out>.
# Usage: (nohup bash ci/top-sampler.sh build/top.log </dev/null >/dev/null 2>&1 &)
out="$1"
mkdir -p "$(dirname "$out")"
echo "hw.ncpu=$(sysctl -n hw.ncpu) hw.memsize=$(( $(sysctl -n hw.memsize) / 1048576 ))M" >> "$out" 2>&1
while true; do
  {
    printf '=== %s load %s | swap %s | ' "$(date -u +%T)" "$(sysctl -n vm.loadavg | tr -d '{}')" \
      "$(sysctl -n vm.swapusage | awk '{print $6}')"
    # vm_stat counts 16 KB pages on Apple silicon; print MB.
    vm_stat | awk '/Pages free|Pages active|Swapouts|Pageouts|Pages occupied by compressor/ {
      v=$NF; gsub("\\.","",v); k=$0; sub(":.*","",k); gsub(" ","_",k); printf "%s=%dM ", k, v*16/1024 }'
    echo
    ps -Ao pcpu=,rss=,comm= | awk '{ n=$3; for (i=4;i<=NF;i++) n=n" "$i; sub(".*/","",n); c[n]+=$1; m[n]+=$2 }
      END { for (k in c) if (c[k] >= 3 || m[k] >= 300*1024) printf "%6.1f%% %6dM  %s\n", c[k], m[k]/1024, k }' \
      | sort -rn | head -12
  } >> "$out" 2>&1
  sleep 10
done
