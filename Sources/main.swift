import AppKit
import Carbon
import ServiceManagement

let app = NSApplication.shared
let plugins = PluginManager([HopPlugin(), CalculatorPlugin(), AppsPlugin(), ClipboardPlugin()])
let mainSearch = MainSearch(plugins: plugins)
let launcher = Launcher(pages: [mainSearch] + plugins.pages)

HotKeys.listen()
HotKeys.add(HotKey(key: kVK_Space, modifiers: optionKey)) { launcher.toggle(mainSearch) }
for page in plugins.pages {
    if let hotkey = page.hotkey { HotKeys.add(hotkey) { launcher.toggle(page) } }
}

try? SMAppService.mainApp.register()
app.run()
