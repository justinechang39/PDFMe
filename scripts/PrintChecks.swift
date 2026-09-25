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
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("01 Sample A.pdf"), b = root.appendingPathComponent("02 Sample B.pdf")
        makePDF(a, prefix: "A", pages: 3); makePDF(b, prefix: "B", pages: 2)
        let sourceData = try Data(contentsOf: a)
        var template = PrintTemplate(name: "Test", printerID: "test_queue", orientation: .landscape, duplex: .shortEdge, pagesPerSide: 2)
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
        let packedCopies = try PrintPlan(pageCounts: [1, 1], template: PrintTemplate(duplex: .shortEdge, pagesPerSide: 2, startEachFileOnNewSheet: false), copies: [2, 1])
        try check(packedCopies.sheetCount == 2 && packedCopies.sides[1].isEmpty && packedCopies.sides[2].map(\.document) == [0, 1], "continuous files still keep repeat copies on separate sheets")
        for counts in [[0], [1000], [], [1, 2]] {
            do { _ = try PrintPlan(pageCounts: [1], template: template, copies: counts); throw PrintError.message("FAIL: invalid copies accepted") }
            catch PrintError.message(let text) { try check(!text.hasPrefix("FAIL"), "invalid copy counts rejected: \(counts)") }
        }
        template.printAsImage = true; template.dpi = 150
        _ = try PrintComposer.prepare(urls: [a, b], template: template, output: root.appendingPathComponent("2-up image.pdf"))
        let raster = PDFDocument(url: root.appendingPathComponent("2-up image.pdf"))!
        try check(raster.pageCount == 4 && (raster.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "print as image rasterizes the pages")
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
