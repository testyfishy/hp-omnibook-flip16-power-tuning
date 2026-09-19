#!/bin/bash
# STEP 14d — Is "balanced" worth it over "power-saver" at the SAME power cap?  Interleaved A/B/C on battery, ~25 min.
#   sudo bash scripts/step14d-epp-ab.sh              (defaults: CAP=6/6 W, ROUNDS=6)
#   CAP=8/8 ROUNDS=4 sudo -E bash scripts/step14d-epp-ab.sh
# Conditions (what power-profiles-daemon 0.30 actually changes on this machine = intel_pstate EPP + HP thermal mode):
#   saver     = ppd power-saver  -> EPP power,               HP platform profile quiet
#   balanced  = ppd balanced     -> EPP balance_performance, HP platform profile balanced
#   saver+bp  = ppd power-saver + EPP overridden to balance_power (the middle setting power-switch could apply)
# Method (from the energy-benchmarking literature: randomised/interleaved order, warm-up, thermal gate before every trial,
# >=5 repetitions, medians + paired differences; energy-to-completion for fixed work; a bursty deadline workload for the
# race-to-idle question):  ROUNDS rounds, each running all 3 conditions in a different order (the 6 permutations cycle,
# so every condition sits in every slot equally) -> drift in battery voltage/temperature/background cancels out.
# Per trial: settle -> thermal gate -> 10 s idle -> 20 bursts of fixed work every 0.5 s (latency + J/burst) ->
#            pdf render, office convert, python, zstd once each -> 20 s sustained zstd.  Same 2 Hz sampler as step14c.
# Held constant: the cap (re-applied and read back after every profile switch), panel refresh (refresh-follow stopped;
# the 48 vs 120 Hz question is a separate display-power decision), brightness, Wi-Fi.  Analysis: ab-analyze.py.
set -u
[ "$(id -u)" -eq 0 ] || { echo "Run with: sudo bash $0" >&2; exit 1; }
unset LD_PRELOAD
U=${SUDO_USER:-$(logname)}; H=$(getent passwd "$U" | cut -d: -f6); M=$(cd "$(dirname "$0")" && pwd); LOGS=${LOGS:-$M/logs}; mkdir -p "$LOGS"
CAP=${CAP:-6/6}; ROUNDS=${ROUNDS:-6}; IDLE_S=10; SUST_S=20; BURSTS=20; BURST_N=1500000; BURST_PERIOD=0.5
W=/dev/shm/abtest; mkdir -p "$W"; chown $U:$U "$W"
STAMP=$(date +%Y%m%d-%H%M); PFX=$LOGS/ab-$STAMP
TSV=$PFX.tasks.tsv; SAMPLES=$PFX.samples.tsv; MARKS=$PFX.marks.tsv; BURSTF=$PFX.bursts.tsv
exec > >(tee -a "$PFX.console.log") 2>&1   # keep the per-trial readback lines (msr/mmio/epp/profile) with the data
RAPL=(/sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0)
E=/sys/class/powercap/intel-rapl:0/energy_uj; CORE_E=/sys/class/powercap/intel-rapl:0:0/energy_uj; UNC_E=/sys/class/powercap/intel-rapl:0:1/energy_uj
EMAX=$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj); echo "$EMAX" > "$PFX.emax"
TEMP=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = coretemp ] && echo $h/temp1_input && break; done)
FAN=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = acpi_fan ] && [ -e $h/fan1_input ] && echo $h/fan1_input && break; done); [ -n "$FAN" ] || FAN=/dev/null
COOL_DELTA_MC=3000; COOL_MAX_S=120
NCPU=$(nproc); EPPF=/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; EPP0=/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
BAT=/sys/class/power_supply/BAT0; BL=/sys/class/backlight/intel_backlight
UID_U=$(id -u $U); UENV="XDG_RUNTIME_DIR=/run/user/$UID_U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_U/bus"
asuser() { runuser -u "$U" -- env HOME=$H "$@"; }
asuserd() { runuser -u "$U" -- env HOME=$H $UENV "$@"; }
for t in soffice pdftoppm zstd python3 powerprofilesctl; do command -v $t >/dev/null || { echo "missing tool: $t"; exit 1; }; done
PDF=${PDF:-}   # optional: path to a real PDF for the render task (the published runs used a 4.4 MB, 40-page journal PDF with figures)

echo "--- preflight"
echo "Unplug the charger (lid open). Starting when on battery…"
for i in $(seq 120); do [ "$(cat /sys/class/power_supply/ADP1/online)" = 0 ] && break; sleep 5; done
[ "$(cat /sys/class/power_supply/ADP1/online)" = 0 ] || { echo "still plugged in — giving up"; exit 1; }
sleep 12   # let power-switch apply its battery settings first
pgrep -x firefox >/dev/null && echo "WARNING: Firefox is running (it was measured rendering constantly earlier) — close it for a clean run"
read u0 n0 s0 i0 < <(awk '/^cpu /{print $2,$3,$4,$5}' /proc/stat); sleep 5; read u1 n1 s1 i1 < <(awk '/^cpu /{print $2,$3,$4,$5}' /proc/stat)
busy=$(( ((u1-u0)+(n1-n0)+(s1-s0))*100 / ((u1-u0)+(n1-n0)+(s1-s0)+(i1-i0)) )); echo "background CPU busy over 5 s: ${busy}%  (want <3%; the terminal running this test is fine)"
top -bn2 -d3 | awk '/^ *PID/{p++} p==2 && NR>0 && $1 ~ /^[0-9]+$/ {print "   ", $9"%", $12}' | head -5
echo "brightness $(cat $BL/brightness)/$(cat $BL/max_brightness)  wifi: $(nmcli -t -f DEVICE,STATE device | grep '^wlo' )  battery $(cat $BAT/capacity)%"

# NOT via the asuserd function: "func … &" backgrounds a subshell, $! is the subshell, and killing it orphans the inhibitor
# (that is what kept the laptop awake for hours after the first run). Direct runuser + a name-based pkill in the trap.
runuser -u "$U" -- env HOME=$H $UENV gnome-session-inhibit --inhibit idle:suspend --reason "power A/B test" --inhibit-only >/dev/null 2>&1 & INH1=$!
systemd-inhibit --what=sleep:idle --who=abtest --why="power A/B test" sleep 3600 >/dev/null 2>&1 & INH2=$!
RF_WAS=$(asuserd systemctl --user is-active refresh-follow 2>/dev/null || true)
[ "$RF_WAS" = active ] && { asuserd systemctl --user stop refresh-follow; echo "refresh-follow stopped (panel refresh frozen at its current rate for the whole test)"; }
T_START=$(date +%s)
PROF0=$(powerprofilesctl get)
PL1_0=$(( $(cat ${RAPL[0]}/constraint_0_power_limit_uw)/1000000 )); PL2_0=$(( $(cat ${RAPL[0]}/constraint_1_power_limit_uw)/1000000 ))
set_cap() { for d in "${RAPL[@]}"; do echo $(( $1*1000000 )) > "$d/constraint_0_power_limit_uw"; echo $(( $2*1000000 )) > "$d/constraint_1_power_limit_uw"; done; }
set_epp() { for f in $EPPF; do echo "$1" > "$f"; done; }
readback() { echo "msr $(( $(cat ${RAPL[0]}/constraint_0_power_limit_uw)/1000000 ))/$(( $(cat ${RAPL[0]}/constraint_1_power_limit_uw)/1000000 )) mmio $(( $(cat ${RAPL[1]}/constraint_0_power_limit_uw)/1000000 ))/$(( $(cat ${RAPL[1]}/constraint_1_power_limit_uw)/1000000 )) epp $(cat $EPP0) profile $(powerprofilesctl get)"; }
SAMP=""
trap 'kill $SAMP $INH1 $INH2 2>/dev/null; pkill -f "gnome-session-inhibit.*power A/B test" 2>/dev/null; powerprofilesctl set $PROF0 2>/dev/null; sleep 1; set_cap $PL1_0 $PL2_0; [ "$RF_WAS" = active ] && asuserd systemctl --user start refresh-follow; rm -rf "$W"; echo "restored profile $PROF0, PL ${PL1_0}/${PL2_0} W, refresh-follow $RF_WAS, inhibitors released"' EXIT

echo "--- preparing workloads"
tar -cf - /usr/lib/x86_64-linux-gnu 2>/dev/null | head -c 250M > "$W/corpus.tar"
python3 - <<'PY' > "$W/sample.txt"
import random; random.seed(1)
words="atrial fibrillation stroke anticoagulation appendage closure ablation guideline cohort outcome risk score trial patients".split()
for p in range(900): print(" ".join(random.choice(words) for _ in range(random.randint(60,140))).capitalize()+".\n")
PY
cat > "$W/pytask.py" <<'PY'
import json, re, random, hashlib
random.seed(7)
recs=[{"id":i,"name":"pt%06d"%random.randrange(10**6),"age":random.randint(18,95),"tags":[random.choice("abcdefgh") for _ in range(4)]} for i in range(300000)]
s=json.dumps(recs); recs=json.loads(s)
recs.sort(key=lambda r:(r["age"],r["name"]))
n=sum(1 for r in recs if re.match(r"pt0?[1-3]\d+",r["name"]))
print(n,hashlib.sha256(s.encode()).hexdigest()[:8])
PY
cat > "$W/burst.py" <<'PY'
# bursty interactive stand-in: fixed single-thread work (interpreter loop ~180 ms at EPP power) every PERIOD s, BURSTS times.
# prints one line per burst: ms.  Race-to-idle vs pace-to-idle shows up here as latency AND energy per burst.
import sys, time
bursts, n, period = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
out = open(sys.argv[4], "w")
def work(n):
    s = 0
    for i in range(n): s += i * i % 7
    return s
t_next = time.perf_counter()
for b in range(bursts):
    t0 = time.perf_counter(); work(n); t1 = time.perf_counter()
    out.write(f"{(t1-t0)*1000:.1f}\n")
    t_next += period
    d = t_next - time.perf_counter()
    if d > 0: time.sleep(d)
out.close()
PY
chown -R $U:$U "$W"
asuser soffice --headless --convert-to docx --outdir "$W" "$W/sample.txt" >/dev/null 2>&1
asuser soffice --headless --convert-to pdf  --outdir "$W/out" "$W/sample.docx" >/dev/null 2>&1
if [ -n "$PDF" ]; then cp "$PDF" "$W/doc.pdf"; else cp "$W/out/sample.pdf" "$W/doc.pdf"; fi   # render-task input

sampler() { local t pkg core unc bat batE v temp fan f sum
  exec 9<> <(:)
  while :; do
    t=$EPOCHREALTIME; pkg=$(<$E); core=$(<$CORE_E); unc=$(<$UNC_E)
    bat=$(<$BAT/power_now); batE=$(<$BAT/energy_now); v=$(<$BAT/voltage_now); temp=$(<$TEMP); fan=$(<$FAN); fan=${fan:-0}
    sum=0; for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do sum=$(( sum + $(<$f) )); done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$pkg" "$core" "$unc" "$bat" "$batE" "$v" "$temp" $(( sum / NCPU )) "$fan"
    read -t 0.5 -u 9 _ || true
  done; }
sampler > "$SAMPLES" & SAMP=$!
mark() { printf '%s\t%s\t%s\n' "$EPOCHREALTIME" "$1" "$2" >> "$MARKS"; }
task() { local e0 t0 e1 t1 de; e0=$(cat $E); t0=$EPOCHREALTIME; "$@" >/dev/null 2>&1; t1=$EPOCHREALTIME; e1=$(cat $E)
  de=$(( e1 - e0 )); [ $de -lt 0 ] && de=$(( de + EMAX )); awk -v t0=$t0 -v t1=$t1 -v de=$de 'BEGIN{printf "%.3f %.3f %.1f", t0, t1, de/1e6}'; }
rec() { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$1" "$2" "$(awk -v a=$4 -v b=$5 'BEGIN{print b-a}')" "$4" "$5" "$6" "$3" | tee -a "$TSV"; }
fresh() { rm -rf "$W/out"; mkdir -p "$W/out"; chown $U:$U "$W/out"; }

apply_cond() {   # $1 = saver | balanced | saver+bp ; re-apply the cap afterwards (firmware/ppd may touch limits on a profile change)
  case $1 in
    # EPP is set EXPLICITLY after the profile: ppd only touches EPP when the profile actually changes, so "power-saver"
    # requested right after saver+bp (already power-saver) left balance_power in place -> rounds 2+3 of the first run were contaminated.
    saver)    powerprofilesctl set power-saver; sleep 2; set_epp power;;
    balanced) powerprofilesctl set balanced;    sleep 2; set_epp balance_performance;;
    saver+bp) powerprofilesctl set power-saver; sleep 2; set_epp balance_power;;
  esac
  set_cap ${CAP%/*} ${CAP#*/}; sleep 4; }
cooldown() { local t0=$SECONDS t; mark cool wait
  while t=$(<$TEMP); [ $t -gt $(( T_REF + COOL_DELTA_MC )) ] && [ $(( SECONDS - t0 )) -lt $COOL_MAX_S ]; do sleep 2; done
  printf "    cool-down %ss -> %s C (ref %s C) " $(( SECONDS - t0 )) $(( t/1000 )) $(( T_REF/1000 )); }
trial() { local label=$1 r
  mark "$label" idle; sleep $IDLE_S
  fresh; mark "$label" bursty; r=$(task asuser python3 "$W/burst.py" $BURSTS $BURST_N $BURST_PERIOD "$W/out/bursts.txt")
  set -- $r; rec "$label" bursty $BURSTS "$1" "$2" "$3"; printf "%s\t%s\n" "$label" "$(tr '\n' ' ' < "$W/out/bursts.txt")" >> "$BURSTF"
  mark "$label" gap; sleep 3
  for name in pdf_render office python compress; do fresh; mark "$label" $name
    case $name in
      pdf_render) r=$(task asuser pdftoppm -r 110 -f 1 -l 40 -png "$W/doc.pdf" "$W/out/p");;
      office)     r=$(task asuser soffice --headless --convert-to pdf --outdir "$W/out" "$W/sample.docx");;
      python)     r=$(task asuser python3 "$W/pytask.py");;
      compress)   r=$(task asuser zstd -q -T0 -12 -f "$W/corpus.tar" -o "$W/out/c.zst");;
    esac
    set -- $r; rec "$label" $name 1 "$1" "$2" "$3"; mark "$label" gap; sleep 3
  done
  fresh; mark "$label" sustained20s
  r=$(task bash -c "end=\$((SECONDS+$SUST_S)); n=0; while [ \$SECONDS -lt \$end ]; do runuser -u $U -- zstd -q -T0 -12 -f $W/corpus.tar -o $W/out/c.zst; n=\$((n+1)); done; echo \$n > $W/out/count")
  set -- $r; rec "$label" sustained20s $(( $(cat "$W/out/count") * 250 )) "$1" "$2" "$3"
  mark "$label" end; sleep 4; }

printf "tier\ttask\tseconds\tt0\tt1\tsoc_joules\twork\n" > "$TSV"; : > "$MARKS"; : > "$BURSTF"
mark ref settle; sleep 15; T_REF=$(<$TEMP); echo "reference package temp $(( T_REF/1000 )) C"
echo "--- warm-up (discarded)"; apply_cond saver; mark warm warm; asuser zstd -q -T0 -12 -f "$W/corpus.tar" -o "$W/c.zst"; rm -f "$W/c.zst"; asuser python3 "$W/burst.py" 5 $BURST_N $BURST_PERIOD /dev/null; sleep 5
PERMS=("saver balanced saver+bp" "balanced saver+bp saver" "saver+bp saver balanced" "saver saver+bp balanced" "balanced saver saver+bp" "saver+bp balanced saver")
for round in $(seq 1 $ROUNDS); do
  order=${PERMS[$(( (round-1) % 6 ))]}
  echo "=== round $round/$ROUNDS  order: $order   battery $(cat $BAT/capacity)% $(awk '{printf "%.2f", $1/1e6}' $BAT/energy_now) Wh  $(date +%T)"
  for cond in $order; do
    apply_cond $cond; cooldown; echo "[$cond] $(readback)"
    trial "$cond#r$round"
  done
done
kill $SAMP 2>/dev/null; SAMP=""; sleep 1
echo; python3 "$M/ab-analyze.py" "$PFX" | tee "$PFX.summary.txt"
python3 "$M/ladder-analyze.py" "$PFX" >/dev/null 2>&1 && echo "chart: $PFX.png  (time series: $PFX.timeseries.csv)"
if journalctl -k --since "@$T_START" -o cat 2>/dev/null | grep -q 'PM: suspend entry'; then echo "WARNING: the machine SUSPENDED during the run"; else echo "check: no suspend during the run"; fi
chown $U:$U "$PFX".* 2>/dev/null
echo "raw: $PFX.{tasks,samples,marks,bursts}.tsv   summary: $PFX.summary.txt"; echo "battery now $(cat $BAT/capacity)% — plug back in"; echo "=== step14d done ==="
