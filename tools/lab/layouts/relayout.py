#!/usr/bin/env python3
"""Puts every arcade panel on one positioning system.

The problem this solves, measured across all 59 arcade layouts: the same
control lands in a different place depending on what ELSE the cabinet
carried. Action button 1 sat at x 0.39, 0.51 or 0.67 in portrait, a 120
point swing, because a pedal dragged the cluster left and a mechanism
beside a stick pushed it right. A button came in five sizes. The
arrangement changed from an arc to a grid at five buttons. The movement
control had three widths and two left edges.

The numbers are the MASTER's: Marcus edited arcade-stick6 in the
editor on 2026-08-25, marked it green, and these tables are read from
that file. This script exists to spread the master, not to design.

The rule is LANES. A control's lane never moves. When something else
needs room the lane gets NARROWER; it does not relocate. So button 1 is
at the same place on every panel, and the panel with pedals simply has
two columns of buttons where another has three.

Preserves every kind, label and input exactly. Only frames change.

Run: python3 tools/lab/layouts/relayout.py [--dry-run]
"""
import sys, os, glob, math
sys.path.insert(0, os.path.dirname(__file__))
import layoutfmt

ROOT = 'RommApp/RommApp/Resources/ControlLayouts'
MECH = ('dpad', 'stick', 'spinner', 'trackball', 'rotary', 'wheel')

def R(x, y, w, h, px, py):
    """A frame and the touch frame around it, in one go."""
    return ({'x': round(x, 4), 'y': round(y, 4), 'w': round(w, 4), 'h': round(h, 4)},
            {'x': round(x - px, 4), 'y': round(y - py, 4),
             'w': round(w + px * 2, 4), 'h': round(h + py * 2, 4)})

# ---- the lanes -------------------------------------------------------
# Portrait is normalised against the 330pt control strip, landscape
# against the whole screen. The numbers differ; the SYSTEM does not.
# Service pills keep the exact frames they already had on 53 of the 59
# panels, TOUCH FRAMES INCLUDED. Those are stated rather than derived from
# a padding, because landscape Menu's is deliberately lopsided: it pads
# 0.005 on the left and 0.035 on the right so it does not eat into Coin
# beside it. Deriving it symmetrically put an 18% overlap on every pedal
# panel, which is how this comment came to exist.
P = {
    'coin':  ((0.05, 0.045, 0.14, 0.17), (0.01, 0.005, 0.22, 0.26)),
    'start': ((0.40, 0.075, 0.20, 0.10), (0.36, 0.025, 0.28, 0.20)),
    'menu':  ((0.72, 0.075, 0.17, 0.10), (0.68, 0.025, 0.25, 0.20)),
    'mech':  ((0.05, 0.31, 0.38, 0.54),  (0.02, 0.27, 0.44, 0.62)),
    'btn':    (0.15, 0.20, 0.04, 0.06),               # w h padx pady
    'col0':   0.50, 'colstep': 0.16, 'rowbase': 0.61, 'rowstep2': 0.26,
    'btn3':   (0.15, 0.17, 0.04, 0.05), 'rowstep3': 0.185,
    'stagger': 0.05, 'clusterrow': 0.22,
}
L = {
    'menu':  ((0.03, 0.085, 0.095, 0.09), (0.025, 0.045, 0.135, 0.16)),
    'coin':  ((0.19, 0.06, 0.06, 0.14),   (0.17, 0.03, 0.085, 0.21)),
    'start': ((0.855, 0.085, 0.10, 0.09), (0.83, 0.055, 0.14, 0.14)),
    'mech':  ((0.03, 0.31, 0.19, 0.42),   (0.01, 0.27, 0.23, 0.50)),
    'btn':    (0.065, 0.15, 0.02, 0.05),
    'btn3':   (0.065, 0.13, 0.02, 0.04), 'rowstep3': 0.17,
    'col0':   0.725, 'colstep': 0.09, 'rowbase': 0.545, 'rowstep2': 0.23,
    'stagger': 0.04, 'clusterrow': 0.19,
    # A pedal is held down for a whole race by the right thumb, so
    # buttons on the right cannot be reached. Marcus found that playing
    # Super Off Road. The lane mirrors rather than narrowing, and this is
    # the one place the system bends for a fact about hands.
    'pedalcol0': 0.26,
}


# The companion panel, the phone as the controller with no picture on it.
# Read from the master's companionItems the same way P and L are. Column
# x's are stated as a list because his columns are not a uniform step.
C = {
    'menu':  ((0.03, 0.085, 0.095, 0.09), (0.015, 0.07, 0.125, 0.12)),
    # The racing master, arcade-spinner6p1, moved two things on the
    # companion: the mechanism drops to sit flush with the button rows,
    # and the pedal centres vertically on the right edge. Family
    # overrides rather than new global numbers, because the stick master
    # keeps its own mech height and both masters are his.
    'mech_pedal': ((0.07, 0.3265, 0.19, 0.42), (0.05, 0.3065, 0.23, 0.46)),
    'pedalbox':   ((0.87, 0.3772, 0.10, 0.30), (0.845, 0.3472, 0.15, 0.36)),
    'start': ((0.87, 0.085, 0.10, 0.09),  (0.855, 0.07, 0.13, 0.12)),
    'coin':  ((0.20, 0.06, 0.06, 0.14),   (0.18, 0.04, 0.10, 0.18)),
    'mech':  ((0.07, 0.335, 0.19, 0.42),  (0.05, 0.315, 0.23, 0.46)),
    # The editor stores what his fingers actually left, so these carry
    # its full precision rather than tidied numbers: tidying them made
    # the master fail to round-trip by two ten-thousandths.
    'btn':    (0.0747, 0.1725),
    'btnpad': (0.02, 0.02),
    'cols':   [0.6382, 0.7418, 0.8452],
    'rowbase': 0.591, 'rowstep2': 0.2645,
    'stagger': 0.045, 'clusterrow': 0.21,
}


# The gun master, arcade-gun2, read from Marcus's file like the rest.
# A gun panel has no strip and no lanes: the whole screen is the aiming
# surface, the service row holds the top edge, and the buttons hold the
# bottom band in portrait and the right edge in landscape, where a thumb
# can fire without covering the picture.
G = {
    'p_coin':  ((0.035, 0.02, 0.165, 0.085), (0.015, 0.005, 0.205, 0.115)),
    'p_start': ((0.46, 0.02, 0.21, 0.075),   (0.44, 0.01, 0.25, 0.10)),
    'p_menu':  ((0.78, 0.02, 0.18, 0.075),   (0.76, 0.01, 0.22, 0.10)),
    'p_btn':    (0.219, 0.0992, 0.02, 0.015),     # w h padx pady
    'p_two':    (0.1905, 0.5905),   # his hand-placed pair beats the formula
    'p_row':    0.8479, 'p_rowstep': 0.117,
    'l_coin':  ((0.0475, 0.175, 0.065, 0.15), (0.0225, 0.135, 0.10, 0.24)),
    'l_start': ((0.87, 0.015, 0.10, 0.09),    (0.84, -0.025, 0.15, 0.16)),
    'l_menu':  ((0.03, 0.015, 0.10, 0.09),    (0.025, -0.025, 0.14, 0.16)),
    'l_btn':    (0.08, 0.18, 0.0097, 0.03),
    'l_col':    0.845, 'l_row': 0.63, 'l_rowstep': 0.18,
    # The companion aiming panel, from the master's own companion set.
    'c_menu':  ((0.03, 0.015, 0.10, 0.09),   (0.015, 0.0, 0.13, 0.12)),
    'c_start': ((0.87, 0.015, 0.10, 0.09),   (0.855, 0.0, 0.13, 0.12)),
    'c_coin':  ((0.0475, 0.15, 0.065, 0.15), (0.0275, 0.13, 0.105, 0.19)),
    'c_gun':   ((0.13, 0.095, 0.81, 0.81),   (0.11, 0.075, 0.85, 0.85)),
    'c_btn':    (0.0655, 0.146, 0.02, 0.02),
    'c_col':    0.8545, 'c_bottom': 0.7955, 'c_colstep': 0.095,
}


def shape_positions(n, anchor, stepx, stag, rowstep):
    """Third pass on Marcus's button shapes, and this time from a
    picture: MAME4iOS's cluster, which he sent 2026-08-25 saying "I want
    it like their buttons." The look is a real cabinet's: buttons nearly
    touching, each column stepped UP going right the way arcade panels
    arc their rows, and a second row sitting tight above, offset half a
    button so it nests into the stagger.

    Button one keeps its anchor on every count. Two is a nested pair,
    three is the full arcing row, four is the tight two-by-two with the
    right column raised, five is the row of three with two nested above.
    Six is the master's own grid and never comes through here."""
    x0, y0 = anchor
    row1 = [(x0 + i * stepx, y0 - i * stag) for i in range(3)]
    if n == 1: return [row1[0]]
    if n == 2: return row1[:2]
    if n == 3: return row1
    if n == 4: return [row1[0], row1[1],
                       (x0, y0 - rowstep), (x0 + stepx, y0 - stag - rowstep)]
    if n == 5: return row1 + [(x0 + 0.5 * stepx, y0 - rowstep),
                              (x0 + 1.5 * stepx, y0 - stag - rowstep)]
    return None

def rows_for(n, cols):
    return max(1, math.ceil(n / cols))

def place_buttons(items, S, cols, col0):
    """Button 1 lands at (col0, rowbase) on EVERY panel. That anchor is
    the point: a thumb finds button one in the same place whatever
    cabinet is running. Two to five buttons arrange as constellations
    inside the six-button footprint (see shape_positions); six, and any
    panel narrowed by pedals, keeps the grid."""
    acts = [i for i in items if i['kind'] == 'button' and i.get('label') != 'Coin']
    n = len(acts)
    if not n: return
    w, h, px, py = S['btn']
    if cols == 3:
        pts = shape_positions(n, (col0, S['rowbase']), S['colstep'],
                              S['stagger'], S['clusterrow'])
        if pts:
            for it, (x, y) in zip(acts, pts):
                f, e = R(x, y, w, h, px, py)
                it['frame'], it['extended'] = f, e
            return
    r = rows_for(n, cols)
    w, h, px, py = S['btn3'] if r >= 3 else S['btn']
    step = S['rowstep3'] if r >= 3 else S.get('rowstep2', 0.26)
    ys = [S['rowbase'] - step * (r - 1 - i) for i in range(r)]
    for idx, it in enumerate(acts):
        row, col = idx // cols, idx % cols
        f, e = R(col0 + col * S['colstep'], ys[len(ys) - 1 - row], w, h, px, py)
        it['frame'], it['extended'] = f, e


def relayout_gun_companion(d):
    """The gun master's companion spreads too: a large centred aiming
    surface, buttons stacked up the right edge, service in the corners.
    Pure gun panels only; the two combo cabinets keep their generated
    companion until a combo master exists."""
    items = d.get('items') or []
    out = []
    def put(src, box):
        fr, ex = box
        c = {k: v for k, v in src.items() if k not in ('frame', 'extended')}
        c['frame'] = {'x': fr[0], 'y': fr[1], 'w': fr[2], 'h': fr[3]}
        c['extended'] = {'x': ex[0], 'y': ex[1], 'w': ex[2], 'h': ex[3]}
        out.append(c)
    by = {i.get('label'): i for i in items}
    gun = next(i for i in items if i['kind'] == 'gun')
    if 'Menu' in by: put(by['Menu'], G['c_menu'])
    if 'Start' in by: put(by['Start'], G['c_start'])
    if 'Coin' in by: put(by['Coin'], G['c_coin'])
    put(gun, G['c_gun'])
    # A combo's mechanism sits inside the aiming surface's lower left,
    # under the resting thumb, and a pedal takes the master's right-edge
    # pedal box from the racing companion.
    for m in [i for i in items if i['kind'] in ('spinner', 'trackball')]:
        put(m, ((0.05, 0.62, 0.17, 0.30), (0.03, 0.59, 0.21, 0.36)))
    for pd in [i for i in items if i['kind'] == 'pedal']:
        put(pd, C['pedalbox'])
    w, h, px, py = G['c_btn']
    btns = [i for i in items if i['kind'] == 'button' and i.get('label') != 'Coin']
    has_pedal = any(i['kind'] == 'pedal' for i in items)
    for idx, b in enumerate(btns):
        col, row = idx // 3, idx % 3
        x = G['c_col'] - col * G['c_colstep']
        y = G['c_bottom'] - h - row * h
        if has_pedal:
            # The pedal owns the right edge; the buttons drop below it.
            x, y = G['c_col'], 0.80 - row * (h + 0.02)
        put(b, ((round(x, 4), round(y, 4), w, h),
                (round(x - px, 4), round(y - py, 4), round(w + px * 2, 4), round(h + py * 2, 4))))
    d['companionItems'] = out

def relayout_gun(d, name):
    """Spreads the gun master across the gun family. The master's two
    portrait buttons sit at thirds of the width; one centres, and three
    or more space evenly, a second row stacking above when the count
    passes three. Landscape is one column up the right edge, a second
    column stepping inward past three. The two combo cabinets keep their
    mechanism where the earlier pass put it, and gun-spinner1p1's button
    drops below its pedal, which owns the edge the column wants."""
    for key in ('items', 'landscapeItems'):
        items = d.get(key)
        if not items: continue
        port = key == 'items'
        mechs = [i for i in items if i['kind'] in ('spinner', 'trackball')]
        for it in items:
            lab = it.get('label')
            slot = {'Coin': 'coin', 'Start': 'start', 'Menu': 'menu'}.get(lab)
            if slot and it['kind'] in ('pill', 'button'):
                fr, ex = G[('p_' if port else 'l_') + slot]
                it['frame'] = {'x': fr[0], 'y': fr[1], 'w': fr[2], 'h': fr[3]}
                it['extended'] = {'x': ex[0], 'y': ex[1], 'w': ex[2], 'h': ex[3]}
        # The combo cabinets, a mechanism beside the gun. The bottom-left
        # corner is the mechanism's: the aiming hand owns the picture, so
        # the other thumb gets the ball or dial where it rests, and the
        # button band slides right to clear it. Sized square in points,
        # which on a gun panel means h and w scale differently.
        for m in mechs:
            if port:
                m['frame'] = {'x': 0.05, 'y': 0.79, 'w': 0.30, 'h': 0.138}
                m['extended'] = {'x': 0.02, 'y': 0.765, 'w': 0.36, 'h': 0.17}
            else:
                m['frame'] = {'x': 0.03, 'y': 0.54, 'w': 0.14, 'h': 0.30}
                m['extended'] = {'x': 0.01, 'y': 0.50, 'w': 0.18, 'h': 0.38}
        btns = [i for i in items if i['kind'] == 'button' and i.get('label') != 'Coin']
        peds = [i for i in items if i['kind'] == 'pedal']
        n = len(btns)
        if not n: continue
        if port:
            w, h, px, py = G['p_btn']
            for idx, b in enumerate(btns):
                row, col = idx // 3, idx % 3
                across = min(n - row * 3, 3) if n > 3 else min(n, 3)
                gap = (1.0 - across * w) / (across + 1)
                x = gap + col * (w + gap)
                if n == 2: x = G['p_two'][col]
                elif n == 1: x = 0.5 - w / 2
                if mechs:
                    # The band starts right of the mechanism's corner.
                    x = 0.50 + col * 0.245 if n > 1 else 0.62
                y = G['p_row'] - row * G['p_rowstep']
                b['frame'] = {'x': round(x, 4), 'y': round(y, 4), 'w': w, 'h': h}
                b['extended'] = {'x': round(x - px, 4), 'y': round(y - py, 4),
                                 'w': round(w + px * 2, 4), 'h': round(h + py * 2, 4)}
        else:
            w, h, px, py = G['l_btn']
            for idx, b in enumerate(btns):
                col, row = idx // 3, idx % 3
                x = G['l_col'] - col * 0.095
                y = G['l_row'] - row * G['l_rowstep']
                if peds and not col:
                    # The pedal owns the right edge from 0.40 down; the
                    # column starts below it instead of through it.
                    y = 0.72 + row * 0.0
                b['frame'] = {'x': round(x, 4), 'y': round(y, 4), 'w': w, 'h': h}
                b['extended'] = {'x': round(x - px, 4), 'y': round(y - py, 4),
                                 'w': round(w + px * 2, 4), 'h': round(h + py * 2, 4)}

def relayout_companion(d):
    """Companion sets spread from the master too, but by REPLACEMENT:
    most files have no companionItems at all (the app falls back to its
    generated panel), and the ones that do carry stale seeds. The master's
    set is copied with this panel's own mechanism swapped into the
    movement slot and this panel's own buttons laid on the master's grid,
    every kind, label and input taken from the panel's portrait items so
    nothing is invented."""
    items = d.get('items') or []
    if any(i['kind'] == 'gun' for i in items): return
    if len([i for i in items if i['kind'] in ('dpad', 'stick')]) > 1: return
    mechs = [i for i in items if i['kind'] in MECH]
    btns = [i for i in items if i['kind'] == 'button' and i.get('label') != 'Coin']
    peds = [i for i in items if i['kind'] == 'pedal']
    out = []
    def put(src, box):
        fr, ex = box
        c = {k: v for k, v in src.items() if k not in ('frame', 'extended')}
        c['frame'] = {'x': fr[0], 'y': fr[1], 'w': fr[2], 'h': fr[3]}
        c['extended'] = {'x': ex[0], 'y': ex[1], 'w': ex[2], 'h': ex[3]}
        out.append(c)
    # Emitted in the master's own order, Menu and Start first, then the
    # mechanism, then Coin, then the action buttons, so a spread panel is
    # list-identical to the master and the round-trip check can be exact.
    by = {i.get('label'): i for i in items}
    if 'Menu' in by: put(by['Menu'], C['menu'])
    if 'Start' in by: put(by['Start'], C['start'])
    mech_box = C['mech_pedal'] if peds else C['mech']
    fr, ex = mech_box
    if len(mechs) == 1:
        put(mechs[0], mech_box)
    elif mechs:
        half = (fr[2] - 0.02) / 2
        for k, m in enumerate(mechs):
            x = fr[0] + k * (half + 0.02)
            put(m, ((x, fr[1], half, fr[3]),
                    (x - 0.02, ex[1], half + 0.04, ex[3])))
    if 'Coin' in by: put(by['Coin'], C['coin'])
    w, h = C['btn']; px, py = C['btnpad']
    cols = C['cols'][:2] if peds else C['cols']
    n = len(btns)
    if n:
        pts = None
        if not peds:
            pts = shape_positions(n, (C['cols'][0], C['rowbase']),
                                  C['cols'][1] - C['cols'][0],
                                  C['stagger'], C['clusterrow'])
        if pts:
            for b, (x, y) in zip(btns, pts):
                put(b, ((round(x, 4), round(y, 4), w, h),
                        (round(x - px, 4), round(y - py, 4),
                         round(w + px * 2, 4), round(h + py * 2, 4))))
        else:
            r = rows_for(n, len(cols))
            ys = [C['rowbase'] - C['rowstep2'] * (r - 1 - k) for k in range(r)]
            for idx, b in enumerate(btns):
                row, col = idx // len(cols), idx % len(cols)
                x, y = cols[col], ys[len(ys) - 1 - row]
                put(b, ((x, y, w, h), (x - px, y - py, w + px * 2, h + py * 2)))
    # One pedal sits exactly where the racing master put it. Two stack
    # in the same lane, the pair centred where the one would be; no
    # master carries two, so the second's offset is arithmetic, stated
    # here so it is findable when a two-pedal master exists to replace it.
    (pfr, pex) = C['pedalbox']
    for k, pd in enumerate(peds):
        y = pfr[1] if len(peds) == 1 else 0.24 + k * 0.36
        put(pd, ((pfr[0], y, pfr[2], pfr[3]),
                 (pex[0], y - 0.03, pex[2], pex[3])))
    d['companionItems'] = out


def relayout_twin(d):
    """The twin master spreads by direct copy: positions are read from
    arcade-twin6.json itself rather than restated as tables, sticks and
    service by name, buttons as a prefix of the master's six. The master
    file is Marcus's verbatim, so this cannot drift from it."""
    master = layoutfmt.load(os.path.join(ROOT, 'arcade-twin6.json'))
    for key in ('items', 'landscapeItems', 'companionItems'):
        items = d.get(key)
        mitems = master.get(key)
        if not mitems: continue
        if items is None and key == 'companionItems':
            # A sibling gets the master's companion cut to its own
            # controls: same sticks, same service, first N buttons.
            src = d.get('items') or []
            have = {i.get('label') for i in src if i['kind'] == 'button'}
            n = len([i for i in src if i['kind'] == 'button' and i.get('label') != 'Coin'])
            out = []
            sticks = iter([i for i in src if i['kind'] in ('dpad', 'stick')])
            for m in mitems:
                if m['kind'] in ('dpad', 'stick'):
                    src_item = next(sticks, None)
                    if src_item is None: continue
                    c = {k: v for k, v in src_item.items() if k not in ('frame', 'extended')}
                elif m['kind'] == 'button' and m.get('label') != 'Coin':
                    if m['label'] not in have: continue
                    c = {k: v for k, v in next(i for i in src if i.get('label') == m['label']).items()
                         if k not in ('frame', 'extended')}
                else:
                    if m.get('label') not in have and m['kind'] == 'button': continue
                    match = next((i for i in src if i.get('label') == m.get('label')), None)
                    if match is None: continue
                    c = {k: v for k, v in match.items() if k not in ('frame', 'extended')}
                c['frame'] = dict(m['frame']); c['extended'] = dict(m['extended'])
                out.append(c)
            d['companionItems'] = out
            continue
        if not items: continue
        msticks = [m for m in mitems if m['kind'] in ('dpad', 'stick')]
        mbtn = {m.get('label'): m for m in mitems if m['kind'] == 'button'}
        mby = {m.get('label'): m for m in mitems if m['kind'] == 'pill'}
        sticks = [i for i in items if i['kind'] in ('dpad', 'stick')]
        for i, src_m in zip(sticks, msticks):
            i['frame'] = dict(src_m['frame']); i['extended'] = dict(src_m['extended'])
        for i in items:
            m = None
            if i['kind'] == 'button': m = mbtn.get(i.get('label'))
            elif i['kind'] == 'pill': m = mby.get(i.get('label'))
            if m:
                i['frame'] = dict(m['frame']); i['extended'] = dict(m['extended'])

def relayout(d, name):
    if len([i for i in (d.get('items') or []) if i['kind'] in ('dpad', 'stick')]) > 1:
        relayout_twin(d)
        return
    relayout_companion(d)
    if any(i['kind'] == 'gun' for i in (d.get('items') or [])):
        relayout_gun(d, name)
        relayout_gun_companion(d)
    for key, S in (('items', P), ('landscapeItems', L)):
        items = d.get(key)
        if not items: continue
        gun = any(i['kind'] == 'gun' for i in items)
        twin = len([i for i in items if i['kind'] in ('dpad', 'stick')]) > 1
        pedals = [i for i in items if i['kind'] == 'pedal']

        # The service row is fixed on every panel that has a strip. A gun
        # panel has no strip, so it keeps its own band.
        if not gun:
            for it in items:
                lab, kind = it.get('label'), it['kind']
                slot = ('coin' if lab == 'Coin' else
                        'start' if lab == 'Start' else
                        'menu' if lab == 'Menu' else None)
                if slot and kind in ('pill', 'button'):
                    fr, ex = S[slot]
                    it['frame'] = {'x': fr[0], 'y': fr[1], 'w': fr[2], 'h': fr[3]}
                    it['extended'] = {'x': ex[0], 'y': ex[1], 'w': ex[2], 'h': ex[3]}

        # The movement lane. Twin stick is the stated exception: two
        # sticks cannot share one lane, so they take the outer edges and
        # the buttons live in the corridor between them.
        mechs = [i for i in items if i['kind'] in MECH]
        if not gun and mechs and not twin:
            fr, ex = S['mech']
            if len(mechs) == 1:
                mechs[0]['frame'] = {'x': fr[0], 'y': fr[1], 'w': fr[2], 'h': fr[3]}
                mechs[0]['extended'] = {'x': ex[0], 'y': ex[1], 'w': ex[2], 'h': ex[3]}
            else:
                # A stick AND a mechanism, the Discs of Tron shape. They
                # SHARE the movement lane rather than one of them pushing
                # the action buttons across the panel, which is what used
                # to happen and is why button 1 moved 120 points.
                half = (fr[2] - 0.02) / 2
                for i, m in enumerate(mechs):
                    m['frame'], m['extended'] = R(
                        fr[0] + i * (half + 0.02), fr[1], half, fr[3], 0.02, 0.04)

        if gun or twin:
            continue

        if pedals and key == 'landscapeItems':
            place_buttons(items, S, 2, S['pedalcol0'])
        else:
            place_buttons(items, S, 2 if pedals else 3, S['col0'])

# The masters are Marcus's files verbatim, byte for byte as pulled from
# the editor, hand-unevenness included: his gun companion's two buttons
# are deliberately not the same height, and the first version of this
# loop 'corrected' them. Sources, not targets. The spread never touches
# them.
MASTERS = {'arcade-stick6', 'arcade-spinner6p1', 'arcade-gun2', 'arcade-twin6'}

dry = '--dry-run' in sys.argv
changed = 0
for f in sorted(glob.glob(os.path.join(ROOT, 'arcade-*.json'))):
    name = os.path.basename(f)[:-5]
    if name in MASTERS: continue
    d = layoutfmt.load(f)
    before = str(d)
    relayout(d, name)
    if str(d) == before: continue
    changed += 1
    if not dry: layoutfmt.save(f, d)
    print("   " + name)
print("%d panels %s" % (changed, "would change" if dry else "relaid"))
