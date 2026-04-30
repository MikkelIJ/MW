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

    // Snap-to-grid (toggle with G). Grid dimensions come from
    // Preferences; default 12×12 hits halves, thirds, quarters,
    // sixths and twelfths cleanly.
    private var snapToGrid: Bool = true
    private var gridCols: CGFloat = CGFloat(GridSettings.columns)
    private var gridRows: CGFloat = CGFloat(GridSettings.rows)

    // Resize state.
    private struct EdgeMask: OptionSet {
        let rawValue: Int
        static let left   = EdgeMask(rawValue: 1 << 0)
        static let right  = EdgeMask(rawValue: 1 << 1)
        static let top    = EdgeMask(rawValue: 1 << 2)
        static let bottom = EdgeMask(rawValue: 1 << 3)
    }
    private var resizing: (index: Int, edges: EdgeMask, original: NSRect, anchor: NSPoint)?
    private let edgeGrabSize: CGFloat = 8

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
            let snapped = snapToGrid ? snap(r) : r
            let yTop = bounds.height - (snapped.origin.y + snapped.height)
            return Region(x: snapped.origin.x / bounds.width,
                          y: yTop / bounds.height,
                          w: snapped.width / bounds.width,
                          h: snapped.height / bounds.height)
        }
    }

    // MARK: snap helpers
    private func gridStep() -> NSSize {
        NSSize(width: bounds.width / gridCols,
               height: bounds.height / gridRows)
    }

    private func snap(_ value: CGFloat, step: CGFloat) -> CGFloat {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private func snap(_ rect: NSRect) -> NSRect {
        let step = gridStep()
        let x = snap(rect.origin.x, step: step.width)
        let y = snap(rect.origin.y, step: step.height)
        let maxX = snap(rect.maxX, step: step.width)
        let maxY = snap(rect.maxY, step: step.height)
        var r = NSRect(x: x, y: y,
                       width: max(step.width, maxX - x),
                       height: max(step.height, maxY - y))
        // Clamp to bounds.
        if r.maxX > bounds.width  { r.size.width  = bounds.width  - r.origin.x }
        if r.maxY > bounds.height { r.size.height = bounds.height - r.origin.y }
        if r.origin.x < 0 { r.origin.x = 0 }
        if r.origin.y < 0 { r.origin.y = 0 }
        return r
    }

    // MARK: hit testing
    private func edges(at p: NSPoint, of rect: NSRect) -> EdgeMask {
        guard rect.insetBy(dx: -edgeGrabSize, dy: -edgeGrabSize).contains(p) else { return [] }
        var mask: EdgeMask = []
        if abs(p.x - rect.minX) <= edgeGrabSize { mask.insert(.left) }
        if abs(p.x - rect.maxX) <= edgeGrabSize { mask.insert(.right) }
        if abs(p.y - rect.minY) <= edgeGrabSize { mask.insert(.bottom) }
        if abs(p.y - rect.maxY) <= edgeGrabSize { mask.insert(.top) }
        return mask
    }

    // MARK: drawing
    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        if snapToGrid { drawGrid() }

        for rect in working {
            NSColor.systemBlue.withAlphaComponent(0.35).setFill()
            rect.fill()
            NSColor.systemBlue.setStroke()
            let p = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
        }

        if let s = dragStart, let c = dragCurrent {
            var r = NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                           width: abs(c.x - s.x), height: abs(c.y - s.y))
            if snapToGrid { r = snap(r) }
            NSColor.systemGreen.withAlphaComponent(0.35).setFill()
            r.fill()
            NSColor.systemGreen.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
        }

        drawHud()
    }

    private func drawGrid() {
        let step = gridStep()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        var x: CGFloat = step.width
        while x < bounds.width {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
            x += step.width
        }
        var y: CGFloat = step.height
        while y < bounds.height {
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: bounds.width, y: y))
            y += step.height
        }
        path.stroke()
    }

    private func drawHud() {
        let title = "Editing: \(display.label)"
        let snap  = snapToGrid ? "ON" : "off"
        let grid  = "\(Int(gridCols))×\(Int(gridRows))"
        let hint  = "Drag empty space to add · Drag edges to resize · Click inside to remove · G: snap-to-grid (\(snap), \(grid)) · Return saves all · Esc cancels"

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

        // Resize hit-test runs first so users can grab the edge of an
        // existing region without it being treated as a click-to-remove.
        for idx in working.indices.reversed() {
            let edges = edges(at: p, of: working[idx])
            if !edges.isEmpty && !working[idx].insetBy(dx: edgeGrabSize, dy: edgeGrabSize).contains(p) {
                resizing = (idx, edges, working[idx], p)
                return
            }
        }

        // Click inside an existing region → remove it.
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
        let p = convert(event.locationInWindow, from: nil)
        if var r = resizing {
            let dx = p.x - r.anchor.x
            let dy = p.y - r.anchor.y
            var new = r.original
            if r.edges.contains(.left)  { new.origin.x   += dx; new.size.width  -= dx }
            if r.edges.contains(.right) { new.size.width += dx }
            if r.edges.contains(.bottom){ new.origin.y   += dy; new.size.height -= dy }
            if r.edges.contains(.top)   { new.size.height += dy }
            // Enforce a minimum size.
            let minSize: CGFloat = 24
            if new.size.width  < minSize { new.size.width  = minSize }
            if new.size.height < minSize { new.size.height = minSize }
            // Clamp to view bounds.
            if new.origin.x < 0 { new.origin.x = 0 }
            if new.origin.y < 0 { new.origin.y = 0 }
            if new.maxX > bounds.width  { new.size.width  = bounds.width  - new.origin.x }
            if new.maxY > bounds.height { new.size.height = bounds.height - new.origin.y }
            working[r.index] = new
            r.original = new // not necessary since we use r.original+delta from anchor
            resizing = (r.index, r.edges, r.original, r.anchor)
            needsDisplay = true
            return
        }
        dragCurrent = p
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let r = resizing {
            if snapToGrid { working[r.index] = snap(working[r.index]) }
            resizing = nil
            needsDisplay = true
            return
        }
        defer { dragStart = nil; dragCurrent = nil; needsDisplay = true }
        guard let s = dragStart, let c = dragCurrent else { return }
        var r = NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                       width: abs(c.x - s.x), height: abs(c.y - s.y))
        if snapToGrid { r = snap(r) }
        if r.width > 12 && r.height > 12 { working.append(r) }
    }

    // MARK: keys
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:        onCancel()           // Esc
        case 36, 76:    onCommit()           // Return / keypad enter
        case 5:                              // G — toggle snap-to-grid
            snapToGrid.toggle()
            if snapToGrid { working = working.map { snap($0) } }
            needsDisplay = true
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

    // MARK: - Drag-snap mode
    //
    // Like `present(targetWindow:onPick:)`, but the overlay windows are
    // mouse-transparent so the user can keep dragging the underlying
    // window. Hover and drop are driven externally by `DragSnapMonitor`
    // via `updateDragCursor(_:)` and `dropTarget(at:)`.
    func presentForDrag() {
        dismiss()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        store.refreshLabels(from: screens)

        var any = false
        for screen in screens {
            let id = screen.snapDisplayID
            let regions = store.regions(for: id)
            if !regions.isEmpty { any = true }

            let frame = screen.visibleFrame
            let win = NSWindow(contentRect: NSRect(origin: .zero, size: frame.size),
                               styleMask: .borderless,
                               backing: .buffered, defer: false)
            win.level = .mainMenu + 1
            win.isOpaque = false
            win.backgroundColor = .clear
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            win.hasShadow = false
            win.setFrame(frame, display: false)

            let view = OverlayView(
                frame: NSRect(origin: .zero, size: frame.size),
                regions: regions,
                screenFrame: frame,
                displayLabel: id.label,
                hasAnyRegion: !regions.isEmpty,
                interactive: false
            )
            win.contentView = view
            win.setFrame(frame, display: true)
            win.orderFrontRegardless()

            windows.append(win)
            views.append(view)
        }

        if !any { dismiss() }
    }

    /// Update region highlight to follow the cursor at `screenPoint`
    /// (global Cocoa coordinates, e.g. from `NSEvent.mouseLocation`).
    func updateDragCursor(_ screenPoint: NSPoint) {
        for view in views {
            guard view.screenFrame.contains(screenPoint) else {
                view.setExternalHover(localPoint: nil)
                continue
            }
            let local = NSPoint(x: screenPoint.x - view.screenFrame.origin.x,
                                y: screenPoint.y - view.screenFrame.origin.y)
            view.setExternalHover(localPoint: local)
        }
    }

    /// Returns the global frame of the region under `screenPoint`, or nil
    /// if the cursor isn't over a region.
    func dropTarget(at screenPoint: NSPoint) -> NSRect? {
        for view in views where view.screenFrame.contains(screenPoint) {
            let local = NSPoint(x: screenPoint.x - view.screenFrame.origin.x,
                                y: screenPoint.y - view.screenFrame.origin.y)
            if let r = view.regionRect(atLocal: local) { return r }
        }
        return nil
    }
}

fileprivate final class OverlayView: NSView {
    fileprivate let regions: [Region]
    fileprivate let screenFrame: NSRect
    private let displayLabel: String
    private let hasAnyRegion: Bool
    private let onPick: ((NSRect?) -> Void)?
    private let interactive: Bool
    private var hover: Int? = nil
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect,
         regions: [Region],
         screenFrame: NSRect,
         displayLabel: String,
         hasAnyRegion: Bool,
         interactive: Bool = true,
         onPick: ((NSRect?) -> Void)? = nil) {
        self.regions = regions
        self.screenFrame = screenFrame
        self.displayLabel = displayLabel
        self.hasAnyRegion = hasAnyRegion
        self.interactive = interactive
        self.onPick = onPick
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { interactive }
    override func becomeFirstResponder() -> Bool { interactive }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard interactive else { return }
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    /// Local-coordinate hit test. Used by drag mode (passes points
    /// translated from a global mouse position).
    fileprivate func regionRect(atLocal p: NSPoint) -> NSRect? {
        guard let idx = regions.indices.last(where: { localRect(for: regions[$0]).contains(p) })
        else { return nil }
        return regions[idx].rect(in: screenFrame)
    }

    /// Drive hover externally (the window is mouse-transparent in drag mode).
    fileprivate func setExternalHover(localPoint p: NSPoint?) {
        let newHover: Int?
        if let p {
            newHover = regions.indices.last { localRect(for: regions[$0]).contains(p) }
        } else {
            newHover = nil
        }
        if newHover != hover { hover = newHover; needsDisplay = true }
    }

    private func localRect(for r: Region) -> NSRect {
        let x = r.x * bounds.width
        let w = r.w * bounds.width
        let h = r.h * bounds.height
        let y = bounds.height - (r.y * bounds.height + h)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    override func draw(_ dirty: NSRect) {
        // Native-style overlay:
        //   * Drag mode (non-interactive): no screen dim; regions appear
        //     as soft white rounded rectangles, the hovered one bright
        //     white with a subtle glow — mirroring macOS window-tiling.
        //   * Interactive mode: dim background so the user can spot
        //     every zone, but use the same rounded white rendering.
        if interactive {
            NSColor.black.withAlphaComponent(0.30).setFill()
            bounds.fill()
        }

        let radius: CGFloat = 12
        let inset: CGFloat = 6

        for (i, r) in regions.enumerated() {
            let rect = localRect(for: r).insetBy(dx: inset, dy: inset)
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: radius, yRadius: radius)
            let isHover = (i == hover)

            if isHover {
                // Soft outer glow.
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = NSColor.white.withAlphaComponent(0.55)
                glow.shadowBlurRadius = 24
                glow.shadowOffset = .zero
                glow.set()
                NSColor.white.withAlphaComponent(0.001).setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()

                NSColor.white.withAlphaComponent(0.55).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.95).setStroke()
                path.lineWidth = 2.5
                path.stroke()
            } else {
                let baseFill: CGFloat = interactive ? 0.18 : 0.12
                let baseStroke: CGFloat = interactive ? 0.55 : 0.40
                NSColor.white.withAlphaComponent(baseFill).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(baseStroke).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        }

        // Per-screen label only in interactive picker mode — the drag
        // overlay should stay quiet to feel native.
        guard interactive else { return }
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
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6).fill()
        str.draw(at: NSPoint(x: bg.minX + pad, y: bg.minY + pad))
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactive else { return }
        let p = convert(event.locationInWindow, from: nil)
        let newHover = regions.indices.last { localRect(for: regions[$0]).contains(p) }
        if newHover != hover { hover = newHover; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let idx = regions.indices.last(where: { localRect(for: regions[$0]).contains(p) }) {
            onPick?(regions[idx].rect(in: screenFrame))
        } else {
            onPick?(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard interactive else { super.keyDown(with: event); return }
        if event.keyCode == 53 { onPick?(nil) } // Esc
        else { super.keyDown(with: event) }
    }
}
