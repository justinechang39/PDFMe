import AppKit
import PDFKit

@MainActor
final class Receiver: NSObject, NSApplicationDelegate {
    let service = FinderPrintService()
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    func applicationDidFinishLaunching(_ notification: Notification) {
        service.receive = { urls in
            let valid = urls.count == 2 && urls.allSatisfy { (PDFDocument(url: $0)?.pageCount ?? 0) > 0 }
            try! JSONSerialization.data(withJSONObject: ["valid": valid, "paths": urls.map(\.path)]).write(to: self.root.appendingPathComponent("received.json"))
        }
        NSApp.servicesProvider = service
        NSUpdateDynamicServices()
        for name in ["Sample A & B.pdf", "学习.PDF"] {
            let url = root.appendingPathComponent(name)
            var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
            let context = CGContext(url as CFURL, mediaBox: &bounds, nil)!
            context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        }
        try! Data().write(to: root.appendingPathComponent("ready"))
    }
}
@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Receiver(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
