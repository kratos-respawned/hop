import AppKit

struct Item {
    let title: String
    var subtitle = ""
    var badge = ""
    var action = ""
    var preview: Preview?
    var section: String?
    var opens: Page?
    var commandAction = ""
    var commandRun: (() -> Void)?
    var remove: (() -> Void)?
    let icon: () -> NSImage?
    var run: (() -> Void)?
}

enum Preview {
    case text(String)
    case image(URL)
    case answer(question: String, answer: String)
    case code(String)
    case rich(NSAttributedString)
}

struct Command {
    let name: String
    let icon: NSImage
    let run: () -> Void
}

protocol SearchProvider: AnyObject {
    func search(_ query: String) -> [Item]
}

protocol Page: SearchProvider {
    var name: String { get }
    var icon: NSImage { get }
    var placeholder: String { get }
    var actionName: String { get }
    var hasPreview: Bool { get }
    var hotkey: HotKey? { get }
    func willShow()
    func didSelect(_ item: Item, query: String)
}

extension Page {
    var hasPreview: Bool { false }
    var hotkey: HotKey? { nil }
    func willShow() {}
    func didSelect(_ item: Item, query: String) {}
}

extension Notification.Name {
    static let pageChanged = Notification.Name("HopPageChanged")
}

/// Opens a page from a hop://<name>?... link, so other apps can send Hop straight to it.
protocol LinkOpener: AnyObject {
    var linkName: String { get }
    func page(for link: URLComponents) -> Page?
}

protocol Plugin {
    func register(in hop: PluginRegistry)
}

protocol PluginRegistry: AnyObject {
    func add(search: SearchProvider)
    func add(page: Page)
    func add(command: Command)
    func add(link: LinkOpener)
}

final class PluginManager: PluginRegistry {
    private(set) var searches: [SearchProvider] = []
    private(set) var pages: [Page] = []
    private(set) var commands: [Command] = []
    private var links: [LinkOpener] = []

    init(_ plugins: [Plugin]) {
        plugins.forEach { $0.register(in: self) }
    }

    func add(search: SearchProvider) { searches.append(search) }
    func add(page: Page) { pages.append(page) }
    func add(command: Command) { commands.append(command) }
    func add(link: LinkOpener) { links.append(link) }

    func page(for url: URL) -> Page? {
        guard url.scheme == "hop", let link = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return links.first { $0.linkName == link.host }?.page(for: link)
    }
}
