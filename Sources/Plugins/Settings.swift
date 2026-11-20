import AppKit
import Carbon

enum OpenShortcut {
    static var id: UInt32 = 0
    private static let standard = HotKey(key: kVK_Space, modifiers: optionKey, label: "⌥ Space")

    static var current: HotKey {
        UserDefaults.standard.data(forKey: "openShortcut").flatMap { try? JSONDecoder().decode(HotKey.self, from: $0) } ?? standard
    }

    static func save(_ hotkey: HotKey) {
        UserDefaults.standard.set(try? JSONEncoder().encode(hotkey), forKey: "openShortcut")
    }
}

struct Setting {
    let key: String
    let title: String
    let detail: String
    let section: String

    var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    static let skipCopiedRequests = Setting(
        key: "skipCopiedRequests", title: "Skip copied logins",
        detail: "Clipboard history won't save text that carries cookies, authorization headers or a reddit_session, like a request copied as cURL from DevTools.",
        section: "Clipboard")
    static let redditNSFW = Setting(
        key: "redditNSFW", title: "Allow NSFW on Reddit",
        detail: "Reddit posts marked NSFW appear in the Wallpapers page.",
        section: "Wallpapers")
    static let selectionButton = Setting(
        key: "selectionButton", title: "AI button on selected text",
        detail: "Shows a small button next to text you select with the mouse in any app. Click it to proofread or rewrite the text with AI.",
        section: "AI")
    static let all = [skipCopiedRequests, redditNSFW, selectionButton]
}

final class SettingsPlugin: Plugin, Page {
    let name = "Settings"
    let icon = tile("gearshape.fill", .systemGray)
    let placeholder = "Search settings"
    let actionName = "Switch"
    var hasPreview: Bool { true }
    private var recording = false
    private var notice = ""

    func register(in hop: PluginRegistry) {
        hop.add(page: self)
    }

    func search(_ query: String) -> [Item] {
        [shortcutRow, AIEngine.settingRow(opens: self)].filter { query.isEmpty || fuzzyScore(query, $0.title) != nil } + Setting.all.filter { query.isEmpty || fuzzyScore(query, $0.title) != nil }.map { setting in
            let on = setting.isOn
            return Item(title: setting.title, subtitle: setting.detail, badge: on ? "On" : "Off", action: on ? "Turn Off" : "Turn On",
                        preview: .rich(NSAttributedString(string: setting.detail, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])),
                        section: setting.section, opens: self,
                        icon: { tile(on ? "checkmark.circle.fill" : "circle", on ? .systemGreen : .systemGray) },
                        run: { UserDefaults.standard.set(!on, forKey: setting.key) })
        }
    }

    private var shortcutRow: Item {
        let shortcut = OpenShortcut.current.label
        let detail = notice.isEmpty ? "Opens Hop from any app. Press Enter, then the new keys. Use at least one of ⌘, ⌥ or ⌃." : notice
        let spotlight = "To use ⌘ Space, first turn off Spotlight's shortcut in System Settings, Keyboard, Keyboard Shortcuts, Spotlight."
        return Item(title: recording ? "Press the new shortcut" : "Shortcut to open Hop",
                    subtitle: recording ? "Esc cancels" : detail, badge: recording ? "" : shortcut, action: "Change",
                    preview: .rich(NSAttributedString(string: detail + "\n\n" + spotlight, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])),
                    section: "General", opens: self, icon: { tile("keyboard", .systemBlue) }, run: { [self] in record() })
    }

    private func record() {
        recording = true
        notice = ""
        HotKeys.register(nil, id: OpenShortcut.id)
        launcher.keyRecorder = { [self] event in
            guard let event, event.keyCode != kVK_Escape else { return finish(nil) }
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            guard !flags.isDisjoint(with: [.control, .option, .command]) else { return NSSound.beep() }
            finish(HotKey(key: Int(event.keyCode), modifiers: Self.carbon(flags), label: Self.label(flags, event)))
        }
    }

    private func finish(_ hotkey: HotKey?) {
        launcher.keyRecorder = nil
        recording = false
        if let hotkey, HotKeys.register(hotkey, id: OpenShortcut.id) {
            OpenShortcut.save(hotkey)
        } else {
            HotKeys.register(OpenShortcut.current, id: OpenShortcut.id)
            if let hotkey { notice = "\(hotkey.label) is taken by another app, pick a different one." }
        }
        NotificationCenter.default.post(name: .pageChanged, object: self)
    }

    private static func carbon(_ flags: NSEvent.ModifierFlags) -> Int {
        [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
            .filter { flags.contains($0.0) }.reduce(0) { $0 | $1.1 }
    }

    private static func label(_ flags: NSEvent.ModifierFlags, _ event: NSEvent) -> String {
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { flags.contains($0.0) }.map(\.1).joined()
        let names = [kVK_Space: "Space", kVK_Return: "↵", kVK_Tab: "Tab", kVK_Delete: "⌫", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                     kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                     kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        let key = names[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        return symbols + " " + key
    }
}
