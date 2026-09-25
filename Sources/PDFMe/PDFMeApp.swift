import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class StatusDropView: NSView {
    var clicked: (() -> Void)?
    var dropped: (([URL]) -> Void)?
    var highlighted = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("PDFMe, create or print PDF")
        toolTip = "PDFMe — drop DOCX to convert or PDF to print"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }
    override func mouseDown(with event: NSEvent) { clicked?() }
    override func accessibilityPerformPress() -> Bool { clicked?(); return true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { highlighted = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        dropped?(urls)
        return !urls.isEmpty
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var previewWindow: NSWindow?
    var dropView: StatusDropView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: 34)
        statusItem.autosaveName = "PDFMe"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.badge.arrow.up", accessibilityDescription: "PDFMe")
            button.image?.isTemplate = true
            dropView = StatusDropView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            button.addSubview(dropView)
            dropView.clicked = { [weak self] in self?.toggle() }
            dropView.dropped = { [weak self] urls in self?.model.route(urls) }
        }
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 700)
        popover.contentViewController = NSHostingController(rootView: ContentView(model: model))
        model.show = { [weak self] in self?.showPopover() }
        model.printing.show = { [weak self] in
            self?.model.printingMode = true; self?.model.settings = false; self?.showPopover()
        }
        model.progressChanged = { [weak self] busy in
            self?.statusItem.button?.image = NSImage(systemSymbolName: busy ? "doc.badge.clock" : "doc.badge.arrow.up", accessibilityDescription: busy ? "PDFMe is converting" : "PDFMe")
            self?.statusItem.button?.image?.isTemplate = true
        }
        if CommandLine.arguments.contains("--preview") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "PDFMe"
            window.contentView = NSHostingView(rootView: ContentView(model: model))
            window.center(); window.makeKeyAndOrderFront(nil)
            previewWindow = window
            NSApp.activate(ignoringOtherApps: true)
        } else {
            showPopover()
        }
    }
    func applicationWillTerminate(_ notification: Notification) { model.printing.cleanup() }
    func toggle() { if popover.isShown { popover.performClose(nil) } else { showPopover() } }
    func showPopover() {
        guard let button = statusItem?.button else { return }
        model.refreshEngine()
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        model.route(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.showPopover() }
        completionHandler()
    }
}

@main
struct PDFMeApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
