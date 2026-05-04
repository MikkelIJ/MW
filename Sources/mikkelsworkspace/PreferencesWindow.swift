import AppKit
import Carbon.HIToolbox

/// Preferences window: main snap-to-region hotkey + per-slot instant-snap
/// hotkeys.
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var recorder: HotkeyRecorderField?
    private var instantRecorders: [HotkeyRecorderField] = []
    private var gridBridge: GridBridge?
    private var profilesContainer: NSView?
    private let store: RegionStore
    private let onChange: (KeyCombo) -> Void
    private let onInstantChange: ([KeyCombo?]) -> Void
    private let onProfilesChanged: () -> Void

    init(store: RegionStore,
         onChange: @escaping (KeyCombo) -> Void,
         onInstantChange: @escaping ([KeyCombo?]) -> Void,
         onProfilesChanged: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
        self.onInstantChange = onInstantChange
        self.onProfilesChanged = onProfilesChanged
    }

    func show(current: KeyCombo, instants: [KeyCombo?]) {
        if let w = window {
            recorder?.combo = current
            for (i, r) in instantRecorders.enumerated() {
                r.combo = (i < instants.count ? instants[i] : nil)
                    ?? KeyCombo(keyCode: 0, modifiers: 0)
            }
            gridBridge?.refresh()
            rebuildProfilesSection()
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
        let profilesBlockH: CGFloat = 230
        let hintH: CGFloat = 36
        let contentH = topPad + mainBlockH + instantHeader
            + CGFloat(slotCount) * rowH + 8 + gridBlockH
            + profilesBlockH + hintH + bottomPad
        let contentW: CGFloat = 480

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
        let gridHeader = NSTextField(labelWithString: "Editor Grid Size (snap-to-grid, square cells)")
        gridHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        gridHeader.frame = NSRect(x: 20, y: y - 18, width: contentW - 40, height: 18)
        content.addSubview(gridHeader)
        y -= 18 + 8

        let cellsLabel = NSTextField(labelWithString: "Cells across main display")
        cellsLabel.font = NSFont.systemFont(ofSize: 12)
        cellsLabel.textColor = .secondaryLabelColor
        cellsLabel.frame = NSRect(x: 20, y: y - 22, width: 200, height: 18)
        content.addSubview(cellsLabel)

        let cellsField = NSTextField(frame: NSRect(x: 225, y: y - 26, width: 55, height: 22))
        cellsField.alignment = .right
        cellsField.integerValue = GridSettings.cellsAcrossMain
        content.addSubview(cellsField)

        let cellsStepper = NSStepper(frame: NSRect(x: 285, y: y - 28, width: 20, height: 28))
        cellsStepper.minValue = Double(GridSettings.minCells)
        cellsStepper.maxValue = Double(GridSettings.maxCells)
        cellsStepper.integerValue = GridSettings.cellsAcrossMain
        content.addSubview(cellsStepper)

        let gridReset = NSButton(title: "Reset", target: nil, action: nil)
        gridReset.bezelStyle = .rounded
        gridReset.frame = NSRect(x: 320, y: y - 28, width: 80, height: 28)
        content.addSubview(gridReset)

        // Wire stepper ↔ field ↔ persisted setting.
        let bridge = GridBridge(field: cellsField, stepper: cellsStepper,
                                resetButton: gridReset)
        self.gridBridge = bridge
        bridge.attach()

        y -= 70

        // Display Profiles section
        let profilesHeader = NSTextField(labelWithString: "Display Profiles")
        profilesHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        profilesHeader.frame = NSRect(x: 20, y: y - 18, width: contentW - 40, height: 18)
        content.addSubview(profilesHeader)
        y -= 18 + 6

        let profilesScroll = NSScrollView(
            frame: NSRect(x: 20, y: y - (profilesBlockH - 24),
                          width: contentW - 40, height: profilesBlockH - 24))
        profilesScroll.hasVerticalScroller = true
        profilesScroll.autohidesScrollers = true
        profilesScroll.borderType = .bezelBorder
        profilesScroll.drawsBackground = true
        let docView = NSView(frame: NSRect(x: 0, y: 0,
                                           width: profilesScroll.contentSize.width,
                                           height: profilesScroll.contentSize.height))
        docView.autoresizingMask = [.width]
        profilesScroll.documentView = docView
        content.addSubview(profilesScroll)
        self.profilesContainer = docView
        rebuildProfilesSection()
        y -= (profilesBlockH - 24)

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

    // MARK: - Display Profiles

    private func rebuildProfilesSection() {
        guard let container = profilesContainer else { return }
        container.subviews.forEach { $0.removeFromSuperview() }

        let profiles = store.allKnownDisplays
        let connectedKeys = Set(NSScreen.screens.map { $0.snapDisplayID.key })

        let rowH: CGFloat = 70
        let pad: CGFloat = 10
        let contentWidth = container.bounds.width

        if profiles.isEmpty {
            let empty = NSTextField(labelWithString:
                "No saved display profiles yet. Add regions from “Edit Regions for All Displays…”.")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.frame = NSRect(x: pad, y: 0, width: contentWidth - 2 * pad, height: 40)
            empty.autoresizingMask = [.width]
            container.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 40)
            container.addSubview(empty)
            return
        }

        let totalH = CGFloat(profiles.count) * rowH
        container.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(totalH, 40))

        for (i, d) in profiles.enumerated() {
            let yTop = container.bounds.height - CGFloat(i + 1) * rowH
            let row = NSView(frame: NSRect(x: 0, y: yTop, width: contentWidth, height: rowH))
            row.autoresizingMask = [.width]

            // Subtle separator above (except first row)
            if i > 0 {
                let sep = NSBox(frame: NSRect(x: pad, y: rowH - 1,
                                              width: contentWidth - 2 * pad, height: 1))
                sep.boxType = .separator
                sep.autoresizingMask = [.width]
                row.addSubview(sep)
            }

            // Preview thumbnail
            let aspect = aspectRatio(forKey: d.key)
            let previewH: CGFloat = 50
            let previewW: CGFloat = min(90, max(50, previewH * aspect))
            let preview = RegionPreviewView(frame: NSRect(
                x: pad, y: (rowH - previewH) / 2,
                width: previewW, height: previewH))
            preview.regions = store.regions(for: DisplayID(key: d.key, label: d.label))
            row.addSubview(preview)

            // Name + status
            let nameX = pad + previewW + 12
            let isConnected = connectedKeys.contains(d.key)
            let name = NSTextField(labelWithString: d.label)
            name.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            name.frame = NSRect(x: nameX, y: rowH / 2 + 2,
                                width: contentWidth - nameX - 100, height: 18)
            name.autoresizingMask = [.width]
            row.addSubview(name)

            let statusText = isConnected ? "Connected" : "Offline"
            let countText = "\(d.regionCount) region\(d.regionCount == 1 ? "" : "s")"
            let sub = NSTextField(labelWithString: "\(statusText) · \(countText)")
            sub.font = NSFont.systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.frame = NSRect(x: nameX, y: rowH / 2 - 18,
                               width: contentWidth - nameX - 100, height: 16)
            sub.autoresizingMask = [.width]
            row.addSubview(sub)

            // Delete button
            let trashImage = NSImage(systemSymbolName: "trash",
                                     accessibilityDescription: "Delete profile")
            let delete = NSButton(title: "Delete", image: trashImage ?? NSImage(),
                                  target: self, action: #selector(deleteProfile(_:)))
            delete.imagePosition = trashImage == nil ? .noImage : .imageLeading
            delete.bezelStyle = .rounded
            delete.contentTintColor = .systemRed
            delete.toolTip = "Delete this display profile and its saved regions"
            delete.frame = NSRect(x: contentWidth - 90 - pad,
                                  y: (rowH - 28) / 2, width: 90, height: 28)
            delete.autoresizingMask = [.minXMargin]
            delete.identifier = NSUserInterfaceItemIdentifier(d.key)
            row.addSubview(delete)

            container.addSubview(row)
        }
    }

    private func aspectRatio(forKey key: String) -> CGFloat {
        if let s = NSScreen.screens.first(where: { $0.snapDisplayID.key == key }) {
            let f = s.frame
            if f.height > 0 { return f.width / f.height }
        }
        return 16.0 / 10.0
    }

    @objc private func deleteProfile(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let label = store.allKnownDisplays.first { $0.key == key }?.label ?? "this display"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete profile for “\(label)”?"
        alert.informativeText = "All saved regions for this display will be removed. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.setRegions([], for: DisplayID(key: key, label: ""))
        rebuildProfilesSection()
        onProfilesChanged()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        recorder = nil
        instantRecorders.removeAll()
        gridBridge = nil
        profilesContainer = nil
    }
}

// MARK: - Region preview

/// Tiny thumbnail of a display profile's regions, drawn inside its bounds.
final class RegionPreviewView: NSView {
    var regions: [Region] = [] { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirty: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                              xRadius: 3, yRadius: 3)
        NSColor.windowBackgroundColor.setFill()
        bg.fill()
        NSColor.separatorColor.setStroke()
        bg.lineWidth = 1
        bg.stroke()

        guard !regions.isEmpty else {
            // "Empty" placeholder: faint dashes
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let s = NSAttributedString(string: "empty", attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                               y: (bounds.height - size.height) / 2))
            return
        }

        let fill = NSColor.controlAccentColor.withAlphaComponent(0.30)
        let stroke = NSColor.controlAccentColor.withAlphaComponent(0.85)
        for r in regions {
            // Region uses top-down y; convert to AppKit bottom-up.
            let rx = bounds.minX + r.x * bounds.width
            let rw = r.w * bounds.width
            let rh = r.h * bounds.height
            let ry = bounds.maxY - r.y * bounds.height - rh
            let rect = NSRect(x: rx, y: ry, width: rw, height: rh).insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - Grid size bridge

/// Glues the columns/rows steppers + text fields to `GridSettings`,
/// keeping them in sync and persisting changes.
private final class GridBridge: NSObject, NSTextFieldDelegate {
    private let field: NSTextField
    private let stepper: NSStepper
    private let resetButton: NSButton
    private let preview = GridPreviewController()

    init(field: NSTextField, stepper: NSStepper, resetButton: NSButton) {
        self.field = field
        self.stepper = stepper
        self.resetButton = resetButton
    }

    func attach() {
        field.delegate = self
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        resetButton.target = self
        resetButton.action = #selector(resetGrid)
    }

    @objc private func stepperChanged() {
        commit(stepper.integerValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as AnyObject?) === field else { return }
        commit(field.integerValue)
    }

    @objc private func resetGrid() {
        commit(GridSettings.defaultCellsAcrossMain)
    }

    func refresh() {
        let v = GridSettings.cellsAcrossMain
        field.integerValue = v
        stepper.integerValue = v
    }

    private func commit(_ raw: Int) {
        let clamped = max(GridSettings.minCells,
                          min(GridSettings.maxCells, raw))
        field.integerValue = clamped
        stepper.integerValue = clamped
        guard clamped != GridSettings.cellsAcrossMain || true else { return }
        GridSettings.cellsAcrossMain = clamped
        NotificationCenter.default.post(name: .gridSettingsChanged, object: nil)
        // Show / refresh the live grid preview across all displays.
        preview.showBriefly()
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
