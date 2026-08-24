import Foundation
import ServiceManagement

/// Registers/unregisters the app as a login item using SMAppService
/// (macOS 13+). Requires the app to be running from a proper .app bundle
/// (see Scripts/build_app.sh) — it has no effect for a bare `swift run`
/// binary since there is no bundle identifier to register.
enum LoginItemManager {

    static var isEnabled: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status == .enabled { return }
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Tide: failed to update login item: \(error)")
            }
        }
    }
}
