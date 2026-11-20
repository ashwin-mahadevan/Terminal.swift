# Terminal.swift

An open-source (MIT) streaming terminal emulator for SwiftUI, maintained by
Ashwin Mahadevan. It's a Swift package with one library, `Terminal`, and is a
port of terminal.svelte, which it must behave exactly like.

**This repo is public.** Everything committed here, including commit messages,
issues and PRs, is visible to anyone. Never bring in code or details from the
private XTerm.app repo, even though it uses this library.

## Layout

| Path                                   | What it is                                                              |
| -------------------------------------- | ----------------------------------------------------------------------- |
| `Sources/Terminal/Screen.swift`        | The emulator's state and every operation on it, as a value type         |
| `Sources/Terminal/Parser.swift`        | The streaming parser that turns output into operations on a `Screen`    |
| `Sources/Terminal/TerminalState.swift` | The public, observable wrapper around a `Screen`                        |
| `Sources/Terminal/StreamTerminal.swift`| The SwiftUI view. `TerminalInput.swift` reads the keyboard per platform |
| `Conformance/`                         | Generates the fixtures that pin the behavior to terminal.svelte's       |

## Staying identical to terminal.svelte

The emulator (`Screen`, `Parser`, `Grapheme`, `Width`, `Charsets`, `Keyboard`)
mirrors terminal.svelte's `src/lib` file by file, comments included. When
terminal.svelte changes, port the change and regenerate the fixtures as
`Conformance/README.md` describes. Don't change the emulator's behavior here
first: change terminal.svelte, then port it.

## Code quality

Run `./checks.sh` before a change is merged. It runs every check: `swift test`,
then a build for iOS, which compiles the UIKit code that `swift test` doesn't.
No GitHub workflow checks a change.

Indent with tabs. Commit frequently as you work.

## Releases

Merging into `master` is the only way to release. To release, a change bumps
the version in `VERSION`. Nothing runs `./release.sh` by itself: whoever merges
runs it from the merged commit, right after the merge. It creates the
`v<version>` GitHub release and tag, which is what Swift Package Manager
resolves. A merge that doesn't bump the version releases nothing.

Nobody else runs `./release.sh`, and nobody runs `gh release create` or pushes
a tag by hand.
