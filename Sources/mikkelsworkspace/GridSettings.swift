import Foundation
import AppKit

/// Persisted snap-grid setting used by the region editor.
///
/// The grid is now defined by a single number — `cellsAcrossMain` — i.e.
/// how many columns the grid has on the *main* display. The cell is
/// always a perfect square (in points), so:
///   * the cell size in points = mainDisplay.width / cellsAcrossMain
///   * other displays derive their own column/row count from that cell
///     size, keeping cells uniformly sized across every monitor.
enum GridSettings {
    private static let cellsKey = "GridCellsAcrossMain"
    // Legacy key retained only so we can migrate gracefully.
    private static let legacyColsKey = "GridColumns"

    static let defaultCellsAcrossMain: Int = 24
    static let minCells: Int = 2
    static let maxCells: Int = 128

    static var cellsAcrossMain: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: cellsKey)
            if v != 0 { return clamp(v) }
            // Migrate from the previous columns/rows pair if present.
            let legacy = UserDefaults.standard.integer(forKey: legacyColsKey)
            if legacy != 0 { return clamp(legacy) }
            return defaultCellsAcrossMain
        }
        set { UserDefaults.standard.set(clamp(newValue), forKey: cellsKey) }
    }

    private static func clamp(_ v: Int) -> Int {
        max(minCells, min(maxCells, v))
    }

    // MARK: - Per-display derivation

    /// Square cell size in points, derived from the main display.
    static func cellSize() -> CGFloat {
        let mainW = NSScreen.main?.visibleFrame.width
            ?? NSScreen.screens.first?.visibleFrame.width
            ?? 1440
        return max(1, mainW / CGFloat(cellsAcrossMain))
    }

    /// Columns to use for a display whose visible frame has the given size.
    static func columns(forDisplaySize size: CGSize) -> Int {
        let n = Int((size.width / cellSize()).rounded())
        return max(1, min(maxCells, n))
    }

    /// Rows to use for a display whose visible frame has the given size.
    static func rows(forDisplaySize size: CGSize) -> Int {
        let n = Int((size.height / cellSize()).rounded())
        return max(1, min(maxCells, n))
    }
}

extension Notification.Name {
    /// Posted whenever `GridSettings.cellsAcrossMain` changes, so any
    /// open editor / preview overlays can re-derive their grids.
    static let gridSettingsChanged = Notification.Name("MWGridSettingsChanged")
}
