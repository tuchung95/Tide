import AppKit

/// The "Settings…" window, laid out as a macOS System Settings–style
/// sidebar with one tab per functional area: General (Launch at Login +
/// updates), Screenshot (Save/Copy toggles), Shortcuts (global hotkeys).
/// Shortcut persistence/registration is still owned by the app delegate via
/// `applyShortcutChange`; Save/Copy and Launch at Login are simple enough
/// to read/write directly from here.
final class SettingsWindowController: NSWindowController {

    /// Returns true if `combo` (nil means "clear") was applied successfully.
    var applyShortcutChange: ((ShortcutAction, KeyCombo?) -> Bool)?

    /// Triggered by the "Check for Updates…" button; the app delegate owns
    /// the actual check + install flow since it needs to show alerts.
    var checkForUpdates: (() -> Void)?

    private enum Tab: Int, CaseIterable {
        case general
        case screenshot
        case shortcuts

        var title: String {
            switch self {
            case .general: return "General"
            case .screenshot: return "Screenshot"
            case .shortcuts: return "Shortcuts"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .screenshot: return "camera.viewfinder"
            case .shortcuts: return "keyboard"
            }
        }
    }

    private static let captureActions: [ShortcutAction] = [.selectedArea, .window, .fullScreen]

    private let sidebarWidth: CGFloat = 140
    private let labelWidth: CGFloat = 110
    private let checkboxWidth: CGFloat = 50
    private let recorderWidth: CGFloat = 130

    private var sidebarButtons: [Tab: NSButton] = [:]
    private var panes: [Tab: NSView] = [:]

    private var recorders: [ShortcutAction: ShortcutRecorderControl] = [:]
    private var saveCheckboxes: [ShortcutAction: NSButton] = [:]
    private var copyCheckboxes: [ShortcutAction: NSButton] = [:]
    private var launchAtLoginCheckbox: NSButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
        select(.general)
    }

    // MARK: - Layout

    private func buildContent() {
        let sidebar = buildSidebar()

        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        for tab in Tab.allCases {
            let pane = buildPane(for: tab)
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.isHidden = true
            contentContainer.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 24),
                pane.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 24),
                pane.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -24)
            ])
            panes[tab] = pane
        }

        let root = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        root.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth),

            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        window?.contentView = root
    }

    private func buildSidebar() -> NSView {
        // .sidebar material matches the native translucent gray macOS uses
        // for source lists (Finder, Mail, System Settings) in both
        // appearances, with no manual color theming needed.
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for tab in Tab.allCases {
            let button = makeSidebarButton(for: tab)
            sidebarButtons[tab] = button
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor)
        ])
        return background
    }

    private func makeSidebarButton(for tab: Tab) -> NSButton {
        let button = NSButton(title: tab.title, target: self, action: #selector(sidebarTapped(_:)))
        button.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.alignment = .left
        button.font = NSFont.systemFont(ofSize: 13)
        button.tag = tab.rawValue
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    @objc private func sidebarTapped(_ sender: NSButton) {
        guard let tab = Tab(rawValue: sender.tag) else { return }
        select(tab)
    }

    private func select(_ tab: Tab) {
        for (candidate, button) in sidebarButtons {
            button.state = (candidate == tab) ? .on : .off
        }
        for (candidate, pane) in panes {
            pane.isHidden = (candidate != tab)
        }
        window?.title = tab.title
    }

    private func buildPane(for tab: Tab) -> NSView {
        switch tab {
        case .general: return buildGeneralPane()
        case .screenshot: return buildScreenshotPane()
        case .shortcuts: return buildShortcutsPane()
        }
    }

    // MARK: - General pane

    private func buildGeneralPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(toggleLaunchAtLogin))
        launchAtLoginCheckbox.state = LoginItemManager.isEnabled ? .on : .off
        stack.addArrangedSubview(launchAtLoginCheckbox)

        let updateRow = NSStackView()
        updateRow.orientation = .horizontal
        updateRow.spacing = 8

        let versionLabel = NSTextField(labelWithString: "Version \(Self.currentVersion)")
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.font = NSFont.systemFont(ofSize: 11)

        let checkUpdatesButton = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdatesTapped))
        checkUpdatesButton.bezelStyle = .rounded

        updateRow.addArrangedSubview(versionLabel)
        updateRow.addArrangedSubview(checkUpdatesButton)
        stack.addArrangedSubview(updateRow)

        return stack
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        LoginItemManager.isEnabled = sender.state == .on
    }

    @objc private func checkForUpdatesTapped() {
        checkForUpdates?()
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: - Screenshot pane (Save/Copy toggles)

    private func buildScreenshotPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        stack.addArrangedSubview(makeColumnHeaderRow(columns: [("Save", checkboxWidth), ("Copy", checkboxWidth)]))
        for action in Self.captureActions {
            stack.addArrangedSubview(makeScreenshotRow(for: action))
        }

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreScreenshotDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)

        return stack
    }

    private func makeColumnHeaderRow(columns: [(title: String, width: CGFloat)]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        row.addArrangedSubview(spacer)

        for column in columns {
            row.addArrangedSubview(makeCaptionLabel(column.title, width: column.width))
        }
        return row
    }

    private func makeCaptionLabel(_ title: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func makeScreenshotRow(for action: ShortcutAction) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let label = NSTextField(labelWithString: action.displayName)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        let tag = Self.captureActions.firstIndex(of: action) ?? 0

        let saveCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleSave(_:)))
        saveCheckbox.state = CaptureSettingsStore.isSaveEnabled(for: action) ? .on : .off
        saveCheckbox.tag = tag
        reserveColumnWidth(saveCheckbox, width: checkboxWidth)
        saveCheckboxes[action] = saveCheckbox

        let copyCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCopy(_:)))
        copyCheckbox.state = CaptureSettingsStore.isCopyEnabled(for: action) ? .on : .off
        copyCheckbox.tag = tag
        reserveColumnWidth(copyCheckbox, width: checkboxWidth)
        copyCheckboxes[action] = copyCheckbox

        row.addArrangedSubview(label)
        row.addArrangedSubview(saveCheckbox)
        row.addArrangedSubview(copyCheckbox)
        return row
    }

    /// Reserves the same width as the column header caption above it, so
    /// checkboxes roughly line up under "Save"/"Copy" instead of each row
    /// sizing to its own content.
    private func reserveColumnWidth(_ control: NSView, width: CGFloat) {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    @objc private func toggleSave(_ sender: NSButton) {
        let action = Self.captureActions[sender.tag]
        let enabling = sender.state == .on
        guard enabling || CaptureSettingsStore.isCopyEnabled(for: action) else {
            // Refuse to leave both destinations off — revert the click.
            sender.state = .on
            NSSound.beep()
            return
        }
        CaptureSettingsStore.setSaveEnabled(enabling, for: action)
    }

    @objc private func toggleCopy(_ sender: NSButton) {
        let action = Self.captureActions[sender.tag]
        let enabling = sender.state == .on
        guard enabling || CaptureSettingsStore.isSaveEnabled(for: action) else {
            sender.state = .on
            NSSound.beep()
            return
        }
        CaptureSettingsStore.setCopyEnabled(enabling, for: action)
    }

    @objc private func restoreScreenshotDefaults() {
        for action in Self.captureActions {
            CaptureSettingsStore.setSaveEnabled(true, for: action)
            CaptureSettingsStore.setCopyEnabled(true, for: action)
            saveCheckboxes[action]?.state = .on
            copyCheckboxes[action]?.state = .on
        }
    }

    // MARK: - Shortcuts pane

    private func buildShortcutsPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        stack.addArrangedSubview(makeColumnHeaderRow(columns: [("Shortcut", recorderWidth)]))
        for action in Self.captureActions {
            stack.addArrangedSubview(makeShortcutRow(for: action))
        }

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreShortcutDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)

        return stack
    }

    private func makeShortcutRow(for action: ShortcutAction) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let label = NSTextField(labelWithString: action.displayName)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        let recorder = ShortcutRecorderControl(frame: NSRect(x: 0, y: 0, width: recorderWidth, height: 22))
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: recorderWidth).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 22).isActive = true
        recorder.combo = ShortcutStore.combo(for: action)
        recorder.onChange = { [weak self, weak recorder] newCombo in
            guard let self, let recorder else { return }
            self.handleShortcutChange(action: action, recorder: recorder, newCombo: newCombo)
        }
        recorders[action] = recorder

        row.addArrangedSubview(label)
        row.addArrangedSubview(recorder)
        return row
    }

    private func handleShortcutChange(action: ShortcutAction, recorder: ShortcutRecorderControl, newCombo: KeyCombo?) {
        guard applyShortcutChange?(action, newCombo) == true else {
            recorder.combo = ShortcutStore.combo(for: action)
            NSSound.beep()

            let alert = NSAlert()
            alert.messageText = "Couldn't set shortcut"
            alert.informativeText = "That combination may already be in use by macOS or another app. Try a different one."
            alert.runModal()
            return
        }
    }

    @objc private func restoreShortcutDefaults() {
        for action in Self.captureActions {
            let combo = action.defaultCombo
            if applyShortcutChange?(action, combo) == true {
                recorders[action]?.combo = combo
            }
        }
    }
}
