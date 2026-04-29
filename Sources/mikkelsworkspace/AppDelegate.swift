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

    func applicationDidFinishLaunching(_ note: Notification) {
        ensureAccessibilityPermission()
        store.load()
        store.refreshLabels(from: NSScreen.screens)
        currentCombo = KeyCombo.load()
        instantCombos = InstantSnapStore.load()
        buildMenu()
        registerHotkey()
        registerInstantHotkeys()

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
        let snapTitle = currentCombo.isEmpty
            ? "Snap to Region"
            : "Snap to Region   \(currentCombo.display)"
        menu.addItem(withTitle: snapTitle,
                     action: #selector(showOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "Edit Regions for All Displays…",
                     action: #selector(editRegions), keyEquivalent: "")
        menu.addItem(withTitle: "Preferences…",
                     action: #selector(showPreferences), keyEquivalent: ",")
        menu.addItem(withTitle: "About MW",
                     action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…",
                     action: #selector(checkForUpdates), keyEquivalent: "")

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

        // Saved profiles for displays that aren't currently connected
        let connectedKeys = Set(NSScreen.screens.map { $0.snapDisplayID.key })
        let offline = store.allKnownDisplays.filter { !connectedKeys.contains($0.key) }
        if !offline.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Saved Profiles (offline)",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for d in offline {
                let item = NSMenuItem(
                    title: "  \(d.label) — \(d.regionCount) region\(d.regionCount == 1 ? "" : "s")",
                    action: #selector(forgetProfile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = d.key
                item.toolTip = "Click to forget this saved profile"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        for item in menu.items where item.target == nil && item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func forgetProfile(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Forget profile for “\(sender.title.trimmingCharacters(in: .whitespaces))”?"
        alert.informativeText = "Saved regions for this display will be deleted."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Use a synthetic DisplayID to clear it.
        store.setRegions([], for: DisplayID(key: key, label: ""))
        buildMenu()
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
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MW",
            .applicationVersion: "Mikkel’s Workspace",
            .credits: credits,
        ])
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
        a.messageText = "No focused window to snap"
        a.informativeText = """
        MW couldn’t find a focused window when you triggered the \
        hotkey. Click into the window you want to snap, then press \
        \(currentCombo.display) again.

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

    // MARK: - Accessibility prompt
    private func ensureAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}
