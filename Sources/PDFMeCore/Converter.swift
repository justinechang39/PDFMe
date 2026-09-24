import Foundation
import PDFKit
import Darwin

public enum PDFQuality: String, CaseIterable, Sendable {
    case compact = "Small", balanced = "Balanced", best = "Best"
    public var detail: String {
        switch self {
        case .compact: return "Smaller files · 150 dpi images"
        case .balanced: return "Everyday quality · 300 dpi images"
        case .best: return "Original resolution · lossless images"
        }
    }
    public var filter: String {
        let values: [String: [String: String]] = [
            "Quality": ["type": "long", "value": self == .compact ? "75" : "90"],
            "UseLosslessCompression": ["type": "boolean", "value": self == .best ? "true" : "false"],
            "ReduceImageResolution": ["type": "boolean", "value": self == .best ? "false" : "true"],
            "MaxImageResolution": ["type": "long", "value": self == .compact ? "150" : "300"],
            "UseTaggedPDF": ["type": "boolean", "value": "true"],
            "ExportBookmarks": ["type": "boolean", "value": "true"],
            "ExportNotes": ["type": "boolean", "value": "false"]
        ]
        let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        return "pdf:writer_pdf_Export:" + String(decoding: data, as: UTF8.self)
    }
}

public enum ConversionError: LocalizedError {
    case unsupported, unreadable, invalidDocument, missingEngine, conversionFailed, invalidPDF, encryptionFailed, timeout
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "DOCX files only. Choose a Word document ending in .docx."
        case .unreadable: return "This file can’t be read. Check its permissions and download it from iCloud or your cloud drive first."
        case .invalidDocument: return "This isn’t a valid DOCX document, or it is encrypted. Open it in Word and save an unencrypted DOCX copy."
        case .missingEngine: return "LibreOffice is needed to convert documents. Install it in Applications, then try again."
        case .conversionFailed: return "The document couldn’t be converted. It may be damaged or password protected. Try saving a fresh DOCX copy."
        case .invalidPDF: return "The converter did not produce a readable PDF. Your original document is unchanged."
        case .encryptionFailed: return "Password protection could not be verified. No PDF was saved."
        case .timeout: return "This conversion took longer than two minutes. Try a smaller document."
        }
    }
}

public enum Converter {
    public static var engineURL: URL? {
        ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
         NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
            .map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func validate(_ source: URL) throws {
        guard source.isFileURL, source.pathExtension.lowercased() == "docx" else { throw ConversionError.unsupported }
        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values?.isRegularFile == true, values?.isReadable == true else { throw ConversionError.unreadable }
    }

    public static func availableDestination(_ desired: URL) -> URL {
        var result = desired
        var index = 2
        while pathExists(result) {
            result = desired.deletingLastPathComponent().appendingPathComponent("\(desired.deletingPathExtension().lastPathComponent) (\(index)).pdf")
            index += 1
        }
        return result
    }

    private static func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// All file work runs off the UI actor. The caller owns queue ordering.
    public static func convert(source: URL, destination: URL, quality: PDFQuality,
                               password: String? = nil,
                               stage: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        try validate(source)
        guard let engine = engineURL else { throw ConversionError.missingEngine }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PDFMe-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let input = root.appendingPathComponent("document.docx")
        try fm.copyItem(at: source, to: input)
        let listing = root.appendingPathComponent("validation.log")
        stage("Checking document")
        let status = try await run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", input.path], log: listing)
        let entries = (try? String(contentsOf: listing, encoding: .utf8))?.components(separatedBy: .newlines) ?? []
        guard status == 0, entries.contains("[Content_Types].xml"), entries.contains("word/document.xml") else {
            throw ConversionError.invalidDocument
        }
        try Task.checkCancellation()
        // An isolated profile avoids interfering with an open LibreOffice session.
        // Disable macros and external-link updates in that profile.
        let profile = root.appendingPathComponent("profile")
        let user = profile.appendingPathComponent("user")
        try fm.createDirectory(at: user, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <oor:items xmlns:oor="http://openoffice.org/2001/registry">
        <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
        <item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>2</value></prop></item>
        </oor:items>
        """.write(to: user.appendingPathComponent("registrymodifications.xcu"), atomically: true, encoding: .utf8)
        stage("Creating PDF")
        let exit = try await run(engine, ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--nologo", "--nodefault", "--norestore", "--convert-to", quality.filter, "--outdir", root.path, input.path], log: root.appendingPathComponent("conversion.log"))
        guard exit == 0 else { throw ConversionError.conversionFailed }
        var output = root.appendingPathComponent("document.pdf")
        guard let document = PDFDocument(url: output), document.pageCount > 0, !document.isLocked else { throw ConversionError.invalidPDF }
        if let password {
            guard !password.isEmpty else { throw ConversionError.encryptionFailed }
            stage("Protecting PDF")
            let encrypted = root.appendingPathComponent("protected.pdf")
            guard document.write(to: encrypted, withOptions: [
                .userPasswordOption: password,
                .ownerPasswordOption: UUID().uuidString + UUID().uuidString
            ]), let check = PDFDocument(url: encrypted), check.isEncrypted, check.isLocked,
                  check.unlock(withPassword: password), check.pageCount == document.pageCount else { throw ConversionError.encryptionFailed }
            output = encrypted
        }
        try Task.checkCancellation()
        stage("Saving PDF")
        // Stage on the destination volume, then atomically create a link without replacing files.
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".pdfme-\(UUID().uuidString).pdf")
        try fm.copyItem(at: output, to: staged)
        defer { try? fm.removeItem(at: staged) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        try Task.checkCancellation()
        var candidate = availableDestination(destination)
        while link(staged.path, candidate.path) != 0 {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            candidate = availableDestination(destination)
        }
        return candidate
    }

    static func run(_ executable: URL, _ arguments: [String], log: URL) async throws -> Int32 {
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let start = Date()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date().timeIntervalSince(start) < 120 else { throw ConversionError.timeout }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            if process.isRunning {
                process.terminate()
                // Never leave a converter writing into a workspace after cleanup.
                for _ in 0..<10 where process.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
        return process.terminationStatus
    }
}
