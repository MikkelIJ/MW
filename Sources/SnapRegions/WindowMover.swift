import AppKit
import ApplicationServices

enum WindowMover {

    enum MoveResult {
        case ok
        case notTrusted
        case noWindow
        case axError(position: AXError, size: AXError)
    }

    /// Returns the AXUIElement of the frontmost app's focused window.
    /// Falls back to the main window or first listed window when an app
    /// (typically Chromium/Electron) hasn't populated its AX tree yet.
    static func focusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        let appStatus = AXUIElementCopyAttributeValue(system,
                                                      kAXFocusedApplicationAttribute as CFString,
                                                      &appRef)
        guard appStatus == .success, let appCF = appRef else {
            // Fallback: NSWorkspace says who's frontmost.
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                let app = AXUIElementCreateApplication(pid)
                return windowOf(app: app)
            }
            NSLog("SnapRegions: focusedApplication failed status=\(appStatus.rawValue)")
            return nil
        }
        let app = appCF as! AXUIElement
        if let w = windowOf(app: app) { return w }

        // Last-ditch: try via the running-app pid (sometimes the systemwide
        // element gives a different element than the per-pid one).
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            return windowOf(app: AXUIElementCreateApplication(pid))
        }
        return nil
    }

    private static func windowOf(app: AXUIElement) -> AXUIElement? {
        // 1) Focused window.
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let w = ref { return (w as! AXUIElement) }
        // 2) Main window.
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &ref) == .success,
           let w = ref { return (w as! AXUIElement) }
        // 3) First listed window.
        var arr: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &arr) == .success,
           let cfArr = arr,
           let list = cfArr as? [AXUIElement],
           let first = list.first {
            return first
        }
        return nil
    }

    /// Returns the AX application element that owns the given window, plus
    /// the bundle id (when known) so callers can apply per-app workarounds.
    private static func ownerApp(for window: AXUIElement) -> (app: AXUIElement?, pid: pid_t) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid > 0 else { return (nil, 0) }
        return (AXUIElementCreateApplication(pid), pid)
    }

    /// Move/resize the given window. `frameNS` is in Cocoa coords
    /// (bottom-left origin of the primary screen).
    @discardableResult
    static func move(window: AXUIElement?, to frameNS: NSRect) -> MoveResult {
        guard AXIsProcessTrusted() else {
            NSLog("SnapRegions: AX not trusted")
            return .notTrusted
        }
        guard let window else { return .noWindow }
        guard let primary = NSScreen.screens.first else { return .noWindow }

        // Convert to AX (top-left origin of primary screen).
        let topLeftY = primary.frame.height - (frameNS.origin.y + frameNS.height)
        let pos  = CGPoint(x: frameNS.origin.x, y: topLeftY)
        let size = CGSize(width: frameNS.width, height: frameNS.height)

        // Chromium/Electron apps (Chrome, Teams, Slack, VS Code, …) silently
        // ignore AX position/size writes when their app isn't frontmost.
        // Re-activate the owning app first, give it a short beat to process
        // the activation, then drive the geometry.
        let owner = ownerApp(for: window)
        if let pid = owner.pid as pid_t?,
           pid > 0,
           let runningApp = NSRunningApplication(processIdentifier: pid),
           !runningApp.isActive {
            runningApp.activate(options: [])
            // Wait briefly for activation to take effect.
            let deadline = Date().addingTimeInterval(0.25)
            while Date() < deadline && !runningApp.isActive {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }

        // Drive the window to the target geometry. Apps clamp position
        // based on the *old* size and vice versa, so we pump
        // size → position → size → position → size.
        let posErr1  = setPos(window, pos)
        let sizeErr1 = setSize(window, size)
        let posErr2  = setPos(window, pos)
        let sizeErr2 = setSize(window, size)

        // Verify; retry once if geometry didn't stick.
        if let actual = readFrame(window),
           abs(actual.origin.x - pos.x)         > 2 ||
           abs(actual.origin.y - pos.y)         > 2 ||
           abs(actual.size.width  - size.width)  > 2 ||
           abs(actual.size.height - size.height) > 2 {
            NSLog("SnapRegions: drift after first move target=\(pos),\(size) actual=\(actual); retrying")
            // Tiny delay to let the app settle.
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            _ = setSize(window, size)
            _ = setPos(window, pos)
            _ = setSize(window, size)

            if let actual2 = readFrame(window),
               abs(actual2.origin.x - pos.x)         > 2 ||
               abs(actual2.origin.y - pos.y)         > 2 ||
               abs(actual2.size.width  - size.width)  > 2 ||
               abs(actual2.size.height - size.height) > 2 {
                NSLog("SnapRegions: drift persisted target=\(pos),\(size) actual=\(actual2)")
            }
        }

        let posErr  = posErr2  != .success ? posErr2  : posErr1
        let sizeErr = sizeErr2 != .success ? sizeErr2 : sizeErr1
        if posErr != .success || sizeErr != .success {
            NSLog("SnapRegions: AX move failed pid=\(owner.pid) pos=\(posErr.rawValue) size=\(sizeErr.rawValue)")
            return .axError(position: posErr, size: sizeErr)
        }
        return .ok
    }

    /// Current frame of `window` in Cocoa coordinates (origin at the
    /// bottom-left of the primary screen). Returns nil if the geometry
    /// can't be read.
    static func frame(of window: AXUIElement) -> NSRect? {
        guard let raw = readFrame(window),
              let primary = NSScreen.screens.first else { return nil }
        let cocoaY = primary.frame.height - raw.origin.y - raw.size.height
        return NSRect(x: raw.origin.x, y: cocoaY,
                      width: raw.size.width, height: raw.size.height)
    }

    /// Best NSScreen for the given window (the one containing its centre,
    /// falling back to the screen with the largest intersection).
    static func screen(of window: AXUIElement) -> NSScreen? {
        guard let f = frame(of: window) else { return nil }
        let centre = CGPoint(x: f.midX, y: f.midY)
        if let s = NSScreen.screens.first(where: { $0.frame.contains(centre) }) {
            return s
        }
        return NSScreen.screens.max { a, b in
            a.frame.intersection(f).width * a.frame.intersection(f).height
            < b.frame.intersection(f).width * b.frame.intersection(f).height
        }
    }

    // MARK: - low-level helpers

    private static func setPos(_ w: AXUIElement, _ p: CGPoint) -> AXError {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
    }
    private static func setSize(_ w: AXUIElement, _ s: CGSize) -> AXError {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v)
    }
    private static func readFrame(_ w: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }
}

