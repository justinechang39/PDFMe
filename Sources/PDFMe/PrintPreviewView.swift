import SwiftUI
import PDFKit
import PDFMeCore

struct PrintPreviewView: View {
    @ObservedObject var model: PrintModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PRINT PREVIEW")
                .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                .foregroundStyle(.secondary)
            if let input = model.previewInput {
                Text(input.url.lastPathComponent).font(.system(size: 14, weight: .semibold))
                    .lineLimit(2).help(input.url.path)
                Text("\(model.template.paper.rawValue) · \(model.template.orientation.rawValue) · \(model.template.pagesPerSide) per side")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.045))
                    if model.previewLoading {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Updating preview…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else if let error = model.previewError {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle").font(.system(size: 24))
                            Text(error).font(.system(size: 12)).multilineTextAlignment(.center)
                        }.foregroundStyle(.secondary).padding(24)
                    } else if let data = model.previewData {
                        SheetPDFView(data: data).padding(16)
                            .accessibilityLabel("Print preview for \(input.url.lastPathComponent), \(model.previewSheetTitle)")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 8) {
                    Button { model.movePreview(by: -1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(ToolbarIconButtonStyle()).disabled(model.previewOffset == 0)
                        .help("Previous side").accessibilityLabel("Previous preview side")
                    Spacer(minLength: 0)
                    VStack(spacing: 4) {
                        Text(model.previewSheetTitle).font(.system(size: 12, weight: .medium))
                        Text("\(model.previewOffset + 1) of \(model.previewIndices.count) sides for this PDF")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { model.movePreview(by: 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(ToolbarIconButtonStyle()).disabled(model.previewOffset + 1 >= model.previewIndices.count)
                        .help("Next side").accessibilityLabel("Next preview side")
                }
                if model.previewSide.isEmpty {
                    Text("Blank back · next PDF or copy starts on a fresh sheet")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text(pageDescription).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                }
                Text("\(model.template.duplex.rawValue). Printer margins may slightly change the final scale.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36, weight: .light))
                    Text("Select a PDF to preview").font(.system(size: 14, weight: .medium))
                    Text("The preview follows your print settings.").font(.system(size: 12))
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.4))
            .onAppear { model.setPreviewVisible(true) }
            .onDisappear { model.setPreviewVisible(false) }
    }

    private var pageDescription: String {
        let shared = Set(model.previewSide.map(\.document)).count > 1
        return model.previewSide.map { reference in
            let name = shared && model.inputs.indices.contains(reference.document)
                ? model.inputs[reference.document].url.lastPathComponent + ": " : ""
            return "\(name)page \(reference.page + 1)"
        }.joined(separator: " · ")
    }
}

private struct SheetPDFView: NSViewRepresentable {
    let data: Data
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displayBox = .mediaBox
        view.displaysPageBreaks = false
        view.backgroundColor = .clear
        view.autoScales = true
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
        view.autoScales = true
    }
    final class Coordinator { var data: Data? }
}
