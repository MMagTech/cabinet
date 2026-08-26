#!/usr/bin/env python3
"""Maps the games the pixel pass could not, from their own source.

Four games light nothing in idle mode, so pressing inputs and diffing
frames found no buttons: both Chicky Woggys, Crazy Chewy, Motor Cross.
Reading beats watching. Every .mgw carries its converted Delphi source,
and unit1.bs declares each control's exact rectangle, so the game
buttons can be read the same way extract_menu.py already reads the
service ones.

The link is the keymap in main.bs: it names which RetroPad button maps
to which key, and the sim's own controls carry matching names
(btn_up_top, im_btn_left, and so on). Whatever a game calls its
buttons, the source says both halves.

Run: python3 tools/lab/gw/extract_direct.py <mgw-dir> <in-out.json> <name...>
"""
import json, os, re, subprocess, sys, tempfile

PAD = {'b': 0, 'y': 1, 'select': 2, 'start': 3, 'up': 4, 'down': 5,
       'left': 6, 'right': 7, 'a': 8, 'x': 9, 'l1': 10, 'r1': 11}

def sources(bin_, mgw):
    raw = subprocess.run(['bunzip2', '-c', mgw], capture_output=True).stdout
    out, i = {}, 0
    with tempfile.TemporaryDirectory() as td:
        while i + 512 <= len(raw):
            name = raw[i:i+100].rstrip(b'\x00 ').decode('utf-8', 'replace')
            if not name: break
            size = int(raw[i+124:i+136].rstrip(b'\x00 ') or b'0', 8)
            if name.endswith('.bs'):
                p = os.path.join(td, name)
                open(p, 'wb').write(raw[i+512:i+512+size])
                out[name] = subprocess.run([bin_, p], capture_output=True).stdout.decode('utf-8', 'replace')
            i += 512 + ((size + 511) // 512) * 512
    return out

def geometry(unit, control):
    geo = {}
    for f in ('left', 'top', 'width', 'height'):
        m = re.search(r'self\.%s\.%s = (\d+)' % (re.escape(control), f), unit)
        if m: geo[f] = int(m.group(1))
    return [geo['left'], geo['top'], geo['width'], geo['height']] if len(geo) == 4 else None

def buttons_for(main, unit):
    """Every non-service key in the keymap, with its drawn rectangle.

    These four hold a JOYSTICK where the corner-button games hold four
    separate caps, one control named btn_joystick_top, which is why the
    pixel pass found nothing to diff and why name-guessing found nothing
    to read. A stick is quartered into its four directions: press the
    top of the drawn stick and the sim gets up, exactly as a thumb on the
    real one would. The quarters overlap slightly at the centre so a
    diagonal push registers both, the same courtesy TouchControlPad's own
    d-pad extends."""
    found = {}
    for pad_name in ('up', 'down', 'left', 'right', 'a', 'b', 'x', 'y'):
        km = re.search(r'\b%s\s*=\s*\{[^}]*"([^"]+)"' % pad_name, main)
        if not km: continue
        label = km.group(1).lower().replace(' ', '_').replace('/', '_')
        for guess in ('btn_%s_top' % label, 'btn_%s_top' % pad_name,
                      'im_btn_%s' % label, 'btn_%s' % label):
            rect = geometry(unit, guess)
            if rect:
                found[pad_name] = rect
                break
    if found:
        return found
    # Three spellings across four games, because four different
    # companies drew the same control: a single square pad
    # (btn_joystick_top, btn_pad_top), or a cross split into its two
    # arms (btn_cross_h and btn_cross_v), whose union is the same shape.
    stick = (geometry(unit, 'btn_joystick_top') or geometry(unit, 'btn_pad_top')
             or geometry(unit, 'im_joystick'))
    if not stick:
        hor, ver = geometry(unit, 'btn_cross_h'), geometry(unit, 'btn_cross_v')
        if hor and ver:
            x0 = min(hor[0], ver[0]); y0 = min(hor[1], ver[1])
            x1 = max(hor[0] + hor[2], ver[0] + ver[2])
            y1 = max(hor[1] + hor[3], ver[1] + ver[3])
            stick = [x0, y0, x1 - x0, y1 - y0]
    if not stick:
        return {}
    x, y, w, h = stick
    ox, oy = w // 6, h // 6            # the shared centre
    return {
        'up':    [x, y, w, h // 2 + oy],
        'down':  [x, y + h // 2 - oy, w, h // 2 + oy],
        'left':  [x, y, w // 2 + ox, h],
        'right': [x + w // 2 - ox, y, w // 2 + ox, h],
    }

def main_():
    mgwdir, jsonpath = sys.argv[1], sys.argv[2]
    targets = sys.argv[3:]
    here = os.path.dirname(os.path.abspath(__file__))
    bin_ = os.path.join(here, 'bsdump')
    spots = json.load(open(jsonpath))
    added = 0
    for fn in targets:
        srcs = sources(bin_, os.path.join(mgwdir, fn))
        main, unit = srcs.get('main.bs', ''), srcs.get('unit1.bs', '')
        btns = buttons_for(main, unit)
        # The panel's own size, so hit tests share the artwork's frame.
        bg = geometry(unit, 'im_background') or geometry(unit, 'form1')
        w = h = None
        for f, key in (('width', 'w'), ('height', 'h')):
            m = re.search(r'self\.form1\.client%s = (\d+)' % f, unit)
            if m: (w := int(m.group(1))) if key == 'w' else None
        m = re.search(r'self\.im_background\.width = (\d+)', unit)
        n = re.search(r'self\.im_background\.height = (\d+)', unit)
        if m and n: w, h = int(m.group(1)), int(n.group(1))
        if not btns or not w:
            print('%-52s FAIL buttons=%d size=%s' % (fn[:52], len(btns), w)); continue
        spots[fn] = {
            'width': w, 'height': h,
            'orientation': 'landscape' if w >= h else 'portrait',
            'ready_hint': 240,
            'buttons': {k: v for k, v in btns.items()},
        }
        added += 1
        print('%-52s %d buttons  %dx%d' % (fn[:52], len(btns), w, h))
    json.dump(spots, open(jsonpath, 'w'), indent=1, sort_keys=True)
    print('\n%d added from source' % added)

if __name__ == '__main__': main_()
