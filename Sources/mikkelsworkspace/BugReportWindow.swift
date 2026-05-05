import AppKit

/// A two-step bug-report flow:
///   1. User types a description.
///   2. User presses **Start Recording** — debug logging is turned on
///      and the current log file size is remembered.
///   3. User reproduces the bug.
///   4. User presses **Stop Recording** — the new log lines written
///      since step 2 are captured.
///   5. User presses **Send Bug Report** — a GitHub issue is opened in
///      the browser, prefilled with the description, environment info,
///      and the captured log slice. If the URL would exceed GitHub's
///      length limit, the full body is also copied to the clipboard.
final class BugReportWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    private let issueRepo = "MikkelIJ/MW"
    /// Conservative cap: GitHub accepts long URLs but browsers vary.
    /// Above this we fall back to copy-to-clipboard.
    private let maxURLBodyBytes = 6000

    private let descriptionTextView = NSTextView()
    private let stepsTextView = NSTextView()
    private let recordButton = NSButton(title: "Start Recording", target: nil, action: nil)
    private let recordStatus = NSTextField(labelWithString: "Not recording.")
    private let sendButton = NSButton(title: "Send Bug Report", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var recording: Bool = false
    private var recordStartOffset: UInt64 = 0
    private var capturedLog: String = ""
    /// Tracks whether DebugLog was on before we started, so we can
    /// leave it as we found it when the report is sent.
    private var debugLogWasEnabledBeforeRecording: Bool = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Report a Bug"
        window.minSize = NSSize(width: 480, height: 460)
        super.init(window: window)
        window.delegate = self
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let intro = NSTextField(wrappingLabelWithString:
            "Briefly describe the bug, then press Start Recording, reproduce the problem, and press Stop Recording. Sending opens a prefilled GitHub issue.")
        intro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        intro.textColor = .secondaryLabelColor

        let descLabel = NSTextField(labelWithString: "Bug description")
        let stepsLabel = NSTextField(labelWithString: "Steps to reproduce (optional)")

        configureTextView(descriptionTextView, placeholder: "What went wrong? What did you expect?")
        configureTextView(stepsTextView, placeholder: "1. …\n2. …\n3. …")

        let descScroll = makeScroll(for: descriptionTextView, minHeight: 90)
        let stepsScroll = makeScroll(for: stepsTextView, minHeight: 70)

        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.bezelStyle = .rounded

        recordStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        recordStatus.textColor = .secondaryLabelColor

        sendButton.target = self
        sendButton.action = #selector(sendReport)
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.isEnabled = false

        cancelButton.target = self
        cancelButton.action = #selector(closeWindow)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let recordRow = NSStackView(views: [recordButton, recordStatus])
        recordRow.orientation = .horizontal
        recordRow.spacing = 12
        recordRow.alignment = .centerY

        let buttonRow = NSStackView(views: [NSView(), cancelButton, sendButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fill

        let stack = NSStackView(views: [
            intro,
            descLabel, descScroll,
            stepsLabel, stepsScroll,
            recordRow,
            buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            descScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func configureTextView(_ tv: NSTextView, placeholder: String) {
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.delegate = self
        tv.string = ""
        // Without these, the text view paints with the default (black)
        // text on a transparent background, which is invisible against
        // the bezel's dark fill in dark mode.
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textColor = .textColor
        tv.insertionPointColor = .textColor
        // `textColor` alone only affects existing characters; newly
        // typed glyphs pick up `typingAttributes`, which otherwise
        // defaults to black foreground and is invisible in dark mode.
        tv.typingAttributes = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.textColor,
        ]
        // Lightweight placeholder via accessibility hint (NSTextView has
        // no real placeholder API; intro label above sets expectation).
        tv.setAccessibilityPlaceholderValue(placeholder)
    }

    private func makeScroll(for tv: NSTextView, minHeight: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tv
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        return scroll
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        descriptionTextView.window?.makeFirstResponder(descriptionTextView)
        updateSendEnabled()
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        if recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        debugLogWasEnabledBeforeRecording = DebugLog.shared.enabled
        if !DebugLog.shared.enabled {
            DebugLog.shared.enabled = true
        }
        DebugLog.shared.log("--- bug report: recording started ---")
        // Read current size; we'll capture only bytes written from here.
        let url = DebugLog.shared.logFileURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        recordStartOffset = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        capturedLog = ""
        recording = true
        recordButton.title = "Stop Recording"
        recordStatus.stringValue = "Recording… reproduce the bug, then press Stop."
        recordStatus.textColor = .systemRed
        updateSendEnabled()
    }

    private func stopRecording() {
        DebugLog.shared.log("--- bug report: recording stopped ---")
        recording = false
        recordButton.title = "Start Recording"

        let url = DebugLog.shared.logFileURL
        let slice: String
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: recordStartOffset)
            let data = (try? handle.readToEnd()) ?? Data()
            slice = String(data: data, encoding: .utf8) ?? "(log slice was not valid UTF-8)"
        } else {
            slice = "(could not read log file at \(url.path))"
        }
        capturedLog = slice

        // Restore prior debug-logging state.
        if !debugLogWasEnabledBeforeRecording {
            DebugLog.shared.enabled = false
        }

        let lines = capturedLog.split(separator: "\n").count
        let bytes = capturedLog.utf8.count
        recordStatus.stringValue = "Captured \(lines) line\(lines == 1 ? "" : "s") (\(bytes) bytes)."
        recordStatus.textColor = .secondaryLabelColor
        updateSendEnabled()
    }

    // MARK: - Send

    @objc private func sendReport() {
        let description = descriptionTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            NSSound.beep()
            return
        }
        let steps = stepsTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)

        let title = makeIssueTitle(from: description)
        let body = makeIssueBody(description: description, steps: steps, log: capturedLog)

        // Try to open a prefilled GitHub issue URL. GitHub itself
        // accepts long URLs, but browsers and the URL APIs we use
        // don't always cope, so fall back to a clipboard handoff for
        // anything large.
        let bodyForURL: String
        let usedClipboard: Bool
        if body.utf8.count > maxURLBodyBytes {
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            clipboard.setString(body, forType: .string)
            bodyForURL = """
                The bug report is on your clipboard — please paste it here \
                (the captured log was too long to fit in the URL).
                """
            usedClipboard = true
        } else {
            bodyForURL = body
            usedClipboard = false
        }

        guard let url = makeIssueURL(title: title, body: bodyForURL) else {
            presentSendFailure()
            return
        }
        NSWorkspace.shared.open(url)
        if usedClipboard {
            presentClipboardHandoff()
        } else {
            close()
        }
    }

    private func makeIssueTitle(from description: String) -> String {
        // First non-empty line, capped at 80 chars.
        let firstLine = description
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? "Bug report"
        let trimmed = firstLine.count > 80 ? String(firstLine.prefix(77)) + "…" : firstLine
        return "[Bug] \(trimmed)"
    }

    private func makeIssueBody(description: String, steps: String, log: String) -> String {
        var body = "### Description\n\n\(description)\n\n"
        if !steps.isEmpty {
            body += "### Steps to reproduce\n\n\(steps)\n\n"
        }
        body += "### Environment\n\n\(environmentSection())\n\n"
        body += "### Debug log\n\n"
        if log.isEmpty {
            body += "_No log captured. The reporter did not run a recording session._\n"
        } else {
            body += "```\n\(log)\n```\n"
        }
        return body
    }

    private func environmentSection() -> String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? UpdateChecker.currentVersion
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let arch: String = {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x86_64"
            #else
            return "unknown"
            #endif
        }()
        let displays = NSScreen.screens.count
        return """
        - MW version: \(version) (build \(build))
        - macOS: \(os)
        - Architecture: \(arch)
        - Connected displays: \(displays)
        """
    }

    private func makeIssueURL(title: String, body: String) -> URL? {
        var comps = URLComponents(string: "https://github.com/\(issueRepo)/issues/new")
        comps?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "bug"),
        ]
        return comps?.url
    }

    private func presentSendFailure() {
        let alert = NSAlert()
        alert.messageText = "Couldn’t open the GitHub issue page"
        alert.informativeText = "Please file an issue manually at https://github.com/\(issueRepo)/issues/new — the bug report has been copied to your clipboard."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentClipboardHandoff() {
        let alert = NSAlert()
        alert.messageText = "Bug report copied to clipboard"
        alert.informativeText = "The captured log was too long to fit in the URL. Paste (⌘V) the report into the GitHub issue body that just opened in your browser."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        close()
    }

    // MARK: - State

    private func updateSendEnabled() {
        let hasDescription = !descriptionTextView.string
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasDescription && !recording
    }

    func textDidChange(_ notification: Notification) {
        updateSendEnabled()
    }

    @objc private func closeWindow() { close() }

    func windowWillClose(_ notification: Notification) {
        // Restore debug-log state if the user closed mid-recording.
        if recording {
            recording = false
            if !debugLogWasEnabledBeforeRecording {
                DebugLog.shared.enabled = false
            }
        }
    }
}
