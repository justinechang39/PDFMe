import AppKit

/// Finder selection URLs do not themselves grant the extension file access.
/// Send only their paths to PDFMe's existing service; the app opens the PDFs
/// under its own permissions, exactly as for the working Services menu action.
enum FinderServiceHandoff {
    static func send(_ urls: [URL], serviceName: String = "Add to PDFMe Print Queue") -> Bool {
        guard FinderSelection.accepts(urls) else { return false }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([NSPasteboard.PasteboardType("NSFilenamesPboardType")], owner: nil)
        guard pasteboard.setPropertyList(urls.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) else { return false }
        return NSPerformService(serviceName, pasteboard)
    }
}
