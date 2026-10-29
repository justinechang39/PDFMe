import Foundation
import PDFKit
import PDFMeCore

@main
struct PrintPreviewChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PrintError.message("FAIL: " + message) }
        print("PASS: " + message)
    }
    @MainActor
    static func waitForPreview(_ model: PrintModel) async throws -> PDFDocument {
        for _ in 0..<250 {
            if let error = model.previewError { throw PrintError.message(error) }
            if !model.previewLoading, let data = model.previewData, let document = PDFDocument(data: data) { return document }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw PrintError.message("Preview timed out")
    }
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let inputs = try PrintComposer.inspect([root.appendingPathComponent("01 Sample A.pdf"), root.appendingPathComponent("02 Sample B.pdf")])
        let model = PrintModel()
        model.template = PrintTemplate(orientation: .landscape, duplex: .shortEdge, pagesPerSide: 2, printAsImage: false)
        model.inputs = inputs
        model.setPreviewVisible(true)
        let first = try await waitForPreview(model)
        try check(first.string?.contains("A1") == true && model.selectedPreviewID == inputs[0].id, "first dropped PDF is selected automatically")
        model.selectPreview(inputs[1].id)
        let second = try await waitForPreview(model)
        try check(second.string?.contains("B1") == true && second.string?.contains("A1") != true, "selecting a different PDF replaces its preview")
        model.movePreview(by: 1)
        let blank = try await waitForPreview(model)
        try check((blank.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.previewSheetTitle.contains("Back"), "blank duplex backs are navigable")
        model.selectPreview(inputs[0].id)
        model.template.orientation = .portrait
        model.selectPreview(inputs[1].id)
        model.template.pagesPerSide = 1
        let changed = try await waitForPreview(model)
        let bounds = changed.page(at: 0)!.bounds(for: .mediaBox)
        try check(bounds.height > bounds.width && changed.string?.contains("B1") == true && changed.string?.contains("B2") != true, "rapid selection and layout changes show only the newest render")
        model.template.orientation = .landscape
        model.template.pagesPerSide = 2
        model.template.startEachFileOnNewSheet = false
        model.selectPreview(inputs[0].id)
        model.selectPreview(inputs[1].id)
        let shared = try await waitForPreview(model)
        try check(shared.string?.contains("A3") == true && shared.string?.contains("B1") == true, "selected PDF retains neighboring pages on a shared sheet")
        model.remove(inputs[1].id)
        _ = try await waitForPreview(model)
        try check(model.selectedPreviewID == inputs[0].id, "removing the selected file selects a remaining PDF")
        model.template.orientation = .portrait
        model.clear()
        try await Task.sleep(nanoseconds: 350_000_000)
        try check(model.previewData == nil && model.selectedPreviewID == nil && !model.previewLoading, "clearing a batch cancels pending previews without restoring stale data")
        model.inputs = inputs
        model.setPreviewVisible(true)
        model.setPreviewVisible(false)
        model.template.orientation = .landscape
        _ = try await waitForPreview(model)
        try check(model.previewData != nil, "closing one of two preview surfaces keeps the other preview live")
        model.setPreviewVisible(false)

        // The inline preview uses the same selected pages as the prepared job.
        let ranged = PrintModel()
        ranged.template = PrintTemplate(printAsImage: false)
        ranged.inputs = inputs
        ranged.setPreviewVisible(true)
        ranged.setPageSelection(.custom("3"), for: inputs[0].id)
        let third = try await waitForPreview(ranged)
        try check(ranged.previewIndices.count == 1 && third.string?.contains("A3") == true && third.string?.contains("A1") != true, "custom pages limit the preview to the selected PDF page")
        ranged.setPageSelection(.custom("2-4"), for: inputs[0].id)
        try await Task.sleep(nanoseconds: 350_000_000)
        try check(ranged.previewIndices.isEmpty && ranged.previewData == nil && ranged.inputProblem != nil && !ranged.canPreview, "an invalid range shows no stale preview and blocks preview export")
        ranged.setPageSelection(PageSelection(isCustom: false, text: "2-4"), for: inputs[0].id)
        _ = try await waitForPreview(ranged)
        try check(ranged.previewIndices.count == 3 && ranged.inputProblem == nil, "switching back to All previews every page")
        ranged.setPreviewVisible(false)
        try await galleryChecks(inputs)
        print("All preview state checks passed. No print jobs submitted.")
    }

    @MainActor
    static func thumbnail(_ model: PrintModel, _ offset: Int) async throws -> PrintThumbnailKey {
        guard let key = model.previewThumbnailKey(at: offset), case .success? = await model.thumbnails.image(for: key) else {
            throw PrintError.message("FAIL: thumbnail \(offset) did not render")
        }
        return key
    }

    /// Wraparound navigation, exact thumbnail selection, and thumbnail invalidation.
    @MainActor
    static func galleryChecks(_ inputs: [PrintInput]) async throws {
        let model = PrintModel()
        model.template = PrintTemplate(printAsImage: false)
        model.inputs = [inputs[0]]
        model.setPreviewVisible(true)
        _ = try await waitForPreview(model)
        try check(model.previewIndices.count == 3 && model.previewOffset == 0, "a three-page PDF starts on its first side")
        model.movePreview(by: -1)
        let last = try await waitForPreview(model)
        try check(model.previewOffset == 2 && last.string?.contains("A3") == true, "back from the first side wraps to the last")
        model.movePreview(by: 1)
        let first = try await waitForPreview(model)
        try check(model.previewOffset == 0 && first.string?.contains("A1") == true, "next from the last side wraps to the first")
        model.movePreview(by: 7)
        try check(model.previewOffset == 1, "large forward steps wrap")
        model.movePreview(by: -8)
        try check(model.previewOffset == 2, "large backward steps wrap")
        model.movePreview(by: Int.max); model.movePreview(by: Int.min)
        try check(model.previewOffset == 1, "extreme steps wrap without overflow")

        try check(model.selectPreviewSide(at: 2) && model.previewOffset == 2, "a thumbnail selects its exact side")
        let exact = try await waitForPreview(model)
        try check(exact.string?.contains("A3") == true && model.previewThumbnailKey(at: 2)?.pages.map(\.page) == model.previewSide.map(\.page),
                  "the large preview shows the side of the selected thumbnail")
        try check(!model.selectPreviewSide(at: 3) && !model.selectPreviewSide(at: -1) && model.previewOffset == 2, "out-of-range sides are rejected")
        let shown = model.previewData
        model.selectPreviewSide(at: 2)
        try check(model.previewData == shown && !model.previewLoading, "selecting the current side keeps its preview")

        // Thumbnails are shared and reused while navigating.
        let a1 = try await thumbnail(model, 0)
        let renders = model.thumbnails.renderCount
        model.movePreview(by: 1); model.selectPreviewSide(at: 0)
        _ = try await thumbnail(model, 0)
        try check(model.thumbnails.renderCount == renders, "navigating reuses rendered thumbnails")
        model.setPreviewVisible(true)
        let store = model.thumbnails, a2 = model.previewThumbnailKey(at: 1)!
        async let left = store.image(for: a2)
        async let right = store.image(for: a2)
        if case .success(let one)? = await left, case .success(let two)? = await right {
            try check(one === two && model.thumbnails.renderCount == renders + 1, "two preview surfaces share one render per side")
        } else { throw PrintError.message("FAIL: shared thumbnail") }
        model.setPreviewVisible(false)

        // One side disables both directions; zero sides never index.
        model.setPageSelection(.custom("2"), for: inputs[0].id)
        _ = try await waitForPreview(model)
        let single = model.previewData
        model.movePreview(by: 1); model.movePreview(by: -1)
        try check(model.previewIndices.count == 1 && model.previewOffset == 0 && model.previewData == single && !model.previewLoading, "a single side stays put")
        model.setPageSelection(.custom("9"), for: inputs[0].id)
        model.movePreview(by: 1); model.movePreview(by: -1)
        try check(model.previewIndices.isEmpty && !model.selectPreviewSide(at: 0) && model.previewThumbnailKey(at: 0) == nil &&
                  model.previewSide(at: 0).isEmpty && model.previewSheetTitle.isEmpty, "zero sides are safe to navigate")

        // Content changes produce new thumbnails; copies reuse identical sides.
        model.setPageSelection(.all, for: inputs[0].id)
        _ = try await waitForPreview(model)
        try check(model.previewThumbnailKey(at: 0) == a1, "restoring the range finds the cached thumbnail")
        model.template.pagesPerSide = 2
        try check(model.previewThumbnailKey(at: 0) != a1 && model.previewThumbnailKey(at: 0)?.pages.map(\.page) == [0, 1], "a layout change invalidates thumbnails")
        model.setPageSelection(.custom("3, 1"), for: inputs[0].id)
        let ranged = model.previewThumbnailKey(at: 0)
        try check(ranged?.pages.map(\.page) == [0, 2], "a range change invalidates thumbnails")
        _ = try await thumbnail(model, 0)
        let before = model.thumbnails.renderCount
        model.setCopies(3, for: inputs[0].id)
        try check(model.previewIndices.count == 3 && Set((0..<3).compactMap { model.previewThumbnailKey(at: $0) }) == [ranged!], "copies reuse identical thumbnails")
        for offset in 0..<3 { _ = try await thumbnail(model, offset) }
        try check(model.thumbnails.renderCount == before, "changing copies does not re-render identical sides")
        model.inputs.append(inputs[1])
        model.selectPreview(inputs[1].id)
        let b = try await thumbnail(model, 0)
        model.remove(inputs[1].id)
        let removed = await model.thumbnails.image(for: b)
        try check(model.thumbnails.peek(b) == nil && removed == nil && model.thumbnails.peek(ranged!) != nil, "removing a PDF drops only its thumbnails")
        model.setPreviewVisible(false)
        try check(model.thumbnails.pendingCount == 0 && !model.thumbnails.isRendering, "closing the preview leaves no thumbnail work")
    }
}
