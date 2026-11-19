import AppKit
import Carbon
import ServiceManagement

enum HotKeys {
    static var actions: [UInt32: () -> Void] = [:]

    static func add(key: Int, modifiers: Int, _ action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: OSType(0x484F_5021), id: id),
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

let app = NSApplication.shared
let launcher = Launcher(sources: [AppsSource(), ClipboardSource()])
HotKeys.listen()
HotKeys.add(key: kVK_Space, modifiers: optionKey) { launcher.toggle(0) }
HotKeys.add(key: kVK_ANSI_V, modifiers: optionKey) { launcher.toggle(1) }

// App Nap would throttle the clipboard timer while no window is visible and miss copies.
let keepAwake = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "clipboard history")
try? SMAppService.mainApp.register()
app.run()
