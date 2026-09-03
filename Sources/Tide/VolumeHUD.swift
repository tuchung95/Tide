import AppKit

/// The floating panel shown when a volume key changes a monitor's volume.
///
/// Tide swallows those keys (see VolumeKeyTap), so macOS never puts up its
/// own volume HUD — without this, a keypress would change the monitor's
/// volume with nothing on screen to say it worked. This is the stand-in,
/// laid out to match the panel it replaces: the device name over a slider
/// flanked by a quiet and a loud speaker icon, with a row of tick dots
/// under the track for the steps a volume key moves in.
///
/// A non-activating, click-through panel rather than an NSPopover: a
/// popover would need somewhere to anchor and would pull focus to Tide,
/// which is exactly wrong for something that appears while the user is
/// working in another app.
final class VolumeHUD {

    private var panel: NSPanel?
    private var titleLabel: NSTextField!
    private var levelView: LevelBar!
    private var hideWorkItem: DispatchWorkItem?

    // Proportioned off macOS's own volume HUD — wide and shallow, where
    // this used to be a small squarish card.
    private static let panelSize = NSSize(width: 310, height: 72)
    private static let cornerRadius: CGFloat = 18
    private static let visibleDuration: TimeInterval = 1.2

    /// Shows (or refreshes) the HUD for `title` at `level` 0…1.
    ///
    /// Repeated calls while it's already up just update it and restart the
    /// timer, so holding a volume key keeps one steady panel on screen
    /// instead of flickering it once per repeat.
    func show(title: String, level: Float, anchoredTo statusButton: NSStatusBarButton?) {
        let panel = panelIfNeeded()

        titleLabel.stringValue = title
        levelView.level = CGFloat(min(max(level, 0), 1))

        // Placed only when the HUD isn't already on screen. Tide's menu
        // bar item is a live speed readout whose width changes with the
        // number in it, so re-anchoring on every key press walked the
        // panel sideways while the volume was still being adjusted — it
        // stays put now for as long as one showing lasts, fade-out
        // included, and re-anchors only on its next appearance.
        if !panel.isVisible {
            panel.setFrameOrigin(Self.origin(anchoredTo: statusButton))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: workItem)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    // MARK: - Panel construction

    private func panelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            // .nonactivatingPanel is what keeps the user's current app
            // frontmost when this appears.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above ordinary windows but below the menu bar itself, and
        // present on every Space including over a full-screen app —
        // otherwise it simply wouldn't appear where it's most needed.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        // Pinned dark, the way macOS's own volume HUD is in either
        // appearance. Left to follow the system, the material turns pale
        // grey in light mode and the white text and level bar on it are
        // barely legible.
        background.appearance = NSAppearance(named: .darkAqua)
        // Without .active the material greys out whenever Tide isn't the
        // frontmost app — which is always, for a menu bar utility.
        background.state = .active
        // Shaped with maskImage rather than a layer cornerRadius +
        // masksToBounds: a .behindWindow material is composited by the
        // window server, outside this process and past any layer mask set
        // here, so the blur — and the window shadow traced from it — kept
        // the panel's full square and leaked out past the curve at all
        // four corners. maskImage is the hook the server does honour, and
        // it takes the same NSBezierPath.squircle the Settings page and
        // cards use (SquircleBox), so the HUD's corners match theirs
        // exactly instead of the tighter circular arc a layer draws.
        background.maskImage = Self.cornerMask(radius: Self.cornerRadius)

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 12, y: 40, width: Self.panelSize.width - 24, height: 16)
        titleLabel.autoresizingMask = [.width]

        // Two fixed icons marking the ends of the range, as macOS's HUD
        // has, rather than the single icon that used to change with the
        // level: at a glance the panel then reads as a slider between
        // quiet and loud instead of as a status symbol.
        let quietIcon = Self.iconView(
            named: "speaker.fill",
            pointSize: 11,
            frame: NSRect(x: 11, y: 17.5, width: 13, height: 13)
        )
        let loudIcon = Self.iconView(
            named: "speaker.wave.3.fill",
            pointSize: 12,
            frame: NSRect(x: Self.panelSize.width - 33, y: 17.5, width: 19, height: 13)
        )
        loudIcon.autoresizingMask = [.minXMargin]

        levelView = LevelBar(frame: NSRect(
            x: 32,
            y: 12,
            width: Self.panelSize.width - 76,
            height: LevelBar.height
        ))
        levelView.autoresizingMask = [.width]

        // The pale rim macOS's HUD carries along its edge. Drawn as a
        // SquircleBox so the stroke follows exactly the same curve the
        // mask above clips to, and left unfilled so only the outline
        // lands on top of the material.
        let rim = SquircleBox(frame: NSRect(origin: .zero, size: Self.panelSize))
        rim.cornerRadius = Self.cornerRadius
        rim.borderColor = NSColor.white.withAlphaComponent(0.18)
        rim.borderWidth = 1
        rim.autoresizingMask = [.width, .height]

        background.addSubview(titleLabel)
        background.addSubview(quietIcon)
        background.addSubview(loudIcon)
        background.addSubview(levelView)
        background.addSubview(rim)
        background.autoresizingMask = [.width, .height]
        panel.contentView = background

        self.panel = panel
        return panel
    }

    /// The squircle silhouette the material is clipped to, as a nine-part
    /// resizable image: only the four corner tiles carry the curve, and
    /// the cap insets let AppKit stretch the flat middle out to whatever
    /// size the panel is without smearing them.
    private static func cornerMask(radius: CGFloat) -> NSImage {
        // A squircle corner runs 1.52866483 × radius along each edge
        // before it meets the straight part, so a corner tile has to be at
        // least that big to hold the whole curve.
        let corner = ceil(radius * 1.52866483)
        let size = NSSize(width: corner * 2 + 1, height: corner * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath.squircle(in: rect, cornerRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: corner, left: corner, bottom: corner, right: corner)
        image.resizingMode = .stretch
        return image
    }

    private static func iconView(named name: String, pointSize: CGFloat, frame: NSRect) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Volume")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
        image?.isTemplate = true

        let view = NSImageView(frame: frame)
        view.image = image
        view.contentTintColor = .white
        view.imageScaling = .scaleProportionallyDown
        return view
    }

    /// Centred under Tide's own menu bar item, so the HUD reads as coming
    /// from Tide. Falls back to the top centre of the main screen if the
    /// status item has no window yet.
    private static func origin(anchoredTo statusButton: NSStatusBarButton?) -> NSPoint {
        let gapBelowMenuBar: CGFloat = 8

        if let window = statusButton?.window {
            let inScreen = window.convertToScreen(statusButton!.bounds)
            return NSPoint(
                x: clampedToScreen(inScreen.midX - panelSize.width / 2, near: window.screen),
                y: inScreen.minY - panelSize.height - gapBelowMenuBar
            )
        }

        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: screen.midX - panelSize.width / 2,
            y: screen.maxY - panelSize.height - 40
        )
    }

    /// Keeps the panel on screen when the status item sits close enough
    /// to an edge that a panel centred under it would hang off — easy to
    /// hit now the HUD is 310pt wide against a menu bar item a fraction
    /// of that.
    private static func clampedToScreen(_ x: CGFloat, near screen: NSScreen?) -> CGFloat {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return x }
        let margin: CGFloat = 8
        return min(max(x, visible.minX + margin), visible.maxX - margin - panelSize.width)
    }

    /// The filled track, with macOS's row of tick dots under it. Drawn by
    /// hand rather than with NSLevelIndicator, which has no style that
    /// looks right on a dark HUD.
    private final class LevelBar: NSView {

        /// Track along the top edge, dots along the bottom one.
        static let height: CGFloat = 16
        private static let trackHeight: CGFloat = 8
        private static let tickDiameter: CGFloat = 2
        /// One dot per step a volume key moves the volume in, the way the
        /// system HUD prints them.
        private static let tickCount = 16

        var level: CGFloat = 0 {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            let track = NSRect(
                x: 0,
                y: bounds.height - Self.trackHeight,
                width: bounds.width,
                height: Self.trackHeight
            )
            let radius = track.height / 2

            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

            if level > 0 {
                // Never narrower than the track is tall, so a very low
                // level still draws as a round dot instead of a sliver.
                let width = max(track.width * level, track.height)
                let filled = NSRect(x: track.minX, y: track.minY, width: width, height: track.height)
                NSColor.white.setFill()
                NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
            }

            // Spread end to end under the track, so the first and last dot
            // line up with the two ends of the range rather than floating
            // inside them.
            NSColor.white.withAlphaComponent(0.35).setFill()
            let diameter = Self.tickDiameter
            let step = (bounds.width - diameter) / CGFloat(Self.tickCount - 1)
            for index in 0..<Self.tickCount {
                let dot = NSRect(x: CGFloat(index) * step, y: 0, width: diameter, height: diameter)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }
}
