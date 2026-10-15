import AppKit
import FinderSync

@main
struct FinderExtensionChecks {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL: " + message) }
        print("PASS: " + message)
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFMe-finder-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [root.appendingPathComponent("A & B #1.pdf"), root.appendingPathComponent("学习.PDF")]
        // The extension checks selection shape; the main app validates PDF contents.
        for url in files { try Data().write(to: url) }
        let target = NSObject()
        let menu = PDFMeFinderSync.makeMenu(kind: .contextualMenuForItems, urls: files, target: target)
        check(menu?.items.count == 1 && menu?.items[0].submenu == nil, "PDF selections produce one top-level item, not a submenu")
        check(menu?.items[0].title == "Add to PDFMe Print Queue", "menu action matches the print queue")
        check(menu?.items[0].representedObject == nil, "menu does not depend on custom data surviving Finder’s process boundary")
        check(menu?.items[0].action == NSSelectorFromString("addToQueue:"), "menu uses the extension action selector")
        check(PDFMeFinderSync.makeMenu(kind: .contextualMenuForContainer, urls: files, target: target) == nil, "no action on folder background")
        check(PDFMeFinderSync.makeMenu(kind: .contextualMenuForSidebar, urls: files, target: target) == nil, "no action on sidebar")
        check(PDFMeFinderSync.makeMenu(kind: .toolbarItemMenu, urls: files, target: target) == nil, "no extra Finder toolbar menu")
        check(!FinderSelection.accepts([]), "empty selections rejected")
        check(!FinderSelection.accepts(files + [root.appendingPathComponent("Word.docx")]), "mixed selections rejected")
        check(!FinderSelection.accepts([URL(string: "https://example.com/file.pdf")!]), "remote URLs rejected")
        let directory = root.appendingPathComponent("Folder.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        check(!FinderSelection.accepts([URL(fileURLWithPath: directory.path, isDirectory: false)]), "folders with a PDF suffix rejected")
        let app = URL(fileURLWithPath: "/Applications/PDFMe.app")
        check(FinderSelection.containingApp(for: app.appendingPathComponent("Contents/PlugIns/PDFMeFinder.appex")) == app, "delivery targets this extension’s containing app")
        check(FinderSelection.containingApp(for: root.appendingPathComponent("PDFMeFinder.appex")) == nil, "unexpected bundle layouts do not target arbitrary apps")
        let finder = PDFMeFinderSync(monitorFolders: false)
        finder.extensionURL = app.appendingPathComponent("Contents/PlugIns/PDFMeFinder.appex")
        var selection = files
        finder.selectedURLs = { selection }
        var opened: [URL] = []; var destination: URL?; var failures: [String] = []
        finder.openDocuments = { urls, app, completion in opened = urls; destination = app; completion(nil) }
        finder.reportError = { failures.append($0) }
        // Reproduce Finder's reconstructed sender: title and selector, no representedObject.
        let sender = NSMenuItem(title: "Add to PDFMe Print Queue", action: NSSelectorFromString("addToQueue:"), keyEquivalent: "")
        _ = finder.perform(sender.action!, with: sender)
        check(opened == files && destination == app && failures.isEmpty, "actual Finder action hands off multiple PDFs when sender metadata is absent")
        selection = [files[1]]; opened = []
        sender.representedObject = [root.appendingPathComponent("stale.pdf")]
        _ = finder.perform(sender.action!, with: sender)
        check(opened == [files[1]], "action reads the current Finder selection instead of stale menu data")
        selection = []; opened = []
        _ = finder.perform(sender.action!, with: sender)
        check(opened.isEmpty && failures.count == 1, "missing selection reports an error instead of silently returning")
        selection = files
        finder.openDocuments = { _, _, completion in completion(NSError(domain: "Synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic handoff failure"])) }
        _ = finder.perform(sender.action!, with: sender)
        check(failures.last == "Synthetic handoff failure", "Launch Services failures are surfaced without retrying")
        print("All Finder extension checks passed. No apps opened and no jobs submitted.")
    }
}
