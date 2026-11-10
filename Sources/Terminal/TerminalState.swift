import Observation

/// A terminal's screen, scrollback, cursor, modes and window title. An
/// `Emulator` writes a program's output into it, and a `StreamTerminal` draws
/// it.
///
/// It's observable: a SwiftUI view that reads a property, such as `title`, is
/// updated when it changes.
@MainActor
public final class TerminalState: Observable {
	/// The default number of lines kept in the scrollback.
	public static let defaultScrollbackLimit = 1000

	private let registrar = ObservationRegistrar()
	private var screen: Screen

	public init(
		columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = TerminalState.defaultScrollbackLimit
	) {
		screen = Screen(columns: columns, rows: rows, scrollbackLimit: scrollbackLimit)
	}

	private func read<Value>(_ keyPath: KeyPath<TerminalState, Value>, _ value: Value) -> Value {
		registrar.access(self, keyPath: keyPath)
		return value
	}

	public var columns: Int { read(\.columns, screen.columns) }
	public var rows: Int { read(\.rows, screen.rows) }

	/// The screen shown: the primary one, or the alternate one if `alternate`.
	public var buffer: [Line] { read(\.buffer, screen.buffer) }

	/// Lines scrolled off the top of the primary screen, oldest first, keeping
	/// at most `scrollbackLimit` of them. The alternate screen has none.
	public var scrollback: [Line] { read(\.scrollback, screen.scrollback) }
	public var scrollbackLimit: Int { screen.scrollbackLimit }

	/// Whether the alternate screen is shown. Full-screen applications draw
	/// there, so the shell's screen comes back when they exit.
	public var alternate: Bool { read(\.alternate, screen.alternate) }

	/// The window title, set by OSC 0 and OSC 2.
	public var title: String { read(\.title, screen.title) }

	/// The cursor's column. With a wrap pending, it's `columns`, one past the
	/// last: see `cursorColumn`.
	public var column: Int { read(\.column, screen.column) }
	public var row: Int { read(\.row, screen.row) }

	/// The column the cursor is drawn in.
	public var cursorColumn: Int { min(column, columns - 1) }

	/// The cursor's shape, and whether it blinks.
	public var cursorStyle: CursorStyle { read(\.cursorStyle, screen.style) }
	public var cursorBlink: Bool { read(\.cursorBlink, screen.cursorBlink) }
	/// Whether the cursor is drawn (DECTCEM).
	public var cursorVisible: Bool { read(\.cursorVisible, screen.cursorVisible) }

	/// Whether printing in the last column wraps to the next line (DECAWM).
	public var autowrap: Bool { read(\.autowrap, screen.autowrap) }
	/// Whether the arrow keys send SS3 sequences instead of CSI ones (DECCKM).
	public var applicationCursor: Bool { read(\.applicationCursor, screen.applicationCursor) }
	/// Whether the keypad sends application sequences (DECKPAM).
	public var applicationKeypad: Bool { read(\.applicationKeypad, screen.applicationKeypad) }
	/// Whether pasted text is wrapped in markers, so the application can tell
	/// it from typing.
	public var bracketedPaste: Bool { read(\.bracketedPaste, screen.bracketedPaste) }

	/// Resize the screen. The primary screen and its scrollback are reflowed:
	/// lines that wrapped are joined and wrapped again at the new width. A
	/// `StreamTerminal` does this itself, to fit its container.
	public func resize(columns: Int, rows: Int) {
		mutate { $0.resize(columns, rows) }
	}

	/// Change the screen, and tell the observers of whatever changed. The
	/// screen and the scrollback are too big to compare, so they're always
	/// taken to have changed.
	func mutate<Result>(_ body: (inout Screen) -> Result) -> Result {
		let before = Summary(screen)

		registrar.willSet(self, keyPath: \.buffer)
		registrar.willSet(self, keyPath: \.scrollback)
		let result = body(&screen)
		registrar.didSet(self, keyPath: \.scrollback)
		registrar.didSet(self, keyPath: \.buffer)

		// Observers only have to hear before they next read, so the rest can be
		// told now that it's known what changed.
		let after = Summary(screen)
		func changed<Value: Equatable>(
			_ keyPath: KeyPath<TerminalState, Value>, _ value: KeyPath<Summary, Value>
		) {
			guard before[keyPath: value] != after[keyPath: value] else { return }
			registrar.willSet(self, keyPath: keyPath)
			registrar.didSet(self, keyPath: keyPath)
		}
		changed(\.columns, \.columns)
		changed(\.rows, \.rows)
		changed(\.alternate, \.alternate)
		changed(\.title, \.title)
		changed(\.column, \.column)
		changed(\.row, \.row)
		changed(\.cursorStyle, \.style)
		changed(\.cursorBlink, \.cursorBlink)
		changed(\.cursorVisible, \.cursorVisible)
		changed(\.autowrap, \.autowrap)
		changed(\.applicationCursor, \.applicationCursor)
		changed(\.applicationKeypad, \.applicationKeypad)
		changed(\.bracketedPaste, \.bracketedPaste)

		return result
	}

	/// The small parts of the screen, which are cheap to compare.
	private struct Summary {
		let columns: Int
		let rows: Int
		let alternate: Bool
		let title: String
		let column: Int
		let row: Int
		let style: CursorStyle
		let cursorBlink: Bool
		let cursorVisible: Bool
		let autowrap: Bool
		let applicationCursor: Bool
		let applicationKeypad: Bool
		let bracketedPaste: Bool

		init(_ screen: Screen) {
			columns = screen.columns
			rows = screen.rows
			alternate = screen.alternate
			title = screen.title
			column = screen.column
			row = screen.row
			style = screen.style
			cursorBlink = screen.cursorBlink
			cursorVisible = screen.cursorVisible
			autowrap = screen.autowrap
			applicationCursor = screen.applicationCursor
			applicationKeypad = screen.applicationKeypad
			bracketedPaste = screen.bracketedPaste
		}
	}
}
