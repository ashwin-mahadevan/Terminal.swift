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

After every change, before committing:

1. Run `swift test`.
2. Build for iOS, which compiles the UIKit code that `swift test` doesn't:
   `xcodebuild -scheme Terminal.swift -destination 'generic/platform=iOS Simulator' build`.

Indent with tabs. Commit frequently as you work.

## Releases

Merging a PR into `master` is the only way to release. Never run
`gh release create` or push a tag by hand. A merge that doesn't bump the
version releases nothing.

To release, bump the version in `VERSION` in your PR. On every push to
`master`, `.github/workflows/release.yml` checks whether a `v<version>` tag
exists yet. If it doesn't, it runs `checks.yml` and, only if everything passes,
creates the `v<version>` GitHub release and tag, which is what Swift Package
Manager resolves. PRs run `checks.yml` too.
