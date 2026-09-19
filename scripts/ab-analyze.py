#!/usr/bin/env python3
"""Paired analysis of an interleaved A/B/C profile test (step14d): per condition medians/IQR/means, and per-round paired
differences against the first condition with bootstrap 95 % CIs and win counts.  python3 ab-analyze.py logs/ab-<stamp>"""
import sys, os, random, statistics as st
prefix = sys.argv[1]; BASE = sys.argv[2] if len(sys.argv) > 2 else "saver"
EMAX = int(open(prefix + ".emax").read()) if os.path.exists(prefix + ".emax") else 2**32
tasks = [l.rstrip("\n").split("\t") for l in open(prefix + ".tasks.tsv")][1:]
S = []
for l in open(prefix + ".samples.tsv"):
    p = l.split()
    if len(p) in (9, 10):
        try: S.append([float(p[0])] + [int(x) for x in p[1:]] + ([0] if len(p) == 9 else []))
        except ValueError: pass
marks = [(float(a), b, c) for a, b, c in (l.rstrip("\n").split("\t") for l in open(prefix + ".marks.tsv") if l.count("\t") == 2)]
bursts = {}
if os.path.exists(prefix + ".bursts.tsv"):
    for l in open(prefix + ".bursts.tsv"):
        k, v = l.rstrip("\n").split("\t"); bursts[k] = [float(x) for x in v.split()]
P = []
for a, b in zip(S, S[1:]):
    dt = b[0] - a[0]
    if dt <= 0.05: continue
    P.append((a[0], dt, ((b[1] - a[1]) % EMAX) / 1e6 / dt, b[5] / 1e6, b[7] / 1000, b[8] / 1000, b[0]))
win = []
for i, (t, tier, phase) in enumerate(marks):
    tend = marks[i + 1][0] if i + 1 < len(marks) else S[-1][0]
    win.append((t, tend, tier, phase))
def pts(w): return [p for p in P if w[0] <= p[0] and p[6] <= w[1]]
labels = list(dict.fromkeys(r[0] for r in tasks))                # cond#rN
conds = list(dict.fromkeys(l.split("#")[0] for l in labels)); rounds = sorted({int(l.split("#r")[1]) for l in labels})
if BASE not in conds: BASE = conds[0]
# ---------- metrics per trial  (lower is better unless noted)
M = {}   # (cond, round) -> {metric: value}
for lab in labels:
    cond, rd = lab.split("#r"); rd = int(rd); m = {}
    ws = [w for w in win if w[2] == lab]
    idle = [p[2] for w in ws if w[3] == "idle" for p in pts(w)]
    if idle: m["idle SoC W"] = st.fmean(idle)
    for r in tasks:
        if r[0] != lab: continue
        name, sec, j, work = r[1], float(r[2]), float(r[5]), float(r[6])
        if name == "bursty":
            m["burst J/burst"] = j / work
            b = bursts.get(lab, [])
            if b: m["burst latency ms (median)"] = st.median(b); m["burst latency ms (p95)"] = sorted(b)[min(len(b) - 1, int(round(0.95 * (len(b) - 1))))]
        elif name.startswith("sustained"):
            m["sustained MB/s (higher=better)"] = work / sec; m["sustained SoC J/GB"] = j / work * 1024; m["sustained SoC W"] = j / sec
        else:
            m[f"{name} J"] = j; m[f"{name} s"] = sec
    tp = [p for w in ws for p in pts(w)]
    if tp:
        ta, tb = min(w[0] for w in ws), max(w[1] for w in ws); allp = [p for p in P if ta <= p[0] < tb]
        m["trial SoC Wh"] = sum(p[2] * p[1] for p in allp) / 3600
        m["trial battery Wh (36 J steps)"] = allp[0][3] - allp[-1][3]
        m["trial s"] = tb - ta; m["trial temp max C"] = max(p[4] for p in allp); m["trial mean MHz"] = st.fmean(p[5] for p in allp)
    M[(cond, rd)] = m
metrics = list(dict.fromkeys(k for m in M.values() for k in m))
HIGHER = {"sustained MB/s (higher=better)"}
def q(v, f): v = sorted(v); return v[min(len(v) - 1, int(round(f * (len(v) - 1))))]
def boot_ci(diffs, n=10000, seed=1):
    rnd = random.Random(seed); meds = []
    for _ in range(n): meds.append(st.median(rnd.choices(diffs, k=len(diffs))))
    meds.sort(); return meds[int(0.025 * n)], meds[int(0.975 * n)]
print(f"=== PER-CONDITION SUMMARY  ({len(rounds)} rounds, interleaved; median [p25..p75], mean)")
print(f"{'metric':34}" + "".join(f"{c:>30}" for c in conds))
for k in metrics:
    row = f"{k:34}"
    for c in conds:
        v = [M[(c, r)][k] for r in rounds if (c, r) in M and k in M[(c, r)]]
        dp = 3 if v and max(abs(x) for x in v) < 1 else 2
        row += f"{st.median(v):9.{dp}f} [{q(v,.25):7.{dp}f}..{q(v,.75):7.{dp}f}] {st.fmean(v):7.{dp}f}" if v else f"{'-':>30}"
    print(row)
print(f"\n=== PAIRED DIFFERENCES vs {BASE}  (same round, cond - {BASE}; negative = less/lower than {BASE}; 'wins' = rounds where cond is better)")
print(f"{'metric':34}" + "".join(f"{c:>34}" for c in conds if c != BASE))
print(f"{'':34}" + "".join(f"{'median diff  [95% boot CI]  wins':>34}" for c in conds if c != BASE))
verdict = {c: [] for c in conds if c != BASE}
for k in metrics:
    row = f"{k:34}"
    for c in conds:
        if c == BASE: continue
        d = [M[(c, r)][k] - M[(BASE, r)][k] for r in rounds if (c, r) in M and (BASE, r) in M and k in M[(c, r)] and k in M[(BASE, r)]]
        if len(d) < 2: row += f"{'-':>34}"; continue
        lo, hi = boot_ci(d); better = sum(1 for x in d if (x > 0) == (k in HIGHER) and x != 0)
        sig = "*" if (lo > 0 or hi < 0) else " "
        dp = 3 if max(abs(x) for x in d) < 1 else 2
        row += f"{st.median(d):+9.{dp}f} [{lo:+8.{dp}f}..{hi:+8.{dp}f}] {better:2d}/{len(d)}{sig}"
        if sig == "*": verdict[c].append((k, st.median(d), better, len(d)))
    print(row)
print("\n* = 95 % bootstrap CI of the median paired difference excludes zero (a real, consistent difference at this sample size)")
print("\n=== VERDICT (differences that are consistent across rounds)")
for c, items in verdict.items():
    if not items: print(f"{c}: no consistent difference vs {BASE} on any metric"); continue
    print(f"{c} vs {BASE}:")
    for k, d, b, n in items:
        base_med = st.median([M[(BASE, r)][k] for r in rounds if (BASE, r) in M and k in M[(BASE, r)]])
        print(f"   {k:34} {d:+8.2f}  ({d/base_med*100:+5.1f} %)  better in {b}/{n} rounds")
print("\nRead: energy metrics (J, Wh, W) decide battery life; time/latency metrics decide how it feels. A profile is 'worth it' only if it")
print("wins on time/latency WITHOUT a consistent energy loss, or wins on energy without a consistent latency loss.")
