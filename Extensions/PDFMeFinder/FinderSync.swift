import AppKit
import FinderSync

@objc(PDFMeFinderSync)
final class PDFMeFinderSync: FIFinderSync {
    override init() {
        super.init()
        // Finder supplies menu callbacks for browsed folders. No crawling, badges,
        // file observers, or background PDF processing takes place in this extension.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        Self.makeMenu(kind: menuKind, urls: FIFinderSyncController.default().selectedItemURLs() ?? [], target: self)
    }

    static func makeMenu(kind: FIMenuKind, urls: [URL], target: AnyObject) -> NSMenu? {
        guard kind == .contextualMenuForItems, FinderSelection.accepts(urls) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Add to PDFMe Print Queue", action: #selector(addToQueue(_:)), keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: "printer", accessibilityDescription: nil)
        item.representedObject = urls
        menu.addItem(item)
        return menu
    }

    @objc private func addToQueue(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], FinderSelection.accepts(urls),
              let app = FinderSelection.containingApp(for: Bundle.main.bundleURL) else { return }
        // Document URLs are handed to the containing app through Launch Services.
        // No shell, command-line arguments, shared files, or printer access is needed.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn’t open PDFMe"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}
