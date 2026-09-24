# Contributing to PDFMe

Thanks for helping make document conversion feel effortless.

Start with an issue for larger changes. For a fix, include what happened, what you expected, your macOS version, and your LibreOffice version. Do not upload private documents or passwords. A minimal synthetic DOCX demonstrating the issue is ideal.

## Development

1. Install Swift 5.9+ and LibreOffice.
2. Run `swift build` or `./scripts/build.sh`.
3. Run `./scripts/test.sh`; with full Xcode available, also run `swift test`.
4. Open `dist/PDFMe.app`, check the normal and processing states, and try a real Finder drop.

Keep expensive work off the main actor. Never overwrite source documents or existing outputs. Do not add telemetry or upload document contents. Support cancellation and readable error messages. Respect Reduce Motion and provide accessibility labels for icon-only actions.

The app is deliberately focused on DOCX to PDF. Discuss new formats and dependencies before implementing them. Avoid adding tests that only mirror view markup; test user-visible conversion and file-safety behavior.

For UI changes include a screenshot, and check narrow text, long filenames, errors, and batch results. For conversion changes test a document with multiple pages, images, tables, and unusual filenames. Never commit generated documents containing personal data.

All contributions are provided under the repository’s MIT license. No contributor license agreement is required. Be kind and constructive in discussions.
