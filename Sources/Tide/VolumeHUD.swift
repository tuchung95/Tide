import AppKit

/// The floating panel shown when a volume key changes a monitor's volume.
///
/// Tide swallows those keys (see VolumeKeyTap), so macOS never puts up its
/// own volume HUD — without this, a keypress would change the monitor's
/// volume with nothing on screen to say it worked. This is the stand-in:
/// same idea as the system HUD, named for the monitor being controlled.
///
/// A non-activating, click-through panel rather than an NSPopover: a
/// popover would need somewhere to anchor and would pull focus to Tide,
/// which is exactly wrong for something that appears while the user is
/// working in another app.
final class VolumeHUD {

    private var panel: NSPanel?
    private var titleLabel: NSTextField!
    private var iconView: NSImageView!
    private var levelView: LevelBar!
    private var hideWorkItem: DispatchWorkItem?

    private static let panelSize = NSSize(width: 232, height: 76)
    private static let cornerRadius: CGFloat = 20
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
        iconView.image = Self.icon(for: level)

        panel.setFrameOrigin(Self.origin(anchoredTo: statusButton))
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
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cornerRadius
        // Continuous corners, like the Settings window's cards and page
        // (SquircleBox) and like macOS's own HUD — a circular arc reads as
        // a visibly tighter curve at the same radius. masksToBounds clips
        // the material to that shape, and the panel is non-opaque with a
        // clear backgroundColor above, so the four corners stay at alpha 0.
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 16, y: 44, width: Self.panelSize.width - 32, height: 16)
        titleLabel.autoresizingMask = [.width]

        iconView = NSImageView(frame: NSRect(x: 16, y: 18, width: 18, height: 16))
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyDown

        levelView = LevelBar(frame: NSRect(x: 42, y: 22, width: Self.panelSize.width - 58, height: 8))
        levelView.autoresizingMask = [.width]

        background.addSubview(titleLabel)
        background.addSubview(iconView)
        background.addSubview(levelView)
        panel.contentView = background

        self.panel = panel
        return panel
    }

    private static func icon(for level: Float) -> NSImage? {
        let name: String
        switch level {
        case ..<0.001: name = "speaker.slash.fill"
        case ..<0.34: name = "speaker.wave.1.fill"
        case ..<0.67: name = "speaker.wave.2.fill"
        default: name = "speaker.wave.3.fill"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Volume")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        image?.isTemplate = true
        return image
    }

    /// Centred under Tide's own menu bar item, so the HUD reads as coming
    /// from Tide. Falls back to the top centre of the main screen if the
    /// status item has no window yet.
    private static func origin(anchoredTo statusButton: NSStatusBarButton?) -> NSPoint {
        let gapBelowMenuBar: CGFloat = 8

        if let window = statusButton?.window {
            let inScreen = window.convertToScreen(statusButton!.bounds)
            return NSPoint(
                x: inScreen.midX - panelSize.width / 2,
                y: inScreen.minY - panelSize.height - gapBelowMenuBar
            )
        }

        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: screen.midX - panelSize.width / 2,
            y: screen.maxY - panelSize.height - 40
        )
    }

    /// The filled track. Drawn by hand rather than with NSLevelIndicator,
    /// which has no style that looks right on a dark HUD.
    private final class LevelBar: NSView {

        var level: CGFloat = 0 {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            let radius = bounds.height / 2

            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

            guard level > 0 else { return }
            // Never narrower than the track is tall, so a very low level
            // still draws as a round dot instead of a sliver.
            let width = max(bounds.width * level, bounds.height)
            let filled = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
        }
    }
}
