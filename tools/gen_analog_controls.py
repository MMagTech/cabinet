#!/usr/bin/env python3
"""Build Resources/analog-controls.json from mame2003-plus driver source.

The bundled arcade profile map (tools/mame_profiles.py -> profiles.json)
flattens every dial, trackball, paddle and gun game into one "special"
bucket and keeps nothing about what the control actually was, so the
player cannot know a game wants a spinner. This file is the missing
half: per romset shortname, which analog mechanisms player 1 actually
has, read straight from the ROM_START/INPUT_PORTS blocks of the core
that will run the game, so the two can never disagree.

Usage: gen_analog_controls.py <path-to-mame2003-plus-checkout>
Writes RommApp/RommApp/Resources/analog-controls.json, committed unlike
profiles.json because the app ships it and it is small.
"""
import json, re, sys, glob, os, collections

ANALOG = ['DIAL_V','DIAL','PADDLE_V','PADDLE','TRACKBALL_X','TRACKBALL_Y',
          'AD_STICK_X','AD_STICK_Y','LIGHTGUN_X','LIGHTGUN_Y','PEDAL2','PEDAL']
OTHER = re.compile(r'IPF_PLAYER[234]')

def main(src):
    game_re = re.compile(
        r'\bGAME[BLX]?\w*\s*\(\s*[^,]*,\s*([A-Za-z0-9_]+)\s*,\s*([A-Za-z0-9_]+)\s*,'
        r'\s*[A-Za-z0-9_]+\s*,\s*([A-Za-z0-9_]+)\s*,')
    port_controls = {}
    all_ports = set()
    file_fallback = {}
    games = []
    for path in glob.glob(os.path.join(src, 'src/drivers/*.c')):
        text = open(path, errors='ignore').read()
        for m in re.finditer(r'INPUT_PORTS_START\s*\(\s*([A-Za-z0-9_]+)\s*\)(.*?)INPUT_PORTS_END',
                             text, re.S):
            all_ports.add(m.group(1))
            p1 = '\n'.join(l for l in m.group(2).splitlines() if not OTHER.search(l))
            counts = {}
            for t in ANALOG:
                n = len(re.findall(r'IPT_' + t + r'\b', p1))
                if t == 'DIAL':   n -= len(re.findall(r'IPT_DIAL_V\b', p1))
                if t == 'PADDLE': n -= len(re.findall(r'IPT_PADDLE_V\b', p1))
                if t == 'PEDAL':  n -= len(re.findall(r'IPT_PEDAL2\b', p1))
                if n > 0: counts[t] = n
            if not counts: continue
            mech = {}
            d = counts.get('DIAL', 0) + counts.get('DIAL_V', 0)
            if d: mech['dial'] = d
            p = counts.get('PADDLE', 0) + counts.get('PADDLE_V', 0)
            if p: mech['paddle'] = p
            if counts.get('TRACKBALL_X') or counts.get('TRACKBALL_Y'): mech['trackball'] = 1
            if counts.get('LIGHTGUN_X') or counts.get('LIGHTGUN_Y'): mech['lightgun'] = 1
            ax, ay = counts.get('AD_STICK_X', 0), counts.get('AD_STICK_Y', 0)
            if ax and ay: mech['stick'] = 1
            elif ax or ay: mech['axis'] = 1
            if counts.get('PEDAL') or counts.get('PEDAL2'): mech['pedals'] = 1
            if mech:
                port_controls[m.group(1)] = mech
                # Some drivers declare ports through a token-pasting macro
                # (centiped.c's INPUT_PORTS_START(GAMENAME)), so the block
                # name is the macro parameter and no game's own name ever
                # appears. Only a macro-parameter-looking name (uppercase)
                # may serve as a file's fallback, and, below, only for a
                # port name that exists in no block at all: a game whose
                # port matched a plain joystick block is not analog, full
                # stop. Without both conditions this file attributed The
                # Irritating Maze's trackball to every Neo Geo game.
                if m.group(1).isupper():
                    file_fallback.setdefault(path, mech)
        for g in game_re.findall(re.sub(r'\s+', ' ', text)):
            games.append((g[0], g[1], g[2], path))

    out = {}
    port_of = {short: port for short, parent, port, _ in games}
    for short, parent, port, path in games:
        mech = port_controls.get(port)
        # Clones without their own port block inherit the parent's.
        if mech is None and parent not in ('0', 'NULL'):
            mech = port_controls.get(port_of.get(parent, ''))
        if mech is None and port not in all_ports:
            mech = file_fallback.get(path)
        if mech: out[short] = mech

    dest = os.path.join(os.path.dirname(__file__), '..',
                        'RommApp/RommApp/Resources/analog-controls.json')
    with open(dest, 'w') as f:
        json.dump(dict(sorted(out.items())), f, separators=(',', ':'))
    print(f"{len(out)} games -> {os.path.normpath(dest)}")

if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
