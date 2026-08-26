#!/usr/bin/env python3
"""Reads each Game & Watch simulator's own source for its menu buttons.

The pixel-diff extractor cannot see GAME A / GAME B / TIME: those are
not direct inputs but entries in the framework's hand menu, driven by
select (cycle) and start (press), and pressing select just draws the
hand, which is exactly the artifact the first pass mistook for a button.
The truth is IN the games: every .mgw carries its converted Delphi
source, obfuscated with bstree, and the core's own reader decodes it.
main.bs declares `menu = { { btn_x_down, "Label", key }, ... }` in press
order, and unit1.bs carries every button's left/top/width/height, with
hints like "click to start game A" for good measure.

Emits, per game: menu = [ {label, rect, seq} ] where seq is how many
select presses put the hand on that entry before start presses it.

Run: python3 tools/lab/gw/extract_menu.py <mgw-dir> <in-out.json>
"""
import json, os, re, subprocess, sys, tempfile

def bsdump(bin_, path):
    r = subprocess.run([bin_, path], capture_output=True)
    return r.stdout.decode('utf-8', 'replace')

def tar_entries(data):
    i = 0
    while i + 512 <= len(data):
        name = data[i:i+100].rstrip(b'\x00 ').decode('utf-8', 'replace')
        if not name: break
        size = int(data[i+124:i+136].rstrip(b'\x00 ') or b'0', 8)
        yield name, data[i+512:i+512+size]
        i += 512 + ((size + 511) // 512) * 512

def extract(bin_, mgw):
    raw = subprocess.run(['bunzip2', '-c', mgw], capture_output=True).stdout
    units = {}
    for name, body in tar_entries(raw):
        if name.endswith('.bs'): units[name] = body
    if 'main.bs' not in units: return None, 'no main.bs'
    with tempfile.TemporaryDirectory() as td:
        srcs = {}
        for name, body in units.items():
            p = os.path.join(td, name)
            open(p, 'wb').write(body)
            srcs[name] = bsdump(bin_, p)
    main = srcs['main.bs']
    unit = srcs.get('unit1.bs', '')
    def geometry(top_name):
        geo = {}
        for field in ('left', 'top', 'width', 'height'):
            g = re.search(r'self\.%s\.%s = (\d+)' % (re.escape(top_name), field), unit)
            if g: geo[field] = int(g.group(1))
        return [geo['left'], geo['top'], geo['width'], geo['height']] if len(geo) == 4 else None
    m = re.search(r'local\s+menu\s*=\s*\{(.*?)\n\}', main, re.S)
    if m:
        entries = re.findall(r'\{\s*unit1\.form1\.(\w+)\s*,\s*"([^"]+)"', m.group(1))
        menu = []
        for seq, (img, label) in enumerate(entries, start=1):
            rect = geometry(img.replace('_down', '_top'))
            if rect: menu.append({'label': label, 'seq': seq, 'rect': rect})
        if menu: return {'menu': menu}, None
        return None, 'no geometry for menu entries'
    # Menu-less game (Egg's generation): compatinit keeps the direct
    # shoulder keys, so its service buttons press straight through.
    # Their names in the keymap are l1/r1/l2/r2; their rects come from
    # the btn_*_top control whose label matches.
    RETRO = {'l1': 10, 'r1': 11, 'l2': 12, 'r2': 13}
    direct = []
    for btn, rid in RETRO.items():
        km = re.search(r'%s\s*=\s*\{\s*\d+\s*,\s*"([^"]+)"' % btn, main)
        if not km: continue
        label = km.group(1)
        guess = 'btn_' + label.lower().replace(' ', '_') + '_top'
        rect = geometry(guess)
        if not rect and label.lower() == 'time':
            rect = geometry('btn_mode_top')
        if not rect and label.lower() == 'acl':
            rect = geometry('btn_acl_top')
        if rect: direct.append({'label': label, 'id': rid, 'rect': rect})
    if direct: return {'direct': direct}, None
    return None, 'no menu table and no direct geometry'

def main():
    mgwdir, jsonpath = sys.argv[1], sys.argv[2]
    here = os.path.dirname(os.path.abspath(__file__))
    bin_ = os.path.join(here, 'bsdump')
    core = 'spikes/cores/gw/src'
    subprocess.run(['cc', '-O2', '-o', bin_, os.path.join(here, 'bsdump.c'),
                    os.path.join(core, 'gwlua/bsreader.c'),
                    '-I' + os.path.join(core, 'gwlua'),
                    '-I' + os.path.join(core, 'lua/src')], check=True)
    spots = json.load(open(jsonpath))
    ok = fail = 0
    for fn, spec in sorted(spots.items()):
        found, err = extract(bin_, os.path.join(mgwdir, fn))
        if found:
            spec.pop('menu', None); spec.pop('direct', None)
            spec.update(found); ok += 1
            kind, entries = next(iter(found.items()))
            print('%-52s %s: %s' % (fn[:52], kind, ', '.join(e['label'] for e in entries)))
        else:
            fail += 1
            print('%-52s MENU FAIL %s' % (fn[:52], err))
    json.dump(spots, open(jsonpath, 'w'), indent=1, sort_keys=True)
    print('\nmenu extracted for %d, failed %d' % (ok, fail))

if __name__ == '__main__': main()
