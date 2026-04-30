import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Watches global mouse events. While the user is actively dragging a
/// window (left mouse button down + window frame moved), pressing **Z**
/// toggles the snap-region overlay. Releasing the mouse over a region
/// snaps the focused window into it.
///
/// Z is observed via a non-consuming `NSEvent` monitor, NOT a Carbon
/// hotkey, so the keystroke is never reserved for MW — you can keep
/// typing “z” in any app while MW is running.
final class DragSnapMonitor {
    private let store: RegionStore
    private let overlay: OverlayWindowController

    private var mouseGlobalMonitor: Any?
    private var mouseLocalMonitor: Any?
    private var keyGlobalMonitor: Any?
    private var keyLocalMonitor: Any?

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
        // Key monitors observe Z but do NOT consume the event — Z keeps
        // working everywhere even while MW is running.
        if keyGlobalMonitor == nil {
            keyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
                self?.handleKey(e)
            }
        }
        if keyLocalMonitor == nil {
            keyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                self?.handleKey(e)
                return e
            }
        }
    }

    func stop() {
        for m in [mouseGlobalMonitor, mouseLocalMonitor,
                  keyGlobalMonitor, keyLocalMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
        mouseGlobalMonitor = nil; mouseLocalMonitor = nil
        keyGlobalMonitor   = nil; keyLocalMonitor   = nil
        if case .dragging(_, let shown) = state, shown { overlay.dismiss() }
        state = .idle
    }

    // MARK: - Event handling

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

    private func handleKey(_ event: NSEvent) {
        // Only react to Z while a window is actually being dragged.
        guard case .dragging(let target, let shown) = state,
              Int(event.keyCode) == kVK_ANSI_Z,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { return }

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
