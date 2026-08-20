#!/usr/bin/env python3
"""Tabulate a stock-vs-tuned device sweep: one line per core, both sides."""
import glob, os, subprocess, sys, re

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/cabinet-bench"
HERE = os.path.dirname(os.path.abspath(__file__))

def summarize(path):
    p = subprocess.run([sys.executable, os.path.join(HERE, "summarize_trace.py"), path],
                       capture_output=True, text=True)
    t = p.stdout
    def grab(pat):
        m = re.search(pat, t)
        return float(m.group(1)) if m else None
    geo = re.search(r"(\d+x\d+)", t)
    return {
        "core_med": grab(r"core ms\s+median\s+([\d.]+)"),
        "core_p99": grab(r"p99\s+([\d.]+)"),
        "upload_med": grab(r"upload ms median\s+([\d.]+)"),
        "budget_med": grab(r"budget\s+median\s+([\d.]+)%"),
        "budget_p99": grab(r"p99\s+([\d.]+)%"),
        "audio": grab(r"ratio ([\d.]+)"),
        "geo": geo.group(1) if geo else "?",
        "rows": grab(r"frames\s+(\d+)"),
    }

labels = sorted({os.path.basename(f).rsplit("-", 1)[0] for f in glob.glob(OUT + "/*.csv")})
print(f"{'system':<22} {'geometry':>12} {'core ms':>16} {'budget med':>12} {'budget p99':>12} {'audio':>7}")
for label in labels:
    st = OUT + f"/{label}-stock.csv"
    tu = OUT + f"/{label}-tuned.csv"
    a = summarize(st) if os.path.exists(st) else None
    b = summarize(tu) if os.path.exists(tu) else None
    if not a or not b or a["core_med"] is None or b["core_med"] is None:
        print(f"{label:<22} incomplete")
        continue
    geo = a["geo"] if a["geo"] == b["geo"] else f"{a['geo']}->{b['geo']}"
    ratio = b["core_med"] / a["core_med"] if a["core_med"] else 0
    print(f"{label:<22} {geo:>12} {a['core_med']:6.3f}->{b['core_med']:6.3f} {ratio:4.2f}x"
          f" {a['budget_med']:5.1f}->{b['budget_med']:5.1f}% {a['budget_p99']:5.1f}->{b['budget_p99']:5.1f}%"
          f" {b['audio']:6.3f}")
