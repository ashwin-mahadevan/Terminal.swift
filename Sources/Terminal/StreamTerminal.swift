#if canImport(SwiftUI)
	import SwiftUI

	/// Draws a `TerminalState`, and sends what the user types.
	///
	/// It fills its container, which must have a size: the grid is fitted to
	/// it, not the other way around, and the state is resized to match. It's
	/// drawn in the environment's font, in its monospaced design.
	///
	///     StreamTerminal(state: state) { data in send(data) }
	///         .font(.system(size: 13))
	public struct StreamTerminal: View {
		private let state: TerminalState
		private let onData: ((String) -> Void)?
		private let optionSendsEscape: Bool

		@Environment(\.font) private var environmentFont
		@Environment(\.terminalPalette) private var palette

		// The container's size, and a cell's, measured from a hidden run of
		// glyphs in the terminal's font.
		@State private var container = CGSize.zero
		@State private var cell = CGSize.zero

		// Scrollback: the terminal scrolls to show it, and follows the output as
		// long as it's scrolled to the bottom. Scrolling up stops that, until
		// it's scrolled back down or a key is pressed.
		@State private var position = ScrollPosition(edge: .bottom)
		@State private var scroll = ScrollTracker()

		@State private var blinkOn = true
		@State private var input = InputProxy()

		/// - Parameters:
		///   - state: The terminal to draw.
		///   - optionSendsEscape: Whether Option sends ESC before the key, as
		///     Meta. By default it doesn't: Option types its characters.
		///   - onData: Called with the user's keystrokes and pastes, to send to
		///     the PTY. Without it, the terminal takes no input.
		public init(
			state: TerminalState, optionSendsEscape: Bool = false, onData: ((String) -> Void)? = nil
		) {
			self.state = state
			self.optionSendsEscape = optionSendsEscape
			self.onData = onData
		}

		private var font: Font { (environmentFont ?? .body).monospaced() }

		// The scrollback, shown above the primary screen. The alternate screen is
		// shown alone.
		private var history: [Line] { state.alternate ? [] : state.scrollback }

		// A blinking cursor is drawn for half of every interval. Moving it starts
		// it over, drawn, so it can be seen while it moves.
		private static let blinkInterval = Duration.milliseconds(1200)

		private struct Blink: Equatable {
			var row: Int
			var column: Int
			var enabled: Bool
		}

		private struct Grid: Equatable {
			var container: CGSize
			var cell: CGSize
		}

		private struct Height: Equatable {
			var history: Int
			var rows: Int
		}

		public var body: some View {
			let history = history
			let lines = state.buffer
			let columns = state.columns

			// A pending wrap parks the cursor one column past the edge; draw it on
			// the last column instead. On the right half of a wide character, it's
			// drawn on the character, since that half draws nothing.
			let cursorColumn = state.cursorColumn
			let onRightHalf =
				state.row < lines.count && cursorColumn < lines[state.row].cells.count
				&& lines[state.row].cells[cursorColumn]?.width == 0
			let cursor = Cursor(column: onRightHalf ? cursorColumn - 1 : cursorColumn, style: state.cursorStyle)
			let cursorShown = state.cursorVisible && blinkOn

			ScrollView(.vertical) {
				LazyVStack(alignment: .leading, spacing: 0) {
					ForEach(0..<history.count + lines.count, id: \.self) { index in
						let row = index - history.count
						Row(
							line: row < 0 ? history[index] : lines[row],
							columns: columns,
							cursor: cursorShown && row == state.row ? cursor : nil,
							cell: cell,
							font: font,
							palette: palette
						)
						.equatable()
						.frame(width: CGFloat(columns) * cell.width, height: cell.height)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.scrollPosition($position)
			.defaultScrollAnchor(.bottom, for: .initialOffset)
			.onScrollPhaseChange { _, phase in scroll.byUser = phase != .idle }
			.onScrollGeometryChange(for: ScrollTracker.Geometry.self) { geometry in
				ScrollTracker.Geometry(
					offset: geometry.contentOffset.y + geometry.contentInsets.top,
					visible: geometry.containerSize.height - geometry.contentInsets.top
						- geometry.contentInsets.bottom,
					content: geometry.contentSize.height)
			} action: { _, geometry in
				scroll.geometry = geometry
				// Only the user's scrolling stops the terminal following the output:
				// output that makes the content taller mustn't.
				if scroll.byUser { scroll.following = geometry.atBottom }
			}
			.background(palette.background)
			.onGeometryChange(for: CGSize.self) { $0.size } action: { container = $0 }
			.background {
				// Cell measurement. The run is long so that a fractional cell width
				// isn't lost to rounding.
				Text(String(repeating: "W", count: Self.measured))
					.font(font)
					.lineLimit(1)
					.fixedSize()
					.hidden()
					.onGeometryChange(for: CGSize.self) { $0.size } action: { size in
						cell = CGSize(width: size.width / CGFloat(Self.measured), height: size.height)
					}
			}
			// Fit the grid to the container. A zero-size container leaves it alone.
			.onChange(of: Grid(container: container, cell: cell), initial: true) { _, grid in
				guard grid.container.width > 0, grid.container.height > 0, grid.cell.width > 0,
					grid.cell.height > 0
				else { return }
				state.resize(
					columns: Int(grid.container.width / grid.cell.width),
					rows: Int(grid.container.height / grid.cell.height))
			}
			// The content only grows taller with the scrollback, or changes height
			// with the screen. A full scrollback stays the same height while it
			// scrolls.
			.onChange(of: Height(history: history.count, rows: lines.count)) {
				if scroll.following { position.scrollTo(edge: .bottom) }
			}
			.task(id: Blink(row: state.row, column: state.column, enabled: state.cursorBlink)) {
				blinkOn = true
				guard state.cursorBlink else { return }
				while (try? await Task.sleep(for: Self.blinkInterval / 2)) != nil {
					blinkOn.toggle()
				}
			}
			.modifier(
				TerminalInput(
					proxy: input, enabled: onData != nil, handle: handle(_:))
			)
			.accessibilityLabel("Terminal")
		}

		private static let measured = 64

		private func scrollToBottom() {
			scroll.following = true
			position.scrollTo(edge: .bottom)
		}

		private func send(_ data: String) {
			// Anything typed goes to the bottom, where it's echoed.
			scrollToBottom()
			onData?(data)
		}

		/// Handle something the user did. Returns false to leave it to the system.
		private func handle(_ event: InputEvent) -> Bool {
			switch event {
			case .key(let key):
				// Shift+PageUp and Shift+PageDown scroll through the scrollback, when
				// there is one to show.
				if key.key == .pageUp || key.key == .pageDown, key.shift, !key.control, !key.option,
					!key.command, !state.alternate
				{
					let page = scroll.geometry.visible - cell.height
					let target = scroll.geometry.offset + (key.key == .pageUp ? -page : page)
					let limit = max(0, scroll.geometry.content - scroll.geometry.visible)
					let offset = min(max(0, target), limit)
					scroll.following = offset >= limit - 1
					position.scrollTo(y: offset)
					return true
				}

				let modes = KeyboardModes(
					applicationCursor: state.applicationCursor,
					applicationKeypad: state.applicationKeypad,
					optionSendsEscape: optionSendsEscape)
				guard let data = encodeKey(key, modes: modes) else { return false }
				send(data)

			case .text(let text):
				send(text)

			case .paste(let text):
				guard !text.isEmpty else { return false }
				onData?(encodePaste(text, bracketed: state.bracketedPaste))
			}
			return true
		}
	}

	/// Where the terminal is scrolled to. It's not observed: nothing is redrawn
	/// when it changes.
	@MainActor
	private final class ScrollTracker {
		struct Geometry: Equatable {
			var offset: CGFloat = 0
			var visible: CGFloat = 0
			var content: CGFloat = 0

			var atBottom: Bool { offset + visible >= content - 1 }
		}

		var geometry = Geometry()
		var following = true
		var byUser = false
	}

	/// The cursor, as it's drawn on its row.
	private struct Cursor: Equatable {
		var column: Int
		var style: CursorStyle
	}

	/// One line of the screen or the scrollback.
	private struct Row: View, Equatable {
		let line: Line
		let columns: Int
		let cursor: Cursor?
		let cell: CGSize
		let font: Font
		let palette: TerminalPalette

		var body: some View {
			Canvas(rendersAsynchronously: false) { context, _ in
				var column = 0
				while column < line.cells.count {
					column = draw(&context, from: column)
				}
				// The cursor may sit past the end of a line cut short.
				if let cursor, cursor.column >= line.cells.count {
					drawCell(&context, nil, at: cursor.column, cursor: cursor.style)
				}
			}
		}

		/// Whether a cell can be drawn as part of a run of text: one ASCII
		/// character, which the font is sure to have at exactly a cell's width.
		private func plain(_ cell: Cell?) -> Bool {
			guard let cell else { return true }
			return cell.width == 1 && cell.text.utf8.count == 1
		}

		/// Draw the cell at `column`, and the ones after it that look the same,
		/// as one piece of text. Returns the column to go on from.
		private func draw(_ context: inout GraphicsContext, from column: Int) -> Int {
			let first = line.cells[column]
			guard plain(first), cursor?.column != column else {
				drawCell(&context, first, at: column, cursor: cursor?.column == column ? cursor?.style : nil)
				return column + 1
			}

			var end = column + 1
			var text = first?.text ?? " "
			while end < line.cells.count, end != cursor?.column, plain(line.cells[end]),
				line.cells[end]?.attributes == first?.attributes
			{
				text += line.cells[end]?.text ?? " "
				end += 1
			}
			drawText(
				&context, text, first?.attributes ?? .default, at: column, width: end - column,
				cursor: nil)
			return end
		}

		private func drawCell(
			_ context: inout GraphicsContext, _ cell: Cell?, at column: Int, cursor: CursorStyle?
		) {
			// The right half of a wide character draws nothing: the character
			// covers it.
			if cell?.width == 0 { return }
			drawText(
				&context, cell?.text ?? " ", cell?.attributes ?? .default, at: column,
				width: cell?.width == 2 ? 2 : 1, cursor: cursor)
		}

		private func drawText(
			_ context: inout GraphicsContext, _ string: String, _ attributes: Attributes,
			at column: Int, width: Int, cursor: CursorStyle?
		) {
			if attributes.invisible { return }

			// Inverse swaps the colors. A block cursor inverts the cell.
			var foreground = attributes.foreground.map(palette.color) ?? palette.foreground
			var background = attributes.background.map(palette.color)
			if attributes.inverse {
				(foreground, background) = (background ?? palette.background, foreground)
			}
			if cursor == .block {
				(foreground, background) = (palette.background, palette.foreground)
			}

			var context = context
			if attributes.dim { context.opacity = 0.5 }

			let frame = CGRect(
				x: CGFloat(column) * cell.width, y: 0, width: CGFloat(width) * cell.width,
				height: cell.height)
			if let background { context.fill(Path(frame), with: .color(background)) }

			if string.contains(where: { $0 != " " }) || attributes.underline || attributes.strikethrough {
				var text = Text(string).font(font).foregroundStyle(foreground)
				if attributes.bold { text = text.bold() }
				if attributes.italic { text = text.italic() }
				if attributes.underline { text = text.underline() }
				if attributes.strikethrough { text = text.strikethrough() }
				context.draw(text, at: frame.origin, anchor: .topLeading)
			}

			// An underline or a bar cursor is a 2pt line along the cell's bottom or
			// left edge.
			switch cursor {
			case .underline:
				let line = CGRect(x: frame.minX, y: frame.maxY - 2, width: frame.width, height: 2)
				context.fill(Path(line), with: .color(palette.foreground))
			case .bar:
				let line = CGRect(x: frame.minX, y: frame.minY, width: 2, height: frame.height)
				context.fill(Path(line), with: .color(palette.foreground))
			case .block, nil:
				break
			}
		}
	}
#endif
