import CoreGraphics
import Foundation

/// Brightness control for the built-in laptop panel, which has no DDC at
/// all — its backlight is driven by the display pipeline directly.
///
/// The only APIs that reach it are private:
/// `DisplayServicesSetBrightness` (what Apple's own brightness keys and
/// Control Center use) with `CoreDisplay_Display_SetUserBrightness` as a
/// second try. Both are resolved with dlsym, so a future macOS that drops
/// them degrades to "no built-in slider" instead of failing to launch.
enum BuiltInBrightness {

    /// Whether this display can be driven at all. False on machines with
    /// no built-in panel, or if the private symbols have gone away.
    static func isSupported(displayID: CGDirectDisplayID) -> Bool {
        guard let symbols = Symbols.shared else { return false }
        if let canChange = symbols.canChangeBrightness, canChange(displayID) { return true }
        // `DisplayServicesCanChangeBrightness` is itself optional, and it
        // answers false on some Apple Silicon panels that nonetheless
        // accept writes — so a successful read is accepted as proof too.
        return get(displayID: displayID) != nil
    }

    /// Current brightness as 0…1, or nil if neither API answers.
    static func get(displayID: CGDirectDisplayID) -> Float? {
        guard let symbols = Symbols.shared else { return nil }

        if let getBrightness = symbols.getBrightness {
            var value: Float = 0
            if getBrightness(displayID, &value) == KERN_SUCCESS, value.isFinite, value >= 0 {
                return min(value, 1)
            }
        }
        if let getUserBrightness = symbols.getUserBrightness {
            let value = getUserBrightness(displayID)
            if value.isFinite, value >= 0 { return Float(min(value, 1)) }
        }
        return nil
    }

    @discardableResult
    static func set(displayID: CGDirectDisplayID, brightness: Float) -> Bool {
        guard let symbols = Symbols.shared else { return false }
        let clamped = min(max(brightness, 0), 1)

        if let setBrightness = symbols.setBrightness, setBrightness(displayID, clamped) == KERN_SUCCESS {
            return true
        }
        if let setUserBrightness = symbols.setUserBrightness {
            setUserBrightness(displayID, Double(clamped))
            return true
        }
        return false
    }

    // MARK: - Private symbols

    private final class Symbols {

        typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
        typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
        typealias GetUserBrightness = @convention(c) (CGDirectDisplayID) -> Double
        typealias SetUserBrightness = @convention(c) (CGDirectDisplayID, Double) -> Void

        let getBrightness: GetBrightness?
        let setBrightness: SetBrightness?
        let canChangeBrightness: CanChangeBrightness?
        let getUserBrightness: GetUserBrightness?
        let setUserBrightness: SetUserBrightness?

        static let shared: Symbols? = Symbols()

        private init?() {
            let displayServices = dlopen(
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
            )
            let coreDisplay = dlopen(
                "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY
            )

            getBrightness = displayServices
                .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
                .map { unsafeBitCast($0, to: GetBrightness.self) }
            setBrightness = displayServices
                .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
                .map { unsafeBitCast($0, to: SetBrightness.self) }
            canChangeBrightness = displayServices
                .flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }
                .map { unsafeBitCast($0, to: CanChangeBrightness.self) }
            getUserBrightness = coreDisplay
                .flatMap { dlsym($0, "CoreDisplay_Display_GetUserBrightness") }
                .map { unsafeBitCast($0, to: GetUserBrightness.self) }
            setUserBrightness = coreDisplay
                .flatMap { dlsym($0, "CoreDisplay_Display_SetUserBrightness") }
                .map { unsafeBitCast($0, to: SetUserBrightness.self) }

            guard setBrightness != nil || setUserBrightness != nil else {
                NSLog("Tide: built-in brightness unavailable (no private symbols found)")
                return nil
            }
        }
    }
}
