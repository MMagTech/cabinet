#!/usr/bin/env python3
"""Puts Menu where Marcus has repeatedly said it goes.

The rule, which fits every instruction he has given and needed all of
them to see: Menu takes the LEFT CORNER, because it is the one control
that is not part of the game and should sit in the same place on every
machine. The single exception is a layout whose corners are already
owned by shoulder buttons, where L and R have a stronger claim to the
corner than Menu does; there, and only there, Menu takes the centre.

That is why "always centred" and "always left" both kept producing
something he had to correct. Neither is the rule. The corner is.

A lone Menu with nothing to balance against is left alone.
"""
import sys, os, glob
sys.path.insert(0, os.path.dirname(__file__))
import layoutfmt

SHOULDER = {'L', 'R', 'L1', 'L2', 'R1', 'R2'}
PAD = 0.015
GAP = 2*PAD + 0.006

def run(root):
    out = []
    for path in sorted(glob.glob(os.path.join(root, '**/*.json'), recursive=True)):
        d = layoutfmt.load(path)
        name = os.path.basename(path)[:-5]
        touched = []
        for key in ('items', 'landscapeItems', 'companionItems'):
            items = d.get(key)
            if not items: continue
            pills = [i for i in items if i.get('kind') == 'pill']
            labels = {i['label'] for i in pills}
            if 'Menu' not in labels or len(pills) < 2: continue
            if SHOULDER & labels: continue          # corners are spoken for

            menu = next(i for i in pills if i['label'] == 'Menu')
            rest = sorted((i for i in pills if i is not menu),
                          key=lambda i: i['frame']['x'])
            # Being NEAR the left is not the same as being the leftmost
            # thing there. Game Boy's landscape row read Select | Menu |
            # Start and this shortcut passed it, because Menu sat at
            # 0.035 and the test only asked whether that was small.
            # Menu must be leftmost AND alone there. Game Boy's
            # landscape stacks Select directly above Menu at the same
            # x, so "is anything further left" answered no while Select
            # was plainly still on the left side. The corner is Menu's
            # alone; everything else belongs on the other side.
            if all(i['frame']['x'] >= menu['frame']['x'] + menu['frame']['w']
                   for i in rest):
                continue

            row = min(i['frame']['y'] for i in pills)
            def put(p, x):
                fr = p['frame']; ex = p.get('extended')
                if ex:
                    dx, dy = ex['x']-fr['x'], ex['y']-fr['y']
                    ex['x'], ex['y'] = round(x+dx, 4), round(row+dy, 4)
                fr['x'], fr['y'] = round(x, 4), round(row, 4)

            before = [(i, dict(i['frame']), dict(i.get('extended') or {})) for i in pills]
            put(menu, 0.03)
            # The others keep their order and pack to the right corner,
            # so the last of them lands in it. Gaps come from each
            # pill's own padding rather than a constant, since the
            # files do not all use the same one.
            x = 0.97
            for p in reversed(rest):
                x -= p['frame']['w']
                put(p, x)
                pad = (p['frame']['x'] - (p.get('extended') or p['frame'])['x'])
                x -= 2*max(pad, PAD) + 0.006

            # The left corner is not always free. Arcade keeps a Coin
            # button there, and a rule about pills has no business
            # evicting a control the player actually presses. Where the
            # move collides, put everything back and leave the layout
            # alone.
            def rect(i): return i.get('extended') or i['frame']
            def ov(a, b):
                return not (a['x']+a['w'] <= b['x'] or b['x']+b['w'] <= a['x'] or
                            a['y']+a['h'] <= b['y'] or b['y']+b['h'] <= a['y'])
            # Only the pills matter here. Face buttons overlap each
            # other by design, so asking "does anything overlap" would
            # answer yes on nearly every layout and revert them all.
            nonpill = [i for i in items if i.get('kind') != 'pill']
            clash = (any(ov(rect(a), rect(b))
                         for n, a in enumerate(pills) for b in pills[n+1:])
                     or any(ov(rect(p), rect(o)) for p in pills for o in nonpill))
            if clash:
                for it, fr, ex in before:
                    it['frame'].update(fr)
                    if ex: it['extended'].update(ex)
                continue
            touched.append("%s: Menu | %s" % (key, " ".join(i['label'] for i in rest)))
        if touched:
            layoutfmt.save(path, d)
            out.append((name, touched))
    return out

for name, t in run(sys.argv[1]):
    print("  %-16s %s" % (name, "   ".join(t)))
