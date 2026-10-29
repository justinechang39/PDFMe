import SwiftUI
import PDFKit
import PDFMeCore

struct PrintPreviewView: View {
    @ObservedObject var model: PrintModel
    @State private var showsGrid = false
    private let stripHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("PRINT PREVIEW")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.previewInput != nil {
                    Button { showsGrid.toggle() } label: {
                        Image(systemName: gridShown ? "rectangle" : "square.grid.2x2").font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(ToolbarIconButtonStyle())
                    .disabled(!gridShown && model.previewIndices.count < 2)
                    .help(gridShown ? "Show the selected side" : "Show all sides")
                    .accessibilityLabel(gridShown ? "Show the selected side" : "Show all sides as a grid")
                }
            }
            if let input = model.previewInput {
                Text(input.url.lastPathComponent).font(.system(size: 14, weight: .semibold))
                    .lineLimit(2).help(input.url.path)
                Text("\(model.template.paper.rawValue) · \(model.template.orientation.rawValue) · \(model.template.pagesPerSide) per side")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if input.pageSelection.isCustom, let count = try? input.selectedPages().count {
                    Text("PDF pages \(input.pageSelection.text.trimmingCharacters(in: .whitespacesAndNewlines)) · \(count) of \(input.pages)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.045))
                    if gridShown {
                        grid
                    } else if model.previewIndices.isEmpty, let problem = model.inputProblem {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle").font(.system(size: 24))
                            Text(problem).font(.system(size: 12)).multilineTextAlignment(.center)
                        }.foregroundStyle(.secondary).padding(24)
                    } else if model.previewLoading {
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
                if !model.previewIndices.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.previewSheetTitle).font(.system(size: 12, weight: .medium))
                        Text("\(model.previewOffset + 1) of \(model.previewIndices.count) sides for this PDF")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }.lineLimit(1)
                    Text(model.previewSide.isEmpty ? "Blank back · next PDF or copy starts on a fresh sheet" : pageDescription(model.previewSide))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    if !gridShown { strip }
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
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.4))
            .onAppear { model.setPreviewVisible(true) }
            .onDisappear { model.setPreviewVisible(false) }
    }

    private var gridShown: Bool { showsGrid && !model.previewIndices.isEmpty }
    private var pageAspect: CGFloat { model.template.pageSize.width / model.template.pageSize.height }

    /// Arrows wrap around; the strip keeps the selected side scrolled into view.
    private var strip: some View {
        let single = model.previewIndices.count < 2
        return HStack(spacing: 6) {
            Button { model.movePreview(by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(ToolbarIconButtonStyle(width: 44, height: stripHeight + 14)).disabled(single)
                .help("Previous side").accessibilityLabel("Previous preview side")
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(0..<model.previewIndices.count, id: \.self) { offset in
                            stripTile(offset).id(offset)
                        }
                    }.padding(.horizontal, 2).padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(model.previewOffset) }
                .onChange(of: model.previewOffset) { proxy.scrollTo($0) }
                .onChange(of: model.selectedPreviewID) { _ in proxy.scrollTo(model.previewOffset) }
            }
            Button { model.movePreview(by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(ToolbarIconButtonStyle(width: 44, height: stripHeight + 14)).disabled(single)
                .help("Next side").accessibilityLabel("Next preview side")
        }.frame(height: stripHeight + 30)
    }

    private func stripTile(_ offset: Int) -> some View {
        let selected = offset == model.previewOffset
        let side = model.previewSide(at: offset)
        let width = max(40, stripHeight * pageAspect)
        return Button { model.selectPreviewSide(at: offset) } label: {
            VStack(spacing: 3) {
                SideThumbnail(key: model.previewThumbnailKey(at: offset), store: model.thumbnails, aspect: pageAspect)
                    .frame(width: stripHeight * pageAspect, height: stripHeight)
                    .overlay(alignment: .topLeading) {
                        Text(sideBadge(offset)).font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 3).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white).padding(2)
                    }
                    .overlay(selectionBorder(selected))
                Text(pagesLabel(side)).font(.system(size: 9, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary).lineLimit(1).truncationMode(.middle)
            }.frame(width: width)
        }
        .buttonStyle(.plain)
        .help(tileHelp(offset, side))
        .accessibilityLabel(tileHelp(offset, side))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Clicking a side opens it in the large preview.
    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 112), spacing: 10)], spacing: 12) {
                    ForEach(0..<model.previewIndices.count, id: \.self) { offset in
                        gridTile(offset).id(offset)
                    }
                }.padding(12)
            }.onAppear { proxy.scrollTo(model.previewOffset, anchor: .center) }
                .onChange(of: model.selectedPreviewID) { _ in proxy.scrollTo(model.previewOffset, anchor: .center) }
                .onChange(of: model.previewOffset) { proxy.scrollTo($0, anchor: .center) }
        }
    }

    private func gridTile(_ offset: Int) -> some View {
        let selected = offset == model.previewOffset
        let side = model.previewSide(at: offset)
        return Button { model.selectPreviewSide(at: offset); showsGrid = false } label: {
            VStack(spacing: 3) {
                SideThumbnail(key: model.previewThumbnailKey(at: offset), store: model.thumbnails, aspect: pageAspect)
                    .frame(maxWidth: .infinity).overlay(selectionBorder(selected))
                Text(model.sheetTitle(forSide: model.previewIndices[offset])).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Text(side.isEmpty ? "Blank" : "p. " + pagesLabel(side)).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .help(tileHelp(offset, side))
        .accessibilityLabel(tileHelp(offset, side))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectionBorder(_ selected: Bool) -> some View {
        Rectangle().strokeBorder(selected ? Color.accentColor : Color.black.opacity(0.15), lineWidth: selected ? 2.5 : 1)
    }
    /// "3F" is sheet 3, front, in the full job.
    private func sideBadge(_ offset: Int) -> String {
        let index = model.previewIndices[offset]
        return model.template.duplex == .off ? "\(index + 1)" : "\(index / 2 + 1)\(index % 2 == 0 ? "F" : "B")"
    }
    private func tileHelp(_ offset: Int, _ side: [PrintPageReference]) -> String {
        "\(model.sheetTitle(forSide: model.previewIndices[offset])): " + (side.isEmpty ? "blank back" : pageDescription(side))
    }
    /// PDF page numbers, collapsing runs such as 21–24. Pages from different PDFs are joined with +.
    private func pagesLabel(_ side: [PrintPageReference]) -> String {
        guard !side.isEmpty else { return "Blank" }
        var groups: [(document: Int, pages: [Int])] = []
        for reference in side {
            if groups.last?.document == reference.document { groups[groups.count - 1].pages.append(reference.page + 1) }
            else { groups.append((reference.document, [reference.page + 1])) }
        }
        return groups.map { group in
            var runs: [String] = [], start = group.pages[0], end = start
            for page in group.pages.dropFirst() {
                if page == end + 1 { end = page; continue }
                runs.append(start == end ? "\(start)" : "\(start)–\(end)"); start = page; end = page
            }
            runs.append(start == end ? "\(start)" : "\(start)–\(end)")
            return runs.joined(separator: ", ")
        }.joined(separator: " + ")
    }
    private func pageDescription(_ side: [PrintPageReference]) -> String {
        let shared = Set(side.map(\.document)).count > 1
        return side.map { reference in
            let name = shared && model.inputs.indices.contains(reference.document)
                ? model.inputs[reference.document].url.lastPathComponent + ": " : ""
            return "\(name)page \(reference.page + 1)"
        }.joined(separator: " · ")
    }
}

/// A small bitmap of one composed side, requested only while the cell is on screen.
private struct SideThumbnail: View {
    let key: PrintThumbnailKey?
    let store: PrintThumbnailStore
    let aspect: CGFloat
    @State private var loaded: Loaded?
    @State private var isVisible = false
    private struct Loaded { let key: PrintThumbnailKey; let image: CGImage?; let failure: String? }

    var body: some View {
        // Never show an image for a previous key, such as before a range or layout change.
        let current = loaded.flatMap { $0.key == key ? $0 : nil }
        let image = isVisible ? (current?.image ?? key.flatMap { store.peek($0) }) : nil
        let failure = current?.failure ?? key.flatMap { store.failure(for: $0) }
        ZStack {
            Rectangle().fill(Color.white)
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            } else if let failure {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.secondary).help(failure)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .onAppear { isVisible = true }
        .task(id: key) { await load() }
        // Lazy stacks retain offscreen state. Clear both the state and rendered image reference.
        .onDisappear { isVisible = false; loaded = nil }
    }

    private func load() async {
        guard let key else { return }
        // A short pause skips cells that only flash past while scrolling.
        if store.peek(key) == nil { try? await Task.sleep(nanoseconds: 60_000_000) }
        while !Task.isCancelled {
            let result = await store.image(for: key)
            guard !Task.isCancelled, isVisible else { return }
            switch result {
            case .success(let image)?: loaded = Loaded(key: key, image: image, failure: nil); return
            case .failure(let error)?: loaded = Loaded(key: key, image: nil, failure: error.localizedDescription); return
            case nil: try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
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
