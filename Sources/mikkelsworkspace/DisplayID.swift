import AppKit

/// Stable, human-readable identifier for a connected display.
///
/// We hash CoreGraphics vendor/model/serial together with the resolution
/// so that two physically identical monitors still get distinct profiles
/// when their arrangement differs. As a last-resort fallback (e.g. when
/// vendor numbers are zero, common for some virtual displays) we fall
/// back to the localized name.
struct DisplayID: Hashable, Codable {
    let key: String      // persisted; stable across reconnects
    let label: String    // shown in UI

    init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

extension NSScreen {
    /// CoreGraphics display id, if available.
    var cgDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Best-effort stable identifier for this physical display.
    var snapDisplayID: DisplayID {
        let label = self.localizedName
        guard let id = cgDisplayID else {
            return DisplayID(key: "name:\(label)", label: label)
        }
        let vendor = CGDisplayVendorNumber(id)
        let model  = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        let w = Int(frame.width)
        let h = Int(frame.height)
        if vendor != 0 || model != 0 || serial != 0 {
            let key = "v\(vendor)-m\(model)-s\(serial)-\(w)x\(h)"
            return DisplayID(key: key, label: label)
        }
        // Fallback: name + size.
        return DisplayID(key: "name:\(label)-\(w)x\(h)", label: label)
    }
}
