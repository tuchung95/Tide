import AppKit

/// The "Settings…" window, laid out as a macOS System Settings–style
/// sidebar with one tab per functional area: General (Launch at Login +
/// updates), Screenshot (Save/Copy toggles), Shortcuts (global hotkeys).
/// Shortcut persistence/registration is still owned by the app delegate via
/// `applyShortcutChange`; Save/Copy and Launch at Login are simple enough
/// to read/write directly from here.
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

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

        // Matches System Settings' rounded, colored icon "badges".
        var badgeColor: NSColor {
            switch self {
            case .general: return .systemGray
            case .screenshot: return .systemBlue
            case .shortcuts: return .systemIndigo
            }
        }
    }

    private static let captureActions: [ShortcutAction] = [.selectedArea, .window, .fullScreen]
    private static let sidebarCellIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")

    private let sidebarWidth: CGFloat = 180
    private let labelWidth: CGFloat = 110
    private let checkboxWidth: CGFloat = 50
    private let recorderWidth: CGFloat = 130

    private var sidebarTableView: NSTableView!
    private var panes: [Tab: NSView] = [:]

    private var recorders: [ShortcutAction: ShortcutRecorderControl] = [:]
    private var saveCheckboxes: [ShortcutAction: NSButton] = [:]
    private var copyCheckboxes: [ShortcutAction: NSButton] = [:]
    private var launchAtLoginCheckbox: NSButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
        sidebarTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
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

    /// A real NSTableView in `.sourceList` style — the same native component
    /// System Settings/Finder/Mail use for their sidebars — rather than a
    /// hand-rolled button stack, so selection gets the standard rounded
    /// highlight pill for free instead of an approximation of it.
    private func buildSidebar() -> NSView {
        // .sidebar material matches the native translucent gray macOS uses
        // for source lists in both appearances, with no manual color
        // theming needed.
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let tableView = NSTableView()
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 32
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.width = sidebarWidth - 16
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        sidebarTableView = tableView

        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        return background
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        Tab.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.sidebarCellIdentifier, owner: self) as? NSTableCellView)
            ?? makeSidebarCell()

        let tab = Tab.allCases[row]
        cell.textField?.stringValue = tab.title
        cell.imageView?.image = Self.badgeImage(symbol: tab.symbol, color: tab.badgeColor)
        return cell
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarTableView.selectedRow
        guard row >= 0 else { return }
        showPane(for: Tab.allCases[row])
    }

    private func makeSidebarCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.sidebarCellIdentifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = NSFont.systemFont(ofSize: 13)

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 20),
            imageView.heightAnchor.constraint(equalToConstant: 20),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    /// Draws a rounded, colored square with a white SF Symbol centered in
    /// it — the "badge" look System Settings uses for each sidebar row.
    private static func badgeImage(symbol: String, color: NSColor, size: CGFloat = 22) -> NSImage {
        let badge = NSImage(size: NSSize(width: size, height: size))
        badge.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: size * 0.24, yRadius: size * 0.24).fill()

        if let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .semibold)
            let configured = symbolImage.withSymbolConfiguration(config) ?? symbolImage
            let glyphSize = configured.size
            let glyphRect = NSRect(
                x: (size - glyphSize.width) / 2,
                y: (size - glyphSize.height) / 2,
                width: glyphSize.width,
                height: glyphSize.height
            )
            // Standard NSImage tint trick: draw the template glyph, then
            // flood the rect with white using sourceAtop so only the
            // glyph's existing alpha gets recolored.
            NSColor.white.set()
            configured.draw(in: glyphRect)
            glyphRect.fill(using: .sourceAtop)
        }

        badge.unlockFocus()
        return badge
    }

    private func showPane(for tab: Tab) {
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
