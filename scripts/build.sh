#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
# Native builds are quick for development; releases use PDFME_ARCHS="arm64 x86_64".
read -r -a architectures <<< "${PDFME_ARCHS:-$(uname -m)}"
mkdir -p dist work
stage="$(mktemp -d "$PWD/dist/build-XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/PDFMe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
executables=()
extensions=()
for architecture in "${architectures[@]}"; do
  case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
  swift build -c "$configuration" --arch "$architecture"
  bin_dir="$(swift build -c "$configuration" --arch "$architecture" --show-bin-path)"
  executables+=("$bin_dir/PDFMe")
  swiftc -parse-as-library -application-extension -O -module-name PDFMeFinder \
    -target "$architecture-apple-macosx13.0" \
    Extensions/PDFMeFinder/FinderSelection.swift Extensions/PDFMeFinder/FinderServiceHandoff.swift Extensions/PDFMeFinder/FinderSync.swift \
    -framework AppKit -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$stage/PDFMeFinder-$architecture"
  extensions+=("$stage/PDFMeFinder-$architecture")
done
/usr/bin/lipo -create "${executables[@]}" -output "$app/Contents/MacOS/PDFMe"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
artifact=".build/artifacts/sparkle/Sparkle"
framework="$app/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$artifact/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$framework"
cp "$artifact/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
# Sign nested helpers first. Do not use --deep to sign: it loses component entitlements.
for component in "$framework/Versions/B/XPCServices/Downloader.xpc" \
                 "$framework/Versions/B/XPCServices/Installer.xpc" \
                 "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"; do
  /usr/bin/codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$component"
done
extension="$app/Contents/PlugIns/PDFMeFinder.appex"
mkdir -p "$extension/Contents/MacOS"
/usr/bin/lipo -create "${extensions[@]}" -output "$extension/Contents/MacOS/PDFMeFinder"
cp Extensions/PDFMeFinder/Info.plist "$extension/Contents/Info.plist"
/usr/bin/codesign --force --sign "${CODE_SIGN_IDENTITY:--}" --entitlements Extensions/PDFMeFinder/Entitlements.plist "$extension"
/usr/bin/codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
archive_arch="${architectures[0]}"
if [ "${#architectures[@]}" -gt 1 ]; then archive_arch=universal; fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/PDFMe-macOS-$archive_arch.zip"
# Replace only generated output after the new bundle has passed signature validation.
rm -rf dist/PDFMe.app
mv "$app" dist/PDFMe.app
mv "$stage/PDFMe-macOS-$archive_arch.zip" dist/
echo "Built dist/PDFMe.app and dist/PDFMe-macOS-$archive_arch.zip"
