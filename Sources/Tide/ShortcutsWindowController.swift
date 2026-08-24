import AppKit

/// A small preferences window listing one ShortcutRecorderControl per
/// capture action. Owns no persistence itself — every change is routed
/// through `applyChange`, which the app delegate uses to (re)register the
/// global hotkey and only persist the change if that succeeds.
final class ShortcutsWindowController: NSWindowController {

    /// Returns true if `combo` (nil means "clear") was applied successfully.
    var applyChange: ((ShortcutAction, KeyCombo?) -> Bool)?

    private var recorders: [ShortcutAction: ShortcutRecorderControl] = [:]

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        for action in ShortcutAction.allCases {
            stack.addArrangedSubview(makeRow(for: action))
        }

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)

        let contentView = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
        ])
        window?.contentView = contentView
    }

    private func makeRow(for action: ShortcutAction) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10

        let label = NSTextField(labelWithString: action.displayName)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let recorder = ShortcutRecorderControl(frame: NSRect(x: 0, y: 0, width: 130, height: 22))
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: 130).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 22).isActive = true
        recorder.combo = ShortcutStore.combo(for: action)
        recorder.onChange = { [weak self, weak recorder] newCombo in
            guard let self, let recorder else { return }
            self.handleChange(action: action, recorder: recorder, newCombo: newCombo)
        }
        recorders[action] = recorder

        row.addArrangedSubview(label)
        row.addArrangedSubview(recorder)
        return row
    }

    private func handleChange(action: ShortcutAction, recorder: ShortcutRecorderControl, newCombo: KeyCombo?) {
        guard applyChange?(action, newCombo) == true else {
            recorder.combo = ShortcutStore.combo(for: action)
            NSSound.beep()

            let alert = NSAlert()
            alert.messageText = "Couldn't set shortcut"
            alert.informativeText = "That combination may already be in use by macOS or another app. Try a different one."
            alert.runModal()
            return
        }
    }

    @objc private func restoreDefaults() {
        for action in ShortcutAction.allCases {
            let combo = action.defaultCombo
            if applyChange?(action, combo) == true {
                recorders[action]?.combo = combo
            }
        }
    }
}
