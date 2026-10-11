# Core control on the phone: the evidence behind ADR 009, amendment 2026-10-10 (wake-then-pin).
# Reads the core_ctl state of each cluster, then shows that pinning to the parked X2 (cpu 7) is
# refused at idle, that a busy loop wakes it, that pinning then succeeds (for an idle and for a busy
# process), and that the X2 is parked again after the load stops. Runs a few seconds; kills what it starts.
#
# Run from the repo root, phone on USB (Git Bash: prefix MSYS_NO_PATHCONV=1 so /data/... is not rewritten):
#   adb push tools/model_check/core_control_check.sh /data/local/tmp/ && adb shell sh /data/local/tmp/core_control_check.sh
#   adb shell rm /data/local/tmp/core_control_check.sh
# Save the output as docs/measurements/<date>_core_control_check.txt.

date
for c in 0 4 7; do
  d=/sys/devices/system/cpu/cpu$c/core_ctl
  echo "cluster of cpu$c: min_cpus=$(cat $d/min_cpus) max_cpus=$(cat $d/max_cpus) active_cpus=$(cat $d/active_cpus) offline_delay_ms=$(cat $d/offline_delay_ms)"
done
d=/sys/devices/system/cpu/cpu7/core_ctl
sleep 30 & SP=$!
echo "1) at idle (cpu7 active_cpus=$(cat $d/active_cpus)), pin an idle process to cpu7:"
taskset -p 80 $SP 2>&1
sh -c 'while :; do :; done' & BP=$!
( sleep 6; kill $BP $SP 2>/dev/null ) &
i=0
while [ $i -lt 100 ]; do a=$(cat $d/active_cpus); [ "$a" = "1" ] && break; i=$((i+1)); sleep 0.01; done
echo "2) busy loop running: cpu7 active_cpus=$(cat $d/active_cpus) after $i polls (each: read + sleep 10 ms)"
echo "3) pin the idle process to cpu7 now:"; taskset -p 80 $SP 2>&1
echo "4) pin the busy process itself to cpu7:"; taskset -p 80 $BP 2>&1
sleep 0.3
echo "   the busy process now runs on cpu $(cut -d' ' -f39 /proc/$BP/stat)"
kill $BP 2>/dev/null; sleep 0.5
echo "5) 0.5 s after the load stopped: cpu7 active_cpus=$(cat $d/active_cpus)"
kill $SP 2>/dev/null
