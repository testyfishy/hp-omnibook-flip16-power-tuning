#!/bin/bash
# STEP 59 — Heavy stress with telemetry: prove the final battery policy (power-saver + EPP balance_power + 6/6 W) holds.
#   sudo bash scripts/step59-stress-verify.sh        (~6 min, on battery, lid open; two GL windows will pop up briefly)
# Phases: 20 s idle -> 30 s single-thread (clocks must climb) -> 90 s all-core zstd -19 -> ~50 s all-core openssl sha256 ->
#         ~60 s all-core openssl + iGPU (glxgears, vsync off) -> 30 s recovery idle.
# Telemetry: 2 Hz sampler (RAPL pkg/core/uncore, battery, pkg temp, fan, mean+max core MHz, GPU MHz), turbostat 10 s summaries,
#            CPU/package thermal-throttle counters, xe throttle reasons, EPP + cap readback at every phase boundary.
# Checks:   cap held (all-core SoC W mean <= 6.3, p99 <= 7.0), EPP stayed balance_power on all CPUs, caps still 6/6,
#           single-thread max core >= 2500 MHz, no thermal throttle events, temp < 90 C, recovery idle < 1.0 W.
set -u
[ "$(id -u)" -eq 0 ] || { echo "Run with: sudo bash $0" >&2; exit 1; }
unset LD_PRELOAD
U=${SUDO_USER:-$(logname)}; H=$(getent passwd "$U" | cut -d: -f6); M=$(cd "$(dirname "$0")" && pwd); LOGS=${LOGS:-$M/logs}; mkdir -p "$LOGS"
W=/dev/shm/stress; mkdir -p "$W"; chown $U:$U "$W"
STAMP=$(date +%Y%m%d-%H%M); PFX=$LOGS/stress-$STAMP
TSV=$PFX.tasks.tsv; SAMPLES=$PFX.samples.tsv; MARKS=$PFX.marks.tsv
exec > >(tee -a "$PFX.console.log") 2>&1
RAPL=(/sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0)
E=/sys/class/powercap/intel-rapl:0/energy_uj; CORE_E=/sys/class/powercap/intel-rapl:0:0/energy_uj; UNC_E=/sys/class/powercap/intel-rapl:0:1/energy_uj
EMAX=$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj); echo "$EMAX" > "$PFX.emax"
TEMP=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = coretemp ] && echo $h/temp1_input && break; done)
FAN=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = acpi_fan ] && [ -e $h/fan1_input ] && echo $h/fan1_input && break; done); [ -n "$FAN" ] || FAN=/dev/null
GPUF=$(ls /sys/class/drm/card*/device/tile0/gt0/freq0/act_freq | head -1); GPUT=$(dirname $GPUF)/throttle
NCPU=$(nproc); EPP0=/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference; BAT=/sys/class/power_supply/BAT0
UID_U=$(id -u $U); UENV="XDG_RUNTIME_DIR=/run/user/$UID_U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_U/bus WAYLAND_DISPLAY=wayland-0 DISPLAY=:0"
asuser() { runuser -u "$U" -- env HOME=$H "$@"; }
for t in zstd openssl python3 turbostat glxgears; do command -v $t >/dev/null || { echo "missing tool: $t"; exit 1; }; done
echo "Unplug the charger (lid open). Starting when on battery…"
for i in $(seq 120); do [ "$(cat /sys/class/power_supply/ADP1/online)" = 0 ] && break; sleep 5; done
[ "$(cat /sys/class/power_supply/ADP1/online)" = 0 ] || { echo "still plugged in — giving up"; exit 1; }
sleep 8
runuser -u "$U" -- env HOME=$H $UENV gnome-session-inhibit --inhibit idle:suspend --reason "stress verify" --inhibit-only >/dev/null 2>&1 & INH1=$!
systemd-inhibit --what=sleep:idle --who=stress --why="stress verify" sleep 3600 >/dev/null 2>&1 & INH2=$!
T_START=$(date +%s); SAMP=""; TS=""; GL=""
trap 'kill $SAMP $TS $GL $INH1 $INH2 2>/dev/null; pkill -f "gnome-session-inhibit.*stress verify" 2>/dev/null; pkill -x glxgears 2>/dev/null; rm -rf "$W"; echo "inhibitors released"' EXIT

readback() { local epps; epps=$(cat /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference | sort -u | tr '\n' ',')
  echo "[$1] profile=$(powerprofilesctl get) epp=${epps%,} msr=$(( $(cat ${RAPL[0]}/constraint_0_power_limit_uw)/1000000 ))/$(( $(cat ${RAPL[0]}/constraint_1_power_limit_uw)/1000000 )) mmio=$(( $(cat ${RAPL[1]}/constraint_0_power_limit_uw)/1000000 ))/$(( $(cat ${RAPL[1]}/constraint_1_power_limit_uw)/1000000 )) gpu_max=$(cat $(dirname $GPUF)/max_freq) temp=$(( $(cat $TEMP)/1000 ))C fan=$(cat $FAN) throttle_pkg=$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count) xe_throttle=$(cat $GPUT/status) $(date +%T)"; }
echo "=== stress-verify $STAMP  policy: $(grep -v '^#' /etc/power-switch.conf | tr '\n' ' ')"; readback start
echo "$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count) $(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count)" > "$W/thr0"

tar -cf - /usr/lib/x86_64-linux-gnu 2>/dev/null | head -c 250M > "$W/corpus.tar"; chown $U:$U "$W/corpus.tar"
sampler() { local t pkg core unc bat batE v temp fan f sum mx x g
  exec 9<> <(:)
  while :; do
    t=$EPOCHREALTIME; pkg=$(<$E); core=$(<$CORE_E); unc=$(<$UNC_E)
    bat=$(<$BAT/power_now); batE=$(<$BAT/energy_now); v=$(<$BAT/voltage_now); temp=$(<$TEMP); fan=$(<$FAN); fan=${fan:-0}; g=$(<$GPUF)
    sum=0; mx=0; for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do x=$(<$f); sum=$(( sum + x )); [ $x -gt $mx ] && mx=$x; done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$pkg" "$core" "$unc" "$bat" "$batE" "$v" "$temp" $(( sum / NCPU )) "$fan" "$mx" "$g"
    read -t 0.5 -u 9 _ || true
  done; }
sampler > "$SAMPLES" & SAMP=$!
turbostat --quiet --interval 10 --Summary > "$PFX.turbostat.txt" 2>&1 & TS=$!
mark() { printf '%s\t%s\t%s\n' "$EPOCHREALTIME" "$1" "$2" >> "$MARKS"; }
phase() { local name=$1; shift; local e0 t0 e1 t1 de
  mark stress "$name"; e0=$(cat $E); t0=$EPOCHREALTIME; "$@" >/dev/null 2>&1; t1=$EPOCHREALTIME; e1=$(cat $E)
  de=$(( e1 - e0 )); [ $de -lt 0 ] && de=$(( de + EMAX ))
  awk -v n=$name -v t0=$t0 -v t1=$t1 -v de=$de 'BEGIN{printf "stress\t%s\t%.3f\t%.3f\t%.3f\t%.1f\t1\n", n, t1-t0, t0, t1, de/1e6}' >> "$TSV"
  readback "$name done"; }
printf "tier\ttask\tseconds\tt0\tt1\tsoc_joules\twork\n" > "$TSV"; : > "$MARKS"
echo "--- idle 20 s";            phase idle sleep 20
echo "--- single-thread 30 s";   phase single asuser python3 -c 'import time
t=time.time()+30
while time.time()<t:
    s=0
    for i in range(300000): s+=i*i%7'
echo "--- all-core zstd -19, 90 s"; phase allcore_zstd bash -c "end=\$((SECONDS+90)); while [ \$SECONDS -lt \$end ]; do runuser -u $U -- zstd -q -T0 -19 -f $W/corpus.tar -o $W/c.zst; done"
echo "--- all-core openssl sha256 (8 threads)"; phase allcore_openssl asuser openssl speed -seconds 8 -multi 8 -evp sha256
echo "--- all-core openssl + iGPU (glxgears, vsync off)"
runuser -u "$U" -- env HOME=$H $UENV vblank_mode=0 glxgears -geometry 1200x900 >/dev/null 2>&1 & GL=$!
sleep 3; phase combined_cpu_gpu asuser openssl speed -seconds 8 -multi 8 -evp sha256
kill $GL 2>/dev/null; pkill -x glxgears 2>/dev/null; GL=""
echo "--- recovery idle 30 s";   phase recovery sleep 30
kill $SAMP $TS 2>/dev/null; SAMP=""; TS=""; sleep 1
read p1 c1 < "$W/thr0"; echo "thermal throttle counters (pkg/core) start $p1/$c1 -> end $(cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count)/$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count)"
echo "xe throttle reasons now: $(for r in $GPUT/reason_*; do printf "%s=%s " $(basename $r | sed s/reason_//) $(cat $r); done)"
echo; echo "=== per-phase statistics"; python3 "$M/ladder-analyze.py" "$PFX" | sed -n '1,/^\* batW/p'
echo; echo "=== CHECKS"
python3 - "$PFX" "$W/thr0" <<'PY'
import sys, csv, statistics as st
pfx, thr0 = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(pfx + ".timeseries.csv")))
# extra columns from the raw samples (max core MHz, GPU MHz) keyed by time
S = [l.split() for l in open(pfx + ".samples.tsv") if len(l.split()) == 12]
mx = {float(s[0]): (int(s[10]) / 1000, int(s[11])) for s in S}
t0 = float(S[0][0])
def ph(name): return [r for r in rows if r["phase"] == name]
def W(rs): return [float(r["soc_w"]) for r in rs]
def q(v, f): v = sorted(v); return v[min(len(v) - 1, int(round(f * (len(v) - 1))))]
def mxmhz(rs): return max((mx.get(round(float(r["t_s"]) + t0, 2), (0, 0))[0] for r in rs), default=0)
fails = 0
def check(ok, msg):
    global fails; fails += 0 if ok else 1; print(("PASS  " if ok else "FAIL  ") + msg)
for name in ("allcore_zstd", "allcore_openssl", "combined_cpu_gpu"):
    w = W(ph(name))
    if not w: check(False, f"{name}: no samples"); continue
    check(st.fmean(w) <= 6.3 and q(w, .99) <= 7.0, f"{name}: cap held — SoC W mean {st.fmean(w):.2f}, median {st.median(w):.2f}, p99 {q(w,.99):.2f}, max {max(w):.2f} (limit 6 W)")
single = ph("single"); m = 0
for r in single:
    t = None
    for k in mx:
        if abs(k - (float(r["t_s"]) + t0)) < 0.3: t = mx[k][0]; break
    if t: m = max(m, t)
peak_single = max((mx[k][0] for k in mx if single and float(single[0]["t_s"]) + t0 <= k <= float(single[-1]["t_s"]) + t0), default=0)
check(peak_single >= 2500, f"single-thread: fastest core reached {peak_single:.0f} MHz (EPP balance_power lets it climb; 'power' sat at ~900)")
temps = [float(r["pkg_temp_c"]) for r in rows]; fans = [float(r["fan_rpm"]) for r in rows]
check(max(temps) < 90, f"thermals: package max {max(temps):.0f} C, fan max {max(fans):.0f} rpm")
rec = W(ph("recovery")[-30:]); check(bool(rec) and st.fmean(rec) < 1.0, f"recovery: idle SoC W after load {st.fmean(rec) if rec else 0:.2f} (want < 1.0)")
gpu = [mx[k][1] for k in mx if ph("combined_cpu_gpu") and float(ph("combined_cpu_gpu")[0]["t_s"]) + t0 <= k <= float(ph("combined_cpu_gpu")[-1]["t_s"]) + t0]
print(f"info  iGPU during combined phase: mean {st.fmean(gpu) if gpu else 0:.0f} MHz, max {max(gpu) if gpu else 0} MHz (ceiling 1500)")
epps = set(open(f"/sys/devices/system/cpu/cpu{i}/cpufreq/energy_performance_preference").read().strip() for i in range(8))
check(epps == {"balance_power"}, f"EPP on all CPUs at end: {','.join(sorted(epps))}")
pl = [int(open(f"/sys/class/powercap/intel-rapl:0/constraint_{i}_power_limit_uw").read()) // 10**6 for i in (0, 1)]
check(pl == [6, 6], f"MSR caps at end: {pl[0]}/{pl[1]} W")
p0, c0 = open(thr0).read().split()
p1 = open("/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count").read().strip(); c1 = open("/sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count").read().strip()
check(p1 == p0 and c1 == c0, f"no thermal throttle events (pkg {p0}->{p1}, core {c0}->{c1})")
print(f"\n{'ALL CHECKS PASSED' if fails == 0 else str(fails) + ' CHECK(S) FAILED'}")
PY
echo; echo "turbostat 10 s summaries: $PFX.turbostat.txt   chart: $PFX.png   raw: $PFX.{samples,marks,tasks}.tsv"
echo "battery now $(cat $BAT/capacity)% — plug back in"; echo "=== step59 done ==="
