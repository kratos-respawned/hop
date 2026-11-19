import AppKit

struct HopPlugin: Plugin {
    func register(in hop: PluginRegistry) {
        hop.add(command: Command(name: "Quit Hop", icon: tile("power", .systemRed)) { NSApp.terminate(nil) })
    }
}
