#!/bin/sh
# One command for a control-layout change, so shipping it is not a thing
# anyone has to remember.
#
# Marcus, 2026-08-24, after being told twice that an app was updated
# when it was not, and then having to ask again: "I shouldn't need to
# keep reminding you."
#
# The trap is that a layout lives in FOUR places at once. The repo has
# it; both apps BUNDLE it, so a layout change is a code change as far
# as they are concerned and needs a build and an install; and the
# editor keeps a working copy per layout on the phone which SHADOWS the
# bundled one, so the repo can be right while every surface a person
# actually touches is stale. Fixing the JSON is the smallest part of
# the job.
#
# Usage: sh tools/lab/layouts/ship.sh [--no-device]
set -e
cd "$(dirname "$0")/../../.."

PHONE=4B536CB7-E086-5C97-AA3F-6C38C6395301
TV=539DFD4E-FAAB-56D5-A39D-34D941DA2754
DD=/Users/mmagtech/Library/Developer/Xcode/DerivedData/RommApp-coelcbauvffcdyhahywaajactsyf/Build/Products

echo "== rules =="
python3 tools/lab/layouts/check.py

echo "== building (layouts are bundled, so this is not optional) =="
# Piping xcodebuild into grep hands the PIPELINE grep's exit status, so
# `set -e` never sees a failed build and the script sails on to install
# a stale binary. That is exactly how a broken Layout Editor reached
# Marcus's phone on 2026-08-24: the build had been failing for half an
# hour and every run still printed its way to "done". Capture the log,
# check the real status, print only on failure.
build() {
    scheme=$1; dest=$2
    log=$(mktemp)
    if xcodebuild -project RommApp/RommApp.xcodeproj -scheme "$scheme" \
            -destination "$dest" -configuration Debug build >"$log" 2>&1; then
        echo "   $scheme built"
    else
        echo "   $scheme FAILED:" >&2
        grep -E "error:" "$log" | head -5 >&2
        exit 1
    fi
}
build LayoutEditor 'generic/platform=iOS'
build RommApp      'generic/platform=iOS'
build RommAppTV    'generic/platform=tvOS'

[ "$1" = "--no-device" ] && { echo "(skipping devices)"; exit 0; }

echo "== installing =="
for app in "Layout Editor" "Cabinet"; do
    xcrun devicectl device install app --device $PHONE "$DD/Debug-iphoneos/$app.app" \
        >/dev/null 2>&1 && echo "   $app -> phone" || echo "   FAILED $app"
done
xcrun devicectl device install app --device $TV "$DD/Debug-appletvos/Cabinet TV.app" \
    >/dev/null 2>&1 && echo "   Cabinet TV -> Apple TV" || echo "   FAILED Cabinet TV"

echo "== the editor's working copies, which shadow all of the above =="
WORK=$(mktemp -d)
xcrun devicectl device copy from --device $PHONE --domain-type appDataContainer \
    --domain-identifier com.mmagtech.CabinetLayoutEditor \
    --source "Documents/Working" --destination "$WORK" >/dev/null 2>&1
python3 tools/lab/layouts/check.py "$WORK" || {
    echo "   working copies FAIL the rules; repair and re-run" >&2; exit 1; }
echo "== done =="
