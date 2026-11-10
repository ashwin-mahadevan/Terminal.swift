// Default interval between tab stops, in columns.
private let tabStopInterval = 8

// The number of titles XTWINOPS 22 can save.
private let titleStackLimit = 10

// The most characters one REP prints, so a huge count can't hang the app.
// It's the largest parameter xterm and Ghostty accept.
private let repeatLimit = 65535

/// A cursor-like position that a resize moves along with the text under it.
/// As elsewhere, `column == columns` means a wrap is pending.
struct Position: Equatable, Sendable {
	var row: Int
	var column: Int
}

struct SavedCursor: Equatable, Sendable {
	var column: Int
	var row: Int
	var attributes: Attributes
	var originMode: Bool
	var charsets: [Charset]
	var shift: Int

	var position: Position {
		get { Position(row: row, column: column) }
		set {
			row = newValue.row
			column = newValue.column
		}
	}
}

private func clamp(_ value: Int, _ minimum: Int, _ maximum: Int) -> Int {
	min(max(value, minimum), maximum)
}

extension Array {
	/// The element at `index`, or `nil` if it's out of range.
	fileprivate subscript(at index: Int) -> Element? {
		index >= 0 && index < count ? self[index] : nil
	}
}

extension [Cell?] {
	/// The width of the cell at `column`, or `nil` if it's empty or out of range.
	fileprivate func width(at column: Int) -> Int? {
		column >= 0 && column < count ? self[column]?.width : nil
	}

	fileprivate mutating func set(_ column: Int, _ cell: Cell?) {
		if column >= 0 && column < count { self[column] = cell }
	}

	/// Before a cell is written: blank the other half of the wide character
	/// it's part of, if any.
	fileprivate mutating func clearWide(_ column: Int) {
		switch width(at: column) {
		case 2: set(column + 1, nil)
		case 0 where column > 0: set(column - 1, nil)
		default: break
		}
	}

	/// After cells are moved, erased or cut off: replace either half of a wide
	/// character left without the other with `blank`.
	fileprivate mutating func repair(_ blank: Cell?) {
		for column in indices {
			guard let width = self[column]?.width else { continue }
			if width == 2 && self.width(at: column + 1) != 0 {
				self[column] = blank
			} else if width == 0 && self.width(at: column - 1) != 2 {
				self[column] = blank
			}
		}
	}

	/// Cut off or pad with empty cells to `columns`.
	fileprivate mutating func fit(_ columns: Int) {
		if count > columns {
			removeLast(count - columns)
		} else if count < columns {
			append(contentsOf: repeatElement(nil, count: columns - count))
		}
	}
}

/// The grapheme and width states at the end of a cluster's text, which the
/// next code point is folded into.
private func fold(_ text: String) -> (Grapheme.State, Width.State) {
	var grapheme = Grapheme.initial
	var width = Width.initial
	for scalar in text.unicodeScalars {
		grapheme = Grapheme.advance(grapheme, Grapheme.property(of: scalar))
		width = Width.width(width, scalar).state
	}
	return (grapheme, width)
}

/// Rewrap lines `width` columns wide to `columns`, joining the ones that
/// wrapped into one before splitting them again. Each position's row is an
/// index into `lines`, and is updated to an index into the result.
private func rewrap(
	_ lines: [Line], width: Int, columns: Int, positions: inout [Position]
) -> [Line] {
	var result: [Line] = []
	var moved = positions

	var start = 0
	while start < lines.count {
		var end = start
		while end < lines.count - 1 && lines[end].wrapped { end += 1 }

		// The text of the logical line, and where each of its lines starts in
		// it. Wrapped lines are full, but for one padded at the end because the
		// wide character after it didn't fit: the padding isn't text. The last
		// one ends at its last cell that was ever written.
		var cells: [Cell?] = []
		var starts: [Int] = []
		for index in start...end {
			starts.append(cells.count)
			let line = lines[index].cells
			var length = width
			if index == end {
				while length > 0 && (line[at: length - 1] ?? nil) == nil { length -= 1 }
			} else if (line[at: length - 1] ?? nil) == nil && lines[index + 1].cells.width(at: 0) == 2 {
				length -= 1
			}
			for column in 0..<length { cells.append(line[at: column] ?? nil) }
		}

		// Lay the text out `columns` wide. A wide character that would straddle
		// the edge moves to the next row, leaving padding.
		var rows: [[Cell?]] = [[]]
		var places: [Position] = []
		var row = 0
		var column = 0
		for cell in cells {
			if column == columns || (cell?.width == 2 && column == columns - 1 && columns > 1) {
				row += 1
				column = 0
				rows.append([])
			}
			places.append(Position(row: row, column: column))
			rows[row].append(cell)
			column += 1
		}

		// Where an offset into the text lands: on its cell, or past the end of
		// the text, counting on from the end.
		func place(_ offset: Int) -> Position {
			if offset < cells.count { return places[offset] }
			let total = row * columns + column + (offset - cells.count)
			return Position(row: total / columns, column: total % columns)
		}

		var height = rows.count
		for (index, position) in positions.enumerated() {
			guard position.row >= start && position.row <= end else { continue }

			// A pending wrap is just after the character in the last column: it
			// stays pending only if that character lands in the last column again.
			// The same goes for a cursor just after the text that now ends in the
			// last column, so it doesn't start a line of its own.
			let offset = starts[position.row - start] + min(position.column, width)
			let pending =
				position.column >= width || (offset > 0 && offset == cells.count && column == columns)
			let at = place(pending ? offset - 1 : offset)
			var landed = at.column
			if pending { landed = landed == columns - 1 ? columns : landed + 1 }

			height = max(height, at.row + 1)
			moved[index] = Position(row: result.count + at.row, column: landed)
		}

		for index in 0..<height {
			var line = rows[at: index] ?? []
			line.fit(columns)
			line.repair(nil)
			result.append(Line(cells: line, wrapped: index < height - 1))
		}
		start = end + 1
	}

	positions = moved
	return result
}

private func defaultTabStops(_ columns: Int) -> [Bool] {
	(0..<columns).map { $0 > 0 && $0 % tabStopInterval == 0 }
}

/// The emulator's state: the screens, the scrollback, the cursor and the
/// modes. It's a value, so `TerminalState` can change it as much as a chunk of
/// output needs and tell its observers once.
struct Screen: Sendable {
	private(set) var columns: Int
	private(set) var rows: Int

	/// The screen shown: the primary one, or the alternate one if `alternate`.
	private(set) var buffer: [Line] = []

	/// Lines scrolled off the top of the primary screen, oldest first, keeping
	/// at most `scrollbackLimit` of them. The alternate screen has none.
	private(set) var scrollback: [Line] = []
	let scrollbackLimit: Int

	/// ?47, ?1047 and ?1049: whether the alternate screen is shown. Full-screen
	/// applications draw there, so the shell's screen comes back when they exit.
	private(set) var alternate = false

	/// The screen that isn't shown, with its own saved cursor.
	private var hiddenBuffer: [Line] = []
	private var hiddenSavedCursor: SavedCursor?

	/// DECSTBM: the scroll region, as the first and last rows (inclusive) that
	/// linefeeds, IL, DL, SU and SD scroll.
	private(set) var scrollTop = 0
	private(set) var scrollBottom = 0

	/// DECOM (?6): whether cursor positions count from the top of the scroll
	/// region, and keep the cursor inside it.
	private(set) var originMode = false

	/// The window title, set by OSC 0 and OSC 2. It survives RIS, as in xterm.
	var title = ""

	/// Titles saved by XTWINOPS 22 and restored by 23, so an application like
	/// vim can put back the title it found. Like xterm, it holds up to 10.
	private var titleStack: [String] = []

	// Cursor
	var column = 0
	private(set) var row = 0
	/// DECSCUSR: the cursor's shape, and whether it blinks (also set by ?12).
	private(set) var style = CursorStyle.block
	private(set) var cursorBlink = false
	private(set) var attributes = Attributes.default

	/// Tab stops, shared across the whole terminal (not per-screen): indexed by
	/// column, true where a stop is set.
	private(set) var tabStops: [Bool] = []

	/// The cursor state saved by DECSC (ESC 7) and restored by DECRC (ESC 8),
	/// for the screen shown. Each screen has its own.
	private(set) var savedCursor: SavedCursor?

	/// The character sets designated into G0–G3 by SCS. SO and SI print with G1
	/// or G0 (`shift`), and SS2 and SS3 print just the next character with G2
	/// or G3 (`singleShift`).
	var charsets: [Charset] = [.ascii, .ascii, .ascii, .ascii]
	var shift = 0
	var singleShift: Int?

	/// The last grapheme cluster printed, and its width, which REP repeats.
	private var lastPrinted: (text: String, width: Int)?

	/// DECKPAM/DECKPNM: whether the keypad sends application sequences (SS3-
	/// prefixed) instead of the characters printed on the keys.
	var applicationKeypad = false

	// DECSET/DECRST modes.
	/// DECAWM (?7): whether printing in the last column wraps to the next line.
	var autowrap = true
	/// DECTCEM (?25): whether the cursor is drawn.
	private(set) var cursorVisible = true
	/// DECCKM (?1): whether the arrow keys send SS3 sequences instead of CSI ones.
	private(set) var applicationCursor = false
	/// ?2004: whether pasted text is wrapped in markers, so the application can
	/// tell it from typing.
	private(set) var bracketedPaste = false

	init(columns: Int, rows: Int, scrollbackLimit: Int) {
		self.columns = max(1, columns)
		self.rows = max(1, rows)
		self.scrollbackLimit = max(0, scrollbackLimit)
		reset()
	}

	mutating func pushTitle() {
		titleStack.append(title)
		if titleStack.count > titleStackLimit { titleStack.removeFirst() }
	}

	/// With nothing saved, the title stays as it is.
	mutating func popTitle() {
		if let title = titleStack.popLast() { self.title = title }
	}

	/// LF, IND: move down a row, scrolling the region at its bottom margin.
	/// Below the region, the cursor stops at the bottom of the screen instead.
	mutating func linefeed() {
		if column == columns { column -= 1 }
		if row == scrollBottom {
			scrollUp(1)
		} else if row < rows - 1 {
			row += 1
		}
	}

	/// RI: move up a row, scrolling the region down at its top margin.
	mutating func reverseLinefeed() {
		if column == columns { column -= 1 }
		if row == scrollTop {
			scrollDown(1)
		} else if row > 0 {
			row -= 1
		}
	}

	/// SU, and a linefeed at the bottom margin: scroll the region up, blanking
	/// lines at its bottom. Lines scrolled off the top of the primary screen
	/// go to the scrollback. The cursor does not move.
	mutating func scrollUp(_ count: Int) {
		let top = scrollTop
		let bottom = scrollBottom
		let count = min(count, bottom - top + 1)
		guard count > 0 else { return }
		let removed = Array(buffer[top..<top + count])
		buffer.removeSubrange(top..<top + count)
		buffer.insert(contentsOf: blankLines(count), at: bottom - count + 1)
		if top == 0 && !alternate { keep(removed) }
	}

	/// SD, and a reverse linefeed at the top margin: scroll the region down,
	/// blanking lines at its top. The cursor does not move.
	mutating func scrollDown(_ count: Int) {
		let top = scrollTop
		let bottom = scrollBottom
		let count = min(count, bottom - top + 1)
		guard count > 0 else { return }
		buffer.removeSubrange(bottom - count + 1...bottom)
		buffer.insert(contentsOf: blankLines(count), at: top)
	}

	/// Add lines to the scrollback, forgetting the oldest beyond the limit.
	private mutating func keep(_ lines: [Line]) {
		scrollback.append(contentsOf: lines)
		let excess = scrollback.count - scrollbackLimit
		if excess > 0 { scrollback.removeFirst(excess) }
	}

	/// DECSTBM: set the scroll region to rows top through bottom, zero-based
	/// and inclusive, and home the cursor. A region of less than two rows is
	/// ignored.
	mutating func setScrollRegion(_ top: Int, _ bottom: Int) {
		let bottom = min(bottom, rows - 1)
		if top < 0 || top >= bottom { return }
		scrollTop = top
		scrollBottom = bottom
		setCursorPosition(0, 0)
	}

	/// Show the alternate screen (or the primary one), keeping the other and
	/// its saved cursor for later. The cursor itself stays where it is.
	private mutating func useAlternate(_ enabled: Bool) {
		if enabled == alternate { return }
		swap(&buffer, &hiddenBuffer)
		swap(&savedCursor, &hiddenSavedCursor)
		alternate = enabled
	}

	/// RIS. The scrollback survives it, as in xterm.
	mutating func reset() {
		buffer = Array(repeating: .empty(columns), count: rows)
		hiddenBuffer = Array(repeating: .empty(columns), count: rows)
		hiddenSavedCursor = nil
		alternate = false
		scrollTop = 0
		scrollBottom = rows - 1
		originMode = false

		column = 0
		row = 0
		style = .block
		cursorBlink = false
		attributes = .default
		tabStops = defaultTabStops(columns)
		savedCursor = nil
		charsets = [.ascii, .ascii, .ascii, .ascii]
		shift = 0
		singleShift = nil
		lastPrinted = nil
		applicationKeypad = false
		autowrap = true
		cursorVisible = true
		applicationCursor = false
		bracketedPaste = false
	}

	/// DECSET (enabled) and DECRST (disabled) for one private mode. Returns
	/// false if the mode isn't supported.
	@discardableResult
	mutating func setPrivateMode(_ mode: Int, _ enabled: Bool) -> Bool {
		switch mode {
		case 1:
			applicationCursor = enabled
		case 6:
			originMode = enabled
			setCursorPosition(0, 0)
		case 7:
			autowrap = enabled
		case 12:
			cursorBlink = enabled
		case 25:
			cursorVisible = enabled
		case 47:
			useAlternate(enabled)
		// Like 47, but the alternate screen is cleared on leaving it.
		case 1047:
			if !enabled && alternate { buffer = blankLines(rows) }
			useAlternate(enabled)
		// DECSC and DECRC, as a mode.
		case 1048:
			if enabled { saveCursor() } else { restoreCursor() }
		// 1048 and 1047 together: save the cursor and switch to a cleared
		// alternate screen, then switch back and restore the cursor.
		case 1049:
			if enabled && !alternate {
				saveCursor()
				useAlternate(true)
				buffer = blankLines(rows)
			} else if !enabled && alternate {
				useAlternate(false)
				restoreCursor()
			}
		case 2004:
			bracketedPaste = enabled
		default:
			return false
		}
		return true
	}

	/// DECSCUSR: 0 restores the default, a steady block. Then 1 and 2 are a
	/// blinking and a steady block, 3 and 4 an underline, and 5 and 6 a bar.
	mutating func setCursorStyle(_ style: Int) {
		if style > 6 { return }
		self.style = style <= 2 ? .block : style <= 4 ? .underline : .bar
		cursorBlink = style % 2 == 1
	}

	/// DECSC: save the cursor position, attributes, origin mode, character
	/// sets, and (since a pending wrap is encoded as `column == columns`) the
	/// last-column flag.
	mutating func saveCursor() {
		savedCursor = SavedCursor(
			column: column, row: row, attributes: attributes, originMode: originMode,
			charsets: charsets, shift: shift)
	}

	/// DECRC: restore the saved cursor state, or home the cursor with default
	/// attributes if nothing has been saved.
	mutating func restoreCursor() {
		if let savedCursor {
			column = savedCursor.column
			row = savedCursor.row
			attributes = savedCursor.attributes
			originMode = savedCursor.originMode
			charsets = savedCursor.charsets
			shift = savedCursor.shift
		} else {
			column = 0
			row = 0
			attributes = .default
			originMode = false
			charsets = [.ascii, .ascii, .ascii, .ascii]
			shift = 0
		}
	}

	/// SGR: apply each parameter in turn to the current attributes. Each comes
	/// with any sub-parameters that followed it after colons, like the 3 of
	/// 4:3. An empty parameter, like an empty list, means 0 (reset); unknown
	/// ones are ignored.
	mutating func selectGraphicRendition(_ groups: [[Int?]]) {
		var attributes = attributes
		if groups.isEmpty { attributes = .default }

		// The semicolon forms of 38, 48 and 58 spread their color over the
		// parameters after them.
		let parameters = groups.map { $0[0] }

		var index = 0
		while index < groups.count {
			defer { index += 1 }
			let parameter = groups[index][0] ?? 0
			let subParameters = groups[index].dropFirst()
			if !subParameters.isEmpty {
				Self.apply(&attributes, parameter, Array(subParameters))
				continue
			}

			switch parameter {
			case 0: attributes = .default
			case 1: attributes.bold = true
			case 2: attributes.dim = true
			case 3: attributes.italic = true
			case 4, 21: attributes.underline = true  // 21: double, drawn as single
			case 5, 6: attributes.blink = true  // 6: rapid, drawn as a normal blink
			case 7: attributes.inverse = true
			case 8: attributes.invisible = true
			case 9: attributes.strikethrough = true
			case 22:
				attributes.bold = false
				attributes.dim = false
			case 23: attributes.italic = false
			case 24: attributes.underline = false
			case 25: attributes.blink = false
			case 27: attributes.inverse = false
			case 28: attributes.invisible = false
			case 29: attributes.strikethrough = false
			case 38, 48, 58:
				let (color, consumed) = Self.extendedColor(parameters, index)
				index += consumed
				// 58 (underline color) isn't drawn, but its color is still skipped.
				guard let color, parameter != 58 else { break }
				if parameter == 38 { attributes.foreground = color } else { attributes.background = color }
			case 39: attributes.foreground = nil
			case 49: attributes.background = nil
			case 30...37: attributes.foreground = .palette(UInt8(parameter - 30))
			case 40...47: attributes.background = .palette(UInt8(parameter - 40))
			case 90...97: attributes.foreground = .palette(UInt8(parameter - 82))
			case 100...107: attributes.background = .palette(UInt8(parameter - 92))
			default: break
			}
		}

		self.attributes = attributes
	}

	/// SGR 38, 48 and 58: read the extended color that follows the selector at
	/// `index`, either 5;n (a palette index) or 2;r;g;b (a direct color).
	/// Returns the color, or nil if a component is out of range, and the number
	/// of parameters it occupied. A truncated or unknown form consumes the rest
	/// of the list, since there's no telling where it ends.
	private static func extendedColor(_ parameters: [Int?], _ index: Int) -> (CellColor?, Int) {
		let rest = parameters.count - index - 1
		switch parameters[at: index + 1] ?? nil {
		case 5:
			if rest < 2 { return (nil, rest) }
			let palette = parameters[index + 2] ?? 0
			return (palette <= 255 ? .palette(UInt8(palette)) : nil, 2)
		case 2:
			if rest < 4 { return (nil, rest) }
			let r = parameters[index + 2] ?? 0
			let g = parameters[index + 3] ?? 0
			let b = parameters[index + 4] ?? 0
			return (
				r <= 255 && g <= 255 && b <= 255
					? .rgb(red: UInt8(r), green: UInt8(g), blue: UInt8(b)) : nil, 4
			)
		default:
			return (nil, rest)
		}
	}

	/// SGR 38, 48 and 58 in their colon form: 5:n, a palette index, or a direct
	/// color, as 2:r:g:b or 2:cs:r:g:b. The ID of the color space, cs, is
	/// usually empty, and is ignored. Returns nil for anything else, or a
	/// component out of range.
	private static func subParameterColor(_ subParameters: [Int?]) -> CellColor? {
		guard let type = subParameters.first else { return nil }
		let rest = Array(subParameters.dropFirst())
		if type == 5 && rest.count >= 1 {
			let palette = rest[0] ?? 0
			return palette <= 255 ? .palette(UInt8(palette)) : nil
		}
		if type == 2 && rest.count >= 3 {
			let components = rest.count == 3 ? rest : Array(rest[1..<4])
			let r = components[0] ?? 0
			let g = components[1] ?? 0
			let b = components[2] ?? 0
			return r <= 255 && g <= 255 && b <= 255
				? .rgb(red: UInt8(r), green: UInt8(g), blue: UInt8(b)) : nil
		}
		return nil
	}

	/// Apply an SGR parameter that came with sub-parameters: 4:n, an underline
	/// style (0 for none, then single, double, curly, dotted and dashed, all
	/// drawn as a single underline), or 38, 48 and 58 with their color. Others
	/// are ignored.
	private static func apply(_ attributes: inout Attributes, _ parameter: Int, _ subParameters: [Int?]) {
		switch parameter {
		case 4:
			let style = subParameters[0] ?? 0
			if style <= 5 { attributes.underline = style != 0 }
		case 38, 48, 58:
			// 58 (underline color) isn't drawn.
			guard let color = subParameterColor(subParameters), parameter != 58 else { return }
			if parameter == 38 { attributes.foreground = color } else { attributes.background = color }
		default:
			break
		}
	}

	/// The column the cursor is drawn in: a pending wrap parks `column` one
	/// past the edge, but the cursor itself is still on the last column.
	var cursorColumn: Int { min(column, columns - 1) }

	/// The cursor row as the application addresses it: in origin mode, rows
	/// count from the top of the scroll region.
	var cursorRow: Int { originMode ? row - scrollTop : row }

	/// Cursor movement. Every move is clamped to the screen and cancels a
	/// pending wrap.
	mutating func moveTo(_ row: Int, _ column: Int) {
		self.row = clamp(row, 0, rows - 1)
		self.column = clamp(column, 0, columns - 1)
	}

	/// CUP and VPA: like moveTo, but in origin mode the row counts from the top
	/// of the scroll region and stays inside it.
	mutating func setCursorPosition(_ row: Int, _ column: Int) {
		var row = row
		if originMode { row = clamp(row + scrollTop, scrollTop, scrollBottom) }
		moveTo(row, column)
	}

	/// Relative moves stop at a margin of the scroll region, if the cursor
	/// starts inside it, rather than leaving it.
	mutating func moveBy(_ rows: Int, _ columns: Int) {
		var row = self.row + rows
		if rows < 0 && self.row >= scrollTop { row = max(row, scrollTop) }
		if rows > 0 && self.row <= scrollBottom { row = min(row, scrollBottom) }
		moveTo(row, cursorColumn + columns)
	}

	/// The cell left behind by an erase. Like xterm's "back color erase", it
	/// takes the current background, and is otherwise empty.
	private func blankCell() -> Cell? {
		guard let background = attributes.background else { return nil }
		var attributes = Attributes.default
		attributes.background = background
		return Cell(text: " ", attributes: attributes)
	}

	private func blankLines(_ count: Int) -> [Line] {
		Array(repeating: Line(cells: Array(repeating: blankCell(), count: columns)), count: count)
	}

	/// Blank the columns in `from..<to` of a row.
	private mutating func eraseColumns(_ row: Int, _ from: Int, _ to: Int) {
		let blank = blankCell()
		for column in from..<max(from, to) { buffer[row].cells.set(column, blank) }
		buffer[row].cells.repair(blank)
	}

	/// ED: 0 erases from the cursor to the end of the screen, 1 from the start
	/// of the screen to the cursor, 2 the whole screen, and 3 the scrollback
	/// (only). The cursor does not move.
	mutating func eraseInDisplay(_ mode: Int) {
		if mode == 3 { scrollback = [] }
		if mode > 2 { return }
		let first = mode == 0 ? row : 0
		let last = mode == 1 ? row : rows - 1

		for row in first...last {
			let from = mode == 0 && row == self.row ? cursorColumn : 0
			let to = mode == 1 && row == self.row ? cursorColumn + 1 : columns
			eraseColumns(row, from, to)
			if to == columns { buffer[row].wrapped = false }
		}
	}

	/// EL: 0 erases from the cursor to the end of the line, 1 from the start
	/// of the line to the cursor, and 2 the whole line. The cursor does not
	/// move.
	mutating func eraseInLine(_ mode: Int) {
		if mode > 2 { return }
		let from = mode == 0 ? cursorColumn : 0
		let to = mode == 1 ? cursorColumn + 1 : columns
		eraseColumns(row, from, to)
		if to == columns { buffer[row].wrapped = false }
	}

	/// ECH: blank `count` characters from the cursor, without shifting.
	mutating func eraseCharacters(_ count: Int) {
		column = cursorColumn
		eraseColumns(row, column, min(column + count, columns))
	}

	/// ICH: insert `count` blanks at the cursor, pushing the rest of the line
	/// right and off the edge.
	mutating func insertCharacters(_ count: Int) {
		column = cursorColumn
		let shift = min(count, columns - column)
		var target = columns - 1
		while target >= column + shift {
			buffer[row].cells[target] = buffer[row].cells[target - shift]
			target -= 1
		}
		eraseColumns(row, column, column + shift)
	}

	/// DCH: delete `count` characters at the cursor, pulling the rest of the
	/// line left and blanking the end.
	mutating func deleteCharacters(_ count: Int) {
		column = cursorColumn
		let shift = min(count, columns - column)
		var target = column
		while target < columns - shift {
			buffer[row].cells[target] = buffer[row].cells[target + shift]
			target += 1
		}
		eraseColumns(row, columns - shift, columns)
	}

	/// IL: insert `count` blank lines at the cursor row, pushing the lines
	/// below it down and off the bottom margin. The cursor returns to the first
	/// column. Outside the scroll region, it does nothing.
	mutating func insertLines(_ count: Int) {
		if row < scrollTop || row > scrollBottom { return }
		let inserted = min(count, scrollBottom - row + 1)
		buffer.removeSubrange(scrollBottom - inserted + 1...scrollBottom)
		buffer.insert(contentsOf: blankLines(inserted), at: row)
		column = 0
	}

	/// DL: delete `count` lines at the cursor row, pulling the lines below it
	/// up and blanking the bottom of the scroll region. The cursor returns to
	/// the first column. Outside the scroll region, it does nothing.
	mutating func deleteLines(_ count: Int) {
		if row < scrollTop || row > scrollBottom { return }
		let deleted = min(count, scrollBottom - row + 1)
		buffer.removeSubrange(row..<row + deleted)
		buffer.insert(contentsOf: blankLines(deleted), at: scrollBottom - deleted + 1)
		column = 0
	}

	/// Resize the screen to the given dimensions. The primary screen and its
	/// scrollback are reflowed: lines that wrapped are joined and wrapped again
	/// at the new width. The alternate screen's lines are cut off or padded
	/// instead, since the application redraws it anyway (on SIGWINCH). Each
	/// screen's cursor, and saved cursor, stay with the text under them. The
	/// scroll region is reset to the whole screen.
	mutating func resize(_ columns: Int, _ rows: Int) {
		let columns = max(1, columns)
		let rows = max(1, rows)
		if columns == self.columns && rows == self.rows { return }

		// The cursor, then the saved cursor, of the screen shown; and the saved
		// cursor of the hidden one.
		var shown = [Position(row: row, column: column)] + (savedCursor.map { [$0.position] } ?? [])
		var hidden = hiddenSavedCursor.map { [$0.position] } ?? []

		if alternate {
			hiddenBuffer = reflow(hiddenBuffer, columns, rows, &hidden)
			buffer = truncate(buffer, columns, rows, &shown)
		} else {
			buffer = reflow(buffer, columns, rows, &shown)
			hiddenBuffer = truncate(hiddenBuffer, columns, rows, &hidden)
		}
		row = shown[0].row
		column = shown[0].column
		if shown.count > 1 { savedCursor?.position = shown[1] }
		if let position = hidden.first { hiddenSavedCursor?.position = position }

		// New columns get the default tab stops.
		var stops = Array(tabStops.prefix(min(columns, self.columns)))
		for column in stops.count..<max(stops.count, columns) {
			stops.append(column % tabStopInterval == 0 && column > 0)
		}
		tabStops = stops

		self.columns = columns
		self.rows = rows
		scrollTop = 0
		scrollBottom = rows - 1
	}

	/// Reflow the primary screen, with the scrollback above it, to the new
	/// size, and return its new lines. Blank lines at the bottom are dropped
	/// before anything is scrolled off the top, and when the screen grows,
	/// lines come back from the scrollback before blank ones are added. The
	/// first position is the one kept on the screen.
	private mutating func reflow(
		_ screen: [Line], _ columns: Int, _ rows: Int, _ positions: inout [Position]
	) -> [Line] {
		let offset = scrollback.count
		for index in positions.indices { positions[index].row += offset }

		var lines = scrollback + screen
		let lowest = positions.map(\.row).max() ?? -1
		while lines.count - 1 > lowest, let last = lines.last, last.isBlank { lines.removeLast() }
		if columns != self.columns {
			lines = rewrap(lines, width: self.columns, columns: columns, positions: &positions)
		}

		// Scroll as much as fits off the top, but no further than the cursor's
		// line (or, with the alternate screen shown, the saved cursor's): lines
		// below it that don't fit are dropped instead.
		let anchor = positions.first?.row ?? Int.max
		let top = min(max(0, lines.count - rows), anchor)
		scrollback = Array(lines[max(0, top - scrollbackLimit)..<top])
		for index in positions.indices { positions[index].row = max(0, positions[index].row - top) }

		var result = Array(lines[top..<min(top + rows, lines.count)])
		while result.count < rows { result.append(.empty(columns)) }
		return result
	}

	/// Fit the alternate screen to the new size, cutting lines off or padding
	/// them. When it's shorter, blank lines below the cursor go first, then
	/// lines off the top.
	private func truncate(
		_ screen: [Line], _ columns: Int, _ rows: Int, _ positions: inout [Position]
	) -> [Line] {
		var lines = screen
		for index in lines.indices {
			lines[index].cells.fit(columns)
			lines[index].cells.repair(nil)
		}
		for index in positions.indices {
			if positions[index].column >= self.columns {
				positions[index].column = columns
			} else {
				positions[index].column = min(positions[index].column, columns - 1)
			}
		}

		let lowest = positions.map(\.row).max() ?? -1
		while lines.count > rows, lines.count - 1 > lowest, let last = lines.last, last.isBlank {
			lines.removeLast()
		}
		let excess = max(0, lines.count - rows)
		lines.removeFirst(excess)
		for index in positions.indices { positions[index].row = max(0, positions[index].row - excess) }

		while lines.count < rows { lines.append(.empty(columns)) }
		return lines
	}

	/// HTS: set a tab stop at the cursor.
	mutating func setTabStop() {
		if column < tabStops.count { tabStops[column] = true }
	}

	/// HT: move the cursor right to the next tab stop, or the last column if
	/// none remain.
	mutating func tab() {
		while column < columns {
			column += 1
			if tabStops[at: column] == true { break }
		}
		if column == columns { column -= 1 }
	}

	/// CBT: move the cursor left to the previous tab stop, or the first column
	/// if none remain.
	mutating func backTab() {
		column = cursorColumn
		while column > 0 {
			column -= 1
			if tabStops[at: column] == true { break }
		}
	}

	/// TBC: 0 clears the tab stop at the cursor, and 3 clears them all.
	mutating func clearTabStops(_ mode: Int) {
		if mode == 0 {
			tabStops[cursorColumn] = false
		} else if mode == 3 {
			tabStops = Array(repeating: false, count: tabStops.count)
		}
	}

	/// BS: move the cursor left a column, cancelling a pending wrap.
	mutating func backspace() {
		if column == columns { column -= 1 }
		if column > 0 { column -= 1 }
	}

	/// REP: print the last character printed `count` more times, in the same
	/// character set. With nothing printed since RIS, it does nothing.
	mutating func `repeat`(_ count: Int) {
		guard let last = lastPrinted else { return }
		for _ in 0..<min(count, repeatLimit) { put(last.text, last.width) }
	}

	/// Print a code point in the character set in use. One that continues the
	/// grapheme cluster before the cursor joins its cell, rather than taking a
	/// cell of its own. Like Ghostty, only code points past U+00FF are checked:
	/// none before can continue a cluster.
	mutating func print(_ scalar: Unicode.Scalar) {
		var scalar = scalar
		if singleShift != nil || charsets[shift] != .ascii {
			let charset = charsets[singleShift ?? shift]
			singleShift = nil
			scalar = charset.translate(scalar)
		}

		if scalar.value <= 0xff {
			put(String(Character(scalar)), 1)
		} else if !join(scalar) {
			put(String(Character(scalar)), Width.width(Width.initial, scalar).cells)
		}
	}

	/// Add a code point to the cluster before the cursor, unless there's a
	/// grapheme break between them. Returns whether it was added. The cluster
	/// may get wider (with VS16, say) or narrower (with VS15).
	private mutating func join(_ scalar: Unicode.Scalar) -> Bool {
		let cells = buffer[row].cells

		// The cluster is under the cursor if a wrap is pending, or if the cursor
		// is on a written last column with autowrap off; otherwise it's to the
		// left. A wide character's right half stands for the character.
		var column = self.column - 1
		if self.column == columns {
			column = columns - 1
		} else if !autowrap && self.column == columns - 1 && cells[self.column] != nil {
			column = self.column
		}
		if cells.width(at: column) == 0 { column -= 1 }
		guard let cell = cells[at: column] ?? nil, !cell.text.isEmpty else { return false }

		let (grapheme, width) = fold(cell.text)
		if Grapheme.isBreak(grapheme, Grapheme.property(of: scalar)) { return false }
		let wide = Width.width(width, scalar).cells == 2
		var joined = cell.text
		joined.unicodeScalars.append(scalar)
		lastPrinted = (joined, wide ? 2 : 1)

		if wide == (cell.width == 2) {
			buffer[row].cells[column]?.text = joined
		} else if !wide {
			// Narrower: drop the right half, and put the cursor just after it.
			buffer[row].cells[column] = Cell(text: joined, attributes: cell.attributes)
			buffer[row].cells.set(column + 1, nil)
			self.column = min(column + 1, columns - 1)
		} else if column < columns - 1 {
			// Wider: take the next cell too, and put the cursor after it.
			buffer[row].cells.clearWide(column + 1)
			buffer[row].cells[column] = Cell(text: joined, attributes: cell.attributes, width: 2)
			buffer[row].cells[column + 1] = Cell(text: "", attributes: cell.attributes, width: 0)
			let next = column + 2
			self.column = next < columns ? next : autowrap ? columns : columns - 1
		} else if autowrap {
			// Wider, in the last column: move it to the next line.
			buffer[row].cells[column] = nil
			buffer[row].wrapped = true
			self.column = 0
			linefeed()
			put(joined, 2, cell.attributes)
		} else {
			// With no room to grow, it stays narrow.
			buffer[row].cells[column]?.text = joined
		}
		return true
	}

	/// Write a grapheme cluster `width` cells wide at the cursor, and advance it.
	private mutating func put(_ text: String, _ width: Int, _ attributes: Attributes? = nil) {
		let attributes = attributes ?? self.attributes

		// A previous character filled the last column, leaving a wrap pending
		// (column == columns). With autowrap (DECAWM) on, resolve it by moving
		// to a new line before writing; with it off, cancel the wrap so the
		// cursor overwrites the last column instead.
		if column == columns {
			if autowrap {
				buffer[row].wrapped = true
				column = 0
				linefeed()
			} else {
				column -= 1
			}
		}

		// A wide character needs two columns. In the last one, it wraps to the
		// next line, leaving padding, or with autowrap off isn't printed. On a
		// one-column screen, it leaves the cell empty.
		if width == 2 && column == columns - 1 {
			if columns == 1 {
				buffer[row].cells.clearWide(column)
				buffer[row].cells[column] = nil
				if autowrap { column = columns }
				return
			}
			if !autowrap { return }
			buffer[row].cells.clearWide(column)
			buffer[row].cells[column] = nil
			buffer[row].wrapped = true
			column = 0
			linefeed()
		}

		buffer[row].cells.clearWide(column)
		if width == 2 {
			buffer[row].cells.clearWide(column + 1)
			buffer[row].cells[column] = Cell(text: text, attributes: attributes, width: 2)
			buffer[row].cells[column + 1] = Cell(text: "", attributes: attributes, width: 0)
		} else {
			buffer[row].cells[column] = Cell(text: text, attributes: attributes)
		}

		let next = column + width
		if next < columns {
			column = next
		} else if autowrap {
			column = columns
		} else {
			column = columns - 1
		}
		lastPrinted = (text, width)
	}
}
