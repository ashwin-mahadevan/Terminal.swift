/// A color set by SGR. A cell with no color (`nil`) is drawn in the default
/// foreground or background.
public enum CellColor: Hashable, Sendable {
	/// An index into the 256-color palette.
	case palette(UInt8)
	/// A direct color.
	case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

/// The graphic rendition of a cell, as set by SGR.
public struct Attributes: Hashable, Sendable {
	public var foreground: CellColor?
	public var background: CellColor?
	public var bold = false
	public var dim = false
	public var italic = false
	public var underline = false
	public var blink = false
	public var inverse = false
	public var invisible = false
	public var strikethrough = false

	public init() {}

	static let `default` = Attributes()
}

/// One cell of the screen. A cell that was never written, or was erased with
/// the default background, is `nil` in its line.
public struct Cell: Hashable, Sendable {
	/// A grapheme cluster: one or more code points drawn as one character.
	public var text: String
	public var attributes: Attributes
	/// 2 for a wide character, which covers the next cell too, and 0 for that
	/// next cell, which has no text of its own. Otherwise 1.
	public var width: Int

	public init(text: String, attributes: Attributes, width: Int = 1) {
		self.text = text
		self.attributes = attributes
		self.width = width
	}
}

/// A row of the screen or the scrollback.
public struct Line: Hashable, Sendable {
	public var cells: [Cell?]

	/// Whether the next line is a continuation of this one: the text wrapped
	/// at the last column.
	public var wrapped: Bool

	public init(cells: [Cell?], wrapped: Bool = false) {
		self.cells = cells
		self.wrapped = wrapped
	}

	static func empty(_ columns: Int) -> Line {
		Line(cells: Array(repeating: nil, count: columns))
	}

	var isBlank: Bool {
		!wrapped && cells.allSatisfy { $0 == nil }
	}
}

/// The shape of the cursor, as set by DECSCUSR.
public enum CursorStyle: Hashable, Sendable {
	case block
	case underline
	case bar
}
