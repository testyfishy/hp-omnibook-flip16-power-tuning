#!/usr/bin/env python3
"""Analyse a battery ladder run: per-tier / per-phase power statistics (mean, median, p10, p90, max),
whole-tier battery drain, a time-series CSV and a PNG chart.  Re-runnable on old logs:
    python3 ladder-analyze.py logs/ladder2-YYYYmmdd-HHMM   (prefix of the .tasks.tsv/.samples.tsv/.marks.tsv files)
"""
import sys, statistics as st
prefix = sys.argv[1]
EMAX = int(open(prefix + ".emax").read()) if __import__("os").path.exists(prefix + ".emax") else 2**32
tasks = [l.rstrip("\n").split("\t") for l in open(prefix + ".tasks.tsv")][1:]
S = []
for l in open(prefix + ".samples.tsv"):
    p = l.split()
    if len(p) >= 9:   # extra columns (stress run: max core MHz, GPU MHz) are ignored here
        try: S.append([float(p[0])] + [int(x) for x in p[1:10]] + ([0] if len(p) == 9 else []))
        except ValueError: pass
marks = [(float(a), b, c) for a, b, c in (l.rstrip("\n").split("\t") for l in open(prefix + ".marks.tsv") if l.count("\t") == 2)]
if len(S) < 3: sys.exit("not enough samples")
# power samples between consecutive readings: W = dE / dt (RAPL counters wrap at EMAX)
P = []   # (t_start, dt, soc_w, core_w, unc_w, bat_w, batE_wh, temp_c, mhz, fan_rpm, t_end)
for a, b in zip(S, S[1:]):
    dt = b[0] - a[0]
    if dt <= 0.05: continue
    d = lambda i: ((b[i] - a[i]) % EMAX) / 1e6 / dt
    P.append((a[0], dt, d(1), d(2), d(3), b[4] / 1e6, b[5] / 1e6, b[7] / 1000, b[8] / 1000, b[9], b[0]))
t0 = S[0][0]
# phase windows from the markers
win = []
for i, (t, tier, phase) in enumerate(marks):
    tend = marks[i + 1][0] if i + 1 < len(marks) else S[-1][0]
    win.append((t, tend, tier, phase))
SKIP = {"end", "gap", "settle", "wait"}          # not scored: rests between runs, cool-down waits
tiers = [t for t in dict.fromkeys(w[2] for w in win) if t not in ("ref", "cool")]
phases = [p for p in dict.fromkeys(w[3] for w in win) if p not in SKIP]
def stats(vals):
    if not vals: return None
    v = sorted(vals); n = len(v)
    q = lambda f: v[min(n - 1, int(round(f * (n - 1))))]
    return dict(n=n, mean=st.fmean(v), median=st.median(v), p10=q(0.1), p90=q(0.9), max=v[-1])
def inwin(w): return [p for p in P if w[0] <= p[0] and p[10] <= w[1]]   # interval fully inside the window (no boundary mixing)
# ---------- time series csv
with open(prefix + ".timeseries.csv", "w") as f:
    f.write("t_s,tier,phase,soc_w,core_w,uncore_w,bat_power_now_w,bat_energy_wh,pkg_temp_c,cpu_mhz,fan_rpm\n")
    for p in P:
        lab = next(((w[2], w[3]) for w in win if w[0] <= p[0] < w[1]), ("", "gap"))
        f.write(f"{p[0]-t0:.2f},{lab[0]},{lab[1]},{p[2]:.3f},{p[3]:.3f},{p[4]:.3f},{p[5]:.3f},{p[6]:.3f},{p[7]:.1f},{p[8]:.0f},{p[9]}\n")
# ---------- per-tier / per-phase table
print("=== SoC POWER PER TIER AND PHASE (W, from RAPL package energy, 2 Hz samples; short tasks = both repetitions)")
hdr = f"{'tier':22}{'phase':13}{'n':>5}{'mean':>7}{'median':>8}{'p10':>7}{'p90':>7}{'max':>7}{'temp':>6}{'fan':>6}{'MHz':>6}{'batW*':>7}"
print(hdr)
tier_rows = {}
for t in tiers:
    for ph in phases:
        ws = [w for w in win if w[2] == t and w[3] == ph]
        pts = [p for w in ws for p in inwin(w)]
        s = stats([p[2] for p in pts])
        if not s: continue
        tier_rows[(t, ph)] = s
        bat = [p[5] for p in pts if p[5] > 0]
        print(f"{t:22}{ph:13}{s['n']:5d}{s['mean']:7.2f}{s['median']:8.2f}{s['p10']:7.2f}{s['p90']:7.2f}{s['max']:7.2f}"
              f"{st.fmean(p[7] for p in pts):6.0f}{st.fmean(p[9] for p in pts):6.0f}{st.fmean(p[8] for p in pts):6.0f}{(st.fmean(bat) if bat else 0):7.2f}")
    print()
print("* batW = BAT0 power_now, EC-smoothed over tens of seconds: only meaningful for idle and sustained phases.\n")
# ---------- whole-tier battery drain (energy_now counter, 10 mWh = 36 J resolution)
print("=== WHOLE-TIER VIEW  (battery Wh from BAT0 energy_now; SoC Wh from RAPL; 'rest' = screen, RAM, Wi-Fi, ...)")
print(f"{'tier':22}{'dur s':>7}{'BAT Wh':>8}{'BAT W':>7}{'SoC Wh':>8}{'SoC W':>7}{'rest W':>8}{'idle W':>8}{'sust W':>8}{'T0 C':>6}{'Tmax':>6}{'fanmax':>7}")
for t in tiers:
    ws = [w for w in win if w[2] == t]; ta, tb = min(w[0] for w in ws), max(w[1] for w in ws)
    pts = [p for p in P if ta <= p[0] < tb]
    if not pts: continue
    batwh = pts[0][6] - pts[-1][6]; dur = tb - ta
    socwh = sum(p[2] * p[1] for p in pts) / 3600
    idle = tier_rows.get((t, "idle"), {}).get("mean", float("nan")); sus = tier_rows.get((t, "sustained40s"), {}).get("mean", float("nan"))
    print(f"{t:22}{dur:7.0f}{batwh:8.3f}{batwh*3600/dur:7.2f}{socwh:8.3f}{socwh*3600/dur:7.2f}{(batwh-socwh)*3600/dur:8.2f}{idle:8.2f}{sus:8.2f}{pts[0][7]:6.0f}{max(p[7] for p in pts):6.0f}{max(p[9] for p in pts):7.0f}")
print()
# ---------- task table (best of 2)
def batJ(a, b):
    return sum(p[5] * p[1] for p in P if a <= p[0] < b)
d = {}
for r in tasks:
    tier, name, sec, ta, tb, socj, work = r[0], r[1], float(r[2]), float(r[3]), float(r[4]), float(r[5]), float(r[6])
    d[(tier, name)] = (sec, socj, work)
short = [k for k in dict.fromkeys(r[1] for r in tasks) if k != "sustained40s"]
base = next((t for t in tiers if t.startswith('fw')), tiers[-1])   # ratios vs the current battery caps
print("=== SHORT TASKS (pdf / office / python / zstd), best of 2 — SoC joules is what the cap controls")
print(f"{'tier':22}{'total s':>9}{'SoC J':>8}{'slow':>7}{'energy':>8}   per task s")
for t in tiers:
    if not all((t, k) in d for k in short): continue
    T = sum(d[(t, k)][0] for k in short); J = sum(d[(t, k)][1] for k in short)
    T0 = sum(d[(base, k)][0] for k in short); J0 = sum(d[(base, k)][1] for k in short)
    print(f"{t:22}{T:9.1f}{J:8.0f}{T/T0:6.2f}x{J/J0:7.2f}x   " + " / ".join(f"{d[(t,k)][0]:.1f}" for k in short))
print("\n=== SUSTAINED 40 s all-core zstd (base vs boost shows here)")
print(f"{'tier':22}{'MB':>7}{'MB/s':>7}{'SoC W':>7}{'SoC J/GB':>10}{'median W':>10}{'p90 W':>8}")
for t in tiers:
    if (t, "sustained40s") not in d: continue
    sec, socj, mb = d[(t, "sustained40s")]; s = tier_rows.get((t, "sustained40s"), {})
    print(f"{t:22}{mb:7.0f}{mb/sec:7.1f}{socj/sec:7.2f}{socj/mb*1024:10.0f}{s.get('median',0):10.2f}{s.get('p90',0):8.2f}")
# ---------- chart (PIL only; no matplotlib on this machine)
try:
    from PIL import Image, ImageDraw, ImageFont
    Wd, Hd, L, R, T, B = 2000, 700, 70, 20, 30, 90
    im = Image.new("RGB", (Wd, Hd), (255, 255, 255)); dr = ImageDraw.Draw(im); fn = ImageFont.load_default()
    tmax = P[-1][0] - t0; ymax = max(2.0, max(p[2] for p in P) * 1.05)
    X = lambda t: L + (t - t0) / tmax * (Wd - L - R); Y = lambda w: Hd - B - w / ymax * (Hd - T - B)
    for i, t in enumerate(tiers):
        ws = [w for w in win if w[2] == t]; a, b = min(w[0] for w in ws), max(w[1] for w in ws)
        dr.rectangle([X(a), T, X(b), Hd - B], fill=(240, 240, 250) if i % 2 else (252, 252, 252))
        dr.text((X(a) + 2, Hd - B + 4 + (i % 2) * 12), t, fill=(0, 0, 0), font=fn)
    for w in win:
        if w[3] == "sustained40s": dr.rectangle([X(w[0]), T, X(w[1]), T + 6], fill=(255, 200, 120))
        if w[3] == "idle": dr.rectangle([X(w[0]), T, X(w[1]), T + 6], fill=(160, 220, 160))
    g = 1 if ymax <= 12 else 2 if ymax <= 30 else 5
    for w in range(0, int(ymax) + 1, g):
        dr.line([L, Y(w), Wd - R, Y(w)], fill=(225, 225, 225)); dr.text((4, Y(w) - 5), f"{w} W", fill=(0, 0, 0), font=fn)
    dr.line([(X(p[0]), Y(min(p[5], ymax))) for p in P if p[5] > 0] or [(0, 0), (0, 0)], fill=(200, 120, 0), width=1)
    dr.line([(X(p[0]), Y(min(p[2], ymax))) for p in P], fill=(30, 80, 200), width=1)
    dr.text((L, 8), "blue = SoC W (RAPL)   orange = battery power_now W (EC-smoothed)   green bar = idle   orange bar = sustained;  x = seconds", fill=(0, 0, 0), font=fn)
    for s in range(0, int(tmax) + 1, 120): dr.text((X(t0 + s), Hd - B + 30), str(s), fill=(90, 90, 90), font=fn)
    im.save(prefix + ".png"); print(f"\nchart: {prefix}.png")
except Exception as e: print("chart skipped:", e)
print(f"time series: {prefix}.timeseries.csv")
