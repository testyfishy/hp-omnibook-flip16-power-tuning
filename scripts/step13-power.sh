#!/bin/bash
# STEP 13 — Automatic power modes (17 Sep 2026).
#   unplugged  -> GNOME "power-saver" (CPU pref = power, HP thermal mode = quiet) + package power cap 15 W / burst 20 W + iGPU max 1500 MHz
#   plugged in -> GNOME "balanced"    (CPU pref = balance_performance, HP thermal mode = balanced) + 30 W / 37 W + iGPU max 2050 MHz
#   "performance" is never selected automatically; choosing it in the quick-settings menu (or `power-switch.sh performance`) is a manual act
#   and the next plug/unplug event returns to the automatic mode.
# Installs: /etc/power-switch.conf (numbers, edit freely), /usr/local/sbin/power-switch.sh, a udev rule on the AC adapter,
#           power-switch.service (applies the right mode at boot) and a sleep hook (re-applies after resume, firmware resets limits).
# Rollback: sudo bash scripts/step13-rollback.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with: sudo bash $0" >&2; exit 1; }
U=${SUDO_USER:-$(logname)}; H=$(getent passwd "$U" | cut -d: -f6); M=$(cd "$(dirname "$0")" && pwd); LOGS=${LOGS:-$M/logs}; mkdir -p "$LOGS"
exec > >(tee -a "$LOGS/step13.log") 2>&1
echo "=== step13 $(date -Is) ==="
unset LD_PRELOAD

echo "--- 13a config"
cat > /etc/power-switch.conf <<'EOF'
# power-switch: numbers used by /usr/local/sbin/power-switch.sh  (watts / MHz). Edit and unplug/replug to apply.
BAT_PROFILE=power-saver
BAT_PL1=15          # sustained package power on battery (whole SoC: CPU cores + iGPU + NPU). Chip max is 30.
BAT_PL2=20          # short bursts (~1 s) on battery
BAT_GPU_MAX=1500    # iGPU max MHz on battery (hardware max 2050)
AC_PROFILE=balanced
AC_PL1=30
AC_PL2=37
AC_GPU_MAX=2050
EOF

echo "--- 13b switch script"
cat > /usr/local/sbin/power-switch.sh <<'EOF'
#!/bin/bash
# Apply the power mode that matches the AC adapter state (or a mode given as $1: auto|performance).
# Logs to journal: journalctl -t power-switch
set -u
. /etc/power-switch.conf
online=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null || echo 1)
mode=${1:-auto}
if [ "$mode" = performance ]; then
  profile=performance; pl1=$AC_PL1; pl2=$AC_PL2; gpu=$AC_GPU_MAX
elif [ "$online" = 1 ]; then
  profile=$AC_PROFILE; pl1=$AC_PL1; pl2=$AC_PL2; gpu=$AC_GPU_MAX
else
  profile=$BAT_PROFILE; pl1=$BAT_PL1; pl2=$BAT_PL2; gpu=$BAT_GPU_MAX
fi
# 1. GNOME/ppd profile -> sets CPU energy-performance preference and the HP thermal (fan) mode
powerprofilesctl set "$profile" 2>/dev/null || true
sleep 1   # the HP firmware rewrites its own limits when the thermal mode changes; apply ours afterwards
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
logger -t power-switch "adapter=$([ "$online" = 1 ] && echo AC || echo battery) mode=$mode -> profile=$profile PL1=${pl1}W PL2=${pl2}W gpu_max=${gpu}MHz"
EOF
chmod 755 /usr/local/sbin/power-switch.sh

echo "--- 13c udev rule (fires on plug/unplug)"
cat > /etc/udev/rules.d/90-power-switch.rules <<'EOF'
# Claude maintenance 2026-09-17: re-evaluate power mode when the AC adapter changes state
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change", RUN+="/usr/bin/systemctl start --no-block power-switch.service"
EOF
udevadm control --reload-rules

echo "--- 13d boot service"
cat > /etc/systemd/system/power-switch.service <<'EOF'
[Unit]
Description=Apply power mode matching the AC adapter state
After=power-profiles-daemon.service
Wants=power-profiles-daemon.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/power-switch.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable power-switch.service

echo "--- 13e re-apply after resume"
mkdir -p /usr/lib/systemd/system-sleep
cat > /usr/lib/systemd/system-sleep/power-switch <<'EOF'
#!/bin/sh
[ "$1" = post ] && /usr/local/sbin/power-switch.sh
exit 0
EOF
chmod 755 /usr/lib/systemd/system-sleep/power-switch

echo "--- 13f apply now + verify"
systemctl start power-switch.service
sleep 2
echo "profile: $(powerprofilesctl get)"
echo "epp:     $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)"
for d in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0; do
  printf "%-40s PL1=%sW PL2=%sW\n" "$(basename $d)" "$(( $(cat $d/constraint_0_power_limit_uw)/1000000 ))" "$(( $(cat $d/constraint_1_power_limit_uw)/1000000 ))"
done
echo "gpu max: $(cat /sys/class/drm/card*/device/tile0/gt0/freq0/max_freq | head -1) MHz"
journalctl -t power-switch -n 3 --no-pager
echo
echo "Now unplug the charger, wait 5 s, and run:  journalctl -t power-switch -n 2 ; powerprofilesctl get"
echo "=== step13 done ==="
