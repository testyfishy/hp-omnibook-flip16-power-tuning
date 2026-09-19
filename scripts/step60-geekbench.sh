#!/bin/bash
# STEP 60 — Geekbench 6.7.1 CPU across three power configurations, with 2 Hz power telemetry, tabulated at the end.
#   sudo bash scripts/step60-geekbench.sh                 # all three, in order (it tells you when to plug in)
#   MODES="battery6" sudo -E bash …    /   MODES="ac performance" sudo -E bash …      # a subset
#   STAMP=20260919-0544 MODES="ac performance" sudo -E bash …                         # resume: append to an existing log set
#   1. battery6     on battery: power-saver + EPP balance_power + 6/6 W (the final policy; script asserts it)
#   2. ac           plugged in: balanced + 30/37 W, EPP from power-profiles-daemon (balance_performance)
#   3. performance  plugged in: `power-switch.sh performance` = performance profile + 30/37 W + GPU 2050, EPP performance;
#                   restored to auto afterwards
# The free Geekbench build uploads every result to browser.geekbench.com (public URL, no name unless you claim it).
# Output: logs/geekbench-<stamp>.{battery6,ac,performance}.cpu.txt, .summary.txt + .md table, .png chart, raw samples.
set -u
[ "$(id -u)" -eq 0 ] || { echo "Run with: sudo bash $0" >&2; exit 1; }
unset LD_PRELOAD
U=${SUDO_USER:-$(logname)}; H=$(getent passwd "$U" | cut -d: -f6); M=$(cd "$(dirname "$0")" && pwd); LOGS=${LOGS:-$M/logs}; mkdir -p "$LOGS"; GB=${GEEKBENCH:-$M/bench/Geekbench-6.7.1-Linux/geekbench6}
[ -x "$GB" ] || { echo "geekbench binary missing: $GB"; exit 1; }
MODES=${MODES:-"battery6 ac performance"}
STAMP=${STAMP:-$(date +%Y%m%d-%H%M)}; PFX=$LOGS/geekbench-$STAMP   # STAMP=<old stamp> MODES="ac performance" resumes into an existing log set
exec > >(tee -a "$PFX.console.log") 2>&1
RAPL=(/sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0)
E=/sys/class/powercap/intel-rapl:0/energy_uj; CORE_E=/sys/class/powercap/intel-rapl:0:0/energy_uj; UNC_E=/sys/class/powercap/intel-rapl:0:1/energy_uj
EMAX=$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj); echo "$EMAX" > "$PFX.emax"
TEMP=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = coretemp ] && echo $h/temp1_input && break; done)
FAN=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = acpi_fan ] && [ -e $h/fan1_input ] && echo $h/fan1_input && break; done); [ -n "$FAN" ] || FAN=/dev/null
GPUF=$(ls /sys/class/drm/card*/device/tile0/gt0/freq0/act_freq | head -1)
NCPU=$(nproc); BAT=/sys/class/power_supply/BAT0; ADP=/sys/class/power_supply/ADP1/online
UID_U=$(id -u $U); UENV="XDG_RUNTIME_DIR=/run/user/$UID_U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_U/bus"
readback() { local epps; epps=$(cat /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference | sort -u | tr '\n' ',')
  echo "adapter=$([ "$(cat $ADP)" = 1 ] && echo AC || echo battery) profile=$(powerprofilesctl get) epp=${epps%,} msr=$(( $(cat ${RAPL[0]}/constraint_0_power_limit_uw)/1000000 ))/$(( $(cat ${RAPL[0]}/constraint_1_power_limit_uw)/1000000 )) mmio=$(( $(cat ${RAPL[1]}/constraint_0_power_limit_uw)/1000000 ))/$(( $(cat ${RAPL[1]}/constraint_1_power_limit_uw)/1000000 )) gpu_max=$(cat $(dirname $GPUF)/max_freq) temp=$(( $(cat $TEMP)/1000 ))C fan=$(cat $FAN) bat=$(cat $BAT/capacity)%"; }
wait_adapter() { local want=$1; [ "$(cat $ADP)" = "$want" ] && return 0
  echo ">>> $([ "$want" = 1 ] && echo "PLUG THE CHARGER IN" || echo "UNPLUG THE CHARGER") now (waiting up to 10 min)…"
  for i in $(seq 120); do [ "$(cat $ADP)" = "$want" ] && { sleep 10; return 0; }; sleep 5; done
  echo "adapter never reached the wanted state — giving up"; return 1; }
runuser -u "$U" -- env HOME=$H $UENV gnome-session-inhibit --inhibit idle:suspend --reason "geekbench" --inhibit-only >/dev/null 2>&1 & INH1=$!
systemd-inhibit --what=sleep:idle --who=geekbench --why="geekbench" sleep 7200 >/dev/null 2>&1 & INH2=$!
SAMP=""; PERF_SET=0
trap 'kill $SAMP $INH1 $INH2 2>/dev/null; pkill -f "gnome-session-inhibit.*geekbench" 2>/dev/null; [ $PERF_SET = 1 ] && /usr/local/sbin/power-switch.sh >/dev/null 2>&1 && echo "power mode restored to auto"; echo "inhibitors released"' EXIT
sampler() { local t pkg core unc bat batE v temp fan f sum mx x g
  exec 9<> <(:)
  while :; do
    t=$EPOCHREALTIME; pkg=$(<$E); core=$(<$CORE_E); unc=$(<$UNC_E)
    bat=$(<$BAT/power_now); batE=$(<$BAT/energy_now); v=$(<$BAT/voltage_now); temp=$(<$TEMP); fan=$(<$FAN); fan=${fan:-0}; g=$(<$GPUF)
    sum=0; mx=0; for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do x=$(<$f); sum=$(( sum + x )); [ $x -gt $mx ] && mx=$x; done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$pkg" "$core" "$unc" "$bat" "$batE" "$v" "$temp" $(( sum / NCPU )) "$fan" "$mx" "$g"
    read -t 0.5 -u 9 _ || true
  done; }
sampler >> "$PFX.samples.tsv" & SAMP=$!
mark() { printf '%s\t%s\t%s\n' "$EPOCHREALTIME" "$1" "$2" >> "$PFX.marks.tsv"; }
phase() { local tier=$1 name=$2; shift 2; local e0 t0 e1 t1 de
  mark "$tier" "$name"; e0=$(cat $E); t0=$EPOCHREALTIME; "$@"; t1=$EPOCHREALTIME; e1=$(cat $E)
  de=$(( e1 - e0 )); [ $de -lt 0 ] && de=$(( de + EMAX ))
  awk -v T=$tier -v n=$name -v t0=$t0 -v t1=$t1 -v de=$de 'BEGIN{printf "%s\t%s\t%.3f\t%.3f\t%.3f\t%.1f\t1\n", T, n, t1-t0, t0, t1, de/1e6}' >> "$PFX.tasks.tsv"; }
[ -s "$PFX.tasks.tsv" ] || printf "tier\ttask\tseconds\tt0\tt1\tsoc_joules\twork\n" > "$PFX.tasks.tsv"; touch "$PFX.marks.tsv" "$PFX.readback.txt"
pgrep -x firefox >/dev/null && echo "WARNING: Firefox running — close it for clean scores"

for mode in $MODES; do
  case $mode in
    battery6)    wait_adapter 0 || exit 1; rb=$(readback); { echo "$rb" | grep -q 'epp=balance_power ' && echo "$rb" | grep -q 'msr=6/6'; } || { echo "battery policy is not balance_power + 6/6: $rb"; exit 1; };;
    ac)          wait_adapter 1 || exit 1; [ $PERF_SET = 1 ] && { /usr/local/sbin/power-switch.sh; PERF_SET=0; sleep 3; }; rb=$(readback); { echo "$rb" | grep -q 'profile=balanced ' && echo "$rb" | grep -q 'msr=30/37'; } || { echo "AC state is not balanced + 30/37: $rb"; exit 1; };;
    performance) wait_adapter 1 || exit 1; /usr/local/sbin/power-switch.sh performance; PERF_SET=1; sleep 3; rb=$(readback); echo "$rb" | grep -q 'profile=performance' || { echo "performance mode not active: $rb"; exit 1; };;
    *) echo "unknown mode $mode"; exit 1;;
  esac
  echo "=== [$mode] $rb  $(date +%T)"; echo "$mode	$rb" >> "$PFX.readback.txt"
  # short cool-down so a hot previous run does not hand its temperature to the next one
  for i in $(seq 60); do [ $(( $(cat $TEMP)/1000 )) -le 45 ] && break; sleep 2; done
  phase "$mode" idle sleep 15
  phase "$mode" geekbench_cpu runuser -u "$U" -- env HOME=$H "$GB" --cpu 2>&1 | tee "$PFX.$mode.cpu.txt"
  mark "$mode" end; sleep 5
  # the free CLI prints no scores; the public result page has them but sits behind a bot check that curl fails and a
  # real browser passes -> headless Firefox screenshot of the page (scores are then copied into $PFX.$mode.scores.txt)
  url=$(grep -o 'https://browser.geekbench.com/v6/cpu/[0-9]*' "$PFX.$mode.cpu.txt" | head -1)
  if [ -n "$url" ] && command -v firefox >/dev/null; then tmpp=$(mktemp -d /dev/shm/ffp.XXXX); chown $U:$U "$tmpp"
    runuser -u "$U" -- env HOME=$H timeout 90 firefox --headless --profile "$tmpp" --window-size=1200,2400 --screenshot "$PFX.$mode.page.png" "$url" >/dev/null 2>&1 || true
    rm -rf "$tmpp"; [ -s "$PFX.$mode.page.png" ] && echo "result page screenshot: $PFX.$mode.page.png ($url)"; fi
done
[ $PERF_SET = 1 ] && { /usr/local/sbin/power-switch.sh; PERF_SET=0; echo "power mode restored to auto"; }
kill $SAMP 2>/dev/null; SAMP=""; sleep 1
python3 "$M/ladder-analyze.py" "$PFX" >/dev/null 2>&1 || true
python3 "$M/bench-tabulate.py" "$PFX" | tee "$PFX.summary.txt"
chown $U:$U "$PFX".* 2>/dev/null
echo "logs: $PFX.*   chart: $PFX.png   table: $PFX.md"; echo "=== step60 done ==="
