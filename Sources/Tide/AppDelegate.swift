import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var updateTimer: Timer?
    private var networkInfoItem: NSMenuItem!
    private var publicNetworkInfo: PublicNetworkInfo.Info?
    private var isFetchingPublicNetworkInfo = false
    private var captureMenuItems: [ShortcutAction: NSMenuItem] = [:]

    private let networkMonitor = NetworkMonitor()
    private let screenshotManager = ScreenshotManager()
    private lazy var captureSound = Bundle.main.url(forResource: "CaptureSound", withExtension: "mp3")
        .flatMap { NSSound(contentsOf: $0, byReference: true) }

    private let hotKeyManager = HotKeyManager.shared
    private var hotKeyIDs: [ShortcutAction: UInt32] = [:]
    private var settingsWindowController: SettingsWindowController?

    // Small per-line font so two stacked lines still fit the menu bar's height.
    private lazy var statusFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    private lazy var lastSpeedImage = Self.placeholderImage(font: statusFont)
    private var isShowingCaptureFeedback = false
    private var feedbackResetWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = lastSpeedImage
        statusItem.button?.imagePosition = .imageOnly

        statusItem.menu = buildMenu()

        for action in ShortcutAction.allCases {
            registerHotKey(for: action)
        }

        // First poll establishes the baseline sample; the first real
        // reading appears one refreshInterval later.
        networkMonitor.poll()
        restartUpdateTimer()

        // Delayed slightly so it never competes with app launch for the
        // network stack; silent unless a newer version is actually found.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkForUpdates(silent: true)
        }

        // Pre-warm the settings window off the critical launch path so
        // its real (and currently somewhat expensive) construction work
        // happens here instead of as a visible hitch the first time the
        // user actually opens Settings. Building it doesn't show it —
        // NSWindow stays offscreen until something orders it front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.makeSettingsWindowControllerIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let info = publicNetworkInfo {
            applyPublicNetworkInfo(info)
        } else if !isFetchingPublicNetworkInfo {
            fetchPublicNetworkInfo()
        }
    }

    /// Looked up once per launch (see PublicNetworkInfo for why) and cached;
    /// retried on the next menu open only if the previous attempt failed.
    private func fetchPublicNetworkInfo() {
        isFetchingPublicNetworkInfo = true
        networkInfoItem.title = "Looking up…"

        PublicNetworkInfo.fetch { [weak self] info in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetchingPublicNetworkInfo = false
                self.publicNetworkInfo = info
                if let info {
                    self.applyPublicNetworkInfo(info)
                } else {
                    self.networkInfoItem.title = "Unavailable"
                }
            }
        }
    }

    /// "{ISP name} {public IP}", e.g. "VNPT Corp 14.161.12.83".
    private func applyPublicNetworkInfo(_ info: PublicNetworkInfo.Info) {
        let isp = info.ispName ?? "Unknown ISP"
        networkInfoItem.title = "\(isp) \(info.ip)"
    }

    /// (Re)creates the polling timer at SpeedMeterSettingsStore's current
    /// refreshInterval. Called at launch and again whenever the Speed
    /// Meter settings pane changes that interval, since a running Timer's
    /// own interval can't be changed in place.
    private func restartUpdateTimer() {
        updateTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: SpeedMeterSettingsStore.refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshSpeed()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    /// Called after any Speed Meter setting changes (from the Settings
    /// window) to apply it immediately rather than waiting for the next
    /// scheduled poll.
    private func applySpeedMeterSettingsChange() {
        restartUpdateTimer()
        refreshSpeed()
    }

    private func refreshSpeed() {
        guard let sample = networkMonitor.poll() else { return }

        let showUpload = SpeedMeterSettingsStore.showUpload
        let showDownload = SpeedMeterSettingsStore.showDownload
        guard SpeedMeterSettingsStore.isEnabled, showUpload || showDownload else {
            lastSpeedImage = Self.placeholderImage(font: statusFont)
            guard !isShowingCaptureFeedback else { return }
            statusItem.button?.image = lastSpeedImage
            return
        }

        let unit = SpeedMeterSettingsStore.unit
        var lines: [(icon: String, value: String)] = []
        if showUpload {
            lines.append(("↑", SpeedFormatter.format(bytesPerSecond: sample.uploadBytesPerSecond, unit: unit)))
        }
        if showDownload {
            lines.append(("↓", SpeedFormatter.format(bytesPerSecond: sample.downloadBytesPerSecond, unit: unit)))
        }
        lastSpeedImage = Self.stackedImage(lines: lines, font: statusFont)

        // Don't stomp on the capture confirmation while it's showing.
        guard !isShowingCaptureFeedback else { return }
        statusItem.button?.image = lastSpeedImage
    }

    /// A static bolt glyph shown instead of live numbers when the speed
    /// meter is off (or both its lines are hidden) — the menu bar item
    /// itself always stays, since it's the only way to reach the app.
    private static func placeholderImage(font: NSFont) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Tide")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// Draws 1 or 2 stacked "{icon} {value}" lines as a single template
    /// image: arrow icons fixed on the left, values right-aligned to a
    /// shared right edge so the digits don't jump around as their width
    /// changes. NSButton's automatic title layout doesn't reliably center
    /// a two-line NSAttributedString within the menu bar's fixed row
    /// height either (it clips the top and bottom), so the whole thing is
    /// rasterized by hand instead.
    private static func stackedImage(lines: [(icon: String, value: String)], font: NSFont) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let rendered = lines.map { line in
            (
                icon: NSAttributedString(string: line.icon, attributes: attributes),
                value: NSAttributedString(string: " \(line.value)", attributes: attributes)
            )
        }
        guard !rendered.isEmpty else { return NSImage() }

        let iconWidth = ceil(rendered.map { $0.icon.size().width }.max() ?? 0)
        let valueWidth = ceil(rendered.map { $0.value.size().width }.max() ?? 0)
        let lineHeight = ceil(rendered.map { $0.icon.size().height }.max() ?? 0)
        let height = lineHeight * CGFloat(rendered.count)

        let image = NSImage(size: NSSize(width: iconWidth + valueWidth, height: height))
        image.lockFocus()
        for (index, line) in rendered.enumerated() {
            // Top line first: AppKit's y grows upward, so line 0 sits at
            // the highest y and later lines descend from there.
            let y = height - CGFloat(index + 1) * lineHeight
            line.icon.draw(at: NSPoint(x: 0, y: y))
            line.value.draw(at: NSPoint(x: iconWidth + (valueWidth - line.value.size().width), y: y))
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        networkInfoItem = makeItem("—", action: nil, symbol: "network")
        networkInfoItem.isEnabled = false
        menu.addItem(networkInfoItem)

        menu.addItem(.separator())

        let screenshotHeader = NSMenuItem(title: "Screenshot", action: nil, keyEquivalent: "")
        screenshotHeader.isEnabled = false
        menu.addItem(screenshotHeader)

        let selectedAreaItem = makeCaptureItem(.selectedArea, symbol: "crop")
        let windowItem = makeCaptureItem(.window, symbol: "macwindow")
        let fullScreenItem = makeCaptureItem(.fullScreen, symbol: "rectangle.dashed")
        captureMenuItems = [.selectedArea: selectedAreaItem, .window: windowItem, .fullScreen: fullScreenItem]
        menu.addItem(selectedAreaItem)
        menu.addItem(windowItem)
        menu.addItem(fullScreenItem)

        menu.addItem(.separator())

        menu.addItem(makeItem("Settings…", action: #selector(openSettingsWindow), key: ",", symbol: "gearshape"))

        menu.addItem(.separator())
        // Default keyEquivalentModifierMask is .command, so this reads as Cmd+Q.
        menu.addItem(makeItem("Quit Tide", action: #selector(quit), key: "q", symbol: "xmark.circle"))

        refreshShortcutMenuItems()
        return menu
    }

    /// Shows each capture action's currently assigned shortcut as the
    /// standard macOS key-equivalent hint on its menu item (e.g. "⌃⇧4").
    /// Purely cosmetic — the item still fires the same action either way,
    /// and the real global trigger is HotKeyManager's Carbon registration.
    private func refreshShortcutMenuItems() {
        for (action, item) in captureMenuItems {
            guard let combo = ShortcutStore.combo(for: action),
                  let character = combo.menuEquivalentCharacter
            else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                continue
            }
            item.keyEquivalent = character
            item.keyEquivalentModifierMask = combo.modifierFlags.intersection(.deviceIndependentFlagsMask)
        }
    }

    private func makeItem(_ title: String, action: Selector?, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        return item
    }

    private func makeCaptureItem(_ action: ShortcutAction, symbol: String) -> NSMenuItem {
        let item = makeItem(action.displayName, action: #selector(handleMenuCapture(_:)), symbol: symbol)
        item.representedObject = action
        return item
    }

    @objc private func handleMenuCapture(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ShortcutAction else { return }
        performCapture(action)
    }

    /// Captures using whichever destinations are currently enabled for this
    /// action (Save to Desktop and/or Copy to Clipboard, independently
    /// toggled in Settings). If neither is on, this is a no-op.
    private func performCapture(_ action: ShortcutAction) {
        var destinations: ScreenshotManager.Destinations = []
        if CaptureSettingsStore.isSaveEnabled(for: action) { destinations.insert(.file) }
        if CaptureSettingsStore.isCopyEnabled(for: action) { destinations.insert(.clipboard) }
        guard !destinations.isEmpty else { return }

        screenshotManager.capture(mode: action.captureMode, destinations: destinations) { [weak self] result in
            switch result {
            case .success(.captured):
                self?.showCaptureConfirmation(destinations: destinations)
            case .success(.cancelled):
                break
            case .failure(let error):
                NSLog("Tide: screenshot capture failed: \(error)")
            }
        }
    }

    /// Briefly flashes a confirmation ("✓ Saved", "✓ Copied", or "✓ Saved &
    /// Copied") in the menu bar with a short sound, then reverts to the
    /// current speed reading.
    private func showCaptureConfirmation(destinations: ScreenshotManager.Destinations) {
        feedbackResetWorkItem?.cancel()
        isShowingCaptureFeedback = true
        statusItem.button?.image = nil
        statusItem.button?.title = Self.confirmationLabel(for: destinations)

        if let captureSound {
            captureSound.stop()
            captureSound.play()
        }

        let resetWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowingCaptureFeedback = false
            self.statusItem.button?.title = ""
            self.statusItem.button?.image = self.lastSpeedImage
        }
        feedbackResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: resetWorkItem)
    }

    private static func confirmationLabel(for destinations: ScreenshotManager.Destinations) -> String {
        switch (destinations.contains(.file), destinations.contains(.clipboard)) {
        case (true, true): return "✓ Saved & Copied"
        case (true, false): return "✓ Saved"
        case (false, true): return "✓ Copied"
        case (false, false): return "✓ Done"
        }
    }

    /// Builds the settings window controller if it doesn't exist yet.
    /// Building it (buildContent(), all three panes, table view, icon
    /// PNGs read from disk, the whole Auto Layout pass) is real work done
    /// synchronously — cheap once already built (showWindow on an
    /// existing window is near-instant), but a visible hitch the first
    /// time it happens. Called both from a pre-warm shortly after launch
    /// and, as a fallback, from openSettingsWindow itself in case that
    /// pre-warm hasn't run yet (e.g. the user opens Settings within the
    /// first second after launch).
    @discardableResult
    private func makeSettingsWindowControllerIfNeeded() -> SettingsWindowController {
        if let existing = settingsWindowController {
            return existing
        }
        let controller = SettingsWindowController()
        controller.applyShortcutChange = { [weak self] action, combo in
            self?.applyShortcutChange(action: action, combo: combo) ?? false
        }
        controller.checkForUpdates = { [weak self] in
            self?.checkForUpdates(silent: false)
        }
        controller.onSpeedMeterSettingsChanged = { [weak self] in
            self?.applySpeedMeterSettingsChange()
        }
        settingsWindowController = controller
        return controller
    }

    @objc private func openSettingsWindow() {
        let controller = makeSettingsWindowControllerIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// `silent`: on launch, say nothing if already up to date (no need to
    /// interrupt startup with an "up to date" alert). From a manual "Check
    /// for Updates…" click, always report the result either way.
    private func checkForUpdates(silent: Bool) {
        UpdateChecker.checkForUpdate { [weak self] update in
            DispatchQueue.main.async {
                guard self != nil else { return }

                guard let update else {
                    if !silent {
                        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                        let alert = NSAlert()
                        alert.messageText = "You're up to date"
                        alert.informativeText = "Tide \(currentVersion) is the latest version."
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                    return
                }

                let alert = NSAlert()
                alert.messageText = "Update Available"
                alert.informativeText = "Tide \(update.version) is available. Download and install now? Tide will quit and reopen automatically."
                alert.addButton(withTitle: "Update Now")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }

                UpdateInstaller.downloadAndInstall(from: update.downloadURL) { result in
                    DispatchQueue.main.async {
                        guard case .failure(let error) = result else { return } // success quits the app itself
                        let errorAlert = NSAlert()
                        errorAlert.messageText = "Update Failed"
                        errorAlert.informativeText = "\(error)"
                        errorAlert.runModal()
                    }
                }
            }
        }
    }

    /// (Re)registers the global hotkey currently stored for `action`, if any.
    @discardableResult
    private func registerHotKey(for action: ShortcutAction) -> Bool {
        if let id = hotKeyIDs.removeValue(forKey: action) {
            hotKeyManager.unregister(id: id)
        }

        guard let combo = ShortcutStore.combo(for: action) else { return true } // no shortcut assigned

        guard let id = hotKeyManager.register(combo: combo, handler: { [weak self] in
            self?.performCapture(action)
        }) else {
            return false
        }

        hotKeyIDs[action] = id
        return true
    }

    /// Applies a shortcut change requested from Settings: unregisters the
    /// old hotkey, tries to register the new one, and only persists it if
    /// that succeeds. On failure, restores whatever was previously
    /// registered.
    private func applyShortcutChange(action: ShortcutAction, combo: KeyCombo?) -> Bool {
        if let id = hotKeyIDs.removeValue(forKey: action) {
            hotKeyManager.unregister(id: id)
        }

        guard let combo else {
            ShortcutStore.setCombo(nil, for: action)
            refreshShortcutMenuItems()
            return true
        }

        guard let id = hotKeyManager.register(combo: combo, handler: { [weak self] in
            self?.performCapture(action)
        }) else {
            registerHotKey(for: action) // restore the previously active shortcut
            return false
        }

        hotKeyIDs[action] = id
        ShortcutStore.setCombo(combo, for: action)
        refreshShortcutMenuItems()
        return true
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
