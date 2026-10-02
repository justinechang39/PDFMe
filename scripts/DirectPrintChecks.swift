import Foundation
import PDFKit
import PDFMeCore

actor FakeIPPPrinter {
    let mode: String
    var operations: [UInt16] = []
    var uploaded = false
    init(_ mode: String = "ok") { self.mode = mode }
    func send(_ uri: URL, _ body: Data, _ file: URL?) throws -> Data {
        let request = try IPPCodec.decode(body)
        operations.append(request.code)
        var code: UInt16 = 0, attributes: [IPPAttribute] = [], unsupported: [IPPAttribute] = []
        switch request.code {
        case 0xB:
            precondition(file == nil && request.strings("document-format") == ["application/pdf"])
            attributes = [.text("document-format-supported", [mode == "noPDF" ? "image/urf" : "application/pdf"]),
                .init(tag: 0x23, name: "operations-supported", values: [4, 5, 6, 8, 9].filter { mode != "noCreate" || $0 != 5 }.map { IPPAttribute.integer("", $0).values[0] }),
                .text("media-supported", PrintPaper.allCases.map(\.ippMedia)),
                .text("sides-supported", PrintDuplex.allCases.map(\.cupsValue)),
                .text("print-color-mode-supported", ["color", "monochrome"]), .text("print-scaling-supported", ["none", "fit"]),
                .boolean("printer-is-accepting-jobs", mode != "notAccepting"),
                .integer("printer-state", mode == "stopped" ? 5 : 3, tag: 0x23)]
        case 4, 5:
            precondition(file == nil)
            precondition(request.boolean("ipp-attribute-fidelity") == true)
            precondition(request.integers("copies") == [1] && request.integers("number-up") == [1])
            precondition(request.strings("print-scaling") == ["none"])
            precondition(request.strings("sides").count == 1 && request.strings("media").count == 1)
            precondition(request.attributes["Duplex"] == nil && request.attributes["fit-to-page"] == nil)
            if request.code == 4 && mode == "rejected" { code = 0x040B; unsupported = [.text("sides", ["invalid"])] }
            if request.code == 4 && mode == "substituted" { code = 1 }
            if request.code == 5 {
                precondition(request.strings("job-name").first!.hasPrefix("PDFMe "))
                precondition(request.attributes["document-format"] == nil)
                if mode != "noID" { attributes = [.integer("job-id", 42)] }
                if mode == "createSubstitution" { code = 1 }
            }
        case 6:
            precondition(request.integers("job-id") == [42])
            precondition(request.boolean("last-document") == true && request.strings("document-format") == ["application/pdf"])
            precondition(file != nil && (try! Data(contentsOf: file!)).starts(with: Data("%PDF".utf8)))
            uploaded = true
            if mode == "lostUploadReply" { throw URLError(.networkConnectionLost) }
            if mode == "uploadRejected" { code = 0x0411 }
        case 8:
            precondition(file == nil && request.integers("job-id") == [42])
        case 9:
            precondition(file == nil && request.integers("job-id") == [42])
            if mode == "missingHistory" { code = 0x0406 }
            else { attributes = [.integer("job-state", 9, tag: 0x23), .text("job-state-reasons", ["none"])] }
        default: fatalError("Unexpected operation: \(request.code)")
        }
        return try IPPCodec.encode(code: code, requestID: request.requestID, groups: [(1, []), (request.code == 11 ? 4 : 2, attributes), (5, unsupported)])
    }
    func check(_ expected: [UInt16], uploaded expectedUpload: Bool) {
        precondition(operations == expected && uploaded == expectedUpload, "Unexpected requests: \(operations)")
    }
}

@main struct DirectPrintChecks {
    static func require(_ condition: Bool, _ message: String) { precondition(condition, message); print("PASS: " + message) }
    @MainActor static func main() async throws {
        if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--wire" {
            let endpoint = URL(string: CommandLine.arguments[2])!, file = URL(fileURLWithPath: CommandLine.arguments[3])
            let client = try IPPClient(uri: endpoint)
            let template = PrintTemplate(printerID: "Simulated", duplex: .longEdge)
            if endpoint.path == "/redirect" {
                do { _ = try await DirectPrinterService.check(client, template: template); fatalError("Redirect followed") }
                catch { print("PASS: HTTP redirects are rejected") }
            } else if endpoint.path == "/lost-reply" {
                do { _ = try await DirectPrinterService.submit(file: file, template: template, printer: Printer(id: "Simulated", name: "Simulated"), client: client); fatalError("Lost reply accepted") }
                catch let failure as DirectPrintFailure { require(failure.submission.jobID == "42", "Disconnected HTTP upload retains job ID") }
            } else {
                let result = try await DirectPrinterService.submit(file: file, template: template, printer: Printer(id: "Simulated", name: "Simulated"), client: client)
                require(result.jobID == "42", "Real HTTP transport accepts a streamed PDF")
                _ = try await DirectPrinterService.jobStatus(result, client: client)
                try await DirectPrinterService.cancel(result, client: client)
            }
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), file = root.appendingPathComponent("01 Sample A.pdf")
        let uri = URL(string: "ipp://test.local:631/custom/resource")!
        let template = PrintTemplate(printerID: "Test", duplex: .longEdge)
        let printer = Printer(id: "Test", name: "Test Printer")
        let encoded = try IPPCodec.encode(code: 0xB, requestID: 0x12345678, groups: [(1, [.text("a", ["b", "c"])])])
        require(Array(encoded) == [2,0,0,11,18,52,86,120,1,68,0,1,97,0,1,98,68,0,0,0,1,99,3], "RFC binary encoding and repeated values match independent golden bytes")
        let decoded = try IPPCodec.decode(encoded, expectedID: 0x12345678)
        require(decoded.strings("a") == ["b", "c"], "IPP repeated values decode")
        for count in 0..<encoded.count {
            do { _ = try IPPCodec.decode(encoded.prefix(count)); fatalError("Truncated IPP accepted") } catch {}
        }
        do { _ = try IPPCodec.decode(encoded, expectedID: 7); fatalError("Wrong request ID accepted") } catch {}
        print("PASS: Truncated and mismatched responses fail safely")
        require(try IPPClient.httpURL(uri).absoluteString == "http://test.local:631/custom/resource", "IPP maps to HTTP without changing resource")
        require(try IPPClient.httpURL(URL(string: "ipps://test.local/print")!).absoluteString == "https://test.local:631/print", "IPPS uses TLS")
        for invalid in ["file:///tmp/a", "socket://test:9100", "ipp://user:pass@test/print", "ipp://test/print#bad"] {
            do { _ = try IPPClient(uri: URL(string: invalid)!); fatalError("Invalid endpoint accepted") } catch {}
        }
        let parts = try PrinterEndpointResolver.serviceParts("dnssd://Example%20Printer%20%5B123%5D._ipp._tcp.local./?uuid=123")
        require(parts.name == "Example Printer [123]" && parts.type == "_ipp._tcp." && parts.domain == "local.", "Bonjour URI preserves selected printer and domain")
        let secure = try PrinterEndpointResolver.serviceParts("dnssd://Example._ipps._tcp.local./")
        require(secure.type == "_ipps._tcp.", "Secure Bonjour service remains secure")
        let resolved = try PrinterEndpointResolver.endpoint(host: "printer.local.", port: 8631, type: "_ipps._tcp.", resource: "/custom/My%20Printer/")
        require(resolved.absoluteString == "ipps://printer.local:8631/custom/My%20Printer/", "Advertised host, port, security, escaped resource and trailing slash are preserved")
        for orientation in PrintOrientation.allCases {
            for duplex in PrintDuplex.allCases {
                let fake = FakeIPPPrinter(), client = try IPPClient(uri: uri, sender: { try await fake.send($0, $1, $2) })
                var options = template; options.orientation = orientation; options.duplex = duplex; options.pagesPerSide = 2
                let attrs = try IPPCodec.decode(IPPCodec.encode(code: 5, requestID: 1, groups: [(2, DirectPrinterService.jobAttributes(options))]))
                require(attrs.strings("sides") == [duplex.cupsValue] && attrs.integers("orientation-requested") == [orientation == .portrait ? 3 : 4], "\(orientation) / \(duplex) sends the exact edge and orientation")
                let result = try await DirectPrinterService.submit(file: file, template: options, printer: printer, client: client)
                require(result.jobID == "42" && result.directPrinterURI == uri, "Job retains its direct endpoint")
                require(try await DirectPrinterService.jobStatus(result, client: client) == "Completed (reported by printer)", "Job status comes from the printer")
                try await DirectPrinterService.cancel(result, client: client)
                await fake.check([11,4,5,6,9,8], uploaded: true)
            }
        }
        for (mode, operations) in [("noPDF", [11]), ("noCreate", [11]), ("notAccepting", [11]), ("stopped", [11]),
                                  ("rejected", [11,4]), ("substituted", [11,4]), ("noID", [11,4,5]), ("createSubstitution", [11,4,5,8])] {
            let fake = FakeIPPPrinter(mode), client = try IPPClient(uri: uri, sender: { try await fake.send($0, $1, $2) })
            do { _ = try await DirectPrinterService.submit(file: file, template: template, printer: printer, client: client); fatalError("\(mode) accepted") }
            catch { print("PASS: \(mode) blocks PDF upload") }
            await fake.check(operations.map(UInt16.init), uploaded: false)
        }
        for mode in ["lostUploadReply", "uploadRejected"] {
            let fake = FakeIPPPrinter(mode), client = try IPPClient(uri: uri, sender: { try await fake.send($0, $1, $2) })
            do { _ = try await DirectPrinterService.submit(file: file, template: template, printer: printer, client: client); fatalError("Unconfirmed upload accepted") }
            catch let failure as DirectPrintFailure {
                require(failure.submission.jobID == "42" && failure.submission.directPrinterURI == uri, "\(mode) retains cancellation reference")
            }
            await fake.check([11,4,5,6], uploaded: true)
            print("PASS: No retry or macOS fallback after \(mode)")
        }
        let missing = FakeIPPPrinter("missingHistory"), missingClient = try IPPClient(uri: uri, sender: { try await missing.send($0, $1, $2) })
        do { _ = try await DirectPrinterService.jobStatus(PrintSubmission(jobID: "42", printerName: "Test", directPrinterURI: uri), client: missingClient); fatalError("Missing history means completed") }
        catch { print("PASS: Missing history does not imply completion") }
        print("Direct printing checks passed. All printer operations were simulated.")
    }
}
