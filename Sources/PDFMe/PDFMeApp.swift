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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var previewWindow: NSWindow?
    var dropView: StatusDropView!
    var printWindow: NSWindow?
    let finderService = FinderPrintService()
    private var receivedFilesAtLaunch = false


    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(printWindow == nil ? .accessory : .regular)
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
        model.panelSizeChanged = { [weak self] in
            guard let self else { return }
            self.popover.contentSize = self.model.panelSize
            self.previewWindow?.setContentSize(self.model.panelSize)
        }
        model.openPrintWindow = { [weak self] in self?.showPrintWindow(selectPrimary: true) }
        finderService.receive = { [weak self] urls in
            guard let self else { return }
            self.receivedFilesAtLaunch = true
            self.showPrintWindow()
            self.model.printQueue.accept(urls)
        }
        NSApp.servicesProvider = finderService
        NSUpdateDynamicServices()
        installMenu()
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
        } else if CommandLine.arguments.contains("--print-queue") {
            showPrintWindow()
        } else if !LoginItem.launchedAtLogin && !receivedFilesAtLaunch {
            showPopover()
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshLoginItem() }
    func applicationWillTerminate(_ notification: Notification) { model.printQueue.cleanup() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy || model.printQueue.occupied else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Work is still in progress"
        alert.informativeText = "Wait for the current operation to finish. To stop a multi-group batch, use Stop after this group in the Print Queue."
        alert.addButton(withTitle: "Keep PDFMe open")
        alert.runModal()
        return .terminateCancel
    }
    @objc func openQueueMenu() { showPrintWindow() }
    func showPrintWindow(selectPrimary: Bool = false) {
        popover.performClose(nil)
        if selectPrimary { model.printQueue.selectedID = model.printQueue.groups[0].id }
        NSApp.setActivationPolicy(.regular)
        if printWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 780),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "PDFMe — Print Queue"
            window.contentMinSize = NSSize(width: 940, height: 610)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: PrintQueueView(queue: model.printQueue, showMini: { [weak self] in self?.showPopover() }))
            window.center()
            window.setFrameAutosaveName("PDFMePrintQueue")
            printWindow = window
        }
        printWindow?.deminiaturize(nil)
        printWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === printWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
    func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "PDFMe")
        appMenu.addItem(withTitle: "About PDFMe", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenu(); let serviceItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        serviceItem.submenu = services; appMenu.addItem(serviceItem); NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide PDFMe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit PDFMe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let fileItem = NSMenuItem(); let fileMenu = NSMenu(title: "File")
        let queueItem = NSMenuItem(title: "Print Queue", action: #selector(openQueueMenu), keyEquivalent: "1")
        queueItem.target = self; fileMenu.addItem(queueItem)
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu; menu.addItem(fileItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem)
        let windowItem = NSMenuItem(); let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu; menu.addItem(windowItem); NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }
    func toggle() { if popover.isShown { popover.performClose(nil) } else { showPopover() } }
    func showPopover() {
        guard let button = statusItem?.button else { return }
        model.refreshEngine()
        model.refreshLoginItem()
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        receivedFilesAtLaunch = true
        if !urls.isEmpty && urls.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) {
            showPrintWindow(); model.printQueue.accept(urls)
        } else { model.route(urls) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPrintWindow(); return true }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            if response.notification.request.content.title == "Print job submitted" { self.showPrintWindow() }
            else { self.showPopover() }
        }
        completionHandler()
    }
}

@main
struct PDFMeApp {
    @MainActor
    static func main() {
        if LoginItem.handleCommandLine() { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
