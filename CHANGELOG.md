# Changelog

## 1.8.0 — 2026-10-29

- Add a thumbnail strip under the print preview showing every side of the selected PDF, with sheet/front/back badges, PDF page numbers, tooltips, and accessibility labels. Click a thumbnail to jump to that side.
- Add a grid button to the preview header that shows all sides in a scrollable grid; clicking one returns to the large preview on that side.
- Preview arrows now wrap around: back from the first side goes to the last, and next from the last goes to the first. With a single side both are disabled.
- Thumbnails are drawn at most 300 pixels on the long edge with the print layout code, never at the print resolution. Only visible thumbnails are rendered, one at a time, with cancellation, a bounded cache, a bounded queue, and shared images for identical sides. Print output is unchanged.
- Extend offline checks: thumbnail pixels against prepared sides for page ranges, 2-up duplex with copies and blank backs, grayscale 4-up, rotation, crop, and annotations; wraparound and exact side selection; invalidation after range, layout, copy, and PDF changes; cache, queue, concurrency, and cancellation bounds. No physical printing in tests.

## 1.7.0 — 2026-10-29

- Add per-PDF page ranges in the mini app and Print Queue. **Pages: All** remains the default; **Custom** accepts PDF page numbers such as `1-15, 21-30` or `21-end`, with commas, spaces, en/em dashes, and `end`. Overlaps print once in document order.
- Show the selected page count and inline errors on a second row under each file name. Invalid or unfinished ranges block Print, Open in Preview, and Print all groups, so no group is sent and nothing silently falls back to all pages.
- Apply selected pages before pages per side, duplex blank backs, and collated copies. The preview, sheet counts, and prepared job use the same pages. Ranges travel with each PDF when reordered or moved between groups and are not saved in templates.
- Refuse to print a PDF whose page count changed after it was added, instead of reinterpreting its range.
- Fix the copies field recreating “1” on backspace. Both views share a text editor that allows an empty field, applies valid 1–999 counts as you type, blocks printing while the value is empty or invalid, and restores the last valid count when you leave the field.
- Extend offline checks for range parsing, prepared page content with 2-up, duplex, and copies, group moves, invalid-range blocking, and copy editing. No physical printing in tests.

## 1.5.3

- Fix the permission error when the top-level Finder action tries to open selected PDFs from its sandbox. Route selected paths through PDFMe’s existing macOS Service using a named pasteboard; the main app validates and opens them with its own permissions.
- Keep the top-level menu action and current queue; no added file-access entitlements or automatic printing.
- Add a real signed-sandbox integration test with an isolated service receiver. Verify that the sender cannot read the synthetic PDFs while the receiver gets and reads both files correctly.

## 1.5.2

- Fix the top-level Finder action silently returning when Finder reconstructs its menu item without custom metadata. Read the current file selection from the Finder controller inside the action.
- Test the actual Objective-C action with a reconstructed sender, multiple PDFs, stale metadata, missing selection, and handoff failures.
- Report selection and launch errors instead of silently ignoring them; log handoff status without file paths.

## 1.5.1

- Add a sandboxed Finder extension that provides “Add to PDFMe Print Queue” directly in the contextual menu for PDF-only selections.
- Hand selected files to the containing app through Launch Services, opening the existing review workflow without printing.
- Add Finder extension status and a Manage Finder Extension button in Settings. Keep the Services fallback for locations where Finder extension menus are unavailable.
- Build and sign the embedded extension locally with Command Line Tools; add offline menu-selection and routing checks.

## 1.5.0

- Add a resizable Print Queue companion window, accessible from the menu bar, Dock, and Command-1.
- Add Finder’s “Add to PDFMe Print Queue” service for one or multiple PDFs; open the queue for review without printing.
- Organize PDFs into independent template groups with per-document copies, drag handles to reorder or move between groups, and a live sheet preview.
- Share the primary group with the mini app. Keep template management and direct/macOS transport preferences synchronized.
- Submit groups sequentially, clear accepted files, stop on failures, and allow stopping after the current group. Unknown submission outcomes require review before retrying.
- Preserve the menu bar app when the window closes. Retain unsent groups for the session; saved templates persist as before.
- Extend offline checks for Finder service selection, group ownership, submission order, copy counts, partial failures, and duplicate prevention. GitHub Actions remains disabled.

## 1.4.0

- Add optional Direct PDF printing over IPP/IPPS using native macOS networking, with no new installed dependencies.
- Resolve the selected network printer using its installed address and Bonjour resource path; send the prepared PDF without macOS print filters.
- Validate native PDF support and requested paper, color, orientation, and duplex settings before creating a job. Send copies and pages per side as 1 because PDFMe already composes them.
- Keep a persistent toggle in Print PDF and Settings to return to macOS printing. Existing installs retain macOS printing unless enabled.
- Add direct job status and cancellation. Keep uncertain uploads from being resent automatically; clear their batch and retain the job number for cancellation.
- Test the protocol with simulated printers, a byte-for-byte PDF upload over 32 MB, redirects, rejected settings, and dropped HTTP connections. No physical printing in automated tests.

## 1.3.1

- Detect paused printer queues while Print PDF is open and check again before submitting.
- Add Resume printer with confirmation that existing queued jobs may print, and verify the queue resumed.
- Keep previews available while a queue is paused. Never automatically resume, resend files, or release held jobs.

## 1.3.0

- Widen Print PDF mode with a live sheet preview beside the file list and settings.
- Select a PDF to inspect its actual batch sides, including copies, shared sheets, and blank duplex backs.
- Update previews when print settings change; render only the displayed side in the background.
- Keep the full job available through Open in Preview.

## 1.2.0

- Add a Start at login toggle backed by macOS Login Items, with approval and error states.
- Launch quietly in the menu bar when opened by macOS at login.
- Make print selectors fill the available row width.

## 1.1.1

- Clear PDFs and their copy counts after successful print submission to prevent accidental repeat jobs. Keep the submitted job’s queue and cancellation controls available.

## 1.1.0

- Per-PDF copy counts, drag handles for ordering, and full-width pickers below their labels.
- Add a PDF-only print workflow beneath Create PDF, with saved templates, printer selection, copies, and batch ordering.
- Add A4 landscape two-up duplex image template for compatible default printers.
- Compose 1/2/4-up layouts locally, optionally rasterize at 150/300/600 dpi, and preview without printing.
- Collate each PDF’s copies, keep documents on separate sheets when requested, and submit through the macOS spooler.
- Validate driver capabilities and show submission IDs with cancellation and queue access.
- Add print checks that do not submit any physical jobs.
- Use a portable fixture font for conversion text-extraction checks on older macOS versions.

## 1.0.0

Initial release: native menu bar drag-and-drop, DOCX batch conversion, local LibreOffice engine, three quality presets, optional password protection, configurable save dialogs, safe numbered filenames, progress, cancellation, completion notifications, and Finder shortcuts.
