import Foundation
import PDFKit

public enum PrintTransport {
    public static let preferenceKey = "directIPPPrinting"
}

extension PrintPaper {
    public var ippMedia: String {
        switch self {
        case .a4: return "iso_a4_210x297mm"
        case .letter: return "na_letter_8.5x11in"
        case .a5: return "iso_a5_148x210mm"
        case .legal: return "na_legal_8.5x14in"
        case .a3: return "iso_a3_297x420mm"
        }
    }
}

/// A bounded RFC 8010 codec. We request simple attributes, not media collections.
public struct IPPAttribute: Sendable {
    public let tag: UInt8
    public let name: String
    public let values: [Data]
    public init(tag: UInt8, name: String, values: [Data]) { self.tag = tag; self.name = name; self.values = values }
    public static func text(_ name: String, _ values: [String], tag: UInt8 = 0x44) -> Self {
        Self(tag: tag, name: name, values: values.map { Data($0.utf8) })
    }
    public static func integer(_ name: String, _ value: Int, tag: UInt8 = 0x21) -> Self {
        let number = UInt32(truncatingIfNeeded: value)
        return Self(tag: tag, name: name, values: [Data([UInt8(number >> 24), UInt8(truncatingIfNeeded: number >> 16), UInt8(truncatingIfNeeded: number >> 8), UInt8(truncatingIfNeeded: number)])])
    }
    public static func boolean(_ name: String, _ value: Bool) -> Self {
        Self(tag: 0x22, name: name, values: [Data([value ? 1 : 0])])
    }
}

public struct IPPMessage: Sendable {
    public let code: UInt16
    public let requestID: UInt32
    public let attributes: [String: IPPAttribute]
    public let unsupported: [String]
    public func strings(_ name: String) -> [String] { attributes[name]?.values.compactMap { String(data: $0, encoding: .utf8) } ?? [] }
    public func integers(_ name: String) -> [Int] {
        guard let attribute = attributes[name], [0x21, 0x23].contains(attribute.tag) else { return [] }
        return attribute.values.compactMap { value in
            guard value.count == 4 else { return nil }
            return Int(Int32(bitPattern: value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }))
        }
    }
    public func boolean(_ name: String) -> Bool? {
        guard let attribute = attributes[name], attribute.tag == 0x22,
              let value = attribute.values.first, value.count == 1, value.first == 0 || value.first == 1 else { return nil }
        return value.first == 1
    }
    public func requireSuccess() throws {
        guard code == 0, unsupported.isEmpty else {
            let detail = strings("status-message").first ?? "IPP status 0x\(String(code, radix: 16))"
            let options = unsupported.isEmpty ? "" : " Unsupported: \(unsupported.joined(separator: ", "))."
            throw PrintError.message("The printer rejected or changed the requested settings: \(detail).\(options) Nothing will be resent automatically.")
        }
    }
}

public enum IPPCodec {
    public static func encode(code: UInt16, requestID: UInt32, groups: [(UInt8, [IPPAttribute])]) throws -> Data {
        var data = Data([2, 0, UInt8(code >> 8), UInt8(truncatingIfNeeded: code)])
        data.append(contentsOf: [UInt8(requestID >> 24), UInt8(truncatingIfNeeded: requestID >> 16), UInt8(truncatingIfNeeded: requestID >> 8), UInt8(truncatingIfNeeded: requestID)])
        func field(_ bytes: Data) throws {
            guard bytes.count <= 65535 else { throw PrintError.message("IPP attribute is too long.") }
            data.append(contentsOf: [UInt8(bytes.count >> 8), UInt8(truncatingIfNeeded: bytes.count)])
            data.append(bytes)
        }
        for (group, attributes) in groups {
            data.append(group)
            for attr in attributes {
                for (index, value) in attr.values.enumerated() {
                    data.append(attr.tag)
                    try field(index == 0 ? Data(attr.name.utf8) : Data())
                    try field(value)
                }
            }
        }
        data.append(3)
        return data
    }
    public static func decode(_ data: Data, expectedID: UInt32? = nil) throws -> IPPMessage {
        func malformed() -> PrintError { .message("The printer returned an invalid IPP response.") }
        guard data.count >= 9, data.count <= 4_194_304 else { throw malformed() }
        let bytes = [UInt8](data)
        guard [1, 2].contains(bytes[0]) else { throw malformed() }
        let code = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        let id = bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if let expectedID, id != expectedID { throw malformed() }
        var offset = 8, group: UInt8 = 0, name = "", attrs: [String: IPPAttribute] = [:], unsupported: [String] = []
        func field() throws -> Data {
            guard offset + 2 <= bytes.count else { throw malformed() }
            let count = Int(bytes[offset]) * 256 + Int(bytes[offset + 1]); offset += 2
            guard offset + count <= bytes.count else { throw malformed() }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }
        while offset < bytes.count {
            let tag = bytes[offset]; offset += 1
            if tag == 3 { return IPPMessage(code: code, requestID: id, attributes: attrs, unsupported: unsupported) }
            if tag < 0x10 { group = tag; name = ""; continue }
            guard group != 0 else { throw malformed() }
            let rawName = try field(), value = try field()
            if !rawName.isEmpty {
                guard let decoded = String(data: rawName, encoding: .utf8) else { throw malformed() }
                name = decoded
            }
            guard !name.isEmpty else { throw malformed() }
            if group == 5 { if !unsupported.contains(name) { unsupported.append(name) }; continue }
            var values = rawName.isEmpty ? (attrs[name]?.values ?? []) : []
            values.append(value)
            attrs[name] = IPPAttribute(tag: tag, name: name, values: values)
        }
        throw malformed()
    }
}

/// Reject redirects and HTTP authentication. TLS uses the system trust store.
private final class IPPHTTPDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

public struct IPPClient: Sendable {
    public typealias Sender = @Sendable (URL, Data, URL?) async throws -> Data
    public let uri: URL
    private let sender: Sender
    public init(uri: URL, sender: @escaping Sender = { try await IPPClient.send(uri: $0, header: $1, file: $2) }) throws {
        _ = try Self.httpURL(uri)
        self.uri = uri; self.sender = sender
    }
    public static func httpURL(_ uri: URL) throws -> URL {
        guard var parts = URLComponents(url: uri, resolvingAgainstBaseURL: false),
              ["ipp", "ipps"].contains(parts.scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil else {
            throw PrintError.message("Direct printing needs an IPP network printer. Turn off Direct PDF printing to use macOS printing.")
        }
        parts.scheme = parts.scheme == "ipps" ? "https" : "http"
        if parts.port == nil { parts.port = 631 }
        if parts.path.isEmpty { parts.path = "/" }
        guard let result = parts.url else { throw PrintError.message("Invalid printer address.") }
        return result
    }
    public func request(_ operation: UInt16, extra: [IPPAttribute] = [], job: [IPPAttribute] = [], file: URL? = nil) async throws -> IPPMessage {
        try Task.checkCancellation()
        let id = UInt32.random(in: 1...UInt32(Int32.max))
        let base: [IPPAttribute] = [.text("attributes-charset", ["utf-8"], tag: 0x47),
            .text("attributes-natural-language", ["en"], tag: 0x48), .text("printer-uri", [uri.absoluteString], tag: 0x45)]
        // RFC 8011 §4.1.5 requires job-id to be fourth, immediately after printer-uri.
        let target = extra.filter { $0.name == "job-id" }
        let options = extra.filter { $0.name != "job-id" }
        var groups: [(UInt8, [IPPAttribute])] = [(1, base + target + [.text("requesting-user-name", [NSUserName()], tag: 0x42)] + options)]
        if !job.isEmpty { groups.append((2, job)) }
        let body = try IPPCodec.encode(code: operation, requestID: id, groups: groups)
        let response = try await sender(uri, body, file)
        return try IPPCodec.decode(response, expectedID: id)
    }
    public static func send(uri: URL, header: Data, file: URL?) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: IPPHTTPDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try httpURL(uri))
        request.httpMethod = "POST"; request.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
        request.setValue("application/ipp", forHTTPHeaderField: "Accept")
        let response: (Data, URLResponse)
        if let file {
            // Stream the PDF into a private upload file; do not load large raster jobs into RAM.
            let upload = FileManager.default.temporaryDirectory.appendingPathComponent("PDFMe-ipp-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: upload.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw PrintError.message("Couldn’t create the print upload.")
            }
            defer { try? FileManager.default.removeItem(at: upload) }
            let writer = try FileHandle(forWritingTo: upload), reader = try FileHandle(forReadingFrom: file)
            defer { try? writer.close(); try? reader.close() }
            try writer.write(contentsOf: header)
            while let chunk = try reader.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation(); try writer.write(contentsOf: chunk)
            }
            try writer.close()
            response = try await session.upload(for: request, fromFile: upload)
        } else {
            response = try await session.upload(for: request, from: header)
        }
        guard let http = response.1 as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.lowercased() == "application/ipp" else {
            throw PrintError.message("The printer didn’t return an IPP response (HTTP \((response.1 as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return response.0
    }
}

public struct DirectPrintFailure: LocalizedError {
    public let submission: PrintSubmission
    public let errorDescription: String?
    public init(submission: PrintSubmission, message: String) { self.submission = submission; errorDescription = message }
}

public enum DirectPrinterService {
    public static func jobAttributes(_ template: PrintTemplate) -> [IPPAttribute] {
        // Copies and N-up are already in the composed PDF. No vendor duplex aliases or raster back transforms.
        [.integer("copies", 1), .integer("number-up", 1), .text("media", [template.paper.ippMedia]),
         .integer("orientation-requested", template.orientation == .landscape ? 4 : 3, tag: 0x23),
         .text("sides", [template.duplex.cupsValue]), .text("print-color-mode", [template.color == .color ? "color" : "monochrome"])]
    }
    public static func check(_ client: IPPClient, template: PrintTemplate) async throws -> IPPMessage {
        try template.validate()
        let attrs = try await client.request(0x000B, extra: [.text("document-format", ["application/pdf"], tag: 0x49),
            .text("requested-attributes", ["document-format-supported", "operations-supported", "media-supported", "sides-supported",
                "print-color-mode-supported", "print-scaling-supported", "printer-is-accepting-jobs", "printer-state", "printer-state-reasons"])])
        try attrs.requireSuccess()
        guard attrs.strings("document-format-supported").contains("application/pdf"),
              [0x0004, 0x0005, 0x0006, 0x0008].allSatisfy(attrs.integers("operations-supported").contains) else {
            throw PrintError.message("This printer doesn’t support direct PDF job submission. Turn off Direct PDF printing to use macOS printing.")
        }
        guard attrs.boolean("printer-is-accepting-jobs") == true, attrs.integers("printer-state").first != 5 else {
            throw PrintError.message("The printer isn’t accepting jobs: \(attrs.strings("printer-state-reasons").joined(separator: ", ")). Check the printer before printing.")
        }
        guard attrs.strings("media-supported").contains(template.paper.ippMedia),
              attrs.strings("sides-supported").contains(template.duplex.cupsValue),
              attrs.strings("print-color-mode-supported").contains(template.color == .color ? "color" : "monochrome") else {
            throw PrintError.message("The printer doesn’t support the selected paper, duplex, or color settings for direct PDF printing. Adjust the template or turn off Direct PDF printing.")
        }
        return attrs
    }
    public static func submit(file: URL, template: PrintTemplate, printer: Printer, client: IPPClient) async throws -> PrintSubmission {
        guard let pdf = PDFDocument(url: file), !pdf.isLocked, pdf.pageCount > 0 else { throw PrintError.message("The prepared print file is unreadable.") }
        let caps = try await check(client, template: template)
        var job = jobAttributes(template)
        // Avoid a second fit/rotation by the Mac. Use native PDF coordinates where supported.
        if caps.strings("print-scaling-supported").contains("none") { job.append(.text("print-scaling", ["none"])) }
        let validated = try await client.request(0x0004, extra: [.boolean("ipp-attribute-fidelity", true),
            .text("document-format", ["application/pdf"], tag: 0x49)], job: job)
        try validated.requireSuccess()
        try Task.checkCancellation()
        let created: IPPMessage
        do {
            created = try await client.request(0x0005, extra: [.boolean("ipp-attribute-fidelity", true),
                .text("job-name", ["PDFMe \(UUID().uuidString)"], tag: 0x42)], job: job)
        } catch {
            throw PrintError.message("Couldn’t confirm job creation. No PDF was uploaded. Check the printer before trying again. \(error.localizedDescription)")
        }
        guard let number = created.integers("job-id").first, number > 0 else {
            try created.requireSuccess()
            throw PrintError.message("The printer didn’t return a job number. No PDF was uploaded; check the printer before trying again.")
        }
        let submission = PrintSubmission(jobID: String(number), printerName: printer.name, directPrinterURI: client.uri)
        do { try created.requireSuccess() }
        catch {
            try? await cancel(submission, client: client)
            throw error
        }
        // One application-level Send-Document attempt. Never switch to lp or retry an uncertain upload.
        do {
            try Task.checkCancellation()
            let sent = try await client.request(0x0006, extra: [.integer("job-id", number),
                .text("document-format", ["application/pdf"], tag: 0x49), .boolean("last-document", true)], file: file)
            try sent.requireSuccess()
            return submission
        } catch {
            throw DirectPrintFailure(submission: submission,
                message: "Job \(number): submission wasn’t confirmed. It may have printed. Check the printer or cancel this job before sending it again. \(error.localizedDescription)")
        }
    }
    public static func cancel(_ submission: PrintSubmission, client supplied: IPPClient? = nil) async throws {
        guard let uri = submission.directPrinterURI, let id = Int(submission.jobID), id > 0 else { throw PrintError.message("Invalid direct print job.") }
        let client = try supplied ?? IPPClient(uri: uri)
        let response = try await client.request(0x0008, extra: [.integer("job-id", id)])
        try response.requireSuccess()
    }
    public static func jobStatus(_ submission: PrintSubmission, client supplied: IPPClient? = nil) async throws -> String {
        guard let uri = submission.directPrinterURI, let id = Int(submission.jobID), id > 0 else { throw PrintError.message("Invalid direct print job.") }
        let client = try supplied ?? IPPClient(uri: uri)
        let response = try await client.request(0x0009, extra: [.integer("job-id", id),
            .text("requested-attributes", ["job-state", "job-state-reasons", "job-impressions-completed"])])
        try response.requireSuccess()
        let states = [3: "Queued", 4: "Held", 5: "Printing", 6: "Stopped", 7: "Cancelled", 8: "Aborted", 9: "Completed (reported by printer)"]
        guard let state = response.integers("job-state").first, let description = states[state] else { throw PrintError.message("Job status unavailable.") }
        let reasons = response.strings("job-state-reasons").filter { $0 != "none" }
        return reasons.isEmpty ? description : description + " · " + reasons.joined(separator: ", ")
    }
}

/// Resolve the selected installed printer, never a hard-coded model or a different device.
@MainActor public enum PrinterEndpointResolver {
    public static func endpoint(host: String, port: Int, type: String, resource: String) throws -> URL {
        guard !host.isEmpty, (1...65535).contains(port), ["_ipp._tcp.", "_ipps._tcp."].contains(type), !resource.isEmpty,
              let path = URLComponents(string: "/" + resource.drop(while: { $0 == "/" })), path.query == nil, path.fragment == nil else {
            throw PrintError.message("The printer didn’t advertise a valid IPP endpoint.")
        }
        var parts = URLComponents()
        parts.scheme = type == "_ipps._tcp." ? "ipps" : "ipp"
        parts.host = host.hasSuffix(".") ? String(host.dropLast()) : host
        parts.port = port; parts.percentEncodedPath = path.percentEncodedPath
        guard let uri = parts.url else { throw PrintError.message("Invalid printer endpoint.") }
        _ = try IPPClient.httpURL(uri)
        return uri
    }
    public static func serviceParts(_ uri: String) throws -> (name: String, type: String, domain: String) {
        guard uri.hasPrefix("dnssd://"), let raw = uri.dropFirst(8).split(separator: "/", maxSplits: 1).first,
              let decoded = String(raw).removingPercentEncoding else { throw PrintError.message("Invalid Bonjour printer address.") }
        for type in ["_ipps._tcp.", "_ipp._tcp."] {
            if let range = decoded.range(of: "." + type) {
                let name = String(decoded[..<range.lowerBound]), domain = String(decoded[range.upperBound...])
                guard !name.isEmpty, !domain.isEmpty else { break }
                return (name, type, domain)
            }
        }
        throw PrintError.message("Direct printing needs an IPP network printer. Turn off Direct PDF printing to use macOS printing.")
    }
    public static func resolve(printerID: String) async throws -> URL {
        let result = try await PrintCommand.run("/usr/bin/lpstat", ["-v", printerID])
        let prefix = "device for \(printerID): "
        guard result.status == 0, let line = result.output.components(separatedBy: .newlines).first(where: { $0.hasPrefix(prefix) }) else {
            throw PrintError.message("Couldn’t read the selected printer’s network address.")
        }
        let address = String(line.dropFirst(prefix.count))
        if let url = URL(string: address), ["ipp", "ipps"].contains(url.scheme) {
            // Queue URI query parameters configure the Mac backend, not the printer resource.
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.query = nil
            let endpoint = parts.url!; _ = try IPPClient.httpURL(endpoint); return endpoint
        }
        let parts = try serviceParts(address)
        let resolver = BonjourPrinterResolver(name: parts.name, type: parts.type, domain: parts.domain)
        return try await resolver.resolve()
    }
}

@MainActor private final class BonjourPrinterResolver: NSObject, @preconcurrency NetServiceDelegate {
    private let service: NetService
    private var continuation: CheckedContinuation<URL, Error>?
    private var timer: Task<Void, Never>?
    init(name: String, type: String, domain: String) { service = NetService(domain: domain, type: type, name: name); super.init() }
    func resolve() async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                service.delegate = self; service.schedule(in: .main, forMode: .common); service.resolve(withTimeout: 8)
                timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 9_000_000_000) } catch { return }
                    self?.finish(.failure(PrintError.message("Printer unavailable. Connect to its network or turn off Direct PDF printing to use macOS printing.")))
                }
            }
        }, onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } })
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, let txt = sender.txtRecordData(),
              let resource = NetService.dictionary(fromTXTRecord: txt).first(where: { $0.key.lowercased() == "rp" }).flatMap({ String(data: $0.value, encoding: .utf8) }),
              !resource.isEmpty, sender.port > 0 else {
            finish(.failure(PrintError.message("The printer didn’t advertise an IPP PDF endpoint."))); return
        }
        do { finish(.success(try PrinterEndpointResolver.endpoint(host: host, port: sender.port, type: sender.type, resource: resource))) }
        catch { finish(.failure(error)) }
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(.failure(PrintError.message("Printer unavailable. Connect to its network or turn off Direct PDF printing to use macOS printing.")))
    }
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timer?.cancel(); service.stop(); service.remove(from: .main, forMode: .common); service.delegate = nil
        continuation.resume(with: result)
    }
}
