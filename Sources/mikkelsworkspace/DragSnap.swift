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
    private var gestureGlobalMonitor: Any?

    // Right-click event tap (for cycling overlapping regions while a
    // window drag is in progress). Hosted on a dedicated background
    // thread so AppKit's window-drag tracking loop can't starve it.
    private var rightClickTap: CFMachPort?
    private var rightClickRunLoopSource: CFRunLoopSource?
    private var rightClickThread: Thread?
    private var rightClickRunLoop: CFRunLoop?

    /// Tracks Control-key state across `flagsChanged` events so we can
    /// edge-detect press/release transitions during a drag. (Option is
    /// reserved by macOS 15+ for native window tiling, so we use ⌃.)
    fileprivate var controlDownDuringDrag: Bool = false

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
        //
        // Trackpad secondary-click (two-finger tap or bottom-right
        // corner with macOS's "Secondary click" enabled) is delivered
        // by the system as the same `rightMouseDown` / `rightMouseUp`
        // events as a hardware right button, so this path covers
        // trackpads too.
        if rightMouseGlobalMonitor == nil {
            rightMouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.rightMouseDown, .rightMouseUp]) { [weak self] e in
                guard let self else { return }
                if e.type == .rightMouseDown {
                    self.handleRightDownWhileDragging()
                } else if e.type == .rightMouseUp {
                    self.handleRightUpWhileDragging(at: NSEvent.mouseLocation)
                }
            }
        }
        // Trackpad gesture events. macOS's multitouch driver suppresses
        // `rightMouseDown` while a one-finger drag is in progress, but
        // some gesture event types (begin/end/gesture/magnify/swipe/
        // smartMagnify/pressure) sometimes still leak through. We log
        // every one of them during a drag (so we can see in the
        // DebugLog which actually fires for the user's two-finger tap)
        // and treat any of them as an overlay trigger.
        let gestureMask: NSEvent.EventTypeMask = [
            .beginGesture, .endGesture, .gesture,
            .magnify, .swipe, .smartMagnify, .pressure,
        ]
        if gestureGlobalMonitor == nil {
            gestureGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: gestureMask) { [weak self] e in
                self?.handleGestureEvent(e)
            }
        }
        installRightClickTap()
        DebugLog.shared.log("DragSnap.start: monitors installed")
    }

    func stop() {
        for m in [mouseGlobalMonitor, mouseLocalMonitor, rightMouseGlobalMonitor, gestureGlobalMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
        mouseGlobalMonitor = nil
        mouseLocalMonitor = nil
        rightMouseGlobalMonitor = nil
        gestureGlobalMonitor = nil
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
            controlDownDuringDrag = false

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
        // We listen for a wide range of event types so that *any*
        // secondary input the user makes during a one-finger drag can
        // trigger the overlay. macOS's multitouch driver is known to
        // suppress `rightMouseDown` and `flagsChanged` while a
        // one-finger click-drag is in progress, so we cast a wide net
        // — scrollWheel (two-finger scroll), otherMouseDown (extra
        // mouse buttons), and tabletPointer — and let the handler
        // decide what counts as a trigger.
        let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                 | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
                 | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                 | CGEventMask(1 << CGEventType.scrollWheel.rawValue)
                 | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
                 | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
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
            // context menus and modifier-key handling continue to work.
            switch type {
            case .rightMouseDown:
                if monitor.handleRightDownFromTap() { return nil }
            case .rightMouseUp:
                if monitor.handleRightUpFromTap() { return nil }
            case .flagsChanged:
                let flags = event.flags
                let controlDown = flags.contains(.maskControl)
                if monitor.handleControlFromTap(down: controlDown) { return nil }
            case .scrollWheel:
                if monitor.handleScrollFromTap(event: event) { return nil }
            case .otherMouseDown:
                if monitor.handleOtherMouseDownFromTap() { return nil }
            case .otherMouseUp:
                // Always consume the matching up so the underlying app
                // doesn't see a stray button-up in isolation.
                if case .dragging = monitor.state { return nil }
            default:
                // Log unexpected types so we can extend coverage.
                if case .dragging = monitor.state {
                    DispatchQueue.main.async {
                        DebugLog.shared.log("  tap: unexpected event type=\(type.rawValue) during drag")
                    }
                }
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
        // Consume the event so it doesn't reach the underlying app
        // (which would otherwise pop a context menu). The actual
        // overlay action runs on right-up so the user gets standard
        // click feedback (press, release, then UI reacts).
        DispatchQueue.main.async { [weak self] in
            self?.handleRightDownWhileDragging()
        }
        return true
    }

    /// Right-button-up handler called from the CGEventTap thread.
    fileprivate func handleRightUpFromTap() -> Bool {
        guard case .dragging = state else { return false }
        let p = NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            self?.handleRightUpWhileDragging(at: p)
        }
        return true
    }

    /// Right-button-down during a drag: no-op aside from being marked
    /// as consumed (which the tap callback handles). The visible action
    /// happens on right-up so the gesture behaves like a normal click.
    private func handleRightDownWhileDragging() {
        // Intentionally empty.
    }

    /// Trackpad gesture event from the global NSEvent monitor. We
    /// always log it (so the user's DebugLog reveals exactly which
    /// gesture type their two-finger tap produces during a drag), and
    /// if a drag is in progress we treat any gesture as a present-or-
    /// cycle trigger \u2014 this is the trackpad's primary path.
    private func handleGestureEvent(_ event: NSEvent) {
        let name = gestureEventName(event.type)
        DebugLog.shared.log("evt \(name) src=global loc=\(fmt(NSEvent.mouseLocation)) state=\(stateName())")
        guard case .dragging = state else { return }
        // Some gesture types fire continuously (e.g. .magnify, .gesture
        // with phase=changed). Only act on the *first* one of each
        // gesture sequence, which we approximate by reacting only to
        // begin-style events plus standalone discrete gestures.
        switch event.type {
        case .beginGesture, .smartMagnify, .swipe:
            handleRightUpWhileDragging(at: NSEvent.mouseLocation)
        case .pressure:
            // Pressure begins at stage 1 (light press); only trigger
            // on the transition into stage \u2265 1 to avoid storms.
            if event.stage >= 1 {
                handleRightUpWhileDragging(at: NSEvent.mouseLocation)
            }
        case .gesture, .magnify, .endGesture:
            // Don't trigger here \u2014 begin/swipe/smartMagnify already
            // covered the start; .gesture/.magnify fire repeatedly,
            // and .endGesture would re-trigger after we already showed.
            break
        default:
            break
        }
    }

    private func gestureEventName(_ t: NSEvent.EventType) -> String {
        switch t {
        case .beginGesture: return "beginGesture"
        case .endGesture: return "endGesture"
        case .gesture: return "gesture"
        case .magnify: return "magnify"
        case .swipe: return "swipe"
        case .smartMagnify: return "smartMagnify"
        case .pressure: return "pressure"
        default: return "gesture(\(t.rawValue))"
        }
    }

    /// Scroll-wheel handler from the CGEventTap. A two-finger
    /// scroll/swipe on a trackpad reliably generates `.scrollWheel`
    /// events even while a one-finger drag is in progress (it's the
    /// only multi-touch event type that does). We use the very first
    /// scroll event during a drag as the overlay trigger; further
    /// scroll events cycle through overlapping regions.
    fileprivate func handleScrollFromTap(event: CGEvent) -> Bool {
        guard case .dragging = state else { return false }
        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let p = NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            DebugLog.shared.log("  scrollWheel during drag dx=\(dx) dy=\(dy)")
            self.handleRightUpWhileDragging(at: p)
        }
        return true
    }

    /// Extra-mouse-button (e.g. mouse4/5) handler. Treated like a
    /// secondary trigger so users with multi-button mice have an
    /// alternative to right-click.
    fileprivate func handleOtherMouseDownFromTap() -> Bool {
        guard case .dragging = state else { return false }
        let p = NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            DebugLog.shared.log("  otherMouseDown during drag")
            self.handleRightUpWhileDragging(at: p)
        }
        return true
    }

    /// Control-key handler called from the CGEventTap thread. Trackpads
    /// don't deliver `rightMouseDown`/`rightMouseUp` while the user is
    /// holding a one-finger click-drag (the multitouch driver consumes
    /// extra fingers as continuations of the existing gesture), so the
    /// Control key is offered as a parallel trigger that *does* reach
    /// the event tap during a drag. (Option is reserved by macOS 15+
    /// for native window tiling, so we can't use ⌥.) The semantics
    /// mirror the right button:
    ///   • first Control-press during a drag → present overlay,
    ///   • each subsequent Control-press → cycle to next region,
    ///   • releasing the left mouse while overlay is shown → snap.
    /// Returns true if the event was consumed (only when we actually
    /// acted on it — outside a drag, Control must propagate normally).
    fileprivate func handleControlFromTap(down: Bool) -> Bool {
        guard case .dragging = state else {
            controlDownDuringDrag = false
            return false
        }
        // Edge-detect: ignore unchanged states (flagsChanged fires for
        // every modifier toggle).
        guard down != controlDownDuringDrag else { return false }
        controlDownDuringDrag = down
        let p = NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if down {
                // Treat like a right-button release: present or cycle.
                self.handleRightUpWhileDragging(at: p)
            }
            // Releasing Control does nothing; the overlay stays up so
            // the user can still drop into the highlighted region.
            // (If we hid on release, the user would have to keep ⌃
            // pressed for the whole drag, which is uncomfortable.)
        }
        return true
    }

    /// Right-button-up during a drag drives the overlay:
    ///   • first click of the drag → present the overlay (highlight
    ///     the topmost region under the cursor),
    ///   • each subsequent click → cycle to the next overlapping region
    ///     under the cursor.
    /// Releasing the left button while the overlay is shown snaps the
    /// window into the highlighted region. Releasing the left button
    /// without ever clicking right just completes the drag normally.
    private func handleRightUpWhileDragging(at point: NSPoint) {
        switch state {
        case .dragging(let target, false):
            overlay.presentForDrag()
            overlay.updateDragCursor(point)
            state = .dragging(target: target, overlayPresented: true)
            DebugLog.shared.log("  rightUp: overlay shown at \(fmt(point))")
        case .dragging(_, true):
            let cycled = overlay.cycleHover(at: point)
            DebugLog.shared.log("  rightUp: cycled overlapping region (cycled=\(cycled))")
        default:
            break
        }
    }
}
