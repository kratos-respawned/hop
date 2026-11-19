import AppKit

final class MainSearch: Page {
    let name = "Search"
    let icon = tile("magnifyingglass", .systemBlue)
    let placeholder = "Search apps and commands"
    let actionName = "Open"
    private let plugins: PluginManager
    private let recentLimit = 3
    private var recents = UserDefaults.standard.data(forKey: "recentSearches")
        .flatMap { try? JSONDecoder().decode([Recent].self, from: $0) } ?? []

    private struct Recent: Codable {
        let query: String
        let title: String
    }

    init(plugins: PluginManager) {
        self.plugins = plugins
    }

    func search(_ query: String) -> [Item] {
        guard query.isEmpty else { return commands(matching: query) + results(for: query) }
        let recentItems = recents.compactMap(item)
        let recentTitles = Set(recentItems.map(\.title))
        return recentItems + results(for: query).filter { !recentTitles.contains($0.title) }
    }

    // Answers like a calculation or a definition are one-off lookups, not places to go back to.
    func didSelect(_ item: Item, query: String) {
        guard item.preview == nil else { return }
        let originalQuery = query.isEmpty ? recents.first { $0.title == item.title }?.query ?? item.title : query
        recents.removeAll { $0.title == item.title }
        recents = Array(([Recent(query: originalQuery, title: item.title)] + recents).prefix(recentLimit))
        UserDefaults.standard.set(try? JSONEncoder().encode(recents), forKey: "recentSearches")
    }

    private func results(for query: String) -> [Item] {
        plugins.searches.flatMap { $0.search(query) }
    }

    private func item(for recent: Recent) -> Item? {
        guard var item = (commands(matching: recent.query) + results(for: recent.query)).first(where: { $0.title == recent.title }),
              item.preview == nil else { return nil }
        item.section = "Recent"
        return item
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
