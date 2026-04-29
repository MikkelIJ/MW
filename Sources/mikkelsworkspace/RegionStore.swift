import Foundation
import AppKit

/// A region is stored as fractions of the screen (0…1) so it survives
/// resolution changes and works on whichever screen is active.
struct Region: Codable, Identifiable {
    var id = UUID()
    var x: CGFloat   // fraction
    var y: CGFloat   // fraction (top-down: 0 = top of screen)
    var w: CGFloat
    var h: CGFloat

    /// Returns a global Cocoa rect (origin at bottom-left, y growing up)
    /// for the given screen frame, interpreting the stored `y` as top-down.
    func rect(in screenFrame: NSRect) -> NSRect {
        let width  = w * screenFrame.width
        let height = h * screenFrame.height
        let x      = screenFrame.minX + self.x * screenFrame.width
        let yTop   = screenFrame.maxY - self.y * screenFrame.height
        let y      = yTop - height
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

/// On-disk schema (v2): map of display key → list of regions, plus a
/// label cache so the menu can show friendly names for displays that are
/// currently disconnected.
private struct StoreFile: Codable {
    var version: Int = 2
    var profiles: [String: [Region]] = [:]
    var labels:   [String: String]   = [:]
}

final class RegionStore {
    private(set) var profiles: [String: [Region]] = [:]
    private(set) var labels:   [String: String]   = [:]

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("mikkelsworkspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("regions.json")
    }

    // MARK: - I/O

    func load() {
        guard let data = try? Data(contentsOf: url) else { return }

        // v2 schema first
        if let file = try? JSONDecoder().decode(StoreFile.self, from: data) {
            profiles = file.profiles
            labels   = file.labels
            return
        }
        // v1 fallback: bare [Region] for the (then) main screen.
        if let legacy = try? JSONDecoder().decode([Region].self, from: data) {
            if let main = NSScreen.main {
                let id = main.snapDisplayID
                profiles[id.key] = legacy
                labels[id.key]   = id.label
            } else {
                profiles["legacy"] = legacy
                labels["legacy"]   = "Legacy"
            }
            save()
        }
    }

    func save() {
        let file = StoreFile(profiles: profiles, labels: labels)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Per-display API

    func regions(for display: DisplayID) -> [Region] {
        profiles[display.key] ?? []
    }

    func setRegions(_ new: [Region], for display: DisplayID) {
        if new.isEmpty {
            profiles.removeValue(forKey: display.key)
        } else {
            profiles[display.key] = new
        }
        labels[display.key] = display.label
        save()
    }

    /// Refresh the cached label for any currently-connected display.
    func refreshLabels(from screens: [NSScreen]) {
        for s in screens {
            let id = s.snapDisplayID
            labels[id.key] = id.label
        }
        save()
    }

    /// All known display keys (connected + remembered).
    var allKnownDisplays: [(key: String, label: String, regionCount: Int)] {
        profiles.keys.sorted().map {
            (key: $0, label: labels[$0] ?? $0, regionCount: profiles[$0]?.count ?? 0)
        }
    }
}
