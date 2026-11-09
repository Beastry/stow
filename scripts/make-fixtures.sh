#!/bin/zsh
# Rebuilds the disk-image test fixtures in Tests/Fixtures (committed; hdiutil can't run inside the
# sandboxed test host). Each holds a tiny ad-hoc-signed app built from a one-line C program, a
# background picture, a volume icon and the usual "Applications" shortcut.
#
# Fixture-Layout.dmg (#344) is an authored installer window: a dotted, non-ASCII volume name, a
# `.DS_Store` placing the app and the shortcut over 2x artwork, a declared app icon and an
# unplaced file. Its assets come from scripts/fixture-layout/main.swift, compiled with the
# vendored DSStore package in ThirdParty/DSStore.
# Fixture-Compatibility.dmg adds a self-authored 8 KiB DS_Store leaf, a root multi-resolution
# TIFF, a regular Applications bookmark and a CFBundleIconName-only .icns companion. Pass
# --compatibility-only to rebuild only this fixture without rewriting the older disk images.
set -e
cd "${0:a:h}/.."
mode=${1:-all}
[[ $# -le 1 && ( $mode == all || $mode == --compatibility-only ) ]] || {
  print -u2 'Usage: scripts/make-fixtures.sh [--compatibility-only]'; exit 2
}
out=Tests/Fixtures
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out" "$work/vol/.background" "$work/vol/Fixture Tool.app/Contents/MacOS"
print 'int main(void) { return 0; }' > "$work/main.c"
clang -Os -arch arm64 -mmacosx-version-min=26.0 -o "$work/vol/Fixture Tool.app/Contents/MacOS/Fixture Tool" "$work/main.c"
cat > "$work/vol/Fixture Tool.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Fixture Tool</string>
<key>CFBundleIdentifier</key><string>app.stow.fixture.tool</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$work/vol/Fixture Tool.app"
print -n 'PNG' > "$work/vol/.background/background.png"
print -n 'icns' > "$work/vol/.VolumeIcon.icns"
ln -s /Applications "$work/vol/Applications"
xattr -cr "$work/vol"
if [[ $mode == all ]]; then
  hdiutil create -quiet -ov -volname "Fixture Tool" -srcfolder "$work/vol" -fs HFS+ -format UDZO "$out/Fixture-HFS.dmg"
  hdiutil create -quiet -ov -volname "Fixture Tool" -srcfolder "$work/vol" -fs APFS -format ULFO "$out/Fixture-APFS.dmg"
fi

# The authored window.
dsstore=ThirdParty/DSStore/Sources/DSStore
[[ -d $dsstore ]] || { print "The vendored DSStore source is missing." >&2; exit 1; }
swiftc -O -module-name DSStore -o "$work/make-layout" $dsstore/*.swift scripts/fixture-layout/main.swift
if [[ $mode == all ]]; then
"$work/make-layout" "$work/assets"
layout="$work/layout"
app="$layout/Layout Tool.app"
mkdir -p "$layout/.background" "$app/Contents/MacOS" "$app/Contents/Resources" "$work/tool.iconset"
cp "$work/vol/Fixture Tool.app/Contents/MacOS/Fixture Tool" "$app/Contents/MacOS/Layout Tool"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Layout Tool</string>
<key>CFBundleIdentifier</key><string>app.stow.fixture.layout</string>
<key>CFBundleIconFile</key><string>tool</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.7.1</string>
</dict></plist>
PLIST
for size in 16 32 128 256; do
  sips -z $size $size "$work/assets/icon.png" --out "$work/tool.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$work/assets/icon.png" --out "$work/tool.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$app/Contents/Resources/tool.icns" "$work/tool.iconset"
codesign --force --sign - "$app"
cp "$work/assets/bg@2x.png" "$layout/.background/bg@2x.png"
cp "$work/assets/DS_Store" "$layout/.DS_Store"
print 'Read me first.' > "$layout/Read Me.txt"
ln -s /Applications "$layout/Applications"
xattr -cr "$layout"
hdiutil create -quiet -ov -volname "Layout Tool v2.7.1 测试" -srcfolder "$layout" -fs HFS+ -format UDZO "$out/Fixture-Layout.dmg"
fi

# The compatibility image's values and artwork are fixed; the only native bookmark targets the
# stable /Applications directory. No downloaded app, image, icon or DS_Store is copied into it.
"$work/make-layout" "$work/compatibility-assets" --compatibility
compat="$work/compatibility"
app="$compat/Compatibility Tool.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$work/compatibility.iconset"
cp "$work/vol/Fixture Tool.app/Contents/MacOS/Fixture Tool" "$app/Contents/MacOS/Compatibility Tool"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Compatibility Tool</string>
<key>CFBundleIdentifier</key><string>app.stow.fixture.compatibility</string>
<key>CFBundleIconName</key><string>Compatibility</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>8.0</string>
</dict></plist>
PLIST
for size in 16 32 128 256; do
  sips -z $size $size "$work/compatibility-assets/icon.png" --out "$work/compatibility.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$work/compatibility-assets/icon.png" --out "$work/compatibility.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$app/Contents/Resources/Compatibility.icns" "$work/compatibility.iconset"
codesign --force --sign - "$app"
cp "$work/compatibility-assets/DS_Store" "$compat/.DS_Store"
cp "$work/compatibility-assets/.background.tiff" "$compat/.background.tiff"
cp "$work/compatibility-assets/Applications" "$compat/Applications"
print 'Self-generated compatibility fixture; no third-party payloads.' > "$compat/Read Me.txt"
xattr -cr "$compat"
hdiutil create -quiet -ov -volname "Compatibility Tool v8.0 测试" -srcfolder "$compat" -fs HFS+ -format UDZO "$out/Fixture-Compatibility.dmg"
ls -l "$out"
