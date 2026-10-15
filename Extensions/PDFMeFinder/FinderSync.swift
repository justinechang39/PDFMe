import AppKit
import FinderSync
import OSLog

@objc(PDFMeFinderSync)
final class PDFMeFinderSync: FIFinderSync {
    private static let logger = Logger(subsystem: "io.github.justinechang39.PDFMe.Finder", category: "Queue handoff")
    // Injectable boundaries let checks invoke the actual Objective-C menu action
    // with a reconstructed sender, without opening documents or using Finder UI.
    var selectedURLs: () -> [URL] = { FIFinderSyncController.default().selectedItemURLs() ?? [] }
    var sendToService: ([URL]) -> Bool = { FinderServiceHandoff.send($0) }
    var reportError: (String) -> Void = { message in
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Couldn’t add PDFs to PDFMe"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    override convenience init() { self.init(monitorFolders: true) }
    init(monitorFolders: Bool) {
        super.init()
        if monitorFolders {
            // Finder supplies callbacks for browsed folders; no crawling or badges.
            FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        Self.makeMenu(kind: menuKind, urls: selectedURLs(), target: self)
    }

    static func makeMenu(kind: FIMenuKind, urls: [URL], target: AnyObject) -> NSMenu? {
        guard kind == .contextualMenuForItems, FinderSelection.accepts(urls) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Add to PDFMe Print Queue", action: #selector(addToQueue(_:)), keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: "printer", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    @objc private func addToQueue(_ sender: NSMenuItem) {
        // Finder reconstructs the sender across processes. Its representedObject
        // cannot carry our URLs. Query the controller inside the action instead.
        let urls = selectedURLs()
        Self.logger.notice("Queue action received with \(urls.count) selected items")
        guard FinderSelection.accepts(urls) else {
            reportError("Select one or more PDF files in Finder and try again.")
            return
        }
        if sendToService(urls) {
            Self.logger.notice("PDFMe print service accepted the queue handoff")
        } else {
            Self.logger.error("PDFMe print service did not accept the handoff")
            reportError("Couldn’t reach PDFMe’s print service. Open PDFMe and try again, or use Services → Add to PDFMe Print Queue.")
        }
    }
}
