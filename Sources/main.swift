import AppKit
import Carbon
import ServiceManagement

let app = NSApplication.shared
// The first file size shown loads ICU data for ~12 ms; pay it off the main thread.
DispatchQueue.global(qos: .utility).async { _ = ByteCountFormatter.string(fromByteCount: 1, countStyle: .file) }
let plugins = PluginManager([HopPlugin(), DecodePlugin(), CalculatorPlugin(), AppsPlugin(), ClipboardPlugin(), ClaudePlugin(), WorktreePlugin(), MetalPlugin(), PortPlugin(), ShelfPlugin()])
let mainSearch = MainSearch(plugins: plugins)
let launcher = Launcher(pages: [mainSearch] + plugins.pages)

HotKeys.listen()
HotKeys.add(HotKey(key: kVK_Space, modifiers: optionKey)) { launcher.toggle(mainSearch) }
for page in plugins.pages {
    if let hotkey = page.hotkey { HotKeys.add(hotkey) { launcher.toggle(page) } }
}

try? SMAppService.mainApp.register()
app.run()
