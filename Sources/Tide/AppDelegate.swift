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

    private let hotKeyManager = HotKeyManager.shared
    private var hotKeyIDs: [ShortcutAction: UInt32] = [:]
    private var shortcutsWindowController: ShortcutsWindowController?

    // Small per-line font so two stacked lines still fit the menu bar's height.
    private lazy var statusFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    private lazy var lastSpeedImage = Self.stackedImage(up: "--", down: "--", font: statusFont)
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
        // reading appears one second later.
        networkMonitor.poll()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshSpeed()
        }
        RunLoop.main.add(updateTimer!, forMode: .common)
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

    private func refreshSpeed() {
        guard let sample = networkMonitor.poll() else { return }
        let down = SpeedFormatter.format(bytesPerSecond: sample.downloadBytesPerSecond)
        let up = SpeedFormatter.format(bytesPerSecond: sample.uploadBytesPerSecond)
        lastSpeedImage = Self.stackedImage(up: up, down: down, font: statusFont)

        // Don't stomp on the "✓ Copied" confirmation while it's showing.
        guard !isShowingCaptureFeedback else { return }
        statusItem.button?.image = lastSpeedImage
    }

    /// Draws a two-line "↑ up / ↓ down" template image: arrow icons fixed
    /// on the left, values right-aligned to a shared right edge so the
    /// digits don't jump around as their width changes. NSButton's automatic
    /// title layout doesn't reliably center a two-line NSAttributedString
    /// within the menu bar's fixed row height either (it clips the top and
    /// bottom), so the whole thing is rasterized by hand instead.
    private static func stackedImage(up: String, down: String, font: NSFont) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let upIcon = NSAttributedString(string: "↑", attributes: attributes)
        let downIcon = NSAttributedString(string: "↓", attributes: attributes)
        let upValue = NSAttributedString(string: " \(up)", attributes: attributes)
        let downValue = NSAttributedString(string: " \(down)", attributes: attributes)

        let iconWidth = ceil(max(upIcon.size().width, downIcon.size().width))
        let valueWidth = ceil(max(upValue.size().width, downValue.size().width))
        let lineHeight = ceil(max(upIcon.size().height, downIcon.size().height))

        let width = iconWidth + valueWidth
        let image = NSImage(size: NSSize(width: width, height: lineHeight * 2))
        image.lockFocus()
        upIcon.draw(at: NSPoint(x: 0, y: lineHeight))
        upValue.draw(at: NSPoint(x: iconWidth + (valueWidth - upValue.size().width), y: lineHeight))
        downIcon.draw(at: NSPoint(x: 0, y: 0))
        downValue.draw(at: NSPoint(x: iconWidth + (valueWidth - downValue.size().width), y: 0))
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

        let selectedAreaItem = makeItem("Selected Area…", action: #selector(captureSelection), symbol: "crop")
        let windowItem = makeItem("Window…", action: #selector(captureWindow), symbol: "macwindow")
        let fullScreenItem = makeItem("Full Screen", action: #selector(captureFullScreen), symbol: "rectangle.dashed")
        captureMenuItems = [.selectedArea: selectedAreaItem, .window: windowItem, .fullScreen: fullScreenItem]
        menu.addItem(selectedAreaItem)
        menu.addItem(windowItem)
        menu.addItem(fullScreenItem)

        menu.addItem(.separator())

        menu.addItem(makeItem("Keyboard Shortcuts…", action: #selector(openShortcutsWindow), symbol: "keyboard"))

        let launchItem = makeItem("Launch at Login", action: #selector(toggleLaunchAtLogin), symbol: "power")
        launchItem.state = LoginItemManager.isEnabled ? .on : .off
        menu.addItem(launchItem)

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

    @objc private func captureSelection() {
        runCapture(.selection)
    }

    @objc private func captureWindow() {
        runCapture(.window)
    }

    @objc private func captureFullScreen() {
        runCapture(.fullScreen)
    }

    private func runCapture(_ mode: ScreenshotManager.Mode) {
        screenshotManager.capture(mode: mode) { [weak self] result in
            switch result {
            case .success(let url) where url != nil:
                self?.showCaptureConfirmation()
            case .success:
                break // user cancelled an interactive capture
            case .failure(let error):
                NSLog("Tide: screenshot capture failed: \(error)")
            }
        }
    }

    /// Briefly flashes "✓ Copied" in the menu bar with a short sound to
    /// confirm the screenshot was copied to the clipboard, then reverts to
    /// the current speed reading.
    private func showCaptureConfirmation() {
        feedbackResetWorkItem?.cancel()
        isShowingCaptureFeedback = true
        statusItem.button?.image = nil
        statusItem.button?.title = "✓ Copied"
        NSSound(named: "Pop")?.play()

        let resetWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowingCaptureFeedback = false
            self.statusItem.button?.title = ""
            self.statusItem.button?.image = self.lastSpeedImage
        }
        feedbackResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: resetWorkItem)
    }

    @objc private func openShortcutsWindow() {
        if shortcutsWindowController == nil {
            let controller = ShortcutsWindowController()
            controller.applyChange = { [weak self] action, combo in
                self?.applyShortcutChange(action: action, combo: combo) ?? false
            }
            shortcutsWindowController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        shortcutsWindowController?.showWindow(nil)
        shortcutsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func handleShortcut(_ action: ShortcutAction) {
        switch action {
        case .selectedArea: captureSelection()
        case .window: captureWindow()
        case .fullScreen: captureFullScreen()
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
            self?.handleShortcut(action)
        }) else {
            return false
        }

        hotKeyIDs[action] = id
        return true
    }

    /// Applies a shortcut change requested from the Keyboard Shortcuts
    /// window: unregisters the old hotkey, tries to register the new one,
    /// and only persists it if that succeeds. On failure, restores whatever
    /// was previously registered.
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
            self?.handleShortcut(action)
        }) else {
            registerHotKey(for: action) // restore the previously active shortcut
            return false
        }

        hotKeyIDs[action] = id
        ShortcutStore.setCombo(combo, for: action)
        refreshShortcutMenuItems()
        return true
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = !LoginItemManager.isEnabled
        LoginItemManager.isEnabled = newState
        sender.state = newState ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
