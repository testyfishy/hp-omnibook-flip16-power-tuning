#!/usr/bin/env python3
"""Summary figures for the README, generated from the files in results/.  Needs matplotlib.
    python3 scripts/make-figures.py            (writes results/figures/fig*.png + .svg)"""
import csv, os, re, sys, statistics as st
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
RES = os.path.join(ROOT, "results"); OUT = os.path.join(RES, "figures"); os.makedirs(OUT, exist_ok=True)
plt.rcParams.update({"font.size": 10, "axes.spines.top": False, "axes.spines.right": False, "figure.dpi": 150, "savefig.dpi": 200,
                     "axes.grid": True, "grid.alpha": 0.25, "axes.titleweight": "bold", "axes.titlesize": 11})
BLUE, ORANGE, GREEN, GREY, RED = "#2b6cb0", "#dd6b20", "#2f855a", "#718096", "#c53030"
def save(fig, name):
    fig.tight_layout(); fig.savefig(os.path.join(OUT, name + ".png")); fig.savefig(os.path.join(OUT, name + ".svg")); plt.close(fig); print("wrote", name)

# ---------- data: battery ladder
LAD = os.path.join(RES, "02-battery-ladder", "ladder2-20260918-2258")
tasks = [l.rstrip("\n").split("\t") for l in open(LAD + ".tasks.tsv")][1:]
def tier_label(t): return t.split("(")[0]
sust = {tier_label(r[0]): (float(r[2]), float(r[5]), float(r[6])) for r in tasks if r[1] == "sustained40s"}   # sec, J, MB
short = {}
for r in tasks:
    if r[1] != "sustained40s": short.setdefault(tier_label(r[0]), {})[r[1]] = (float(r[2]), float(r[5]))
equal = ["4/4", "5/5", "6/6", "8/8", "10/10", "12/12", "fw"]
xlab = {"fw": "stock\n12/21"}

# ---------- Fig 1: efficiency vs cap
fig, ax = plt.subplots(figsize=(7, 3.8))
x = list(range(len(equal))); jgb = [sust[t][1] / sust[t][2] * 1024 for t in equal]; mbs = [sust[t][2] / sust[t][0] for t in equal]
ax.plot(x, jgb, "-o", color=BLUE, lw=2.2, ms=6, label="energy per GB compressed (J/GB, lower = better)")
i6 = equal.index("6/6"); ax.annotate("inflection point\n6 W: 149 J/GB", (i6, jgb[i6]), xytext=(i6 + 0.9, 144), color=BLUE,
                                     arrowprops=dict(arrowstyle="->", color=BLUE), fontsize=9, fontweight="bold")
ax.set_ylabel("SoC energy per GB (J)", color=BLUE); ax.set_ylim(140, 190)
ax2 = ax.twinx(); ax2.plot(x, mbs, "--s", color=GREY, lw=1.4, ms=4, label="throughput (MB/s)"); ax2.set_ylabel("throughput (MB/s)", color=GREY); ax2.set_ylim(0, 80); ax2.grid(False)
ax.set_xticks(x); ax.set_xticklabels([xlab.get(t, t) for t in equal]); ax.set_xlabel("package power cap PL1/PL2 (W), on battery")
ax.set_title("Sustained all-core work: efficiency peaks at a 6 W cap")
h1, l1 = ax.get_legend_handles_labels(); h2, l2 = ax2.get_legend_handles_labels(); ax.legend(h1 + h2, l1 + l2, loc="upper center", fontsize=8.5, frameon=False)
save(fig, "fig1-efficiency-vs-cap")

# ---------- Fig 2: daily tasks vs cap (time), showing the EPP outlier
fig, ax = plt.subplots(figsize=(7, 3.8))
names = [("pdf_render", "PDF render (40 pages)"), ("office", "office docx→pdf"), ("python", "python job"), ("compress", "zstd 250 MB (all-core)")]
cols = [BLUE, GREEN, ORANGE, GREY]
tiers2 = ["4/4", "5/5", "6/6", "8/8", "10/10", "12/12", "fw"]; x = list(range(len(tiers2)))
for (k, lab), c in zip(names, cols):
    ax.plot(x, [short[t][k][0] for t in tiers2], "-o", color=c, lw=2, ms=5, label=lab)
bp = short["8/8@balance_power"]
for (k, lab), c in zip(names, cols):
    ax.plot([tiers2.index("8/8")], [bp[k][0]], marker="*", ms=13, color=c, mec="black", mew=0.6, ls="none")
ax.annotate("★ same 8 W cap, EPP balance_power\n(single-thread tasks 35–45 % faster)", (tiers2.index("8/8"), bp["pdf_render"][0]), xytext=(3.4, 12.2), fontsize=8.5,
            arrowprops=dict(arrowstyle="->", color="black"))
ax.set_xticks(x); ax.set_xticklabels([xlab.get(t, t) for t in tiers2]); ax.set_xlabel("package power cap PL1/PL2 (W), on battery"); ax.set_ylabel("task time (s), best of 2")
ax.set_title("Daily tasks are insensitive to the cap; the EPP is what throttles them"); ax.legend(fontsize=8.5, frameon=False, loc="center right"); ax.set_ylim(0, 17)
save(fig, "fig2-daily-tasks-vs-cap")

# ---------- Fig 3: profile comparison at 6 W (clean rounds)
AB = os.path.join(RES, "03-profile-ab", "ab-20260918-2356")
abt = [l.rstrip("\n").split("\t") for l in open(AB + ".tasks.tsv")][1:]
bursts = {}
for l in open(AB + ".bursts.tsv"):
    k, v = l.rstrip("\n").split("\t"); bursts[k] = [float(x) for x in v.split()]
CLEAN = {1, 4, 5, 6}
COND = [("saver", "stock Power Saver\n(EPP power)", GREY), ("balanced", "stock Balanced\n(EPP balance_performance)", ORANGE), ("saver+bp", "tuned Power Saver\n(EPP balance_power)  ← final", GREEN)]
def med(cond, task, col):
    v = [float(r[col]) for r in abt if r[0].split("#r")[0] == cond and int(r[0].split("#r")[1]) in CLEAN and r[1] == task]; return st.median(v)
def burst_lat(cond): return st.median([st.median(v) for k, v in bursts.items() if k.split("#r")[0] == cond and int(k.split("#r")[1]) in CLEAN])
fig, (a1, a2) = plt.subplots(1, 2, figsize=(9, 3.9))
tl = [("pdf_render", "PDF render"), ("office", "office"), ("python", "python"), ("compress", "zstd")]
w = 0.26
for i, (c, lab, col) in enumerate(COND):
    a1.bar([j + (i - 1) * w for j in range(4)], [med(c, k, 2) for k, _ in tl], w, color=col, label=lab)
    a2.bar([j + (i - 1) * w for j in range(4)], [med(c, k, 5) for k, _ in tl], w, color=col)
a1.set_xticks(range(4)); a1.set_xticklabels([l for _, l in tl]); a1.set_ylabel("time (s), median of 4 rounds"); a1.set_title("Time per task at the same 6 W cap")
a2.set_xticks(range(4)); a2.set_xticklabels([l for _, l in tl]); a2.set_ylabel("SoC energy (J), median of 4 rounds"); a2.set_title("Energy per task at the same 6 W cap")
lat = [burst_lat(c) for c, _, _ in COND]
a1.text(0.02, 0.97, "interactive burst latency:\n" + "\n".join(f"{l.splitlines()[0]}: {v:.0f} ms" for (c, l, _), v in zip(COND, lat)), transform=a1.transAxes, va="top", fontsize=8, bbox=dict(boxstyle="round", fc="white", ec=GREY, alpha=0.9))
a1.set_ylim(0, 20); a1.legend(fontsize=8, frameon=False, loc="upper right")
save(fig, "fig3-profiles-at-6w")

# ---------- Fig 4: stress verification power trace
ST = os.path.join(RES, "04-stress-verify", "stress-20260919-0511")
rows = list(csv.DictReader(open(ST + ".timeseries.csv")))
fig, ax = plt.subplots(figsize=(9, 3.6))
t = [float(r["t_s"]) for r in rows]; wv = [float(r["soc_w"]) for r in rows]
ax.plot(t, wv, color=BLUE, lw=1.1, label="SoC power (RAPL, 2 Hz)")
ax.axhline(6, color=RED, lw=1.2, ls="--", label="6 W cap")
labels = {"idle": "idle", "single": "single-\nthread", "allcore_zstd": "all-core zstd -19", "allcore_openssl": "all-core\nopenssl", "combined_cpu_gpu": "CPU + iGPU", "recovery": "recovery"}
cur = None; start = 0
for r in rows + [None]:
    ph = r["phase"] if r else None
    if ph != cur:
        if cur in labels:
            end = float(r["t_s"]) if r else t[-1]
            ax.axvspan(start, end, color=GREY if labels and list(labels).index(cur) % 2 else "white", alpha=0.08)
            ax.text((start + end) / 2, 7.6, labels[cur], ha="center", fontsize=8, color="black")
        cur = ph; start = float(r["t_s"]) if r else 0
ax.set_ylim(0, 8.3); ax.set_xlabel("seconds"); ax.set_ylabel("watts"); ax.set_title("Final policy under stress: the package never leaves 6 W (fan 0 rpm, max 49 °C)")
ax.legend(loc="center", bbox_to_anchor=(0.36, 0.3), fontsize=8.5, frameon=False)
save(fig, "fig4-stress-trace")

# ---------- Fig 0: idle walk-down
fig, ax = plt.subplots(figsize=(7, 3.2))
steps = [("Firefox + chat app open,\npanel 120 Hz", 1.68), ("panel 48 Hz", 1.38), ("Firefox frozen\n(animated tab)", 1.02), ("everything quiet", 0.53)]
ax.barh(range(len(steps))[::-1], [v for _, v in steps], color=[GREY, ORANGE, ORANGE, GREEN])
for i, (_, v) in enumerate(steps): ax.text(v + 0.03, len(steps) - 1 - i, f"{v:.2f} W", va="center", fontsize=9)
ax.set_yticks(range(len(steps))[::-1]); ax.set_yticklabels([l for l, _ in steps]); ax.set_xlabel("SoC power at idle (W), screen on, battery"); ax.set_xlim(0, 2.0)
ax.set_title("Idle: what the SoC costs before any cap matters")
save(fig, "fig0-idle-walkdown")

# ---------- Fig 5: Geekbench across the three power configurations
GBMD = os.path.join(RES, "05-geekbench", "geekbench-20260919-0556.md")
if os.path.exists(GBMD):
    rows = [l.split("|")[1:-1] for l in open(GBMD) if l.startswith("| ") and not l.startswith("| config")]
    rows = [[c.strip() for c in r] for r in rows]
    names = {"battery6": "battery\n6 W cap\ntuned Power Saver", "ac": "plugged in\n30/37 W\nstock Balanced", "performance": "plugged in\n30/37 W\nPerformance"}
    labs = [names.get(r[0], r[0]) for r in rows]; single = [int(r[5]) for r in rows]; multi = [int(r[6]) for r in rows]
    wmean = [float(r[8]) for r in rows]; wh = [float(r[10]) for r in rows]
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(10.5, 4.2), gridspec_kw={"width_ratios": [1.25, 1]})
    x = list(range(len(rows))); w = 0.38
    b1 = a1.bar([i - w / 2 for i in x], single, w, color=BLUE, label="single-core score"); b2 = a1.bar([i + w / 2 for i in x], multi, w, color=ORANGE, label="multi-core score")
    for b in list(b1) + list(b2): a1.text(b.get_x() + b.get_width() / 2, b.get_height() + 120, f"{int(b.get_height())}", ha="center", fontsize=8)
    a1.set_xticks(x); a1.set_xticklabels(labs, fontsize=8.5); a1.set_ylabel("Geekbench 6.7.1 score"); a1.set_ylim(0, 13500); a1.set_title("Score"); a1.legend(frameon=False, fontsize=8.5, loc="upper left")
    ppw = [m / p for m, p in zip(multi, wmean)]
    b3 = a2.bar(x, ppw, 0.5, color=[GREEN, GREY, GREY])
    for b, e in zip(b3, wh): a2.text(b.get_x() + b.get_width() / 2, b.get_height() + 25, f"{b.get_height():.0f}\n({e:.2f} Wh/run)", ha="center", fontsize=8)
    a2.set_xticks(x); a2.set_xticklabels(labs, fontsize=8.5); a2.set_ylabel("multi-core score per mean SoC watt"); a2.set_ylim(0, 1900); a2.set_title("Efficiency (higher = better)")
    save(fig, "fig5-geekbench")

# ---------- Fig 6: inflection re-test — aggregate curves and the time price
INF = os.path.join(RES, "06-inflection", "inflection-20260919-0634")
if os.path.exists(INF + ".tasks.tsv"):
    rows = [l.rstrip("\n").split("\t") for l in open(INF + ".tasks.tsv")][1:]
    rest = 4.0
    try: rest = float(re.search(r"rest-of-system ([0-9.]+) W", open(INF + ".summary.txt").read()).group(1))
    except Exception: pass
    D = {}
    for r in rows: D.setdefault(r[1], {}).setdefault(float(r[0].split("W#")[0]), []).append((float(r[2]), float(r[5])))
    caps = sorted({c for n in D for c in D[n]}); TOL = 0.03
    soc = {n: {c: st.median([j for _, j in D[n][c]]) for c in D[n]} for n in D}
    wl = {n: {c: st.median([j + rest * s for s, j in D[n][c]]) for c in D[n]} for n in D}
    def agg(table):
        sens = [n for n in table if max(table[n].values()) / min(table[n].values()) - 1 > TOL]
        return {c: st.fmean(table[n][c] / min(table[n].values()) for n in sens) for c in caps}, sens
    a_soc, s_soc = agg(soc); a_wl, s_wl = agg(wl)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(10.5, 4.0))
    for a, lab, col in ((a_soc, f"SoC-only (screen on anyway)\n{len(s_soc)} cap-sensitive jobs", BLUE), (a_wl, f"whole-laptop (+{rest:.1f} W × time)\n{len(s_wl)} all-core jobs", ORANGE)):
        m = min(a.values()); a1.plot(caps, [a[c] / m for c in caps], "-o", color=col, lw=2, ms=5, label=lab)
        flat = [c for c in caps if a[c] / m <= 1 + TOL]; a1.axvspan(flat[0], flat[-1], color=col, alpha=0.08)
    a1.axhline(1 + TOL, color=GREY, ls="--", lw=1); a1.text(caps[-1], 1 + TOL + 0.005, "3 % band", ha="right", fontsize=8, color=GREY)
    a1.axvline(6, color=GREEN, lw=1.5, ls=":"); a1.text(6.1, a1.get_ylim()[1] * 0.98 if False else 1.42, "6 W (installed)", color=GREEN, fontsize=8.5, va="top")
    a1.set_xlabel("package cap PL1 = PL2 (W)"); a1.set_ylabel("energy per job / best (mean over jobs)"); a1.set_ylim(0.98, 1.45)
    a1.set_title("Where the energy optimum sits, by accounting view"); a1.legend(fontsize=8, frameon=False, loc="upper right")
    for n, lab, col in (("zstd_mt", "zstd, all-core", BLUE), ("sha_mt", "sha3 ×8", ORANGE), ("pdf_mt", "PDF ×8 parallel", GREEN), ("pdf_st", "PDF single-thread", GREY)):
        t = {c: st.median([s for s, _ in D[n][c]]) for c in D[n]}; a2.plot(caps, [t[c] / t[12.0] for c in caps], "-o", color=col, lw=2, ms=4, label=lab)
    a2.axvline(6, color=GREEN, lw=1.5, ls=":"); a2.set_xlabel("package cap PL1 = PL2 (W)"); a2.set_ylabel("time per job / time at 12 W")
    a2.set_title("The price: how much longer a job takes"); a2.legend(fontsize=8, frameon=False)
    save(fig, "fig6-inflection-retest")

# ---------- Fig 7: profile comparison — paired differences with bootstrap CIs
if os.path.exists(AB + ".tasks.tsv"):
    import random
    rnd = random.Random(1)
    def per_round(cond, task, col):
        return {int(r[0].split("#r")[1]): float(r[col]) for r in abt if r[0].split("#r")[0] == cond and r[1] == task and int(r[0].split("#r")[1]) in CLEAN}
    def lat_round(cond): return {int(k.split("#r")[1]): st.median(v) for k, v in bursts.items() if k.split("#r")[0] == cond and int(k.split("#r")[1]) in CLEAN}
    metrics = [("PDF render time", "pdf_render", 2), ("office time", "office", 2), ("python time", "python", 2), ("zstd time", "compress", 2), ("burst latency", None, None),
               ("PDF render energy", "pdf_render", 5), ("office energy", "office", 5), ("python energy", "python", 5), ("zstd energy", "compress", 5), ("sustained power", "sustained20s", None)]
    fig, ax = plt.subplots(figsize=(8.5, 4.6))
    ys = list(range(len(metrics)))[::-1]
    for ci, (cond, lab, col) in enumerate([("balanced", "stock Balanced − stock Power Saver", ORANGE), ("saver+bp", "tuned Power Saver − stock Power Saver", GREEN)]):
        pts = []
        for (name, task, colidx) in metrics:
            if task is None: base, other = lat_round("saver"), lat_round(cond)
            elif name == "sustained power":
                b = per_round("saver", task, 5); bt = per_round("saver", task, 2); o = per_round(cond, task, 5); ot = per_round(cond, task, 2)
                base = {r: b[r] / bt[r] for r in b}; other = {r: o[r] / ot[r] for r in o}
            else: base, other = per_round("saver", task, colidx), per_round(cond, task, colidx)
            d = [(other[r] - base[r]) / base[r] * 100 for r in sorted(base) if r in other]
            meds = sorted(st.median(rnd.choices(d, k=len(d))) for _ in range(4000)); pts.append((st.median(d), meds[100], meds[3899]))
        off = 0.18 if ci == 0 else -0.18
        for y, (m, lo, hi) in zip(ys, pts):
            ax.plot([lo, hi], [y + off, y + off], color=col, lw=2.2, alpha=0.9); ax.plot(m, y + off, "o", color=col, ms=6, label=lab if y == ys[0] else None)
    ax.axvline(0, color="black", lw=1); ax.set_yticks(ys); ax.set_yticklabels([m[0] for m in metrics]); ax.set_xlabel("paired difference vs stock Power Saver (%), median of 4 rounds with 95 % bootstrap CI")
    ax.axhspan(4.5, 9.6, color=BLUE, alpha=0.05); ax.text(-46, 9.3, "speed / latency  (negative = faster)", fontsize=8.5, color=BLUE)
    ax.axhspan(-0.5, 4.5, color=RED, alpha=0.05); ax.text(-46, 4.2, "energy / power  (positive = costs more)", fontsize=8.5, color=RED)
    ax.set_xlim(-50, 25); ax.set_title("What changing only the EPP does at a fixed 6 W cap"); ax.legend(fontsize=8.5, frameon=True, loc="upper right")
    save(fig, "fig7-profile-paired-diffs")
