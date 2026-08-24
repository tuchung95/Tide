import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var updateTimer: Timer?

    private let networkMonitor = NetworkMonitor()
    private let screenshotManager = ScreenshotManager()

    private lazy var statusFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = statusFont
        statusItem.button?.title = "↓ -- ↑ --"

        statusItem.menu = buildMenu()

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

    private func refreshSpeed() {
        guard let sample = networkMonitor.poll() else { return }
        let down = SpeedFormatter.format(bytesPerSecond: sample.downloadBytesPerSecond)
        let up = SpeedFormatter.format(bytesPerSecond: sample.uploadBytesPerSecond)
        statusItem.button?.title = "↓ \(down)  ↑ \(up)"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let screenshotHeader = NSMenuItem(title: "Screenshot", action: nil, keyEquivalent: "")
        screenshotHeader.isEnabled = false
        menu.addItem(screenshotHeader)

        menu.addItem(makeItem("Selected Area…", action: #selector(captureSelection)))
        menu.addItem(makeItem("Window…", action: #selector(captureWindow)))
        menu.addItem(makeItem("Full Screen", action: #selector(captureFullScreen)))
        menu.addItem(makeItem("Open Screenshots Folder", action: #selector(openScreenshotsFolder)))

        menu.addItem(.separator())

        let launchItem = makeItem("Launch at Login", action: #selector(toggleLaunchAtLogin))
        launchItem.state = LoginItemManager.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        // Default keyEquivalentModifierMask is .command, so this reads as Cmd+Q.
        menu.addItem(makeItem("Quit Tide", action: #selector(quit), key: "q"))

        return menu
    }

    private func makeItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
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
        screenshotManager.capture(mode: mode) { result in
            if case .failure(let error) = result {
                NSLog("Tide: screenshot capture failed: \(error)")
            }
        }
    }

    @objc private func openScreenshotsFolder() {
        screenshotManager.revealScreenshotsFolder()
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
