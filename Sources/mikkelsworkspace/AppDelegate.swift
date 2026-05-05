import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var editor: EditorWindowController?
    private var overlay: OverlayWindowController?
    private let store = RegionStore()
    private var hotkey: Hotkey?
    private var currentCombo: KeyCombo = .default
    private var instantHotkeys: [Hotkey?] = Array(repeating: nil, count: InstantSnapStore.slotCount)
    private var instantCombos: [KeyCombo?] = Array(repeating: nil, count: InstantSnapStore.slotCount)
    private var prefs: PreferencesWindowController?
    private var dragSnap: DragSnapMonitor?
    private var logWindow: LogWindowController?
    private var bugReport: BugReportWindowController?
    /// Polls Accessibility-trust state so MW can wire up
    /// AX-dependent features (drag-snap event tap, window mover)
    /// the moment the user grants permission — no restart needed.
    private var accessibilityTrustTimer: Timer?
    private var lastAccessibilityTrust = false

    func applicationDidFinishLaunching(_ note: Notification) {
        ensureAccessibilityPermission()
        store.load()
        store.refreshLabels(from: NSScreen.screens)
        currentCombo = KeyCombo.load()
        instantCombos = InstantSnapStore.load()
        buildMenu()
        registerHotkey()
        registerInstantHotkeys()
        setupDragSnap()

        // Rebuild the menu (and dismiss any in-flight overlays) when
        // displays come and go so each monitor's profile is picked up.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    @objc private func screensChanged() {
        store.refreshLabels(from: NSScreen.screens)
        editor?.close()
        overlay?.dismiss()
        buildMenu()
    }

    // MARK: - Menu bar
    private func buildMenu() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let btn = statusItem.button {
                if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
                   let img = NSImage(contentsOf: url) {
                    img.size = NSSize(width: 18, height: 18)
                    // Render as a template: macOS uses only the alpha channel
                    // and auto-tints it for light/dark menu bars.
                    img.isTemplate = true
                    btn.image = img
                } else {
                    btn.image = NSImage(systemSymbolName: "rectangle.split.2x2",
                                        accessibilityDescription: "Snap Regions")
                }
            }
        }

        let menu = NSMenu()

        // Primary actions
        let snapTitle = currentCombo.isEmpty
            ? "Snap to Region"
            : "Snap to Region   \(currentCombo.display)"
        menu.addItem(withTitle: snapTitle,
                     action: #selector(showOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "Edit Regions for All Displays…",
                     action: #selector(editRegions), keyEquivalent: "")

        // Connected displays
        menu.addItem(.separator())
        let connectedHeader = NSMenuItem(title: "Connected Displays", action: nil, keyEquivalent: "")
        connectedHeader.isEnabled = false
        menu.addItem(connectedHeader)
        for screen in NSScreen.screens {
            let id = screen.snapDisplayID
            let count = store.regions(for: id).count
            let mark = count > 0 ? "●" : "○"
            let item = NSMenuItem(
                title: "  \(mark) \(id.label) — \(count) region\(count == 1 ? "" : "s")",
                action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Preferences
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferences…",
                     action: #selector(showPreferences), keyEquivalent: ",")

        // App info
        menu.addItem(.separator())
        menu.addItem(withTitle: "About MW",
                     action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…",
                     action: #selector(checkForUpdates), keyEquivalent: "")

        // Diagnostics
        menu.addItem(.separator())
        let debugItem = NSMenuItem(title: "Debug Logging",
                                   action: #selector(toggleDebugLogging),
                                   keyEquivalent: "")
        debugItem.state = DebugLog.shared.enabled ? .on : .off
        menu.addItem(debugItem)
        menu.addItem(withTitle: "Report a Bug…",
                     action: #selector(reportBug), keyEquivalent: "")

        // Quit
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MW",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        for item in menu.items where item.target == nil && item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func toggleDebugLogging() {
        DebugLog.shared.enabled.toggle()
        DebugLog.shared.log("--- debug logging \(DebugLog.shared.enabled ? "ENABLED" : "DISABLED") ---")
        if DebugLog.shared.enabled {
            showLogWindow()
        } else {
            hideLogWindow()
        }
        buildMenu()
    }

    /// Shows an in-app window that tails the debug log live. Using our
    /// own window (rather than spawning Terminal.app) means toggling
    /// debug logging off can reliably close it — we couldn't close a
    /// Terminal.app window without AppleScript automation permission.
    private func showLogWindow() {
        if logWindow == nil {
            let controller = LogWindowController(logURL: DebugLog.shared.logFileURL)
            controller.onUserClose = { [weak self] in
                self?.handleLogWindowClosedByUser()
            }
            logWindow = controller
        }
        logWindow?.showWindow(nil)
        logWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hideLogWindow() {
        logWindow?.onUserClose = nil
        logWindow?.close()
        logWindow = nil
    }

    /// Called when the user closes the log window with the red
    /// traffic-light button. Treats it as turning debug logging off so
    /// the menu bar checkmark stays in sync with reality.
    private func handleLogWindowClosedByUser() {
        logWindow = nil
        if DebugLog.shared.enabled {
            DebugLog.shared.log("--- debug logging DISABLED (window closed) ---")
            DebugLog.shared.enabled = false
        }
        buildMenu()
    }

    @objc private func reportBug() {
        if bugReport == nil {
            bugReport = BugReportWindowController()
        }
        bugReport?.show()
    }

    // MARK: - Hotkey
    private func registerHotkey() {
        hotkey = nil // tear down any prior registration
        guard !currentCombo.isEmpty else { return }
        let new = Hotkey(keyCode: currentCombo.keyCode,
                         modifiers: currentCombo.modifiers) { [weak self] in
            self?.showOverlay()
        }
        if new == nil {
            // Most likely a conflict with another app holding the same combo.
            DispatchQueue.main.async { [weak self] in
                self?.notifyConflict()
            }
        }
        hotkey = new
    }

    private func notifyConflict() {
        let alert = NSAlert()
        alert.messageText = "Couldn’t register \(currentCombo.display)"
        alert.informativeText = "Another app is probably using this shortcut. Open Preferences… to pick a different one."
        alert.addButton(withTitle: "Open Preferences…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            showPreferences()
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "MW stands for Mikkel’s Workspace.\n\nIt was made out of need and curiosity " +
                    "about how to build an app like this for macOS.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
            ])
        let info = Bundle.main.infoDictionary
        let shortVersion = (info?["CFBundleShortVersionString"] as? String) ?? UpdateChecker.currentVersion
        let build = (info?["CFBundleVersion"] as? String) ?? ""
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "MW — Mikkel’s Workspace",
            .applicationVersion: shortVersion,
            .credits: credits,
        ]
        if !build.isEmpty, build != shortVersion {
            options[.version] = build
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        UpdateChecker.check { [weak self] result in
            DispatchQueue.main.async {
                self?.presentUpdateResult(result)
            }
        }
    }

    private func presentUpdateResult(_ result: Result<UpdateChecker.Result, Error>) {
        let alert = NSAlert()
        switch result {
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .success(let info):
            let current = UpdateChecker.currentVersion
            if info.isNewer {
                alert.messageText = "MW \(info.latestTag) is available"
                alert.informativeText = """
                You’re running \(current). The latest release is \(info.latestTag).

                Open the release page to download, or copy the install command \
                to update from the terminal.
                """
                alert.addButton(withTitle: "Open Release Page")
                alert.addButton(withTitle: "Copy Install Command")
                alert.addButton(withTitle: "Later")
                let response = alert.runModal()
                switch response {
                case .alertFirstButtonReturn:
                    NSWorkspace.shared.open(info.htmlURL)
                case .alertSecondButtonReturn:
                    let cmd = "curl -fsSL https://raw.githubusercontent.com/\(UpdateChecker.repo)/main/install.sh | bash"
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(cmd, forType: .string)
                default:
                    break
                }
            } else {
                alert.messageText = "MW is up to date"
                alert.informativeText = "You’re on \(current) (latest is \(info.latestTag))."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc private func showPreferences() {
        if prefs == nil {
            prefs = PreferencesWindowController(
                store: store,
                onChange: { [weak self] combo in
                    guard let self else { return }
                    self.currentCombo = combo
                    self.registerHotkey()
                    self.buildMenu()
                },
                onInstantChange: { [weak self] combos in
                    guard let self else { return }
                    self.instantCombos = combos
                    InstantSnapStore.save(combos)
                    self.registerInstantHotkeys()
                },
                onProfilesChanged: { [weak self] in
                    self?.buildMenu()
                })
        }
        prefs?.show(current: currentCombo, instants: instantCombos)
    }

    // MARK: - Instant snap
    private func registerInstantHotkeys() {
        instantHotkeys = Array(repeating: nil, count: InstantSnapStore.slotCount)
        for (i, combo) in instantCombos.enumerated() {
            guard let combo, !combo.isEmpty else { continue }
            let hk = Hotkey(keyCode: combo.keyCode,
                            modifiers: combo.modifiers) { [weak self] in
                self?.instantSnap(toRegionIndex: i)
            }
            if hk == nil {
                NSLog("mikkelsworkspace: failed to register instant snap #\(i + 1) (\(combo.display))")
            }
            instantHotkeys[i] = hk
        }
    }

    private func instantSnap(toRegionIndex index: Int) {
        guard let window = WindowMover.focusedWindow() else {
            notifyNoWindow()
            return
        }
        guard let screen = WindowMover.screen(of: window) ?? NSScreen.main else { return }
        let regions = store.regions(for: screen.snapDisplayID)
        guard index < regions.count else {
            NSSound.beep()
            return
        }
        let frame = regions[index].rect(in: screen.visibleFrame)
        let result = WindowMover.move(window: window, to: frame)
        switch result {
        case .ok, .axError:
            break
        case .notTrusted:
            promptForAccessibility()
        case .noWindow:
            notifyNoWindow()
        }
    }

    // MARK: - Actions
    @objc private func editRegions() {
        if editor == nil { editor = EditorWindowController(store: store) }
        editor?.show()
        // Refresh menu after the editor closes; cheapest is to update on next tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.buildMenu()
        }
    }

    @objc private func showOverlay() {
        // Capture currently-focused window BEFORE we steal focus.
        let target = WindowMover.focusedWindow()
        if overlay == nil { overlay = OverlayWindowController(store: store) }
        overlay?.present(targetWindow: target) { [weak self] frame in
            guard let self else { return }
            self.overlay?.dismiss()
            guard let frame else { return }
            let result = WindowMover.move(window: target, to: frame)
            switch result {
            case .ok:
                break
            case .notTrusted:
                self.promptForAccessibility()
            case .noWindow:
                self.notifyNoWindow()
            case .axError:
                break
            }
        }
    }

    private func notifyNoWindow() {
        let a = NSAlert()
        a.messageText = "Click the window you want to snap"
        let hint = currentCombo.isEmpty
            ? "Click into the window you want to snap, then trigger MW again."
            : "Click into the window you want to snap, then press \(currentCombo.display) again."
        a.informativeText = """
        MW didn’t have a focused window to move into the selected region.

        \(hint)

        If this keeps happening, your bundle may not have Accessibility \
        access — see Preferences ▸ Privacy & Security ▸ Accessibility.
        """
        a.runModal()
    }

    private func promptForAccessibility() {
        let a = NSAlert()
        a.messageText = "Accessibility access required"
        a.informativeText = """
        MW needs Accessibility permission to move windows in other apps.

        If you previously granted it to an older build, remove the existing \
        “MW” entry first (select it and press –), then add this \
        bundle again and re-launch the app.
        """
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Drag-snap
    private func setupDragSnap() {
        if overlay == nil { overlay = OverlayWindowController(store: store) }
        // Defer starting the event tap until Accessibility is granted;
        // CGEvent.tapCreate silently returns nil without it.
        guard AXIsProcessTrusted() else { return }
        let monitor = DragSnapMonitor(store: store, overlay: overlay!)
        monitor.start()
        dragSnap = monitor
    }

    // MARK: - Accessibility prompt
    private func ensureAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        lastAccessibilityTrust = AXIsProcessTrustedWithOptions(opts)
        // macOS doesn't post a reliable system notification when
        // Accessibility is granted to a freshly-prompted process, so
        // poll for the transition and wire up AX-dependent features
        // as soon as it flips. 1 s is fast enough to feel instant
        // without measurable battery cost.
        if !lastAccessibilityTrust {
            accessibilityTrustTimer = Timer.scheduledTimer(
                withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkAccessibilityTrust()
            }
        }
    }

    private func checkAccessibilityTrust() {
        let trusted = AXIsProcessTrusted()
        guard trusted, !lastAccessibilityTrust else { return }
        lastAccessibilityTrust = true
        accessibilityTrustTimer?.invalidate()
        accessibilityTrustTimer = nil
        // Now safe to install the drag-snap event tap.
        if dragSnap == nil { setupDragSnap() }
    }
}
