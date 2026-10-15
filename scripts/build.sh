#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app="dist/PDFMe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/PDFMe" "$app/Contents/MacOS/PDFMe"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp LICENSE "$app/Contents/Resources/LICENSE"
extension="$app/Contents/PlugIns/PDFMeFinder.appex"
mkdir -p "$extension/Contents/MacOS"
# Finder extensions enter through NSExtensionMain. Build with Command Line Tools;
# no Xcode project, package dependency, or paid signing identity is needed locally.
swiftc -parse-as-library -application-extension -O -module-name PDFMeFinder \
  -target "$(uname -m)-apple-macosx13.0" \
  Extensions/PDFMeFinder/FinderSelection.swift Extensions/PDFMeFinder/FinderSync.swift \
  -framework AppKit -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$extension/Contents/MacOS/PDFMeFinder"
cp Extensions/PDFMeFinder/Info.plist "$extension/Contents/Info.plist"
/usr/bin/codesign --force --sign "${CODE_SIGN_IDENTITY:--}" --entitlements Extensions/PDFMeFinder/Entitlements.plist "$extension"
/usr/bin/codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "dist/PDFMe-macOS-$(uname -m).zip"
echo "Built $app"
