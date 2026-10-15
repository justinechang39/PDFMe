import AppKit
import PDFMeCore

/// macOS launches PDFMe for this service if needed. No print action is called here.
@MainActor
final class FinderPrintService: NSObject {
    var receive: (([URL]) -> Void)?
    @objc(addToPrintQueue:userData:error:)
    func addToPrintQueue(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        do { receive?(try Self.fileURLs(from: pasteboard)) }
        catch let failure { error.pointee = failure.localizedDescription as NSString }
    }
    static func fileURLs(from pasteboard: NSPasteboard) throws -> [URL] {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        guard !urls.isEmpty, urls.allSatisfy({ $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }) else {
            throw PrintError.message("Select one or more PDF files in Finder.")
        }
        return urls
    }
}
