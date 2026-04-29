import Foundation

/// Persists up to `slotCount` "instant snap" hotkeys. Slot `i` snaps the
/// focused window to region index `i` on whichever display that window
/// currently lives on.
enum InstantSnapStore {
    static let slotCount = 6
    private static let key = "mikkelsworkspace.instantSnaps"

    static func load() -> [KeyCombo?] {
        var result: [KeyCombo?] = Array(repeating: nil, count: slotCount)
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([KeyCombo?].self, from: data)
        else { return result }
        for (i, c) in decoded.prefix(slotCount).enumerated() { result[i] = c }
        return result
    }

    static func save(_ combos: [KeyCombo?]) {
        if let data = try? JSONEncoder().encode(combos) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
