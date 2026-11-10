// The character sets SCS can designate into G0–G3: US ASCII (ESC ( B), the
// British set (ESC ( A), which has £ in place of #, and DEC Special Graphics
// (ESC ( 0), which draws lines, boxes and symbols in place of ` and the
// lowercase letters. ncurses draws its borders with it.
enum Charset: Sendable {
	case ascii
	case british
	case decGraphics

	/// The set a final byte designates. Others aren't supported.
	init?(designation: UInt8) {
		switch designation {
		case 0x42: self = .ascii  // B
		case 0x41: self = .british  // A
		case 0x30: self = .decGraphics  // 0
		default: return nil
		}
	}

	// ` through ~ in DEC Special Graphics.
	private static let decGraphicsCharacters: [Unicode.Scalar] = [
		"\u{25c6}",  // ◆ diamond
		"\u{2592}",  // ▒ checkerboard
		"\u{2409}",  // ␉ HT
		"\u{240c}",  // ␌ FF
		"\u{240d}",  // ␍ CR
		"\u{240a}",  // ␊ LF
		"\u{00b0}",  // ° degree
		"\u{00b1}",  // ± plus or minus
		"\u{2424}",  // ␤ NL
		"\u{240b}",  // ␋ VT
		"\u{2518}",  // ┘ lower right corner
		"\u{2510}",  // ┐ upper right corner
		"\u{250c}",  // ┌ upper left corner
		"\u{2514}",  // └ lower left corner
		"\u{253c}",  // ┼ crossing lines
		"\u{23ba}",  // ⎺ scan line 1
		"\u{23bb}",  // ⎻ scan line 3
		"\u{2500}",  // ─ horizontal line (scan line 5)
		"\u{23bc}",  // ⎼ scan line 7
		"\u{23bd}",  // ⎽ scan line 9
		"\u{251c}",  // ├ left tee
		"\u{2524}",  // ┤ right tee
		"\u{2534}",  // ┴ bottom tee
		"\u{252c}",  // ┬ top tee
		"\u{2502}",  // │ vertical line
		"\u{2264}",  // ≤
		"\u{2265}",  // ≥
		"\u{03c0}",  // π
		"\u{2260}",  // ≠
		"\u{00a3}",  // £
		"\u{00b7}",  // · centered dot
	]

	/// The character `scalar` is drawn as in this set. Only ASCII is replaced.
	func translate(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
		switch self {
		case .ascii:
			return scalar
		case .british:
			return scalar == "#" ? "£" : scalar
		case .decGraphics:
			guard scalar.value >= 0x60 && scalar.value <= 0x7e else { return scalar }
			return Self.decGraphicsCharacters[Int(scalar.value) - 0x60]
		}
	}
}
