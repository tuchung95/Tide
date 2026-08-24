import AppKit

/// The "Settings…" window, laid out to match macOS System Settings: a real
/// NSTableView sidebar in `.sourceList` style with rounded icon badges, and
/// content panes built from rounded "card" groups (NSBox) with NSSwitch
/// toggles and hairline dividers between rows — the same visual language
/// System Settings itself uses, rather than a generic checkbox form.
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
            case .general: return "gearshape.fill"
            case .screenshot: return "camera.viewfinder"
            case .shortcuts: return "keyboard.fill"
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
    private let rowHeight: CGFloat = 40

    private var sidebarTableView: NSTableView!
    private var panes: [Tab: NSView] = [:]

    private var recorders: [ShortcutAction: ShortcutRecorderControl] = [:]
    private var saveSwitches: [ShortcutAction: NSSwitch] = [:]
    private var copySwitches: [ShortcutAction: NSSwitch] = [:]
    private var launchAtLoginSwitch: NSSwitch!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        // System Settings itself never shows a title next to the traffic
        // lights when a sidebar + pane is on screen; the bold in-pane
        // heading already says which tab is showing, so a title bar label
        // here would just duplicate it. fullSizeContentView + a transparent
        // titlebar let the two content cards extend up near the traffic
        // lights instead of starting below a separate gray titlebar strip.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
        sidebarTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    // MARK: - Window layout

    /// System Settings' current layout isn't a sidebar flush against the
    /// window edges: both the sidebar and the content pane are separate
    /// floating rounded cards — sidebar in frosted glass, content in a
    /// flat white card — sitting with a margin on a plain white/light
    /// window backdrop. This mirrors that rather than one edge-to-edge
    /// split view.
    private static let cardMargin: CGFloat = 10
    private static let cardGap: CGFloat = 10
    private static let cardCornerRadius: CGFloat = 10
    // Bigger top inset than the other edges: with fullSizeContentView the
    // content area starts at the very top of the window, right where the
    // traffic-light buttons sit — a plain 10pt margin would run the
    // sidebar's first row straight under them.
    private static let cardTopMargin: CGFloat = 32

    private func buildContent() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let sidebarCard = buildSidebar()
        let contentCard = buildContentCard()

        sidebarCard.translatesAutoresizingMaskIntoConstraints = false
        contentCard.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarCard)
        root.addSubview(contentCard)

        NSLayoutConstraint.activate([
            sidebarCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.cardMargin),
            sidebarCard.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.cardTopMargin),
            sidebarCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.cardMargin),
            sidebarCard.widthAnchor.constraint(equalToConstant: sidebarWidth),

            contentCard.leadingAnchor.constraint(equalTo: sidebarCard.trailingAnchor, constant: Self.cardGap),
            contentCard.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.cardTopMargin),
            contentCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.cardMargin),
            contentCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.cardMargin)
        ])

        window?.contentView = root
    }

    /// The flat white/rounded card the right-hand pane content sits in —
    /// as opposed to the sidebar's frosted glass card.
    private func buildContentCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = Self.cardCornerRadius
        card.layer?.masksToBounds = true

        for tab in Tab.allCases {
            let pane = buildPane(for: tab)
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.isHidden = true
            card.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
                pane.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
                pane.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -24)
            ])
            panes[tab] = pane
        }

        return card
    }

    // MARK: - Sidebar (native NSTableView, .sourceList style)

    private func buildSidebar() -> NSView {
        // .sidebar material matches the native translucent gray macOS uses
        // for source lists in both appearances, with no manual color
        // theming needed.
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cardCornerRadius
        background.layer?.masksToBounds = true

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
        // Let the single column track the table's actual width instead of
        // a width computed by hand: with a hardcoded width and no leading
        // inset on the scroll view, the selection pill rendered flush
        // against the left edge with an uneven, asymmetric margin instead
        // of the centered rounded highlight System Settings shows.
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.minWidth = 50
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        sidebarTableView = tableView

        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 7),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -7),
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
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
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
    /// The glyph is tinted white on its own isolated, transparent canvas
    /// first: doing the sourceAtop white fill directly against the colored
    /// background (as a single pass) recolors the *entire* opaque
    /// background rect white, not just the glyph, since sourceAtop only
    /// looks at destination alpha — and the background is opaque
    /// everywhere.
    private static func badgeImage(symbol: String, color: NSColor, size: CGFloat = 22) -> NSImage {
        let badge = NSImage(size: NSSize(width: size, height: size))
        badge.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: size * 0.24, yRadius: size * 0.24).fill()
        badge.unlockFocus()

        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return badge
        }
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .semibold)
        let configured = symbolImage.withSymbolConfiguration(config) ?? symbolImage
        let glyphSize = configured.size

        let whiteGlyph = NSImage(size: glyphSize)
        whiteGlyph.lockFocus()
        configured.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: glyphSize).fill(using: .sourceAtop)
        whiteGlyph.unlockFocus()

        badge.lockFocus()
        let glyphRect = NSRect(
            x: (size - glyphSize.width) / 2,
            y: (size - glyphSize.height) / 2,
            width: glyphSize.width,
            height: glyphSize.height
        )
        whiteGlyph.draw(in: glyphRect)
        badge.unlockFocus()

        return badge
    }

    private func showPane(for tab: Tab) {
        for (candidate, pane) in panes {
            pane.isHidden = (candidate != tab)
        }
    }

    private func buildPane(for tab: Tab) -> NSView {
        switch tab {
        case .general: return buildGeneralPane()
        case .screenshot: return buildScreenshotPane()
        case .shortcuts: return buildShortcutsPane()
        }
    }

    // MARK: - Shared pane chrome (title + card group)

    private func makePaneTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        return label
    }

    /// A rounded, filled group box with hairline dividers between its rows
    /// — System Settings' basic building block for every pane.
    private func makeCard(rows: [NSView]) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 0
        box.fillColor = .controlBackgroundColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rows.enumerated() {
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            if index < rows.count - 1 {
                let divider = NSBox()
                divider.boxType = .separator
                stack.addArrangedSubview(divider)
            }
        }

        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        return box
    }

    /// A fixed-height row with a leading view pinned left and a trailing
    /// view pinned right, both vertically centered — the standard "label
    /// … control" row shape used throughout System Settings.
    private func makeRow(leading: NSView, trailing: NSView) -> NSView {
        let row = NSView()
        row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        leading.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(leading)
        row.addSubview(trailing)

        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            leading.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 8)
        ])
        return row
    }

    // MARK: - General pane

    private func buildGeneralPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        stack.addArrangedSubview(makePaneTitle("General"))

        launchAtLoginSwitch = NSSwitch()
        launchAtLoginSwitch.state = LoginItemManager.isEnabled ? .on : .off
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(toggleLaunchAtLogin(_:))
        let launchRow = makeRow(leading: NSTextField(labelWithString: "Launch at Login"), trailing: launchAtLoginSwitch)

        let versionLabel = NSTextField(labelWithString: "Version \(Self.currentVersion)")
        versionLabel.textColor = .secondaryLabelColor
        let checkUpdatesButton = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdatesTapped))
        checkUpdatesButton.bezelStyle = .rounded
        let updateRow = makeRow(leading: versionLabel, trailing: checkUpdatesButton)

        let card = makeCard(rows: [launchRow, updateRow])
        card.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.addArrangedSubview(card)

        return stack
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) {
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

        stack.addArrangedSubview(makePaneTitle("Screenshot"))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        let rows = Self.captureActions.map { makeScreenshotRow(for: $0) }
        let card = makeCard(rows: rows)
        card.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.addArrangedSubview(card)

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreScreenshotDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)

        return stack
    }

    private func makeScreenshotRow(for action: ShortcutAction) -> NSView {
        let saveSwitch = NSSwitch()
        saveSwitch.state = CaptureSettingsStore.isSaveEnabled(for: action) ? .on : .off
        saveSwitch.target = self
        saveSwitch.action = #selector(toggleSave(_:))
        saveSwitch.tag = Self.captureActions.firstIndex(of: action) ?? 0
        saveSwitches[action] = saveSwitch

        let copySwitch = NSSwitch()
        copySwitch.state = CaptureSettingsStore.isCopyEnabled(for: action) ? .on : .off
        copySwitch.target = self
        copySwitch.action = #selector(toggleCopy(_:))
        copySwitch.tag = Self.captureActions.firstIndex(of: action) ?? 0
        copySwitches[action] = copySwitch

        // Each switch carries its own inline label ("Save"/"Copy") rather
        // than relying on a column header above the card: System Settings'
        // own multi-toggle rows are self-describing like this, and it also
        // sidesteps having to keep a separate header row's columns pixel-
        // aligned with the card's internal padding.
        let saveGroup = NSStackView(views: [NSTextField(labelWithString: "Save"), saveSwitch])
        saveGroup.spacing = 6
        let copyGroup = NSStackView(views: [NSTextField(labelWithString: "Copy"), copySwitch])
        copyGroup.spacing = 6

        let trailing = NSStackView(views: [saveGroup, copyGroup])
        trailing.orientation = .horizontal
        trailing.spacing = 20

        return makeRow(leading: NSTextField(labelWithString: action.displayName), trailing: trailing)
    }

    @objc private func toggleSave(_ sender: NSSwitch) {
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

    @objc private func toggleCopy(_ sender: NSSwitch) {
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
            saveSwitches[action]?.state = .on
            copySwitches[action]?.state = .on
        }
    }

    // MARK: - Shortcuts pane

    private func buildShortcutsPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        stack.addArrangedSubview(makePaneTitle("Shortcuts"))

        let rows = Self.captureActions.map { makeShortcutRow(for: $0) }
        let card = makeCard(rows: rows)
        card.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.addArrangedSubview(card)

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreShortcutDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)

        return stack
    }

    private func makeShortcutRow(for action: ShortcutAction) -> NSView {
        let recorder = ShortcutRecorderControl(frame: NSRect(x: 0, y: 0, width: 130, height: 22))
        recorder.widthAnchor.constraint(equalToConstant: 130).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 22).isActive = true
        recorder.combo = ShortcutStore.combo(for: action)
        recorder.onChange = { [weak self, weak recorder] newCombo in
            guard let self, let recorder else { return }
            self.handleShortcutChange(action: action, recorder: recorder, newCombo: newCombo)
        }
        recorders[action] = recorder

        return makeRow(leading: NSTextField(labelWithString: action.displayName), trailing: recorder)
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
