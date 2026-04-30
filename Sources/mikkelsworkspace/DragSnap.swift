import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Watches global mouse events. While the user is actively dragging
/// (left mouse button down + moving), pressing **Z** toggles the
/// snap-region overlay. Releasing the mouse over a region snaps the
/// focused window into it.
///
/// The Z key is registered as a Carbon hotkey only for the duration of
/// the drag, so it doesn't interfere with normal typing.
final class DragSnapMonitor {
    private let store: RegionStore
    private let overlay: OverlayWindowController

    private var globalMonitor: Any?
    private var localMonitor: Any?

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

    /// Carbon hotkey for Z; only registered while a drag is in progress.
    private var zHotkey: Hotkey?

    init(store: RegionStore, overlay: OverlayWindowController) {
        self.store = store
        self.overlay = overlay
    }

    deinit { stop() }

    func start() {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        ]
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
                self?.handle(e)
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
                self?.handle(e)
                return e
            }
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor  { NSEvent.removeMonitor(l); localMonitor  = nil }
        unregisterZ()
        if case .dragging(_, let shown) = state, shown { overlay.dismiss() }
        state = .idle
    }

    // MARK: - Event handling

    private func handle(_ event: NSEvent) {
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
                // window's frame actually moved. Otherwise leave Z
                // alone so it keeps working for normal typing.
                guard let win, let initial,
                      let now = WindowMover.frame(of: win),
                      now.origin != initial.origin
                else { return }
                state = .dragging(target: win, overlayShown: false)
                registerZ()
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
            unregisterZ()
            state = .idle

        default:
            break
        }
    }

    // MARK: - Z hotkey (drag-scoped)

    private func registerZ() {
        guard zHotkey == nil else { return }
        zHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_Z), modifiers: 0) { [weak self] in
            self?.toggleOverlay()
        }
    }

    private func unregisterZ() {
        zHotkey = nil
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
