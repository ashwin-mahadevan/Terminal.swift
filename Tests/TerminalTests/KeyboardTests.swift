import Testing

@testable import Terminal

private let meta = KeyboardModes(optionSendsEscape: true)

private func encode(
	_ key: TerminalKey.Key, keypad: Character? = nil, physical: Character? = nil,
	shift: Bool = false, option: Bool = false, control: Bool = false, command: Bool = false,
	modes: KeyboardModes = meta
) -> String? {
	encodeKey(
		TerminalKey(
			key, keypad: keypad, physical: physical, shift: shift, option: option, control: control,
			command: command),
		modes: modes)
}

private func encode(_ text: String, shift: Bool = false, option: Bool = false, control: Bool = false)
	-> String?
{
	encode(.character(text), shift: shift, option: option, control: control)
}

@Suite struct KeyboardTests {
	@Test func sendsPrintableCharactersAsThemselves() {
		#expect(encode("a") == "a")
		#expect(encode("A", shift: true) == "A")
		#expect(encode(" ") == " ")
		#expect(encode("é") == "é")
		#expect(encode("😀") == "😀")
	}

	@Test func sendsTheEditingKeys() {
		#expect(encode(.enter) == "\r")
		#expect(encode(.backspace) == "\u{7f}")
		#expect(encode(.backspace, control: true) == "\u{08}")
		#expect(encode(.tab) == "\t")
		#expect(encode(.tab, shift: true) == "\u{1b}[Z")
		#expect(encode(.escape) == "\u{1b}")
	}

	@Test func sendsArrowsHomeAndEndAsCSIOrSS3InApplicationCursorMode() {
		let keys: [(TerminalKey.Key, String)] = [
			(.up, "A"), (.down, "B"), (.right, "C"), (.left, "D"), (.home, "H"), (.end, "F"),
		]
		for (key, final) in keys {
			#expect(encode(key) == "\u{1b}[\(final)")
			#expect(encode(key, modes: KeyboardModes(applicationCursor: true)) == "\u{1b}O\(final)")
		}
	}

	@Test func addsTheModifiersToArrowsHomeAndEndInEitherCursorMode() {
		#expect(encode(.right, control: true) == "\u{1b}[1;5C")
		#expect(encode(.left, option: true) == "\u{1b}[1;3D")
		#expect(encode(.up, shift: true) == "\u{1b}[1;2A")
		#expect(encode(.home, shift: true, control: true) == "\u{1b}[1;6H")
		#expect(encode(.end, shift: true, option: true, control: true) == "\u{1b}[1;8F")
		#expect(
			encode(.right, control: true, modes: KeyboardModes(applicationCursor: true))
				== "\u{1b}[1;5C")
	}

	@Test func sendsInsertDeletePageUpAndPageDownAsCSITilde() {
		#expect(encode(.insert) == "\u{1b}[2~")
		#expect(encode(.delete) == "\u{1b}[3~")
		#expect(encode(.pageUp) == "\u{1b}[5~")
		#expect(encode(.pageDown) == "\u{1b}[6~")
		#expect(encode(.delete, control: true) == "\u{1b}[3;5~")
	}

	@Test func sendsTheFunctionKeys() {
		let expected = [
			"\u{1b}OP", "\u{1b}OQ", "\u{1b}OR", "\u{1b}OS", "\u{1b}[15~", "\u{1b}[17~", "\u{1b}[18~",
			"\u{1b}[19~", "\u{1b}[20~", "\u{1b}[21~", "\u{1b}[23~", "\u{1b}[24~",
		]
		for (index, data) in expected.enumerated() {
			#expect(encode(.function(index + 1)) == data)
		}
		#expect(encode(.function(13)) == nil)
	}

	@Test func addsTheModifiersToTheFunctionKeys() {
		#expect(encode(.function(1), shift: true) == "\u{1b}[1;2P")
		#expect(encode(.function(4), control: true) == "\u{1b}[1;5S")
		#expect(encode(.function(5), shift: true) == "\u{1b}[15;2~")
		#expect(encode(.function(12), option: true, control: true) == "\u{1b}[24;7~")
	}

	@Test func sendsControlWithALetterAsAControlCharacter() {
		#expect(encode("a", control: true) == "\u{01}")
		#expect(encode("c", control: true) == "\u{03}")
		#expect(encode("Z", shift: true, control: true) == "\u{1a}")
	}

	@Test func sendsControlWithSymbolsAndDigitsAsTheirControlCharacters() {
		#expect(encode(" ", control: true) == "\u{00}")
		#expect(encode("2", control: true) == "\u{00}")
		#expect(encode("[", control: true) == "\u{1b}")
		#expect(encode("\\", control: true) == "\u{1c}")
		#expect(encode("]", control: true) == "\u{1d}")
		#expect(encode("6", control: true) == "\u{1e}")
		#expect(encode("/", control: true) == "\u{1f}")
		#expect(encode("-", control: true) == "\u{1f}")
		#expect(encode("8", control: true) == "\u{7f}")
	}

	@Test func leavesOtherControlCombinationsToTheSystem() {
		#expect(encode("1", control: true) == nil)
		#expect(encode("=", control: true) == nil)
	}

	@Test func sendsESCBeforeKeysWithOption() {
		#expect(encode("b", option: true) == "\u{1b}b")
		#expect(encode("B", shift: true, option: true) == "\u{1b}B")
		#expect(encode(".", option: true) == "\u{1b}.")
		#expect(encode(.enter, option: true) == "\u{1b}\r")
		#expect(encode(.backspace, option: true) == "\u{1b}\u{7f}")
		#expect(encode("x", option: true, control: true) == "\u{1b}\u{18}")
	}

	@Test func sendsOptionKeysAsTypedWhenOptionDoesNotSendESC() {
		let modes = KeyboardModes()
		#expect(encode(.character("å"), physical: "A", option: true, modes: modes) == "å")
		#expect(encode(.backspace, option: true, modes: modes) == "\u{7f}")
	}

	@Test func usesTheKeyItselfNotTheCharacterOptionComposes() {
		#expect(encode(.character("∫"), physical: "B", option: true) == "\u{1b}b")
		#expect(encode(.character("ı"), physical: "B", shift: true, option: true) == "\u{1b}B")
		#expect(encode(.character("¡"), physical: "1", option: true) == "\u{1b}1")
	}

	@Test func leavesCommandShortcutsToTheSystem() {
		#expect(encode(.character("c"), command: true) == nil)
		#expect(encode(.character("v"), command: true) == nil)
		#expect(encode(.left, command: true) == nil)
	}

	@Test func sendsNothingForKeysThatTypeNoSingleCharacter() {
		#expect(encode("") == nil)
		#expect(encode("ab") == nil)
	}

	@Test func sendsTheApplicationKeypadSequences() {
		let keypad = KeyboardModes(applicationKeypad: true)
		#expect(encode(.character("5"), keypad: "5", modes: keypad) == "\u{1b}Ou")
		#expect(encode(.enter, keypad: "\r", modes: keypad) == "\u{1b}OM")
		#expect(encode(.character("5"), modes: keypad) == "5")
		#expect(encode(.enter, keypad: "\r") == "\r")
	}

	@Test func pastesLineBreaksAsCarriageReturns() {
		#expect(encodePaste("a\r\nb\nc\rd", bracketed: false) == "a\rb\rc\rd")
	}

	@Test func bracketsAPasteAndDropsItsEscapes() {
		#expect(encodePaste("a\n\u{1b}[201~b", bracketed: true) == "\u{1b}[200~a\r[201~b\u{1b}[201~")
	}
}
