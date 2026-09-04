#!/bin/zsh
# Sign, notarize and package Cabinet for Mac from an archive.
#
#   tools/release-mac.sh <path/to/Cabinet-Mac.xcarchive> <version> <profile.provisionprofile>
#
# Produces Cabinet-mac-<version>.dmg next to the archive. Why this exists
# instead of `xcodebuild -exportArchive`: see the Mac release notes in
# CLAUDE.md. The archive itself comes from
#   xcodebuild archive -scheme RommAppMac \
#     -destination "generic/platform=macOS,variant=Mac Catalyst" -archivePath …
# Needs the Developer ID Application certificate in the login keychain
# and the App Store Connect API key for notarization.
set -e
ARCHIVE=$1; VERSION=$2; PROFILE=$3
[ -d "$ARCHIVE" ] && [ -n "$VERSION" ] && [ -f "$PROFILE" ] || { echo "usage: $0 <archive> <version> <profile>"; exit 1; }
KEY=~/.appstoreconnect/private_keys/AuthKey_J2W42KSTLD.p8; KEYID=J2W42KSTLD; ISSUER=4184c3b4-a7ad-415c-abb8-6e1b17c25f31
IDENTITY="Developer ID Application: Marcus Magnant (ZMUB88RZ5D)"
OUT=$(dirname "$ARCHIVE"); WORK="$OUT/mac-signed"; rm -rf "$WORK"; mkdir -p "$WORK"
cp -R "$ARCHIVE/Products/Applications/Cabinet Mac.app" "$WORK/Cabinet.app"
APP="$WORK/Cabinet.app"
cat > "$WORK/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>ZMUB88RZ5D.com.mmagtech.Cabinet.mac</string>
<key>com.apple.developer.team-identifier</key><string>ZMUB88RZ5D</string>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>keychain-access-groups</key><array><string>ZMUB88RZ5D.com.mmagtech.Cabinet.mac</string></array>
</dict></plist>
PLIST
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
for fw in "$APP/Contents/Frameworks/"*.framework; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$fw"
done
codesign --force --options runtime --timestamp --entitlements "$WORK/entitlements.plist" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "$WORK/upload.zip"
xcrun notarytool submit "$WORK/upload.zip" --key "$KEY" --key-id "$KEYID" --issuer "$ISSUER" --wait | grep -E "status:" | tail -1 | grep -q Accepted
xcrun stapler staple "$APP"
rm -rf "$WORK/dmg-root"; mkdir -p "$WORK/dmg-root"; cp -R "$APP" "$WORK/dmg-root/Cabinet.app"; ln -s /Applications "$WORK/dmg-root/Applications"
DMG="$OUT/Cabinet-mac-$VERSION.dmg"; rm -f "$DMG"
hdiutil create -volname "Cabinet $VERSION" -srcfolder "$WORK/dmg-root" -ov -format UDZO "$DMG" >/dev/null
xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$KEYID" --issuer "$ISSUER" --wait | grep -E "status:" | tail -1 | grep -q Accepted
xcrun stapler staple "$DMG"
spctl --assess --type execute -vv "$WORK/dmg-root/Cabinet.app" 2>&1 | grep -q "Notarized Developer ID" && echo "ok: $DMG"
