import Foundation

/// Locks the screen straight away — the Keyboard pane's Lock Screen action.
///
/// SACLockScreenImmediate, in the private login.framework, locks at once and
/// needs no permission; it's what lock-screen utilities generally call. Being
/// private, it's looked up at run time rather than linked, so a macOS that
/// drops it costs the action, not the app: Tide then puts the display to
/// sleep instead, which locks too wherever a password is required on wake.
enum ScreenLocker {

    static func lock() {
        if let lockImmediately {
            _ = lockImmediately()
            return
        }
        NSLog("Tide: SACLockScreenImmediate unavailable; sleeping the display instead")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    private typealias LockFunction = @convention(c) () -> Int32

    private static let lockImmediately: LockFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()
}
