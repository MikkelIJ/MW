import AppKit
import ApplicationServices
import CoreGraphics

/// Watches global mouse events. As soon as a window-titlebar drag is
/// detected (left button held + focused window's frame moved), the
/// snap-region overlay is shown. Releasing the left button over a
/// region snaps the focused window into it.
///
/// This unconditional approach is the only one that works: macOS's
/// window-drag tracking runloop swallows every non-left-button mouse
/// event and every `flagsChanged` event, so neither right-click,
/// middle-click, nor any modifier key reach our NSEvent monitors. Only
/// `leftMouseDragged`/`leftMouseUp` come through.
///
/// Right-click cycling of overlapping regions is therefore handled via
/// a low-level `CGEventTap`, which sees right-mouse-down events even
/// while AppKit's window-drag loop is active.
final class DragSnapMonitor {
    private let store: RegionStore
    private let overlay: OverlayWindowController

    private var mouseGlobalMonitor: Any?
    private var mouseLocalMonitor: Any?
    private var rightMouseGlobalMonitor: Any?

    // Right-click event tap (for cycling overlapping regions while a
    // window drag is in progress). Hosted on a dedicated background
    // thread so AppKit's window-drag tracking loop can't starve it.
    private var rightClickTap: CFMachPort?
    private var rightClickRunLoopSource: CFRunLoopSource?
    private var rightClickThread: Thread?
    private var rightClickRunLoop: CFRunLoop?

    /// Pixels the mouse must travel after mouse-down before we treat
    /// the gesture as a drag (rather than an incidental click).
    private let dragThreshold: CGFloat = 5

    private enum State {
        case idle
        case mouseDown(start: NSPoint,
                       window: AXUIElement?,
                       initialFrame: NSRect?)
        /// Drag confirmed (window has moved past threshold). The
        /// overlay isn't shown unless the user holds the right mouse
        /// button. We always create the overlay on the first right-down
        /// of a drag and keep its views alive for the whole drag — they
        /// just toggle visibility on right-up / right-down so the
        /// overlap-cycle index survives a momentary release.
        case dragging(target: AXUIElement?, overlayPresented: Bool)
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
                self?.handleMouse(e, source: "global")
            }
        }
        if mouseLocalMonitor == nil {
            mouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] e in
                self?.handleMouse(e, source: "local")
                return e
            }
        }
        // NSEvent fallback for right-button handling. The CGEventTap
        // is the primary path (it sees events first and lets us
        // *consume* them so they don't pop a context menu), but on
        // systems where the tap fails to install — e.g. Accessibility
        // was reset by an upgrade and the user hasn't re-granted it —
        // these NSEvent monitors still pick up right-button events
        // delivered to other apps.
        if rightMouseGlobalMonitor == nil {
            rightMouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.rightMouseDown, .rightMouseUp]) { [weak self] e in
                guard let self else { return }
                let p = NSEvent.mouseLocation
                if e.type == .rightMouseDown {
                    self.handleRightDownWhileDragging(at: p)
                } else if e.type == .rightMouseUp {
                    self.handleRightUpWhileDragging()
                }
            }
        }
        installRightClickTap()
        DebugLog.shared.log("DragSnap.start: monitors installed")
    }

    func stop() {
        for m in [mouseGlobalMonitor, mouseLocalMonitor, rightMouseGlobalMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
        mouseGlobalMonitor = nil
        mouseLocalMonitor = nil
        rightMouseGlobalMonitor = nil
        removeRightClickTap()
        if case .dragging(_, true) = state { overlay.dismiss() }
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
                DebugLog.shared.log("  drag CONFIRMED: dist=\(Int(dist)) frame moved \(fmt(initial))→\(fmt(now)) → hold right mouse button to show overlay")
                state = .dragging(target: win, overlayPresented: false)
            case .dragging(_, true):
                overlay.updateDragCursor(p)
            case .dragging(_, false), .idle:
                break
            }

        case .leftMouseUp:
            switch state {
            case .dragging(let target, true):
                let drop = overlay.dropTarget(at: NSEvent.mouseLocation)
                overlay.dismiss()
                DebugLog.shared.log("  leftUp: drop=\(drop.map(fmt) ?? "nil") target=\(target == nil ? "nil" : "ok")")
                if let drop {
                    _ = WindowMover.move(window: target, to: drop)
                }
            case .dragging(_, false):
                // User dragged but never showed the overlay (right
                // button was never held): just let go, no snap.
                DebugLog.shared.log("  leftUp: drag ended without overlay, ignoring")
            default:
                break
            }
            state = .idle

        default:
            break
        }
    }

    // MARK: - Debug helpers

    private func stateName() -> String {
        switch state {
        case .idle: return "idle"
        case .mouseDown: return "mouseDown"
        case .dragging(_, true):  return "dragging+overlay"
        case .dragging(_, false): return "dragging"
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

    // MARK: - Right-button overlay control (CGEventTap)

    private func installRightClickTap() {
        guard rightClickTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                 | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            // The tap can be disabled by the system if it ever blocks
            // for too long; re-enable on the spot.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon {
                    let monitor = Unmanaged<DragSnapMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    if let tap = monitor.rightClickTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<DragSnapMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // Only intercept while we're actively dragging a window.
            // Outside a drag, hand the event back so normal right-click
            // context menus continue to work.
            switch type {
            case .rightMouseDown:
                if monitor.handleRightDownFromTap() { return nil }
            case .rightMouseUp:
                if monitor.handleRightUpFromTap() { return nil }
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask
                                              | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
                                              | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue),
                                          callback: callback,
                                          userInfo: refcon) else {
            NSLog("MW: CGEvent.tapCreate failed — right-button overlay control will fall back to NSEvent monitor (works only outside the dragged window's own app).")
            DebugLog.shared.log("DragSnap.installRightClickTap: tapCreate failed (no Accessibility?)")
            return
        }
        rightClickTap = tap
        // Run the tap on its own dedicated thread so AppKit's
        // window-drag tracking loop on the main thread can never starve
        // it. Without this, right-clicks issued mid-drag arrive *after*
        // the user has already released the left button.
        let thread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()
            self.rightClickRunLoop = runLoop
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.rightClickRunLoopSource = source
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            // Park here forever; CFRunLoopStop is called from `stop()`.
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }
        thread.name = "MW.RightClickEventTap"
        thread.qualityOfService = .userInteractive
        rightClickThread = thread
        thread.start()
        DebugLog.shared.log("DragSnap.installRightClickTap: installed on dedicated thread")
    }

    private func removeRightClickTap() {
        if let tap = rightClickTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop = rightClickRunLoop {
            CFRunLoopStop(runLoop)
        }
        rightClickThread?.cancel()
        rightClickTap = nil
        rightClickRunLoopSource = nil
        rightClickRunLoop = nil
        rightClickThread = nil
    }

    /// Right-button-down handler called from the CGEventTap thread.
    /// Returns true if the event was consumed.
    fileprivate func handleRightDownFromTap() -> Bool {
        guard case .dragging = state else { return false }
        let p = NSEvent.mouseLocation
        // Sync to main is unsafe — the main thread may be blocked in
        // AppKit's window-drag tracking syscall. Dispatch async and
        // assume we're consuming the event regardless.
        DispatchQueue.main.async { [weak self] in
            self?.handleRightDownWhileDragging(at: p)
        }
        return true
    }

    /// Right-button-up handler called from the CGEventTap thread.
    fileprivate func handleRightUpFromTap() -> Bool {
        guard case .dragging = state else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.handleRightUpWhileDragging()
        }
        return true
    }

    /// First press during a drag presents the overlay; subsequent
    /// presses (after a momentary right-up) cycle through overlapping
    /// regions under the cursor.
    private func handleRightDownWhileDragging(at point: NSPoint) {
        switch state {
        case .dragging(let target, false):
            if overlay.isPresented {
                // Re-show the same overlay windows so the cycle index
                // and any other view state is preserved across the
                // brief right-up that just happened. Advance the cycle
                // first so the user actually sees a change between
                // taps.
                _ = overlay.cycleHover(at: point)
                overlay.showWindows()
            } else {
                overlay.presentForDrag()
            }
            overlay.updateDragCursor(point)
            state = .dragging(target: target, overlayPresented: true)
            DebugLog.shared.log("  rightDown: overlay shown at \(fmt(point))")
        case .dragging(_, true):
            // Right was already held — cycle to the next region.
            let cycled = overlay.cycleHover(at: point)
            DebugLog.shared.log("  rightDown (re-entrant): cycled=\(cycled)")
        default:
            break
        }
    }

    /// Releasing the right button hides the overlay (without destroying
    /// view state) so the cycle index survives until the next right-down.
    private func handleRightUpWhileDragging() {
        switch state {
        case .dragging(let target, true):
            overlay.hideWindows()
            state = .dragging(target: target, overlayPresented: false)
            DebugLog.shared.log("  rightUp: overlay hidden")
        default:
            break
        }
    }
}
