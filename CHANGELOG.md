# Changelog

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
