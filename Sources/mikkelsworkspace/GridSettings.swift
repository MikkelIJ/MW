import Foundation

/// Persisted grid size (columns × rows) used by the region editor's
/// snap-to-grid feature.
enum GridSettings {
    private static let colsKey = "GridColumns"
    private static let rowsKey = "GridRows"

    static let defaultCols: Int = 12
    static let defaultRows: Int = 12
    static let minSize: Int = 1
    static let maxSize: Int = 64

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
}
