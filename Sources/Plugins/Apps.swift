import AppKit

struct App: Equatable {
    let name: String
    let path: String
}

final class AppsPlugin: Plugin, SearchProvider {
    private var apps: [App] = []
    private var scannedAt = Date.distantPast
    private var launches = UserDefaults.standard.dictionary(forKey: "launches") as? [String: Int] ?? [:]

    func register(in hop: PluginRegistry) {
        hop.add(search: self)
    }

    func search(_ query: String) -> [Item] {
        if Date().timeIntervalSince(scannedAt) > 10 {
            apps = Self.scan()
            scannedAt = Date()
        }
        let ranked = apps
            .compactMap { app in fuzzyScore(query, app.name).map { (app, $0 + min(launches[app.path] ?? 0, 30) * 10) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
        return ranked.prefix(50).map { item(for: $0.0) }
    }

    private func item(for app: App) -> Item {
        let folder = (app.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return Item(title: app.name, subtitle: folder, badge: "Application", action: "Open Application", section: "Applications",
                    icon: { NSWorkspace.shared.icon(forFile: app.path) }) { [self] in
            launches[app.path, default: 0] += 1
            UserDefaults.standard.set(launches, forKey: "launches")
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: .init())
        }
    }

    private static let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications",
                                NSHomeDirectory() + "/Applications"]

    static func scan() -> [App] {
        var seen = Set<String>(), apps = [App(name: "Finder", path: "/System/Library/CoreServices/Finder.app")]
        func collectApps(in folder: String, searchSubfolders: Bool) {
            for entry in entriesIncludingSymlinks(folder) where !entry.hasPrefix(".") {
                let path = folder + "/" + entry
                if entry.hasSuffix(".app") {
                    let name = String(entry.dropLast(".app".count))
                    if seen.insert(name).inserted { apps.append(App(name: name, path: path)) }
                } else if searchSubfolders {
                    collectApps(in: path, searchSubfolders: false)
                }
            }
        }
        roots.forEach { collectApps(in: $0, searchSubfolders: true) }
        return apps
    }

    // Not FileManager.enumerator: it drops symlinked apps like /Applications/Safari.app.
    private static func entriesIncludingSymlinks(_ folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }
}
