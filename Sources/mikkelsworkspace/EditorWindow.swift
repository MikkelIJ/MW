import AppKit

/// Borderless windows are non-key by default, which means keyDown events
/// (Return / Esc) never reach our view and AppKit beeps. Override.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// =====================================================================
// MARK: - Editor (per-display, multi-screen)
// =====================================================================

/// Owns one transparent overlay per connected screen and lets the user
/// draw regions for each. Return on any window saves all profiles; Esc
/// cancels.
final class EditorWindowController {
    private let store: RegionStore
    private var windows: [NSWindow] = []
    private var views:   [EditorView] = []

    init(store: RegionStore) { self.store = store }

    func show() {
        close()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        store.refreshLabels(from: screens)

        for screen in screens {
            let id = screen.snapDisplayID
            let frame = screen.visibleFrame
            // NB: don't pass `screen:` and a global contentRect together —
            // AppKit will sometimes clamp/relocate the window. Build with a
            // placeholder and then move/size explicitly.
            let win = KeyableWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: frame.width,
                                                  height: frame.height),
                               styleMask: .borderless,
                               backing: .buffered, defer: false)
            win.level = .mainMenu + 1
            win.isOpaque = false
            win.backgroundColor = .clear
            win.ignoresMouseEvents = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.hasShadow = false
            win.setFrame(frame, display: false)

            let view = EditorView(
                frame: NSRect(origin: .zero, size: frame.size),
                display: id,
                existing: store.regions(for: id),
                onCommit: { [weak self] in self?.commitAndClose() },
                onCancel: { [weak self] in self?.close() }
            )
            win.contentView = view
            win.setFrame(frame, display: true)
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)

            windows.append(win)
            views.append(view)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }

    private func commitAndClose() {
        for v in views {
            store.setRegions(v.commitRegions(), for: v.display)
        }
        close()
    }
}

private final class EditorView: NSView {
    let display: DisplayID
    private var working: [NSRect] = []          // screen-local, bottom-up
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private let onCommit: () -> Void
    private let onCancel: () -> Void

    init(frame: NSRect, display: DisplayID, existing: [Region],
         onCommit: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.display = display
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(frame: frame)
        // Seed working set from stored fractions (top-down → bottom-up).
        working = existing.map { r in
            NSRect(x: r.x * frame.width,
                   y: frame.height - (r.y + r.h) * frame.height,
                   width: r.w * frame.width,
                   height: r.h * frame.height)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    func commitRegions() -> [Region] {
        working.map { r in
            let yTop = bounds.height - (r.origin.y + r.height)
            return Region(x: r.origin.x / bounds.width,
                          y: yTop / bounds.height,
                          w: r.width / bounds.width,
                          h: r.height / bounds.height)
        }
    }

    // MARK: drawing
    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        for rect in working {
            NSColor.systemBlue.withAlphaComponent(0.35).setFill()
            rect.fill()
            NSColor.systemBlue.setStroke()
            let p = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
        }

        if let s = dragStart, let c = dragCurrent {
            let r = NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                           width: abs(c.x - s.x), height: abs(c.y - s.y))
            NSColor.systemGreen.withAlphaComponent(0.35).setFill()
            r.fill()
            NSColor.systemGreen.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
        }

        drawHud()
    }

    private func drawHud() {
        let title = "Editing: \(display.label)"
        let hint  = "Drag to add · Click to remove · Return saves all · Esc cancels"

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]

        let t = NSAttributedString(string: title, attributes: titleAttrs)
        let h = NSAttributedString(string: hint,  attributes: hintAttrs)
        let tSize = t.size()
        let hSize = h.size()
        let pad: CGFloat = 10
        let width  = max(tSize.width, hSize.width) + 2 * pad
        let height = tSize.height + hSize.height + 3 * pad
        let bg = NSRect(x: (bounds.width - width) / 2,
                        y: bounds.height - height - 24,
                        width: width, height: height)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        t.draw(at: NSPoint(x: bg.minX + pad,
                           y: bg.maxY - pad - tSize.height))
        h.draw(at: NSPoint(x: bg.minX + pad,
                           y: bg.minY + pad))
    }

    // MARK: mouse
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let idx = working.lastIndex(where: { $0.contains(p) }) {
            working.remove(at: idx)
            needsDisplay = true
            return
        }
        dragStart = p
        dragCurrent = p
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragCurrent = nil; needsDisplay = true }
        guard let s = dragStart, let c = dragCurrent else { return }
        let r = NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                       width: abs(c.x - s.x), height: abs(c.y - s.y))
        if r.width > 12 && r.height > 12 { working.append(r) }
    }

    // MARK: keys
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:        onCancel()           // Esc
        case 36, 76:    onCommit()           // Return / keypad enter
        default:        super.keyDown(with: event)
        }
    }
}

// =====================================================================
// MARK: - Picker (per-display overlay)
// =====================================================================

final class OverlayWindowController {
    private let store: RegionStore
    private var windows: [NSWindow] = []
    private var views:   [OverlayView] = []

    init(store: RegionStore) { self.store = store }

    func present(targetWindow: AXUIElement?,
                 onPick: @escaping (NSRect?) -> Void) {
        dismiss()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { onPick(nil); return }
        store.refreshLabels(from: screens)

        var any = false
        for screen in screens {
            let id = screen.snapDisplayID
            let regions = store.regions(for: id)
            if !regions.isEmpty { any = true }

            let frame = screen.visibleFrame
            let win = KeyableWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: frame.width,
                                                  height: frame.height),
                               styleMask: .borderless,
                               backing: .buffered, defer: false)
            win.level = .mainMenu + 1
            win.isOpaque = false
            win.backgroundColor = .clear
            win.ignoresMouseEvents = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.hasShadow = false
            win.setFrame(frame, display: false)

            let view = OverlayView(
                frame: NSRect(origin: .zero, size: frame.size),
                regions: regions,
                screenFrame: frame,
                displayLabel: id.label,
                hasAnyRegion: !regions.isEmpty,
                onPick: { [weak self] picked in
                    self?.dismiss()
                    onPick(picked)
                }
            )
            win.contentView = view
            win.setFrame(frame, display: true)
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)

            windows.append(win)
            views.append(view)
        }

        if !any {
            dismiss()
            onPick(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }
}

private final class OverlayView: NSView {
    private let regions: [Region]
    private let screenFrame: NSRect
    private let displayLabel: String
    private let hasAnyRegion: Bool
    private let onPick: (NSRect?) -> Void
    private var hover: Int? = nil
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect,
         regions: [Region],
         screenFrame: NSRect,
         displayLabel: String,
         hasAnyRegion: Bool,
         onPick: @escaping (NSRect?) -> Void) {
        self.regions = regions
        self.screenFrame = screenFrame
        self.displayLabel = displayLabel
        self.hasAnyRegion = hasAnyRegion
        self.onPick = onPick
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    private func localRect(for r: Region) -> NSRect {
        let x = r.x * bounds.width
        let w = r.w * bounds.width
        let h = r.h * bounds.height
        let y = bounds.height - (r.y * bounds.height + h)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        for (i, r) in regions.enumerated() {
            let rect = localRect(for: r)
            let color: NSColor = (i == hover) ? .systemGreen : .systemBlue
            color.withAlphaComponent(i == hover ? 0.45 : 0.30).setFill()
            rect.fill()
            color.setStroke()
            let p = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
        }

        // Per-screen label
        let label = regions.isEmpty
            ? "\(displayLabel) — no regions (open Edit Regions…)"
            : displayLabel
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 8
        let bg = NSRect(x: 16, y: bounds.height - size.height - 16 - pad * 2,
                        width: size.width + 2 * pad,
                        height: size.height + 2 * pad)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6).fill()
        str.draw(at: NSPoint(x: bg.minX + pad, y: bg.minY + pad))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let newHover = regions.indices.last { localRect(for: regions[$0]).contains(p) }
        if newHover != hover { hover = newHover; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let idx = regions.indices.last(where: { localRect(for: regions[$0]).contains(p) }) {
            onPick(regions[idx].rect(in: screenFrame))
        } else {
            onPick(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onPick(nil) } // Esc
        else { super.keyDown(with: event) }
    }
}
