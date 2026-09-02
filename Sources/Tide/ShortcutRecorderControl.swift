import AppKit

/// A small clickable field: click it, then press a key combo to assign it as
/// a shortcut. Press Esc to cancel, or Delete/Backspace to clear.
final class ShortcutRecorderControl: NSView {

    var combo: KeyCombo? {
        didSet { needsDisplay = true }
    }

    /// Called whenever recording finishes with a new value: a combo, or nil
    /// if the user cleared it. Not called if the user cancels with Esc.
    var onChange: ((KeyCombo?) -> Void)?

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 130, height: 22)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Esc cancels without changing the current value.
        if event.keyCode == 53 {
            isRecording = false
            return
        }

        // Delete/Backspace clears the shortcut.
        if event.keyCode == 51 || event.keyCode == 117 {
            isRecording = false
            combo = nil
            onChange?(nil)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Require at least one modifier so the recorder can't capture a
        // plain letter/number a user is just trying to type elsewhere later.
        guard !modifiers.isEmpty else { return }

        let newCombo = KeyCombo(keyCode: event.keyCode, modifierFlags: modifiers)
        isRecording = false
        combo = newCombo
        onChange?(newCombo)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Squircle rather than a circular rounded rect, matching the cards
        // and the sidebar pill this field sits among (see SquircleBox);
        // nothing is painted outside the path, so its corners stay clear.
        let path = NSBezierPath.squircle(in: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 5)

        let fillColor: NSColor = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.15)
            : NSColor.controlColor
        fillColor.setFill()
        path.fill()

        let strokeColor: NSColor = isRecording ? .controlAccentColor : .separatorColor
        strokeColor.setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text: String
        let textColor: NSColor
        if isRecording {
            text = "Type shortcut…"
            textColor = .controlAccentColor
        } else if let combo {
            text = combo.displayString
            textColor = .labelColor
        } else {
            text = "Click to record"
            textColor = .tertiaryLabelColor
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedText.size()
        let textRect = NSRect(
            x: bounds.minX,
            y: (bounds.height - textSize.height) / 2,
            width: bounds.width,
            height: textSize.height
        )
        attributedText.draw(in: textRect)
    }
}
