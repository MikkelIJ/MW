import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Watches global mouse events. While the user is actively dragging a
/// window (left mouse button held + window frame moved), the snap
/// overlay can be summoned in two ways:
///
///   * **Right-click** (or two-finger tap on a trackpad) toggles it.
///   * **Holding Control** shows it while the key is down.
///
/// Releasing the left mouse button over a region snaps the focused
/// window into it.
final class DragSnapMonitor {
    private let store: RegionStore
    private let overlay: OverlayWindowController

    private var mouseGlobalMonitor: Any?
    private var mouseLocalMonitor: Any?

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
            .rightMouseDown, .otherMouseDown,
            .flagsChanged,
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
        if case .dragging(_, let shown) = state, shown { overlay.dismiss() }
        state = .idle
        DebugLog.shared.log("DragSnap.stop")
    }

    // MARK: - Mouse handling

    private func handleMouse(_ event: NSEvent, source: String) {
        DebugLog.shared.log("evt \(eventName(event.type)) src=\(source) loc=\(fmt(NSEvent.mouseLocation)) mods=\(modString(event.modifierFlags)) state=\(stateName())")
        switch event.type {
        case .leftMouseDown:
            // Capture the focused window + its current frame at the
            // moment of mouse-down. We'll use the frame later to
            // distinguish a *window* drag (titlebar move) from any
            // other drag (text selection, draw tools, etc.).
            let win = WindowMover.focusedWindow()
            let frame = win.flatMap { WindowMover.frame(of: $0) }
            DebugLog.shared.log("  leftDown: focusedWindow=\(win == nil ? "nil" : "ok") frame=\(frame.map(fmt) ?? "nil")")
            state = .mouseDown(start: NSEvent.mouseLocation,
                               window: win,
                               initialFrame: frame)

        case .leftMouseDragged:
            switch state {
            case .mouseDown(let start, let win, let initial):
                let p = NSEvent.mouseLocation
                let dist = hypot(p.x - start.x, p.y - start.y)
                guard dist >= dragThreshold else { return }
                // Only treat this as a window drag if the focused
                // window's frame actually moved.
                guard let win, let initial else {
                    DebugLog.shared.log("  drag: missing window/frame, ignoring")
                    return
                }
                let now = WindowMover.frame(of: win)
                guard let now, now.origin != initial.origin else {
                    DebugLog.shared.log("  drag: window frame unchanged (\(now.map(fmt) ?? "nil")), not a window drag")
                    return
                }
                DebugLog.shared.log("  drag CONFIRMED: dist=\(Int(dist)) frame moved \(fmt(initial))→\(fmt(now))")
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
                DebugLog.shared.log("  leftUp: drop=\(drop.map(fmt) ?? "nil") target=\(target == nil ? "nil" : "ok")")
                if let drop {
                    _ = WindowMover.move(window: target, to: drop)
                }
            }
            state = .idle

        case .rightMouseDown, .otherMouseDown:
            // Toggle the snap overlay only while a window drag is in
            // progress. Right-click / middle-click (two- or three-finger
            // tap on a trackpad) is left untouched at all other times so
            // context menus etc. work normally.
            guard case .dragging(let target, let shown) = state else {
                DebugLog.shared.log("  \(eventName(event.type)): ignored (not in dragging state)")
                return
            }
            DebugLog.shared.log("  \(eventName(event.type)): toggling overlay → \(!shown)")
            setOverlay(shown: !shown, target: target)

        case .flagsChanged:
            // Trackpad-friendly trigger: hold Control while dragging to
            // show the overlay; release it to hide. Works even when the
            // user has no secondary-click configured.
            guard case .dragging(let target, let shown) = state else {
                DebugLog.shared.log("  flags: ignored (not in dragging state)")
                return
            }
            let wantShown = event.modifierFlags.contains(.control)
            if wantShown != shown {
                DebugLog.shared.log("  flags: control \(wantShown ? "down" : "up") → overlay \(wantShown)")
                setOverlay(shown: wantShown, target: target)
            }

        default:
            break
        }
    }

    private func setOverlay(shown: Bool, target: AXUIElement?) {
        if shown {
            overlay.presentForDrag()
            overlay.updateDragCursor(NSEvent.mouseLocation)
        } else {
            overlay.dismiss()
        }
        state = .dragging(target: target, overlayShown: shown)
    }

    // MARK: - Debug helpers

    private func stateName() -> String {
        switch state {
        case .idle: return "idle"
        case .mouseDown: return "mouseDown"
        case .dragging(_, let s): return "dragging(overlay=\(s))"
        }
    }

    private func eventName(_ t: NSEvent.EventType) -> String {
        switch t {
        case .leftMouseDown: return "leftDown"
        case .leftMouseUp: return "leftUp"
        case .leftMouseDragged: return "leftDrag"
        case .rightMouseDown: return "rightDown"
        case .otherMouseDown: return "otherDown"
        case .flagsChanged: return "flags"
        default: return "\(t.rawValue)"
        }
    }

    private func fmt(_ p: NSPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }
    private func fmt(_ r: NSRect) -> String { "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.size.width))x\(Int(r.size.height)))" }

    private func modString(_ f: NSEvent.ModifierFlags) -> String {
        var s: [String] = []
        if f.contains(.control) { s.append("ctrl") }
        if f.contains(.option) { s.append("opt") }
        if f.contains(.command) { s.append("cmd") }
        if f.contains(.shift) { s.append("shift") }
        if f.contains(.capsLock) { s.append("caps") }
        return s.isEmpty ? "-" : s.joined(separator: "+")
    }
}
