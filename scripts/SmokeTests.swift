// Standalone integration checks for Macs with Command Line Tools but no activated Xcode.
import Foundation
import PDFKit

@main
struct SmokeTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "PDFMeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS: \(message)")
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Hello PDFMe.docx")
        let original = try Data(contentsOf: source)
        for quality in PDFQuality.allCases {
            let output = try await Converter.convert(source: source, destination: root.appendingPathComponent("\(quality.rawValue).pdf"), quality: quality)
            let pdf = PDFDocument(url: output)!
            try check(pdf.pageCount == 2, "\(quality.rawValue): both pages survive")
            try check(pdf.string?.contains("A little less work.") == true, "\(quality.rawValue): selectable text survives")
        }
        let locked = try await Converter.convert(source: source, destination: root.appendingPathComponent("Protected.pdf"), quality: .balanced, password: "a-long-test-password")
        let pdf = PDFDocument(url: locked)!
        try check(pdf.isEncrypted && pdf.isLocked, "PDF requires a password")
        try check(!pdf.unlock(withPassword: "wrong"), "Wrong password rejected")
        try check(pdf.unlock(withPassword: "a-long-test-password") && pdf.pageCount == 2, "Correct password opens both pages")
        let desired = root.appendingPathComponent("Keep.pdf")
        try Data("original".utf8).write(to: desired)
        let numbered = try await Converter.convert(source: source, destination: desired, quality: .balanced)
        try check(numbered.lastPathComponent == "Keep (2).pdf", "Existing PDF gets a numbered sibling")
        let kept = try String(contentsOf: desired, encoding: .utf8)
        try check(kept == "original", "Existing file untouched")
        let invalid = root.appendingPathComponent("fake.docx")
        try Data("invalid".utf8).write(to: invalid)
        do {
            _ = try await Converter.convert(source: invalid, destination: root.appendingPathComponent("fake.pdf"), quality: .balanced)
            fatalError("Invalid DOCX was accepted")
        } catch ConversionError.invalidDocument { print("PASS: malformed DOCX rejected") }
        do { try Converter.validate(desired); fatalError("PDF accepted") }
        catch ConversionError.unsupported { print("PASS: non-DOCX rejected") }
        let directory = root.appendingPathComponent("folder.docx")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try Converter.validate(directory); fatalError("Directory accepted") }
        catch ConversionError.unreadable { print("PASS: directory rejected") }
        let cancelOutput = root.appendingPathComponent("Cancelled.pdf")
        let task = Task { try await Converter.convert(source: source, destination: cancelOutput, quality: .best) }
        task.cancel()
        do { _ = try await task.value; fatalError("Cancellation ignored") }
        catch is CancellationError { print("PASS: cancellation honored") }
        try check(!fm.fileExists(atPath: cancelOutput.path), "Cancelled job publishes no output")
        let updated = try Data(contentsOf: source)
        try check(original == updated, "Original DOCX unchanged")
        let unicode = root.appendingPathComponent("Résumé & notes.DOCX")
        try fm.copyItem(at: source, to: unicode)
        let unicodeOutput = try await Converter.convert(source: unicode, destination: unicode.deletingPathExtension().appendingPathExtension("pdf"), quality: .balanced)
        try check(unicodeOutput.lastPathComponent == "Résumé & notes.pdf", "Unicode, spaces, ampersand, and uppercase extension work")
        print("All integration checks passed.")
    }
}
