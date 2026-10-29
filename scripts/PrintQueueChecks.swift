import AppKit
import PDFKit
import PDFMeCore

/// Behaves like a printer that briefly stops accepting work after the first upload.
actor GroupIPPPrinter {
    var uploads = 0
    var waitingChecks = 0
    var operations: [UInt16] = []
    var pause = true
    func resume() { pause = false }
    func send(_ uri: URL, _ body: Data, _ file: URL?) throws -> Data {
        let request = try IPPCodec.decode(body)
        operations.append(request.code)
        var attributes: [IPPAttribute] = []
        if request.code == 11 {
            let waiting = uploads == 1 && pause
            if waiting { waitingChecks += 1 }
            attributes = [.text("document-format-supported", ["application/pdf"]),
                .init(tag: 0x23, name: "operations-supported", values: [4, 5, 6, 8].map { IPPAttribute.integer("", $0).values[0] }),
                .text("media-supported", PrintPaper.allCases.map(\.ippMedia)),
                .text("sides-supported", PrintDuplex.allCases.map(\.cupsValue)),
                .text("print-color-mode-supported", ["color", "monochrome"]),
                .boolean("printer-is-accepting-jobs", !waiting),
                .integer("printer-state", waiting ? 5 : 4, tag: 0x23)]
        } else if request.code == 5 { attributes = [.integer("job-id", uploads + 1)] }
        else if request.code == 6 {
            precondition(file != nil && request.integers("job-id") == [uploads + 1])
            uploads += 1
        } else { precondition(request.code == 4) }
        return try IPPCodec.encode(code: 0, requestID: request.requestID, groups: [(request.code == 11 ? 4 : 2, attributes)])
    }
}

@main
struct PrintQueueChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PrintError.message("FAIL: " + message) }
        print("PASS: " + message)
    }
    @MainActor
    static func ready(_ model: PrintModel, name: String) {
        model.template = PrintTemplate(name: name, printerID: "", duplex: .longEdge)
        model.printers = [Printer(id: "", name: "Mock")]
        model.capabilities = PrinterCapabilities(output: "PageSize/Paper: A4\nDuplex/Sides: None DuplexNoTumble DuplexTumble\nColorModel/Color: RGB Gray")
        model.notificationsEnabled = false
    }
    @MainActor
    static func waitForImports(_ queue: PrintQueueModel) async throws {
        for _ in 0..<500 {
            if !queue.isImporting { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw PrintError.message("Imports timed out")
    }
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let urls = [root.appendingPathComponent("01 Sample A.pdf"), root.appendingPathComponent("02 Sample B.pdf")]
        let inputs = try PrintComposer.inspect(urls)
        let primary = PrintModel(); ready(primary, name: "Full page")
        let queue = PrintQueueModel(primary: primary, discoverPrinters: false)
        let first = queue.groups[0]
        let second = queue.addGroup(template: primary.template)!
        ready(second.model, name: "Two-up")
        second.model.template.orientation = .landscape; second.model.template.pagesPerSide = 2
        queue.selectedID = first.id
        queue.accept([urls[0]]); queue.accept([urls[1]])
        try await waitForImports(queue)
        try check(primary.inputs.map(\.url) == urls, "rapid imports are serialized without losing files or changing their order")
        try check(primary === first.model, "mini app and desktop share the same primary documents")
        primary.setCopies(3, for: primary.inputs[0].id)
        let movedID = primary.inputs[0].id
        queue.moveDocument(movedID, from: first.id, to: second.id)
        try check(primary.inputs.count == 1 && second.model.inputs.first?.copies == 3, "moving a PDF between groups keeps copies and removes the original entry")
        try check(primary.template.orientation == .portrait && second.model.template.orientation == .landscape, "groups retain independent setting snapshots")
        let third = queue.addGroup(template: primary.template)!
        ready(third.model, name: "Third")
        third.model.inputs = [inputs[0]]
        var calls: [String] = []; var inFlight = 0; var maxInFlight = 0
        for group in queue.groups {
            group.model.submitPrepared = { file, template, _ in
                inFlight += 1; maxInFlight = max(inFlight, maxInFlight)
                defer { inFlight -= 1 }
                try check(queue.groups.allSatisfy { $0.model.reservedForQueue }, "all group entry points are locked during submission")
                try check(PDFDocument(url: file)?.pageCount == group.model.plan?.sides.count, "prepared job materializes per-document copies and layout exactly once")
                calls.append(template.name)
                try await Task.sleep(nanoseconds: 20_000_000)
                return PrintSubmission(jobID: "mock-\(calls.count)", printerName: "Mock")
            }
        }
        try check(queue.canPrint, "valid groups can be submitted")
        queue.printAll(); await queue.operation?.value
        try check(calls == ["Full page", "Two-up", "Third"] && maxInFlight == 1, "groups submit in display order with only one upload in flight")
        try check(queue.documentCount == 0 && !queue.canPrint && queue.groups.allSatisfy { !$0.model.reservedForQueue }, "sent groups clear and unlock, preventing accidental repeat printing")
        queue.printAll()
        try check(calls.count == 3, "a second Print action cannot resubmit accepted groups")

        // Failure after an accepted first group must leave later groups untouched.
        for group in queue.groups { group.model.inputs = [inputs[0]] }
        calls = []
        second.model.submitPrepared = { _, template, _ in
            calls.append(template.name)
            throw PrintError.message("Synthetic lost response")
        }
        queue.printAll(); await queue.operation?.value
        try check(calls == ["Full page", "Two-up"] && primary.inputs.isEmpty && third.model.inputs.count == 1, "failure stops the batch without resending success or touching later groups")
        try check(second.model.requiresSubmissionReview && !queue.canPrint, "unknown submission requires explicit review before retry")
        second.model.clear()
        calls = []
        queue.printAll(); await queue.operation?.value
        try check(calls == ["Third"], "clearing the uncertain group allows only the unsent group to print")

        for group in queue.groups { group.model.inputs = [inputs[0]] }
        second.model.submitPrepared = { _, _, _ in
            throw DirectPrintFailure(submission: PrintSubmission(jobID: "42", printerName: "Mock", directPrinterURI: URL(string: "ipp://localhost/ipp/print")!), message: "Synthetic uncertain upload")
        }
        queue.printAll(); await queue.operation?.value
        try check(second.model.inputs.isEmpty && second.model.submission?.jobID == "42" && third.model.inputs.count == 1, "uncertain direct job keeps its receipt, clears its files, and stops later groups")

        primary.inputs = [inputs[0]]; second.model.clear(); third.model.inputs = [inputs[1]]
        primary.submitPrepared = { _, _, _ in
            queue.stopAfterCurrent()
            return PrintSubmission(jobID: "stop-test", printerName: "Mock")
        }
        queue.printAll(); await queue.operation?.value
        try check(primary.inputs.isEmpty && third.model.inputs.count == 1 && !queue.isPrinting, "stop-after-current finishes the accepted job and keeps future groups")

        // Missing source is detected during composition, before any printer call.
        third.model.clear()
        primary.inputs = [PrintInput(url: root.appendingPathComponent("missing.pdf"), pages: 1)]
        var submitted = false
        primary.submitPrepared = { _, _, _ in submitted = true; return PrintSubmission(jobID: "bad", printerName: "Mock") }
        queue.printAll(); await queue.operation?.value
        try check(!submitted && !primary.inputs.isEmpty && !primary.requiresSubmissionReview, "preparation failure retains documents and never contacts a printer")
        primary.clear()

        // A direct-printer preflight refusal has sent no document, so retry is safe.
        primary.inputs = [inputs[0]]
        primary.submitPrepared = { file, template, _ in
            let client = try IPPClient(uri: URL(string: "ipp://localhost/ipp/print")!, sender: { _, data, file in
                let request = try IPPCodec.decode(data)
                precondition(request.code == 11 && file == nil)
                return try IPPCodec.encode(code: 0x040B, requestID: request.requestID,
                    groups: [(1, [.text("status-message", ["Synthetic preflight refusal"])])])
            })
            return try await DirectPrinterService.submit(file: file, template: template,
                printer: Printer(id: "", name: "Mock"), client: client)
        }
        queue.printAll(); await queue.operation?.value
        try check(primary.lastAttempt == .failed && !primary.requiresSubmissionReview && primary.inputs.count == 1,
                  "direct preflight failure retains unsent files without an Allow retry gate")
        primary.clear()

        // Exercise real direct submission across groups, not just a successful mock callback.
        let hardware = GroupIPPPrinter()
        for group in [first, second] {
            group.model.inputs = [inputs[0]]
            group.model.submitPrepared = { file, template, _ in
                let client = try IPPClient(uri: URL(string: "ipp://localhost/ipp/print")!, sender: { try await hardware.send($0, $1, $2) })
                return try await DirectPrinterService.submit(file: file, template: template,
                    printer: Printer(id: "", name: "Mock"), client: client, readiness: .init(checks: 4, delayNanoseconds: 0),
                    status: { status in
                        if status == "Waiting for printer…" { await hardware.resume() }
                    })
            }
        }
        queue.printAll(); await queue.operation?.value
        let actualOperations = await hardware.operations
        try check(actualOperations == [11,4,5,6,11,11,4,5,6],
                  "second group waits for printer readiness and sends exactly once without recreating groups")
        try check(queue.documentCount == 0 && !queue.isError, "both groups clear after two confirmed direct submissions")

        let unavailable = GroupIPPPrinter()
        for group in [first, second, third] {
            group.model.inputs = [inputs[0]]
            group.model.submitPrepared = { file, template, _ in
                let client = try IPPClient(uri: URL(string: "ipp://localhost/ipp/print")!, sender: { try await unavailable.send($0, $1, $2) })
                return try await DirectPrinterService.submit(file: file, template: template,
                    printer: Printer(id: "", name: "Mock"), client: client, readiness: .init(checks: 2, delayNanoseconds: 0))
            }
        }
        queue.printAll(); await queue.operation?.value
        try check(primary.inputs.isEmpty && second.model.inputs.count == 1 && third.model.inputs.count == 1 && queue.canPrint,
                  "persistent refusal keeps only unsent groups ready for a safe retry")
        try check(queue.message?.contains("This group was not sent.") == true && queue.message?.contains("printer isn’t ready") == true,
                  "batch error includes the actual printer failure instead of hiding it")
        await unavailable.resume()
        queue.printAll(); await queue.operation?.value
        let uploadCount = await unavailable.uploads
        try check(uploadCount == 3 && queue.documentCount == 0,
                  "retry sends only remaining groups without deleting them or duplicating the first job")

        try await pageRangeChecks(queue: queue, groups: [first, second, third], root: root)

        // Finder pasteboard parsing and the actual service selector, including multiple URLs.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects(urls as [NSURL])
        try check(tryURLs(board) == urls, "Finder service accepts multiple PDF URLs in provided order")
        let service = FinderPrintService()
        var received: [URL] = []
        service.receive = { received = $0 }
        var error: NSString?
        service.addToPrintQueue(board, userData: nil, error: &error)
        try check(error == nil && received == urls && service.responds(to: NSSelectorFromString("addToPrintQueue:userData:error:")), "advertised Finder selector routes files for review without printing")
        board.clearContents(); board.writeObjects([urls[0], root.appendingPathComponent("wrong.docx")] as [NSURL])
        received = []; service.addToPrintQueue(board, userData: nil, error: &error)
        try check(error != nil && received.isEmpty, "mixed PDF and DOCX selections are rejected as a whole")
        board.clearContents(); board.writeObjects([URL(string: "https://example.com/file.pdf")!] as [NSURL])
        try check(tryURLs(board) == nil, "remote URLs are not accepted as Finder files")
        board.clearContents(); board.setPropertyList(urls.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        try check(tryURLs(board) == urls, "legacy Finder filename pasteboards preserve multiple selections")
        board.clearContents()
        try check(tryURLs(board) == nil, "empty pasteboards produce a useful selection error")
        queue.cleanup()
        print("All desktop queue and Finder service checks passed. No physical print jobs submitted.")
    }
    @MainActor static func tryURLs(_ board: NSPasteboard) -> [URL]? { try? FinderPrintService.fileURLs(from: board) }
    static func labels(_ page: PDFPage) -> Set<String> {
        let text = page.string ?? ""
        let regex = try! NSRegularExpression(pattern: "\\b[A-Z][0-9]+\\b")
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) })
    }

    /// Page selections and copy drafts belong to each document, survive moves, and gate every group.
    @MainActor
    static func pageRangeChecks(queue: PrintQueueModel, groups: [PrintGroup], root: URL) async throws {
        let (first, second, third) = (groups[0], groups[1], groups[2])
        let primary = first.model
        var calls: [String] = []
        var prepared: [String: [Set<String>]] = [:]
        for group in groups {
            group.model.clear()
            // Vector output keeps the fixture page labels readable in the prepared job.
            group.model.template.printAsImage = false
            group.model.submitPrepared = { file, template, _ in
                calls.append(template.name)
                let pdf = PDFDocument(url: file)!
                prepared[template.name] = (0..<pdf.pageCount).map { labels(pdf.page(at: $0)!) }
                return PrintSubmission(jobID: "range-\(calls.count)", printerName: "Mock")
            }
        }
        let a = root.appendingPathComponent("01 Sample A.pdf"), b = root.appendingPathComponent("02 Sample B.pdf")
        let c = root.appendingPathComponent("03 Sample C.pdf")
        primary.inputs = try PrintComposer.inspect([c, a])
        let cID = primary.inputs[0].id, aID = primary.inputs[1].id
        try check(primary.inputs.allSatisfy { !$0.pageSelection.isCustom } && primary.plan?.sheetCount == 17, "new documents default to all pages")
        primary.setPageSelection(.custom("21-end"), for: cID)
        primary.setPageSelection(.custom("2"), for: aID)
        try check(primary.plan?.sheetCount == 6 && primary.inputProblem == nil, "sheet count uses the selected pages")
        primary.move(aID, to: cID)
        try check(primary.inputs.map(\.id) == [aID, cID] && primary.inputs.map(\.pageSelection.text) == ["2", "21-end"], "reordering keeps each document’s page selection")
        queue.moveDocument(cID, from: first.id, to: second.id)
        try check(second.model.inputs.map(\.id) == [cID] && second.model.inputs[0].pageSelection == .custom("21-end") && primary.inputs.map(\.id) == [aID],
                  "moving a PDF to another group keeps its page selection")

        // An invalid later group blocks the whole batch, so earlier groups are not sent either.
        third.model.inputs = try PrintComposer.inspect([b])
        let bID = third.model.inputs[0].id
        for unfinished in ["", "1-", "1,", "3", "0", "2-1", "x"] {
            third.model.setPageSelection(.custom(unfinished), for: bID)
            try check(third.model.inputProblem != nil && third.model.plan == nil && !third.model.canPreview && !queue.canPrint,
                      "unfinished custom pages \(unfinished.debugDescription) block preview export and printing")
        }
        try check(queue.inputProblem?.hasPrefix("Group 3:") == true, "the queue names the group with the page problem")
        queue.printAll(); await queue.operation?.value
        try check(calls.isEmpty && queue.message?.contains("Nothing was sent") == true && primary.inputs.count == 1 && second.model.inputs.count == 1 && third.model.inputs.count == 1,
                  "Print all groups sends nothing while any group has an invalid range")
        third.model.prepare(previewOnly: true)
        try check(!third.model.busy && third.model.isError && third.model.message == third.model.inputProblem, "Open in Preview is refused for an invalid range instead of using all pages")
        third.model.prepare(previewOnly: false)
        try check(calls.isEmpty && !third.model.busy && third.model.lastAttempt == .failed, "a single group with an invalid range is not submitted")
        third.model.setPageSelection(.custom("1"), for: bID)
        third.model.setPageSelection(PageSelection(isCustom: false, text: "1"), for: bID)
        try check(third.model.plan?.sides.compactMap(\.first?.page) == [0, 1], "switching to All restores every page")

        // Copy text drafts: backspace to empty, retype, and never print a hidden stale count.
        primary.editCopies("", for: aID)
        try check(primary.copiesText(for: aID) == "" && primary.inputs[0].copies == 1 && primary.inputProblem != nil && !queue.canPrint,
                  "an empty copies field stays empty while editing and blocks printing")
        queue.printAll(); await queue.operation?.value
        try check(calls.isEmpty, "Print all groups never sends the stale count behind an empty copies field")
        primary.editCopies("2", for: aID)
        try check(primary.copiesText(for: aID) == "2" && primary.inputs[0].copies == 2 && primary.inputProblem == nil, "typing 2 after clearing applies 2, not 12 or 21")
        for text in ["2x", "2.5", "0", "1000", "-2"] {
            primary.editCopies(text, for: aID)
            try check(primary.copiesText(for: aID) == text && primary.inputs[0].copies == 2 && !queue.canPrint, "invalid copies \(text.debugDescription) stay visible and block printing")
        }
        primary.finishCopiesEdit(for: aID)
        try check(primary.copiesText(for: aID) == "2" && primary.inputProblem == nil, "leaving the field restores the last valid count")
        primary.editCopies("", for: aID)
        queue.moveDocument(aID, from: first.id, to: third.id)
        try check(primary.copyDrafts.isEmpty && third.model.inputs.last?.copies == 2 && third.model.inputs.last?.pageSelection == .custom("2") && third.model.inputProblem == nil,
                  "moving a document with an unfinished copy edit restores its last valid count")
        queue.moveDocument(aID, from: third.id, to: first.id)
        primary.setCopies(2, for: aID)

        try check(queue.canPrint, "valid page ranges and copies can be printed")
        queue.printAll(); await queue.operation?.value
        try check(calls == ["Full page", "Two-up", "Third"], "all groups submit once their ranges are valid")
        try check(prepared["Full page"] == [["A2"], [], ["A2"], []], "prepared job prints only page 2, collated twice with duplex blank backs")
        try check(prepared["Two-up"] == [["C21", "C22"], ["C23", "C24"], ["C25", "C26"], ["C27", "C28"], ["C29", "C30"], []], "moved document prints 21-end with the target group’s 2-up layout")
        try check(prepared["Third"] == [["B1"], ["B2"]], "All prints every page after a custom range was cleared")
        try check(queue.documentCount == 0, "groups with page ranges clear after submission")
    }
}
