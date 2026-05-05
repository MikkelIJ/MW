import AppKit

/// In-app live log viewer. Tails the on-disk DebugLog file using a
/// `DispatchSource.makeFileSystemObjectSource(.write|.extend)` so we
/// only re-read appended bytes (no polling). Keeps things lightweight
/// and means we can fully tear it down by closing the window.
final class LogWindowController: NSWindowController, NSWindowDelegate {
    private let logURL: URL
    private let textView: NSTextView
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var followTail: Bool = true

    /// Invoked when the user closes the window directly (e.g. red
    /// traffic-light button). Lets the owner sync UI state such as
    /// the menu bar checkmark on the **Debug Logging** item.
    var onUserClose: (() -> Void)?

    init(logURL: URL) {
        self.logURL = logURL

        // Text view inside a scroll view, monospaced, dark.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder

        let tv = NSTextView()
        tv.isEditable = false
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(white: 0.08, alpha: 1)
        tv.textColor = NSColor(white: 0.92, alpha: 1)
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        self.textView = tv
        scroll.documentView = tv

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "MW Debug Log"
        win.contentView = scroll
        win.center()
        win.isReleasedWhenClosed = false

        super.init(window: win)
        win.delegate = self
        loadInitialContent()
        startWatching()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { stopWatching() }

    // MARK: - File watching

    private func loadInitialContent() {
        // Make sure file exists.
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        // Read the last ~64 KB so the user sees recent context without
        // dumping huge log histories.
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 64 * 1024
        let start: UInt64 = size > chunk ? size - chunk : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size
        try? handle.close()
        if let s = String(data: data, encoding: .utf8) {
            append(s)
        }
    }

    private func startWatching() {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        fileHandle = handle
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main)
        src.setEventHandler { [weak self] in self?.handleFileEvent(src.data) }
        src.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }
        src.resume()
        source = src
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
    }

    private func handleFileEvent(_ events: DispatchSource.FileSystemEvent) {
        if events.contains(.delete) || events.contains(.rename) {
            // Log was rotated/replaced. Re-open and seek to end.
            stopWatching()
            offset = 0
            startWatching()
            return
        }
        guard let handle = fileHandle else { return }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        if data.isEmpty { return }
        offset += UInt64(data.count)
        if let s = String(data: data, encoding: .utf8) {
            append(s)
        }
    }

    private func append(_ s: String) {
        guard !s.isEmpty else { return }
        let storage = textView.textStorage!
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textView.font as Any,
            .foregroundColor: textView.textColor as Any,
        ]
        storage.append(NSAttributedString(string: s, attributes: attrs))
        // Cap memory: keep only the last ~5 000 lines.
        let maxChars = 400_000
        if storage.length > maxChars {
            let trim = storage.length - maxChars
            storage.deleteCharacters(in: NSRange(location: 0, length: trim))
        }
        if followTail {
            textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopWatching()
        onUserClose?()
    }
}
