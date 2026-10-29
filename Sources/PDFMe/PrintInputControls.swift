import SwiftUI
import PDFMeCore

private let issueColor = Color(red: 0.65, green: 0.27, blue: 0.13)

/// Copy count editor shared by the mini app and the queue window. The text lives in the
/// model, so backspacing to an empty field is allowed, both views stay in sync, and an
/// unfinished value blocks printing instead of silently printing the previous count.
struct CopiesField: View {
    @ObservedObject var model: PrintModel
    let id: UUID
    var showsStepper = false
    var width: CGFloat = 40
    @FocusState private var focused: Bool

    private var input: PrintInput? { model.inputs.first { $0.id == id } }
    private var name: String { input?.url.lastPathComponent ?? "PDF" }
    private var invalid: Bool { model.copyDrafts[id] != nil }

    var body: some View {
        HStack(spacing: 4) {
            TextField("Copies", text: Binding(get: { model.copiesText(for: id) }, set: { model.editCopies($0, for: id) }))
                .textFieldStyle(.roundedBorder).frame(width: width)
                .focused($focused)
                .onSubmit { model.finishCopiesEdit(for: id) }
                .onChange(of: focused) { isFocused in if !isFocused { model.finishCopiesEdit(for: id) } }
                .overlay { if invalid { RoundedRectangle(cornerRadius: 5).strokeBorder(issueColor, lineWidth: 1).allowsHitTesting(false) } }
                .help("1–999 copies")
                .accessibilityLabel("Copies of \(name)")
                .accessibilityHint("Enter 1 to 999")
            if showsStepper {
                Stepper("Copies", value: Binding(get: { input?.copies ?? 1 }, set: { model.setCopies($0, for: id) }), in: CopyCount.range)
                    .labelsHidden().controlSize(.small)
                    .accessibilityLabel("Copies of \(name)")
            }
        }
    }
}

/// Second row of a document: All or Custom pages, plus the selected count or an inline problem.
struct PageSelectionControls: View {
    @ObservedObject var model: PrintModel
    let id: UUID
    /// Shows this document's preview while its pages are being edited.
    var onEdit: () -> Void = {}
    @FocusState private var fieldFocused: Bool

    private var input: PrintInput? { model.inputs.first { $0.id == id } }

    var body: some View {
        if let input {
            let selection = input.pageSelection
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Pages").font(.system(size: 10)).foregroundStyle(.secondary)
                    Picker("Pages", selection: Binding(get: { selection.isCustom }, set: setCustom)) {
                        Text("All").tag(false)
                        Text("Custom").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                        .accessibilityLabel("Pages to print from \(input.url.lastPathComponent)")
                    if selection.isCustom {
                        TextField("e.g. 1-15, 21-end", text: Binding(get: { model.inputs.first { $0.id == id }?.pageSelection.text ?? "" },
                                                                    set: { model.setPageSelection(.custom($0), for: id); onEdit() }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 11)).controlSize(.small)
                            .frame(minWidth: 70, maxWidth: .infinity)
                            .focused($fieldFocused)
                            .overlay { if problem(for: input) != nil { RoundedRectangle(cornerRadius: 5).strokeBorder(issueColor, lineWidth: 1).allowsHitTesting(false) } }
                            .help("PDF page numbers, starting at 1. Separate pages and ranges with commas; use “end” for the last page.")
                            .accessibilityLabel("Custom pages for \(input.url.lastPathComponent)")
                            .accessibilityHint("PDF page numbers, such as 1-15, 21-end")
                    }
                }
                if model.copyDrafts[id] != nil { issue("Copies: enter a whole number from 1 to 999.") }
                if selection.isCustom {
                    if let problem = problem(for: input) { issue(problem) }
                    else if let count = try? input.selectedPages().count {
                        Text("\(count) of \(input.pages) PDF \(input.pages == 1 ? "page" : "pages") selected")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func problem(for input: PrintInput) -> String? {
        input.pageSelection.validationMessage(pageCount: input.pages)
    }
    private func setCustom(_ custom: Bool) {
        guard var selection = model.inputs.first(where: { $0.id == id })?.pageSelection else { return }
        selection.isCustom = custom
        model.setPageSelection(selection, for: id); onEdit()
        if custom { DispatchQueue.main.async { fieldFocused = true } }
    }
    private func issue(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(issueColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}
