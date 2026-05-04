import Foundation
import AppKit

/// Persisted grid size (columns × rows) used by the region editor's
/// snap-to-grid feature.
///
/// The stored `columns`/`rows` describe the grid for the *main* display.
/// Other displays derive their own column/row counts so that one grid
/// cell has roughly the same size in points across every monitor — i.e.
/// a wider monitor gets more columns, a taller monitor gets more rows,
/// and the snap grid never looks "stretched".
enum GridSettings {
    private static let colsKey = "GridColumns"
    private static let rowsKey = "GridRows"

    static let defaultCols: Int = 48
    static let defaultRows: Int = 48
    static let minSize: Int = 1
    static let maxSize: Int = 128

    static var columns: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: colsKey)
            return v == 0 ? defaultCols : clamp(v)
        }
        set { UserDefaults.standard.set(clamp(newValue), forKey: colsKey) }
    }

    static var rows: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: rowsKey)
            return v == 0 ? defaultRows : clamp(v)
        }
        set { UserDefaults.standard.set(clamp(newValue), forKey: rowsKey) }
    }

    private static func clamp(_ v: Int) -> Int {
        max(minSize, min(maxSize, v))
    }

    // MARK: - Per-display derivation

    /// Reference cell size (in points) derived from the user's preferred
    /// columns/rows applied to the main display's visible frame.
    static func referenceCellSize() -> CGSize {
        let mainFrame = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = mainFrame.width  / CGFloat(columns)
        let h = mainFrame.height / CGFloat(rows)
        return CGSize(width: max(1, w), height: max(1, h))
    }

    /// Columns to use for a display whose visible frame has the given
    /// size. The cell width matches the reference cell from the main
    /// display so the grid is uniform across monitors.
    static func columns(forDisplaySize size: CGSize) -> Int {
        let cell = referenceCellSize()
        let n = Int((size.width / cell.width).rounded())
        return clamp(n)
    }

    /// Rows to use for a display whose visible frame has the given size.
    static func rows(forDisplaySize size: CGSize) -> Int {
        let cell = referenceCellSize()
        let n = Int((size.height / cell.height).rounded())
        return clamp(n)
    }
}
