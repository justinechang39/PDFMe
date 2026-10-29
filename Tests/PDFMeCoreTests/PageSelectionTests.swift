import XCTest
@testable import PDFMeCore

final class PageSelectionTests: XCTestCase {
    private func pages(_ text: String, of count: Int) throws -> [Int] {
        try PageSelection.parse(text, pageCount: count).map { $0 + 1 }
    }

    func testDisjointRangesUseOneBasedPDFPageNumbers() throws {
        XCTAssertEqual(try pages("1-15, 21-30", of: 40), Array(1...15) + Array(21...30))
        XCTAssertEqual(PageSelection.custom("1-15, 21-30").validationMessage(pageCount: 40), nil)
    }
    func testEndIsTheFinalPage() throws {
        XCTAssertEqual(try pages("21-end", of: 30), Array(21...30))
        XCTAssertEqual(try pages("28 – END", of: 30), [28, 29, 30])
        XCTAssertEqual(try pages("end", of: 30), [30])
        XCTAssertEqual(try pages("1-end", of: 1), [1])
    }
    func testSinglePagesAndDashesWithWhitespace() throws {
        XCTAssertEqual(try pages("4", of: 9), [4])
        XCTAssertEqual(try pages(" 2 ,5,  7 ", of: 9), [2, 5, 7])
        XCTAssertEqual(try pages("2–3, 5—6, 8 - 9", of: 9), [2, 3, 5, 6, 8, 9])
        XCTAssertEqual(try pages("3-3", of: 9), [3])
    }
    func testOverlapsAreDeduplicatedAndPrintedInDocumentOrder() throws {
        XCTAssertEqual(try pages("8-10, 1, 3-5, 4-9, 1", of: 12), [1, 3, 4, 5, 6, 7, 8, 9, 10])
    }
    func testInvalidEntriesAreRejectedWithoutCrashing() {
        let invalid = ["", "   ", ",", "1,", ",1", "1,,2", "0", "0-3", "-3", "3-", "-", "--", "1--3", "1-2-3",
                       "4-2", "end-3", "11", "5-11", "1.5", "+2", "a", "1 2", "1;2", "١", "2 to 3",
                       "99999999999999999999999999", "1-99999999999999999999999999", "9223372036854775807",
                       String(repeating: "9", count: 5000)]
        for text in invalid {
            XCTAssertThrowsError(try PageSelection.parse(text, pageCount: 10), "accepted \(text.prefix(30))")
            XCTAssertNotNil(PageSelection.custom(text).validationMessage(pageCount: 10))
        }
    }
    func testAllIgnoresStoredCustomText() throws {
        var selection = PageSelection.custom("2, nonsense")
        XCTAssertThrowsError(try selection.pages(of: 3))
        selection.isCustom = false
        XCTAssertEqual(try selection.pages(of: 3), [0, 1, 2])
        XCTAssertEqual(PageSelection.all, PageSelection())
    }
    func testInputDefaultsToAllPages() throws {
        let input = PrintInput(url: URL(fileURLWithPath: "/tmp/a.pdf"), pages: 4)
        XCTAssertFalse(input.pageSelection.isCustom)
        XCTAssertEqual(try input.selectedPages(), [0, 1, 2, 3])
    }
    func testCopyCountParsing() {
        XCTAssertEqual(CopyCount.parse("4"), 4)
        XCTAssertEqual(CopyCount.parse("999"), 999)
        XCTAssertEqual(CopyCount.parse(" 12 "), 12)
        for text in ["", " ", "0", "1000", "-1", "+3", "4.0", "4a", "four", "١", "99999999999999999999"] {
            XCTAssertNil(CopyCount.parse(text), text)
        }
    }

    // Selection happens before n-up, duplex, and collated copies.
    func testSelectionPlansWithTwoUpDuplexAndCollatedCopies() throws {
        let template = PrintTemplate(duplex: .shortEdge, pagesPerSide: 2)
        let a = PrintInput(url: URL(fileURLWithPath: "/tmp/a.pdf"), pages: 10, copies: 2, pageSelection: .custom("2, 5-6"))
        let b = PrintInput(url: URL(fileURLWithPath: "/tmp/b.pdf"), pages: 4, pageSelection: .custom("4-end"))
        let plan = try PrintPlan(inputs: [a, b], template: template)
        XCTAssertEqual(plan.sides.map { $0.map(\.document) }, [[0, 0], [0], [0, 0], [0], [1], []])
        XCTAssertEqual(plan.sides.map { $0.map(\.page) }, [[1, 4], [5], [1, 4], [5], [3], []])
        XCTAssertEqual(plan.sheetCount, 3)
        XCTAssertEqual(plan.sideIndices(forDocument: 0), [0, 1, 2, 3])
        XCTAssertEqual(plan.sideIndices(forDocument: 1), [4, 5])
    }
    func testSelectionAddsBlankBackAfterOddCopy() throws {
        let input = PrintInput(url: URL(fileURLWithPath: "/tmp/a.pdf"), pages: 9, copies: 2, pageSelection: .custom("3"))
        let plan = try PrintPlan(inputs: [input], template: PrintTemplate(duplex: .longEdge))
        XCTAssertEqual(plan.sides.map { $0.map(\.page) }, [[2], [], [2], []])
    }
    func testContinuousFilesShareSidesAfterSelection() throws {
        let template = PrintTemplate(pagesPerSide: 4, startEachFileOnNewSheet: false)
        let a = PrintInput(url: URL(fileURLWithPath: "/tmp/a.pdf"), pages: 6, pageSelection: .custom("6, 1"))
        let b = PrintInput(url: URL(fileURLWithPath: "/tmp/b.pdf"), pages: 3)
        let plan = try PrintPlan(inputs: [a, b], template: template)
        XCTAssertEqual(plan.sides.map { $0.map(\.document) }, [[0, 0, 1, 1], [1]])
        XCTAssertEqual(plan.sides.map { $0.map(\.page) }, [[0, 5, 0, 1], [2]])
    }
    func testAllPagesMatchesLegacyPageCountPlan() throws {
        let template = PrintTemplate(duplex: .shortEdge, pagesPerSide: 2)
        let inputs = [PrintInput(url: URL(fileURLWithPath: "/tmp/a.pdf"), pages: 3, copies: 2),
                      PrintInput(url: URL(fileURLWithPath: "/tmp/b.pdf"), pages: 2)]
        XCTAssertEqual(try PrintPlan(inputs: inputs, template: template).sides,
                       try PrintPlan(pageCounts: [3, 2], template: template, copies: [2, 1]).sides)
    }
    func testInvalidSelectionBlocksThePlan() {
        let input = PrintInput(url: URL(fileURLWithPath: "/tmp/report.pdf"), pages: 5, pageSelection: .custom("4-9"))
        XCTAssertThrowsError(try PrintPlan(inputs: [input], template: PrintTemplate())) { error in
            XCTAssertTrue(error.localizedDescription.contains("report.pdf"))
        }
        XCTAssertThrowsError(try PrintPlan(pages: [[]], template: PrintTemplate()))
        XCTAssertThrowsError(try PrintPlan(pages: [[-1]], template: PrintTemplate()))
    }
}
