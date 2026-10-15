import AppKit
@MainActor
final class Probe: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let files = [root.appendingPathComponent("Sample A & B.pdf"), root.appendingPathComponent("学习.PDF")]
        guard (try? Data(contentsOf: files[0])) == nil else { print("FAIL: probe is not sandbox restricted"); exit(2) }
        print("PASS: sandbox prevents probe from reading the PDFs")
        let sent = FinderServiceHandoff.send(files, serviceName: CommandLine.arguments[2])
        print(sent ? "PASS: real sandboxed Services handoff succeeded" : "FAIL: Services handoff failed")
        exit(sent ? 0 : 3)
    }
}
@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let probe=Probe();app.delegate=probe
        withExtendedLifetime(probe) { app.run() }
    }
}
