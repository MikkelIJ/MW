import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// Watches global mouse events. While the user is actively dragging a
/// window (left mouse button down + window frame moved), pressing **Z**
/// toggles the snap-region overlay. Releasing the mouse over a region
/// snaps the focused window into it.
///
/// Z is observed via a passive `CGEventTap` so the keystroke is never
/// reserved for MW (you can keep typing "z" anywhere) and so it still
/// fires while the OS is in window-drag tracking mode (where regular
/// `NSEvent` global monitors don't deliver key events).
final class DragSnapMonitor {
    private let store: RegionStore
    private let overlay: OverlayWindowController

    private var mouseGlobalMonitor: Any?
    private var mouseLocalMonitor: Any?

    /// Low-level CGEventTap for keyDown. Set up once at start and left
    /// running; the callback inspects `state` and only acts when a
    /// window drag is in progress. Always returns the event unmodified.
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?

    /// Pixels the mouse must travel after mouse-down before we treat
    /// the gesture as a drag (rather than an incidental click).
    private let dragThreshold: CGFloat = 5

    private enum State {
        case idle
        case mouseDown(start: NSPoint,
                       window: AXUIElement?,
                       initialFrame: NSRect?)        // pressed but not yet a confirmed window drag
        case dragging(target: AXUIElement?,           // confirmed window drag
                      overlayShown: Bool)
    }
    private var state: State = .idle

    init(store: RegionStore, overlay: OverlayWindowController) {
        self.store = store
        self.overlay = overlay
    }

    deinit { stop() }

    func start() {
        let mouseMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        ]
        if mouseGlobalMonitor == nil {
            mouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] e in
                self?.handleMouse(e)
            }
        }
        if mouseLocalMonitor == nil {
            mouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] e in
                self?.handleMouse(e)
                return e
            }
        }
        installKeyTap()
    }

    func stop() {
        for m in [mouseGlobalMonitor, mouseLocalMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
        mouseGlobalMonitor = nil; mouseLocalMonitor = nil
        removeKeyTap()
        if case .dragging(_, let shown) = state, shown { overlay.dismiss() }
        state = .idle
    }

    // MARK: - Mouse handling

    private func handleMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Capture the focused window + its current frame at the
            // moment of mouse-down. We'll use the frame later to
            // distinguish a *window* drag (titlebar move) from any
            // other drag (text selection, draw tools, etc.).
            let win = WindowMover.focusedWindow()
            let frame = win.flatMap { WindowMover.frame(of: $0) }
            state = .mouseDown(start: NSEvent.mouseLocation,
                               window: win,
                               initialFrame: frame)

        case .leftMouseDragged:
            switch state {
            case .mouseDown(let start, let win, let initial):
                let p = NSEvent.mouseLocation
                guard hypot(p.x - start.x, p.y - start.y) >= dragThreshold else { return }
                // Only treat this as a window drag if the focused
                // window's frame actually moved.
                guard let win, let initial,
                      let now = WindowMover.frame(of: win),
                      now.origin != initial.origin
                else { return }
                state = .dragging(target: win, overlayShown: false)
            case .dragging(_, let shown):
                if shown { overlay.updateDragCursor(NSEvent.mouseLocation) }
            default:
                break
            }

        case .leftMouseUp:
            if case .dragging(let target, let shown) = state, shown {
                let drop = overlay.dropTarget(at: NSEvent.mouseLocation)
                overlay.dismiss()
                if let drop {
                    _ = WindowMover.move(window: target, to: drop)
                }
            }
            state = .idle

        default:
            break
        }
    }

    // MARK: - Key tap (Z observer)

    private func installKeyTap() {
        guard keyTap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,           // never modify or swallow events
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<DragSnapMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleKeyTap(type: type, event: event)
                // listenOnly taps can't modify the stream anyway, but be explicit.
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            NSLog("mikkelsworkspace: failed to create CGEventTap (Accessibility not granted?)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyTap = tap
        keyTapSource = src
    }

    private func removeKeyTap() {
        if let src = keyTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let tap = keyTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        keyTap = nil
        keyTapSource = nil
    }

    private func handleKeyTap(type: CGEventType, event: CGEvent) {
        // The kernel disables our tap if it ever times out / misbehaves.
        // Re-enable it transparently so Z keeps working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown else { return }

        // Only react to Z, no modifiers, and only while a window is
        // actually being dragged. Hand off to the main thread because
        // taps fire on a high-priority runloop.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_ANSI_Z) else { return }
        let flags = event.flags
        let consequential: CGEventFlags = [.maskCommand, .maskAlternate,
                                           .maskControl, .maskShift]
        guard flags.intersection(consequential).rawValue == 0 else { return }

        DispatchQueue.main.async { [weak self] in
            self?.toggleOverlay()
        }
    }

    private func toggleOverlay() {
        guard case .dragging(let target, let shown) = state else { return }
        if shown {
            overlay.dismiss()
            state = .dragging(target: target, overlayShown: false)
        } else {
            overlay.presentForDrag()
            overlay.updateDragCursor(NSEvent.mouseLocation)
            state = .dragging(target: target, overlayShown: true)
        }
    }
}
