#!/bin/sh
# Brings the layouts Marcus has marked GREEN in the editor into the
# repository. This is the ONLY direction layouts are supposed to travel.
#
# The editor is the source of truth for controls. He edits on the phone,
# marks a layout ready when it is good, and this collects the ready ones.
# Pushing the repo's copies back onto the device is not part of the
# workflow and overwrites work in progress; do not do it.
#
# Green is a zero-byte "<name>.ready" marker beside the working copy, so
# finding them needs no parsing and no app-side cooperation.
#
# Usage: sh tools/lab/layouts/pull-ready.sh [--dry-run]
set -e
cd "$(dirname "$0")/../../.."

PHONE=4B536CB7-E086-5C97-AA3F-6C38C6395301
ID=com.mmagtech.CabinetLayoutEditor
DEST=RommApp/RommApp/Resources/ControlLayouts
TMP=$(mktemp -d)

echo "== looking for green marks =="
xcrun devicectl device info files --device $PHONE --domain-type appDataContainer \
    --domain-identifier $ID 2>/dev/null \
  | grep -oE "Working/[A-Za-z0-9_-]+\.ready" | sed 's|Working/||;s|\.ready||' | sort -u > "$TMP/ready"
echo "   $(wc -l < "$TMP/ready" | tr -d ' ') marked ready"

for n in $(cat "$TMP/ready"); do
    xcrun devicectl device copy from --device $PHONE --domain-type appDataContainer \
        --domain-identifier $ID --source "Documents/Working/$n.json" \
        --destination "$TMP/$n.json" >/dev/null 2>&1 || { echo "   FAILED to fetch $n"; continue; }
    if [ "$1" = "--dry-run" ]; then
        if cmp -s "$TMP/$n.json" "$DEST/$n.json"; then echo "   $n unchanged"
        else echo "   $n WOULD UPDATE"; fi
    else
        cp "$TMP/$n.json" "$DEST/$n.json"
        echo "   $n"
    fi
done

echo "== checking what came in =="
python3 tools/lab/layouts/check.py
