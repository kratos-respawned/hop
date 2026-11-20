import AppKit

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
    static let all = [skipCopiedRequests, redditNSFW]
}

final class SettingsPlugin: Plugin, Page {
    let name = "Settings"
    let icon = tile("gearshape.fill", .systemGray)
    let placeholder = "Search settings"
    let actionName = "Switch"
    var hasPreview: Bool { true }

    func register(in hop: PluginRegistry) {
        hop.add(page: self)
    }

    func search(_ query: String) -> [Item] {
        Setting.all.filter { query.isEmpty || fuzzyScore(query, $0.title) != nil }.map { setting in
            let on = setting.isOn
            return Item(title: setting.title, subtitle: setting.detail, badge: on ? "On" : "Off", action: on ? "Turn Off" : "Turn On",
                        preview: .rich(NSAttributedString(string: setting.detail, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])),
                        section: setting.section, opens: self,
                        icon: { tile(on ? "checkmark.circle.fill" : "circle", on ? .systemGreen : .systemGray) },
                        run: { UserDefaults.standard.set(!on, forKey: setting.key) })
        }
    }
}
