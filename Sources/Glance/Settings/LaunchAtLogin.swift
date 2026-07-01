import ServiceManagement
import Foundation

/// FR18: launch-at-login via SMAppService (macOS 13+). No login-item helper
/// bundle needed for the main app registration.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Glance: launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }
}
