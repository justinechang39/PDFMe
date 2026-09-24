import XCTest
import PDFKit
@testable import PDFMeCore

final class ConverterTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFMeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func fixture(name: String = "Hello PDFMe.docx") throws -> URL {
        let source = root.appendingPathComponent(name)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/make-fixture.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, source.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return source
    }
    func requireEngine() throws { if Converter.engineURL == nil { throw XCTSkip("Install LibreOffice for integration tests") } }

    func testRejectsPDFAndDirectories() throws {
        let pdf = root.appendingPathComponent("input.pdf")
        try Data("%PDF-1.7".utf8).write(to: pdf)
        XCTAssertThrowsError(try Converter.validate(pdf))
        let directory = root.appendingPathComponent("folder.docx")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try Converter.validate(directory))
        XCTAssertThrowsError(try Converter.validate(root.appendingPathComponent("missing.docx")))
    }

    func testNumberedFilenamesPreserveExistingFiles() throws {
        let desired = root.appendingPathComponent("Report.pdf")
        try Data("original".utf8).write(to: desired)
        try Data().write(to: root.appendingPathComponent("Report (2).pdf"))
        XCTAssertEqual(Converter.availableDestination(desired).lastPathComponent, "Report (3).pdf")
        XCTAssertEqual(try String(contentsOf: desired, encoding: .utf8), "original")
    }

    func testDanglingSymlinksCountAsExistingFiles() throws {
        let destination = root.appendingPathComponent("Report.pdf")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("not-here.pdf"))
        XCTAssertEqual(Converter.availableDestination(destination).lastPathComponent, "Report (2).pdf")
    }

    func testConvertsEveryQualityAndPreservesTextPagesAndOriginal() async throws {
        try requireEngine()
        let source = try fixture(name: "Résumé & notes.DOCX")
        let original = try Data(contentsOf: source)
        for quality in PDFQuality.allCases {
            let result = try await Converter.convert(source: source, destination: root.appendingPathComponent("\(quality.rawValue).pdf"), quality: quality)
            let pdf = try XCTUnwrap(PDFDocument(url: result))
            XCTAssertEqual(pdf.pageCount, 2)
            XCTAssertTrue(pdf.string?.filter { !$0.isWhitespace }.contains("Alittlelesswork.") == true, "Extracted text: \(pdf.string ?? "nil")")
            XCTAssertTrue(pdf.string?.contains("Page two, too.") == true)
            XCTAssertFalse(pdf.isEncrypted)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPasswordProtectsEveryPageAndRejectsWrongPassword() async throws {
        try requireEngine()
        let source = try fixture()
        let output = try await Converter.convert(source: source, destination: root.appendingPathComponent("Locked.pdf"), quality: .balanced, password: "a-long-test-password")
        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(pdf.isEncrypted)
        XCTAssertTrue(pdf.isLocked)
        XCTAssertFalse(pdf.unlock(withPassword: "incorrect"))
        XCTAssertTrue(pdf.unlock(withPassword: "a-long-test-password"))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertTrue(pdf.string?.contains("Page two, too.") == true)
        if let destination = ProcessInfo.processInfo.environment["PDFME_QA_OUTPUT"] {
            let qa = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: qa.appendingPathComponent("Protected.pdf"))
            try FileManager.default.copyItem(at: output, to: qa.appendingPathComponent("Protected.pdf"))
        }
    }

    func testMalformedDocxFailsWithoutSaving() async throws {
        try requireEngine()
        let source = root.appendingPathComponent("fake.docx")
        try Data("not a zip file".utf8).write(to: source)
        let output = root.appendingPathComponent("fake.pdf")
        do {
            _ = try await Converter.convert(source: source, destination: output, quality: .balanced)
            XCTFail("Expected invalid document error")
        } catch { XCTAssertTrue(error is ConversionError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testConversionNeverOverwritesAndSavesToSelectedFolder() async throws {
        try requireEngine()
        let source = try fixture()
        let folder = root.appendingPathComponent("Chosen folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let desired = folder.appendingPathComponent("Custom.pdf")
        try Data("keep me".utf8).write(to: desired)
        let result = try await Converter.convert(source: source, destination: desired, quality: .balanced)
        XCTAssertEqual(result.lastPathComponent, "Custom (2).pdf")
        XCTAssertEqual(result.deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(try String(contentsOf: desired, encoding: .utf8), "keep me")
    }

    func testCancellationDoesNotPublishOutput() async throws {
        try requireEngine()
        let source = try fixture()
        let destination = root.appendingPathComponent("Cancelled.pdf")
        let task = Task { try await Converter.convert(source: source, destination: destination, quality: .best) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testMissingDestinationFailsWithoutChangingSource() async throws {
        try requireEngine()
        let source = try fixture()
        let data = try Data(contentsOf: source)
        do {
            _ = try await Converter.convert(source: source, destination: root.appendingPathComponent("missing/output.pdf"), quality: .balanced)
            XCTFail("Expected destination failure")
        } catch { XCTAssertEqual(try Data(contentsOf: source), data) }
    }
}
