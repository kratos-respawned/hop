import AppKit

struct Item {
    let title: String
    var subtitle = ""
    var badge = ""
    var action = ""
    var preview: Preview?
    var section: String?
    var opens: Page?
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
    func didSelect(_ item: Item, query: String)
}

extension Page {
    var hasPreview: Bool { false }
    var hotkey: HotKey? { nil }
    func didSelect(_ item: Item, query: String) {}
}

extension Notification.Name {
    static let pageChanged = Notification.Name("HopPageChanged")
}

protocol Plugin {
    func register(in hop: PluginRegistry)
}

protocol PluginRegistry: AnyObject {
    func add(search: SearchProvider)
    func add(page: Page)
    func add(command: Command)
}

final class PluginManager: PluginRegistry {
    private(set) var searches: [SearchProvider] = []
    private(set) var pages: [Page] = []
    private(set) var commands: [Command] = []

    init(_ plugins: [Plugin]) {
        plugins.forEach { $0.register(in: self) }
    }

    func add(search: SearchProvider) { searches.append(search) }
    func add(page: Page) { pages.append(page) }
    func add(command: Command) { commands.append(command) }
}
