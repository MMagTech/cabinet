#!/usr/bin/env python3
"""Brings a layout's action cluster to the spacing the portrait layout
uses, measured in units of the buttons' own size.

Why that measure: x and y normalise against different lengths, so the
same number means different distances in the two orientations and a
cluster that reads as even in the JSON is not even on glass. Button
widths are the invariant both orientations share.

Portrait is the reference because it is the layout authored for a
thumb rather than for sitting around a picture, and because it is the
one Marcus judges the others against by eye.

Positions move; sizes never do. Only the cluster is touched.
"""
import sys, os, glob
sys.path.insert(0, os.path.dirname(__file__))
import layoutfmt

TOL = 0.15

def spread(items):
    w = sum(i['frame']['w'] for i in items)/len(items)
    h = sum(i['frame']['h'] for i in items)/len(items)
    cx = [i['frame']['x']+i['frame']['w']/2 for i in items]
    cy = [i['frame']['y']+i['frame']['h']/2 for i in items]
    return ((max(cx)-min(cx))/max(w,1e-4), (max(cy)-min(cy))/max(h,1e-4))

def run(root, key, skip_prefix='arcade'):
    done = []
    for path in sorted(glob.glob(os.path.join(root, '**/*.json'), recursive=True)):
        name = os.path.basename(path)[:-5]
        if skip_prefix and name.startswith(skip_prefix): continue
        d = layoutfmt.load(path)
        P = [i for i in (d.get('items') or []) if i.get('kind') == 'button']
        C = [i for i in (d.get(key) or []) if i.get('kind') == 'button']
        if len(P) < 2 or len(C) < 2: continue
        want, have = spread(P), spread(C)
        if min(want+have) < 0.01: continue
        fx = want[0]/have[0] if abs(have[0]/want[0]-1) > TOL else 1.0
        fy = want[1]/have[1] if abs(have[1]/want[1]-1) > TOL else 1.0
        if fx == 1.0 and fy == 1.0: continue
        ccx = sum(i['frame']['x']+i['frame']['w']/2 for i in C)/len(C)
        ccy = sum(i['frame']['y']+i['frame']['h']/2 for i in C)/len(C)
        for b in C:
            fr = b['frame']; ex = b.get('extended')
            dx, dy = (ex['x']-fr['x'], ex['y']-fr['y']) if ex else (0, 0)
            ncx = ccx + (fr['x']+fr['w']/2 - ccx)*fx
            ncy = ccy + (fr['y']+fr['h']/2 - ccy)*fy
            fr['x'] = round(ncx-fr['w']/2, 4); fr['y'] = round(ncy-fr['h']/2, 4)
            if ex: ex['x'] = round(fr['x']+dx, 4); ex['y'] = round(fr['y']+dy, 4)
        layoutfmt.save(path, d)
        now = spread(C)
        done.append((name, fx, fy, now[0]/want[0], now[1]/want[1]))
    return done

root = sys.argv[1]; key = sys.argv[2] if len(sys.argv) > 2 else 'landscapeItems'
for n, fx, fy, ax, ay in run(root, key):
    print("  %-13s scaled x%.2f y%.2f  ->  now %.2f / %.2f of portrait" % (n, fx, fy, ax, ay))
