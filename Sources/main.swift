import AppKit
import Carbon
import ServiceManagement

// launchd starts this same binary as the meeting point, under the job label.
if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Suite.service { MeetingPoint.run() }

let app = NSApplication.shared
// The first file size shown loads ICU data for ~12 ms; pay it off the main thread.
DispatchQueue.global(qos: .utility).async { _ = ByteCountFormatter.string(fromByteCount: 1, countStyle: .file) }
let writing = WritingPlugin(), setup = SetupPlugin(), downloads = DownloadsPlugin()
let plugins = PluginManager([HopPlugin(), SettingsPlugin(), setup, writing, DecodePlugin(), DictionaryPlugin(), downloads, CalculatorPlugin(), AppsPlugin(), ClipboardPlugin(), ClaudePlugin(), WorktreePlugin(), MetalPlugin(), PortPlugin(), ShelfPlugin(), SharePlugin(), WallpapersPlugin(), DigestPlugin()])
let mainSearch = MainSearch(plugins: plugins)
let launcher = Launcher(pages: [mainSearch] + plugins.pages)

HotKeys.listen()
HotKeys.add(writing.hotkey) { writing.open() }
OpenShortcut.id = HotKeys.add(OpenShortcut.current) { launcher.toggle(SetupPlugin.isDone ? mainSearch : setup) }
for page in plugins.pages {
    if let hotkey = page.hotkey { HotKeys.add(hotkey) { launcher.toggle(page) } }
}

final class Links: NSObject {
    @objc func open(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue.flatMap(URL.init(string:)),
              let page = plugins.page(for: url) else { return }
        launcher.present(page)
    }
}
let links = Links()
NSAppleEventManager.shared().setEventHandler(links, andSelector: #selector(Links.open(_:reply:)),
                                             forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

app.servicesProvider = writing
NSUpdateDynamicServices()
if !SetupPlugin.isDone { DispatchQueue.main.async { launcher.toggle(setup) } }

try? SMAppService.mainApp.register()
try? SMAppService.agent(plistName: Suite.service + ".plist").register()
Suite.listen(to: ["dev.masks.browser"]) { request in
    switch request {
    case .download(let address, let login):
        if let page = downloads.page(downloading: address.absoluteString, login: login) { launcher.present(page) }
    }
}
app.run()
