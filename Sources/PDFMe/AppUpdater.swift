import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns download verification and installation. PDFMe owns the work-safety gate.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, NSMenuItemValidation {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticUpdates = false
    @Published private(set) var message: String?
    private(set) var isInstalling = false
    var hasUnfinishedWork: () -> Bool = { false }
    private var observations: [NSKeyValueObservation] = []
    private(set) lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    func start() {
        let updater = controller.updater
        do { try updater.start() }
        catch { message = "Updates unavailable: \(error.localizedDescription)"; return }
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshPreferences() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshPreferences() }
            }
        ]
    }
    private func refreshPreferences() {
        automaticUpdates = controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates
    }
    func setAutomaticUpdates(_ enabled: Bool) {
        // Sparkle ignores enabling downloads until automatic checking is enabled.
        if enabled {
            controller.updater.automaticallyChecksForUpdates = true
            controller.updater.automaticallyDownloadsUpdates = true
        } else {
            controller.updater.automaticallyDownloadsUpdates = false
            controller.updater.automaticallyChecksForUpdates = false
        }
        refreshPreferences()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { controller.updater.canCheckForUpdates }
    @objc func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else { return }
        message = nil
        controller.checkForUpdates(nil)
    }
    private func requireIdle() throws {
        guard !hasUnfinishedWork() else {
            throw NSError(domain: "PDFMe.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Finish or clear queued documents before updating PDFMe."])
        }
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws { try requireIdle() }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws { try requireIdle() }
    // Checked again after download: documents may have been added since the update check.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard !hasUnfinishedWork() else {
            message = "Update postponed. Finish or clear queued documents, then check for updates again."
            return false
        }
        return true
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { isInstalling = true }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) { isInstalling = false }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Automatic updates", isOn: Binding(get: { updater.automaticUpdates }, set: updater.setAutomaticUpdates))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text("Download verified updates from GitHub. Installs when PDFMe quits; queued work is protected.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Check for Updates…", action: updater.checkForUpdates).controlSize(.small).disabled(!updater.canCheck)
            if let message = updater.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }
}
