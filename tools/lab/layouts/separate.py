#!/usr/bin/env python3
"""Pushes apart only the pill pairs whose touch frames genuinely fight.

Severity matters. Two service pills whose extended frames kiss by a few
thousandths share a sliver nobody can aim at; two sharing a quarter of
their area mean a real chance of firing the wrong one. Only the second
kind is repaired, and each pair is moved the least distance that clears
it, along whichever axis is cheaper, so a layout keeps the shape it was
authored with.

A pill against a panel edge is anchored and does not move: L belongs in
the corner, and pulling it inward to make room would trade a real fault
for a worse one.
"""
import sys, os, glob
sys.path.insert(0, os.path.dirname(__file__))
import layoutfmt

THRESHOLD = 0.15

def rect(i): return i.get('extended') or i['frame']
def inter(a, b):
    w = min(a['x']+a['w'], b['x']+b['w']) - max(a['x'], b['x'])
    h = min(a['y']+a['h'], b['y']+b['h']) - max(a['y'], b['y'])
    return (w, h) if w > 0 and h > 0 else None

def shift(p, dx=0.0, dy=0.0):
    for r in (p['frame'], p.get('extended')):
        if not r: continue
        r['x'] = round(r['x']+dx, 4); r['y'] = round(r['y']+dy, 4)

def anchored(p):
    r = rect(p)
    return r['x'] < 0.03 or r['x']+r['w'] > 0.97

def run(root):
    touched = 0
    for path in sorted(glob.glob(os.path.join(root, '**/*.json'), recursive=True)):
        d = layoutfmt.load(path); notes = []
        for key in ('items', 'landscapeItems', 'companionItems'):
            pills = [i for i in (d.get(key) or []) if i.get('kind') == 'pill']
            for _ in range(8):
                worst = None
                for a in range(len(pills)):
                    for b in range(a+1, len(pills)):
                        A, B = pills[a], pills[b]
                        it = inter(rect(A), rect(B))
                        if not it: continue
                        ref = min(rect(A)['w']*rect(A)['h'], rect(B)['w']*rect(B)['h'])
                        frac = it[0]*it[1]/ref
                        if frac > THRESHOLD and (not worst or frac > worst[0]):
                            worst = (frac, A, B, it)
                if not worst: break
                frac, A, B, it = worst
                # cheaper axis, plus a hair so it clears rather than kisses
                need = min(it) + 0.004
                horiz = it[0] <= it[1]
                lo, hi = (A, B) if (rect(A)['x'] <= rect(B)['x'] if horiz
                                    else rect(A)['y'] <= rect(B)['y']) else (B, A)
                movers = [p for p in (lo, hi) if not anchored(p)] or [lo, hi]
                each = need/len(movers)
                for p in movers:
                    s = -each if p is lo else each
                    shift(p, dx=s if horiz else 0, dy=0 if horiz else s)
                notes.append("%s %s/%s %d%%" % (key, A.get('label'), B.get('label'), round(frac*100)))
        if notes:
            layoutfmt.save(path, d); touched += 1
            print("  %-12s %s" % (os.path.basename(path)[:-5], ", ".join(notes)))
    print("separated pairs in %d files" % touched)

for r in sys.argv[1:]: run(r)
