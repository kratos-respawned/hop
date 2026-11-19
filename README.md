# Hop

A launcher for macOS that searches apps and clipboard history. It uses native AppKit, has no dependencies, and the binary is about 180KB.

- `⌥ Space` searches apps. Matching is fuzzy, with prefixes, word starts and initials (`vsc`, `ws`), and apps you launch often rank higher.
- `⌥ V` opens clipboard history: text and images, the last 300 entries, with a preview of the selected entry on the right. Items that password managers mark as concealed are not saved.
- The app search also answers math (`2^10`, `(3+4)*2`), percentages (`150 + 10%`, `20% of 150`, `20% off 150`) and currency (`100 usd to inr`, `$50 in eur`). Enter copies the answer and saves it, and your last 7 calculations show under the answer, with a large preview on the right. Exchange rates come from open.er-api.com, refresh every 6 hours, and are saved for offline use.
- Claude Manager (type `claude`) lists every running Claude Code session with its folder, whether it's working or idle, and how many subagents are working. Enter caffeinates a session, which keeps the Mac awake even with the lid closed. When that session finishes and waits for its next prompt, or exits, Hop decafs it. If the lid is closed by then, the Mac goes to sleep. The first caffeinate asks for your password once, to add `/etc/sudoers.d/hop`. That rule lets your user run only `pmset -a disablesleep 1`, `pmset -a disablesleep 0` and `pmset sleepnow` without a password, because only root can stop lid-close sleep. A caffeinated session shows `☕ caffeinated` in its Claude status line, through `scripts/claude-status.sh`.
- Worktree Manager (type `worktree`) lists every repo in `~/Desktop/work` with its worktrees, their size, and how much of that is build artifacts. Each worktree has a merge badge, checked with git after a fetch: In main or In uat means `git merge-tree origin/<base> HEAD` leaves that branch unchanged, so everything in the worktree is already there, squash merges included. Not merged and Uncommitted mean deleting it loses something. Enter opens its actions: clear `node_modules`, `.next`, `dist`, `build` and similar folders (only ones git ignores), or delete the worktree. Delete keeps the branch and runs `git worktree prune`. Both rename the folder away at once and remove it in the background. Sizes are saved and recounted every 10 minutes. A Recommended section on top lists what is safe to clean, biggest first. "Last used" is the later of when HEAD last moved (commit, checkout, pull) and when an uncommitted file was last edited. The rules: delete a worktree that is in main or uat and unused for 3 days; delete one whose commits are all on a remote and that has been clean and unused for 14 days; otherwise clear its artifacts if it has been unused for 7 days and they take over 200 MB. A worktree with uncommitted or unpushed work is never recommended for delete. Recommended deletes rank above artifact clears, and "Delete all pushed worktrees" opens a review page that lists every worktree it will remove, with one Enter to delete them all.
- Metal Manager (type `metal`) shows what is using CPU and memory, grouped by app, so Chrome's 20 helpers count as one Google Chrome row. A CPU section lists apps above 1% CPU, the heat makers, and a Memory section lists every app by memory, the same footprint number as Activity Monitor's Memory column. Each row shows memory and its share of RAM, CPU, and power in watts, from the kernel's per-process energy counter. It reads the kernel directly through libproc, about 3 ms for every process. It samples every 2 seconds while open and every 10 seconds in the background, so the numbers are current the moment it opens, and Hop stays under 0.2% CPU. When something is heavy, a Worth quitting section shows first: apps above 40% CPU, apps holding a fifth of your RAM, and, once memory is 85% full, every app above 1 GB. On a calm Mac the section isn't there. Rows keep their place while you look, so the selection doesn't jump. Enter opens an app's actions: Quit (like ⌘Q), Force Quit all its processes, or force quit one process. Each process shows the folder it is running in, so you can tell which `node` belongs to which project. Root processes such as WindowServer and kernel_task are not shown, because a normal user can't read or kill them.
- Each plugin, and Quit Hop, appears as a command in the app search. Type `clip` and press Enter to open Clipboard History in the same panel. Esc, or Backspace in an empty search field, goes back to the app search.
- `Tab` switches between the two lists, `↑↓` move the selection, `Enter` opens the app or pastes the entry, `Esc` closes the panel. Type `quit hop` to quit.

Build and install with `./build.sh install`, which runs the fuzzy-match check, builds, and copies the app to `~/Applications`.

## Plugins

Every feature is a plugin in `Sources/Plugins/`. The contract lives in `Sources/Plugin.swift`. A plugin conforms to `Plugin`, and in `register(in:)` it tells the registry what it adds:

- `add(search:)` adds results to the main search. Apps and the calculator do this.
- `add(page:)` adds a page with its own list, an optional hotkey and an optional preview. Clipboard History does this. Every page also shows up as a command in the main search.
- `add(command:)` adds a named action to the main search, like Quit Hop.

```swift
final class EmojiPlugin: Plugin, SearchProvider {
    func register(in hop: PluginRegistry) { hop.add(search: self) }
    func search(_ query: String) -> [Item] { ... }
}
```

A page whose results change in the background posts `NotificationCenter.default.post(name: .pageChanged, object: self)`, and Hop refreshes it if it's on screen. An item can open a page that isn't registered, like a details page, and Esc goes back.

To turn it on, add it to the `PluginManager([...])` list in `Sources/main.swift`. That list's order is also the order of results in the main search. No other file changes.

Pasting straight into the frontmost app needs Accessibility permission. Without it, Enter only copies the entry. `build.sh` signs Hop with the first Apple Development identity in your keychain, so macOS keeps Accessibility and Desktop folder permissions across rebuilds. Without one it falls back to ad hoc signing, and each rebuild resets those permissions.
