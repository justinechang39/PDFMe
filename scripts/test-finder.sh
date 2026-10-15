#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
swiftc -parse-as-library Extensions/PDFMeFinder/FinderSelection.swift Extensions/PDFMeFinder/FinderSync.swift \
  scripts/FinderExtensionChecks.swift -framework AppKit -framework FinderSync -o work/FinderExtensionChecks
work/FinderExtensionChecks
plutil -lint Extensions/PDFMeFinder/Info.plist Extensions/PDFMeFinder/Entitlements.plist
