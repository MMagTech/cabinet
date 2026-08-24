#!/usr/bin/env python3
"""Repairs layout collisions in place, minimally.

Deliberately NOT a re-flow. Every layout here has been tuned by hand
and most of each one is right; this only moves what actually collides,
keeps the reading order it finds, and leaves everything else at the
exact numbers it was authored with.

Two passes:
  1. Pills in the same row are spaced until their touch frames clear.
     Order and the row's centre are preserved; the row is squeezed
     toward minimum gaps before it is allowed to grow past the edges.
  2. A pill still sitting on a stick, d-pad or button is walked upward
     until it is clear, since the top band is where service controls
     belong and the thumbs own everything below.

Face buttons are never touched: their overlapping touch frames are the
deliberate DeltaCore-style targets that make a diagonal reachable.

Run: python3 tools/lab/layouts/relax.py <directory> [more dirs...]
"""
import sys, os, glob
sys.path.insert(0, os.path.dirname(__file__))
import layoutfmt

PAD = 0.015
GAP = 2 * PAD + 0.006

def rect(i): return i.get('extended') or i['frame']
def ov(a, b):
    return not (a['x']+a['w'] <= b['x'] or b['x']+b['w'] <= a['x'] or
                a['y']+a['h'] <= b['y'] or b['y']+b['h'] <= a['y'])

def set_x(p, x):
    fr = p['frame']; ex = p.get('extended')
    if ex: ex['x'] = round(ex['x'] + (x - fr['x']), 4)
    fr['x'] = round(x, 4)

def set_y(p, y):
    fr = p['frame']; ex = p.get('extended')
    if ex: ex['y'] = round(ex['y'] + (y - fr['y']), 4)
    fr['y'] = round(y, 4)

def relax(path):
    d = layoutfmt.load(path)
    changed = []
    # Repeated until it settles: spacing a row can push a pill onto a
    # thumb control, and lifting a pill off one can push it into a row.
    # Each pass only ever reduces collisions, so this converges.
    for _ in range(6):
      before = len(changed)
      for key in ('items', 'landscapeItems', 'companionItems'):
          items = d.get(key)
          if not items: continue
          pills = [i for i in items if i.get('kind') == 'pill']
          rest = [i for i in items if i.get('kind') != 'pill']

          # --- pass 1: rows ---
          rows = []
          for p in sorted(pills, key=lambda i: (i['frame']['y'], i['frame']['x'])):
              for r in rows:
                  if abs(r[0]['frame']['y'] - p['frame']['y']) < 0.06:
                      r.append(p); break
              else:
                  rows.append([p])
          for row in rows:
              if len(row) < 2: continue
              row.sort(key=lambda i: i['frame']['x'])
              # Only a row that actually collides is re-spaced. A row that
              # already clears is left at the exact numbers it was
              # authored with, however uneven those look: this file
              # repairs faults, it does not impose a house style on
              # layouts somebody tuned by hand.
              if not any(ov(rect(row[a]), rect(row[b]))
                         for a in range(len(row)) for b in range(a+1, len(row))):
                  continue
              need = sum(p['frame']['w'] for p in row) + GAP * (len(row) - 1)
              lo = min(p['frame']['x'] for p in row)
              hi = max(p['frame']['x'] + p['frame']['w'] for p in row)
              start = (lo + hi) / 2 - need / 2
              start = max(0.02 + PAD, min(start, 0.98 - PAD - need))
              x = start
              for p in row:
                  if abs(p['frame']['x'] - x) > 0.0005:
                      set_x(p, x); changed.append((key, p.get('label'), 'row'))
                  x += p['frame']['w'] + GAP

          # --- pass 2: pills off the thumbs ---
          for p in pills:
              steps = 0
              while any(ov(rect(p), rect(r)) for r in rest) and steps < 40:
                  ny = p['frame']['y'] - 0.005
                  if ny < 0.0: break
                  set_y(p, ny); steps += 1
              if steps:
                  changed.append((key, p.get('label'), 'lifted %d' % steps))
      if len(changed) == before: break
    if changed:
        layoutfmt.save(path, d)
    return changed

total = 0
for root in sys.argv[1:]:
    for path in sorted(glob.glob(os.path.join(root, '**/*.json'), recursive=True)):
        ch = relax(path)
        if ch:
            total += 1
            print("  %-22s %s" % (os.path.basename(path)[:-5],
                                  ", ".join("%s %s(%s)" % c for c in ch[:6])))
print("touched %d files" % total)
