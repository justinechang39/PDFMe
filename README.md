<div align="center">
  <img src="docs/icon.png" width="100" alt="PDFMe icon">
  <h1>PDFMe</h1>
  <p><strong>Create and print PDFs from your menu bar.</strong></p>
  <p>A native macOS menu bar app for DOCX conversion and PDF printing.<br>Saved print templates, collated batches, and local processing.</p>
  <p><a href="https://github.com/justinechang39/PDFMe/releases/latest">Download</a> · <a href="#getting-started">Get started</a> · <a href="CONTRIBUTING.md">Contribute</a></p>
  <p><img src="https://img.shields.io/badge/macOS-13%2B-416347" alt="macOS 13 or later"> <img src="https://img.shields.io/badge/Swift-native-416347" alt="Native Swift app"> <img src="https://img.shields.io/badge/license-MIT-416347" alt="MIT license"></p>
</div>

## Features

- **Drop onto the menu bar icon** or the **Create PDF** panel. Click to browse, or use Finder’s **Open With → PDFMe**.
- **Separate workflows:** DOCX only for Create PDF; PDF only for Print PDF. The menu bar icon routes a single-format batch to the appropriate workflow.
- **Saved beside the original** by default. Turn on **Ask every time** to choose a location for each document.
- **Small, Balanced, or Best** image quality. Text stays sharp and selectable.
- **Optional password protection.** Choose and confirm a password for each batch; it is never persisted or passed in command-line arguments.
- **Batch conversion**, honest stage-based progress, cancellation, completion notifications, and shortcuts to open or reveal results.
- **Existing files stay safe.** `Report.pdf` becomes `Report (2).pdf` if needed, even when a save dialog names an existing file.
- **Local processing.** No account, cloud upload service, or telemetry. Print through macOS or send PDF directly to your selected network printer over IPP.
- Native **SwiftUI + AppKit**, keyboard-accessible controls, and support for Reduce Motion.

## Getting started

Requires **macOS 13 or later**. DOCX conversion additionally requires [LibreOffice](https://www.libreoffice.org/download/download-libreoffice/) in `/Applications` or `~/Applications`. PDF printing needs an installed printer; LibreOffice is not needed. Direct printing uses macOS networking and an IPP printer that accepts PDF, with no additional installation.

1. For DOCX conversion, install LibreOffice (or run `brew install --cask libreoffice`). Printing PDFs does not require LibreOffice.
2. Download the ZIP matching your Mac from [Releases](https://github.com/justinechang39/PDFMe/releases). `arm64` is for Apple silicon; `x86_64` is for Intel when available.
3. Unzip and move **PDFMe.app** into Applications.
4. Open PDFMe. Its document icon appears in the menu bar. Drop a `.docx` file on it.

The initial community build is **ad-hoc signed, not Apple-notarized**. macOS may block a downloaded copy. After trying to open it, use **System Settings → Privacy & Security → Open Anyway** if you trust the release, or build from source. Do not disable Gatekeeper globally. To open PDFMe automatically when you sign in, enable **Settings → Start at login**. The toggle uses macOS Login Items and reflects changes made in System Settings. If macOS requires approval, PDFMe shows an **Open Login Items** button. Login launches stay in the menu bar without opening the panel.

Allow notifications when macOS asks if you want completion banners. Results also appear inside PDFMe regardless of notification permission. Documents from iCloud or another cloud drive must be downloaded before conversion.

## Print PDF

Click **Print PDF** below Create PDF, or drop one or more PDFs on that target or the menu bar icon. Dropping files opens a review; it never prints automatically. DOCX files are rejected by the print target.

1. Add the PDFs you want to print.
2. Choose a saved template and the printer. Adjust settings for this job if needed.
3. Set **Copies** on each PDF row. Drag the handle on the right to change the file order; each document’s copies stay together.
4. Click a PDF in the list to see its sheet layout on the right. Use the arrows to inspect its printed sides. **Open in Preview** opens the complete batch in macOS Preview.
5. Click **Print** to send one job to the selected printer.

After successful submission, the PDF list and its copy counts are cleared, disabling Print until you add new files. Saved templates remain available, along with the submitted job’s status and cancellation controls. Previewing or a failure before upload keeps the files for review. An uncertain direct upload also clears the batch to prevent accidental duplicates and retains its printer job number.

### Direct PDF printing

Enable **Direct PDF printing** in Print PDF or Settings to send the composed PDF to the selected network printer using IPP/IPPS. It bypasses the Mac queue and its PDF/raster filters. Turn it off at any time to return to macOS printing; saved templates stay intact. The default remains macOS printing until you enable it.

Connect to the printer’s network and allow PDFMe access to the local network if macOS asks. Bonjour printers are resolved by service name, advertised host, port, and resource path each time you print, so a changed IP address does not require rebuilding the app. Direct printing does not support USB-only printers, legacy socket/LPD queues, printers that require HTTP authentication, or printers without native PDF and Create-Job/Send-Document support. Use macOS printing for those devices.

PDFMe checks the printer’s PDF capabilities and validates the exact settings before uploading. Copies, ordering, blank backs, and 1/2/4-up layout are already in the prepared PDF; the printer receives **copies=1** and **number-up=1**, along with explicit paper, orientation, duplex edge, and color. Where supported, scaling is disabled for direct jobs because PDFMe has already composed the sheet with margins. Unsupported or substituted settings block upload. Printer firmware still controls physical output, so test duplex and collation on your printer before relying on this path for a large batch.

Direct jobs do not appear in the Mac queue. PDFMe retains the printer’s job number and provides **Check status** and **Cancel this job**, even after switching modes. A receipt confirms submission only. Printers may discard completed job history; missing status never means the job definitely completed. If an upload response is lost, PDFMe reports uncertainty and never automatically retries or falls back to macOS printing. Check the printer before sending the file again.

Read the [protocol design and references](docs/direct-printing.md) for implementation details.

If macOS pauses the selected printer queue, PDFMe shows the queue’s error and a **Resume printer** button. It checks every five seconds while Print PDF is open and again before submitting a job. Preview remains available while paused. Resuming requires confirmation because existing queued jobs, including partially printed ones, may start printing. Use **Printers & queues** to remove unwanted jobs first. PDFMe verifies the queue resumed; it never automatically retries documents, releases held jobs, or changes the printer’s error policy. A resumed Mac queue does not guarantee that the physical printer is ready; recurring errors may require attention on the printer itself.

### Live sheet preview

Print PDF mode expands to show the file list and settings on the left and a live preview on the right. Selecting a file highlights it and shows the sides that contain it in the actual batch. The preview includes its requested copies, blank duplex backs, and neighboring PDFs when documents share a side. Sheet numbers refer to the full print job.

Changes to paper, orientation, pages per side, image rendering, and color update the preview automatically. Rendering runs in the background and only prepares the visible side. Old renders are cancelled when selection or settings change; clearing the batch clears the preview. The preview also works before a printer is selected.

The inline preview shares the print compositor. Black-and-white vector jobs are simulated in grayscale for display; actual printer color handling and printable margins can differ. Front/back labels identify the side being shown, not an animation of the physical duplex turn. **Open in Preview** still generates the complete batch at the selected image resolution. No preview operation submits a print job.

### Templates

The first time you open printing, PDFMe creates a basic template for your system default printer. If that printer supports A4 and duplex, it also creates **A4 · 2-up duplex**: A4 landscape, two portrait pages side by side, short-edge duplex, print as image at 300 dpi. No personal printer identifiers are bundled with the app.

Use **Manage templates** (the sliders icon) to name a template, **Save** changes, **Save as new**, delete a template, or **Use as default**. Templates are stored locally and include:

- Printer and paper size (A4, Letter, A5, Legal, or A3 where supported).
- Portrait/landscape, one-sided or long-/short-edge duplex.
- One, two, or four pages per side, in left-to-right/top-to-bottom order.
- Color or black and white, where advertised by the printer driver.
- Print as image and image resolution (150, 300, or 600 dpi).
- Whether each PDF starts on a fresh physical sheet.

Unsaved setting changes affect the current job only. Copy counts are set separately for each PDF in the current job and are not stored in templates. A missing saved printer must be explicitly replaced; PDFMe does not silently redirect jobs to a different printer. Unsupported paper, color, or duplex options block submission instead of silently changing the template.

### Layout and collation

For example, with two copies of A and one copy of B, the job contains **A, A, B**, with every document’s pages in order. Copies are included in the prepared PDF, so **Open in Preview** shows the complete job. Repeated copies of a document always start on separate physical sheets. With **Start each PDF on a new sheet**, PDFMe also keeps different documents on separate sheets, adding blank backs where necessary for duplex. Turn it off to let different PDFs share a sheet. The sheet total includes all requested copies and any blank backs.

Two-up places pages side by side on each printed side; it is not booklet imposition. Landscape and short-edge duplex normally produce the expected left/right page turning for this arrangement. Printer drivers can differ, so test one sheet before a large run.

PDFMe composes the sheet layout itself with an 18-point outer margin and 12-point gap, preserving source page aspect ratios, crop boxes, rotations, and printable annotations. In macOS mode the printer fits the prepared sheet to its printable area, so the physical scale can differ slightly from the preview. Direct mode requests no extra scaling when supported. This release does not offer actual-size technical drawing output, custom margins, finishing/stapling, manual duplex, or page-range selection.

**Print as image** rasterizes each composed side at the selected resolution before spooling. This can help with PDFs whose fonts or graphics print incorrectly, but can be slower and produce larger jobs. It preserves the original files. Extremely large paper/resolution combinations are blocked with a prompt to lower resolution to limit memory usage.

### Queue status and privacy

A success notification means **submitted**, not physically printed. In macOS mode this means accepted by the system queue; in direct mode it means accepted by the printer’s IPP endpoint. The printer can still be offline, paused, out of paper, or require attention. PDFMe shows the job ID, provides a link to **Printers & queues**, and can request cancellation of its own submitted job. Sheets already printed cannot be recalled. After a timeout or an ambiguous spooler reply, check the queue before retrying to avoid duplicate copies.

Locked PDFs and PDFs that prohibit printing are rejected. Source PDFs are never edited. Temporary print files live in a private directory and are removed after spooling; preview files are retained for the current app session until the list is cleared or PDFMe quits. The macOS print spooler manages its own copies. A crash can leave temporary files for macOS to clean up. Saved templates contain local printer names/IDs and preferences, not the dropped files or their paths.

## Which conversion quality should I choose?

| Preset | Images | Good for |
| --- | --- | --- |
| Small | JPEG quality 75, downsample to 150 dpi | Email and everyday sharing |
| Balanced (default) | JPEG quality 90, downsample to 300 dpi | Most documents and printing |
| Best | Lossless, original resolution | Detailed images and graphics |

These settings affect images, not the resolution of text. The actual size difference depends on the source document. A text-only document may have almost the same size in every preset.

PDFMe uses LibreOffice’s Word import and PDF export engine. Complex layouts, unavailable fonts, fields, or Word-specific features can differ from Microsoft Word’s rendering. Check important documents before sharing. This is not a PDF/A, digital-signature, accessibility-certification, redaction, or permissions-management tool. Existing comments are not exported as PDF notes.

## Passwords and privacy

Password protection requires at least eight characters and matching confirmation. One password applies to the current batch only. macOS PDFKit encrypts the output; PDFMe verifies that it is locked and can be reopened with the supplied password before publishing it. It does not claim a particular encryption algorithm across macOS versions. Passwords are not written to preferences, logs, or process arguments; they exist in memory for the batch. Swift strings do not guarantee cryptographic memory erasure.

Conversion uses a private temporary workspace and isolated LibreOffice profile, with macros and automatic linked-content updates disabled. Temporary copies are removed after success, failure, or cancellation. A force quit or machine crash can leave temporary files for macOS to clean up; cleanup is not secure disk erasure. LibreOffice runs with your user permissions and is a separately installed dependency, not a security sandbox. DOCX conversion makes no network requests from PDFMe; printing explicitly submits to your chosen printer through macOS or directly over IPP; untrusted documents should always be treated with care.

Recent results are in memory only and disappear when PDFMe quits. Quality, protection, save-location preferences, and print templates persist. Output files receive owner-only file permissions; originals are never edited. Completed PDFs remain after cancelling a batch.

## Build from source

Builds run locally. GitHub Actions is disabled for this repository and the build workflow has been removed; pushes and pull requests do not start GitHub builds. Releases can be built and uploaded manually.

Requires macOS 13 or later and Apple Command Line Tools. The commands below were verified on Apple silicon with Swift 6.2, Python 3.11.6, and LibreOffice 26.2.3.2. No third-party Swift packages are required. Install Command Line Tools with `xcode-select --install` if needed, then verify the selected tools:

```sh
xcode-select -p
swift --version
```

LibreOffice is needed for DOCX conversion and its tests, but not for building PDFMe or testing PDF printing. The standalone test scripts also require Python 3 (`python3 --version`).

```sh
git clone https://github.com/justinechang39/PDFMe.git
cd PDFMe
./scripts/build.sh
/usr/bin/codesign --verify --deep --strict --verbose=2 dist/PDFMe.app
```

The script makes `dist/PDFMe.app` and `dist/PDFMe-macOS-$(uname -m).zip` for the current Mac’s architecture, then ad-hoc signs the app. Set `CODE_SIGN_IDENTITY` to your own signing identity if you maintain a distribution build. Developer ID signing, hardened runtime, and notarization are release-maintainer responsibilities and are not configured by this script.

### Install a local build

If PDFMe is running, choose **Quit PDFMe** from its panel before replacing the app. From the repository directory:

```sh
/usr/bin/ditto dist/PDFMe.app /Applications/PDFMe.app
/usr/bin/codesign --verify --deep --strict --verbose=2 /Applications/PDFMe.app
/Applications/PDFMe.app/Contents/MacOS/PDFMe --print-transport-status
open /Applications/PDFMe.app
```

Replacing the bundle preserves saved templates and preferences, which are stored separately. The status command only reads the printing preference; it does not start the UI or send a print job. These copy, signature, and status commands have also been verified with a staged installation outside Applications. Opening the installed app shows its icon in the menu bar. Use **Settings → Start at login** if desired, and allow local-network access if macOS asks when using direct printing.

### Test locally

```sh
# Real conversion, encryption, cancellation, and file-safety checks:
./scripts/test.sh

# Print layout, rasterization, collation, and printer-option checks; prints no paper:
./scripts/test-print.sh

# XCTest suite (requires full Xcode selected and licensed):
swift test
```

`scripts/test.sh` requires LibreOffice in `/Applications` or `~/Applications`. `scripts/test-print.sh` does not need LibreOffice; it uses Swift, Python 3, and the built-in macOS printing tools. Both scripts work with Command Line Tools alone and generate fixtures under ignored `work/`. Print checks submit only to simulated IPP endpoints and never require or send jobs to a physical printer.

`swift test` additionally requires full Xcode selected and licensed; Command Line Tools alone may report a missing XCTest module. Conversion XCTest cases skip when LibreOffice is absent. Do not change the selected developer directory just to run the standalone scripts.

## How it works

`PDFMe` owns the menu bar, native drop target, SwiftUI panel, queue, save dialogs, and notifications. `PDFMeCore` validates DOCX packages, runs LibreOffice asynchronously with a two-minute timeout, checks the resulting PDF, optionally applies password protection using PDFKit, and stages the final file on the destination volume. An atomic exclusive hard link publishes it without overwriting a file, including a concurrent naming collision. Destinations must support hard links (the usual macOS APFS/HFS+ disks do); unsupported volumes produce an error instead of risking replacement.

Printing uses PDFKit/Core Graphics for composition and the macOS `lpstat`, `lpoptions`, `lp`, and `cancel` tools with argument arrays rather than shell commands. N-up and per-file copy counts are applied during composition, and the complete prepared PDF is submitted exactly once with explicit print options. Printer defaults are queried but never changed.

See [LibreOffice’s PDF export parameters](https://help.libreoffice.org/latest/en-US/text/shared/guide/pdf_params.html) for the image-quality settings used by the app.

## Open source

[MIT licensed](LICENSE), copyright © 2026 Justine Chang. Contributions and [issues](https://github.com/justinechang39/PDFMe/issues) are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
