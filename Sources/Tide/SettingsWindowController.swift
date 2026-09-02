import AppKit

/// The "Settings…" window, laid out to match macOS System Settings: a real
/// NSTableView sidebar in `.sourceList` style with rounded icon badges, and
/// content panes built from squircle "card" groups (SquircleBox) with NSSwitch
/// toggles and hairline dividers between rows — the same visual language
/// System Settings itself uses, rather than a generic checkbox form.
/// Shortcut persistence/registration is still owned by the app delegate via
/// `applyShortcutChange`; Save/Copy and Launch at Login are simple enough
/// to read/write directly from here.
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    /// Returns true if `combo` (nil means "clear") was applied successfully.
    var applyShortcutChange: ((ShortcutAction, KeyCombo?) -> Bool)?

    /// Triggered by the "Check for Updates…" button; the app delegate owns
    /// the actual check + install flow since it needs to show alerts.
    var checkForUpdates: (() -> Void)?

    /// Triggered after any Speed Meter setting changes, so the app
    /// delegate can apply it to the live menu bar display/timer right
    /// away instead of waiting for the next scheduled poll.
    var onSpeedMeterSettingsChanged: (() -> Void)?

    /// Triggered after any Scrolling setting changes, so the app delegate
    /// can install/remove the scroll event tap (and ask for Accessibility
    /// permission the first time) right away.
    var onScrollSettingsChanged: (() -> Void)?

    /// Whether the scroll event tap is actually installed right now, so
    /// the Scrolling pane can say so — the difference between "granted"
    /// and "actually reversing" is otherwise invisible, and a stale
    /// Accessibility grant (macOS keeps showing the app as enabled while
    /// silently refusing it) looks exactly like the feature not working.
    var isScrollReversingActive: (() -> Bool)?

    /// Triggered after the volume key setting changes, so the app delegate
    /// can install/remove the key tap (and ask for Accessibility the first
    /// time) right away.
    var onVolumeKeySettingsChanged: (() -> Void)?

    /// Whether the volume key tap is actually installed, so the Display
    /// pane can say so — same reasoning as isScrollReversingActive: a
    /// stale Accessibility grant looks exactly like the feature not
    /// working.
    var isVolumeKeyTapActive: (() -> Bool)?

    /// Fired when this window closes, so the app delegate can drop the
    /// Dock icon it puts up while Settings is open.
    var onWindowClose: (() -> Void)?

    private enum Tab: Int, CaseIterable {
        case general
        case screenshot
        case speedMeter
        case display
        case scrolling

        var title: String {
            switch self {
            case .general: return "General"
            case .screenshot: return "Screenshot"
            case .speedMeter: return "Speed Meter"
            case .display: return "Display"
            case .scrolling: return "Scrolling"
            }
        }

        // Bundled PNGs (from macosicons.com) rather than SF Symbol badges —
        // filenames match the resource names copied into the app bundle by
        // build_app.sh. Each is cropped so the artwork fills the whole
        // canvas: a transparent margin leaves the badge's drop shadow
        // tracing the canvas edge instead of the icon, which reads as a
        // black ring around it.
        var iconResourceName: String {
            switch self {
            case .general: return "SidebarGeneralIcon"
            case .screenshot: return "SidebarScreenshotIcon"
            case .speedMeter: return "SidebarSpeedMeterIcon"
            case .display: return "SidebarDisplayIcon"
            case .scrolling: return "SidebarScrollingIcon"
            }
        }
    }

    private static let captureActions: [ShortcutAction] = [.selectedArea, .window, .fullScreen]
    private static let sidebarCellIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")

    private let sidebarWidth: CGFloat = 220
    private let rowHeight: CGFloat = 40
    // sidebarIconSize + sidebarItemPadding above and below, so each item's
    // vertical padding matches its horizontal padding. Kept as the sum
    // rather than a literal: change the icon size and the row follows,
    // instead of silently drifting to some other padding.
    private let sidebarRowHeight = SettingsWindowController.sidebarIconSize
        + SettingsWindowController.sidebarItemPadding * 2
    // Gap between the item list (scrollView) and the sidebar card's own
    // edges, so the selection pill reads as inset from the card's border
    // rather than flush against it.
    private static let sidebarListInset: CGFloat = 12
    // Bigger top inset than the other edges: the sidebar card now runs up
    // to the window's own top edge (see cardTopMargin), so this keeps the
    // first pill clear of the traffic-light buttons floating above it.
    private static let sidebarListTopInset: CGFloat = 42
    // Padding around each item's own content (icon/text) within its row —
    // applied on all four sides, since sidebarRowHeight is derived from it.
    // 22pt badge + 5pt above and below lands the row on the 32pt System
    // Settings uses, measured as the pitch between its sidebar icons.
    private static let sidebarItemPadding: CGFloat = 5
    // Gap between a sidebar item's icon and its label text.
    private static let sidebarIconTextGap: CGFloat = 8
    // Rendered size of a sidebar item's icon badge, measured off System
    // Settings' own sidebar. The bundled PNGs are 256x256, so there is
    // plenty of detail to scale down from.
    private static let sidebarIconSize: CGFloat = 22
    // Corner radius of that badge. Shared with the shadow drawn behind it:
    // the two have to agree, or the shadow shows past the icon's corners
    // on one side of the rounding and falls short on the other.
    private static let sidebarIconCornerRadius: CGFloat = 7
    // Gap between a pane's content and everything around it: the window's
    // top, trailing and bottom edges, and the sidebar card on its left.
    // One flat value rather than card margin + inset, so the number here
    // is the distance actually seen on screen.
    private static let panePadding: CGFloat = 20
    // Padding around a small group card's rows, inside its own box.
    private static let smallCardPadding: CGFloat = 14
    // Minimum gap between a row's label and its trailing control.
    private static let rowContentGap: CGFloat = 8
    // Width every pane's group card is pinned to.
    private static let paneCardWidth: CGFloat = 460
    // Size of every toggle in the window (see makeSwitch). One step down
    // from the default, which reads less heavy next to the 13pt row labels.
    private static let switchControlSize: NSControl.ControlSize = .small
    // The dot carrying a status line's state, and its gap to the text.
    private static let statusDotSize: CGFloat = 8
    private static let statusDotGap: CGFloat = 6
    // Vertical padding around a text-only card row (makeTextRow), which
    // sizes to its text rather than to rowHeight.
    private static let textRowVerticalPadding: CGFloat = 12

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
    private var reverseScrollingSwitch: NSSwitch!
    private var reverseMouseSwitch: NSSwitch!
    private var reverseTrackpadSwitch: NSSwitch!
    private var scrollStatusLabel: NSTextField!
    private var scrollStatusDot: NSBox!
    private var volumeKeyStatusDot: NSBox!
    private var volumeKeySwitch: NSSwitch!
    private var volumeKeyStatusLabel: NSTextField!

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
        window.delegate = self
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

    func windowWillClose(_ notification: Notification) {
        onWindowClose?()
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

        // Whether each button does anything is read off the window's own
        // style mask rather than assumed: this window is .closable only, so
        // the other two would call performMiniaturize/performZoom into
        // nothing. Painting all three live regardless advertises actions
        // that don't exist — macOS greys out the ones a window can't do.
        let styleMask = window?.styleMask ?? []
        let lights: [(NSColor, Bool, () -> Void)] = [
            (NSColor(red: 1.0, green: 0.373, blue: 0.341, alpha: 1),
             styleMask.contains(.closable),
             { [weak self] in self?.window?.performClose(nil) }),
            (NSColor(red: 1.0, green: 0.741, blue: 0.180, alpha: 1),
             styleMask.contains(.miniaturizable),
             { [weak self] in self?.window?.performMiniaturize(nil) }),
            (NSColor(red: 0.157, green: 0.784, blue: 0.251, alpha: 1),
             styleMask.contains(.resizable),
             { [weak self] in self?.window?.performZoom(nil) })
        ]

        let symbols: [TrafficLightButton.Symbol] = [.close, .minimize, .zoom]
        let buttons = lights.enumerated().map { index, light -> TrafficLightButton in
            let button = TrafficLightButton()
            button.color = light.0
            button.isEnabled = light.1
            button.onClick = light.2
            button.symbol = symbols[index]
            button.frame = NSRect(
                x: CGFloat(index) * Self.trafficLightSpacing, y: 0,
                width: Self.trafficLightDiameter, height: Self.trafficLightDiameter
            )
            return button
        }

        // The three sit in one group so a single tracking area covers them
        // all: macOS reveals the symbols on every button as soon as the
        // pointer is anywhere over the cluster, and per-button tracking
        // would instead blink them off and on while crossing the gaps.
        let group = TrafficLightGroup(buttons: buttons)
        group.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(group)
        NSLayoutConstraint.activate([
            group.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.trafficLightLeading),
            group.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.trafficLightTop),
            group.widthAnchor.constraint(equalToConstant: Self.trafficLightSpacing * 2 + Self.trafficLightDiameter),
            group.heightAnchor.constraint(equalToConstant: Self.trafficLightDiameter)
        ])
    }

    // MARK: - Window layout

    /// System Settings' current layout isn't a sidebar flush against the
    /// window edges: both the sidebar and the content pane are separate
    /// floating rounded cards — sidebar in frosted glass, content in a
    /// flat white card — sitting with a margin on a plain white/light
    /// window backdrop. This mirrors that rather than one edge-to-edge
    /// split view.
    private static let cardMargin: CGFloat = 8
    // Rounding of the window's own backdrop. Named like every other
    // radius in here rather than left as a literal at the call site.
    private static let windowCornerRadius: CGFloat = 24
    private static let cardCornerRadius: CGFloat = 16
    // How much bigger than the sidebar card its DropShadowView is made, on
    // every side, matching that shadow's blurRadius (12) + offset (1).
    // Bigger than cardMargin, so the shadow gets clipped at the window's
    // own edge before fully fading out — acceptable now that it's subtle.
    private static let cardShadowPadding: CGFloat = 13
    // The small group cards in the right-hand panes get their own, smaller
    // radius rather than sharing the sidebar's.
    //
    // Matched to System Settings by measurement rather than by copying its
    // number: its cards straighten out 16 retina pixels below their top
    // edge, and 11 was what landed on that. The value dates from when these
    // cards were circular-cornered NSBoxes, which needed a bigger number
    // than Apple's to look the same; they are true squircles now
    // (SquircleBox), so it is worth re-measuring rather than trusted.
    private static let smallCardCornerRadius: CGFloat = 11
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
        // SquircleBox rather than NSBox: NSBox's cornerRadius is a
        // circular arc, and macOS rounds a window's backdrop with a
        // continuous (squircle) curve. It also paints nothing outside that
        // curve, so the window's four corner pixels stay at alpha 0 and
        // show the desktop — see the window's isOpaque/backgroundColor
        // above. Unlike NSBox it does not clip its own subviews to the
        // rounded shape either, so the traffic-light replacements and the
        // sidebar card shadow no longer have a corner sliver to stay clear
        // of.
        let root = SquircleBox()
        root.cornerRadius = Self.windowCornerRadius
        root.fillColor = Self.pageFillColor

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
                pane.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.panePadding),
                pane.leadingAnchor.constraint(equalTo: sidebarCard.trailingAnchor, constant: Self.panePadding),
                pane.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Self.panePadding),
                // Required inequality, so it also acts as the window's
                // minimum height the way the trailing one already fixes
                // its width: the tallest pane (Screenshot, two cards)
                // would otherwise run past the window's bottom edge and
                // get clipped, since panes are laid out from the top and
                // nothing else drives the content height.
                pane.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -Self.panePadding)
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
        // consistent flat palette. SquircleBox rather than NSBox: continuous
        // corners like every other card, drawn with nothing outside the
        // curve so the page shows through the four corners at alpha 0. Its
        // fill/border stay NSColors resolved at draw time, the way NSBox's
        // did — a layer-backed NSView would freeze them at one appearance.
        let background = SquircleBox()
        background.cornerRadius = Self.cardCornerRadius
        background.borderWidth = 1
        background.borderColor = Self.cardBorderColor
        background.fillColor = Self.sidebarCardFillColor
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
        cell.textField?.stringValue = tab.title
        cell.imageView?.image = Self.sidebarIcon(named: tab.iconResourceName)
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
        // Without this, the 256x256 source PNGs render cropped to the
        // view's much smaller bounds instead of scaled down to fit them — NSImageView's default imageScaling
        // isn't a reliable proportional fit once the view is layer-backed
        // (needed below for corner clipping).
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Clip to a rounded rect regardless of how each source icon's own
        // corners look at full size — otherwise they read inconsistently
        // once scaled down to a 24pt badge.
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.sidebarIconCornerRadius
        // Continuous corners, matching the squircle shadow drawn behind it
        // below (and the shape every macOS app icon already has) — a
        // circular clip here would show the shadow past the badge's corners.
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true

        // A separate view behind the badge draws its drop shadow: CALayer's
        // shadow properties don't render at all on this machine, and even
        // if they did, they'd be clipped away by imageView's own
        // masksToBounds above (needed for the rounded-corner clip) since a
        // layer's masksToBounds clips its own shadow too. NSShadow inside
        // draw(_:) avoids both problems — plain Core Graphics, on its own
        // view with no masking. Filled as a plain rounded rect at the same
        // corner radius as imageView's own clip, rather than traced from
        // each icon's actual alpha shape: the bundled icons vary in how
        // much transparent margin they carry around their own artwork, so
        // a shadow derived from each image's real silhouette came out a
        // different size per icon instead of a uniform badge shadow.
        // Sized contentInset bigger than the badge on every side so the
        // blur has room to fade out before hitting this view's own edge
        // (draw(_:) is clipped to that).
        let badgeShadow = DropShadowView()
        badgeShadow.cornerRadius = Self.sidebarIconCornerRadius
        badgeShadow.shadowOpacity = 0.45
        badgeShadow.shadowBlurRadius = 7
        badgeShadow.shadowOffset = NSSize(width: 0, height: -2)
        // Has to clear shadowBlurRadius plus the offset, or draw(_:)'s own
        // clip cuts the shadow off along the bottom edge.
        badgeShadow.contentInset = 11
        badgeShadow.shapeInset = 1.5
        badgeShadow.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = NSFont.systemFont(ofSize: 13)

        cell.addSubview(badgeShadow)
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            cell.pillBackground.topAnchor.constraint(equalTo: cell.topAnchor),
            cell.pillBackground.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            cell.pillBackground.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            cell.pillBackground.bottomAnchor.constraint(equalTo: cell.bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.sidebarItemPadding),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: Self.sidebarIconSize),
            imageView.heightAnchor.constraint(equalToConstant: Self.sidebarIconSize),

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
        case .speedMeter: return buildSpeedMeterPane()
        case .display: return buildDisplayPane()
        case .scrolling: return buildScrollingPane()
        }
    }

    // MARK: - Shared pane chrome (title + card group)

    private func makePaneTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        // 22pt lands this on the same glyph height as System Settings' own
        // pane title, measured on both: 16.5pt of cap height, where 20pt
        // was giving 15.
        label.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        return label
    }


    /// Fill for the group cards in the panes: a translucent white wash, so
    /// a card sits *lighter* than the page it is on.
    ///
    /// This only works because pageFillColor is a grey rather than white.
    /// White over white is still white, which is what made an earlier
    /// attempt at this vanish in Light Mode.
    ///
    /// Measured off System Settings, the Light card came out #F9F9F9 on a
    /// #F6F6F6 page — three levels apart, which reads as the card sinking
    /// into the page rather than sitting on it, so this deliberately goes
    /// past the measurement: solid white in Light, and a bigger lift than
    /// the measured ~20% in Dark.
    private static let groupCardFillColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.white.withAlphaComponent(isDark ? 0.08 : 1.0)
    }

    /// Fill for the sidebar card, which is deliberately *not* the same as
    /// the group cards.
    ///
    /// System Settings moves the two in opposite directions in Dark Mode:
    /// its group cards lift about 20% above the page while its sidebar
    /// drops about 10% below it, the sidebar reading as a recess rather
    /// than a raised panel. In Light Mode both sit lighter than the page,
    /// so the two agree there.
    private static let sidebarCardFillColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor.black.withAlphaComponent(0.10)
            : NSColor.white.withAlphaComponent(0.33)
    }

    /// The window's backdrop. Explicit rather than .controlBackgroundColor,
    /// which measured #FFFFFF in Light Mode — pure white leaves no room for
    /// a card to be lighter than it. System Settings gets its own grey from
    /// an NSVisualEffectView material, not from a semantic colour, so this
    /// matches the measured result instead of the mechanism.
    private static let pageFillColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(white: 0x1E / 255, alpha: 1)
            : NSColor(white: 0xF6 / 255, alpha: 1)
    }

    /// The rim around the two big cards. White at 80% reads as a soft
    /// highlight against a light window, but the same value on a dark one
    /// is a hard white outline drawn around everything (the fill behind it
    /// is only 0.16 white), so Dark Mode gets a far lower opacity.
    private static let cardBorderColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.white.withAlphaComponent(isDark ? 0.12 : 0.8)
    }

    /// Hairline between a card's rows. Same problem as cardBorderColor: a
    /// fixed near-white is a faint line on a light card and a bright one
    /// on a dark card.
    private static let cardDividerColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor(white: 0.9, alpha: 1)
    }

    /// A rounded, filled group box with hairline dividers between its rows
    /// — System Settings' basic building block for every pane.
    private func makeCard(rows: [NSView]) -> NSView {
        let box = SquircleBox()
        box.cornerRadius = Self.smallCardCornerRadius
        // Now that the page itself is pure white, the card needs its own
        // gray fill to read as a distinct card at all — controlBackgroundColor
        // (also white) was flush with the page and invisible.
        box.fillColor = Self.groupCardFillColor
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
                divider.fillColor = Self.cardDividerColor
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

    /// A card row holding stacked wrapping text instead of a control —
    /// explanatory copy and live status that belong to the group above
    /// them, so they sit inside the same card rather than loose beneath
    /// it. Height comes from the text, unlike makeRow's fixed rowHeight.
    /// A status line in the System Settings idiom: a coloured dot carries
    /// the state and the sentence stays in ordinary text. Tinting the whole
    /// sentence instead makes it read as a warning even when it is just
    /// reporting that everything is fine.
    private func makeStatusRow(dot: NSBox, label: NSTextField) -> NSView {
        let row = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(dot)
        row.addSubview(label)

        label.preferredMaxLayoutWidth = Self.paneCardWidth - Self.smallCardPadding * 2
            - Self.statusDotSize - Self.statusDotGap

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.statusDotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.statusDotSize),
            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            // Tied to the first line's baseline rather than to the row's
            // centre, so the dot stays beside the opening words instead of
            // drifting down the side of a wrapped paragraph.
            dot.bottomAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -1),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: Self.statusDotGap),
            label.topAnchor.constraint(equalTo: row.topAnchor),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    /// Sets a status line's text and tints both the dot and the sentence
    /// from one colour, so the two can't drift apart.
    private func applyStatus(dot: NSBox, label: NSTextField, _ text: String, _ color: NSColor) {
        label.stringValue = text
        label.textColor = color
        dot.fillColor = color
    }

    private func makeStatusDot() -> NSBox {
        let dot = NSBox()
        dot.boxType = .custom
        dot.borderWidth = 0
        dot.cornerRadius = Self.statusDotSize / 2
        dot.fillColor = .secondaryLabelColor
        return dot
    }

    private func makeTextRow(labels: [NSView]) -> NSView {
        let row = NSView()
        let textStack = NSStackView(views: labels)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6
        textStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(textStack)

        // Wrapping NSTextFields need an explicit wrap width to report the
        // right height to Auto Layout; the card's own width minus its
        // padding is that width. Views that aren't text (a status line,
        // which sets its own narrower width) are left alone.
        for case let label as NSTextField in labels {
            label.preferredMaxLayoutWidth = Self.paneCardWidth - Self.smallCardPadding * 2
        }

        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: Self.textRowVerticalPadding),
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Self.textRowVerticalPadding)
        ])
        return row
    }

    /// A fixed-height row with a leading view pinned left and a trailing
    /// view pinned right, both vertically centered — the standard "label
    /// … control" row shape used throughout System Settings.
    /// Every toggle in the window is built here so they all share one
    /// size. Set at each construction site instead, this is exactly the
    /// kind of value that ends up different from pane to pane.
    private func makeSwitch(isOn: Bool, action: Selector) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = Self.switchControlSize
        control.state = isOn ? .on : .off
        control.target = self
        control.action = action
        return control
    }

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

        launchAtLoginSwitch = makeSwitch(isOn: LoginItemManager.isEnabled, action: #selector(toggleLaunchAtLogin(_:)))
        let launchRow = makeRow(leading: NSTextField(labelWithString: "Launch at Login"), trailing: launchAtLoginSwitch)

        let versionLabel = NSTextField(labelWithString: "Version \(Self.currentVersion)")
        versionLabel.textColor = .secondaryLabelColor
        let checkUpdatesButton = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdatesTapped))
        checkUpdatesButton.bezelStyle = .rounded
        let updateRow = makeRow(leading: versionLabel, trailing: checkUpdatesButton)

        let card = makeCard(rows: [launchRow, updateRow])
        card.widthAnchor.constraint(equalToConstant: Self.paneCardWidth).isActive = true
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

    // MARK: - Display pane

    private func buildDisplayPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        stack.addArrangedSubview(makePaneTitle("Display"))

        volumeKeySwitch = makeSwitch(isOn: DisplaySettingsStore.useVolumeKeys, action: #selector(toggleVolumeKeys(_:)))
        let volumeKeyRow = makeRow(
            leading: NSTextField(labelWithString: "Volume Keys Control Monitor Speakers"),
            trailing: volumeKeySwitch
        )

        let card = makeCard(rows: [volumeKeyRow])
        card.widthAnchor.constraint(equalToConstant: Self.paneCardWidth).isActive = true
        stack.addArrangedSubview(card)

        let caption = NSTextField(wrappingLabelWithString: "Brightness and volume sliders for every connected display live in Tide’s menu bar menu.\n\nWhen sound plays through a monitor’s own speakers, macOS can’t change their volume and the volume keys do nothing. Turn this on to let Tide handle those keys over DDC instead. Requires Accessibility permission.")
        caption.font = NSFont.systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        volumeKeyStatusLabel = NSTextField(wrappingLabelWithString: "")
        volumeKeyStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        volumeKeyStatusLabel.textColor = .secondaryLabelColor

        // Its own card rather than more rows in the one above: the copy and
        // the status line describe the setting, they aren't settings
        // themselves — same treatment as the Scrolling pane.
        // One card, but as two rows so makeCard draws its hairline between
        // them: the status is the line that changes while the window is
        // open, and running straight into a static paragraph made it read
        // as part of the same sentence.
        volumeKeyStatusDot = makeStatusDot()
        let notesCard = makeCard(rows: [
            makeTextRow(labels: [makeStatusRow(dot: volumeKeyStatusDot, label: volumeKeyStatusLabel)]),
            makeTextRow(labels: [caption])
        ])
        notesCard.widthAnchor.constraint(equalToConstant: Self.paneCardWidth).isActive = true
        stack.addArrangedSubview(notesCard)

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDisplayDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)

        refreshVolumeKeyStatus()

        return stack
    }

    @objc private func restoreDisplayDefaults() {
        DisplaySettingsStore.useVolumeKeys = false
        volumeKeySwitch.state = .off
        onVolumeKeySettingsChanged?()
        refreshVolumeKeyStatus()
    }

    @objc private func toggleVolumeKeys(_ sender: NSSwitch) {
        DisplaySettingsStore.useVolumeKeys = sender.state == .on
        onVolumeKeySettingsChanged?()
        refreshVolumeKeyStatus()
    }

    func refreshVolumeKeyStatus() {
        guard volumeKeyStatusLabel != nil else { return }
        if !DisplaySettingsStore.useVolumeKeys {
            applyStatus(dot: volumeKeyStatusDot, label: volumeKeyStatusLabel,
                        "Off", .secondaryLabelColor)
        } else if isVolumeKeyTapActive?() == true {
            applyStatus(dot: volumeKeyStatusDot, label: volumeKeyStatusLabel,
                        "Active — the volume keys reach the monitor whenever macOS can’t control the current output itself.",
                        .systemGreen)
        } else {
            applyStatus(dot: volumeKeyStatusDot, label: volumeKeyStatusLabel,
                        "Waiting for Accessibility permission. If Tide already looks enabled in System Settings, switch it off and on again — macOS keeps grants tied to a specific build, so an older entry stays listed but no longer counts.",
                        .systemOrange)
        }
    }

    @objc private func checkForUpdatesTapped() {
        checkForUpdates?()
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: - Screenshot pane (Save/Copy destinations + shortcuts)

    /// One row per capture type carrying everything about it — where the
    /// capture goes and what key triggers it — instead of splitting the
    /// same three capture types across two sidebar tabs (or two cards),
    /// which made the reader match rows up by name across groups.
    private func buildScreenshotPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        stack.addArrangedSubview(makePaneTitle("Screenshot"))

        let card = makeCard(rows: Self.captureActions.map { makeScreenshotRow(for: $0) })
        card.widthAnchor.constraint(equalToConstant: Self.paneCardWidth).isActive = true
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

        let trailing = NSStackView(views: [saveGroup, copyGroup, makeShortcutRecorder(for: action)])
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

    /// Restores both of the pane's cards, since they now share one button.
    @objc private func restoreScreenshotDefaults() {
        for action in Self.captureActions {
            CaptureSettingsStore.setSaveEnabled(true, for: action)
            CaptureSettingsStore.setCopyEnabled(true, for: action)
            saveSwitches[action]?.state = .on
            copySwitches[action]?.state = .on
        }
        restoreShortcutDefaults()
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

        speedMeterEnabledSwitch = makeSwitch(isOn: SpeedMeterSettingsStore.isEnabled, action: #selector(toggleSpeedMeterEnabled(_:)))
        let enabledRow = makeRow(leading: NSTextField(labelWithString: "Show Speed on Menu Bar"), trailing: speedMeterEnabledSwitch)

        showUploadSwitch = makeSwitch(isOn: SpeedMeterSettingsStore.showUpload, action: #selector(toggleShowUpload(_:)))
        let uploadRow = makeRow(leading: NSTextField(labelWithString: "Show Upload (↑)"), trailing: showUploadSwitch)

        showDownloadSwitch = makeSwitch(isOn: SpeedMeterSettingsStore.showDownload, action: #selector(toggleShowDownload(_:)))
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
        card.widthAnchor.constraint(equalToConstant: Self.paneCardWidth).isActive = true
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

    // MARK: - Scrolling pane

    private func buildScrollingPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        stack.addArrangedSubview(makePaneTitle("Scrolling"))

        reverseScrollingSwitch = makeSwitch(isOn: ScrollSettingsStore.isEnabled, action: #selector(toggleReverseScrolling(_:)))
        let enabledRow = makeRow(leading: NSTextField(labelWithString: "Reverse Scroll Direction"), trailing: reverseScrollingSwitch)

        reverseMouseSwitch = makeSwitch(isOn: ScrollSettingsStore.reverseMouse, action: #selector(toggleReverseMouse(_:)))
        let mouseRow = makeRow(leading: NSTextField(labelWithString: "Reverse Mouse"), trailing: reverseMouseSwitch)

        reverseTrackpadSwitch = makeSwitch(isOn: ScrollSettingsStore.reverseTrackpad, action: #selector(toggleReverseTrackpad(_:)))
        let trackpadRow = makeRow(leading: NSTextField(labelWithString: "Reverse Trackpad"), trailing: reverseTrackpadSwitch)

        let caption = NSTextField(wrappingLabelWithString: "macOS shares one “Natural scrolling” setting across every device. Leave it set for one device and reverse the other one here. Requires Accessibility permission.")
        caption.font = NSFont.systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        scrollStatusLabel = NSTextField(wrappingLabelWithString: "")
        scrollStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        scrollStatusLabel.textColor = .secondaryLabelColor

        let card = makeCard(rows: [enabledRow, mouseRow, trackpadRow])
        card.widthAnchor.constraint(equalToConstant: Self.paneCardWidth).isActive = true
        stack.addArrangedSubview(card)

        // Its own card rather than a fourth row in the one above: the copy
        // and the status line describe the whole group, they aren't one
        // more setting in it.
        // One card, but as two rows so makeCard draws its hairline between
        // them: the status is the line that changes while the window is
        // open, and running straight into a static paragraph made it read
        // as part of the same sentence.
        scrollStatusDot = makeStatusDot()
        let notesCard = makeCard(rows: [
            makeTextRow(labels: [makeStatusRow(dot: scrollStatusDot, label: scrollStatusLabel)]),
            makeTextRow(labels: [caption])
        ])
        notesCard.widthAnchor.constraint(equalToConstant: Self.paneCardWidth).isActive = true
        stack.addArrangedSubview(notesCard)

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreScrollingDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)

        updateScrollingSubSwitchAvailability()
        refreshScrollStatus()
        return stack
    }

    /// Reads live state every time rather than caching: Accessibility can
    /// be granted (or revoked) in System Settings while this window sits
    /// open, and the tap starts by itself a moment later.
    func refreshScrollStatus() {
        guard scrollStatusLabel != nil else { return }
        if !ScrollSettingsStore.isActive {
            applyStatus(dot: scrollStatusDot, label: scrollStatusLabel,
                        "Off", .secondaryLabelColor)
        } else if isScrollReversingActive?() == true {
            applyStatus(dot: scrollStatusDot, label: scrollStatusLabel,
                        "Active — reversing scroll events.", .systemGreen)
        } else {
            applyStatus(dot: scrollStatusDot, label: scrollStatusLabel,
                        "Waiting for Accessibility permission. If Tide already looks enabled in System Settings, switch it off and on again — macOS keeps grants tied to a specific build, so an older entry stays listed but no longer counts.",
                        .systemOrange)
        }
    }

    /// The per-device switches only mean anything while the master switch
    /// is on, so they dim with it rather than silently doing nothing.
    private func updateScrollingSubSwitchAvailability() {
        let enabled = reverseScrollingSwitch.state == .on
        reverseMouseSwitch.isEnabled = enabled
        reverseTrackpadSwitch.isEnabled = enabled
    }

    @objc private func toggleReverseScrolling(_ sender: NSSwitch) {
        ScrollSettingsStore.isEnabled = sender.state == .on
        updateScrollingSubSwitchAvailability()
        onScrollSettingsChanged?()
        refreshScrollStatus()
    }

    @objc private func toggleReverseMouse(_ sender: NSSwitch) {
        ScrollSettingsStore.reverseMouse = sender.state == .on
        onScrollSettingsChanged?()
        refreshScrollStatus()
    }

    @objc private func toggleReverseTrackpad(_ sender: NSSwitch) {
        ScrollSettingsStore.reverseTrackpad = sender.state == .on
        onScrollSettingsChanged?()
        refreshScrollStatus()
    }

    @objc private func restoreScrollingDefaults() {
        ScrollSettingsStore.isEnabled = false
        ScrollSettingsStore.reverseMouse = true
        ScrollSettingsStore.reverseTrackpad = false

        reverseScrollingSwitch.state = .off
        reverseMouseSwitch.state = .on
        reverseTrackpadSwitch.state = .off
        updateScrollingSubSwitchAvailability()

        onScrollSettingsChanged?()
        refreshScrollStatus()
    }

    // MARK: - Shortcut recording (trailing control of a Screenshot row)

    private func makeShortcutRecorder(for action: ShortcutAction) -> NSView {
        let recorder = ShortcutRecorderControl(frame: NSRect(x: 0, y: 0, width: 130, height: 22))
        recorder.widthAnchor.constraint(equalToConstant: 130).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 22).isActive = true
        recorder.combo = ShortcutStore.combo(for: action)
        recorder.onChange = { [weak self, weak recorder] newCombo in
            guard let self, let recorder else { return }
            self.handleShortcutChange(action: action, recorder: recorder, newCombo: newCombo)
        }
        recorders[action] = recorder
        return recorder
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

    private func restoreShortcutDefaults() {
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
/// Holds the three traffic lights and lights their symbols together.
///
/// macOS shows the symbols on all three the moment the pointer reaches the
/// cluster, not just on the one under it, so the hover state belongs to the
/// group rather than to each button.
private final class TrafficLightGroup: NSView {

    private let buttons: [TrafficLightButton]
    private var hoverTrackingArea: NSTrackingArea?

    init(buttons: [TrafficLightButton]) {
        self.buttons = buttons
        super.init(frame: .zero)
        buttons.forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        // .activeAlways because the Settings window is often not the key
        // window while the pointer is over it.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        for button in buttons {
            button.isHovered = hovered
        }
    }
}

private final class TrafficLightButton: NSView {
    var color: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    /// False for an action this window doesn't support, which draws the
    /// button in the grey macOS uses for exactly that and stops it
    /// responding to clicks.
    var isEnabled = true {
        didSet { needsDisplay = true }
    }

    var onClick: (() -> Void)?

    /// Drawn rather than set as a layer background: a CGColor is resolved
    /// once and never re-resolves, so the disabled grey would keep its
    /// launch-time appearance after the system switches between Light and
    /// Dark. Filling inside draw(_:) picks the right one every time.
    private static let disabledColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(white: isDark ? 0.33 : 0.84, alpha: 1)
    }

    enum Symbol {
        case close
        case minimize
        case zoom
    }

    var symbol: Symbol = .close

    /// Set for the whole cluster at once by TrafficLightGroup.
    var isHovered = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        (isEnabled ? color : Self.disabledColor).setFill()
        NSBezierPath(ovalIn: bounds).fill()

        // A disabled button stays a bare circle on hover — the symbol would
        // be advertising an action the window can't perform.
        guard isHovered, isEnabled else { return }
        drawSymbol()
    }

    private func drawSymbol() {
        let inset = bounds.width * Self.symbolInsetRatio
        let box = bounds.insetBy(dx: inset, dy: inset)

        let path = NSBezierPath()
        path.lineWidth = max(1, bounds.width * Self.symbolLineWidthRatio)
        path.lineCapStyle = .round

        switch symbol {
        case .close:
            path.move(to: NSPoint(x: box.minX, y: box.minY))
            path.line(to: NSPoint(x: box.maxX, y: box.maxY))
            path.move(to: NSPoint(x: box.minX, y: box.maxY))
            path.line(to: NSPoint(x: box.maxX, y: box.minY))
        case .minimize:
            path.move(to: NSPoint(x: box.minX, y: box.midY))
            path.line(to: NSPoint(x: box.maxX, y: box.midY))
        case .zoom:
            path.move(to: NSPoint(x: box.minX, y: box.midY))
            path.line(to: NSPoint(x: box.maxX, y: box.midY))
            path.move(to: NSPoint(x: box.midX, y: box.minY))
            path.line(to: NSPoint(x: box.midX, y: box.maxY))
        }

        NSColor.black.withAlphaComponent(0.55).setStroke()
        path.stroke()
    }

    /// Both as a fraction of the button's diameter, so the glyphs keep
    /// their proportions if trafficLightDiameter is ever changed.
    private static let symbolInsetRatio: CGFloat = 0.29
    private static let symbolLineWidthRatio: CGFloat = 0.105

    // Declaring init(coder:) suppresses the inherited initialisers, so the
    // designated one has to be spelled out for TrafficLightButton() to work.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }
}

private final class DropShadowView: NSView {
    var cornerRadius: CGFloat = 0
    var contentInset: CGFloat = 0
    // How much smaller the filled shape is than the icon it sits behind —
    // separate from contentInset (which only sizes this view for blur
    // bleed room via its own constraints). Any icon has at least a
    // sub-pixel anti-aliased edge once scaled down to badge size, so a
    // filled shape sized to match the icon exactly still shows a faint
    // dark rim there. Pulling the shape in a bit keeps it safely behind
    // the icon's opaque interior instead.
    var shapeInset: CGFloat = 0
    var shadowOpacity: CGFloat = 0.3
    var shadowBlurRadius: CGFloat = 4
    var shadowOffset: NSSize = NSSize(width: 0, height: -1)

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()

        let inset = contentInset + shapeInset
        // Same continuous-corner shape the cards themselves are drawn with
        // (SquircleBox) — a circular rounded rect here would spill past the
        // card's corners along the diagonal and fall short along the edges.
        let shape = NSBezierPath.squircle(
            in: bounds.insetBy(dx: inset, dy: inset),
            cornerRadius: cornerRadius
        )

        // Clip the shape's own interior away, leaving only the shadow it
        // casts outside itself. A shadow needs something opaque to fall
        // from, but that black fill stays on screen too — harmless under
        // fully opaque content, and a solid black slab showing straight
        // through anything translucent laid on top.
        let hole = NSBezierPath(rect: bounds)
        hole.append(shape)
        hole.windingRule = .evenOdd
        hole.addClip()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowOpacity)
        shadow.shadowBlurRadius = shadowBlurRadius
        shadow.shadowOffset = shadowOffset
        shadow.set()
        NSColor.black.setFill()
        shape.fill()

        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A sidebar row cell with its own selection "pill" background — the
/// table's native selectionHighlightStyle is off (see buildSidebar), so
/// this is the only thing drawing it.
///
/// Rounded less than the group cards, which is the relationship System
/// Settings draws: its pills straighten out 10 retina pixels down, against
/// 16 for a card. See smallCardCornerRadius for why the radius here isn't
/// simply Apple's own number.
private final class SidebarCellView: NSTableCellView {
    let pillBackground: NSBox = {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 7
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
