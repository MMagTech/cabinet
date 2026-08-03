"""Build the platform to core map for the RomM iOS client from RomM's own
source, rather than by hand.

RomM's API exposes no endpoint that lists which cores a platform supports.
The list only exists as a constant in RomM's frontend, `_EJS_CORES_MAP` in
frontend/src/utils/index.ts, which is what its own player reads to decide
what to offer. A hand transcription of that constant drifted the first
time: two entries were removed on 2026-08-02 believing them fabricated,
sourced from the wrong file (EmulatorJS's own generic core registry, not
RomM's), when they were in fact real, just gated behind RomM's netplay
flag and excluded here for that reason, not because they do not exist. A
generator with a cited source cannot make that particular mistake again.

Only `_EJS_CORES_MAP`, the stable map every install ships, is used.
RomM's file also carries `_EJS_NIGHTLY_CORES_MAP`, layered in only when a
server has `EJS_NETPLAY_ENABLED` set, a per install admin toggle this app
has no way to detect. Seeding a core that only exists on some servers
would reproduce the exact bug this script exists to prevent: EmulatorJS
actually attempting to download a core file that is not there. Safe
degradation already exists for a platform this leaves with no entry at
all: the launch screen offers no core choice and RomM's own page decides,
which is exactly what happens for a platform RomM does not support at all.

Usage:
    python generate_cores_map.py -o ../RommApp/RommApp/Resources/cores.json
"""

import argparse
import json
import re
import sys
import urllib.request

SOURCE_URL = (
    "https://raw.githubusercontent.com/rommapp/romm/master"
    "/frontend/src/utils/index.ts"
)


def fetch_stable_map(url):
    with urllib.request.urlopen(url) as response:
        source = response.read().decode("utf-8", errors="replace")

    start = source.find("const _EJS_CORES_MAP")
    if start == -1:
        raise RuntimeError("_EJS_CORES_MAP not found; RomM may have renamed it")
    brace = source.find("{", start)
    end = source.find("} as const;", brace) + 1
    blob = source[brace:end]

    # This is TypeScript, not JSON: bare keys and single quoted platform
    # slugs that contain a hyphen. Quote keys, normalise quotes, drop
    # trailing commas, then it parses as JSON.
    blob = re.sub(r"([{,\[]\s*)([A-Za-z0-9_\-]+)(\s*:)", r'\1"\2"\3', blob)
    blob = blob.replace("'", '"')
    blob = re.sub(r",(\s*[}\]])", r"\1", blob)
    return json.loads(blob)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--output", default="cores.json")
    args = parser.parse_args()

    cores = fetch_stable_map(SOURCE_URL)
    print(f"{len(cores)} platforms from {SOURCE_URL}", file=sys.stderr)

    with open(args.output, "w") as handle:
        json.dump(cores, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"wrote {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
