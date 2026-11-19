# Hop

A launcher for macOS that searches apps and clipboard history. It uses native AppKit, has no dependencies, and the binary is about 180KB.

- `⌥ Space` searches apps. Matching is fuzzy, with prefixes, word starts and initials (`vsc`, `ws`), and apps you launch often rank higher.
- `⌥ V` opens clipboard history: text and images, the last 300 entries, with a preview of the selected entry on the right. Items that password managers mark as concealed are not saved.
- The app search also answers math (`2^10`, `(3+4)*2`), percentages (`150 + 10%`, `20% of 150`, `20% off 150`) and currency (`100 usd to inr`, `$50 in eur`). Enter copies the answer and saves it, and your last 7 calculations show under the answer, with a large preview on the right. Exchange rates come from open.er-api.com, refresh every 6 hours, and are saved for offline use.
- Each plugin, and Quit Hop, appears as a command in the app search. Type `clip` and press Enter to open Clipboard History in the same panel. Esc, or Backspace in an empty search field, goes back to the app search.
- `Tab` switches between the two lists, `↑↓` move the selection, `Enter` opens the app or pastes the entry, `Esc` closes the panel. Type `quit hop` to quit.

Build and install with `./build.sh install`, which runs the fuzzy-match check, builds, and copies the app to `~/Applications`.

To add a plugin, write a class that conforms to `Source` (in `Sources/Launcher.swift`), add it to the list in `Sources/main.swift`, and give it a hotkey.

Pasting straight into the frontmost app needs Accessibility permission. Without it, Enter only copies the entry. The build is signed ad hoc, so each rebuild resets that permission and you have to toggle Hop off and on again in System Settings.
