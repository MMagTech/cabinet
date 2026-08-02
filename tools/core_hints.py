"""Build the arcade core hint map for the RomM iOS client.

Some arcade boards are better served by a core built for that board alone
than by a general one. FinalBurn Neo carries drivers for thousands of
machines, and on iOS that breadth is not free: the webview's content
process runs under a memory ceiling, and CPS2 games on FBNeo sit over it.
The same games on fbalpha2012_cps2, which knows one board and nothing
else, stay comfortably under. Verified on device with Progear and Armored
Warriors, both of which died about a minute into play on FBNeo and are
steady on the CPS2 core.

The romset lists come from MAME's own driver sources, which are the
authoritative statement of which machines belong to which board, and are
parsed here rather than transcribed so the map cannot drift from a typo.

Usage:
    python core_hints.py -o ../RommApp/RommApp/Resources/CoreHints/core_hints.json
"""

import argparse
import json
import re
import sys
import urllib.request

# MAME driver source to the libretro core that specialises in it.
BOARDS = {
    "https://raw.githubusercontent.com/mamedev/mame/master/src/mame/capcom/cps1.cpp":
        "fbalpha2012_cps1",
    "https://raw.githubusercontent.com/mamedev/mame/master/src/mame/capcom/cps2.cpp":
        "fbalpha2012_cps2",
}

# GAME(year, romset, parent, machine, input, class, init, rot, company, ...)
# GAMEL and friends share the shape, so the prefix is matched loosely.
GAME_RE = re.compile(r"\bGAME[A-Z]*\s*\(\s*[^,]+,\s*([A-Za-z0-9_]+)\s*,")


def romsets(url):
    with urllib.request.urlopen(url) as response:
        source = response.read().decode("utf-8", errors="replace")
    return sorted(set(GAME_RE.findall(source)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--output", default="core_hints.json")
    args = parser.parse_args()

    hints = {}
    for url, core in BOARDS.items():
        names = romsets(url)
        print(f"{core}: {len(names)} romsets", file=sys.stderr)
        for name in names:
            hints[name] = core

    with open(args.output, "w") as handle:
        json.dump(hints, handle, indent=0, sort_keys=True)
    print(f"wrote {len(hints)} hints to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
