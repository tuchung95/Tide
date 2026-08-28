import AppKit

/// A section title ("Displays", "Screenshot") drawn as an
/// `NSMenuItem.view` rather than as an ordinary item title.
///
/// AppKit indents an item's title past the widest icon in its section —
/// the run of items between two separators — and computes that width per
/// section. So an identical header item lands in a different column
/// depending on what happens to sit under it: flush with the icons in the
/// Displays section (whose only other row is a slider, which carries no
/// menu icon of its own) but pushed out to the text column in the
/// Screenshot section. Owning the layout here is what makes every header
/// line up with the icon column no matter what follows it.
final class MenuSectionHeaderView: NSView {

    /// Where a menu item's own icon starts, measured from the menu's left
    /// edge. Shared with MenuSliderView so headers, slider icons and item
    /// icons all sit in one column.
    static let iconColumnInset: CGFloat = 16

    private static let rowWidth: CGFloat = 250
    private static let rowHeight: CGFloat = 22

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))

        let label = NSTextField(labelWithString: title)
        // Menu font and the grey AppKit gives a disabled item, so the
        // header looks exactly as it did when it was a real menu title.
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(
            x: Self.iconColumnInset,
            y: (Self.rowHeight - label.frame.height) / 2
        ))

        addSubview(label)
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.rowWidth, height: Self.rowHeight)
    }
}
