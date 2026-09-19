#!/bin/bash
# Apply the power mode that matches the AC adapter state (or a mode given as $1: auto|performance).
# Logs to journal: journalctl -t power-switch
set -u
. /etc/power-switch.conf
sleep 2  # settle: the uevent can precede the firmware flag update
online=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null || echo 1)
mode=${1:-auto}
if [ "$mode" = performance ]; then
  profile=performance; pl1=$AC_PL1; pl2=$AC_PL2; gpu=$AC_GPU_MAX; epp=
elif [ "$online" = 1 ]; then
  profile=$AC_PROFILE; pl1=$AC_PL1; pl2=$AC_PL2; gpu=$AC_GPU_MAX; epp=${AC_EPP:-}
else
  profile=$BAT_PROFILE; pl1=$BAT_PL1; pl2=$BAT_PL2; gpu=$BAT_GPU_MAX; epp=${BAT_EPP:-}
fi
# 1. GNOME/ppd profile -> sets CPU energy-performance preference and the HP thermal (fan) mode
powerprofilesctl set "$profile" 2>/dev/null || true
sleep 1   # the HP firmware rewrites its own limits when the thermal mode changes; apply ours afterwards
# 1b. CPU energy-performance preference override (ppd only writes EPP on a profile CHANGE, so set it explicitly)
if [ -n "$epp" ]; then for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo "$epp" > "$f" 2>/dev/null || true; done; fi
# 2. package power limits, both interfaces (the effective limit is the lower of the two)
for d in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0; do
  [ -d "$d" ] || continue
  echo $((pl1*1000000)) > "$d/constraint_0_power_limit_uw" 2>/dev/null || true
  echo $((pl2*1000000)) > "$d/constraint_1_power_limit_uw" 2>/dev/null || true
done
# 3. iGPU ceiling
for f in /sys/class/drm/card*/device/tile0/gt0/freq0/max_freq; do
  [ -e "$f" ] && echo "$gpu" > "$f" 2>/dev/null || true
done
logger -t power-switch "adapter=$([ "$online" = 1 ] && echo AC || echo battery) mode=$mode -> profile=$profile PL1=${pl1}W PL2=${pl2}W gpu_max=${gpu}MHz epp=${epp:-ppd}"
