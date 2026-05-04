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
        /// Drag confirmed (window has moved past threshold) but the
        /// user hasn't asked for the snap overlay yet. A right-click
        /// here arms the overlay.
        case draggingArmed(target: AXUIElement?)
        /// Overlay is up and tracking the cursor. Right-clicks now
        /// cycle through overlapping regions.
        case draggingActive(target: AXUIElement?)
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
        // NSEvent fallback for right-click cycling. The CGEventTap is
        // the primary path (it sees events first and lets us *consume*
        // them so they don't pop a context menu), but on systems where
        // the tap fails to install — e.g. Accessibility was reset by an
        // upgrade and the user hasn't re-granted it — this NSEvent
        // monitor still picks up right-clicks delivered to other apps.
        if rightMouseGlobalMonitor == nil {
            rightMouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.rightMouseDown]) { [weak self] _ in
                _ = self?.cycleIfDragging(at: NSEvent.mouseLocation)
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
        if case .draggingActive = state { overlay.dismiss() }
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
                DebugLog.shared.log("  drag CONFIRMED: dist=\(Int(dist)) frame moved \(fmt(initial))→\(fmt(now)) → armed (right-click to show overlay)")
                state = .draggingArmed(target: win)
            case .draggingArmed:
                // Wait for the user to right-click before showing the
                // overlay.
                break
            case .draggingActive:
                overlay.updateDragCursor(p)
            default:
                break
            }

        case .leftMouseUp:
            switch state {
            case .draggingActive(let target):
                let drop = overlay.dropTarget(at: NSEvent.mouseLocation)
                overlay.dismiss()
                DebugLog.shared.log("  leftUp: drop=\(drop.map(fmt) ?? "nil") target=\(target == nil ? "nil" : "ok")")
                if let drop {
                    _ = WindowMover.move(window: target, to: drop)
                }
            case .draggingArmed:
                // User dragged but never right-clicked: just let go,
                // no snap.
                DebugLog.shared.log("  leftUp: armed but no overlay was requested, ignoring")
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
        case .draggingArmed: return "draggingArmed"
        case .draggingActive: return "draggingActive"
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

    // MARK: - Right-click cycle (CGEventTap)

    private func installRightClickTap() {
        guard rightClickTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
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
            guard type == .rightMouseDown, let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let monitor = Unmanaged<DragSnapMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // Only intercept while we're actively dragging a window.
            // Hand the event back to the system in every other case so
            // normal right-click context menus continue to work.
            let consume = monitor.handleRightMouseDownFromTap()
            if consume { return nil }
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
            NSLog("MW: CGEvent.tapCreate failed — right-click cycling will fall back to NSEvent monitor (works only outside the dragged window's own app).")
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

    /// Called from the CGEventTap thread. Returns true if the event was
    /// consumed (i.e. we used it to cycle and don't want it to propagate).
    fileprivate func handleRightMouseDownFromTap() -> Bool {
        // Snapshot state from the background thread; the actual UI work
        // (which touches AppKit views) is dispatched onto main.
        switch state {
        case .draggingArmed, .draggingActive:
            break
        default:
            return false
        }
        let cocoaPoint = NSEvent.mouseLocation
        // Sync to main is unsafe — the main thread may be blocked in
        // AppKit's window-drag tracking syscall. Dispatch async and
        // assume we're consuming the event regardless: it's better to
        // swallow a stray right-click than to deadlock.
        DispatchQueue.main.async { [weak self] in
            self?.handleRightClickWhileDragging(at: cocoaPoint)
        }
        return true
    }

    /// Main-thread handler for a right-click that arrived while a drag
    /// is in progress. First click presents the overlay; subsequent
    /// clicks cycle through overlapping regions under the cursor.
    @discardableResult
    private func handleRightClickWhileDragging(at point: NSPoint) -> Bool {
        switch state {
        case .draggingArmed(let target):
            overlay.presentForDrag()
            overlay.updateDragCursor(point)
            state = .draggingActive(target: target)
            DebugLog.shared.log("  rightDown: armed → overlay shown at \(fmt(point))")
            return true
        case .draggingActive:
            let cycled = overlay.cycleHover(at: point)
            if cycled {
                DebugLog.shared.log("  rightDown: cycled overlapping region at \(fmt(point))")
            }
            return cycled
        default:
            return false
        }
    }

    private func cycleIfDragging(at point: NSPoint) -> Bool {
        // NSEvent fallback path (used when the CGEventTap couldn't be
        // installed). Same semantics as the tap callback.
        return handleRightClickWhileDragging(at: point)
    }
}
