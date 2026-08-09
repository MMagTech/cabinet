#!/usr/bin/env python3
"""Pull LayoutEditor working copies and report which are real, worth applying.

This exists because reconstructing this logic by hand, in prose, in a fresh
session with no memory of how it was done before, is exactly how a real edit
sat unapplied: "another session couldn't figure out what to do with the
layout I made." This script is the fix. Run it, read the report, copy in
whatever it says improved. It never writes into Resources/ControlLayouts
itself, that stays a deliberate manual step on purpose, same as the rest of
this workflow (see the layout-editor-companion-app memory).

Usage:
    tools/pull_layout_edits.py                  # physical iPhone (default)
    tools/pull_layout_edits.py --device UDID     # a different physical device
    tools/pull_layout_edits.py --simulator UDID  # a booted simulator instead

What "real" means here: a working copy that is byte-different from the
committed file is not automatically a real edit. Every export round-trips
through 4-decimal rounding, which quietly fixes pre-existing float drift
(psx.json had `0.020000000000000004` where `0.02` was meant) and reads as a
diff even though nothing moved. This script diffs with a tolerance well past
that rounding noise, so only genuine repositioning counts as CHANGED.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

BUNDLE_ID = "com.mmagtech.CabinetLayoutEditor"
DEFAULT_DEVICE_UDID = "4B536CB7-E086-5C97-AA3F-6C38C6395301"  # Marcus's iPhone, macos-environment-facts memory
REPO_LAYOUTS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "RommApp", "Resources", "ControlLayouts",
)
TOLERANCE = 0.0005  # well past the export's own 4-decimal rounding
DIRECTIONAL_KINDS = {"dpad", "stick"}
PERSIST_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".layout_pulls")


def pull_from_device(udid, dest):
    subprocess.run(
        [
            "xcrun", "devicectl", "device", "copy", "from",
            "--device", udid,
            "--domain-type", "appDataContainer",
            "--domain-identifier", BUNDLE_ID,
            "--source", "/Documents",
            "--destination", dest,
        ],
        check=True, capture_output=True, text=True,
    )
    return os.path.join(dest, "Working")


def pull_from_simulator(udid, dest):
    result = subprocess.run(
        ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
        check=True, capture_output=True, text=True,
    )
    container = result.stdout.strip()
    working = os.path.join(container, "Documents", "Working")
    shutil.copytree(working, dest)
    return dest


def rect_intersects(a, b):
    return (
        a["x"] < b["x"] + b["w"] and b["x"] < a["x"] + a["w"]
        and a["y"] < b["y"] + b["h"] and b["y"] < a["y"] + a["h"]
    )


def count_overlaps(items):
    red = orange = 0
    items = items or []
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            a, b = items[i], items[j]
            if not rect_intersects(a["extended"], b["extended"]):
                continue
            if a["kind"] in DIRECTIONAL_KINDS or b["kind"] in DIRECTIONAL_KINDS:
                red += 1
            else:
                orange += 1
    return red, orange


def numeric_diff(a, b, path=""):
    """True if a and b differ by more than TOLERANCE anywhere, recursively."""
    if isinstance(a, dict) and isinstance(b, dict):
        return any(numeric_diff(a.get(k), b.get(k), f"{path}.{k}") for k in set(a) | set(b))
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return True
        return any(numeric_diff(x, y, f"{path}[{i}]") for i, (x, y) in enumerate(zip(a, b)))
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(a - b) > TOLERANCE
    return a != b


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", nargs="?", const=DEFAULT_DEVICE_UDID, default=None, help="physical device UDID")
    parser.add_argument("--simulator", metavar="UDID", help="simulator UDID instead of a physical device")
    args = parser.parse_args()

    if not args.simulator and not args.device:
        args.device = DEFAULT_DEVICE_UDID

    with tempfile.TemporaryDirectory() as tmp:
        dest = os.path.join(tmp, "pull")
        try:
            if args.simulator:
                working_dir = pull_from_simulator(args.simulator, dest)
            else:
                working_dir = pull_from_device(args.device, dest)
        except subprocess.CalledProcessError as e:
            print(f"Pull failed: {e.stderr or e}", file=sys.stderr)
            sys.exit(1)

        if not os.path.isdir(working_dir):
            print("No Working folder found, nothing has been edited yet.")
            return

        names = sorted(f[:-5] for f in os.listdir(working_dir) if f.endswith(".json"))
        if not names:
            print("No working copies found.")
            return

        found_real_edit = False
        for name in names:
            repo_path = os.path.join(REPO_LAYOUTS_DIR, f"{name}.json")
            dev_path = os.path.join(working_dir, f"{name}.json")
            ready = os.path.exists(os.path.join(working_dir, f"{name}.ready"))

            if not os.path.exists(repo_path):
                print(f"SKIP  {name}  (no matching file in the repo)")
                continue

            with open(repo_path) as f:
                repo_json = json.load(f)
            with open(dev_path) as f:
                dev_json = json.load(f)

            if not numeric_diff(repo_json, dev_json):
                tag = "noise-only (matches the repo once rounding is ignored)"
                print(f"{'READY ' if ready else '      '}{name:12s}  {tag}")
                continue

            found_real_edit = True
            r_red, r_orange = count_overlaps(repo_json.get("items"))
            d_red, d_orange = count_overlaps(dev_json.get("items"))
            rl_red, rl_orange = count_overlaps(repo_json.get("landscapeItems"))
            dl_red, dl_orange = count_overlaps(dev_json.get("landscapeItems"))
            better = (d_red + dl_red, d_orange + dl_orange) <= (r_red + rl_red, r_orange + rl_orange)
            verdict = "IMPROVED" if better else "CHECK THIS ONE"
            print(f"{'READY ' if ready else '      '}{verdict:15s}{name:12s}  "
                  f"portrait {r_red}/{r_orange}->{d_red}/{d_orange}  "
                  f"landscape {rl_red}/{rl_orange}->{dl_red}/{dl_orange}")
            # Copied out of the temp pull before it's cleaned up on exit, or
            # this cp line would print a path that's already gone by the
            # time anyone reads it, exactly the kind of thing that leaves a
            # fresh session stuck.
            os.makedirs(PERSIST_DIR, exist_ok=True)
            persisted = os.path.join(PERSIST_DIR, f"{name}.json")
            shutil.copy2(dev_path, persisted)
            print(f"           cp {persisted} {repo_path}")

        if not found_real_edit:
            print("\nNothing has actually changed, every working copy matches the repo.")


if __name__ == "__main__":
    main()
