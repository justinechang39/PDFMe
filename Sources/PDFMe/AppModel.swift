import AppKit
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers
import PDFMeCore

struct ConversionJob: Identifiable {
    let id = UUID()
    let source: URL
    var state = "Waiting"
    var output: URL?
    var failed = false
    var finished = false
}

@MainActor
final class AppModel: ObservableObject {
    @Published var quality: PDFQuality = PDFQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .balanced {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    @Published var askEveryTime = UserDefaults.standard.bool(forKey: "askEveryTime") {
        didSet { UserDefaults.standard.set(askEveryTime, forKey: "askEveryTime") }
    }
    @Published var protect = UserDefaults.standard.bool(forKey: "protect") {
        didSet { UserDefaults.standard.set(protect, forKey: "protect") }
    }
    @Published var jobs: [ConversionJob] = []
    @Published var busy = false
    @Published var message: String?
    @Published var messageIsError = false
    @Published var engineReady = Converter.engineURL != nil
    @Published var settings = false
    @Published var printingMode = false
    let printing = PrintModel()
    var task: Task<Void, Never>?
    var worker: Task<URL, Error>?
    var show: (() -> Void)?
    var progressChanged: ((Bool) -> Void)?

    func route(_ urls: [URL]) {
        if !urls.isEmpty && urls.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) {
            openPrint(); printing.accept(urls)
        } else if !urls.isEmpty && urls.allSatisfy({ $0.pathExtension.lowercased() == "docx" }) {
            printingMode = false; settings = false; accept(urls)
        } else {
            printingMode = false; settings = false; show?()
            inform("Drop DOCX files to create PDFs, or PDF files to print. Keep the two file types in separate batches.", error: true)
        }
    }
    func openPrint() { printingMode = true; settings = false; show?() }

    func refreshEngine() { engineReady = Converter.engineURL != nil }
    func chooseFiles() {
        guard !busy else { inform("A batch is already running. You can add more files when it finishes."); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx")!]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Create PDF"
        panel.message = "Choose Word documents to turn into PDFs."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { accept(panel.urls) }
    }

    func accept(_ urls: [URL]) {
        show?()
        guard !busy else { inform("A batch is already running. Drop your next files when it finishes.", error: true); return }
        guard !urls.isEmpty else { inform("Drop a DOCX file from Finder.", error: true); return }
        do { for url in urls { try Converter.validate(url) } }
        catch { inform(error.localizedDescription, error: true); return }
        refreshEngine()
        guard engineReady else { inform(ConversionError.missingEngine.localizedDescription, error: true); return }
        var password: String?
        if protect {
            guard let entered = requestPassword() else { return }
            password = entered
        }
        let selectedQuality = quality
        let ask = askEveryTime
        jobs = urls.map { ConversionJob(source: $0) }
        message = nil
        busy = true
        progressChanged?(true)
        task = Task {
            var completed = 0
            var failures = 0
            defer { busy = false; worker = nil; task = nil; progressChanged?(false) }
            for index in jobs.indices {
                if Task.isCancelled { break }
                let source = jobs[index].source
                var destination = source.deletingPathExtension().appendingPathExtension("pdf")
                if ask {
                    jobs[index].state = "Choose a destination"
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.pdf]
                    panel.nameFieldStringValue = Converter.availableDestination(destination).lastPathComponent
                    panel.directoryURL = source.deletingLastPathComponent()
                    panel.prompt = "Save PDF"
                    panel.message = "Save \(source.lastPathComponent) as PDF. Existing files are kept with a numbered filename."
                    NSApp.activate(ignoringOtherApps: true)
                    guard panel.runModal() == .OK, let selected = panel.url else {
                        jobs[index].state = "Skipped"; jobs[index].finished = true; continue
                    }
                    destination = selected
                }
                let chosenDestination = destination
                let chosenPassword = password
                let operation = Task.detached(priority: .userInitiated) {
                    try await Converter.convert(source: source, destination: chosenDestination, quality: selectedQuality, password: chosenPassword) { stage in
                        Task { @MainActor in
                            if self.jobs.indices.contains(index), !self.jobs[index].finished { self.jobs[index].state = stage }
                        }
                    }
                }
                worker = operation
                do {
                    let output = try await operation.value
                    jobs[index].output = output
                    jobs[index].state = "Ready · " + Self.fileSize(output)
                    jobs[index].finished = true
                    completed += 1
                } catch is CancellationError {
                    jobs[index].state = "Cancelled"; jobs[index].finished = true
                } catch {
                    jobs[index].state = error.localizedDescription
                    jobs[index].failed = true; jobs[index].finished = true
                    failures += 1
                }
            }
            for index in jobs.indices where !jobs[index].finished {
                jobs[index].state = "Cancelled"; jobs[index].finished = true
            }
            if Task.isCancelled { inform("Conversion cancelled. Completed PDFs are listed below.") }
            else if failures > 0 { inform("\(completed) ready · \(failures) couldn’t be converted.", error: true) }
            else if completed > 0 { inform(completed == 1 ? "PDF created" : "\(completed) PDFs created") }
            else { inform("No PDFs saved") }
            if completed > 0 { notify(completed, failures: failures) }
        }
    }

    func cancel() { task?.cancel(); worker?.cancel() }
    func inform(_ text: String, error: Bool = false) { messageIsError = error; message = text }

    private func requestPassword() -> String? {
        let alert = NSAlert()
        alert.messageText = "Protect your PDF"
        alert.informativeText = "Enter a password to open \(protect ? "these PDFs" : "the PDF"). It applies to this batch only and isn’t saved. "
        alert.addButton(withTitle: "Create PDF")
        alert.addButton(withTitle: "Cancel")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 66))
        let first = NSSecureTextField(frame: NSRect(x: 0, y: 38, width: 300, height: 24))
        first.placeholderString = "Password (at least 8 characters)"
        let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        second.placeholderString = "Confirm password"
        container.addSubview(first); container.addSubview(second)
        alert.accessoryView = container
        alert.window.initialFirstResponder = first
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard first.stringValue.count >= 8, first.stringValue == second.stringValue else {
            inform("Passwords must match and contain at least 8 characters. Drop your files to try again.", error: true)
            return nil
        }
        return first.stringValue
    }

    private func notify(_ count: Int, failures: Int) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = count == 1 ? "PDF created" : "\(count) PDFs created"
            content.body = failures > 0 ? "Some files need attention. Open PDFMe to see the results." : "Saved to your chosen location. Open PDFMe to reveal in Finder."
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    static func fileSize(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
