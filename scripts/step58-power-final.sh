#!/bin/bash
# STEP 58 — Final battery power policy from the ladder (step14c) + profile A/B (step14d):
#   battery = power-saver profile + CPU EPP balance_power + package cap 6/6 W (PL1 = PL2, no burst budget), iGPU 1500 MHz as before.
#   AC unchanged (balanced, 30/37 W, EPP left to power-profiles-daemon).
#   sudo bash scripts/step58-power-final.sh          # or CAP=8/8 sudo -E bash …  (8/8: all-core zstd 4.7 s instead of 6.2 s, +~2 % SoC energy)
# Rollback: sudo bash scripts/step58-rollback.sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo "Run with: sudo bash $0" >&2; exit 1; }
CAP=${CAP:-6/6}; EPP=${EPP:-balance_power}
B=$(dirname "$0")/backup/step58-$(date +%Y%m%d-%H%M); mkdir -p "$B"
cp -a /etc/power-switch.conf /usr/local/sbin/power-switch.sh "$B/"; echo "backup: $B"
# 1. numbers
sed -i -E "s/^BAT_PL1=[0-9]+/BAT_PL1=${CAP%/*}/; s/^BAT_PL2=[0-9]+/BAT_PL2=${CAP#*/}/" /etc/power-switch.conf
grep -q '^BAT_EPP=' /etc/power-switch.conf || cat >> /etc/power-switch.conf <<CONF
# CPU energy-performance preference applied AFTER the profile (empty = leave what power-profiles-daemon set).
# Measured 19 Sep 2026 at 6/6 W: balance_power = single-thread tasks 30-44 % faster than 'power' for ~2 % more SoC energy.
BAT_EPP=$EPP
AC_EPP=
CONF
sed -i -E "s/^BAT_EPP=.*/BAT_EPP=$EPP/" /etc/power-switch.conf
# 2. script: apply the EPP after the profile (ppd only writes EPP when the profile actually changes)
if ! grep -q 'BAT_EPP' /usr/local/sbin/power-switch.sh; then
python3 - <<'PY'
p='/usr/local/sbin/power-switch.sh'; s=open(p).read()
s=s.replace('  profile=performance; pl1=$AC_PL1; pl2=$AC_PL2; gpu=$AC_GPU_MAX',
            '  profile=performance; pl1=$AC_PL1; pl2=$AC_PL2; gpu=$AC_GPU_MAX; epp=')
s=s.replace('  profile=$AC_PROFILE; pl1=$AC_PL1; pl2=$AC_PL2; gpu=$AC_GPU_MAX',
            '  profile=$AC_PROFILE; pl1=$AC_PL1; pl2=$AC_PL2; gpu=$AC_GPU_MAX; epp=${AC_EPP:-}')
s=s.replace('  profile=$BAT_PROFILE; pl1=$BAT_PL1; pl2=$BAT_PL2; gpu=$BAT_GPU_MAX',
            '  profile=$BAT_PROFILE; pl1=$BAT_PL1; pl2=$BAT_PL2; gpu=$BAT_GPU_MAX; epp=${BAT_EPP:-}')
s=s.replace('sleep 1   # the HP firmware rewrites its own limits when the thermal mode changes; apply ours afterwards\n',
            'sleep 1   # the HP firmware rewrites its own limits when the thermal mode changes; apply ours afterwards\n'
            '# 1b. CPU energy-performance preference override (ppd only writes EPP on a profile CHANGE, so set it explicitly)\n'
            'if [ -n "$epp" ]; then for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo "$epp" > "$f" 2>/dev/null || true; done; fi\n')
s=s.replace('PL1=${pl1}W PL2=${pl2}W gpu_max=${gpu}MHz"', 'PL1=${pl1}W PL2=${pl2}W gpu_max=${gpu}MHz epp=${epp:-ppd}"')
open(p,'w').write(s)
PY
fi
bash -n /usr/local/sbin/power-switch.sh
echo "--- /etc/power-switch.conf:"; grep -v '^#' /etc/power-switch.conf
# 3. apply now and read back
/usr/local/sbin/power-switch.sh
sleep 1; journalctl -t power-switch -n 1 --no-pager -o cat
echo "readback: adapter=$(cat /sys/class/power_supply/ADP1/online) profile=$(powerprofilesctl get) epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference) msr $(( $(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw)/1000000 ))/$(( $(cat /sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw)/1000000 )) W  mmio $(( $(cat /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw)/1000000 ))/$(( $(cat /sys/class/powercap/intel-rapl-mmio:0/constraint_1_power_limit_uw)/1000000 )) W  gpu_max $(cat /sys/class/drm/card*/device/tile0/gt0/freq0/max_freq | head -1) MHz"
echo "note: picking a profile by hand in quick settings lets ppd rewrite the EPP until the next unplug/plug, boot or resume."
echo "=== step58 done ==="
