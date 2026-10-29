import AppKit
import Combine
import PDFMeCore

@MainActor
final class PrintGroup: Identifiable {
    let id = UUID()
    let model: PrintModel
    init(model: PrintModel) { self.model = model }
}

/// Groups own independent setting snapshots. Saving a template updates the catalog,
/// not another group's already-reviewed settings. The first group is shared with the mini app.
@MainActor
final class PrintQueueModel: ObservableObject {
    @Published private(set) var groups: [PrintGroup]
    @Published var selectedID: UUID
    @Published private(set) var isPrinting = false
    @Published private(set) var isImporting = false
    @Published private(set) var stopRequested = false
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    @Published private(set) var activeGroupID: UUID?
    private let discoverPrinters: Bool
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var pendingImports: [(UUID, [URL])] = []
    private(set) var operation: Task<Void, Never>?
    private var importOperation: Task<Void, Never>?

    init(primary: PrintModel, discoverPrinters: Bool = true) {
        self.discoverPrinters = discoverPrinters
        let group = PrintGroup(model: primary)
        groups = [group]; selectedID = group.id
        observe(group)
    }
    var selected: PrintGroup { groups.first { $0.id == selectedID } ?? groups[0] }
    var documentCount: Int { groups.reduce(0) { $0 + $1.model.inputs.count } }
    var sheetCount: Int { groups.reduce(0) { $0 + ($1.model.plan?.sheetCount ?? 0) } }
    var occupied: Bool { isPrinting || isImporting || groups.contains { $0.model.busy } }
    var canPrint: Bool {
        let pending = groups.filter { !$0.model.inputs.isEmpty }
        return !occupied && !pending.isEmpty && pending.allSatisfy { $0.model.canPrint }
    }
    /// The first unfinished page range or copy count, which blocks every group from printing.
    var inputProblem: String? {
        for (index, group) in groups.enumerated() {
            if let problem = group.model.inputProblem { return "Group \(index + 1): \(problem)" }
        }
        return nil
    }
    private func observe(_ group: PrintGroup) {
        subscriptions[group.id] = group.model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        group.model.catalogChanged = { [weak self, weak model = group.model] in
            guard let self, let model else { return }
            for other in self.groups where other.model !== model {
                other.model.templates = model.templates
                other.model.defaultTemplateID = model.defaultTemplateID
            }
        }
        group.model.transportChanged = { [weak self] enabled in
            guard let self else { return }
            for other in self.groups where other.model.directPrinting != enabled { other.model.directPrinting = enabled }
        }
    }
    @discardableResult
    func addGroup(template: PrintTemplate? = nil) -> PrintGroup? {
        guard !isPrinting else { return nil }
        let model = PrintModel()
        model.templates = groups[0].model.templates
        model.defaultTemplateID = groups[0].model.defaultTemplateID
        if let template { model.template = template; model.selectedTemplateID = template.id }
        let group = PrintGroup(model: model)
        groups.append(group); observe(group); selectedID = group.id
        if discoverPrinters { model.refreshPrinters() }
        return group
    }
    func removeGroup(_ id: UUID) {
        guard !occupied, let group = groups.first(where: { $0.id == id }) else { return }
        // Keep the primary model alive because the menu bar holds it too.
        if id == groups[0].id { group.model.clear(); return }
        group.model.cleanup(); groups.removeAll { $0.id == id }; subscriptions[id] = nil
        if selectedID == id { selectedID = groups[0].id }
    }
    func moveDocument(_ id: UUID, from sourceID: UUID, to targetID: UUID) {
        guard !occupied, sourceID != targetID,
              let source = groups.first(where: { $0.id == sourceID })?.model,
              let target = groups.first(where: { $0.id == targetID })?.model,
              !source.requiresSubmissionReview, !target.requiresSubmissionReview,
              let index = source.inputs.firstIndex(where: { $0.id == id }) else { return }
        // Page selection and copies travel inside PrintInput; an unfinished copy edit reverts.
        source.finishCopiesEdit(for: id)
        let input = source.inputs.remove(at: index)
        if target.inputs.isEmpty { target.clear() }
        target.inputs.append(input); target.selectPreview(id); selectedID = targetID
    }
    func accept(_ urls: [URL], into id: UUID? = nil) {
        guard !isPrinting else { inform("Printing is in progress. Add files after this batch finishes.", error: true); return }
        pendingImports.append((id ?? selectedID, urls))
        guard !isImporting else { return }
        isImporting = true
        importOperation = Task {
            defer { isImporting = false; importOperation = nil }
            while !pendingImports.isEmpty {
                let (id, urls) = pendingImports.removeFirst()
                guard let group = groups.first(where: { $0.id == id }) else { continue }
                selectedID = id
                if let current = group.model.operation { await current.value }
                group.model.accept(urls, reveal: false)
                if let current = group.model.operation { await current.value }
                if group.model.isError { inform(group.model.message ?? "Couldn’t add PDFs.", error: true) }
                else { message = nil }
            }
        }
    }
    func chooseFiles() {
        guard !isPrinting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.prompt = "Add to group"
        if panel.runModal() == .OK { accept(panel.urls) }
    }
    func printAll() {
        guard canPrint else { inform(inputProblem.map { "\($0) Nothing was sent." } ?? "Check each group’s printer and settings before printing.", error: true); return }
        let batch = groups.filter { !$0.model.inputs.isEmpty }
        isPrinting = true; stopRequested = false; message = nil
        // Lock every entry point, including the shared menu bar model.
        for group in groups { group.model.reservedForQueue = true }
        operation = Task {
            defer {
                for group in groups { group.model.reservedForQueue = false }
                activeGroupID = nil; isPrinting = false; operation = nil
            }
            var sent = 0
            for group in batch {
                if stopRequested { break }
                activeGroupID = group.id; selectedID = group.id
                group.model.reservedForQueue = false
                group.model.prepare(previewOnly: false)
                group.model.reservedForQueue = true
                if let current = group.model.operation { await current.value }
                guard group.model.lastAttempt == .sent else {
                    let reason = group.model.message ?? "Couldn’t submit this group."
                    inform("Stopped at \(group.model.template.name). \(sent) of \(batch.count) groups sent. \(reason) Later groups were not sent.", error: true)
                    return
                }
                sent += 1
            }
            inform(stopRequested && sent < batch.count
                   ? "Stopped. \(sent) of \(batch.count) groups sent. Remaining groups are still in the queue."
                   : "\(sent) \(sent == 1 ? "group" : "groups") sent. Check the printer for completion.")
        }
    }
    func stopAfterCurrent() { if isPrinting { stopRequested = true } }
    func cleanup() { for group in groups { group.model.cleanup() } }
    private func inform(_ text: String, error: Bool = false) { message = text; isError = error }
}
