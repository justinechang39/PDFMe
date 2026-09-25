import XCTest
@testable import PDFMeCore

final class PrintTests: XCTestCase {
    func testIndependentCopyCountsKeepEachDocumentCollated() throws {
        let plan = try PrintPlan(pageCounts: [3, 2], template: PrintTemplate(duplex: .shortEdge, pagesPerSide: 2), copies: [2, 1])
        XCTAssertEqual(plan.sheetCount, 3)
        XCTAssertEqual(plan.sides.flatMap { $0 }.map(\.document), [0, 0, 0, 0, 0, 0, 1, 1])
        XCTAssertEqual(plan.sides.flatMap { $0 }.map(\.page), [0, 1, 2, 0, 1, 2, 0, 1])
        XCTAssertTrue(plan.sides.last!.isEmpty)
    }
    func testCopiesNeverShareSheetsEvenWithContinuousFiles() throws {
        let plan = try PrintPlan(pageCounts: [1, 1], template: PrintTemplate(duplex: .shortEdge, pagesPerSide: 2, startEachFileOnNewSheet: false), copies: [2, 1])
        XCTAssertEqual(plan.sheetCount, 2)
        XCTAssertEqual(plan.sides[0].map(\.document), [0])
        XCTAssertTrue(plan.sides[1].isEmpty)
        XCTAssertEqual(plan.sides[2].map(\.document), [0, 1])
    }
    func testInvalidCopyCountsRejected() {
        for counts in [[0], [1000], [], [1, 2]] {
            XCTAssertThrowsError(try PrintPlan(pageCounts: [1], template: PrintTemplate(), copies: counts))
        }
    }
    func testDuplexStartsEachDocumentAndCopyOnNewSheet() throws {
        let template = PrintTemplate(duplex: .shortEdge, pagesPerSide: 2)
        let plan = try PrintPlan(pageCounts: [1, 3], template: template)
        XCTAssertEqual(plan.sides.count, 4)
        XCTAssertTrue(plan.sides[1].isEmpty)
        XCTAssertEqual(plan.sides[2].map(\.document), [1, 1])
        XCTAssertEqual(plan.sheetCount, 2)
    }
    func testContinuousModePreservesCrossFileOrder() throws {
        let template = PrintTemplate(duplex: .shortEdge, pagesPerSide: 2, startEachFileOnNewSheet: false)
        let plan = try PrintPlan(pageCounts: [1, 2], template: template)
        XCTAssertEqual(plan.sides[0].map(\.document), [0, 1])
        XCTAssertEqual(plan.sides[1].map(\.page), [1])
        XCTAssertEqual(plan.sheetCount, 1)
    }
    func testOddDuplexSidesReceiveBlankBack() throws {
        let plan = try PrintPlan(pageCounts: [5], template: PrintTemplate(duplex: .longEdge, pagesPerSide: 2, startEachFileOnNewSheet: false))
        XCTAssertEqual(plan.sides.count, 4)
        XCTAssertTrue(plan.sides.last!.isEmpty)
    }
    func testSingleSidedHasNoBlankBacks() throws {
        let plan = try PrintPlan(pageCounts: [1, 1], template: PrintTemplate(pagesPerSide: 2))
        XCTAssertEqual(plan.sides.count, 2)
        XCTAssertTrue(plan.sides.allSatisfy { !$0.isEmpty })
    }
    func testInvalidLayoutRejected() {
        XCTAssertThrowsError(try PrintPlan(pageCounts: [3], template: PrintTemplate(pagesPerSide: 0)))
        XCTAssertThrowsError(try PrintPlan(pageCounts: [], template: PrintTemplate()))
    }
    func testPrinterDiscoveryParsesDescriptionsAndDefault() {
        let printers = PrinterService.parsePrinters("printer hp_queue is idle.\n\tDescription: Office HP\nprinter other is idle.\n\tDescription: Other printer\n", defaultID: "hp_queue")
        XCTAssertEqual(printers.first?.id, "hp_queue")
        XCTAssertEqual(printers.first?.name, "Office HP")
        XCTAssertEqual(printers.first?.isDefault, true)
    }
    func testUnsupportedDuplexBlocked() {
        let caps = PrinterCapabilities(output: "PageSize/Media: *A4\nDuplex/Sides: *None\nColorModel/Mode: *RGB Gray")
        XCTAssertThrowsError(try caps.validate(PrintTemplate(duplex: .longEdge)))
    }
    func testArgumentsKeepPathsAndOptionsSeparate() throws {
        let caps = PrinterCapabilities(output: "PageSize/Media: *A4\nDuplex/Sides: *None DuplexNoTumble DuplexTumble\nColorModel/Mode: *RGB Gray")
        let template = PrintTemplate(printerID: "test_queue", orientation: .landscape, duplex: .shortEdge, pagesPerSide: 2)
        let file = URL(fileURLWithPath: "/tmp/a file; literal.pdf")
        let args = try PrinterService.arguments(file: file, template: template, copies: 2, capabilities: caps)
        XCTAssertEqual(args.suffix(2), ["--", file.path])
        XCTAssertTrue(args.contains("number-up=1"))
        XCTAssertTrue(args.contains("Collate=True"))
        XCTAssertTrue(args.contains("sides=two-sided-short-edge"))
        XCTAssertThrowsError(try PrinterService.arguments(file: file, template: template, copies: 0, capabilities: caps))
    }
    func testTemplatePersistsAllOptions() throws {
        let template = PrintTemplate(name: "My printer", printerID: "queue", orientation: .landscape, duplex: .shortEdge, pagesPerSide: 2, printAsImage: true, dpi: 600, color: .grayscale, startEachFileOnNewSheet: false)
        XCTAssertEqual(try JSONDecoder().decode(PrintTemplate.self, from: JSONEncoder().encode(template)), template)
    }
}
