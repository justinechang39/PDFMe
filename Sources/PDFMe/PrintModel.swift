import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import PDFMeCore

@MainActor
final class PrintModel: ObservableObject {
    @Published var inputs: [PrintInput] = []
    @Published var printers: [Printer] = []
    @Published var capabilities: PrinterCapabilities?
    @Published var templates: [PrintTemplate]
    @Published var template: PrintTemplate {
        didSet { if oldValue.printerID != template.printerID { loadCapabilities() } }
    }
    @Published var selectedTemplateID: UUID?
    @Published var defaultTemplateID: UUID?
    @Published var busy = false
    @Published var submitting = false
    @Published var loadingPrinters = false
    @Published var loadingCapabilities = false
    @Published var progress = 0.0
    @Published var stage = ""
    @Published var message: String?
    @Published var isError = false
    @Published var submission: PrintSubmission?
    @Published var showTemplateEditor = false
    var show: (() -> Void)?
    var operation: Task<Void, Never>?
    private var preparation: Task<PrintPlan, Error>?
    private var inspection: Task<[PrintInput], Error>?
    private var capabilityTask: Task<Void, Never>?
    private var workspaces: [URL] = []

    init() {
        let saved = UserDefaults.standard.data(forKey: "printTemplates.v1")
        let templates = saved.flatMap { try? JSONDecoder().decode([PrintTemplate].self, from: $0) } ?? []
        let defaultID = UserDefaults.standard.string(forKey: "defaultPrintTemplate").flatMap(UUID.init(uuidString:))
        let selected = templates.first { $0.id == defaultID } ?? templates.first
        self.templates = templates
        self.defaultTemplateID = defaultID
        self.selectedTemplateID = selected?.id
        self.template = selected ?? PrintTemplate(name: "Default")
        if saved != nil && templates.isEmpty { message = "Saved templates couldn’t be read. Create and save a new template."; isError = true }
    }

    var plan: PrintPlan? { try? PrintPlan(pageCounts: inputs.map(\.pages), template: template, copies: inputs.map(\.copies)) }
    var validationMessage: String? {
        guard printers.contains(where: { $0.id == template.printerID }) else { return "Select an installed printer." }
        guard let capabilities else { return loadingCapabilities ? "Reading printer options…" : "Refresh the printer options before printing." }
        do { try capabilities.validate(template) } catch { return error.localizedDescription }
        return nil
    }
    var changed: Bool { templates.first(where: { $0.id == selectedTemplateID }) != template }
    var canPrint: Bool { !busy && !loadingPrinters && !loadingCapabilities && !inputs.isEmpty && validationMessage == nil }

    func refreshPrinters() {
        guard !loadingPrinters else { return }
        loadingPrinters = true
        Task {
            defer { loadingPrinters = false }
            do {
                printers = try await PrinterService.list()
                if templates.isEmpty, let printer = printers.first {
                    let caps = try await PrinterService.capabilities(for: printer.id)
                    let paper: PrintPaper = caps.papers.contains(.a4) ? .a4 : (caps.papers.first ?? .a4)
                    let basic = PrintTemplate(name: "Default", printerID: printer.id, paper: paper, color: caps.colorValue == nil ? .grayscale : .color)
                    templates = [basic]
                    if caps.supportsDuplex && caps.papers.contains(.a4) {
                        templates.append(PrintTemplate(name: "A4 · 2-up duplex", printerID: printer.id, orientation: .landscape,
                                                       duplex: .shortEdge, pagesPerSide: 2, printAsImage: true, color: caps.colorValue == nil ? .grayscale : .color))
                    }
                    template = basic; selectedTemplateID = basic.id; defaultTemplateID = basic.id
                    persist()
                }
                loadCapabilities()
            } catch { inform(error.localizedDescription, error: true) }
        }
    }
    func loadCapabilities() {
        capabilityTask?.cancel()
        capabilities = nil
        guard !template.printerID.isEmpty else { loadingCapabilities = false; return }
        loadingCapabilities = true
        let id = template.printerID
        capabilityTask = Task {
            do {
                let caps = try await PrinterService.capabilities(for: id)
                guard !Task.isCancelled, template.printerID == id else { return }
                capabilities = caps; loadingCapabilities = false
            } catch {
                guard !Task.isCancelled, template.printerID == id else { return }
                loadingCapabilities = false
                inform(error.localizedDescription, error: true)
            }
        }
    }
    func selectTemplate(_ id: UUID) {
        guard let chosen = templates.first(where: { $0.id == id }) else { return }
        selectedTemplateID = id; template = chosen
        message = nil
    }
    func saveTemplate(asNew: Bool) {
        let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { inform("Enter a template name.", error: true); return }
        if let problem = validationMessage { inform(problem, error: true); return }
        template.name = name
        if asNew || selectedTemplateID == nil {
            template.id = UUID(); templates.append(template); selectedTemplateID = template.id
        } else if let index = templates.firstIndex(where: { $0.id == selectedTemplateID }) { templates[index] = template }
        persist()
        inform("Template saved")
    }
    func makeDefault() {
        guard !changed, let selectedTemplateID else { inform("Save the template first.", error: true); return }
        defaultTemplateID = selectedTemplateID; persist(); inform("Default template updated")
    }
    func deleteTemplate() {
        guard let selectedTemplateID else { return }
        templates.removeAll { $0.id == selectedTemplateID }
        if defaultTemplateID == selectedTemplateID { defaultTemplateID = templates.first?.id }
        if let next = templates.first { selectTemplate(next.id) }
        else { self.selectedTemplateID = nil; template = PrintTemplate(printerID: printers.first?.id ?? ""); showTemplateEditor = true }
        persist()
        inform("Template deleted")
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(templates) { UserDefaults.standard.set(data, forKey: "printTemplates.v1") }
        UserDefaults.standard.set(defaultTemplateID?.uuidString, forKey: "defaultPrintTemplate")
    }

    func chooseFiles() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.prompt = "Add PDFs"; panel.message = "Review files and print settings before printing."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { accept(panel.urls) }
    }
    func accept(_ urls: [URL]) {
        show?()
        guard !busy else { inform("Wait for the current print operation to finish.", error: true); return }
        busy = true; progress = 0; stage = "Checking PDFs"
        operation = Task {
            defer { busy = false; operation = nil; inspection = nil }
            let scan = Task.detached(priority: .userInitiated) { try PrintComposer.inspect(urls) }
            inspection = scan
            do {
                let newInputs = try await scan.value
                guard !Task.isCancelled else { return }
                inputs.append(contentsOf: newInputs)
                submission = nil; message = nil
                if printers.isEmpty { refreshPrinters() }
            } catch is CancellationError { inform("Cancelled") }
            catch { inform(error.localizedDescription, error: true) }
        }
    }
    func move(_ index: Int, by offset: Int) {
        guard !busy, inputs.indices.contains(index), inputs.indices.contains(index + offset) else { return }
        inputs.swapAt(index, index + offset)
    }
    func move(_ id: UUID, to target: UUID) {
        guard !busy, id != target, let source = inputs.firstIndex(where: { $0.id == id }),
              let destination = inputs.firstIndex(where: { $0.id == target }) else { return }
        let input = inputs.remove(at: source)
        inputs.insert(input, at: destination)
    }
    func setCopies(_ count: Int, for id: UUID) {
        guard !busy, let index = inputs.firstIndex(where: { $0.id == id }) else { return }
        inputs[index].copies = min(999, max(1, count))
    }
    func remove(_ id: UUID) { if !busy { inputs.removeAll { $0.id == id } } }
    func clear() { guard !busy else { return }; inputs = []; message = nil; submission = nil; cleanup() }
    func inform(_ text: String, error: Bool = false) { isError = error; message = text }

    func prepare(previewOnly: Bool) {
        guard canPrint else { inform(validationMessage ?? "Add PDF files first.", error: true); return }
        let urls = inputs.map(\.url), snapshot = template, counts = inputs.map(\.copies)
        busy = true; submitting = false; progress = 0; stage = "Preparing print layout"; message = nil
        operation = Task {
            defer { busy = false; submitting = false; operation = nil; preparation = nil }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFMe-print-\(UUID().uuidString)", isDirectory: true)
            var keepPreview = false
            defer { if !keepPreview { try? FileManager.default.removeItem(at: root) } }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let output = root.appendingPathComponent("Print layout.pdf")
                let worker = Task.detached(priority: .userInitiated) {
                    try PrintComposer.prepare(urls: urls, template: snapshot, output: output, copies: counts) { current, total in
                        Task { @MainActor in
                            guard self.busy && !self.submitting else { return }
                            self.progress = Double(current) / Double(total)
                            self.stage = "Preparing side \(current) of \(total)"
                        }
                    }
                }
                preparation = worker
                _ = try await worker.value
                try Task.checkCancellation()
                if previewOnly {
                    guard let previewApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                        throw PrintError.message("Preview is unavailable on this Mac.")
                    }
                    let configuration = NSWorkspace.OpenConfiguration()
                    _ = try await NSWorkspace.shared.open([output], withApplicationAt: previewApp, configuration: configuration)
                    workspaces.append(root); keepPreview = true
                    inform("Preview opened. Nothing has been sent to the printer.")
                } else {
                    submitting = true; stage = "Sending to printer"
                    let accepted = try await PrinterService.submit(file: output, template: snapshot, copies: 1)
                    submission = accepted
                    inform("Sent to \(accepted.printerName)")
                    notify(accepted.printerName)
                }
            } catch is CancellationError { inform("Print preparation cancelled. Nothing was sent.") }
            catch { inform(error.localizedDescription, error: true) }
        }
    }
    func cancelPreparation() {
        guard !submitting else { return }
        preparation?.cancel(); inspection?.cancel(); operation?.cancel()
    }
    func cancelSubmittedJob() {
        guard let submission, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await PrinterService.cancel(jobID: submission.jobID)
                self.submission = nil
                inform("Cancellation requested. Sheets already printed cannot be recalled.")
            } catch { inform(error.localizedDescription, error: true) }
        }
    }
    func cleanup() {
        for root in workspaces { try? FileManager.default.removeItem(at: root) }
        workspaces.removeAll()
    }
    func openPrintSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.printfax")!)
    }
    private func notify(_ printer: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Print job submitted"; content.body = printer; content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
