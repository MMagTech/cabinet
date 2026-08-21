#!/usr/bin/env python3
"""Judge a controller-link probe run. See RommApp/RommApp/Lab/NetProbe.swift
for the harness; this reads the receiver's trace (and optionally the
phone's rtt trace) and prints the numbers the go or no-go decision rests
on, with a verdict against the bar argued out before the probe was built:

  PASS  p99 inter-arrival gap at or under two frames (33ms), stalls over
        100ms at most 2 per hour, loss under 1 percent.
  FAIL  anything worse. A link that hiccups makes every control profile
        feel broken, so there is nothing downstream worth building on it.

The median is printed but deliberately carries no weight: every transport
looks fine at the median, and the doc's whole risk lives in the tail.

Usage:
  summarize_netprobe.py net-probe-udp.csv [net-probe-udp-rtt.csv]

Pull traces off the devices with the usual devicectl copy, for example:
  xcrun devicectl device copy from --device <tv-id> \
    --domain-type appDataContainer --domain-identifier com.mmagtech.CabinetDev.tv \
    --source Library/Caches/net-probe-udp.csv --destination .

A trace that does not end with "# done" is a run that is still going or
died; this refuses to judge it, the same stale-pull rule the bench
harness learned the hard way.
"""
import csv
import sys

SEND_HZ = 100.0


def load(path):
    lines = open(path).read().splitlines()
    if not lines or not lines[-1].startswith("# done"):
        print(f"{path}: no '# done' trailer, refusing to judge an unfinished trace")
        sys.exit(2)
    body = [l for l in lines if l and not l.startswith("#")]
    rows = list(csv.DictReader(body))
    return rows


def pct(values, p):
    if not values:
        return 0.0
    s = sorted(values)
    return s[min(len(s) - 1, int(len(s) * p))]


def main(recv_path, rtt_path=None):
    rows = load(recv_path)
    if len(rows) < 100:
        print(f"{recv_path}: only {len(rows)} rows, not a run worth judging")
        sys.exit(2)

    # Drop the first second the way the frame summarizer does: connection
    # setup is not the workload.
    rows = [r for r in rows if float(r["t_arrive_ms"]) > 1000] or rows
    gaps = [float(r["gap_ms"]) for r in rows[1:]]
    seqs = [int(r["seq"]) for r in rows]
    span_s = (float(rows[-1]["t_arrive_ms"]) - float(rows[0]["t_arrive_ms"])) / 1000.0
    expected = span_s * SEND_HZ
    loss = max(0.0, 1.0 - len(rows) / expected) if expected else 0.0
    stalls100 = sum(1 for g in gaps if g > 100)
    stalls100_per_hour = stalls100 / (span_s / 3600.0) if span_s else 0.0
    # Sequence holes are the same packets the loss estimate sees, but
    # holes localize them: a thousand losses spread thin feel different
    # from one dead second, and the widest hole says which this was.
    holes = [b - a - 1 for a, b in zip(seqs, seqs[1:]) if b > a + 1]

    p50, p95, p99, p999 = (pct(gaps, p) for p in (0.50, 0.95, 0.99, 0.999))
    print(recv_path)
    print(f"   packets {len(rows)}  span {span_s / 60:.1f} min  loss {loss * 100:.2f}%")
    print(f"   gap ms  p50 {p50:6.2f}  p95 {p95:6.2f}  p99 {p99:6.2f}  "
          f"p99.9 {p999:6.2f}  max {max(gaps):.1f}")
    print(f"   gaps over 25ms {sum(1 for g in gaps if g > 25)}"
          f"  over 50ms {sum(1 for g in gaps if g > 50)}"
          f"  over 100ms {stalls100} ({stalls100_per_hour:.1f}/hour)"
          f"  over 300ms {sum(1 for g in gaps if g > 300)}")
    if holes:
        print(f"   seq holes {len(holes)}, widest {max(holes)} packets")

    if rtt_path:
        rtts = [float(r["rtt_ms"]) for r in load(rtt_path)]
        if rtts:
            print(f"   rtt ms  p50 {pct(rtts, 0.5):6.2f}  p95 {pct(rtts, 0.95):6.2f}"
                  f"  p99 {pct(rtts, 0.99):6.2f}  max {max(rtts):.1f}  n {len(rtts)}")

    ok = p99 <= 33.0 and stalls100_per_hour <= 2.0 and loss < 0.01
    short = span_s < 20 * 60
    verdict = "PASS" if ok else "FAIL"
    print(f"   verdict {verdict}"
          + ("  (but run is under 20 min, radio power management may not have shown itself yet)"
             if short else ""))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
