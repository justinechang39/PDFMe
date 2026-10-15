import SwiftUI
import PDFMeCore
import UniformTypeIdentifiers

private let queueAccent = Color(red: 0.24, green: 0.37, blue: 0.27)

struct PrintQueueView: View {
    @ObservedObject var queue: PrintQueueModel
    var showMini: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "printer").font(.system(size: 24)).foregroundStyle(queueAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Print Queue").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("\(queue.documentCount) PDFs · \(queue.sheetCount) sheets").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: showMini) { Label("Mini app", systemImage: "menubar.rectangle") }
                Button(action: queue.chooseFiles) { Label("Add PDFs", systemImage: "plus") }.disabled(queue.isPrinting)
                    .keyboardShortcut("o")
                Menu {
                    ForEach(queue.groups[0].model.templates) { template in
                        Button(template.name) { queue.addGroup(template: template) }
                    }
                    Divider()
                    Button("New group") { queue.addGroup() }
                } label: { Label("Add group", systemImage: "folder.badge.plus") }.fixedSize().disabled(queue.isPrinting)
            }.padding(20)
            Divider()
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        Text("GROUPS").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                        ForEach(Array(queue.groups.enumerated()), id: \.element.id) { index, group in
                            PrintGroupCard(queue: queue, group: group, number: index + 1)
                        }
                        Text("Drop PDFs into a group. Drag a document’s handle to reorder it or move it to another group.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }.padding(16)
                }.frame(minWidth: 290, idealWidth: 340, maxWidth: 440)
                PrintPreviewView(model: queue.selected.model).id(queue.selected.id)
                    .frame(minWidth: 290, maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("GROUP SETTINGS").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                        Text("Applies to every PDF in this group.").font(.system(size: 12)).foregroundStyle(.secondary)
                        PrintReviewView(model: queue.selected.model, showsFiles: false, showsTransport: false)
                    }.padding(18)
                }.frame(minWidth: 285, idealWidth: 310, maxWidth: 390).disabled(queue.isPrinting)
            }
            Divider()
            footer
        }
        .frame(minWidth: 940, minHeight: 610)
        .background(Color(red: 0.97, green: 0.96, blue: 0.93))
        .tint(queueAccent).preferredColorScheme(.light)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: queue.groups.map(\.id))
    }
    private var footer: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                QueueTransportControl(model: queue.groups[0].model).disabled(queue.occupied)
                if let message = queue.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(queue.isError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else {
                    Text("Groups are sent in order, one job per group.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            if queue.isPrinting {
                ProgressView().controlSize(.small)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(queue.groups.first { $0.id == queue.activeGroupID }?.model.stage ?? "Preparing queue")
                        .font(.system(size: 12)).lineLimit(1)
                    Button(queue.stopRequested ? "Stopping after this group…" : "Stop after this group", action: queue.stopAfterCurrent)
                        .disabled(queue.stopRequested)
                }
            } else {
                if queue.isImporting { ProgressView().controlSize(.small); Text("Adding PDFs…").font(.system(size: 12)) }
                Button("Open group in Preview") { queue.selected.model.prepare(previewOnly: true) }
                    .disabled(queue.occupied || !queue.selected.model.canPreview)
                Button("Print all groups", action: queue.printAll).buttonStyle(.borderedProminent)
                    .controlSize(.large).disabled(!queue.canPrint)
            }
        }.padding(18).background(.white.opacity(0.7))
    }
}

private struct QueueTransportControl: View {
    @ObservedObject var model: PrintModel
    var body: some View {
        Toggle("Send directly to printer", isOn: $model.directPrinting).toggleStyle(.switch).controlSize(.small)
            .font(.system(size: 12)).fixedSize()
            .help("Off uses the macOS print queue. Applies to all groups.")
    }
}

private struct PrintGroupCard: View {
    @ObservedObject var queue: PrintQueueModel
    let group: PrintGroup
    let number: Int
    @State private var targeted = false
    @State private var confirmRemove = false
    private var model: PrintModel { group.model }
    private var selected: Bool { queue.selectedID == group.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { queue.selectedID = group.id } label: {
                    HStack(spacing: 10) {
                        Text(String(number)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 26, height: 26).background(queueAccent.opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.template.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text("\(model.inputs.count) PDFs · \(model.plan?.sheetCount ?? 0) sheets")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Group \(number): \(model.template.name)")
                Menu {
                    Button("Add PDFs") { queue.selectedID = group.id; queue.chooseFiles() }
                    Divider()
                    ForEach(model.templates) { template in
                        Button("Use \(template.name)") { model.selectTemplate(template.id) }
                    }
                    Divider()
                    Button(number == 1 ? "Clear group" : "Remove group", role: .destructive) { confirmRemove = true }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 32).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(queue.occupied)
                    .accessibilityLabel("Group actions")
            }.padding(12)
            if model.inputs.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: model.submission == nil ? "doc.badge.plus" : model.lastAttempt == .uncertain ? "exclamationmark.circle" : "checkmark.circle").font(.system(size: 21))
                    Text(model.submission == nil ? "Drop PDFs here" : model.lastAttempt == .uncertain ? "Check printer" : "Group sent").font(.system(size: 12))
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
                    .onTapGesture { queue.selectedID = group.id }
            } else {
                ForEach(model.inputs) { input in
                    Divider().padding(.horizontal, 12)
                    QueueDocumentRow(queue: queue, group: group, input: input)
                }
            }
            if model.requiresSubmissionReview {
                Label("Check printer before retrying", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).padding(12)
            } else if let submission = model.submission {
                Text("Job \(submission.jobID)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(12)
            }
        }
        .background(targeted ? queueAccent.opacity(0.12) : Color.white.opacity(selected ? 1 : 0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(queueAccent.opacity(selected || targeted ? 0.65 : 0.15), lineWidth: selected ? 1.5 : 1) }
        .onDrop(of: [QueueDocumentDrag.type, UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            guard !queue.occupied else { return false }
            if let row = providers.first(where: { $0.hasItemConformingToTypeIdentifier(QueueDocumentDrag.type) }) {
                QueueDocumentDrag.load(row) { source, input in queue.moveDocument(input, from: source, to: group.id) }
            } else { loadFileURLs(providers) { queue.accept($0, into: group.id) } }
            return true
        }
        .alert(number == 1 ? "Clear this group?" : "Remove this group?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { queue.removeGroup(group.id) }
        } message: { Text("This removes the documents from PDFMe’s queue. Files on disk and jobs already sent to a printer are kept.") }
    }
}

private struct QueueDocumentRow: View {
    @ObservedObject var queue: PrintQueueModel
    let group: PrintGroup
    let input: PrintInput
    @State private var targeted = false
    private var model: PrintModel { group.model }
    private var copies: Binding<Int> {
        Binding(get: { model.inputs.first { $0.id == input.id }?.copies ?? input.copies }, set: { model.setCopies($0, for: input.id) })
    }
    var body: some View {
        HStack(spacing: 8) {
            Button {
                queue.selectedID = group.id; model.selectPreview(input.id)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(input.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(2).help(input.url.path)
                    Text("\(input.pages) pages").font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 42, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Preview \(input.url.lastPathComponent)")
            VStack(alignment: .leading, spacing: 4) {
                Text("Copies").font(.system(size: 9)).foregroundStyle(.secondary)
                TextField("Copies", value: copies, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 42)
                    .accessibilityLabel("Copies of \(input.url.lastPathComponent)")
            }.disabled(queue.occupied || model.requiresSubmissionReview)
            Menu {
                ForEach(queue.groups.filter { $0.id != group.id }) { target in
                    Button("Move to \(target.model.template.name)") { queue.moveDocument(input.id, from: group.id, to: target.id) }
                }
                Button("Move to new group") {
                    if let target = queue.addGroup(template: model.template) { queue.moveDocument(input.id, from: group.id, to: target.id) }
                }
                if let index = model.inputs.firstIndex(where: { $0.id == input.id }) {
                    Button("Move up") { model.move(index, by: -1) }.disabled(index == 0)
                    Button("Move down") { model.move(index, by: 1) }.disabled(index + 1 == model.inputs.count)
                }
                Divider()
                Button("Remove", role: .destructive) { model.remove(input.id) }
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 30) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(queue.occupied)
                .accessibilityLabel("Actions for \(input.url.lastPathComponent)")
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).frame(width: 20, height: 40).contentShape(Rectangle())
                .help("Drag to reorder or move between groups")
                .accessibilityLabel("Drag \(input.url.lastPathComponent)")
                .onDrag { QueueDocumentDrag.provider(group: group.id, input: input.id) }
                .disabled(queue.occupied || model.requiresSubmissionReview)
        }.padding(10)
            .background(targeted || (queue.selectedID == group.id && model.selectedPreviewID == input.id) ? queueAccent.opacity(0.07) : .clear)
            .onDrop(of: [QueueDocumentDrag.type], isTargeted: $targeted) { providers in
                guard !queue.occupied, let provider = providers.first else { return false }
                QueueDocumentDrag.load(provider) { source, id in
                    if source == group.id { model.move(id, to: input.id) }
                    else { queue.moveDocument(id, from: source, to: group.id); model.move(id, to: input.id) }
                }
                return true
            }
    }
}

private enum QueueDocumentDrag {
    static let type = "app.pdfme.queue-document"
    static func provider(group: UUID, input: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .ownProcess) { completion in
            completion(Data("\(group.uuidString)/\(input.uuidString)".utf8), nil); return nil
        }
        return provider
    }
    @MainActor
    static func load(_ provider: NSItemProvider, completion: @escaping (UUID, UUID) -> Void) {
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8) else { return }
            let parts = text.split(separator: "/").map(String.init)
            guard parts.count == 2, let group = UUID(uuidString: parts[0]), let input = UUID(uuidString: parts[1]) else { return }
            Task { @MainActor in completion(group, input) }
        }
    }
}
