import ApplicationServices
import CoreGraphics
import Foundation

/// Gives the mouse and the trackpad independent scroll directions.
///
/// macOS has a single system-wide "Natural scrolling" switch shared by
/// every pointing device, so tuning it for the trackpad leaves the mouse
/// inverted (and vice versa). This taps scroll events before they reach
/// apps, works out whether each one came from a mouse or a trackpad (see
/// ScrollDeviceRegistry), and flips the vertical delta for whichever class
/// the user asked to reverse — leaving the system setting to keep driving
/// the other one.
///
/// Only the vertical axis is touched: horizontal deltas feed swipe-style
/// navigation gestures, which stay consistent with the system setting.
final class ScrollDirectionManager {

    enum StartResult {
        /// The tap is installed and reversing scroll events.
        case running
        /// Nothing to do — the feature (or every per-device toggle) is off.
        case disabled
        /// Enabled, but the app isn't trusted for Accessibility yet, so no
        /// tap could be created. Polls in the background and starts by
        /// itself once permission is granted.
        case needsAccessibility
    }

    /// The IORegistry entry ID of the device that produced an event. Not
    /// in CoreGraphics' public CGEventField list, but long-standing and
    /// what every per-device scroll utility relies on.
    private static let senderIDField = CGEventField(rawValue: 87)!

    /// `TIDE_SCROLL_DEBUG=1 /Applications/Tide.app/Contents/MacOS/Tide`
    /// logs how each scroll event was classified — the one thing worth
    /// seeing when a device gets reversed the wrong way.
    private static let isDebugLoggingEnabled = ProcessInfo.processInfo.environment["TIDE_SCROLL_DEBUG"] == "1"

    private let deviceRegistry = ScrollDeviceRegistry()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionPollTimer: Timer?

    var isRunning: Bool { eventTap != nil }

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Fired (once) when the app IS trusted for Accessibility but the tap
    /// still can't be created — the case where macOS only hands the
    /// running process its new privilege after a relaunch.
    var onTapCreationFailedWhileTrusted: (() -> Void)?

    private var hasReportedTapFailureWhileTrusted = false

    /// Fired when the tap actually starts, including the delayed start
    /// after permission is granted from System Settings — the Settings
    /// window uses it to update its status line while it stays open.
    var onStarted: (() -> Void)?

    /// Brings the tap in line with the current ScrollSettingsStore values.
    /// Safe to call repeatedly — at launch, and after every settings
    /// change.
    @discardableResult
    func apply() -> StartResult {
        guard ScrollSettingsStore.isActive else {
            stop()
            return .disabled
        }
        if isRunning {
            return .running
        }
        guard AXIsProcessTrusted() else {
            startPermissionPolling()
            return .needsAccessibility
        }
        return start() ? .running : .needsAccessibility
    }

    /// Shows the system's own "grant Accessibility access" prompt. Kept
    /// separate from `apply()` so a settings toggle can ask for permission
    /// explicitly, while launch-time startup stays silent.
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<ScrollDirectionManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Tide: could not create scroll event tap (Accessibility permission missing?)")
            startPermissionPolling()
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        hasReportedTapFailureWhileTrusted = false
        stopPermissionPolling()
        onStarted?()
        return true
    }

    private func stop() {
        stopPermissionPolling()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Permission is granted in System Settings, outside the app, with no
    /// notification when it lands — so once the user has turned the
    /// feature on, quietly retry until the tap can actually be created.
    private func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard ScrollSettingsStore.isActive else {
                self.stop()
                return
            }
            guard AXIsProcessTrusted() else { return }
            if self.start() { return }
            // Trusted, yet the tap was refused: nothing more polling can
            // do, only a relaunch will pick the privilege up.
            guard !self.hasReportedTapFailureWhileTrusted else { return }
            self.hasReportedTapFailureWhileTrusted = true
            self.onTapCreationFailedWhileTrusted?()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long (or on some user
        // input events); re-enabling is the standard recovery, otherwise
        // scrolling silently stops being reversed until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .scrollWheel, ScrollSettingsStore.isActive else {
            return Unmanaged.passUnretained(event)
        }

        let category = deviceCategory(for: event)
        let shouldReverse: Bool
        switch category {
        case .mouse: shouldReverse = ScrollSettingsStore.reverseMouse
        case .trackpad: shouldReverse = ScrollSettingsStore.reverseTrackpad
        }

        if Self.isDebugLoggingEnabled {
            NSLog("Tide scroll: sender=\(event.getIntegerValueField(Self.senderIDField)) continuous=\(event.getIntegerValueField(.scrollWheelEventIsContinuous)) category=\(category) reversed=\(shouldReverse)")
        }

        if shouldReverse {
            reverseVertical(event)
        }
        return Unmanaged.passUnretained(event)
    }

    /// Registry lookup first (the only way to separate a Magic Mouse from
    /// a trackpad), then the classic fallback: a plain wheel mouse sends
    /// line-based, non-continuous deltas, everything else is a precision
    /// pointing surface.
    private func deviceCategory(for event: CGEvent) -> ScrollDeviceRegistry.Category {
        let senderID = UInt64(bitPattern: Int64(event.getIntegerValueField(Self.senderIDField)))
        if let known = deviceRegistry.category(forSenderID: senderID) {
            return known
        }
        return event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 ? .mouse : .trackpad
    }

    /// All three vertical representations are carried independently in a
    /// scroll event (line, fixed-point, and pixel deltas) and different
    /// apps read different ones, so flipping only one leaves scrolling
    /// inconsistent between apps.
    private func reverseVertical(_ event: CGEvent) {
        let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let fixedPoint = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let pixels = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -line)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedPoint)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pixels)
    }
}
