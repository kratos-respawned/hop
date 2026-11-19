import AppKit

final class MainSearch: Page {
    let name = "Search"
    let icon = tile("magnifyingglass", .systemBlue)
    let placeholder = "Search apps and commands"
    let actionName = "Open"
    private let plugins: PluginManager

    init(plugins: PluginManager) {
        self.plugins = plugins
    }

    func search(_ query: String) -> [Item] {
        commands(matching: query) + plugins.searches.flatMap { $0.search(query) }
    }

    private func commands(matching query: String) -> [Item] {
        guard query.count >= 2 else { return [] }
        let openPages = plugins.pages.map { page in
            Item(title: page.name, badge: "Command", action: "Open", section: "Commands", opens: page, icon: { page.icon })
        }
        let actions = plugins.commands.map { command in
            Item(title: command.name, badge: "Command", action: "Run", section: "Commands", icon: { command.icon }, run: command.run)
        }
        return (openPages + actions).filter { isInitialsOrBetterMatch(query, $0.title) }
    }

    private func isInitialsOrBetterMatch(_ query: String, _ title: String) -> Bool {
        (fuzzyScore(query, title) ?? 0) >= MatchScore.initials - title.count
    }
}
