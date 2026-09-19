#!/usr/bin/env python3
"""Tabulate Geekbench runs from step60: scores + result URLs from the .<mode>.cpu.txt files, power/temperature from the
2 Hz telemetry (ladder-analyze's timeseries), one row per configuration.  Writes <prefix>.md too.
    python3 bench-tabulate.py logs/geekbench-<stamp>"""
import sys, os, re, glob, csv, statistics as st
pfx = sys.argv[1]
rows = list(csv.DictReader(open(pfx + ".timeseries.csv"))) if os.path.exists(pfx + ".timeseries.csv") else []
rb = {}
if os.path.exists(pfx + ".readback.txt"):
    for l in open(pfx + ".readback.txt"):
        k, v = l.rstrip("\n").split("\t", 1); rb[k] = v
tasks = [l.rstrip("\n").split("\t") for l in open(pfx + ".tasks.tsv")][1:] if os.path.exists(pfx + ".tasks.tsv") else []
out = []
ORDER = ["battery6", "ac", "performance"]
def key(f): m = f[len(pfx) + 1:-8]; t = next((float(r[3]) for r in tasks if r[0] == m), None); return (0, t) if t is not None else (1, ORDER.index(m) if m in ORDER else 9)
for f in sorted(glob.glob(pfx + ".*.cpu.txt"), key=key):   # run order (battery6 -> ac -> performance), first row = baseline
    mode = f[len(pfx) + 1:-8]; txt = open(f, errors="replace").read()
    def score(label):
        m = re.search(label + r"\s+Score\s+(\d+)", txt); return int(m.group(1)) if m else None
    sc, mc = score("Single-Core"), score("Multi-Core")
    url = next(iter(re.findall(r"https://browser\.geekbench\.com/v6/cpu/\d+", txt)), "")
    # the free CLI prints no scores locally (they are on the result page, behind a bot check): a sidecar
    # <prefix>.<mode>.scores.txt with "single=NNNN multi=NNNN" (copied from the page) fills them in
    side = f"{pfx}.{mode}.scores.txt"
    if os.path.exists(side):
        st_ = open(side).read(); m1 = re.search(r"single\s*=\s*(\d+)", st_); m2 = re.search(r"multi\s*=\s*(\d+)", st_)
        sc = int(m1.group(1)) if m1 else sc; mc = int(m2.group(1)) if m2 else mc
    ph = [r for r in rows if r["tier"] == mode and r["phase"] == "geekbench_cpu"]
    idle = [float(r["soc_w"]) for r in rows if r["tier"] == mode and r["phase"] == "idle"]
    w = [float(r["soc_w"]) for r in ph]; temp = [float(r["pkg_temp_c"]) for r in ph]; fan = [float(r["fan_rpm"]) for r in ph]
    t = next((r for r in tasks if r[0] == mode and r[1] == "geekbench_cpu"), None)
    sec = float(t[2]) if t else 0; joules = float(t[5]) if t else 0
    r = rb.get(mode, "")
    def field(k): m = re.search(k + r"=(\S+)", r); return m.group(1) if m else ""
    out.append(dict(mode=mode, adapter=field("adapter"), profile=field("profile"), epp=field("epp"), cap=field("msr"), gpu=field("gpu_max"),
                    single=sc, multi=mc, url=url, sec=sec, wh=joules / 3600,
                    w_mean=st.fmean(w) if w else 0, w_med=st.median(w) if w else 0, w_max=max(w) if w else 0,
                    idle=st.fmean(idle) if idle else 0, tmax=max(temp) if temp else 0, fanmax=max(fan) if fan else 0))
if not out: sys.exit("no geekbench result files found")
base = out[0]
hdr = f"{'config':12}{'adapter':9}{'profile':13}{'EPP':20}{'cap W':7}{'single':>8}{'multi':>8}{'run s':>7}{'SoC W mean/med/max':>22}{'Wh/run':>8}{'idle W':>8}{'Tmax':>6}{'fan':>6}"
print("=== GEEKBENCH 6.7.1 CPU — HP OmniBook X Flip 16 (Core Ultra 9 288V), Ubuntu 26.04, kernel " + os.uname().release)
print(hdr)
for o in out:
    print(f"{o['mode']:12}{o['adapter']:9}{o['profile']:13}{o['epp']:20}{o['cap']:7}{o['single'] or 0:8d}{o['multi'] or 0:8d}{o['sec']:7.0f}"
          f"{o['w_mean']:8.2f}/{o['w_med']:5.2f}/{o['w_max']:6.2f}{o['wh']:8.3f}{o['idle']:8.2f}{o['tmax']:6.0f}{o['fanmax']:6.0f}")
print("\nrelative to the first row:")
for o in out:
    s = o["single"] / base["single"] if o["single"] and base["single"] else 0; m = o["multi"] / base["multi"] if o["multi"] and base["multi"] else 0
    e = o["wh"] / base["wh"] if base["wh"] else 0; ppw = (o["multi"] or 0) / o["w_mean"] if o["w_mean"] else 0
    print(f"  {o['mode']:12} single {s:5.2f}x  multi {m:5.2f}x  energy/run {e:5.2f}x  multi-score per SoC watt {ppw:7.0f}")
print("\nresult URLs (public):"); [print(f"  {o['mode']:12} {o['url']}") for o in out]
with open(pfx + ".md", "w") as f:
    f.write("| config | adapter | profile | EPP | cap (W) | single | multi | run (s) | SoC W mean | SoC W max | Wh/run | idle W | pkg Tmax | fan rpm | result |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n")
    for o in out:
        f.write(f"| {o['mode']} | {o['adapter']} | {o['profile']} | {o['epp']} | {o['cap']} | {o['single']} | {o['multi']} | {o['sec']:.0f} | {o['w_mean']:.2f} | {o['w_max']:.2f} | {o['wh']:.3f} | {o['idle']:.2f} | {o['tmax']:.0f} | {o['fanmax']:.0f} | {o['url']} |\n")
print(f"\nmarkdown table: {pfx}.md")
