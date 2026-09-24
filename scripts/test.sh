#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
qa_dir="$(mktemp -d "$PWD/work/qa-XXXXXX")"
python3 scripts/make-fixture.py "$qa_dir/Hello PDFMe.docx"
swiftc -parse-as-library Sources/PDFMeCore/Converter.swift scripts/SmokeTests.swift -o work/SmokeTests
work/SmokeTests "$qa_dir"
echo "Inspect PDF output in $qa_dir"
