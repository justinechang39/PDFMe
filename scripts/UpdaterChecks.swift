import AppKit
import Sparkle

@main
struct UpdaterChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let model = AppUpdater()
        model.start()
        precondition(model.message == nil, "Packaged updater configuration must initialize")
        let updater = model.controller.updater
        for selector in ["updater:mayPerformUpdateCheck:error:", "updater:shouldProceedWithUpdate:updateCheck:error:",
                         "updaterShouldRelaunchApplication:", "updater:willInstallUpdate:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:"] {
            precondition(model.responds(to: NSSelectorFromString(selector)), "Sparkle must actually call the safety delegate: " + selector)
        }
        precondition(updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates)
        model.setAutomaticUpdates(false)
        precondition(!updater.automaticallyChecksForUpdates && !updater.automaticallyDownloadsUpdates)
        model.setAutomaticUpdates(true)
        precondition(model.automaticUpdates)
        print("PASS: bundled updater starts with signed-feed configuration and automatic updates can be disabled")
        let item = SUAppcastItem(dictionary: ["title": "Test", "sparkle:version": "14",
            "enclosure": ["url": "https://example.invalid/update.zip", "sparkle:version": "14", "length": "100"]])!
        for pending in [false, true] {
            model.hasUnfinishedWork = { pending }
            do {
                try model.updater(updater, mayPerform: .updates)
                precondition(!pending)
            } catch { precondition(pending) }
            do {
                try model.updater(updater, shouldProceedWithUpdate: item, updateCheck: .updates)
                precondition(!pending)
            } catch { precondition(pending) }
            precondition(model.updaterShouldRelaunchApplication(updater) == !pending)
        }
        // New work after a download must still prevent relaunch.
        model.hasUnfinishedWork = { false }
        try model.updater(updater, mayPerform: .updates)
        model.hasUnfinishedWork = { true }
        precondition(!model.updaterShouldRelaunchApplication(updater))
        precondition(model.message?.contains("postponed") == true)
        model.updater(updater, willInstallUpdate: item)
        precondition(model.isInstalling)
        model.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
        precondition(!model.isInstalling)
        precondition(model.allowedSystemProfileKeys(for: updater) == [])
        print("PASS: queued/active work blocks checking, proceeding and relaunch, including work added after download")
        print("PASS: installation state resets and system profile sharing is disabled")
    }
}
