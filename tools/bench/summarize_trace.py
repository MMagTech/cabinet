#!/usr/bin/env python3
"""Read a FrameTrace CSV off a device run and say whether the core held
realtime and how much of the frame budget it used.

The numbers that matter, and why these and not an average:
  - core ms percentiles, because a mean over a session hides the scenes that
    actually cost something (the Flycast investigation learned this the hard
    way on load screens).
  - audio frames per emulated second against the core's declared rate, which
    is the only direct read on whether emulation itself kept up.
  - budget use, core+upload against one frame at the core's declared fps.
  - worst thermal state seen, so a slow run is not misread as a slow build.
"""
import csv, sys, statistics

def load(path):
    rows, meta = [], {}
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                for part in line[1:].split():
                    if "=" in part:
                        k, v = part.split("=", 1)
                        meta[k] = v
                continue
            head = line
            break
        r = csv.DictReader(f, fieldnames=head.strip().split(","))
        for row in r:
            try:
                rows.append({k: float(v) for k, v in row.items() if v is not None})
            except (TypeError, ValueError):
                pass
    return meta, rows

def pct(vals, p):
    if not vals: return 0.0
    s = sorted(vals)
    return s[min(len(s) - 1, int(len(s) * p))]

def main(path, label=None):
    meta, rows = load(path)
    if not rows:
        print(f"{label or path}: NO ROWS (run never reached the player)")
        return
    # Drop the first second: texture allocation and the core's own first
    # frames are not the workload.
    rows = [r for r in rows if r.get("elapsed_ms", 0) > 1000] or rows
    run = [r["run_ms"] for r in rows]
    upload = [r.get("upload_ms", 0) for r in rows]
    total = [r["run_ms"] + r.get("upload_ms", 0) for r in rows]
    fps = rows[-1].get("target_fps") or 60.0
    budget = 1000.0 / fps
    span_s = (rows[-1]["elapsed_ms"] - rows[0]["elapsed_ms"]) / 1000.0
    audio = rows[-1].get("audio_frames", 0) - rows[0].get("audio_frames", 0)
    rate = float(meta.get("sample_rate", 44100) or 44100)
    thermal = max(int(r.get("thermal", 0)) for r in rows)
    w = int(rows[-1].get("frame_w", 0)); h = int(rows[-1].get("frame_h", 0))
    print(f"{label or path}")
    print(f"   frames {len(rows):5d}  span {span_s:5.1f}s  budget {budget:5.2f}ms  {w}x{h}"
          f"  thermal {thermal}")
    print(f"   core ms   median {statistics.median(run):6.3f}  p95 {pct(run,0.95):6.3f}"
          f"  p99 {pct(run,0.99):6.3f}")
    print(f"   upload ms median {statistics.median(upload):6.3f}  p95 {pct(upload,0.95):6.3f}")
    print(f"   budget    median {statistics.median(total)/budget*100:5.1f}%"
          f"  p95 {pct(total,0.95)/budget*100:5.1f}%  p99 {pct(total,0.99)/budget*100:5.1f}%")
    if span_s > 0:
        print(f"   audio     {audio/span_s:8.0f}/s vs {rate:.0f} declared"
              f"  ratio {audio/span_s/rate:.3f}")

if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
        print()
