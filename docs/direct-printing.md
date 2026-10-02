# Direct PDF printing

PDFMe has two independent submission paths. The original path uses `lp` and the installed macOS queue. Direct printing reads that queue’s device address, resolves its Bonjour service if needed, and communicates with the advertised IPP endpoint through Foundation `URLSession`. It does not create another macOS queue, install a driver, change system defaults, or use macOS PDF/raster filters. There are no new third-party runtime dependencies.

Direct IPP can avoid an incorrect Mac filter or driver transformation. It cannot repair every printer firmware bug, and does not establish that AirPrint caused a particular physical output problem. AirPrint itself also uses IPP; the change here is sending a native PDF with an explicit job ticket directly to the printer.

## Submission

1. Compose the existing sheet layout into a PDF. Source documents stay unchanged. Copies and collation are materialized in that PDF.
2. Resolve only the selected installed printer. For `dnssd://` addresses use the service’s advertised host, port, and `rp` TXT value. Preserve IPPS for secure services. Direct IPP/IPPS queue addresses are also supported.
3. Get-Printer-Attributes with `document-format=application/pdf`. Check PDF support, Create-Job, Send-Document, Validate-Job, Cancel-Job, media, sides, color, and accepting/stopped state.
4. Validate-Job with `ipp-attribute-fidelity=true` and the exact job ticket. A substitution response or unsupported-attributes group is a failure.
5. Create-Job with that ticket and a unique PDFMe job name. Keep the returned `job-id` and original printer endpoint. No PDF has been uploaded yet. If the printer changes settings at creation, request cancellation of that empty job and stop.
6. Send-Document with that job ID, `document-format=application/pdf`, and `last-document=true`. Issue one application-level upload attempt. Stream bytes into a private upload file instead of holding large raster PDFs in memory. Remove the temporary file afterward.

The ticket sends `copies=1`, `number-up=1`, standardized media names, explicit `orientation-requested`, `sides`, and `print-color-mode`. No PPD `DuplexNoTumble`/`DuplexTumble` alias or raster back-side rotation is sent. Request `print-scaling=none` only when advertised. The prepared PDF already has an 18-point margin.

IPP uses `application/ipp` HTTP POST bodies. IPP maps to HTTP, IPPS to HTTPS, with port 631 unless advertised otherwise. The codec follows RFC 8010, correlates request IDs, bounds response parsing, and handles repeated attribute values. HTTP redirects and authentication challenges are rejected; TLS uses macOS certificate validation. Local network access is declared in the bundle.

## Uncertain outcomes and cancellation

There is no automatic fallback to `lp`, resubmission, queue resume, or retry loop. A failed Create-Job response cannot have printed this PDF because its data has not been uploaded. A failed Send-Document response can be ambiguous: the printer may have received and printed the document before the connection dropped. Keep the job reference, clear the input batch, and ask the user to check or cancel the job before resending.

Cancel-Job and Get-Job-Attributes target the saved endpoint and numeric job ID, irrespective of the current printing mode or selected template. A successful upload is described as submitted, not physically completed. A missing job record is reported as unavailable rather than completed; physical printer job history is not universally retained.

The URLSession transport has finite connection/upload timeouts and no application retry logic. The loopback wire test deliberately disconnects after receiving the PDF and checks that no second upload or new job occurs.

## Tests

`scripts/test-print.sh` runs the existing layout, queue recovery, and preview checks plus direct IPP tests. Scripted responses cover every orientation/duplex combination, lack of native PDF support, missing operations, stopped/rejecting printers, rejected/substituted settings, missing job IDs, upload rejection, lost replies, status, and cancellation. An independent Python loopback server parses the binary requests and verifies a PDF over 32 MB arrives byte-for-byte, once. It also tests redirects and connection loss. No automated test connects to or prints on a real printer.

## Primary references

- [PWG: How to Use the Internet Printing Protocol](https://www.pwg.org/ipp/ippguide.html) — capability discovery, job ticket attributes, Create-Job/Send-Document, status, and cancellation.
- [RFC 8010: IPP Encoding and Transport](https://datatracker.ietf.org/doc/html/rfc8010) — binary encoding, group/value tags, HTTP transport, and URI mapping.
- [RFC 8011: IPP Model and Semantics](https://datatracker.ietf.org/doc/html/rfc8011) — validation/fidelity, orientation, duplex, job creation and document submission semantics.
- [Apple: NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) and [local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — local networking declarations and permission behavior.
