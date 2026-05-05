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
/// `rightMouseDown` and `flagsChanged` are blocked from reaching
/// `NSEvent` global monitors during AppKit's window-drag tracking
/// loop, so we read them via a low-level `CGEventTap` hosted on a
/// dedicated background thread (the main run loop is busy servicing
/// the drag-tracking syscall and would starve the tap).
///
/// **Threading**: the tap callback only ever reads `dragConfirmed`
/// (a single `Bool` guarded by `stateLock`). It never touches the
/// state enum or any AppKit object. All real work is dispatched
/// back to the main queue. Without this discipline the tap callback
/// races with the main thread, the OS times the tap out, disables
/// it, and every subsequent keystroke is dropped until it's
/// re-enabled — a system-wide keyboard freeze.
final class DragSnapMonitor {
    private let store: RegionStore
    private let overlay: OverlayWindowController

    // MARK: Mouse-down/drag tracking (main thread only)

    private var mouseGlobalMonitor: Any?
    private var mouseLocalMonitor: Any?

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

    /// Pixels the mouse must travel after mouse-down before we treat
    /// the gesture as a drag (rather than an incidental click).
    private let dragThreshold: CGFloat = 5

    // MARK: CGEventTap (background thread)

    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    /// The single piece of cross-thread state. Mirrors whether `state`
    /// is `.dragging`; the tap reads it to decide whether to consume.
    private let stateLock = NSLock()
    private var dragConfirmed = false

    init(store: RegionStore, overlay: OverlayWindowController) {
        self.store = store
        self.overlay = overlay
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        ]
        if mouseGlobalMonitor == nil {
            mouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
                self?.handleMouse(e)
            }
        }
        if mouseLocalMonitor == nil {
            mouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
                self?.handleMouse(e)
                return e
            }
        }
        installTap()
        DebugLog.shared.log("DragSnap.start")
    }

    func stop() {
        for m in [mouseGlobalMonitor, mouseLocalMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
        mouseGlobalMonitor = nil
        mouseLocalMonitor = nil
        removeTap()
        if case .dragging(_, true) = state { overlay.dismiss() }
        setDragConfirmed(false)
        state = .idle
        DebugLog.shared.log("DragSnap.stop")
    }

    // MARK: - State (main thread)

    private func setDragConfirmed(_ value: Bool) {
        stateLock.lock()
        dragConfirmed = value
        stateLock.unlock()
    }

    fileprivate func isDragConfirmed() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return dragConfirmed
    }

    private func handleMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let win = WindowMover.focusedWindow()
            let frame = win.flatMap { WindowMover.frame(of: $0) }
            state = .mouseDown(start: NSEvent.mouseLocation,
                               window: win,
                               initialFrame: frame)

        case .leftMouseDragged:
            let p = NSEvent.mouseLocation
            switch state {
            case .mouseDown(let start, let win, let initial):
                let dist = hypot(p.x - start.x, p.y - start.y)
                guard dist >= dragThreshold,
                      let win, let initial,
                      let now = WindowMover.frame(of: win),
                      now.origin != initial.origin
                else { return }
                state = .dragging(target: win, overlayPresented: false)
                setDragConfirmed(true)
                DebugLog.shared.log("DragSnap: drag confirmed")
            case .dragging(_, true):
                overlay.updateDragCursor(p)
            case .dragging(_, false), .idle:
                break
            }

        case .leftMouseUp:
            if case .dragging(let target, true) = state {
                let drop = overlay.dropTarget(at: NSEvent.mouseLocation)
                overlay.dismiss()
                if let drop {
                    _ = WindowMover.move(window: target, to: drop)
                }
            }
            state = .idle
            setDragConfirmed(false)

        default:
            break
        }
    }

    // MARK: - CGEventTap

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                 | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
                 | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                 | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
                 | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            // Tap-thread-local edge-detect for Shift. (The callback
            // only runs on `tapThread`, so a static is safe and avoids
            // touching any cross-thread state.)
            struct TapLocal { static var shiftDown = false }

            // Re-enable on the spot if the system disabled the tap;
            // otherwise the keyboard goes dead until next launch.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon {
                    let m = Unmanaged<DragSnapMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    if let t = m.tap { CGEvent.tapEnable(tap: t, enable: true) }
                }
                return Unmanaged.passUnretained(event)
            }
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<DragSnapMonitor>.fromOpaque(refcon).takeUnretainedValue()

            // Outside an active drag, NEVER consume — Shift, right-click
            // and modifier-laden keystrokes (e.g. ⌘A) must reach other
            // apps untouched.
            guard monitor.isDragConfirmed() else {
                if type == .flagsChanged { TapLocal.shiftDown = false }
                return Unmanaged.passUnretained(event)
            }

            switch type {
            case .rightMouseDown:
                // Suppress context menu; visible action runs on up.
                return nil
            case .rightMouseUp:
                let p = NSEvent.mouseLocation
                DispatchQueue.main.async { [weak monitor] in
                    monitor?.presentOrCycle(at: p)
                }
                return nil
            case .flagsChanged:
                let shiftNow = event.flags.contains(.maskShift)
                let edgePress = shiftNow && !TapLocal.shiftDown
                let edgeRelease = !shiftNow && TapLocal.shiftDown
                TapLocal.shiftDown = shiftNow
                if edgePress {
                    let p = NSEvent.mouseLocation
                    DispatchQueue.main.async { [weak monitor] in
                        monitor?.presentOrCycle(at: p)
                    }
                    return nil   // consume the press
                }
                if edgeRelease { return nil }   // consume the matching release
                return Unmanaged.passUnretained(event)
            default:
                return Unmanaged.passUnretained(event)
            }
        }

        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: refcon) else {
            NSLog("MW: CGEvent.tapCreate failed — drag-snap overlay triggers won't work mid-drag (Accessibility permission?).")
            return
        }
        tap = port
        // Run the tap on a dedicated thread so AppKit's window-drag
        // tracking loop on the main thread can never starve it.
        let thread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()
            self.tapRunLoop = runLoop
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }
        thread.name = "MW.DragSnapEventTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    private func removeTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let runLoop = tapRunLoop { CFRunLoopStop(runLoop) }
        tapThread?.cancel()
        tap = nil
        tapRunLoop = nil
        tapThread = nil
    }

    /// First trigger during a drag presents the overlay; each
    /// subsequent trigger cycles to the next overlapping region.
    fileprivate func presentOrCycle(at point: NSPoint) {
        switch state {
        case .dragging(let target, false):
            overlay.presentForDrag()
            overlay.updateDragCursor(point)
            state = .dragging(target: target, overlayPresented: true)
        case .dragging(_, true):
            _ = overlay.cycleHover(at: point)
        default:
            break
        }
    }
}
