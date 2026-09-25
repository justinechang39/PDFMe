#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
qa_dir="$(mktemp -d "$PWD/work/print-qa-XXXXXX")"
swiftc -parse-as-library Sources/PDFMeCore/Printing.swift Sources/PDFMeCore/Printers.swift scripts/PrintChecks.swift -o work/PrintChecks
work/PrintChecks "$qa_dir"
