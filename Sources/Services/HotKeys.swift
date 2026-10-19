import Carbon.HIToolbox

/// Registers the global shortcuts ⌥⌘L (start/stop) and ⌥⌘M (add marker). Carbon hot keys need no permissions.
enum HotKeys {
    private static var refs: [EventHotKeyRef?] = []

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if id.id == 1 { Recorder.shared.toggle() } else if id.id == 2 { Recorder.shared.addMarker() }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)

        let mods = UInt32(cmdKey | optionKey)
        for (index, key) in [kVK_ANSI_L, kVK_ANSI_M].enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x50534C47), id: UInt32(index + 1)) // 'PSLG'
            if RegisterEventHotKey(UInt32(key), mods, id, GetApplicationEventTarget(), 0, &ref) == noErr {
                refs.append(ref)
            }
        }
    }
}
