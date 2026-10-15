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
        check(menu?.items[0].representedObject as? [URL] == files, "multiple file URLs and Unicode names are preserved without shell encoding")
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
        print("All Finder extension checks passed. No apps opened and no jobs submitted.")
    }
}
