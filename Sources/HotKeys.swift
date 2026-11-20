import Carbon

struct HotKey: Codable {
    let key: Int
    let modifiers: Int
    var label = ""
}

enum HotKeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]

    @discardableResult
    static func add(_ hotkey: HotKey, _ action: @escaping () -> Void) -> UInt32 {
        let id = UInt32(actions.count + 1)
        actions[id] = action
        register(hotkey, id: id)
        return id
    }

    @discardableResult
    static func register(_ hotkey: HotKey?, id: UInt32) -> Bool {
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        guard let hotkey else { return true }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(hotkey.key), UInt32(hotkey.modifiers), EventHotKeyID(signature: OSType(0x484F_5021), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        refs[id] = ref
        return status == noErr
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
