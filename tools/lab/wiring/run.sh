#!/bin/sh
# Static wiring checks. No core runs, no simulator boots, no device is
# touched. Everything here is a question that can be answered by reading
# what is already in the repository, which is why it is the cheapest
# station and the first one to run.
#
# Each check exists because the thing it looks for has actually gone
# wrong here, or would fail silently rather than loudly if it did.
set -e
cd "$(dirname "$0")/../../.."

FAIL=0
note() { printf '  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=1; }

FRONTEND=RommApp/RommApp/Native/Libretro/LibretroFrontend.mm
HEADER=RommApp/RommApp/Native/Libretro/LibretroFrontend.h

# 1. Every core id has a coreAPI case.
#
# coreAPI() ends with "default: break;" and then returns the PlayStation
# core. A core id with no case of its own does not fail to load: it
# quietly runs PCSX ReARMed instead, which looks like the new core being
# broken in a baffling way rather than like a missing line. This is the
# single worst trap in adding a core, so it is the first check.
missing=""
for id in $(grep -oE 'LibretroCoreID[A-Za-z0-9]+ NS_SWIFT_NAME' "$HEADER" | awk '{print $1}'); do
    # The case labels live in coreAPI's switch; count them anywhere in the
    # file, since a case for a core that exists is what matters.
    if ! grep -q "case ${id}:" "$FRONTEND"; then
        missing="$missing $id"
    fi
done
if [ -n "$missing" ]; then
    bad "core ids with no coreAPI case, these silently run PCSX ReARMed:$missing"
else
    note "every core id has its own coreAPI case"
fi

# 2. Symbols that collide between cores.
#
# Every core is linked into one binary, so a symbol left as a common
# (an uninitialised global) is merged with any same-named symbol in
# another core: the two cores end up sharing one piece of storage. This
# has shipped five times, and an earlier collision between FBNeo and
# Genesis Plus GX on an internal "snd" was a real crash.
#
# The iOS archives are scoped and export nothing but their entry points.
# The tvOS archives are not, and currently leak 607 commons between them,
# five of which genuinely collide. Rather than fail forever on debt that
# predates this check, the known set is recorded next door and only a NEW
# collision fails. Shrinking that file is the fix; growing it is a bug.
KNOWN="$(dirname "$0")/known-collisions.txt"
ALL=$(mktemp); trap 'rm -f "$ALL"' EXIT
for a in RommApp/RommApp/Native/*/lib*_tvos.a; do
    nm -g "$a" 2>/dev/null | awk '$2=="C"{print $3}' | sort -u
done | sort | uniq -d > "$ALL"
new_collisions=$(comm -23 "$ALL" "$KNOWN")
if [ -n "$new_collisions" ]; then
    for c in $new_collisions; do bad "new symbol collision between tvOS cores: $c"; done
else
    known_count=$(wc -l < "$KNOWN" | tr -d ' ')
    note "no new symbol collisions ($known_count known, see known-collisions.txt)"
fi

# 3. Both platforms present for every core.
#
# A core built for iOS and forgotten for tvOS is invisible until someone
# opens that platform on the Apple TV and finds nothing there.
for ios in RommApp/RommApp/Native/*/lib*_ios.a; do
    tv=$(echo "$ios" | sed 's/_ios\.a$/_tvos.a/')
    [ -f "$tv" ] || bad "$(basename "$ios") has no tvOS counterpart"
done

# 4. Every native platform resolves to a control layout.
#
# A platform with no layout file of its own falls through to default.json
# and gets a generic pad. That is a real state some platforms are
# deliberately in, so this reports rather than fails, but it should never
# be a surprise.
missing_layouts=""
for slug in $(grep -oE '^    case [a-z0-9]+$' RommApp/RommApp/Native/NativeCore.swift | awk '{print $2}' | sort -u); do
    [ -f "RommApp/RommApp/Resources/ControlLayouts/${slug}.json" ] || missing_layouts="$missing_layouts $slug"
done
[ -n "$missing_layouts" ] && note "platforms using the fallback pad:$missing_layouts"

# 5. Every control layout is in the Layout Editor's own target.
#
# A layout that ships in the app but is missing from the editor cannot be
# tuned, and nothing says so: you open the editor, the system is simply
# not in the list, and it looks like the editor is broken rather than
# like a missing line in the project file. Marcus asked whether the new
# Virtual Boy layout was in the editor, which is how this gap was found;
# the per-core station had already reported that core clean.
#
# Both facts are in the project file, so this is a text comparison, and
# it is deliberately repo-wide rather than per-core: the invariant is
# "every layout is editable", which has nothing to do with which core
# happens to read it.
missing_editor=""
for f in RommApp/RommApp/Resources/ControlLayouts/*.json; do
    base=$(basename "$f")
    grep -q "ControlLayouts/$base" RommApp/RommApp.xcodeproj/project.pbxproj || \
        missing_editor="$missing_editor $base"
done
if [ -n "$missing_editor" ]; then
    for m in $missing_editor; do bad "layout $m is not in the Layout Editor target, so it cannot be tuned"; done
else
    count=$(ls RommApp/RommApp/Resources/ControlLayouts/*.json | wc -l | tr -d ' ')
    note "all $count control layouts are editable in the Layout Editor"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "WIRING OK"
else
    echo "WIRING PROBLEMS ABOVE"
    exit 1
fi
