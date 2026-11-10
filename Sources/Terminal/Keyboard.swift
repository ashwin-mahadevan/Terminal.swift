// Translate key presses into the bytes a PTY expects, as xterm does.

/// A key press, as far as its encoding depends on it.
public struct TerminalKey: Equatable, Sendable {
	public enum Key: Equatable, Sendable {
		/// A key that types text: what it typed, with its modifiers applied.
		case character(String)
		case enter
		case backspace
		case tab
		case escape
		case up
		case down
		case left
		case right
		case home
		case end
		case insert
		case delete
		case pageUp
		case pageDown
		/// F1 through F12.
		case function(Int)
	}

	public var key: Key

	/// For a key on the numeric keypad, what's printed on it: a digit, or one
	/// of `.`, `+`, `-`, `*`, `/`, or `\r` for Enter.
	public var keypad: Character?

	/// For a letter or digit key, the letter (in upper case) or digit printed
	/// on it, whatever the modifiers made it type.
	public var physical: Character?

	public var shift: Bool
	/// Option, or Alt.
	public var option: Bool
	public var control: Bool
	public var command: Bool

	public init(
		_ key: Key, keypad: Character? = nil, physical: Character? = nil, shift: Bool = false,
		option: Bool = false, control: Bool = false, command: Bool = false
	) {
		self.key = key
		self.keypad = keypad
		self.physical = physical
		self.shift = shift
		self.option = option
		self.control = control
		self.command = command
	}
}

public struct KeyboardModes: Equatable, Sendable {
	/// DECCKM (?1): arrows, Home and End send SS3 sequences instead of CSI ones.
	public var applicationCursor: Bool
	/// DECKPAM: the keypad sends SS3 sequences instead of what's printed on it.
	public var applicationKeypad: Bool
	/// Whether Option sends ESC before the key, the way most terminal
	/// applications expect Meta to arrive. Otherwise Option is left to type
	/// what it types, like its special characters.
	public var optionSendsEscape: Bool

	public init(
		applicationCursor: Bool = false, applicationKeypad: Bool = false,
		optionSendsEscape: Bool = false
	) {
		self.applicationCursor = applicationCursor
		self.applicationKeypad = applicationKeypad
		self.optionSendsEscape = optionSendsEscape
	}
}

// DECKPAM: the final byte of each VT220-style application keypad sequence.
private let applicationKeypad: [Character: String] = [
	"0": "p", "1": "q", "2": "r", "3": "s", "4": "t", "5": "u", "6": "v", "7": "w", "8": "x",
	"9": "y", ".": "n", "\r": "M", "+": "k", "-": "m", "*": "j", "/": "o",
]

// Ctrl with a symbol or digit, where it means a control character: the
// VT220's Ctrl-2 through Ctrl-8, and the ASCII symbols they stand for.
private let controlSymbols: [String: String] = [
	" ": "\u{00}", "@": "\u{00}", "2": "\u{00}",
	"[": "\u{1b}", "3": "\u{1b}",
	"\\": "\u{1c}", "4": "\u{1c}",
	"]": "\u{1d}", "5": "\u{1d}",
	"^": "\u{1e}", "6": "\u{1e}",
	"_": "\u{1f}", "-": "\u{1f}", "/": "\u{1f}", "7": "\u{1f}",
	"?": "\u{7f}", "8": "\u{7f}",
]

/// The bytes for a key press, or nil if it sends nothing. Then the system
/// should have it, for a shortcut or to type it through an input method.
public func encodeKey(_ key: TerminalKey, modes: KeyboardModes) -> String? {
	// Command is for the system.
	if key.command { return nil }

	if modes.applicationKeypad, let keypad = key.keypad, let final = applicationKeypad[keypad] {
		return "\u{1b}O\(final)"
	}

	// The xterm modifier parameter: 1, plus 1 for Shift, 2 for Alt, 4 for Ctrl.
	let m = 1 + (key.shift ? 1 : 0) + (key.option ? 2 : 0) + (key.control ? 4 : 0)
	let escape = key.option && modes.optionSendsEscape ? "\u{1b}" : ""

	// Keys sent as CSI (or, unmodified in application cursor mode, SS3) then a
	// final letter. With modifiers they become CSI 1 ; m <letter>.
	func cursor(_ final: String) -> String {
		if m > 1 { return "\u{1b}[1;\(m)\(final)" }
		return modes.applicationCursor ? "\u{1b}O\(final)" : "\u{1b}[\(final)"
	}

	// Keys sent as CSI <number> ~, or CSI <number> ; m ~ with modifiers.
	func tilde(_ number: Int) -> String {
		m > 1 ? "\u{1b}[\(number);\(m)~" : "\u{1b}[\(number)~"
	}

	var text: String
	switch key.key {
	case .up: return cursor("A")
	case .down: return cursor("B")
	case .right: return cursor("C")
	case .left: return cursor("D")
	case .home: return cursor("H")
	case .end: return cursor("F")

	// F1–F4: SS3 then a letter, or CSI 1 ; m <letter> with modifiers.
	case .function(let number) where (1...4).contains(number):
		let final = ["P", "Q", "R", "S"][number - 1]
		return m > 1 ? "\u{1b}[1;\(m)\(final)" : "\u{1b}O\(final)"
	case .function(let number) where (5...12).contains(number):
		return tilde([15, 17, 18, 19, 20, 21, 23, 24][number - 5])
	case .function:
		return nil

	case .insert: return tilde(2)
	case .delete: return tilde(3)
	case .pageUp: return tilde(5)
	case .pageDown: return tilde(6)

	case .enter: return escape + "\r"
	case .backspace: return escape + (key.control ? "\u{08}" : "\u{7f}")
	case .tab: return key.shift ? "\u{1b}[Z" : escape + "\t"
	case .escape: return escape + "\u{1b}"

	case .character(let typed):
		text = typed
	}

	// Anything that isn't a single character sends nothing.
	if text.unicodeScalars.count != 1 { return nil }

	// With Option as Meta, Option+A is å; the key itself is A.
	if !escape.isEmpty, let physical = key.physical {
		if physical.isLetter {
			text = key.shift ? physical.uppercased() : physical.lowercased()
		} else if physical.isNumber && !key.shift {
			text = String(physical)
		}
	}

	if key.control {
		let lower = text.lowercased()
		if let scalar = lower.unicodeScalars.first, lower.unicodeScalars.count == 1,
			scalar >= "a" && scalar <= "z"
		{
			return escape + String(Character(Unicode.Scalar(scalar.value - 96)!))
		}
		// Other Ctrl combinations are left to the system.
		return controlSymbols[text].map { escape + $0 }
	}

	return escape + text
}

/// Pasted text as it's sent: line breaks become CRs, as if the text had been
/// typed. When the application asked for bracketed paste (?2004), the text is
/// wrapped in markers so it can tell a paste from typing; ESCs are dropped
/// then, so the text can't close the bracket early.
public func encodePaste(_ text: String, bracketed: Bool) -> String {
	let normalized = text.replacing("\r\n", with: "\r").replacing("\n", with: "\r")
	guard bracketed else { return normalized }
	return "\u{1b}[200~\(normalized.replacing("\u{1b}", with: ""))\u{1b}[201~"
}
