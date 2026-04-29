import AppKit
import Carbon.HIToolbox

/// Tiny wrapper around Carbon's RegisterEventHotKey.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void
    private static var instances: [UInt32: Hotkey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback
        self.id = Hotkey.nextID
        Hotkey.nextID += 1
        Hotkey.instances[id] = self

        let hkID = EventHotKeyID(signature: OSType(0x534E5052 /* "SNPR" */), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var received = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &received)
            if let hk = Hotkey.instances[received.id] {
                DispatchQueue.main.async { hk.callback() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    deinit {
        if let ref = ref { UnregisterEventHotKey(ref) }
        if let h = handlerRef { RemoveEventHandler(h) }
        Hotkey.instances.removeValue(forKey: id)
    }
}
