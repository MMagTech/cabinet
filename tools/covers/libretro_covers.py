#!/usr/bin/env python3
"""Fills in cover art from libretro's thumbnail repository.

For platforms whose games IGDB has never heard of. Game & Watch and the
other LCD handhelds are the case this was written for: 59 titles, none
matched, no art, because IGDB has no entries for most obscure
electronic handhelds. libretro's thumbnail set does, named by the same
No-Intro convention the ROMs use, so the two line up exactly.

Naming: libretro replaces '&' with '_' in filenames and leaves
everything else alone, so "Banana (VTech, Time & Fun).mgw" pairs with
"Banana (VTech, Time _ Fun).png".

Credentials: this needs roms.write, which a device-flow token does not
carry, so it authenticates as you over HTTP basic. It reads the
password from the ROMM_PASSWORD environment variable and never takes
it on the command line, where it would land in shell history.

  export ROMM_PASSWORD='...'
  python3 tools/covers/libretro_covers.py --platform 47 \
      --set "Handheld Electronic Game" [--dry-run]

--dry-run reports what it would match and changes nothing.
"""
import argparse, getpass, html, json, os, re, sys, urllib.parse, urllib.request

BASE = os.environ.get('ROMM_URL', 'http://192.168.1.10:6005')
THUMBS = 'https://thumbnails.libretro.com'

def get(url, auth=None):
    req = urllib.request.Request(url)
    if auth: req.add_header('Authorization', auth)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--platform', type=int, required=True)
    ap.add_argument('--set', required=True, help='libretro system folder name')
    ap.add_argument('--user', default='MMagTech')
    ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args()

    pw = os.environ.get('ROMM_PASSWORD') or getpass.getpass('RomM password: ')
    import base64
    auth = 'Basic ' + base64.b64encode(f'{a.user}:{pw}'.encode()).decode()

    roms = json.loads(get(f'{BASE}/api/roms?platform_ids={a.platform}&limit=500', auth))
    roms = roms.get('items', roms) if isinstance(roms, dict) else roms
    print(f'{len(roms)} roms on platform {a.platform}')

    folder = urllib.parse.quote(a.set)
    listing = get(f'{THUMBS}/{folder}/Named_Boxarts/').decode('utf-8', 'replace')
    thumbs = {urllib.parse.unquote(m) for m in re.findall(r'href="([^"]+\.png)"', listing)}
    print(f'{len(thumbs)} thumbnails in "{a.set}"')

    done = skipped = failed = 0
    for r in roms:
        stem = r['fs_name'].rsplit('.', 1)[0]
        want = stem.replace('&', '_') + '.png'
        if want not in thumbs:
            print(f'  no art  {stem}')
            skipped += 1
            continue
        if a.dry_run:
            print(f'  would set  {stem}')
            done += 1
            continue
        img = get(f'{THUMBS}/{folder}/Named_Boxarts/{urllib.parse.quote(want)}')
        boundary = '----romm-cover-boundary'
        body = (
            f'--{boundary}\r\n'
            f'Content-Disposition: form-data; name="artwork"; filename="{want}"\r\n'
            f'Content-Type: image/png\r\n\r\n').encode() + img + f'\r\n--{boundary}--\r\n'.encode()
        req = urllib.request.Request(f'{BASE}/api/roms/{r["id"]}', data=body, method='PUT')
        req.add_header('Authorization', auth)
        req.add_header('Content-Type', f'multipart/form-data; boundary={boundary}')
        try:
            urllib.request.urlopen(req, timeout=120)
            print(f'  set     {stem}')
            done += 1
        except Exception as e:
            print(f'  FAILED  {stem}: {e}')
            failed += 1
    print(f'\n{done} covers, {skipped} without art, {failed} failed')

main()
