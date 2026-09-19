#!/usr/bin/env python3
"""Energy per unit of work vs package cap, per workload, median over passes; SoC-only and whole-laptop views;
flat-region ("within X % of the minimum") logic to pick the lowest cap that is not measurably worse.
    python3 inflection-analyze.py logs/inflection-<stamp> [tolerance_percent=3]"""
import sys, os, statistics as st
pfx = sys.argv[1]; TOL = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
EMAX = int(open(pfx + ".emax").read()) if os.path.exists(pfx + ".emax") else 2**32
tasks = [l.rstrip("\n").split("\t") for l in open(pfx + ".tasks.tsv")][1:]
S = [l.split() for l in open(pfx + ".samples.tsv")]; S = [[float(p[0])] + [int(x) for x in p[1:]] for p in S if len(p) >= 10]
marks = [(float(a), b, c) for a, b, c in (l.rstrip("\n").split("\t") for l in open(pfx + ".marks.tsv") if l.count("\t") == 2)]
# ---- rest-of-system power: whole-run battery energy minus whole-run SoC energy (energy_now resolution is fine over ~40 min)
def soc_wh(a, b):
    pts = [s for s in S if a <= s[0] <= b]; return sum(((y[1] - x[1]) % EMAX) for x, y in zip(pts, pts[1:])) / 1e6 / 3600 if len(pts) > 1 else 0
ta, tb = S[0][0], S[-1][0]; bat_wh = (S[0][5] - S[-1][5]) / 1e6; s_wh = soc_wh(ta, tb); dur_h = (tb - ta) / 3600
rest_w = (bat_wh - s_wh) / dur_h if dur_h > 0 else 0
idle = []
for i, (t, tier, ph) in enumerate(marks):
    if ph == "idle":
        te = marks[i + 1][0] if i + 1 < len(marks) else t + 10
        pts = [s for s in S if t <= s[0] <= te]
        if len(pts) > 2: idle.append(((pts[-1][1] - pts[0][1]) % EMAX) / 1e6 / (pts[-1][0] - pts[0][0]))
print(f"run: {dur_h*60:.0f} min, battery {bat_wh:.2f} Wh, SoC {s_wh:.2f} Wh -> rest-of-system {rest_w:.2f} W (panel/RAM/Wi-Fi), idle SoC {st.median(idle) if idle else 0:.2f} W")
# ---- per cap x workload: J per job (SoC) and time; whole-laptop J = SoC J + rest_w * t
D = {}
for r in tasks:
    tier, name, sec, j, work = r[0], r[1], float(r[2]), float(r[5]), float(r[6])
    cap = float(tier.split("W#")[0]); D.setdefault(name, {}).setdefault(cap, []).append((sec, j))
names = list(D); caps = sorted({c for n in D for c in D[n]})
def med(v): return st.median(v)
print(f"\n=== SoC ENERGY PER JOB (J, median of passes; [min..max] spread) — lower is better")
print(f"{'cap W':>6} " + "".join(f"{n:>22}" for n in names))
for c in caps:
    row = f"{c:6.1f} "
    for n in names:
        v = [j for _, j in D[n].get(c, [])]; row += f"{med(v):9.1f} [{min(v):6.1f}..{max(v):6.1f}]" if v else f"{'-':>22}"
    print(row)
print(f"\n=== TIME PER JOB (s, median)")
print(f"{'cap W':>6} " + "".join(f"{n:>10}" for n in names))
for c in caps: print(f"{c:6.1f} " + "".join(f"{med([s for s, _ in D[n][c]]):10.2f}" if c in D[n] else f"{'-':>10}" for n in names))
print(f"\n=== WHOLE-LAPTOP ENERGY PER JOB (J = SoC J + {rest_w:.2f} W x time; the view where finishing faster also saves screen energy)")
print(f"{'cap W':>6} " + "".join(f"{n:>10}" for n in names))
WL = {n: {c: med([j + rest_w * s for s, j in D[n][c]]) for c in D[n]} for n in names}
for c in caps: print(f"{c:6.1f} " + "".join(f"{WL[n][c]:10.1f}" if c in WL[n] else f"{'-':>10}" for n in names))
# ---- verdicts
def verdict(table, label):
    print(f"\n=== {label}: minimum and lowest cap within {TOL:.0f} % of it, per workload")
    picks = []
    for n in names:
        m = {c: table[n][c] for c in table[n]}; cmin = min(m, key=m.get); vmin = m[cmin]
        flat = [c for c in sorted(m) if m[c] <= vmin * (1 + TOL / 100)]
        picks.append(flat[0]); print(f"  {n:10} min at {cmin:4.1f} W ({vmin:.1f} J); flat region {flat[0]:.1f}–{flat[-1]:.1f} W -> lowest acceptable {flat[0]:.1f} W")
    agg = {c: st.fmean(table[n][c] / min(table[n].values()) for n in names if c in table[n]) for c in caps}
    cbest = min(agg, key=agg.get); flat = [c for c in sorted(agg) if agg[c] <= agg[cbest] * (1 + TOL / 100)]
    print(f"  ALL (mean normalised J/job): best {cbest:.1f} W, flat region {flat[0]:.1f}–{flat[-1]:.1f} W -> recommended cap {flat[0]:.1f} W")
    print("  normalised: " + "  ".join(f"{c:g}W={agg[c]:.3f}" for c in caps))
    return flat[0]
soc_pick = verdict({n: {c: med([j for _, j in D[n][c]]) for c in D[n]} for n in names}, "SoC-ONLY (screen on anyway while the job runs)")
wl_pick = verdict(WL, "WHOLE-LAPTOP (the job is the reason the laptop is on)")
print(f"\nSUMMARY: SoC-only optimum {soc_pick:.1f} W; whole-laptop optimum {wl_pick:.1f} W. Pick by use-case: background/while-working -> SoC-only; batch-then-sleep -> whole-laptop.")
# ---- figure (optional)
try:
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    fig, axs = plt.subplots(1, 2, figsize=(11, 4.2))
    for ax, table, ttl in ((axs[0], {n: {c: med([j for _, j in D[n][c]]) for c in D[n]} for n in names}, "SoC energy per job (normalised to each workload's minimum)"), (axs[1], WL, f"Whole-laptop energy per job (+{rest_w:.1f} W rest-of-system)")):
        for n in names:
            cs = sorted(table[n]); vmin = min(table[n].values()); ax.plot(cs, [table[n][c] / vmin for c in cs], "-o", ms=4, label=n)
        ax.axhline(1 + TOL / 100, color="grey", ls="--", lw=1); ax.set_xlabel("package cap PL1 = PL2 (W)"); ax.set_ylabel("J per job / minimum"); ax.set_title(ttl, fontsize=10); ax.grid(alpha=.3); ax.legend(fontsize=8)
    fig.tight_layout(); fig.savefig(pfx + ".png", dpi=160); print(f"figure: {pfx}.png")
except Exception as e: print("figure skipped:", e)
