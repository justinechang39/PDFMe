import Foundation
import CoreGraphics
import CoreText
import PDFKit

@main
struct PrintChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PrintError.message("FAIL: " + message) }
        print("PASS: " + message)
    }
    static func makePDF(_ url: URL, prefix: String, pages: Int) {
        var box = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
            context.setFillColor(CGColor(red: prefix == "A" ? 0.18 : 0.22, green: prefix == "A" ? 0.4 : 0.28, blue: prefix == "A" ? 0.25 : 0.55, alpha: 1))
            context.fill(CGRect(x: 30, y: 660, width: 535, height: 150))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            drawText("\(prefix)\(page)", x: 55, y: 710, size: 64, color: CGColor(gray: 1, alpha: 1), context: context)
            drawText("PDFMe print test", x: 40, y: 620, size: 22, context: context)
            drawText("TOP LEFT", x: 40, y: 805, size: 10, color: CGColor(gray: 1, alpha: 1), context: context)
            drawText("Bottom left - page \(page)", x: 40, y: 35, size: 12, context: context)
            context.setStrokeColor(CGColor(gray: 0.3, alpha: 1)); context.setLineWidth(1)
            context.stroke(CGRect(x: 30, y: 25, width: 535, height: 790))
            context.endPDFPage()
        }
        context.closePDF()
    }
    static func drawText(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor = CGColor(gray: 0.15, alpha: 1), context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, context)
    }
    static func pixels(_ page: PDFPage) -> Data {
        let width = 500, height = 500
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgPage = page.pageRef!
        context.concatenate(cgPage.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(cgPage)
        return Data(bytes: context.data!, count: width * height * 4)
    }
    /// Page labels such as A1 or C21 drawn on each fixture page, read from a prepared side.
    static func labels(_ page: PDFPage) -> Set<String> {
        let text = page.string ?? ""
        let regex = try! NSRegularExpression(pattern: "\\b[A-Z][0-9]+\\b")
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) })
    }
    static func rejects(_ text: String, pageCount: Int) -> Bool {
        (try? PageSelection.parse(text, pageCount: pageCount)) == nil && PageSelection.custom(text).validationMessage(pageCount: pageCount) != nil
    }
    static func pageRangeChecks(root: URL, a: URL, b: URL) throws {
        let c = root.appendingPathComponent("03 Sample C.pdf")
        makePDF(c, prefix: "C", pages: 30)
        func oneBased(_ text: String) -> [Int]? { try? PageSelection.parse(text, pageCount: 30).map { $0 + 1 } }
        try check(oneBased("1-15, 21-30") == Array(1...15) + Array(21...30), "disjoint ranges use 1-based PDF page numbers")
        try check(oneBased("21-end") == Array(21...30) && oneBased("end") == [30] && oneBased("28 – END") == [28, 29, 30], "end means the last PDF page")
        try check(oneBased(" 4 ") == [4] && oneBased("2–3,5—6, 8 - 9") == [2, 3, 5, 6, 8, 9], "single pages, whitespace, en and em dashes")
        try check(oneBased("20-22, 1, 3-5, 4-9, 1") == [1, 3, 4, 5, 6, 7, 8, 9, 20, 21, 22], "overlaps are deduplicated and kept in document order")
        let invalid = ["", " ", "1,", ",1", "1,,2", "0", "-3", "3-", "1--3", "1-2-3", "9-4", "end-3", "31", "29-31", "1.5", "+2", "a", "1 2", "١",
                       "99999999999999999999999999", "2-99999999999999999999999", String(repeating: "9", count: 5000)]
        for text in invalid { try check(rejects(text, pageCount: 30), "invalid page entry rejected: \(text.prefix(20).debugDescription)") }
        try check(CopyCount.parse("4") == 4 && [" ", "", "0", "1000", "4a", "4.0", "-1"].allSatisfy { CopyCount.parse($0) == nil }, "copy text accepts only 1–999")

        // Actual prepared content: selection before 2-up, duplex blanks, and collated copies.
        let template = PrintTemplate(orientation: .landscape, duplex: .shortEdge, pagesPerSide: 2, printAsImage: false)
        var inputs = try PrintComposer.inspect([a, c, b])
        inputs[0].pageSelection = .custom("3, 1"); inputs[0].copies = 2
        inputs[1].pageSelection = .custom("1-3, 21-22, 2, 29-end")
        inputs[2].pageSelection = .custom("2")
        let output = root.appendingPathComponent("Page ranges 2-up duplex.pdf")
        let plan = try PrintComposer.prepare(inputs: inputs, template: template, output: output)
        let pdf = PDFDocument(url: output)!
        let expected: [Set<String>] = [["A1", "A3"], [], ["A1", "A3"], [], ["C1", "C2"], ["C3", "C21"], ["C22", "C29"], ["C30"], ["B2"], []]
        try check(pdf.pageCount == expected.count && plan.sides.count == expected.count && plan.sheetCount == 5, "page ranges change the actual side and sheet count")
        try check((0..<pdf.pageCount).map { labels(pdf.page(at: $0)!) } == expected, "prepared PDF prints exactly the selected pages, in document order, before 2-up, duplex, and copies")
        for index in plan.sides.indices {
            let data = try PrintComposer.previewSide(urls: inputs.map(\.url), side: plan.sides[index], template: template)
            let preview = PDFDocument(data: data)!
            try check(pixels(preview.page(at: 0)!) == pixels(pdf.page(at: index)!), "page-range preview matches printed side \(index + 1)")
        }
        var single = PrintTemplate(printAsImage: false)
        single.startEachFileOnNewSheet = false
        let simple = root.appendingPathComponent("Page ranges 1-up.pdf")
        var tail = try PrintComposer.inspect([c]); tail[0].pageSelection = .custom("21-end")
        _ = try PrintComposer.prepare(inputs: tail, template: single, output: simple)
        let simplePDF = PDFDocument(url: simple)!
        try check(simplePDF.pageCount == 10 && (0..<10).allSatisfy { labels(simplePDF.page(at: $0)!) == ["C\($0 + 21)"] }, "21-end prints PDF pages 21 through 30 one per side")
        tail[0].pageSelection.isCustom = false
        _ = try PrintComposer.prepare(inputs: tail, template: single, output: simple)
        try check(PDFDocument(url: simple)!.pageCount == 30, "switching back to All prints every page, even with custom text retained")

        var bad = try PrintComposer.inspect([a]); bad[0].pageSelection = .custom("2-4")
        let blocked = root.appendingPathComponent("Blocked range.pdf")
        do { _ = try PrintComposer.prepare(inputs: bad, template: single, output: blocked); throw PrintError.message("FAIL: invalid range composed") }
        catch PrintError.message(let text) { try check(!text.hasPrefix("FAIL") && text.contains("01 Sample A.pdf") && !FileManager.default.fileExists(atPath: blocked.path), "out-of-range selection blocks composition with the file name") }
        let stale = [PrintInput(url: a, pages: 5, pageSelection: .custom("5"))]
        do { _ = try PrintComposer.prepare(inputs: stale, template: single, output: blocked); throw PrintError.message("FAIL: changed PDF composed") }
        catch PrintError.message(let text) { try check(!text.hasPrefix("FAIL") && text.contains("changed"), "a PDF whose page count changed after review is not printed") }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("01 Sample A.pdf"), b = root.appendingPathComponent("02 Sample B.pdf")
        makePDF(a, prefix: "A", pages: 3); makePDF(b, prefix: "B", pages: 2)
        let sourceData = try Data(contentsOf: a)
        var template = PrintTemplate(name: "Test", printerID: "test_queue", orientation: .landscape, duplex: .shortEdge, pagesPerSide: 2, printAsImage: false)
        let inspected = try PrintComposer.inspect([a, b])
        try check(inspected.map(\.pages) == [3, 2], "inspect PDF page counts")
        let plan = try PrintPlan(pageCounts: [3, 2], template: template)
        try check(plan.sides.count == 4 && plan.sheetCount == 2, "2-up duplex starts each PDF on a new sheet")
        try check(plan.sides[0].map(\.page) == [0, 1] && plan.sides[1].map(\.page) == [2], "page order within first file")
        try check(plan.sides[2].map(\.document) == [1, 1] && plan.sides[3].isEmpty, "second PDF has a blank back")
        template.startEachFileOnNewSheet = false
        let continuous = try PrintPlan(pageCounts: [3, 2], template: template)
        try check(continuous.sides[1].map(\.document) == [0, 1], "continuous mode can share a side across PDFs")
        template.startEachFileOnNewSheet = true
        let vector = root.appendingPathComponent("2-up vector.pdf")
        _ = try PrintComposer.prepare(urls: [a, b], template: template, output: vector)
        let vectorPDF = PDFDocument(url: vector)!
        try check(vectorPDF.pageCount == 4, "prepared PDF has all four sides")
        try check(abs(vectorPDF.page(at: 0)!.bounds(for: .mediaBox).width - 841.89) < 1, "prepared paper is landscape A4")
        try check(vectorPDF.page(at: 0)!.string?.contains("A1") == true && vectorPDF.page(at: 0)!.string?.contains("A2") == true, "first side contains A1 then A2")
        try check(vectorPDF.page(at: 2)!.string?.contains("B1") == true, "second document appears in order")
        let copiesOutput = root.appendingPathComponent("Per-file copies.pdf")
        let copiesPlan = try PrintComposer.prepare(urls: [a, b], template: template, output: copiesOutput, copies: [2, 1])
        let copiesPDF = PDFDocument(url: copiesOutput)!
        try check(copiesPlan.sheetCount == 3 && copiesPDF.pageCount == 6, "independent PDF copy counts produce the correct sheet total")
        let expected = ["A1", "A3", "A1", "A3", "B1"]
        try check(expected.enumerated().allSatisfy { copiesPDF.page(at: $0.offset)!.string?.contains($0.element) == true }, "per-file copies are collated A, A, B in the actual prepared PDF")
        try check(copiesPlan.sides[5].isEmpty, "duplex per-file copies preserve the final blank back")
        for index in copiesPlan.sides.indices {
            let data = try PrintComposer.previewSide(urls: [a, b], side: copiesPlan.sides[index], template: template)
            let preview = PDFDocument(data: data)!
            try check(preview.pageCount == 1 && pixels(preview.page(at: 0)!) == pixels(copiesPDF.page(at: index)!), "inline preview matches printed side \(index + 1), including copies and blank backs")
        }
        try check(copiesPlan.sideIndices(forDocument: 0) == [0, 1, 2, 3] && copiesPlan.sideIndices(forDocument: 1) == [4, 5], "file selection maps to its actual batch sides")
        let sharedData = try PrintComposer.previewSide(urls: [a, b], side: continuous.sides[1], template: template)
        let sharedText = PDFDocument(data: sharedData)!.string ?? ""
        try check(sharedText.contains("A3") && sharedText.contains("B1"), "preview preserves pages from both PDFs on a shared side")
        let packedCopies = try PrintPlan(pageCounts: [1, 1], template: PrintTemplate(duplex: .shortEdge, pagesPerSide: 2, startEachFileOnNewSheet: false), copies: [2, 1])
        try check(packedCopies.sheetCount == 2 && packedCopies.sides[1].isEmpty && packedCopies.sides[2].map(\.document) == [0, 1], "continuous files still keep repeat copies on separate sheets")
        try pageRangeChecks(root: root, a: a, b: b)
        for counts in [[0], [1000], [], [1, 2]] {
            do { _ = try PrintPlan(pageCounts: [1], template: template, copies: counts); throw PrintError.message("FAIL: invalid copies accepted") }
            catch PrintError.message(let text) { try check(!text.hasPrefix("FAIL"), "invalid copy counts rejected: \(counts)") }
        }
        template.printAsImage = true; template.dpi = 150
        _ = try PrintComposer.prepare(urls: [a, b], template: template, output: root.appendingPathComponent("2-up image.pdf"))
        let raster = PDFDocument(url: root.appendingPathComponent("2-up image.pdf"))!
        try check(raster.pageCount == 4 && (raster.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "print as image rasterizes the pages")
        let imagePreview = try PrintComposer.previewSide(urls: [a, b], side: plan.sides[0], template: template)
        try check(pixels(PDFDocument(data: imagePreview)!.page(at: 0)!) == pixels(raster.page(at: 0)!), "image preview matches rasterized print output")
        template.color = .grayscale
        _ = try PrintComposer.prepare(urls: [a], template: template, output: root.appendingPathComponent("grayscale image.pdf"))
        let rotated = root.appendingPathComponent("Rotated crop.pdf")
        let rotatedDoc = PDFDocument(url: b)!
        rotatedDoc.page(at: 0)!.rotation = 90
        rotatedDoc.page(at: 1)!.setBounds(CGRect(x: 25, y: 20, width: 540, height: 800), for: .cropBox)
        rotatedDoc.write(to: rotated)
        var mixed = template; mixed.printAsImage = false; mixed.color = .color; mixed.pagesPerSide = 4
        _ = try PrintComposer.prepare(urls: [a, rotated], template: mixed, output: root.appendingPathComponent("4-up rotated crop.pdf"))
        try check(PDFDocument(url: root.appendingPathComponent("4-up rotated crop.pdf"))!.pageCount == 4, "4-up handles rotated pages and cropped pages with file boundaries")
        let caps = PrinterCapabilities(output: "PageSize/Media: *A4 Letter\nDuplex/Sides: None *DuplexNoTumble DuplexTumble\nColorModel/Color: Gray *RGB")
        let args = try PrinterService.arguments(file: vector, template: template, copies: 3, capabilities: caps)
        try check(args.contains("number-up=1") && args.contains("Collate=True") && args.contains("multiple-document-handling=separate-documents-collated-copies"), "spool one prepared set with collated copies and no duplicate N-up")
        try check(args.contains("Duplex=DuplexTumble") && args.contains("sides=two-sided-short-edge") && args.contains("ColorModel=Gray"), "driver receives duplex and grayscale options")
        try check(args[args.firstIndex(of: "-n")! + 1] == "3", "copy count passed separately from file layout")
        try check(PrinterService.parseJobID("request id is test_queue-42 (1 file(s))", printerID: "test_queue") == "test_queue-42", "submission ID parsing")
        try check(PrinterService.parseJobID("request id is another-42 (1 file(s))", printerID: "test_queue") == nil, "foreign queue reply not accepted")
        let fake = root.appendingPathComponent("not-a-pdf.pdf")
        try Data("invalid".utf8).write(to: fake)
        do { _ = try PrintComposer.inspect([fake]); throw PrintError.message("FAIL: invalid PDF accepted") }
        catch PrintError.message(let text) { try check(!text.hasPrefix("FAIL"), "malformed PDF rejected") }
        let docx = root.appendingPathComponent("document.docx")
        try Data().write(to: docx)
        do { _ = try PrintComposer.inspect([docx]); throw PrintError.message("FAIL: DOCX accepted") }
        catch PrintError.message(let text) { try check(!text.hasPrefix("FAIL"), "DOCX rejected by print workflow") }
        let locked = root.appendingPathComponent("locked.pdf")
        PDFDocument(url: a)!.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"])
        do { _ = try PrintComposer.inspect([locked]); throw PrintError.message("FAIL: locked PDF accepted") }
        catch PrintError.message(let text) { try check(!text.hasPrefix("FAIL"), "locked PDF rejected before submission") }
        var unsupported = template; unsupported.paper = .a3
        do { _ = try PrinterService.arguments(file: vector, template: unsupported, copies: 1, capabilities: caps); throw PrintError.message("FAIL: unsupported paper accepted") }
        catch PrintError.message(let text) { try check(!text.hasPrefix("FAIL"), "unsupported printer options blocked") }
        let roundtrip = try JSONDecoder().decode(PrintTemplate.self, from: JSONEncoder().encode(template))
        try check(roundtrip == template, "template persistence round trip")
        let unchanged = try Data(contentsOf: a)
        try check(unchanged == sourceData, "source PDFs unchanged")
        let printers = (try? await PrinterService.list()) ?? []
        print("Detected \(printers.count) installed printers. No print jobs submitted.")
        if let printer = printers.first {
            let actual = try await PrinterService.capabilities(for: printer.id)
            try check(!actual.papers.isEmpty, "read actual printer paper capabilities")
        }
        print("All print checks passed. Output: \(root.path)")
    }
}
