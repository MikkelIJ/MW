import AppKit
import Carbon.HIToolbox

/// Preferences window: main snap-to-region hotkey + per-slot instant-snap
/// hotkeys.
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var recorder: HotkeyRecorderField?
    private var instantRecorders: [HotkeyRecorderField] = []
    private let onChange: (KeyCombo) -> Void
    private let onInstantChange: ([KeyCombo?]) -> Void

    init(onChange: @escaping (KeyCombo) -> Void,
         onInstantChange: @escaping ([KeyCombo?]) -> Void) {
        self.onChange = onChange
        self.onInstantChange = onInstantChange
    }

    func show(current: KeyCombo, instants: [KeyCombo?]) {
        if let w = window {
            recorder?.combo = current
            for (i, r) in instantRecorders.enumerated() {
                r.combo = (i < instants.count ? instants[i] : nil)
                    ?? KeyCombo(keyCode: 0, modifiers: 0)
            }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rowH: CGFloat = 32
        let slotCount = InstantSnapStore.slotCount
        let topPad: CGFloat = 20
        let bottomPad: CGFloat = 20
        let mainBlockH: CGFloat = 80
        let instantHeader: CGFloat = 28
        let hintH: CGFloat = 36
        let contentH = topPad + mainBlockH + instantHeader
            + CGFloat(slotCount) * rowH + 8 + hintH + bottomPad
        let contentW: CGFloat = 420

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "MW Preferences"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
        content.autoresizingMask = [.width, .height]

        var y = contentH - topPad

        // Main hotkey
        y -= 20
        let title = NSTextField(labelWithString: "Show snap overlay")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 20, y: y, width: contentW - 40, height: 20)
        content.addSubview(title)

        y -= 36
        let mainRecorder = HotkeyRecorderField(frame: NSRect(x: 20, y: y, width: 240, height: 28))
        mainRecorder.combo = current
        mainRecorder.onChange = { [weak self] combo in
            combo.save()
            self?.onChange(combo)
        }
        content.addSubview(mainRecorder)
        self.recorder = mainRecorder

        let reset = NSButton(title: "Reset", target: self,
                             action: #selector(resetMainCombo))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 270, y: y, width: 90, height: 28)
        content.addSubview(reset)

        // Instant snap section
        y -= 28
        let header = NSTextField(labelWithString: "Instant Snap")
        header.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        header.frame = NSRect(x: 20, y: y, width: contentW - 40, height: 20)
        content.addSubview(header)

        instantRecorders.removeAll()
        for i in 0..<slotCount {
            y -= rowH
            let label = NSTextField(labelWithString: "Region \(i + 1)")
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 20, y: y + 4, width: 80, height: 18)
            content.addSubview(label)

            let rec = HotkeyRecorderField(frame: NSRect(x: 110, y: y, width: 200, height: 26))
            rec.combo = (i < instants.count ? instants[i] : nil)
                ?? KeyCombo(keyCode: 0, modifiers: 0)
            let slotIndex = i
            rec.onChange = { [weak self] combo in
                guard let self else { return }
                var current = self.collectInstants()
                current[slotIndex] = combo.isEmpty ? nil : combo
                self.onInstantChange(current)
            }
            content.addSubview(rec)
            instantRecorders.append(rec)

            let clear = NSButton(title: "Clear", target: self,
                                 action: #selector(clearInstant(_:)))
            clear.bezelStyle = .rounded
            clear.tag = i
            clear.frame = NSRect(x: 320, y: y, width: 80, height: 26)
            content.addSubview(clear)
        }

        // Hint
        y -= 8 + hintH
        let hint = NSTextField(labelWithString:
            "Click a field, then press your keys (a modifier is required).\n" +
            "Instant Snap moves the focused window to that region on its current display.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: y, width: contentW - 40, height: hintH)
        hint.maximumNumberOfLines = 2
        content.addSubview(hint)

        w.contentView = content
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func collectInstants() -> [KeyCombo?] {
        var arr: [KeyCombo?] = Array(repeating: nil, count: InstantSnapStore.slotCount)
        for (i, r) in instantRecorders.enumerated() {
            arr[i] = r.combo.isEmpty ? nil : r.combo
        }
        return arr
    }

    @objc private func resetMainCombo() {
        recorder?.combo = .default
        KeyCombo.default.save()
        onChange(.default)
    }

    @objc private func clearInstant(_ sender: NSButton) {
        let i = sender.tag
        guard instantRecorders.indices.contains(i) else { return }
        instantRecorders[i].combo = KeyCombo(keyCode: 0, modifiers: 0)
        var current = collectInstants()
        current[i] = nil
        onInstantChange(current)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        recorder = nil
        instantRecorders.removeAll()
    }
}

// MARK: - Recorder field

final class HotkeyRecorderField: NSView {
    var combo: KeyCombo = KeyCombo(keyCode: 0, modifiers: 0) {
        didSet { needsDisplay = true }
    }
    var onChange: ((KeyCombo) -> Void)?

    private var recording = false { didSet { needsDisplay = true } }
    private var liveModifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        recording = true
        liveModifiers = []
        return true
    }
    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirty: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                   : NSColor.textBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        let text: String
        if recording {
            let mods = KeyCombo.carbonModifiers(from: liveModifiers)
            let preview = KeyCombo(keyCode: 0, modifiers: mods).display
            text = preview == "—"
                ? "Press a key combo…"
                : "\(preview)…"
        } else {
            text = combo.isEmpty ? "—" : combo.display
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: 10, y: (bounds.height - size.height) / 2))
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { return }
        liveModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        let code = UInt32(event.keyCode)

        // Esc cancels recording without changes.
        if Int(event.keyCode) == kVK_Escape {
            recording = false
            window?.makeFirstResponder(nil)
            return
        }
        // Backspace clears the binding.
        if Int(event.keyCode) == kVK_Delete {
            combo = KeyCombo(keyCode: 0, modifiers: 0)
            onChange?(combo)
            recording = false
            window?.makeFirstResponder(nil)
            return
        }

        let mods = KeyCombo.carbonModifiers(
            from: event.modifierFlags.intersection(.deviceIndependentFlagsMask))

        // Require at least one modifier to avoid trapping plain keys.
        guard mods != 0 else {
            NSSound.beep()
            return
        }

        let next = KeyCombo(keyCode: code, modifiers: mods)
        combo = next
        onChange?(combo)
        recording = false
        window?.makeFirstResponder(nil)
    }
}
