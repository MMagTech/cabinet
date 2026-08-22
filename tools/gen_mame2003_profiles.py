"""
Build the MAME 2003-Plus control profile map from that generation's own
listxml.

The bundled profiles.json comes from a modern MAME listxml, which is the
right source for FBNeo and for the webview player but not for the core
this app actually runs: mame2003-plus is a 0.78 derivative, and twenty
years separate the two input databases. That gap is not academic. 872
games this core runs are absent from the modern file entirely and fall
through to the generic six button guess, and 483 more carry a button
count the 0.78 driver disagrees with, which is a dead button drawn on
the glass or a working one missing from it.

So this reads the reference set's listxml, the one that matches the core
release for release, and writes a second map the native player consults
only when MAME 2003-Plus is the running core. Nothing else reads it, so
FBNeo and the webview keep the modern file byte for byte.

Usage:
    python3 tools/gen_mame2003_profiles.py \
        "/Volumes/T9/MAME_2003-Plus_Reference_Set_2018/MAME 2003-Plus - 2018-12-31.xml" \
        -o RommApp/RommApp/Resources/ArcadeProfiles/mame2003-profiles.json

The old DTD differs from the modern one in three ways that matter:
machines are <game> not <machine>, the control type and its ways are
fused into one string ("joy8way") rather than split across attributes,
and there is exactly one control per game, so a cabinet's second
mechanism is invisible here. That last one is why this file decides the
profile and the button count and nothing else: pedals, rotary sticks and
every other panel fact stay in arcade-panels.json, which states what the
player's hands were on rather than inferring it.

Rows match profiles.json's shape exactly so the app parses both with one
code path: [profile, buttons, ways, coins, parent, vertical], trimmed
from the tail wherever the values are empty or zero.
"""

import argparse
import json
import re
import sys
from xml.etree import ElementTree

from mame_profiles import classify

# "joy8way", "doublejoy4way": the old DTD fuses the kind and the ways.
JOY = re.compile(r"^(doublejoy|joy)(\d+)way$")


def split_control(control):
    """Normalise an old control string onto the modern (kind, ways) pair
    that classify() expects."""
    if not control:
        return "", ""
    match = JOY.match(control)
    if match:
        return match.group(1), match.group(2)
    return control, ""


def read_game(game):
    node = game.find("input")
    if node is None:
        return None
    # 205 machines declare an input element that names neither a control
    # nor a button: the mahjong and gambling panels, whose keypads this
    # generation of listxml had no vocabulary for, plus a handful of dead
    # entries with no players. That is an absence of data, not a machine
    # with nothing on its panel, and the modern map describes them well.
    # Recording them here would let a blank row outrank a good one.
    if node.get("control") is None and node.get("buttons") is None:
        return None
    kind, ways = split_control(node.get("control", ""))
    return {
        "buttons": int(node.get("buttons", 0) or 0),
        "players": int(node.get("players", 0) or 0),
        "coins": int(node.get("coins", 0) or 0),
        "ways": ways,
        "control": kind,
    }


def read_vertical(game):
    video = game.find("video")
    if video is None:
        return False
    return video.get("orientation") == "vertical"


def parse(path):
    raw, order = {}, []
    for _, element in ElementTree.iterparse(path, events=("end",)):
        if element.tag != "game":
            continue
        name = element.get("name")
        if name and element.get("runnable") != "no":
            raw[name] = {
                "input": read_game(element),
                "vertical": read_vertical(element),
                "parent": element.get("cloneof"),
            }
            order.append(name)
        element.clear()
    return raw, order


def resolve(raw, order):
    out, stats = {}, {"self": 0, "parent": 0, "absent": 0}
    for name in order:
        entry = raw[name]
        data, source = entry["input"], "self"

        # A handful of clones declare no input of their own. Walk up the
        # cloneof chain the same way the modern generator does.
        if data is None:
            parent, seen = entry["parent"], set()
            while parent and parent in raw and parent not in seen:
                seen.add(parent)
                if raw[parent]["input"] is not None:
                    data, source = raw[parent]["input"], "parent"
                    break
                parent = raw[parent]["parent"]

        # Nothing of its own and nothing to inherit: leave it out. The app
        # falls back to the modern map, which is the right answer for a
        # game this file cannot describe.
        if data is None:
            stats["absent"] += 1
            continue

        profile = classify(
            data["buttons"], data["ways"], data["players"], data["control"]
        )
        out[name] = [
            profile,
            data["buttons"],
            data["ways"],
            data["coins"],
            entry["parent"] or "",
            1 if entry["vertical"] else 0,
        ]
        stats[source] += 1
    return out, stats


def trim(row):
    """Drop empty and zero values from the tail, as profiles.json does."""
    while len(row) > 1 and not row[-1]:
        row.pop()
    return row


def main():
    parser = argparse.ArgumentParser(
        description="Build the MAME 2003-Plus profile map from its own listxml."
    )
    parser.add_argument("xml", help="Path to the 2003-Plus reference listxml")
    parser.add_argument("-o", "--output", required=True, help="Output JSON path")
    args = parser.parse_args()

    raw, order = parse(args.xml)
    resolved, stats = resolve(raw, order)
    rows = {name: trim(row) for name, row in resolved.items()}

    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(rows, handle, separators=(",", ":"), sort_keys=True)

    counts = {}
    for row in rows.values():
        counts[row[0]] = counts.get(row[0], 0) + 1
    print(f"games: {len(rows)}", file=sys.stderr)
    for key in ("self", "parent", "absent"):
        print(f"  {key:>8}: {stats[key]}", file=sys.stderr)
    for key in sorted(counts, key=lambda k: -counts[k]):
        print(f"  {key:>18}: {counts[key]}", file=sys.stderr)
    print(f"wrote {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
