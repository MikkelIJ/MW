import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Watches global mouse events. While the user is actively dragging a
/// window (left mouse button held + window frame moved), the snap
/// overlay is summoned by **dwelling** — i.e. holding the cursor
/// roughly still for a short moment. Releasing the left mouse button
/// over a region snaps the focused window into it.
///
/// Why dwell rather than a key or second click? macOS's window-drag
/// tracking runloop swallows every non-left-button mouse event and
/// every `flagsChanged` event for the duration of the drag, so neither
/// right-click, middle-click, nor any modifier key reach our NSEvent
/// monitors. `leftMouseDragged` events do, so dwell is the only
/// reliable in-drag trigger.
final class DragSnapMonitor {
    private let store: RegionStore
    private let overlay: OverlayWindowController

    private var mouseGlobalMonitor: Any?
    private var mouseLocalMonitor: Any?

    /// Pixels the mouse must travel after mouse-down before we treat
    /// the gesture as a drag (rather than an incidental click).
    private let dragThreshold: CGFloat = 5

    /// How still the cursor must be (within `dwellRadius` for at least
    /// `dwellDuration`) while dragging before the overlay appears.
    private let dwellDuration: TimeInterval = 0.35
    private let dwellRadius: CGFloat = 4

    private enum State {
        case idle
        case mouseDown(start: NSPoint,
                       window: AXUIElement?,
                       initialFrame: NSRect?)        // pressed but not yet a confirmed window drag
        case dragging(target: AXUIElement?,           // confirmed window drag
                      overlayShown: Bool,
                      lastMove: Date,
                      lastPoint: NSPoint)
    }
    private var state: State = .idle
    private var dwellTimer: Timer?

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
                self?.handleMouse(e, source: "global")
            }
        }
        if mouseLocalMonitor == nil {
            mouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] e in
                self?.handleMouse(e, source: "local")
                return e
            }
        }
        DebugLog.shared.log("DragSnap.start: monitors installed")
    }

    func stop() {
        for m in [mouseGlobalMonitor, mouseLocalMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
        mouseGlobalMonitor = nil; mouseLocalMonitor = nil
        if case .dragging(_, let shown, _, _) = state, shown { overlay.dismiss() }
        cancelDwell()
        state = .idle
        DebugLog.shared.log("DragSnap.stop")
    }

    // MARK: - Mouse handling

    private func handleMouse(_ event: NSEvent, source: String) {
        DebugLog.shared.log("evt \(eventName(event.type)) src=\(source) loc=\(fmt(NSEvent.mouseLocation)) state=\(stateName())")
        switch event.type {
        case .leftMouseDown:
            let win = WindowMover.focusedWindow()
            let frame = win.flatMap { WindowMover.frame(of: $0) }
            DebugLog.shared.log("  leftDown: focusedWindow=\(win == nil ? "nil" : "ok") frame=\(frame.map(fmt) ?? "nil")")
            state = .mouseDown(start: NSEvent.mouseLocation,
                               window: win,
                               initialFrame: frame)

        case .leftMouseDragged:
            let p = NSEvent.mouseLocation
            switch state {
            case .mouseDown(let start, let win, let initial):
                let dist = hypot(p.x - start.x, p.y - start.y)
                guard dist >= dragThreshold else { return }
                guard let win, let initial else {
                    DebugLog.shared.log("  drag: missing window/frame, ignoring")
                    return
                }
                let now = WindowMover.frame(of: win)
                guard let now, now.origin != initial.origin else {
                    DebugLog.shared.log("  drag: window frame unchanged, not a window drag")
                    return
                }
                DebugLog.shared.log("  drag CONFIRMED: dist=\(Int(dist)) frame moved \(fmt(initial))→\(fmt(now))")
                state = .dragging(target: win, overlayShown: false,                setOverlay(shown: true, target: win)                                  lastMove: Date(), lastPoint: p)
                scheduleDwellCheck()
            case .dragging(let target, let shown, _, let lastPoint):
                let movement = hypot(p.x - lastPoint.x, p.y - lastPoint.y)
                if shown {
                    overlay.updateDragCursor(p)
                    // Keep `lastMove` fresh while shown so we don't flap.
                    state = .dragging(target: target, overlayShown: true,
                                      lastMove: Date(), lastPoint: p)
                } else if movement >= dwellRadius {
                    // Real movement → reset the dwell clock.
                    state = .dragging(target: target, overlayShown: false,
                                      lastMove: Date(), lastPoint: p)
                }
            default:
                break
            }

        case .leftMouseUp:
            cancelDwell()
            if case .dragging(let target, let shown, _, _) = state, shown {
                let drop = overlay.dropTarget(at: NSEvent.mouseLocation)
                overlay.dismiss()
                DebugLog.shared.log("  leftUp: drop=\(drop.map(fmt) ?? "nil") target=\(target == nil ? "nil" : "ok")")
                if let drop {
                    _ = WindowMover.move(window: target, to: drop)
                }
            }
            state = .idle

        default:
            break
        }
    }

    // MARK: - Dwell detection

    private func scheduleDwellCheck() {
        cancelDwell()
        // Poll every ~80 ms so we notice the dwell as soon as the user
        // stops moving. We can't rely on a one-shot timer because the
        // user might keep moving and need the timer to "reset".
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.checkDwell()
        }
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    private func checkDwell() {
        guard case .dragging(let target, let shown, let lastMove, let lastPoint) = state else {
            cancelDwell()
            return
        }
        if shown { return }
        let elapsed = Date().timeIntervalSince(lastMove)
        guard elapsed >= dwellDuration else { return }
        DebugLog.shared.log("  DWELL: \(Int(elapsed * 1000))ms still at \(fmt(lastPoint)) → showing overlay")
        overlay.presentForDrag()
        overlay.updateDragCursor(lastPoint)
        state = .dragging(target: target, overlayShown: true,
                          lastMove: Date(), lastPoint: lastPoint)
    }

    // MARK: - Debug helpers

    private func stateName() -> String {
        switch state {
        case .idle: return "idle"
        case .mouseDown: return "mouseDown"
        case .dragging(_, let s, _, _): return "dragging(overlay=\(s))"
        }
    }

    private func eventName(_ t: NSEvent.EventType) -> String {
        switch t {
        case .leftMouseDown: return "leftDown"
        case .leftMouseUp: return "leftUp"
        case .leftMouseDragged: return "leftDrag"
        default: return "\(t.rawValue)"
        }
    }

    private func fmt(_ p: NSPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }
    private func fmt(_ r: NSRect) -> String { "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.size.width))x\(Int(r.size.height)))" }
}
