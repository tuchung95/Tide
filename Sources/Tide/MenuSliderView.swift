import AppKit

/// A slider row hosted inside the menu bar dropdown, used as an
/// `NSMenuItem.view`.
///
/// NSMenu has no slider item of its own, so the row is built by hand: icon
/// on the left, slider filling the rest. The menu stays open while the
/// slider is dragged (custom views keep tracking the mouse), which is
/// exactly the behaviour wanted here — the whole point is to watch the
/// screen change as you drag.
final class MenuSliderView: NSView {

    /// Fired continuously while dragging, with the slider's 0…1 value.
    private let onChange: (Float) -> Void

    private let slider = NSSlider()

    /// Width the row is built at; NSMenu stretches it to the menu's own
    /// width once the menu has sized itself.
    private static let rowWidth: CGFloat = 250
    private static let rowHeight: CGFloat = 26
    /// Matches where AppKit puts a menu item's own icon, so the sun and
    /// speaker glyphs line up with the Screenshot items' symbols and with
    /// the section headers.
    private static let leadingInset = MenuSectionHeaderView.iconColumnInset
    private static let trailingInset: CGFloat = 14
    private static let iconWidth: CGFloat = 16
    private static let iconGap: CGFloat = 8

    init(symbolName: String, accessibilityLabel: String, value: Float, onChange: @escaping (Float) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        // Template rendering is what makes the glyph follow the menu's own
        // colour, including when the row is highlighted or the system is
        // in dark mode.
        icon.image?.isTemplate = true
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown

        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = Double(value)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.setAccessibilityLabel(accessibilityLabel)

        // Laid out with explicit frames rather than Auto Layout: this row
        // gets resized to whatever menu it lands in, and an autoresizing
        // mask says "icon stays put, the slider absorbs the difference"
        // without any ambiguity about which piece should stretch.
        let sliderX = Self.leadingInset + Self.iconWidth + Self.iconGap

        icon.frame = NSRect(
            x: Self.leadingInset, y: (Self.rowHeight - Self.iconWidth) / 2,
            width: Self.iconWidth, height: Self.iconWidth
        )
        icon.autoresizingMask = [.maxXMargin]

        slider.frame = NSRect(
            x: sliderX, y: 0,
            width: Self.rowWidth - Self.trailingInset - sliderX, height: Self.rowHeight
        )
        slider.autoresizingMask = [.width]

        // NSMenu grows its item container to the width of the widest item
        // *after* the view has been added, and then keeps ownership of this
        // view's frame — so the row follows the container the ordinary way
        // rather than trying to measure and resize itself.
        autoresizingMask = [.width]

        addSubview(icon)
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.rowWidth, height: Self.rowHeight)
    }

    /// Called when something other than the user changes the value (the
    /// keyboard's brightness keys, say), so the row can follow without
    /// firing `onChange` back at the caller.
    func setValue(_ value: Float) {
        slider.doubleValue = Double(min(max(value, 0), 1))
    }

    @objc private func sliderMoved() {
        onChange(Float(slider.doubleValue))
    }
}
