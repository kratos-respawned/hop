import AppKit
import Carbon
import ServiceManagement

let app = NSApplication.shared
// The first file size shown loads ICU data for ~12 ms; pay it off the main thread.
DispatchQueue.global(qos: .utility).async { _ = ByteCountFormatter.string(fromByteCount: 1, countStyle: .file) }
let writing = WritingPlugin(), setup = SetupPlugin()
let plugins = PluginManager([HopPlugin(), SettingsPlugin(), setup, writing, DecodePlugin(), DictionaryPlugin(), DownloadsPlugin(), CalculatorPlugin(), AppsPlugin(), ClipboardPlugin(), ClaudePlugin(), WorktreePlugin(), MetalPlugin(), PortPlugin(), ShelfPlugin(), SharePlugin(), WallpapersPlugin(), DigestPlugin()])
let mainSearch = MainSearch(plugins: plugins)
let launcher = Launcher(pages: [mainSearch] + plugins.pages)

HotKeys.listen()
HotKeys.add(writing.hotkey) { writing.open() }
OpenShortcut.id = HotKeys.add(OpenShortcut.current) { launcher.toggle(SetupPlugin.isDone ? mainSearch : setup) }
for page in plugins.pages {
    if let hotkey = page.hotkey { HotKeys.add(hotkey) { launcher.toggle(page) } }
}

app.servicesProvider = writing
NSUpdateDynamicServices()
if !SetupPlugin.isDone { DispatchQueue.main.async { launcher.toggle(setup) } }

try? SMAppService.mainApp.register()
app.run()
