import Carbon

struct HotKey {
    let key: Int
    let modifiers: Int
}

enum HotKeys {
    private static var actions: [UInt32: () -> Void] = [:]

    static func add(_ hotkey: HotKey, _ action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(hotkey.key), UInt32(hotkey.modifiers), EventHotKeyID(signature: OSType(0x484F_5021), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    static func listen() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            HotKeys.actions[hotKey.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
