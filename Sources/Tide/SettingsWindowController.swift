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

    private let sidebarWidth: CGFloat = 220
    private let rowHeight: CGFloat = 40
    // 24pt icon + 8pt above/below = 40pt, so each item's vertical padding
    // matches its horizontal padding (sidebarPadding) instead of the ~6pt
    // it worked out to before.
    private let sidebarRowHeight: CGFloat = 40
    // Same value on all four sides around the nav item list, inside the
    // sidebar card.
    private static let sidebarPadding: CGFloat = 8

    private var sidebarTableView: NSTableView!
    private var previouslySelectedSidebarRow: Int?
    private var panes: [Tab: NSView] = [:]

    private var recorders: [ShortcutAction: ShortcutRecorderControl] = [:]
    private var saveSwitches: [ShortcutAction: NSSwitch] = [:]
    private var copySwitches: [ShortcutAction: NSSwitch] = [:]
    private var launchAtLoginSwitch: NSSwitch!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
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
        // Full reloadData() first so the table actually has its 3 rows
        // before selecting — and notably NOT called again after selecting:
        // a full reload can itself clear the selection it just set,
        // wiping out row 0's pill again immediately.
        sidebarTableView.reloadData()
        sidebarTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        previouslySelectedSidebarRow = 0
        // Belt-and-suspenders in case the selection-changed notification
        // didn't fire for this first selection: force just this one row's
        // cell to redraw with the correct pill state.
        sidebarTableView.reloadData(forRowIndexes: IndexSet(integer: 0), columnIndexes: IndexSet(integer: 0))
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
    private static let cardCornerRadius: CGFloat = 24
    // The small group cards in the right-hand panes get their own,
    // smaller radius rather than sharing the sidebar's.
    private static let smallCardCornerRadius: CGFloat = 12
    // Bigger top inset than the other edges: with fullSizeContentView the
    // content area starts at the very top of the window, right where the
    // traffic-light buttons sit — a plain 10pt margin would run the
    // sidebar's first row straight under them.
    private static let cardTopMargin: CGFloat = 32

    private func buildContent() {
        // NSBox with `fillColor` rather than a plain NSView with
        // `layer.backgroundColor = NSColor…cgColor`: the latter resolves
        // the dynamic system color to a raw CGColor once, at the moment
        // it's called — before this view is even in a window, so it isn't
        // resolving against the real current appearance yet — and then
        // never updates again. NSBox's fillColor is appearance-aware and
        // keeps resolving correctly, the same way the inner group cards
        // (makeCard) already do.
        // The whole page is a plain backdrop — the content side has no
        // separate boxed/rounded fill of its own, this same color shows
        // straight through around the small group cards. Only the sidebar
        // remains a distinct floating card, in glass.
        let root = NSBox()
        root.boxType = .custom
        root.borderWidth = 0
        root.cornerRadius = 0
        // True white (255,255,255) in light mode, still Dark-Mode-aware
        // (unlike a hardcoded literal white would be).
        root.fillColor = .controlBackgroundColor

        let sidebarCard = buildSidebar()
        let contentContainer = buildContentContainer()

        sidebarCard.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarCard)
        root.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebarCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.cardMargin),
            sidebarCard.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.cardTopMargin),
            sidebarCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.cardMargin),
            sidebarCard.widthAnchor.constraint(equalToConstant: sidebarWidth),

            contentContainer.leadingAnchor.constraint(equalTo: sidebarCard.trailingAnchor, constant: Self.cardGap),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.cardTopMargin),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.cardMargin),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.cardMargin)
        ])

        window?.contentView = root
    }

    /// Plain, unstyled container for the right-hand pane content — no
    /// background fill or corner radius of its own; the page's gray shows
    /// straight through around the small white group cards inside each pane.
    private func buildContentContainer() -> NSView {
        let container = NSView()

        for tab in Tab.allCases {
            let pane = buildPane(for: tab)
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.isHidden = true
            container.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
                pane.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
                pane.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24)
            ])
            panes[tab] = pane
        }

        return container
    }

    // MARK: - Sidebar (native NSTableView, .sourceList style)

    private func buildSidebar() -> NSView {
        // The shadow lives on an outer plain wrapper rather than the glass
        // view itself: the glass view needs masksToBounds = true to clip
        // its content to the rounded corners, but that would also clip
        // away any shadow drawn on the same layer (a shadow renders outside
        // the layer's own bounds).
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.shadowColor = NSColor.black.cgColor
        wrapper.layer?.shadowOpacity = 0.4
        wrapper.layer?.shadowRadius = 24
        wrapper.layer?.shadowOffset = NSSize(width: 0, height: -3)
        // Without an explicit shadowPath, CALayer derives the shadow's
        // shape from the layer's own bounds + cornerRadius. The wrapper
        // itself was still a plain rectangle (masksToBounds is off here on
        // purpose, so the shadow can render outside its bounds), so its
        // shadow followed square corners while the glass card underneath
        // is rounded — the mismatch showed as small gray triangular
        // wedges poking past the card's rounded corners.
        wrapper.layer?.cornerRadius = Self.cardCornerRadius

        // Plain solid fill instead of the frosted-glass NSVisualEffectView
        // this used to be — same F7F7F7 as the small group cards, for a
        // consistent flat palette. NSBox rather than a layer-backed NSView:
        // its cornerRadius/borderWidth/borderColor/fillColor all resolve
        // correctly against the current appearance on their own.
        let background = NSBox()
        background.boxType = .custom
        background.cornerRadius = Self.cardCornerRadius
        background.borderWidth = 1
        background.borderColor = NSColor.white.withAlphaComponent(0.8)
        background.fillColor = Self.smallCardFillColor
        background.translatesAutoresizingMaskIntoConstraints = false

        wrapper.addSubview(background)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: wrapper.topAnchor),
            background.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor)
        ])

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let tableView = NSTableView()
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = sidebarRowHeight
        // The system's own .sourceList selection pill draws at a fixed,
        // larger corner radius with no public API to change it — and on
        // this macOS version, overriding NSTableRowView.drawSelection(in:)
        // didn't intercept it either (still rendered natively), so it's
        // disabled outright here. The pill is instead drawn as a plain
        // background view inside each cell, toggled by hand in
        // tableView(_:viewFor:row:).
        tableView.selectionHighlightStyle = .none
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
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.sidebarPadding),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.sidebarPadding),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.sidebarPadding),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.sidebarPadding)
        ])
        return wrapper
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        Tab.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.sidebarCellIdentifier, owner: self) as? SidebarCellView)
            ?? makeSidebarCell()

        let tab = Tab.allCases[row]
        cell.textField?.stringValue = tab.title
        cell.imageView?.image = Self.badgeImage(symbol: tab.symbol, color: tab.badgeColor)
        cell.isRowSelected = (row == tableView.selectedRow)
        return cell
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarTableView.selectedRow
        guard row >= 0 else { return }

        // Native selection drawing is off (selectionHighlightStyle = .none),
        // so every row's own background pill has to be refreshed by hand —
        // both the newly selected one and whichever was selected before.
        // Targeted reloadData(forRowIndexes:) rather than a full
        // reloadData(): a full reload can itself clear the very selection
        // that triggered this callback, making the pill vanish immediately
        // after appearing.
        var rowsToRefresh = IndexSet(integer: row)
        if let previous = previouslySelectedSidebarRow {
            rowsToRefresh.insert(previous)
        }
        sidebarTableView.reloadData(forRowIndexes: rowsToRefresh, columnIndexes: IndexSet(integer: 0))
        previouslySelectedSidebarRow = row

        showPane(for: Tab.allCases[row])
    }

    private func makeSidebarCell() -> SidebarCellView {
        let cell = SidebarCellView()
        cell.identifier = Self.sidebarCellIdentifier

        cell.pillBackground.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(cell.pillBackground)

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
            cell.pillBackground.topAnchor.constraint(equalTo: cell.topAnchor),
            cell.pillBackground.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            cell.pillBackground.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            cell.pillBackground.bottomAnchor.constraint(equalTo: cell.bottomAnchor),

            // Same inset as the card's own outer padding (sidebarPadding),
            // rather than an unrelated one-off value.
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.sidebarPadding),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 24),
            imageView.heightAnchor.constraint(equalToConstant: 24),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Self.sidebarPadding),
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
    private static func badgeImage(symbol: String, color: NSColor, size: CGFloat = 24) -> NSImage {
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

    /// #F7F7F7 in Light Mode — the exact requested value — with a dynamic
    /// provider (rather than a plain literal NSColor) so it still adapts
    /// to a reasonable dark-mode fill instead of staying frozen white-gray
    /// when the system switches appearance.
    private static let smallCardFillColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(white: 0.16, alpha: 1)
            : NSColor(srgbRed: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF7 / 255, alpha: 1)
    }

    /// A rounded, filled group box with hairline dividers between its rows
    /// — System Settings' basic building block for every pane.
    private func makeCard(rows: [NSView]) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = Self.smallCardCornerRadius
        box.borderWidth = 0
        // Now that the page itself is pure white, the card needs its own
        // gray fill to read as a distinct card at all — controlBackgroundColor
        // (also white) was flush with the page and invisible.
        box.fillColor = Self.smallCardFillColor
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

        let creditLabel = NSTextField(labelWithString: "Created by Louis Chung")
        creditLabel.font = NSFont.systemFont(ofSize: 11)
        creditLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(creditLabel)

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

/// A sidebar row cell with its own selection "pill" background, drawn at a
/// fixed 12px corner radius — the table's native selectionHighlightStyle
/// is off (see buildSidebar), so this is the only thing drawing it.
private final class SidebarCellView: NSTableCellView {
    let pillBackground: NSBox = {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 12
        box.fillColor = .clear
        return box
    }()

    var isRowSelected = false {
        didSet {
            pillBackground.fillColor = isRowSelected ? .controlAccentColor : .clear
        }
    }
}
