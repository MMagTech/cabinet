"""
Parse MAME's listxml output into a control profile map for the RomM iOS client.

Usage:
    mame -listxml > mame.xml
    python mame_profiles.py mame.xml -o profiles.json

Output is a JSON object keyed by romset shortname:

    {
      "sf2ce": {
        "profile": "six_button",
        "buttons": 6,
        "ways": "8",
        "players": 2,
        "coins": 2,
        "control": "joy",
        "parent": "sf2",
        "source": "self"
      }
    }

"source" is "self" when the machine declared its own input element, or
"parent" when the values were inherited from its cloneof parent.
"""

import argparse
import json
import sys
from xml.etree import ElementTree


# Control types that a touchscreen or standard gamepad cannot reasonably
# emulate. These get flagged for the in-app picker rather than guessed at.
SPECIAL_CONTROLS = {
    "dial",
    "paddle",
    "trackball",
    "lightgun",
    "positional",
    "mouse",
    "pedal",
    "gambling",
    "hanafuda",
    "mahjong",
    "keypad",
    "keyboard",
}

# Genre substrings used only as a last resort, matched case-insensitively
# against RomM's mame_index genre field if one is supplied.
GENRE_HINTS = (
    ("fight", "six_button"),
    ("versus", "six_button"),
    ("maze", "four_way"),
    ("puzzle", "two_button"),
    ("shoot", "two_button"),
)


def classify(buttons, ways, players, control):
    """Map raw MAME input attributes onto a control profile name."""
    if control in SPECIAL_CONTROLS:
        return "special"

    if control == "doublejoy":
        return "dual_stick"

    if control in ("stick", "joy", "") or control is None:
        if ways == "4":
            return "four_way" if buttons == 0 else "four_way_buttons"
        if ways == "2":
            return "two_way"

    if buttons >= 6:
        return "six_button"
    if buttons == 5:
        return "five_button"
    if buttons == 4:
        return "four_button"
    if buttons == 3:
        return "three_button"
    if buttons == 2:
        return "two_button"
    if buttons == 1:
        return "one_button"
    return "no_buttons"


def read_input(machine):
    """Pull the input element's attributes off a machine element."""
    node = machine.find("input")
    if node is None:
        return None

    controls = node.findall("control")
    control_type = ""
    ways = ""

    # Prefer the first joystick-like control; fall back to whatever is first.
    for candidate in controls:
        kind = candidate.get("type", "")
        if kind in ("joy", "doublejoy", "stick"):
            control_type = kind
            ways = candidate.get("ways", "")
            break
    else:
        if controls:
            control_type = controls[0].get("type", "")
            ways = controls[0].get("ways", "")

    return {
        "buttons": int(node.get("buttons", 0) or 0),
        "players": int(node.get("players", 0) or 0),
        "coins": int(node.get("coins", 0) or 0),
        "ways": ways,
        "control": control_type,
    }


def parse(path, include_devices=False):
    """Stream the listxml and collect raw input data per machine."""
    raw = {}
    order = []

    context = ElementTree.iterparse(path, events=("end",))
    for _, element in context:
        if element.tag != "machine":
            continue

        name = element.get("name")
        if not name:
            element.clear()
            continue

        is_device = element.get("isdevice") == "yes"
        runnable = element.get("runnable") != "no"

        if (is_device or not runnable) and not include_devices:
            element.clear()
            continue

        raw[name] = {
            "input": read_input(element),
            "parent": element.get("cloneof"),
            "description": (element.findtext("description") or "").strip(),
        }
        order.append(name)
        element.clear()

    return raw, order


def resolve(raw, order, genres=None):
    """Apply the resolution chain and classify every machine."""
    genres = genres or {}
    out = {}
    stats = {"self": 0, "parent": 0, "genre": 0, "default": 0, "special": 0}

    for name in order:
        entry = raw[name]
        data = entry["input"]
        source = "self"

        # Step 2: inherit from the cloneof parent.
        if data is None:
            parent = entry["parent"]
            seen = set()
            while parent and parent in raw and parent not in seen:
                seen.add(parent)
                if raw[parent]["input"] is not None:
                    data = raw[parent]["input"]
                    source = "parent"
                    break
                parent = raw[parent]["parent"]

        # Step 3: genre heuristic, only if a genre map was supplied.
        if data is None:
            hint = (genres.get(name) or "").lower()
            profile = None
            for needle, guess in GENRE_HINTS:
                if needle in hint:
                    profile = guess
                    break
            if profile:
                out[name] = {
                    "profile": profile,
                    "buttons": None,
                    "ways": None,
                    "players": None,
                    "coins": None,
                    "control": None,
                    "parent": entry["parent"],
                    "source": "genre",
                }
                stats["genre"] += 1
                continue

        # Step 4: generic default.
        if data is None:
            out[name] = {
                "profile": "six_button",
                "buttons": None,
                "ways": None,
                "players": None,
                "coins": None,
                "control": None,
                "parent": entry["parent"],
                "source": "default",
            }
            stats["default"] += 1
            continue

        profile = classify(
            data["buttons"], data["ways"], data["players"], data["control"]
        )
        out[name] = {
            "profile": profile,
            "buttons": data["buttons"],
            "ways": data["ways"],
            "players": data["players"],
            "coins": data["coins"],
            "control": data["control"],
            "parent": entry["parent"],
            "source": source,
        }
        stats[source] += 1
        if profile == "special":
            stats["special"] += 1

    return out, stats


def main():
    parser = argparse.ArgumentParser(
        description="Build a control profile map from MAME listxml."
    )
    parser.add_argument("xml", help="Path to mame -listxml output")
    parser.add_argument(
        "-o", "--output", default="profiles.json", help="Output JSON path"
    )
    parser.add_argument(
        "--genres",
        help="Optional RomM mame_index.json, used for the genre fallback",
    )
    parser.add_argument(
        "--include-devices",
        action="store_true",
        help="Include non-runnable device entries",
    )
    parser.add_argument(
        "--compact", action="store_true", help="Write without indentation"
    )
    args = parser.parse_args()

    genres = {}
    if args.genres:
        with open(args.genres, encoding="utf-8") as handle:
            index = json.load(handle)
        genres = {
            key: (value.get("genre") or "")
            for key, value in index.items()
            if isinstance(value, dict)
        }

    raw, order = parse(args.xml, include_devices=args.include_devices)
    resolved, stats = resolve(raw, order, genres)

    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(
            resolved, handle, indent=None if args.compact else 2, sort_keys=True
        )

    counts = {}
    for entry in resolved.values():
        counts[entry["profile"]] = counts.get(entry["profile"], 0) + 1

    print(f"machines: {len(resolved)}", file=sys.stderr)
    print("resolution:", file=sys.stderr)
    for key in ("self", "parent", "genre", "default"):
        print(f"  {key:>8}: {stats[key]}", file=sys.stderr)
    print("profiles:", file=sys.stderr)
    for key in sorted(counts, key=lambda k: -counts[k]):
        print(f"  {key:>18}: {counts[key]}", file=sys.stderr)
    print(f"wrote {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
