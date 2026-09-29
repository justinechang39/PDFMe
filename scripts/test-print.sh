#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
qa_dir="$(mktemp -d "$PWD/work/print-qa-XXXXXX")"
swiftc -parse-as-library Sources/PDFMeCore/Printing.swift Sources/PDFMeCore/Printers.swift scripts/PrintChecks.swift -o work/PrintChecks
work/PrintChecks "$qa_dir"
swift build
bin_dir="$(swift build --show-bin-path)"
swiftc -parse-as-library -I "$bin_dir/Modules" "$bin_dir/PDFMeCore.build/"*.swift.o Sources/PDFMe/PrintModel.swift scripts/PrintPreviewChecks.swift -o work/PrintPreviewChecks
work/PrintPreviewChecks "$qa_dir"
