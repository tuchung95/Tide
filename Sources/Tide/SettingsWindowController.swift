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

    /// Triggered after any Speed Meter setting changes, so the app
    /// delegate can apply it to the live menu bar display/timer right
    /// away instead of waiting for the next scheduled poll.
    var onSpeedMeterSettingsChanged: (() -> Void)?

    private enum Tab: Int, CaseIterable {
        case general
        case screenshot
        case shortcuts
        case speedMeter

        var title: String {
            switch self {
            case .general: return "General"
            case .screenshot: return "Screenshot"
            case .shortcuts: return "Shortcuts"
            case .speedMeter: return "Speed Meter"
            }
        }

        // Bundled PNGs (from macosicons.com) rather than SF Symbol badges —
        // filenames match the resource names copied into the app bundle by
        // build_app.sh.
        var iconResourceName: String {
            switch self {
            case .general: return "SidebarGeneralIcon"
            case .screenshot: return "SidebarScreenshotIcon"
            case .shortcuts: return "SidebarShortcutsIcon"
            case .speedMeter: return "SidebarSpeedMeterIcon"
            }
        }
    }

    private static let captureActions: [ShortcutAction] = [.selectedArea, .window, .fullScreen]
    private static let sidebarCellIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")

    private let sidebarWidth: CGFloat = 220
    private let rowHeight: CGFloat = 40
    // 24pt icon + 8pt above/below = 40pt, so each item's vertical padding
    // matches its horizontal padding (sidebarItemPadding) instead of the
    // ~6pt it worked out to before.
    private let sidebarRowHeight: CGFloat = 40
    // Gap between the item list (scrollView) and the sidebar card's own
    // edges, so the selection pill reads as inset from the card's border
    // rather than flush against it.
    private static let sidebarListInset: CGFloat = 12
    // Bigger top inset than the other edges: the sidebar card now runs up
    // to the window's own top edge (see cardTopMargin), so this keeps the
    // first pill clear of the traffic-light buttons floating above it.
    private static let sidebarListTopInset: CGFloat = 42
    // Padding around each item's own content (icon/text) within its row.
    private static let sidebarItemPadding: CGFloat = 8
    // Gap between a sidebar item's icon and its label text.
    private static let sidebarIconTextGap: CGFloat = 8
    // Padding around a pane's content, inside root (leading/top; trailing
    // is capped, not padded, since panes don't have a fixed right edge).
    private static let panePadding: CGFloat = 24
    // Padding around a small group card's rows, inside its own box.
    private static let smallCardPadding: CGFloat = 14
    // Minimum gap between a row's label and its trailing control.
    private static let rowContentGap: CGFloat = 8

    private var sidebarTableView: NSTableView!
    private var previouslySelectedSidebarRow: Int?
    private var panes: [Tab: NSView] = [:]

    private var recorders: [ShortcutAction: ShortcutRecorderControl] = [:]
    private var saveSwitches: [ShortcutAction: NSButton] = [:]
    private var copySwitches: [ShortcutAction: NSButton] = [:]
    private var launchAtLoginSwitch: NSSwitch!
    private var speedMeterEnabledSwitch: NSSwitch!
    private var showUploadSwitch: NSSwitch!
    private var showDownloadSwitch: NSSwitch!
    private var speedUnitPopup: NSPopUpButton!
    private var refreshIntervalPopup: NSPopUpButton!

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
        // Non-opaque with a clear background so the window's own corner
        // pixels — outside root's rounded fill path, which only paints the
        // rounded shape itself — read as transparent (showing the desktop)
        // rather than an opaque square peeking past root's rounded corner.
        window.isOpaque = false
        window.backgroundColor = .clear
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

    // Hand-drawn replacements for the native traffic-light buttons: the
    // native ones live in NSWindow's own NSTitlebarView, a fixed 28pt-tall
    // strip that clips its subviews, so they can't be freely repositioned
    // (confirmed empirically — a big enough offset just makes them vanish,
    // clipped by that strip's own bounds). Drawing our own, positioned as
    // regular subviews of root, isn't bound by that constraint. Trade-off:
    // no native hover-dim, no automatic light/dark glyphs, no built-in
    // accessibility — just plain colored circles wired to the same
    // close/miniaturize/zoom actions.
    private static let trafficLightDiameter: CGFloat = 14
    private static let trafficLightSpacing: CGFloat = 20
    private static let trafficLightLeading: CGFloat = 24
    private static let trafficLightTop: CGFloat = 20

    private func addCustomTrafficLights(to root: NSView) {
        window?.standardWindowButton(.closeButton)?.isHidden = true
        window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window?.standardWindowButton(.zoomButton)?.isHidden = true

        let lights: [(NSColor, () -> Void)] = [
            (NSColor(red: 1.0, green: 0.373, blue: 0.341, alpha: 1), { [weak self] in self?.window?.performClose(nil) }),
            (NSColor(red: 1.0, green: 0.741, blue: 0.180, alpha: 1), { [weak self] in self?.window?.performMiniaturize(nil) }),
            (NSColor(red: 0.157, green: 0.784, blue: 0.251, alpha: 1), { [weak self] in self?.window?.performZoom(nil) })
        ]

        for (index, light) in lights.enumerated() {
            let button = TrafficLightButton()
            button.diameter = Self.trafficLightDiameter
            button.color = light.0
            button.onClick = light.1
            button.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.trafficLightDiameter),
                button.heightAnchor.constraint(equalToConstant: Self.trafficLightDiameter),
                button.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.trafficLightLeading + CGFloat(index) * Self.trafficLightSpacing),
                button.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.trafficLightTop)
            ])
        }
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
    // How much bigger than the sidebar card its DropShadowView is made, on
    // every side, matching that shadow's blurRadius (12) + offset (1).
    // Bigger than cardMargin, so the shadow gets clipped at the window's
    // own edge before fully fading out — acceptable now that it's subtle.
    private static let cardShadowPadding: CGFloat = 13
    // The small group cards in the right-hand panes get their own,
    // smaller radius rather than sharing the sidebar's.
    private static let smallCardCornerRadius: CGFloat = 12
    // Same as cardMargin: the sidebar card now runs all the way up to the
    // window's own top edge, sitting behind/under the traffic-light
    // buttons (which float above content as part of the window's
    // titlebar chrome with fullSizeContentView) rather than stopping
    // short to leave room above them.
    private static let cardTopMargin: CGFloat = cardMargin

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
        // A nonzero cornerRadius here clips root's own subviews to that
        // rounded shape near its corners (confirmed with isolated tests) —
        // content that overlaps the corner's clipped-away triangular
        // sliver disappears. The traffic-light replacements below and the
        // sidebar card shadow both stay clear of that sliver by keeping
        // enough distance from the exact corner point along both axes.
        root.cornerRadius = 30
        // True white (255,255,255) in light mode, still Dark-Mode-aware
        // (unlike a hardcoded literal white would be).
        root.fillColor = .controlBackgroundColor

        let sidebarCard = buildSidebar()
        sidebarCard.translatesAutoresizingMaskIntoConstraints = false
        addCardShadow(for: sidebarCard, toBeAddedTo: root)

        NSLayoutConstraint.activate([
            sidebarCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.cardMargin),
            sidebarCard.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.cardTopMargin),
            sidebarCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.cardMargin),
            sidebarCard.widthAnchor.constraint(equalToConstant: sidebarWidth)
        ])

        // Panes go straight into root — no separate contentContainer
        // wrapper view. It had no background/corner radius of its own
        // (the page backdrop shows straight through around it), so it was
        // adding a layer to the view hierarchy without adding anything
        // visual; each pane can just carry its own panePadding inset from
        // root/sidebarCard directly.
        for tab in Tab.allCases {
            let pane = buildPane(for: tab)
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.isHidden = true
            root.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.cardTopMargin + Self.panePadding),
                pane.leadingAnchor.constraint(equalTo: sidebarCard.trailingAnchor, constant: Self.cardGap + Self.panePadding),
                pane.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -(Self.cardMargin + Self.panePadding))
            ])
            panes[tab] = pane
        }

        window?.contentView = root
        addCustomTrafficLights(to: root)
    }

    // MARK: - Sidebar (native NSTableView, .sourceList style)

    // Adds `card`'s shadow view to `root`, sized cardShadowPadding bigger
    // than `card` on every side so the blur has room to fade out before
    // hitting this view's own edge — see DropShadowView's doc comment for
    // why a separate view is needed at all rather than a CALayer shadow
    // directly on the card. Kept as a standalone view added straight to
    // `root` rather than living inside `card`'s own view (which holds the
    // NSScrollView/NSTableView): a scroll view can force its ancestors
    // into layer-backed clipping for scroll performance, which would clip
    // away exactly the overflow this shadow depends on — sidestepped
    // entirely by not sharing a parent with it.
    //
    // Must be called with `card` not yet added to `root`: this adds the
    // shadow view first and `card` right after, so plain append order
    // (rather than addSubview(_:positioned:relativeTo:), which turned out
    // not to reliably keep the shadow behind an NSBox like `root`) puts
    // the shadow behind card in z-order.
    private func addCardShadow(for card: NSView, toBeAddedTo root: NSView) {
        let cardShadow = DropShadowView()
        cardShadow.cornerRadius = Self.cardCornerRadius
        cardShadow.contentInset = Self.cardShadowPadding
        cardShadow.shadowOpacity = 0.12
        cardShadow.shadowBlurRadius = 12
        cardShadow.shadowOffset = NSSize(width: 0, height: -1)
        cardShadow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cardShadow)
        root.addSubview(card)
        NSLayoutConstraint.activate([
            cardShadow.topAnchor.constraint(equalTo: card.topAnchor, constant: -Self.cardShadowPadding),
            cardShadow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: -Self.cardShadowPadding),
            cardShadow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: Self.cardShadowPadding),
            cardShadow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: Self.cardShadowPadding)
        ])
    }

    private func buildSidebar() -> NSView {
        // `container`'s own bounds are exactly the visible card's bounds —
        // buildContent() positions it against root with cardMargin/width,
        // and other layout (e.g. the content panes' leading anchor) is
        // relative to its trailing edge.
        let container = NSView()

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

        container.addSubview(background)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let tableView = NSTableView()
        // .plain rather than .sourceList: sourceList bakes in an automatic
        // ~16pt leading inset on each cell view (confirmed by isolated
        // testing — present even with intercellSpacing and the scroll
        // view's own margins both at 0), which isn't controllable and
        // fights a precise, symmetric gap to the card's edge. .plain has
        // no such inset; selection/pill drawing is already fully custom
        // here anyway (selectionHighlightStyle = .none below), so the
        // sourceList style wasn't buying anything but that hidden margin.
        tableView.style = .plain
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = sidebarRowHeight
        // Default intercellSpacing (3, 2) leaves a horizontal gap between
        // the column and the row's own content, so the pill never reaches
        // the card's edges even though its constraints pin to cell edges.
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
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
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.sidebarListTopInset),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.sidebarListInset),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.sidebarListInset),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.sidebarListInset)
        ])
        return container
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        Tab.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.sidebarCellIdentifier, owner: self) as? SidebarCellView)
            ?? makeSidebarCell()

        let tab = Tab.allCases[row]
        let icon = Self.sidebarIcon(named: tab.iconResourceName)
        cell.textField?.stringValue = tab.title
        cell.imageView?.image = icon
        cell.badgeShadow.image = icon
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
        // Without this, the source PNGs (1024x1024 down to 128x128 on
        // disk) render cropped to the view's 24x24 bounds instead of
        // scaled down to fit them — NSImageView's default imageScaling
        // isn't a reliable proportional fit once the view is layer-backed
        // (needed below for corner clipping).
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Clip to a rounded rect regardless of how each source icon's own
        // corners look at full size — otherwise they read inconsistently
        // once scaled down to a 24pt badge.
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true

        // A separate view behind the badge draws its drop shadow: CALayer's
        // shadow properties don't render at all on this machine, and even
        // if they did, they'd be clipped away by imageView's own
        // masksToBounds above (needed for the rounded-corner clip) since a
        // layer's masksToBounds clips its own shadow too. NSShadow inside
        // draw(_:) avoids both problems — plain Core Graphics, on its own
        // view with no masking. It redraws the same icon image (rather than
        // a plain filled rect) so the shadow follows each icon's own alpha
        // shape — a generic rect showed through as a flat black box behind
        // any icon whose square canvas has transparent margin around its
        // own rounded artwork. Sized contentInset bigger than the badge on
        // every side so the blur has room to fade out before hitting this
        // view's own edge (draw(_:) is clipped to that).
        let badgeShadow = DropShadowView()
        badgeShadow.cornerRadius = 6
        badgeShadow.contentInset = 6
        badgeShadow.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = NSFont.systemFont(ofSize: 13)

        cell.addSubview(badgeShadow)
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.badgeShadow = badgeShadow
        cell.textField = textField

        NSLayoutConstraint.activate([
            cell.pillBackground.topAnchor.constraint(equalTo: cell.topAnchor),
            cell.pillBackground.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            cell.pillBackground.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            cell.pillBackground.bottomAnchor.constraint(equalTo: cell.bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.sidebarItemPadding),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 24),
            imageView.heightAnchor.constraint(equalToConstant: 24),

            badgeShadow.topAnchor.constraint(equalTo: imageView.topAnchor, constant: -badgeShadow.contentInset),
            badgeShadow.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: -badgeShadow.contentInset),
            badgeShadow.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: badgeShadow.contentInset),
            badgeShadow.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: badgeShadow.contentInset),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: Self.sidebarIconTextGap),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Self.sidebarItemPadding),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    /// Loads a sidebar badge icon bundled as a loose PNG resource (from
    /// macosicons.com) rather than an asset catalog entry, since the app
    /// has no .xcassets — NSImage(named:) won't find it, so this goes
    /// straight to the file in the bundle's Resources folder.
    private static func sidebarIcon(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
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
        case .speedMeter: return buildSpeedMeterPane()
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
                // .separator boxType draws at the system's full separator
                // opacity; a flat light gray-white reads as a fainter
                // hairline instead.
                let divider = NSBox()
                divider.boxType = .custom
                divider.borderWidth = 0
                divider.fillColor = NSColor(white: 0.9, alpha: 1)
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(divider)
            }
        }

        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Self.smallCardPadding),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Self.smallCardPadding),
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
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: Self.rowContentGap)
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
        stack.spacing = 16

        stack.addArrangedSubview(makePaneTitle("Screenshot"))

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
        // NSButton(checkboxWithTitle:) rather than NSSwitch: this pane's
        // Save/Copy options are per-destination toggles, closer in meaning
        // to macOS's checkbox convention ("which of these apply") than the
        // single on/off switch convention used elsewhere (e.g. Launch at
        // Login).
        let saveSwitch = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleSave(_:)))
        saveSwitch.state = CaptureSettingsStore.isSaveEnabled(for: action) ? .on : .off
        saveSwitch.tag = Self.captureActions.firstIndex(of: action) ?? 0
        saveSwitches[action] = saveSwitch

        let copySwitch = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCopy(_:)))
        copySwitch.state = CaptureSettingsStore.isCopyEnabled(for: action) ? .on : .off
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
            saveSwitches[action]?.state = .on
            copySwitches[action]?.state = .on
        }
    }

    // MARK: - Speed Meter pane

    // (label, seconds) pairs offered in the refresh interval popup, in
    // display order.
    private static let refreshIntervalOptions: [(label: String, seconds: Double)] = [
        ("0.5s", 0.5), ("1s", 1.0), ("2s", 2.0), ("5s", 5.0)
    ]

    private func buildSpeedMeterPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        stack.addArrangedSubview(makePaneTitle("Speed Meter"))

        speedMeterEnabledSwitch = NSSwitch()
        speedMeterEnabledSwitch.state = SpeedMeterSettingsStore.isEnabled ? .on : .off
        speedMeterEnabledSwitch.target = self
        speedMeterEnabledSwitch.action = #selector(toggleSpeedMeterEnabled(_:))
        let enabledRow = makeRow(leading: NSTextField(labelWithString: "Show Speed on Menu Bar"), trailing: speedMeterEnabledSwitch)

        showUploadSwitch = NSSwitch()
        showUploadSwitch.state = SpeedMeterSettingsStore.showUpload ? .on : .off
        showUploadSwitch.target = self
        showUploadSwitch.action = #selector(toggleShowUpload(_:))
        let uploadRow = makeRow(leading: NSTextField(labelWithString: "Show Upload (↑)"), trailing: showUploadSwitch)

        showDownloadSwitch = NSSwitch()
        showDownloadSwitch.state = SpeedMeterSettingsStore.showDownload ? .on : .off
        showDownloadSwitch.target = self
        showDownloadSwitch.action = #selector(toggleShowDownload(_:))
        let downloadRow = makeRow(leading: NSTextField(labelWithString: "Show Download (↓)"), trailing: showDownloadSwitch)

        speedUnitPopup = NSPopUpButton()
        speedUnitPopup.addItems(withTitles: SpeedUnit.allCases.map(\.displayName))
        speedUnitPopup.selectItem(at: SpeedUnit.allCases.firstIndex(of: SpeedMeterSettingsStore.unit) ?? 0)
        speedUnitPopup.target = self
        speedUnitPopup.action = #selector(unitChanged(_:))
        let unitRow = makeRow(leading: NSTextField(labelWithString: "Unit"), trailing: speedUnitPopup)

        refreshIntervalPopup = NSPopUpButton()
        refreshIntervalPopup.addItems(withTitles: Self.refreshIntervalOptions.map(\.label))
        let currentInterval = SpeedMeterSettingsStore.refreshInterval
        let intervalIndex = Self.refreshIntervalOptions.firstIndex { $0.seconds == currentInterval } ?? 1
        refreshIntervalPopup.selectItem(at: intervalIndex)
        refreshIntervalPopup.target = self
        refreshIntervalPopup.action = #selector(refreshIntervalChanged(_:))
        let intervalRow = makeRow(leading: NSTextField(labelWithString: "Refresh Interval"), trailing: refreshIntervalPopup)

        let card = makeCard(rows: [enabledRow, uploadRow, downloadRow, unitRow, intervalRow])
        card.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.addArrangedSubview(card)

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreSpeedMeterDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)

        return stack
    }

    @objc private func toggleSpeedMeterEnabled(_ sender: NSSwitch) {
        SpeedMeterSettingsStore.isEnabled = sender.state == .on
        onSpeedMeterSettingsChanged?()
    }

    @objc private func toggleShowUpload(_ sender: NSSwitch) {
        let enabling = sender.state == .on
        guard enabling || SpeedMeterSettingsStore.showDownload else {
            // Refuse to leave both lines off — revert the click.
            sender.state = .on
            NSSound.beep()
            return
        }
        SpeedMeterSettingsStore.showUpload = enabling
        onSpeedMeterSettingsChanged?()
    }

    @objc private func toggleShowDownload(_ sender: NSSwitch) {
        let enabling = sender.state == .on
        guard enabling || SpeedMeterSettingsStore.showUpload else {
            sender.state = .on
            NSSound.beep()
            return
        }
        SpeedMeterSettingsStore.showDownload = enabling
        onSpeedMeterSettingsChanged?()
    }

    @objc private func unitChanged(_ sender: NSPopUpButton) {
        SpeedMeterSettingsStore.unit = SpeedUnit.allCases[sender.indexOfSelectedItem]
        onSpeedMeterSettingsChanged?()
    }

    @objc private func refreshIntervalChanged(_ sender: NSPopUpButton) {
        SpeedMeterSettingsStore.refreshInterval = Self.refreshIntervalOptions[sender.indexOfSelectedItem].seconds
        onSpeedMeterSettingsChanged?()
    }

    @objc private func restoreSpeedMeterDefaults() {
        SpeedMeterSettingsStore.isEnabled = true
        SpeedMeterSettingsStore.showUpload = true
        SpeedMeterSettingsStore.showDownload = true
        SpeedMeterSettingsStore.unit = .bytesBinary
        SpeedMeterSettingsStore.refreshInterval = 1.0

        speedMeterEnabledSwitch.state = .on
        showUploadSwitch.state = .on
        showDownloadSwitch.state = .on
        speedUnitPopup.selectItem(at: 0)
        refreshIntervalPopup.selectItem(at: Self.refreshIntervalOptions.firstIndex { $0.seconds == 1.0 } ?? 1)

        onSpeedMeterSettingsChanged?()
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

/// Draws a rounded, drop-shadowed backdrop behind whatever sits on top of
/// it (a sidebar badge icon, the sidebar card itself), via NSShadow inside
/// draw(_:) (plain Core Graphics) rather than CALayer's shadow properties
/// — those silently don't render on this machine, and even if they did,
/// they'd be clipped away by a masksToBounds set for rounded-corner
/// clipping on that same layer, since a layer's masksToBounds clips its
/// own shadow too. This view carries no masking of its own, so neither
/// problem applies; it just needs to be sized contentInset bigger than the
/// shape on top of it on every side, so the blur has room to fade out
/// before hitting this view's own edge (draw(_:) is clipped to that).
/// A plain colored circle standing in for one native traffic-light
/// button — see addCustomTrafficLights's doc comment for why. Click
/// handling is a bare mouseDown override rather than NSButton/NSCell
/// machinery, since all this needs is "run a closure on click", not any
/// of NSButton's state/highlighting/key-equivalent behavior.
private final class TrafficLightButton: NSView {
    var diameter: CGFloat = 12 {
        didSet { layer?.cornerRadius = diameter / 2 }
    }
    var color: NSColor = .clear {
        didSet { layer?.backgroundColor = color.cgColor }
    }
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.backgroundColor = color.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

private final class DropShadowView: NSView {
    // Set for an icon badge shadow: redraws the icon itself (rather than a
    // plain filled rect) so the shadow's shape always matches the icon's
    // own alpha silhouette — whatever this hides behind gets covered
    // exactly by that same icon drawn on top in imageView, with no
    // mismatched edges peeking through as a flat colored box. Leave nil
    // (and set cornerRadius instead) for a plain rounded-rect shadow, e.g.
    // behind a solid card that has no transparent margin of its own.
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    var cornerRadius: CGFloat = 0
    var contentInset: CGFloat = 0
    var shadowOpacity: CGFloat = 0.2
    var shadowBlurRadius: CGFloat = 4
    var shadowOffset: NSSize = NSSize(width: 0, height: -1)

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowOpacity)
        shadow.shadowBlurRadius = shadowBlurRadius
        shadow.shadowOffset = shadowOffset
        shadow.set()
        let shapeRect = bounds.insetBy(dx: contentInset, dy: contentInset)
        if let image {
            // Clipped to the same rounded rect as imageView's own layer
            // mask: an icon with no transparent margin of its own (a plain
            // opaque square, e.g. a symbol glyph with a full-bleed
            // background) would otherwise paint sharp square corners here
            // that peek out from behind imageView's rounded ones.
            NSBezierPath(roundedRect: shapeRect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
            image.draw(in: shapeRect)
        } else {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: shapeRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A sidebar row cell with its own selection "pill" background, drawn at a
/// fixed 12px corner radius — the table's native selectionHighlightStyle
/// is off (see buildSidebar), so this is the only thing drawing it.
private final class SidebarCellView: NSTableCellView {
    var badgeShadow: DropShadowView!

    let pillBackground: NSBox = {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 14
        box.fillColor = .clear
        return box
    }()

    var isRowSelected = false {
        didSet {
            pillBackground.fillColor = isRowSelected ? .controlAccentColor : .clear
            textField?.textColor = isRowSelected ? .white : .labelColor
        }
    }
}
