import AppKit
import ServiceManagement

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
        } else if status == .enabled || status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    static var statusDescription: String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "disabled"
        case .requiresApproval: return "requires approval in System Settings > General > Login Items"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        let source = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        return source == keyAELaunchedAsLogInItem || source == keyAELaunchedAsServiceItem
    }

    /// Operate from the installed app bundle without opening the interface.
    static func handleCommandLine() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.contains("--enable-start-at-login") || arguments.contains("--disable-start-at-login") || arguments.contains("--login-item-status") else { return false }
        do {
            if arguments.contains("--enable-start-at-login") { try setEnabled(true) }
            else if arguments.contains("--disable-start-at-login") { try setEnabled(false) }
            print("Start at login: \(statusDescription)")
        } catch {
            FileHandle.standardError.write(Data("Start at login: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        return true
    }
}
