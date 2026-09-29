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
        model.template = PrintTemplate(orientation: .landscape, duplex: .shortEdge, pagesPerSide: 2)
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
        model.setPreviewVisible(false)
        print("All preview state checks passed. No print jobs submitted.")
    }
}
