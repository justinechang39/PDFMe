import Foundation
import PDFKit
import Darwin

public struct Printer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    public init(id: String, name: String, isDefault: Bool = false) { self.id = id; self.name = name; self.isDefault = isDefault }
}
public struct PrinterCapabilities: Sendable {
    public let options: [String: [String]]
    public init(output: String) {
        var parsed: [String: [String]] = [:]
        for line in output.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            parsed[key] = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).map { $0.replacingOccurrences(of: "*", with: "") }
        }
        options = parsed
    }
    public var papers: [PrintPaper] { PrintPaper.allCases.filter { options["PageSize", default: []].contains($0.rawValue) } }
    public var supportsDuplex: Bool { options["Duplex", default: []].contains("DuplexNoTumble") && options["Duplex", default: []].contains("DuplexTumble") }
    public var grayscaleValue: String? { ["Gray", "DeviceGray", "Grayscale", "K"].first { options["ColorModel", default: []].contains($0) } }
    public var colorValue: String? { ["RGB", "DeviceRGB", "CMYK", "Color"].first { options["ColorModel", default: []].contains($0) } }
    public func validate(_ template: PrintTemplate) throws {
        try template.validate()
        guard papers.contains(template.paper) else { throw PrintError.message("This printer doesn’t report support for \(template.paper.rawValue). Choose a supported paper size.") }
        if template.duplex != .off && !options["Duplex", default: []].contains(template.duplex.driverValue) {
            throw PrintError.message("This printer doesn’t report support for the selected duplex mode.")
        }
        if template.color == .color && colorValue == nil { throw PrintError.message("This printer doesn’t report color support. Choose Black & white.") }
        if template.color == .grayscale && grayscaleValue == nil { throw PrintError.message("This printer doesn’t report a grayscale mode.") }
    }
}

public struct PrintSubmission: Sendable {
    public let jobID: String
    public let printerName: String
}

/// State of this Mac's queue, not a claim that the physical printer is ready.
public struct PrinterQueueStatus: Equatable, Sendable {
    public let isPaused: Bool
    public let reason: String?

    public init(output: String, printerID: String) throws {
        let lines = output.components(separatedBy: .newlines)
        guard let first = lines.first, first.hasPrefix("printer \(printerID) ") else {
            throw PrintError.message("Couldn’t read the printer queue. Open Printers & queues to check it.")
        }
        let state = first.dropFirst("printer \(printerID) ".count)
        if state.hasPrefix("disabled ") { isPaused = true }
        else if state.hasPrefix("is idle."), state.contains("enabled since") { isPaused = false }
        else if state.hasPrefix("now printing "), state.contains("enabled since") { isPaused = false }
        else { throw PrintError.message("Couldn’t read the printer queue. Open Printers & queues to check it.") }
        // lpstat puts the pause explanation immediately below the header, before labeled fields.
        let detail = lines.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        reason = isPaused && !detail.isEmpty && !detail.contains(":") ? detail : nil
    }
}

public enum PrinterQueueService {
    public typealias Runner = @Sendable (String, [String]) async throws -> PrintCommand.Result
    public static func status(for id: String, run: Runner = { try await PrintCommand.run($0, $1) }) async throws -> PrinterQueueStatus {
        let result = try await run("/usr/bin/lpstat", ["-l", "-p", id])
        guard result.status == 0 else { throw PrintError.message("Couldn’t read the printer queue. Open Printers & queues to check it.") }
        return try PrinterQueueStatus(output: result.output, printerID: id)
    }

    /// Only call after explicit confirmation that existing queued jobs may print.
    /// Does not resubmit documents, release held jobs, or change the error policy.
    public static func resume(_ id: String, run: Runner = { try await PrintCommand.run($0, $1) }) async throws -> PrinterQueueStatus {
        let current = try await status(for: id, run: run)
        guard current.isPaused else { return current }
        try Task.checkCancellation()
        let result = try await run("/usr/sbin/cupsenable", [id])
        guard result.status == 0 else {
            throw PrintError.message("macOS couldn’t resume this printer. Open Printers & queues to resume it or check permissions.")
        }
        let updated = try await status(for: id, run: run)
        guard !updated.isPaused else {
            throw PrintError.message("The queue is still paused. Check the printer and Printers & queues before trying again.")
        }
        return updated
    }
}

public enum PrinterService {
    public static func list() async throws -> [Printer] {
        let status = try await PrintCommand.run("/usr/bin/lpstat", ["-l", "-p"])
        guard status.status == 0 else { throw PrintError.message("No printers found. Add your printer in System Settings → Printers & Scanners.") }
        let defaultOutput = try await PrintCommand.run("/usr/bin/lpstat", ["-d"])
        let defaultID = defaultOutput.output.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespacesAndNewlines)
        return parsePrinters(status.output, defaultID: defaultID)
    }
    public static func parsePrinters(_ text: String, defaultID: String?) -> [Printer] {
        var entries: [(String, String)] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("printer "), let id = line.split(separator: " ").dropFirst().first { entries.append((String(id), String(id).replacingOccurrences(of: "_", with: " "))) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Description:"), !entries.isEmpty {
                let name = trimmed.dropFirst("Description:".count).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { entries[entries.count - 1].1 = name }
            }
        }
        return entries.map { Printer(id: $0.0, name: $0.1, isDefault: $0.0 == defaultID) }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    public static func capabilities(for printerID: String) async throws -> PrinterCapabilities {
        let result = try await PrintCommand.run("/usr/bin/lpoptions", ["-p", printerID, "-l"])
        let capabilities = PrinterCapabilities(output: result.output)
        guard result.status == 0, !capabilities.papers.isEmpty else { throw PrintError.message("Couldn’t read this printer’s paper and duplex options. Check its setup in Printers & Scanners, then refresh.") }
        return capabilities
    }

    public static func arguments(file: URL, template: PrintTemplate, copies: Int, capabilities: PrinterCapabilities) throws -> [String] {
        try capabilities.validate(template)
        guard !template.printerID.isEmpty, (1...999).contains(copies) else { throw PrintError.message("Choose a printer and between 1 and 999 copies.") }
        var args = ["-d", template.printerID, "-t", "PDFMe print job", "-n", String(copies)]
        let color = template.color == .grayscale ? capabilities.grayscaleValue! : capabilities.colorValue!
        // Layout is already imposed in the prepared PDF. Never ask the driver to apply N-up again.
        let options = ["media=\(template.paper.rawValue)", "PageSize=\(template.paper.rawValue)",
                       "sides=\(template.duplex.cupsValue)", "Duplex=\(template.duplex.driverValue)",
                       "Collate=True", "multiple-document-handling=separate-documents-collated-copies",
                       "number-up=1", "orientation-requested=\(template.orientation == .landscape ? 4 : 3)",
                       "print-scaling=fit", "fit-to-page", "outputorder=normal", "page-set=all",
                       "job-sheets=none,none", "job-hold-until=no-hold", "mirror=false",
                       "ColorModel=\(color)", "print-color-mode=\(template.color == .grayscale ? "monochrome" : "color")"]
        for option in options { args += ["-o", option] }
        args += ["--", file.path]
        return args
    }

    /// The only method that submits a new document. Call solely from an explicit Print action.
    public static func submit(file: URL, template: PrintTemplate, copies: Int) async throws -> PrintSubmission {
        let printers = try await list()
        guard let printer = printers.first(where: { $0.id == template.printerID }) else { throw PrintError.message("The template’s printer is no longer installed. Select another printer.") }
        let caps = try await capabilities(for: printer.id)
        try Task.checkCancellation()
        guard let prepared = PDFDocument(url: file), !prepared.isLocked, prepared.pageCount > 0 else {
            throw PrintError.message("The prepared print file is missing or unreadable. Prepare it again.")
        }
        var arguments = try arguments(file: file, template: template, copies: copies, capabilities: caps)
        arguments.insert(contentsOf: ["-o", "page-ranges=1-\(prepared.pageCount)"], at: 0)
        let queue = try await PrinterQueueService.status(for: printer.id)
        guard !queue.isPaused else { throw PrintError.message("The printer queue is paused. Resume it before printing. Nothing was sent.") }
        let result = try await PrintCommand.run("/usr/bin/lp", arguments)
        guard result.status == 0 else { throw PrintError.message("The printer didn’t accept this job. \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        guard let job = parseJobID(result.output, printerID: printer.id) else {
            // Do not retry: the spooler may have accepted the job even when its reply is unexpected.
            throw PrintError.message("The print system accepted the request but didn’t return a job number. Check the queue before trying again to avoid duplicate copies.")
        }
        return PrintSubmission(jobID: job, printerName: printer.name)
    }
    public static func parseJobID(_ text: String, printerID: String) -> String? {
        text.split(whereSeparator: \.isWhitespace).map(String.init).first {
            guard $0.hasPrefix(printerID + "-") else { return false }
            let suffix = $0.dropFirst(printerID.count + 1)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
    }
    public static func cancel(jobID: String) async throws {
        let result = try await PrintCommand.run("/usr/bin/cancel", [jobID])
        guard result.status == 0 else { throw PrintError.message("Couldn’t cancel this job. It may already have printed. Check the system print queue.") }
    }
}

public enum PrintCommand {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public init(status: Int32, output: String) { self.status = status; self.output = output }
    }
    /// Reads and spooling run asynchronously. No shell interpolation or printer preference mutations.
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) async throws -> Result {
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PDFMe-command-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PrintError.message("Couldn’t create a temporary print log.") }
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["LANG"] = "C"
        process.environment = environment
        process.standardOutput = handle; process.standardError = handle; process.standardInput = FileHandle.nullDevice
        try process.run()
        let started = Date()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if Date().timeIntervalSince(started) > timeout { throw PrintError.message("The print system took too long to respond. Check the queue before retrying; a submitted job may still print.") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            throw error
        }
        let output = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Result(status: process.terminationStatus, output: output)
    }
}
