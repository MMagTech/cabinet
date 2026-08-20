#!/usr/bin/env python3
"""Split a FrameTrace by frame size. A core that changes resolution mid-game
(SNES Mode 7, N64) has two different costs and one average hides both."""
import csv, sys, statistics, collections

def pct(v, p):
    s = sorted(v)
    return s[min(len(s) - 1, int(len(s) * p))] if s else 0.0

for path in sys.argv[1:]:
    rows = []
    with open(path) as f:
        for line in f:
            if line.startswith("#"): continue
            head = line; break
        for r in csv.DictReader(f, fieldnames=head.strip().split(",")):
            try: rows.append({k: float(v) for k, v in r.items() if v is not None})
            except (TypeError, ValueError): pass
    groups = collections.defaultdict(list)
    for r in rows:
        groups[(int(r.get("frame_w", 0)), int(r.get("frame_h", 0)))].append(r)
    fps = rows[-1].get("target_fps", 60.0) if rows else 60.0
    budget = 1000.0 / fps
    print(f"{path}   budget {budget:.2f}ms")
    for (w, h), g in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        core = [r["run_ms"] for r in g]
        up = [r.get("upload_ms", 0) for r in g]
        tot = [r["run_ms"] + r.get("upload_ms", 0) for r in g]
        print(f"   {w:5d}x{h:<4d} {len(g):6d} frames ({len(g)*100//max(len(rows),1):3d}%)"
              f"  core {statistics.median(core):6.3f}  upload {statistics.median(up):6.3f}"
              f"  total p95 {pct(tot,0.95):6.3f} = {pct(tot,0.95)/budget*100:5.1f}% of budget")
