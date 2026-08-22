#!/bin/sh
# Bring-up checklist for one core: everything a newly added core needs,
# asked in one place, so the answer is a list rather than an evening.
#
# `tools/lab/lab core <name>` has been advertised in the lab's own help
# since the lab existed and called this file, which did not exist. This
# is that file.
#
# Why these checks and not others: each one is a failure that has really
# happened, and the two most expensive both happened on 2026-08-22, when
# three cores were added in a day and two of them reached a device broken.
#
#   Vectrex shipped unplayable. vecx is the first core in the app to emit
#   RGB1555, and that format had no GPU decode path, so it fell onto a
#   leftover per-pixel CPU loop. At its 1320x1640 output that is 2.16
#   million conversions a frame on the main thread, which delayed UIKit's
#   touch delivery so badly the buttons appeared dead. Nothing asked
#   "does this core's pixel format have a path".
#
#   3DO shipped with no controls at all. Opera keeps its port devices in
#   a zeroed array, zero means nothing plugged in, and its input loop
#   skips empty ports, so it polled nothing until the frontend negotiated
#   a device. Dreamcast and N64 had each hit this before. Nothing asked
#   "does this core need a port device".
#
# The headless bench cannot catch that second one by construction: it
# negotiates a joypad on every port unconditionally, so a core with this
# bug measures perfectly healthy. That blind spot is the reason this
# station reads source rather than running anything.
set -e
cd "$(dirname "$0")/../.."

NAME=$1
if [ -z "$NAME" ]; then
    echo "usage: tools/lab/lab core <name>" >&2
    echo >&2
    echo "known cores (from the build script's own table):" >&2
    # Only the core table. build-core.sh also has a platform switch
    # whose cases (ios, tvos) are not cores.
    awk '/^case "\$NAME" in/{on=1;next} on&&/^esac/{exit} on&&/^[a-z0-9_]+\)$/{gsub(/\)/,"");print "  "$0}' \
        tools/build-core.sh >&2
    exit 2
fi

FRONTEND=RommApp/RommApp/Native/Libretro/LibretroFrontend.mm
HEADER=RommApp/RommApp/Native/Libretro/LibretroFrontend.h
RENDERER=RommApp/RommApp/Native/NativePlayerRenderer.swift
SRC=spikes/cores/$NAME/src

FAIL=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=1; }
note() { printf '  ...   %s\n' "$1"; }

echo "=== $NAME"

# The archive pair, named from the build script's own table so this
# cannot drift from what actually gets built.
OUT=$(awk -v n="$NAME" '
    $0 ~ "^"n"\\)" {found=1}
    found && /OUT=/ {
        match($0, /OUT=[A-Za-z0-9_]+/);
        s=substr($0, RSTART+4, RLENGTH-4); print s; exit
    }' tools/build-core.sh)
LIB=$(awk -v n="$NAME" '
    $0 ~ "^"n"\\)" {found=1}
    found && /LIB=/ {
        match($0, /LIB=lib[A-Za-z0-9_]+_ios\.a/);
        s=substr($0, RSTART+4, RLENGTH-4); print s; exit
    }' tools/build-core.sh)

if [ -z "$OUT" ] || [ -z "$LIB" ]; then
    bad "no entry in tools/build-core.sh, so this core cannot be built by the standard path"
    OUT=""; LIB=""
fi

if [ -n "$OUT" ]; then
    IOS="RommApp/RommApp/Native/$OUT/$LIB"
    TVOS=$(echo "$IOS" | sed 's/_ios\.a$/_tvos.a/')
    for a in "$IOS" "$TVOS"; do
        if [ -f "$a" ]; then
            C=$(nm "$a" 2>/dev/null | awk '$2 == "C"' | wc -l | tr -d ' ')
            T=$(nm -g "$a" 2>/dev/null | grep -c ' T ' || true)
            if [ "$C" -ne 0 ]; then
                bad "$(basename "$a") has $C common symbols; they merge with other cores' storage"
            else
                ok "$(basename "$a") scoped clean, $T exported entry points"
            fi
        else
            bad "$(basename "$a") missing; a core built for one platform only is invisible on the other"
        fi
    done
fi

# Wiring, in the order a launch travels through it. Any one of these
# missing means the core is unreachable or, worse, silently runs a
# different core.
PREFIX=$(awk -v n="$NAME" '
    $0 ~ "^"n"\\)" {found=1}
    found && /PREFIX=/ {
        match($0, /PREFIX=[A-Za-z0-9_]+/);
        s=substr($0, RSTART+7, RLENGTH-7); print s; exit
    }' tools/build-core.sh)
[ -n "$PREFIX" ] && ok "symbol prefix ${PREFIX}_retro_*"

WIRING=$(ls RommApp/RommApp/Native/*/[A-Za-z0-9]*Core.mm 2>/dev/null \
    | xargs grep -l "${PREFIX}_retro_api_version" 2>/dev/null | head -1)
if [ -n "$PREFIX" ] && [ -z "$WIRING" ]; then
    bad "no wiring file fills a LibretroCoreAPI with ${PREFIX}_retro_* symbols"
elif [ -n "$WIRING" ]; then
    ok "wiring file $(basename "$WIRING")"
    # The function NAME, not the return type: the wiring file's first
    # match for [A-Za-z0-9]+CoreAPI is "LibretroCoreAPI", which is the
    # type every one of these returns. Anchor on the definition instead.
    FN=$(grep -oE '\*[A-Za-z0-9]+CoreAPI\(void\)' "$WIRING" | head -1 | tr -d '*()' | sed 's/void$//')
    if grep -q "return ${FN}();" "$FRONTEND"; then
        ok "coreAPI() returns it"
    else
        bad "coreAPI() has no case returning ${FN}(); the id would silently run PCSX ReARMed"
    fi
fi

# What pixel format does this core actually ask for, and does the
# renderer have a path for it? This is the Vectrex failure.
if [ -d "$SRC" ]; then
    FORMATS=$(grep -rhoE 'RETRO_PIXEL_FORMAT_(RGB565|XRGB8888|0RGB1555)' "$SRC" \
        --include=*.c --include=*.cpp --include=*.cxx 2>/dev/null \
        | sort -u | tr '\n' ' ')
    if [ -n "$FORMATS" ]; then
        for f in $FORMATS; do
            case "$f" in
            *RGB565)    key=RGB565 ;;
            *XRGB8888)  key=XRGB8888 ;;
            *0RGB1555)  key=RGB1555 ;;
            esac
            # Case labels in the renderer are combined, e.g.
            # "case .XRGB8888, .RGBA8888:", so match the format anywhere
            # in a case line rather than as the whole label.
            if grep -qE "^ *case .*\.$key[,:]" "$RENDERER"; then
                if grep -A24 -E "^ *case .*\.$key[,:]" "$RENDERER" | grep -qiE 'unpack|texture\?\.replace'; then
                    ok "emits $key, renderer has a path"
                else
                    note "emits $key, renderer path unclear, read it"
                fi
            else
                bad "emits $key and the renderer has NO case for it"
            fi
        done
        # The specific trap: a CPU conversion loop on a high-resolution core.
        if echo "$FORMATS" | grep -q 1555; then
            if grep -q "unpackRGB1555" "$RENDERER"; then
                ok "RGB1555 decodes on the GPU, not the main thread"
            else
                bad "RGB1555 has no GPU path; at high resolutions this starves touch input"
            fi
        fi
    else
        note "no pixel format found in source, core may set it dynamically"
    fi

    # Does this core ignore retro_set_controller_port_device, or need it?
    # An empty body means it does not care. A real body means a platform
    # that never negotiates a device may get no input at all. This is the
    # 3DO failure, and Dreamcast and N64 before it.
    #
    # Matched on the function name alone, NOT on "void retro_set_...":
    # libretro cores routinely put the return type on its own line, which
    # is exactly how Opera declares it, so the stricter pattern silently
    # matched nothing and this check quietly did not run on the one core
    # it was written for. A check that skips itself is worse than no
    # check, so an undetermined answer is now reported rather than
    # passed over.
    PORTBODY=$(grep -rh -A4 '^retro_set_controller_port_device\|[^a-z_]retro_set_controller_port_device *(' "$SRC" \
        --include=*.c --include=*.cpp --include=*.cxx 2>/dev/null \
        | grep -v 'retro_set_controller_port_device *;' | head -20)
    if [ -z "$PORTBODY" ]; then
        note "could not find retro_set_controller_port_device in source, check by hand"
    elif echo "$PORTBODY" | grep -qE '\{ *\}'; then
        ok "ignores set_controller_port_device, no device negotiation needed"
    else
        # It does something. Every platform this core serves must appear in
        # padDevice(for:), or the core is handed no device and may poll
        # nothing at all.
        # It implements the call. That is NOT the same as requiring it,
        # and no amount of grepping can tell the two apart: PCSX ReARMed
        # implements it and works fine unnegotiated because it defaults
        # its ports sensibly, while Opera implements it and polls nothing
        # at all until it is called, because its device array starts
        # zeroed and zero means "nothing plugged in".
        #
        # So this reports rather than fails. An earlier version failed
        # here and flagged half the cores in the app, which is the fastest
        # way to make a checklist ignored.
        note "implements set_controller_port_device. If input is dead on"
        note "  first bring-up, padDevice(for:) in NativeCoreOptions.swift"
        note "  is the first place to look: it is what negotiates a device,"
        note "  and Dreamcast, N64 and 3DO all needed naming there."
    fi

else
    note "no vendored source at $SRC, skipping format and input checks"
fi

# Licensing, which every core has and which one shipped without.
if [ -n "$OUT" ]; then
    LNAME=$(echo "$NAME" | tr '_' '-')
    if grep -qi "$NAME\|$LNAME" docs/licenses.md; then ok "listed in docs/licenses.md"
    else bad "not listed in docs/licenses.md"; fi
    if ls RommApp/RommApp/Resources/Licenses/ 2>/dev/null | grep -qi "^${LNAME}\.txt$\|^${NAME}\.txt$"; then
        ok "bundled licence text present"
    else
        note "no Licenses/${LNAME}.txt; check what LicensesView calls it"
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "CORE OK"
else
    echo "CORE PROBLEMS ABOVE"
    exit 1
fi
