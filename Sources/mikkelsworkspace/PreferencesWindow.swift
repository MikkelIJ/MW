import AppKit
import Carbon.HIToolbox

/// Preferences window: main snap-to-region hotkey + per-slot instant-snap
/// hotkeys.
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var recorder: HotkeyRecorderField?
    private var instantRecorders: [HotkeyRecorderField] = []
    private var gridBridge: GridBridge?
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
            gridBridge?.refresh()
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
        let gridBlockH: CGFloat = 70
        let hintH: CGFloat = 36
        let contentH = topPad + mainBlockH + instantHeader
            + CGFloat(slotCount) * rowH + 8 + gridBlockH + hintH + bottomPad
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

        // Editor grid size
        y -= 8
        let gridHeader = NSTextField(labelWithString: "Editor Grid Size (snap-to-grid)")
        gridHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        gridHeader.frame = NSRect(x: 20, y: y - 18, width: contentW - 40, height: 18)
        content.addSubview(gridHeader)
        y -= 18 + 8

        let colsLabel = NSTextField(labelWithString: "Columns")
        colsLabel.font = NSFont.systemFont(ofSize: 12)
        colsLabel.textColor = .secondaryLabelColor
        colsLabel.frame = NSRect(x: 20, y: y - 22, width: 70, height: 18)
        content.addSubview(colsLabel)

        let colsField = NSTextField(frame: NSRect(x: 95, y: y - 26, width: 50, height: 22))
        colsField.alignment = .right
        colsField.integerValue = GridSettings.columns
        content.addSubview(colsField)

        let colsStepper = NSStepper(frame: NSRect(x: 150, y: y - 28, width: 20, height: 28))
        colsStepper.minValue = Double(GridSettings.minSize)
        colsStepper.maxValue = Double(GridSettings.maxSize)
        colsStepper.integerValue = GridSettings.columns
        content.addSubview(colsStepper)

        let rowsLabel = NSTextField(labelWithString: "Rows")
        rowsLabel.font = NSFont.systemFont(ofSize: 12)
        rowsLabel.textColor = .secondaryLabelColor
        rowsLabel.frame = NSRect(x: 200, y: y - 22, width: 50, height: 18)
        content.addSubview(rowsLabel)

        let rowsField = NSTextField(frame: NSRect(x: 245, y: y - 26, width: 50, height: 22))
        rowsField.alignment = .right
        rowsField.integerValue = GridSettings.rows
        content.addSubview(rowsField)

        let rowsStepper = NSStepper(frame: NSRect(x: 300, y: y - 28, width: 20, height: 28))
        rowsStepper.minValue = Double(GridSettings.minSize)
        rowsStepper.maxValue = Double(GridSettings.maxSize)
        rowsStepper.integerValue = GridSettings.rows
        content.addSubview(rowsStepper)

        let gridReset = NSButton(title: "Reset", target: nil, action: nil)
        gridReset.bezelStyle = .rounded
        gridReset.frame = NSRect(x: 330, y: y - 28, width: 70, height: 28)
        content.addSubview(gridReset)

        // Wire stepper ↔ field ↔ persisted setting.
        let bridge = GridBridge(colsField: colsField, colsStepper: colsStepper,
                                rowsField: rowsField, rowsStepper: rowsStepper,
                                resetButton: gridReset)
        self.gridBridge = bridge
        bridge.attach()

        y -= 70

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
        gridBridge = nil
    }
}

// MARK: - Grid size bridge

/// Glues the columns/rows steppers + text fields to `GridSettings`,
/// keeping them in sync and persisting changes.
private final class GridBridge: NSObject, NSTextFieldDelegate {
    private let colsField: NSTextField
    private let colsStepper: NSStepper
    private let rowsField: NSTextField
    private let rowsStepper: NSStepper
    private let resetButton: NSButton

    init(colsField: NSTextField, colsStepper: NSStepper,
         rowsField: NSTextField, rowsStepper: NSStepper,
         resetButton: NSButton) {
        self.colsField = colsField
        self.colsStepper = colsStepper
        self.rowsField = rowsField
        self.rowsStepper = rowsStepper
        self.resetButton = resetButton
    }

    func attach() {
        colsField.delegate = self
        rowsField.delegate = self
        colsStepper.target = self
        colsStepper.action = #selector(colsStepperChanged)
        rowsStepper.target = self
        rowsStepper.action = #selector(rowsStepperChanged)
        resetButton.target = self
        resetButton.action = #selector(resetGrid)
    }

    @objc private func colsStepperChanged() {
        colsField.integerValue = colsStepper.integerValue
        GridSettings.columns = colsStepper.integerValue
    }
    @objc private func rowsStepperChanged() {
        rowsField.integerValue = rowsStepper.integerValue
        GridSettings.rows = rowsStepper.integerValue
    }
    @objc private func resetGrid() {
        colsField.integerValue   = GridSettings.defaultCols
        colsStepper.integerValue = GridSettings.defaultCols
        rowsField.integerValue   = GridSettings.defaultRows
        rowsStepper.integerValue = GridSettings.defaultRows
        GridSettings.columns = GridSettings.defaultCols
        GridSettings.rows    = GridSettings.defaultRows
    }

    func refresh() {
        colsField.integerValue   = GridSettings.columns
        colsStepper.integerValue = GridSettings.columns
        rowsField.integerValue   = GridSettings.rows
        rowsStepper.integerValue = GridSettings.rows
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let value = max(GridSettings.minSize,
                        min(GridSettings.maxSize, field.integerValue))
        if field === colsField {
            colsStepper.integerValue = value
            GridSettings.columns = value
        } else if field === rowsField {
            rowsStepper.integerValue = value
            GridSettings.rows = value
        }
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
