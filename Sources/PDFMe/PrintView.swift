import SwiftUI
import PDFMeCore
import UniformTypeIdentifiers

struct PrintReviewView: View {
    @ObservedObject var model: PrintModel
    @State private var dropTargeted = false
    @State private var reorderTarget: UUID?
    private let accent = Color(red: 0.24, green: 0.37, blue: 0.27)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("PDF FILES").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                Spacer()
                Button("Add PDFs", action: model.chooseFiles).controlSize(.small)
                if !model.inputs.isEmpty { Button("Clear", action: model.clear).controlSize(.small) }
            }.disabled(model.busy)
            fileList
            if let message = model.message {
                Label(message, systemImage: model.isError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(model.isError ? Color(red: 0.65, green: 0.27, blue: 0.13) : accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                    .background((model.isError ? Color.orange : accent).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            settings
            if let problem = model.validationMessage, !model.loadingPrinters {
                Text(problem).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let submission = model.submission {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Job: \(submission.jobID)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    Text("The job is in the system queue. Submission does not mean printing is complete.").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("Printers & queues", action: model.openPrintSettings)
                        Button("Cancel this job", action: model.cancelSubmittedJob).disabled(model.busy)
                    }.controlSize(.small)
                }
            }
        }
        .onAppear { model.refreshPrinters() }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            if model.inputs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.doc").font(.system(size: 25)).foregroundStyle(accent)
                    Text("Drop PDFs here").font(.system(size: 14, weight: .medium))
                    Text("PDF files only. Nothing prints until you click Print.").font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(Array(model.inputs.enumerated()), id: \.element.id) { index, input in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(input.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).help(input.url.path)
                            Text("\(input.pages) \(input.pages == 1 ? "page" : "pages")").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Copies").font(.system(size: 10)).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                TextField("Copies", value: copyCount(for: input), format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder).frame(width: 38)
                                    .accessibilityLabel("Copies of \(input.url.lastPathComponent)")
                                Stepper("Copies", value: copyCount(for: input), in: 1...999)
                                    .labelsHidden().controlSize(.small)
                                    .accessibilityLabel("Copies of \(input.url.lastPathComponent)")
                            }
                        }
                        Button { model.remove(input.id) } label: { Image(systemName: "xmark") }.help("Remove PDF").accessibilityLabel("Remove \(input.url.lastPathComponent)")
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary).padding(.vertical, 10).padding(.horizontal, 3)
                            .contentShape(Rectangle()).help("Drag to reorder")
                            .accessibilityLabel("Reorder \(input.url.lastPathComponent)")
                            .accessibilityAction(named: "Move up") { model.move(index, by: -1) }
                            .accessibilityAction(named: "Move down") { model.move(index, by: 1) }
                            .onDrag {
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(forTypeIdentifier: PrintRowDropDelegate.type, visibility: .ownProcess) { completion in
                                    completion(Data(input.id.uuidString.utf8), nil)
                                    return nil
                                }
                                return provider
                            }
                    }.font(.system(size: 10)).buttonStyle(.plain).padding(12).disabled(model.busy)
                        .background(reorderTarget == input.id ? accent.opacity(0.1) : Color.clear)
                        .onDrop(of: [PrintRowDropDelegate.type], delegate: PrintRowDropDelegate(model: model, target: input.id, highlighted: $reorderTarget))
                    if index < model.inputs.count - 1 { Divider().padding(.horizontal, 12) }
                }
                Text("Printed in the order shown · drop more PDFs to add").font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.inputs.map(\.id))
        .background(dropTargeted ? accent.opacity(0.14) : Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(dropTargeted ? 0.7 : 0.2), style: StrokeStyle(lineWidth: 1, dash: model.inputs.isEmpty ? [5, 4] : [])) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers) { urls in model.accept(urls) }
            return true
        }
    }

    private func copyCount(for input: PrintInput) -> Binding<Int> {
        Binding(get: { model.inputs.first(where: { $0.id == input.id })?.copies ?? input.copies },
                set: { model.setCopies($0, for: input.id) })
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("TEMPLATE").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                Spacer()
                if model.changed { Text("Unsaved changes").font(.system(size: 10)).foregroundStyle(.secondary) }
                Button { model.showTemplateEditor.toggle() } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).help("Manage templates").accessibilityLabel("Manage templates")
            }
            if !model.templates.isEmpty {
                FullWidthPicker(title: "Saved template",
                                selection: Binding(get: { model.selectedTemplateID ?? model.templates[0].id }, set: model.selectTemplate),
                                options: model.templates.map { ($0.id, $0.name + ($0.id == model.defaultTemplateID ? " · default" : "")) })
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Printer").foregroundStyle(.secondary)
                    Spacer()
                    Button(action: model.refreshPrinters) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh printers").accessibilityLabel("Refresh printers")
                }
                FullWidthPicker(title: "Printer", selection: $model.template.printerID, options: printerOptions)
                    .frame(maxWidth: .infinity)
            }
            if model.loadingPrinters || model.loadingCapabilities { HStack { ProgressView().controlSize(.small); Text("Reading printer options…").font(.system(size: 11)).foregroundStyle(.secondary) } }
            pickerField("Paper") {
                FullWidthPicker(title: "Paper", selection: $model.template.paper, options: PrintPaper.allCases.map { paper in
                    (paper, paper.rawValue + (model.capabilities != nil && !model.capabilities!.papers.contains(paper) ? " (unsupported)" : ""))
                })
            }
            pickerField("Orientation") {
                FullWidthPicker(title: "Orientation", selection: $model.template.orientation, options: PrintOrientation.allCases.map { ($0, $0.rawValue) })
            }
            pickerField("Sides") {
                FullWidthPicker(title: "Sides", selection: $model.template.duplex, options: PrintDuplex.allCases.map { ($0, $0.rawValue) })
            }
            pickerField("Pages per side") {
                FullWidthPicker(title: "Pages per side", selection: $model.template.pagesPerSide, options: [1, 2, 4].map { ($0, String($0)) })
            }
            if model.template.pagesPerSide == 2 {
                Label("Two pages side by side, in file order", systemImage: "rectangle.split.2x1").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            pickerField("Color") {
                FullWidthPicker(title: "Color", selection: $model.template.color, options: PrintColor.allCases.map { ($0, $0.rawValue) })
            }
            Toggle("Print as image", isOn: $model.template.printAsImage).toggleStyle(.switch).controlSize(.small)
            if model.template.printAsImage {
                pickerField("Image resolution") {
                    FullWidthPicker(title: "Image resolution", selection: $model.template.dpi, options: [150, 300, 600].map { ($0, "\($0) dpi") })
                }
            }
            Toggle("Start each PDF on a new sheet", isOn: $model.template.startEachFileOnNewSheet).toggleStyle(.switch).controlSize(.small)
            Text(model.template.startEachFileOnNewSheet ? "Keeps documents on separate sheets. A back may be left blank with duplex." : "Pages flow across files; two PDFs may share a sheet.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if model.showTemplateEditor {
                Divider()
                TextField("Template name", text: $model.template.name).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") { model.saveTemplate(asNew: false) }
                    Button("Save as new") { model.saveTemplate(asNew: true) }
                    Spacer()
                    Button(role: .destructive, action: model.deleteTemplate) { Image(systemName: "trash") }.help("Delete selected template").accessibilityLabel("Delete selected template")
                }.controlSize(.small)
                Button(model.defaultTemplateID == model.selectedTemplateID ? "Default template" : "Use as default", action: model.makeDefault)
                    .disabled(model.changed || model.defaultTemplateID == model.selectedTemplateID).controlSize(.small)
            }
        }.font(.system(size: 12)).padding(14)
            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .disabled(model.busy)
    }

    private var printerOptions: [(String, String)] {
        let installed = model.printers.map { ($0.id, $0.name) }
        return model.printers.contains(where: { $0.id == model.template.printerID })
            ? installed : [(model.template.printerID, "Select printer")] + installed
    }

    private func pickerField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            content().labelsHidden().frame(maxWidth: .infinity)
        }
    }
}

struct PrintActionBar: View {
    @ObservedObject var model: PrintModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.busy {
                HStack {
                    if model.submitting { ProgressView().controlSize(.small) }
                    Text(model.stage).font(.system(size: 11))
                    Spacer()
                    if !model.submitting { Button("Cancel", action: model.cancelPreparation).font(.system(size: 11)) }
                }
                if !model.submitting { ProgressView(value: model.progress) }
            } else {
                HStack {
                    if let plan = model.plan {
                        Text("\(plan.sheetCount) \(plan.sheetCount == 1 ? "sheet" : "sheets") total").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Preview") { model.prepare(previewOnly: true) }.disabled(!model.canPrint)
                    Button("Print") { model.prepare(previewOnly: false) }.buttonStyle(.borderedProminent).disabled(!model.canPrint)
                }
            }
        }.padding(.horizontal, 22).padding(.vertical, 14)
            .background(Color.white.opacity(0.85))
            .overlay(alignment: .top) { Divider() }
    }
}

private struct PrintRowDropDelegate: DropDelegate {
    static let type = "app.pdfme.print-row"
    let model: PrintModel
    let target: UUID
    @Binding var highlighted: UUID?

    func validateDrop(info: DropInfo) -> Bool { !model.busy && info.hasItemsConforming(to: [Self.type]) }
    func dropEntered(info: DropInfo) { highlighted = target }
    func dropExited(info: DropInfo) { if highlighted == target { highlighted = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: model.busy ? .forbidden : .move) }
    func performDrop(info: DropInfo) -> Bool {
        highlighted = nil
        guard !model.busy, let provider = info.itemProviders(for: [Self.type]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: Self.type) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            Task { @MainActor in model.move(id, to: target) }
        }
        return true
    }
}

/// Retain Finder's provided order while loading URL representations asynchronously.
@MainActor
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    Task { @MainActor in
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL { continuation.resume(returning: url) }
                    else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                    else { continuation.resume(returning: nil) }
                }
            }
            guard let url else { completion([]); return }
            urls.append(url)
        }
        completion(urls)
    }
}
