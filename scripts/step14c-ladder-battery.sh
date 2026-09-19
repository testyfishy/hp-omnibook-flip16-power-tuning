#!/bin/bash
# STEP 14c — Battery power ladder with POWER-OVER-TIME logging.  ~30 min, hands off, on battery, lid open.
#   sudo bash scripts/step14c-ladder-battery.sh
#   SMOKE=1 sudo bash scripts/step14c-ladder-battery.sh    # 1 tier, ~1.5 min, works on AC (validates the pipeline)
# Per tier (PL1/PL2 cap):  15 s IDLE window  ->  4 daily-use tasks x2 (pdf render, office convert, python, zstd)  ->  40 s SUSTAINED zstd.
# A 2 Hz sampler logs the whole run: RAPL package/core/uncore energy, BAT0 power_now + energy_now + voltage, package temp, mean CPU MHz.
# Markers tag every sample with tier + phase, so ladder-analyze.py reports mean / median / p10 / p90 / max power per tier and phase,
# whole-tier battery drain (energy_now), energy per task, a time-series CSV and a PNG chart.  Re-analyse any time:
#   python3 scripts/ladder-analyze.py scripts/logs/ladder2-<stamp>
set -u
[ "$(id -u)" -eq 0 ] || { echo "Run with: sudo bash $0" >&2; exit 1; }
unset LD_PRELOAD
U=${SUDO_USER:-$(logname)}; H=$(getent passwd "$U" | cut -d: -f6); M=$(cd "$(dirname "$0")" && pwd); LOGS=${LOGS:-$M/logs}; mkdir -p "$LOGS"
SMOKE=${SMOKE:-0}
W=/dev/shm/ladder; mkdir -p "$W"; chown $U:$U "$W"
STAMP=$(date +%Y%m%d-%H%M); PFX=$LOGS/ladder2-$STAMP
TSV=$PFX.tasks.tsv; SAMPLES=$PFX.samples.tsv; MARKS=$PFX.marks.tsv
RAPL=(/sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0)
E=/sys/class/powercap/intel-rapl:0/energy_uj; CORE_E=/sys/class/powercap/intel-rapl:0:0/energy_uj; UNC_E=/sys/class/powercap/intel-rapl:0:1/energy_uj
EMAX=$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj); echo "$EMAX" > "$PFX.emax"
TEMP=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = coretemp ] && echo $h/temp1_input && break; done)
FAN=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = acpi_fan ] && [ -e $h/fan1_input ] && echo $h/fan1_input && break; done); [ -n "$FAN" ] || FAN=/dev/null
COOL_DELTA_MC=3000; COOL_MAX_S=120   # before each tier: wait until package temp <= reference + 3 C (reference = temp after the initial idle), max 120 s
NCPU=$(nproc)
EPPF=/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
BAT=/sys/class/power_supply/BAT0
asuser() { runuser -u "$U" -- env HOME=$H "$@"; }
for t in soffice pdftoppm zstd python3; do command -v $t >/dev/null || { echo "missing tool: $t"; exit 1; }; done
PDF=${PDF:-}   # optional: path to a real PDF for the render task (the published runs used a 4.4 MB, 40-page journal PDF with figures)

if [ "$SMOKE" = 1 ]; then TIERS="fw"; IDLE_S=5; SUST_S=10; echo "SMOKE run: 1 tier, no battery wait, caps left as they are"
else
  # ascending power so heat/fan carried over from a hotter tier never lands on a cooler one (fw = battery caps from power-switch)
  TIERS="4/4 5/5 6/6 4/8 5/8 6/8 8/8 8/8@balance_power 8/12 8/15 10/10 12/12 fw"; IDLE_S=15; SUST_S=40
  # override:  TIERS="3/3 4/4 5/5@balance_power" sudo -E bash step14c-ladder-battery.sh   (PL1/PL2[@epp], space separated; fw = current caps)
  [ -n "${TIERS_OVERRIDE:-}" ] && TIERS="$TIERS_OVERRIDE"
  echo "Unplug the charger (lid open). Starting when on battery…"
  for i in $(seq 120); do [ "$(cat /sys/class/power_supply/ADP1/online)" = 0 ] && break; sleep 5; done
  [ "$(cat /sys/class/power_supply/ADP1/online)" = 0 ] || { echo "still plugged in — giving up"; exit 1; }
  sleep 15   # let power-switch (udev, 2 s delay) apply power-saver + battery caps first
fi
UID_U=$(id -u $U)
runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_U/bus \
  gnome-session-inhibit --inhibit idle:suspend --reason "battery power ladder" --inhibit-only >/dev/null 2>&1 & INH1=$!
systemd-inhibit --what=sleep:idle --who=ladder --why="battery power ladder" sleep 3600 >/dev/null 2>&1 & INH2=$!
T_START=$(date +%s)
[ "$SMOKE" = 1 ] || { powerprofilesctl set power-saver; sleep 3; }
PL1_0=$(( $(cat ${RAPL[1]}/constraint_0_power_limit_uw)/1000000 )); PL2_0=$(( $(cat ${RAPL[1]}/constraint_1_power_limit_uw)/1000000 ))
EPP_0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)
set_cap() { for d in "${RAPL[@]}"; do echo $(( $1*1000000 )) > "$d/constraint_0_power_limit_uw"; echo $(( $2*1000000 )) > "$d/constraint_1_power_limit_uw"; done; }
set_epp() { for f in $EPPF; do echo "$1" > "$f"; done; }
SAMP=""
trap 'kill $SAMP $INH1 $INH2 2>/dev/null; set_cap $PL1_0 $PL2_0; set_epp $EPP_0; rm -rf "$W"; echo "restored PL ${PL1_0}/${PL2_0} W, epp $EPP_0, inhibitors released"' EXIT

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
chown -R $U:$U "$W"
asuser soffice --headless --convert-to docx --outdir "$W" "$W/sample.txt" >/dev/null 2>&1
asuser soffice --headless --convert-to pdf  --outdir "$W/out" "$W/sample.docx" >/dev/null 2>&1
if [ -n "$PDF" ]; then cp "$PDF" "$W/doc.pdf"; else cp "$W/out/sample.pdf" "$W/doc.pdf"; fi   # render-task input

# --- 2 Hz sampler: no external process per sample (bash builtins + read -t as the timer)
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
run_tier() { local label=$1 r best
  mark "$label" idle; sleep $IDLE_S
  for name in pdf_render office python compress; do best=""
    for rep in 1 2; do rm -rf "$W/out"; mkdir -p "$W/out"; chown $U:$U "$W/out"; mark "$label" $name
      case $name in
        pdf_render) r=$(task asuser pdftoppm -r 110 -f 1 -l 40 -png "$W/doc.pdf" "$W/out/p");;
        office)     r=$(task asuser soffice --headless --convert-to pdf --outdir "$W/out" "$W/sample.docx");;
        python)     r=$(task asuser python3 "$W/pytask.py");;
        compress)   r=$(task asuser zstd -q -T0 -12 -f "$W/corpus.tar" -o "$W/out/c.zst");;
      esac
      set -- $r; local dur; dur=$(awk -v a=$1 -v b=$2 'BEGIN{print b-a}')
      if [ -z "$best" ] || awk -v a=$dur -v b="${best%% *}" 'BEGIN{exit !(a<b)}'; then best="$dur $1 $2 $3"; fi
      mark "$label" gap; sleep 4
    done
    set -- $best; printf "%s\t%s\t%s\t%s\t%s\t%s\t1\n" "$label" "$name" "$1" "$2" "$3" "$4" | tee -a "$TSV"
  done
  rm -rf "$W/out"; mkdir -p "$W/out"; chown $U:$U "$W/out"; mark "$label" sustained40s
  r=$(task bash -c "end=\$((SECONDS+$SUST_S)); n=0; while [ \$SECONDS -lt \$end ]; do runuser -u $U -- zstd -q -T0 -12 -f $W/corpus.tar -o $W/out/c.zst; n=\$((n+1)); done; echo \$n > $W/out/count")
  set -- $r; local mb=$(( $(cat "$W/out/count") * 250 )); local dur; dur=$(awk -v a=$1 -v b=$2 'BEGIN{print b-a}')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$label" "sustained40s" "$dur" "$1" "$2" "$3" "$mb" | tee -a "$TSV"
  mark "$label" end; sleep 8; }

printf "tier\ttask\tseconds\tt0\tt1\tsoc_joules\twork\n" > "$TSV"; : > "$MARKS"
mark ref settle; sleep $IDLE_S; T_REF=$(<$TEMP); echo "reference package temp $(( T_REF/1000 )) C, fan $(<$FAN) rpm (after $IDLE_S s idle)"
cooldown() { local t0=$SECONDS t; mark cool wait
  while t=$(<$TEMP); [ $t -gt $(( T_REF + COOL_DELTA_MC )) ] && [ $(( SECONDS - t0 )) -lt $COOL_MAX_S ]; do sleep 2; done
  echo "    cool-down $(( SECONDS - t0 )) s -> $(( t/1000 )) C (ref $(( T_REF/1000 )) C), fan $(<$FAN) rpm"; }
for spec in $TIERS; do
  cooldown
  epp=$EPP_0; caps=${spec%@*}; [ "$spec" != "$caps" ] && epp=${spec#*@}
  if [ "$caps" = fw ]; then set_cap $PL1_0 $PL2_0; else set_cap ${caps%/*} ${caps#*/}; fi
  set_epp $epp; sleep 6
  # readback: MSR domain honours both writes; the MMIO domain's PL1 is pinned at 12 W by HP firmware on battery (PL2 follows).
  eff="msr$(( $(cat ${RAPL[0]}/constraint_0_power_limit_uw)/1000000 ))/$(( $(cat ${RAPL[0]}/constraint_1_power_limit_uw)/1000000 )),mmio$(( $(cat ${RAPL[1]}/constraint_0_power_limit_uw)/1000000 ))/$(( $(cat ${RAPL[1]}/constraint_1_power_limit_uw)/1000000 ))"
  echo "=== $spec  (readback $eff W, epp $epp, battery $(cat $BAT/capacity)%, $(cat $BAT/energy_now | awk '{printf "%.2f", $1/1e6}') Wh)  $(date +%T)"
  run_tier "$spec"
done
kill $SAMP 2>/dev/null; SAMP=""; sleep 1
echo; python3 "$M/ladder-analyze.py" "$PFX" | tee "$PFX.summary.txt"
if journalctl -k --since "@$T_START" -o cat 2>/dev/null | grep -q 'PM: suspend entry'; then echo "WARNING: the machine SUSPENDED during the run — results after that point are invalid"; else echo "check: no suspend during the run"; fi
chown $U:$U "$PFX".* 2>/dev/null
echo "raw: $PFX.{tasks,samples,marks}.tsv  summary: $PFX.summary.txt  chart: $PFX.png"
echo "battery now $(cat $BAT/capacity)% — plug back in"; echo "=== step14c done ==="
