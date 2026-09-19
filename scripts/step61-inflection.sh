#!/bin/bash
# STEP 61 — Robust inflection-point test: energy per unit of work vs package cap, on battery, under the FINAL EPP.
#   sudo bash scripts/step61-inflection.sh                 (~45 min, lid open, hands off)
#   CAPS="5 6 7 8" PASSES=2 sudo -E bash …                              (subset)
# What is more robust than the first ladder (step14c):
#   * 11 caps 4…12 W in 0.5 W steps around the candidate (4 5 5.5 6 6.5 7 7.5 8 9 10 12), PL1 = PL2
#   * 3 passes in different orders (ascending, descending, shuffled) -> median + spread per cap, order/battery drift cancels
#   * 6 FIXED-WORK workloads so energy-to-completion is exact: all-core int (zstd), all-core vector (8x sha256),
#     all-core real (pdftoppm pages in parallel), single-thread real (pdftoppm), single-thread interpreter (python),
#     single-thread vector (sha256 on 1 GB, Geekbench-like)
#   * EPP = balance_power (the installed policy), not the ladder's EPP power
#   * whole-laptop energy from BAT0 energy_now over the whole run -> rest-of-system watts -> J/job with and without
#     the screen/RAM/Wi-Fi charged to the job (the two use-cases give different optima)
#   * thermal gate before every cap, fan/temperature logged, 10 s idle per cap
# Output: logs/inflection-<stamp>.{tasks,samples,marks}.tsv + inflection-analyze.py summary/figure.
set -u
[ "$(id -u)" -eq 0 ] || { echo "Run with: sudo bash $0" >&2; exit 1; }
unset LD_PRELOAD
U=${SUDO_USER:-$(logname)}; H=$(getent passwd "$U" | cut -d: -f6); M=$(cd "$(dirname "$0")" && pwd); LOGS=${LOGS:-$M/logs}; mkdir -p "$LOGS"
CAPS=${CAPS:-"4 5 5.5 6 6.5 7 7.5 8 9 10 12"}; PASSES=${PASSES:-3}; EPP=${EPP:-balance_power}; IDLE_S=10
W=/dev/shm/inflect; mkdir -p "$W"; chown $U:$U "$W"
STAMP=$(date +%Y%m%d-%H%M); PFX=$LOGS/inflection-$STAMP
exec > >(tee -a "$PFX.console.log") 2>&1
RAPL=(/sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl-mmio:0)
E=/sys/class/powercap/intel-rapl:0/energy_uj; CORE_E=/sys/class/powercap/intel-rapl:0:0/energy_uj; UNC_E=/sys/class/powercap/intel-rapl:0:1/energy_uj
EMAX=$(cat /sys/class/powercap/intel-rapl:0/max_energy_range_uj); echo "$EMAX" > "$PFX.emax"
TEMP=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = coretemp ] && echo $h/temp1_input && break; done)
FAN=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = acpi_fan ] && [ -e $h/fan1_input ] && echo $h/fan1_input && break; done); [ -n "$FAN" ] || FAN=/dev/null
GPUF=$(ls /sys/class/drm/card*/device/tile0/gt0/freq0/act_freq | head -1)
NCPU=$(nproc); EPPF=/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; BAT=/sys/class/power_supply/BAT0
UID_U=$(id -u $U); UENV="XDG_RUNTIME_DIR=/run/user/$UID_U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_U/bus"
COOL_DELTA_MC=3000; COOL_MAX_S=120
asuser() { runuser -u "$U" -- env HOME=$H "$@"; }
for t in zstd openssl pdftoppm python3; do command -v $t >/dev/null || { echo "missing tool: $t"; exit 1; }; done
PDF=${PDF:-}   # optional: a real PDF for the render jobs (the published runs used a 4.4 MB, 40-page journal PDF)
echo "Unplug the charger (lid open). Starting when on battery…"
for i in $(seq 120); do [ "$(cat /sys/class/power_supply/ADP1/online)" = 0 ] && break; sleep 5; done
[ "$(cat /sys/class/power_supply/ADP1/online)" = 0 ] || { echo "still plugged in — giving up"; exit 1; }
sleep 12
pgrep -x firefox >/dev/null && echo "WARNING: Firefox running — close it for a clean run"
runuser -u "$U" -- env HOME=$H $UENV gnome-session-inhibit --inhibit idle:suspend --reason "inflection test" --inhibit-only >/dev/null 2>&1 & INH1=$!
systemd-inhibit --what=sleep:idle --who=inflection --why="inflection test" sleep 7200 >/dev/null 2>&1 & INH2=$!
T_START=$(date +%s)
PL1_0=$(( $(cat ${RAPL[0]}/constraint_0_power_limit_uw)/1000000 )); PL2_0=$(( $(cat ${RAPL[0]}/constraint_1_power_limit_uw)/1000000 )); EPP_0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)
set_cap() { local uw; uw=$(awk -v w=$1 'BEGIN{printf "%d", w*1000000}'); for d in "${RAPL[@]}"; do echo $uw > "$d/constraint_0_power_limit_uw"; echo $uw > "$d/constraint_1_power_limit_uw"; done; }
set_epp() { for f in $EPPF; do echo "$1" > "$f"; done; }
SAMP=""
trap 'kill $SAMP $INH1 $INH2 2>/dev/null; pkill -f "gnome-session-inhibit.*inflection test" 2>/dev/null; set_cap $PL1_0; for d in "${RAPL[@]}"; do echo $((PL2_0*1000000)) > "$d/constraint_1_power_limit_uw"; done; set_epp $EPP_0; rm -rf "$W"; echo "restored PL ${PL1_0}/${PL2_0} W, epp $EPP_0, inhibitors released"' EXIT

echo "--- preparing workloads (fixed work each)"
if [ -n "$PDF" ]; then cp "$PDF" "$W/doc.pdf"; else python3 - "$W/doc.pdf" <<'PY2'
import sys
# fallback: a generated 40-page PDF (text only, lighter than a real document)
from PIL import Image, ImageDraw
pages=[]
for i in range(40):
    im=Image.new("RGB",(1240,1754),"white"); d=ImageDraw.Draw(im)
    for y in range(60,1700,28): d.text((80,y),f"page {i+1} line {y} "+"lorem ipsum dolor sit amet "*4,fill="black")
    pages.append(im)
pages[0].save(sys.argv[1],save_all=True,append_images=pages[1:])
PY2
fi
tar -cf - /usr/lib/x86_64-linux-gnu 2>/dev/null | head -c 250M > "$W/corpus.tar"
for i in 1 2 3 4 5 6 7 8; do head -c 256M /dev/urandom > "$W/blob$i"; done; cat "$W"/blob[1-4] > "$W/big1g"   # 8x256 MB + 1 GB, page-cached in RAM
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
# warm the page cache and the binaries once
asuser openssl dgst -sha3-256 "$W/big1g" >/dev/null; for i in 1 2 3 4 5 6 7 8; do asuser openssl dgst -sha3-256 "$W/blob$i" >/dev/null & done; wait

sampler() { local t pkg core unc bat batE v temp fan f sum mx x g
  exec 9<> <(:)
  while :; do
    t=$EPOCHREALTIME; pkg=$(<$E); core=$(<$CORE_E); unc=$(<$UNC_E)
    bat=$(<$BAT/power_now); batE=$(<$BAT/energy_now); v=$(<$BAT/voltage_now); temp=$(<$TEMP); fan=$(<$FAN); fan=${fan:-0}; g=$(<$GPUF)
    sum=0; mx=0; for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do x=$(<$f); sum=$(( sum + x )); [ $x -gt $mx ] && mx=$x; done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$pkg" "$core" "$unc" "$bat" "$batE" "$v" "$temp" $(( sum / NCPU )) "$fan" "$mx" "$g"
    read -t 0.5 -u 9 _ || true
  done; }
sampler > "$PFX.samples.tsv" & SAMP=$!
mark() { printf '%s\t%s\t%s\n' "$EPOCHREALTIME" "$1" "$2" >> "$PFX.marks.tsv"; }
job() { local tier=$1 name=$2 work=$3; shift 3; local e0 t0 e1 t1 de
  mark "$tier" "$name"; e0=$(cat $E); t0=$EPOCHREALTIME; "$@" >/dev/null 2>&1; t1=$EPOCHREALTIME; e1=$(cat $E)
  de=$(( e1 - e0 )); [ $de -lt 0 ] && de=$(( de + EMAX ))
  awk -v T=$tier -v n=$name -v t0=$t0 -v t1=$t1 -v de=$de -v w=$work 'BEGIN{printf "%s\t%s\t%.3f\t%.3f\t%.3f\t%.1f\t%s\n", T, n, t1-t0, t0, t1, de/1e6, w}' >> "$PFX.tasks.tsv"
  mark "$tier" gap; sleep 3; }
fresh() { rm -rf "$W/out"; mkdir -p "$W/out"; chown $U:$U "$W/out"; }
run_cap() { local tier=$1
  mark "$tier" idle; sleep $IDLE_S
  fresh; job "$tier" zstd_mt      500  bash -c "runuser -u $U -- zstd -q -T0 -12 -f $W/corpus.tar -o $W/out/a.zst; runuser -u $U -- zstd -q -T0 -12 -f $W/corpus.tar -o $W/out/b.zst"   # 500 MB, all-core int
  job "$tier" sha_mt       4096 bash -c "for i in 1 2 3 4 5 6 7 8; do runuser -u $U -- bash -c 'openssl dgst -sha3-256 $W/blob'\$i'; openssl dgst -sha3-256 $W/blob'\$i & done; wait"   # 8 threads x 2 x 256 MB sha3 (no HW accel), all-core vector
  fresh; job "$tier" pdf_mt       80   bash -c "for k in 1 2; do for r in '1 5' '6 10' '11 15' '16 20' '21 25' '26 30' '31 35' '36 40'; do set -- \$r; runuser -u $U -- pdftoppm -r 110 -f \$1 -l \$2 -png $W/doc.pdf $W/out/p\$1 & done; wait; done"   # 2 x 40 pages in 8 parallel jobs, all-core real
  fresh; job "$tier" pdf_st       40   asuser pdftoppm -r 110 -f 1 -l 40 -png "$W/doc.pdf" "$W/out/p"                                                                                # 40 pages, single-thread real
  job "$tier" py_st        2    bash -c "runuser -u $U -- python3 $W/pytask.py; runuser -u $U -- python3 $W/pytask.py"                                                        # 2 x single-thread interpreter job
  job "$tier" sha_st       2048 bash -c "runuser -u $U -- openssl dgst -sha3-256 $W/big1g; runuser -u $U -- openssl dgst -sha3-256 $W/big1g"                                  # 2 x 1 GB sha3, single-thread vector
  mark "$tier" end; }
cooldown() { local t0=$SECONDS t; mark cool wait
  while t=$(<$TEMP); [ $t -gt $(( T_REF + COOL_DELTA_MC )) ] && [ $(( SECONDS - t0 )) -lt $COOL_MAX_S ]; do sleep 2; done
  printf "    cool-down %ss -> %s C  " $(( SECONDS - t0 )) $(( t/1000 )); }

printf "tier\ttask\tseconds\tt0\tt1\tsoc_joules\twork\n" > "$PFX.tasks.tsv"; : > "$PFX.marks.tsv"
set_epp $EPP; set_cap 6; mark ref settle; sleep 15; T_REF=$(<$TEMP); echo "epp $EPP, reference temp $(( T_REF/1000 )) C, battery $(cat $BAT/capacity)% $(awk '{printf "%.2f",$1/1e6}' $BAT/energy_now) Wh"
echo "--- warm-up (discarded)"; mark warm warm; asuser zstd -q -T0 -12 -f "$W/corpus.tar" -o "$W/w.zst"; rm -f "$W/w.zst"
asc=$(echo $CAPS | tr ' ' '\n' | sort -g | tr '\n' ' '); desc=$(echo $CAPS | tr ' ' '\n' | sort -gr | tr '\n' ' '); shuf_=$(echo $CAPS | tr ' ' '\n' | shuf --random-source=<(yes 61) | tr '\n' ' ')
for pass in $(seq 1 $PASSES); do
  case $(( (pass-1) % 3 )) in 0) order=$asc;; 1) order=$desc;; 2) order=$shuf_;; esac
  echo "=== pass $pass/$PASSES  order: $order   battery $(cat $BAT/capacity)% $(awk '{printf "%.2f",$1/1e6}' $BAT/energy_now) Wh  $(date +%T)"
  for cap in $order; do
    set_cap $cap; sleep 4; cooldown
    echo "[cap $cap W] msr $(awk '{printf "%.2f",$1/1e6}' ${RAPL[0]}/constraint_0_power_limit_uw)/$(awk '{printf "%.2f",$1/1e6}' ${RAPL[0]}/constraint_1_power_limit_uw) epp $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference) fan $(cat $FAN) $(date +%T)"
    run_cap "${cap}W#p$pass"
  done
done
set_cap 6; mark ref idle_end; sleep 30; mark ref end
kill $SAMP 2>/dev/null; SAMP=""; sleep 1
echo; python3 "$M/inflection-analyze.py" "$PFX" | tee "$PFX.summary.txt"
if journalctl -k --since "@$T_START" -o cat 2>/dev/null | grep -q 'PM: suspend entry'; then echo "WARNING: the machine SUSPENDED during the run"; fi
chown $U:$U "$PFX".* 2>/dev/null
echo "raw: $PFX.{tasks,samples,marks}.tsv   summary: $PFX.summary.txt"; echo "battery now $(cat $BAT/capacity)% — plug back in"; echo "=== step61 done ==="
