# Terminal.swift

A streaming terminal emulator for SwiftUI. Write a PTY's output into an
`Emulator`, which keeps an observable screen in a `TerminalState`, and draw it
with the `StreamTerminal` view.

It's a port of [terminal.svelte](https://github.com/ashwin-mahadevan/terminal.svelte),
and behaves the same: the two are checked against each other.

```swift
.package(url: "https://github.com/ashwin-mahadevan/Terminal.swift", from: "0.1.0")
```

It needs iOS 18, macOS 15 or visionOS 2.

## Usage

```swift
import SwiftUI
import Terminal

struct TerminalView: View {
	@State private var state = TerminalState()
	@State private var emulator: Emulator?

	// Connect these to your PTY, for example over a WebSocket.
	let output: AsyncStream<Data>
	let send: (Data) -> Void
	let resize: (_ columns: Int, _ rows: Int) -> Void

	var body: some View {
		StreamTerminal(state: state) { data in send(Data(data.utf8)) }
			.font(.system(size: 13))
			.navigationTitle(state.title.isEmpty ? "Terminal" : state.title)
			// The terminal fits itself to its container; pass the new size on.
			.onChange(of: [state.columns, state.rows], initial: true) {
				resize(state.columns, state.rows)
			}
			.task {
				let emulator = Emulator(
					state: state,
					onBell: { print("BEL") },
					// Replies to the program's queries, such as device attributes.
					onData: { send($0) })
				self.emulator = emulator

				// Feed it the PTY's output as bytes.
				for await chunk in output { emulator.write(chunk) }
			}
	}
}
```

- `TerminalState(columns:rows:scrollbackLimit:)` holds the screen, the
  scrollback, the cursor, the modes and the window title, all observable.
  `StreamTerminal` resizes it to fit, and `state.resize(columns:rows:)` does so
  by hand.
- `Emulator.write(_:)` parses a chunk of output, as `Data`, bytes or a string.
  Chunks may split anywhere, even inside an escape sequence or a UTF-8
  character.
- `StreamTerminal` fills its container, which must have a size, and is drawn in
  the environment's font, in its monospaced design. Its `onData` sends the
  user's keystrokes and pastes as strings; without it, the terminal takes no
  input. `optionSendsEscape` makes Option send ESC as Meta; it's off by default.
- `.terminalPalette(_:)` replaces the default colors, which are xterm's.

`TerminalState` and `Emulator` belong to the main actor.

## Input

On a Mac, and with a hardware keyboard on iOS, keys are encoded as xterm does.
On iOS, a tap brings up the on-screen keyboard. Text composed by an input
method, such as Japanese or Chinese, isn't supported yet.

## Conformance

`Tests/TerminalTests/Fixtures/conformance.json` records what terminal.svelte's
emulator makes of several hundred pieces of output, and the tests expect the
same of this one. See [Conformance](Conformance/README.md).
