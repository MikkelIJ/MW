import AppKit
import ApplicationServices
import CoreGraphics

/// Watches global mouse events. As soon as a window-titlebar drag is
/// detected (left button held + focused window's frame moved), the
/// drag is "armed" — the user can then trigger the snap-region overlay
/// in one of two ways:
///
///   • **Right-click** while dragging (mouse users). Each subsequent
///     right-click cycles through overlapping regions under the cursor.
///   • **Shift (⇧)** while dragging (trackpad users). Each subsequent
///     Shift-press cycles. macOS's multitouch driver suppresses every
///     multi-finger gesture (two-finger tap, three-finger tap, force
///     touch, etc.) at *every* layer accessible to apps while a
///     one-finger physical click is held — verified at both
///     `.cgSessionEventTap` and `.cghidEventTap`. Modifier-key events
///     are the only secondary input that survives that filter, and
///     `Option` is reserved by macOS 15+ native window tiling, so we
///     use Shift.
///
/// Releasing the left mouse button while the overlay is up snaps the
/// focused window into the highlighted region. Releasing without ever
/// triggering the overlay completes the drag normally.
///
/// Both `rightMouseDown` and `flagsChanged` are blocked from reaching
/// `NSEvent` global monitors during AppKit's window-drag tracking
/// loop, so we read them via a low-level `CGEventTap` hosted on a
/// dedicated background thread (the main run loop is busy servicing
/// the drag-tracking syscall and would starve the tap).
final class DragSnapMonitor {
    private let store: RegionStore
    private let overlay: OverlayWindowController

    private var mouseGlobalMonitor: Any?
    private var mouseLocalMonitor: Any?

    /// Background-thread CGEventTap that catches `rightMouseDown` and
    /// `flagsChanged` events the main thread can't see during a drag.
    private var rightClickTap: CFMachPort?
    private var rightClickRunLoopSource: CFRunLoopSource?
    private var rightClickThread: Thread?
    private var rightClickRunLoop: CFRunLoop?

    /// Tracks Shift-key state across `flagsChanged` events so we can
    /// edge-detect press/release transitions during a drag.
    fileprivate var shiftDownDuringDrag: Bool = false

    /// Pixels the mouse must travel after mouse-down before we treat
    /// the gesture as a drag (rather than an incidental click).
    private let dragThreshold: CGFloat = 5

    private enum State {
        case idle
        case mouseDown(start: NSPoint,
                       window: AXUIElement?,
                       initialFrame: NSRect?)
        /// Drag confirmed (window has moved past threshold). The
        /// overlay isn't shown until the user right-clicks or presses
        /// Shift; `overlayPresented` flips on the first such trigger.
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
        installRightClickTap()
        DebugLog.shared.log("DragSnap.start: monitors installed")
    }

    func stop() {
        for m in [mouseGlobalMonitor, mouseLocalMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
        mouseGlobalMonitor = nil
        mouseLocalMonitor = nil
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
                DebugLog.shared.log("  drag CONFIRMED: dist=\(Int(dist)) frame moved \(fmt(initial))→\(fmt(now)) → right-click or Shift to show overlay")
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
                DebugLog.shared.log("  leftUp: drag ended without overlay, ignoring")
            default:
                break
            }
            state = .idle
            shiftDownDuringDrag = false

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

    // MARK: - CGEventTap (right-click + Shift)

    private func installRightClickTap() {
        guard rightClickTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                 | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
                 | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            // Re-enable on the spot if the system disabled the tap.
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
            switch type {
            case .rightMouseDown:
                if monitor.handleRightDownFromTap() { return nil }
            case .rightMouseUp:
                if monitor.handleRightUpFromTap() { return nil }
            case .flagsChanged:
                let shiftDown = event.flags.contains(.maskShift)
                if monitor.handleShiftFromTap(down: shiftDown) { return nil }
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
            NSLog("MW: CGEvent.tapCreate failed — drag-snap overlay triggers won't work mid-drag (Accessibility permission?).")
            DebugLog.shared.log("DragSnap.installRightClickTap: tapCreate failed (no Accessibility?)")
            return
        }
        rightClickTap = tap
        // Run the tap on a dedicated thread so AppKit's window-drag
        // tracking loop on the main thread can never starve it.
        let thread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()
            self.rightClickRunLoop = runLoop
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.rightClickRunLoopSource = source
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
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
        // Consume so the underlying app doesn't get a context menu.
        // The visible action runs on right-up for normal click feel.
        return true
    }

    /// Right-button-up handler called from the CGEventTap thread.
    fileprivate func handleRightUpFromTap() -> Bool {
        guard case .dragging = state else { return false }
        let p = NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            self?.presentOrCycle(at: p)
        }
        return true
    }

    /// Shift-key handler called from the CGEventTap thread. First
    /// Shift-press during a drag presents the overlay; each subsequent
    /// press cycles to the next overlapping region under the cursor.
    /// Shift-release does nothing — the overlay stays up so the user
    /// can drop into the highlighted region without holding Shift.
    /// Outside a drag we don't consume the event (Shift must reach
    /// other apps normally).
    fileprivate func handleShiftFromTap(down: Bool) -> Bool {
        guard case .dragging = state else {
            shiftDownDuringDrag = false
            return false
        }
        // Edge-detect: flagsChanged fires for every modifier toggle.
        guard down != shiftDownDuringDrag else { return false }
        shiftDownDuringDrag = down
        guard down else { return true }   // consume the release silently
        let p = NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            self?.presentOrCycle(at: p)
        }
        return true
    }

    /// First trigger during a drag presents the overlay; each
    /// subsequent trigger cycles to the next overlapping region.
    private func presentOrCycle(at point: NSPoint) {
        switch state {
        case .dragging(let target, false):
            overlay.presentForDrag()
            overlay.updateDragCursor(point)
            state = .dragging(target: target, overlayPresented: true)
            DebugLog.shared.log("  trigger: overlay shown at \(fmt(point))")
        case .dragging(_, true):
            let cycled = overlay.cycleHover(at: point)
            DebugLog.shared.log("  trigger: cycled overlapping region (cycled=\(cycled))")
        default:
            break
        }
    }
}
