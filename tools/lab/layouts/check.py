#!/usr/bin/env python3
"""Checks every control layout against the rules Marcus has actually
stated, so a violation is caught here instead of in his hands.

Each rule below exists because a real layout broke it and he had to
say so. The point of the file is that he says it once.

Run: python3 tools/lab/layouts/check.py [directory]
Exits non-zero if anything fails.
"""
import json, glob, os, sys, re

ROOT = sys.argv[1] if len(sys.argv) > 1 else \
    os.path.join(os.path.dirname(__file__), '../../../RommApp/RommApp/Resources/ControlLayouts')

def rect(i): return i.get('extended') or i['frame']
def intersection(a, b):
    w = min(a['x']+a['w'], b['x']+b['w']) - max(a['x'], b['x'])
    h = min(a['y']+a['h'], b['y']+b['h']) - max(a['y'], b['y'])
    return (w, h) if w > 0 and h > 0 else None
def ov(a, b):
    return not (a['x']+a['w'] <= b['x'] or b['x']+b['w'] <= a['x'] or
                a['y']+a['h'] <= b['y'] or b['y']+b['h'] <= a['y'])

def spread(items):
    """Cluster spread in units of the items' OWN size. Aspect free: x and
    y normalise against different lengths, so raw units cannot be
    compared between orientations."""
    w = sum(i['frame']['w'] for i in items)/len(items)
    h = sum(i['frame']['h'] for i in items)/len(items)
    cx = [i['frame']['x']+i['frame']['w']/2 for i in items]
    cy = [i['frame']['y']+i['frame']['h']/2 for i in items]
    return ((max(cx)-min(cx))/max(w, 1e-4), (max(cy)-min(cy))/max(h, 1e-4))

# Known and deliberately kept, with the reason. Not a way to silence
# the checker: anything in here is a fault somebody looked at and chose
# to live with, and it says who and why.
ACCEPTED = {
    # PSX landscape stacks L1 above L2 and R1 above R2 in the corner
    # columns with Select and Start beneath them, and three pills that
    # deep genuinely do not fit above the d-pad without something
    # touching. Marcus asked for this arrangement back on 2026-08-24
    # after I restructured it uninvited; it is the spacing the layout
    # has always had. Fixing it means changing the shape, which is his
    # call to make, not the checker's.
    ("psx", "landscapeItems", "L1", "L2"),
    ("psx", "landscapeItems", "R1", "R2"),
}

# Layouts Marcus has placed by hand, which the general rules must not
# walk over. The rules exist to catch drift, not to overrule a decision
# somebody actually made.
HAND_PLACED = {
    # PSX landscape was restored to its original arrangement on
    # 2026-08-24 at his request, after I had restructured it uninvited.
    # Menu sits left of centre there, and it stays there.
    ("psx", "landscapeItems", "Menu"),
    # Dreamcast's companion panel is the one place the centre is not
    # free: the phone pins player one's VMU window there, a fixed
    # 120x84 overlay at top centre that no layout can move
    # (ControllerPadView, and VMUGuide draws it in the editor). Menu
    # sits off centre to clear it. Marcus, 2026-08-30: "the menu is
    # fine on Dreamcast where I placed it because of the vmu, it's the
    # one exception."
    ("dreamcast", "companionItems", "Menu"),
}

fails = []
def fail(layout, key, msg): fails.append("%s/%s: %s" % (layout, key, msg))

SHOULDER = {'L', 'R', 'L1', 'L2', 'R1', 'R2'}

def menu_rule(name, key, pills):
    """Menu takes the LEFT CORNER, unless a shoulder already owns it.

    It is the one control that is not part of the game, so it should
    sit in the same place on every machine. L and R have a stronger
    claim to a corner than Menu does, so on a layout with shoulders,
    and only there, Menu takes the centre instead.

    Two earlier versions of this rule, "always centred" and "always
    left", each produced something Marcus had to correct, because
    neither is the rule: the corner is. A lone Menu with nothing to
    balance against is left alone.
    """
    menu = [p for p in pills if p.get('label') == 'Menu']
    if not menu or len(pills) < 2: return
    if (name, key, 'Menu') in HAND_PLACED: return
    labels = {p['label'] for p in pills}
    for m in menu:
        if SHOULDER & labels:
            c = m['frame']['x'] + m['frame']['w']/2
            if abs(c - 0.5) > 0.05:
                fail(name, key, "shoulders own the corners, so Menu belongs centred, not at %.3f" % c)
        elif m['frame']['x'] > 0.15:
            fail(name, key, "Menu belongs in the left corner, not at %.3f" % m['frame']['x'])

for path in sorted(glob.glob(os.path.join(ROOT, '*.json'))):
    name = os.path.basename(path)[:-5]
    d = json.load(open(path, encoding='utf-8'))
    portrait_btns = [i for i in (d.get('items') or []) if i.get('kind') == 'button']

    for key in ('items', 'landscapeItems', 'companionItems'):
        items = d.get(key)
        if not items: continue
        pills = [i for i in items if i.get('kind') == 'pill']
        rest = [i for i in items if i.get('kind') != 'pill']

        # RULE 1: service pills must not fight for the same touch.
        #
        # Graded, because severity is the whole point. Two pills whose
        # DRAWN shapes overlap is always wrong and always visible. Two
        # whose generous touch frames kiss by a few thousandths share a
        # sliver nobody can aim at, and calling that a fault buries the
        # real ones: the first version of this file reported 52
        # problems, of which 7 were worth fixing, which is exactly the
        # crying-wolf the editor's own warning badge does.
        #
        # Face buttons are exempt entirely. Their overlapping touch
        # frames are the deliberate DeltaCore-style targets that make a
        # diagonal reachable.
        for a in range(len(pills)):
            for b in range(a+1, len(pills)):
                A, B = pills[a], pills[b]
                if ov(A['frame'], B['frame']):
                    fail(name, key, "pills %s and %s visibly overlap"
                         % (A.get('label'), B.get('label')))
                    continue
                it = intersection(rect(A), rect(B))
                if not it: continue
                ref = min(rect(A)['w']*rect(A)['h'], rect(B)['w']*rect(B)['h'])
                frac = it[0]*it[1]/ref
                if frac > 0.15:
                    pair = tuple(sorted([A.get('label'), B.get('label')]))
                    if (name, key) + pair in ACCEPTED: continue
                    fail(name, key, "pills %s and %s share %d%% of a touch target"
                         % (A.get('label'), B.get('label'), round(frac*100)))

        # RULE 2: a pill never sits on a stick, d-pad or button.
        # Graded like rule 1, and for the same reason: a thumb
        # control's touch frame is deliberately generous, so a service
        # pill grazing its outer edge costs nothing, while a pill
        # sitting a quarter inside one is a press that goes to the
        # wrong place.
        for p in pills:
            for r in rest:
                # A light gun's item IS the picture: it spans the whole
                # panel because you aim anywhere on it. Every control
                # necessarily sits on it, so overlapping one is the
                # normal case rather than a fault.
                if r.get('kind') == 'gun': continue
                if ov(p['frame'], r['frame']):
                    fail(name, key, "pill %s sits on %s"
                         % (p.get('label'), r.get('label') or r.get('kind')))
                    continue
                it = intersection(rect(p), rect(r))
                if not it: continue
                frac = it[0]*it[1]/(rect(p)['w']*rect(p)['h'])
                if frac > 0.15:
                    fail(name, key, "pill %s loses %d%% of its touch area to %s"
                         % (p.get('label'), round(frac*100), r.get('label') or r.get('kind')))

        # RULE 3: nothing leaves the panel.
        for i in items:
            r = rect(i)
            if r['x'] < -0.03 or r['x']+r['w'] > 1.03 or r['y'] < -0.05:
                fail(name, key, "%s runs off the panel" % (i.get('label') or i.get('kind')))

        if key == 'companionItems':
            # RULE 4: on the companion panel the service pills are ONE
            # row across the top, Menu centred.
            menu_rule(name, key, pills)
            if len(pills) > 1:
                # Tidy rows, not necessarily ONE row. This started as
                # "everything on a single line", which was right until
                # PSX, where seven service pills across the top read as
                # a wall. Marcus asked for Select, Start and Menu to
                # step down "so there isn't a straight row across the
                # top". A step is a deliberate shape; what is still
                # wrong is scatter, half a dozen pills each at their own
                # slightly different height, which looks like nobody
                # placed them. So: a few rows, and anything sharing a
                # row shares it exactly.
                ys = sorted({round(p['frame']['y'], 3) for p in pills})
                # Up to four rows: PSX's controller-only panel mirrors
                # its portrait layout, which is four deep. More than
                # that is scatter rather than shape.
                if len(ys) > 4:
                    fail(name, key, "service pills are scattered over %d heights: %s"
                         % (len(ys), ys))
                for a in range(len(ys)-1):
                    if ys[a+1] - ys[a] < 0.03:
                        fail(name, key, "pill rows at %.3f and %.3f are neither aligned nor apart"
                             % (ys[a], ys[a+1]))

            # RULE 5: shoulders keep the side they have on the
            # television. SHOULDERS, not every pill: on a layout with
            # no shoulders, Menu takes the left corner and everything
            # else packs to the right, so Select legitimately changes
            # sides. This rule is about L staying left and R staying
            # right, which is anatomy, not arrangement.
            src = {i['label']: i for i in (d.get('landscapeItems') or d.get('items') or [])
                   if i.get('kind') == 'pill'}
            for p in pills:
                s = src.get(p.get('label'))
                if not s or p.get('label') not in SHOULDER: continue
                was = s['frame']['x'] + s['frame']['w']/2 < 0.5
                now = p['frame']['x'] + p['frame']['w']/2 < 0.5
                if was != now:
                    fail(name, key, "%s changed sides" % p.get('label'))

            # RULE 6: the action cluster is spaced like portrait's, which
            # is the one authored for a thumb. Only too-far is a failure.
            #
            # Arcade is exempt as of 2026-08-25: arcade companion sets are
            # spread mechanically from arcade-stick6, whose companion
            # Marcus laid out by hand and marked green, and his chosen
            # companion spacing deliberately differs from his portrait
            # spacing. The master is the standard there; this rule kept
            # flagging the standard itself, 41 times.
            btns = [i for i in items if i.get('kind') == 'button']
            if not name.startswith('arcade-') and len(btns) > 1 and len(portrait_btns) > 1:
                want, have = spread(portrait_btns), spread(btns)
                for axis, i in (('x', 0), ('y', 1)):
                    if want[i] > 0.01 and have[i] > 0.01 and have[i]/want[i] > 1.20:
                        fail(name, key, "buttons %.0f%% too far apart in %s"
                             % ((have[i]/want[i]-1)*100, axis))

        # RULE 7: two drawn buttons may not run through each other.
        #
        # A touch frame may overlap a neighbour's, deliberately: that
        # is what makes a diagonal on a face-button diamond reachable.
        # The DRAWN shape is different. Two circles passing through
        # one another is a mistake every time, and it is what
        # arcade-twin6 was doing at 43% when Marcus opened it in the
        # editor on 2026-08-25 and asked, fairly, why the checks had
        # not caught it. Measured in points, because a normalised
        # square is not a square: x scales against 430 and y against
        # 330, so an overlap looks smaller in the numbers than on the
        # glass.
        W, H = (932.0, 430.0) if key != 'items' else (430.0, 330.0)
        acts = [i for i in items
                if i.get('kind') == 'button' and i.get('label') != 'Coin']
        for a in range(len(acts)):
            for b in range(a + 1, len(acts)):
                fa, fb = acts[a]['frame'], acts[b]['frame']
                ox = (min(fa['x']+fa['w'], fb['x']+fb['w']) - max(fa['x'], fb['x'])) * W
                oy = (min(fa['y']+fa['h'], fb['y']+fb['h']) - max(fa['y'], fb['y'])) * H
                if ox <= 0 or oy <= 0:
                    continue
                # Circles, not boxes: a diamond's corners clip without
                # the shapes ever meeting.
                ra = min(fa['w']*W, fa['h']*H) / 2
                rb = min(fb['w']*W, fb['h']*H) / 2
                dx = ((fa['x']+fa['w']/2) - (fb['x']+fb['w']/2)) * W
                dy = ((fa['y']+fa['h']/2) - (fb['y']+fb['h']/2)) * H
                gap = (dx*dx + dy*dy) ** 0.5 - (ra + rb)
                if gap < -2:
                    fail(name, key, "drawn buttons %s and %s overlap by %dpt"
                             % (acts[a].get('label'), acts[b].get('label'), round(-gap)))

    # RULE 8: an arcade panel shows every button its name claims.
    #
    # arcade-twin6 drew four. The builder stopped at four ids and said
    # nothing, so four cabinets were missing controls with no way to tell
    # from the file. A panel named for six buttons has six.
    m = re.match(r'^arcade-[a-z-]+?(\d)(?:p\d)?j?$', name)
    if m:
        want = int(m.group(1))
        for key in ('items', 'landscapeItems'):
            items = d.get(key)
            if not items:
                continue
            have = len([i for i in items
                        if i.get('kind') == 'button' and i.get('label') != 'Coin'])
            # A pedal IS one of the cabinet's buttons to this core, so a
            # pedal panel legitimately shows fewer. See ArcadeLayout's
            # actionIds.
            pedals = len([i for i in items if i.get('kind') == 'pedal'])
            if have + pedals < want:
                fail(name, key, "named for %d buttons, draws %d" % (want, have))

    # RULE 9: a panel whose NAME lists a mechanism actually draws it.
    #
    # arcade-gun-trackball2 had no trackball and arcade-gun-spinner1p1 had
    # no dial: the mechanism is placed by replacing the d-pad, and a gun
    # panel has no d-pad to replace, so it vanished with nothing said.
    # Marcus found both by opening them. The name is the contract, so the
    # name is what this checks.
    MECH = {'trackball': 'trackball', 'spinner': 'spinner',
            'rotary': 'rotary', 'gun': 'gun', 'pedal': 'pedal'}
    m = re.match(r'^arcade-([a-z-]+?)\d(?:p\d)?j?$', name)
    if m:
        for fam in m.group(1).split('-'):
            want = MECH.get(fam)
            if not want:
                continue
            for key in ('items', 'landscapeItems'):
                items = d.get(key)
                if not items:
                    continue
                if not any(i.get('kind') == want for i in items):
                    fail(name, key, "named for a %s and does not have one" % fam)

n = len(glob.glob(os.path.join(ROOT, '*.json')))
if fails:
    print("%d layouts checked, %d problems:\n" % (n, len(fails)))
    for f in fails: print("  " + f)
    sys.exit(1)
print("%d layouts checked, all rules pass" % n)
