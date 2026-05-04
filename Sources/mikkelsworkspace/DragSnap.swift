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

    // Right-click event tap (for cycling overlapping regions while a
    // window drag is in progress).
    private var rightClickTap: CFMachPort?
    private var rightClickRunLoopSource: CFRunLoopSource?

    /// Pixels the mouse must travel after mouse-down before we treat
    /// the gesture as a drag (rather than an incidental click).
    private let dragThreshold: CGFloat = 5

    private enum State {
        case idle
        case mouseDown(start: NSPoint,
                       window: AXUIElement?,
                       initialFrame: NSRect?)
        case dragging(target: AXUIElement?)
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
        mouseGlobalMonitor = nil; mouseLocalMonitor = nil
        removeRightClickTap()
        if case .dragging = state { overlay.dismiss() }
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
                DebugLog.shared.log("  drag CONFIRMED: dist=\(Int(dist)) frame moved \(fmt(initial))→\(fmt(now)) → showing overlay")
                state = .dragging(target: win)
                overlay.presentForDrag()
                overlay.updateDragCursor(p)
            case .dragging:
                overlay.updateDragCursor(p)
            default:
                break
            }

        case .leftMouseUp:
            if case .dragging(let target) = state {
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

    // MARK: - Debug helpers

    private func stateName() -> String {
        switch state {
        case .idle: return "idle"
        case .mouseDown: return "mouseDown"
        case .dragging: return "dragging"
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
            guard type == .rightMouseDown, let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let monitor = Unmanaged<DragSnapMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // Only intercept while we're actively dragging a window.
            // Hand the event back to the system in every other case so
            // normal right-click context menus continue to work.
            let consume = monitor.handleRightMouseDownFromTap(event: event)
            if consume { return nil }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: refcon) else {
            DebugLog.shared.log("DragSnap.installRightClickTap: tapCreate failed (no Accessibility?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        rightClickTap = tap
        rightClickRunLoopSource = source
        DebugLog.shared.log("DragSnap.installRightClickTap: installed")
    }

    private func removeRightClickTap() {
        if let tap = rightClickTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = rightClickRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        rightClickTap = nil
        rightClickRunLoopSource = nil
    }

    /// Called from the CGEventTap thread. Returns true if the event was
    /// consumed (i.e. we used it to cycle and don't want it to propagate).
    fileprivate func handleRightMouseDownFromTap(event: CGEvent) -> Bool {
        // The CG location origin is top-left, screen-pixel coordinates.
        // NSEvent.mouseLocation uses bottom-left Cocoa coordinates and
        // is what the overlay views expect.
        let cocoaPoint = NSEvent.mouseLocation
        // Cycle synchronously on the main thread so the next leftMouseUp
        // sees the updated selection.
        var didCycle = false
        if Thread.isMainThread {
            didCycle = self.cycleIfDragging(at: cocoaPoint)
        } else {
            DispatchQueue.main.sync {
                didCycle = self.cycleIfDragging(at: cocoaPoint)
            }
        }
        return didCycle
    }

    private func cycleIfDragging(at point: NSPoint) -> Bool {
        guard case .dragging = state else { return false }
        let cycled = overlay.cycleHover(at: point)
        if cycled {
            DebugLog.shared.log("  rightDown: cycled overlapping region at \(fmt(point))")
        }
        return cycled
    }
}
