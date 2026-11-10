#if canImport(SwiftUI)
	import SwiftUI

	/// Something the user did to the terminal.
	enum InputEvent {
		/// A key press, to encode.
		case key(TerminalKey)
		/// Text to send as it is, from the on-screen keyboard, dictation, or the
		/// emoji picker.
		case text(String)
		/// Pasted text.
		case paste(String)
	}

	/// The view that holds the keyboard focus, so the terminal can ask for it.
	@MainActor
	final class InputProxy {
		#if canImport(UIKit)
			weak var view: UIView?
		#endif
	}

	/// Takes the user's typing for a terminal. `handle` returns false to leave
	/// an event to the system.
	struct TerminalInput: ViewModifier {
		let proxy: InputProxy
		let enabled: Bool
		let handle: (InputEvent) -> Bool

		#if canImport(UIKit)
			func body(content: Content) -> some View {
				if enabled {
					content
						// Keys are read by a view of no size, which holds the focus. A
						// tap gives it to it, which brings up the keyboard.
						.background { KeyInput(proxy: proxy, handle: handle).frame(width: 0, height: 0) }
						.onTapGesture { proxy.view?.becomeFirstResponder() }
				} else {
					content
				}
			}
		#else
			@FocusState private var focused: Bool

			func body(content: Content) -> some View {
				if enabled {
					content
						.focusable()
						.focusEffectDisabled()
						.focused($focused)
						.onAppear { focused = true }
						.onKeyPress(phases: [.down, .repeat]) { press in
							handle(.key(TerminalKey(press))) ? .handled : .ignored
						}
						.onPasteCommand(of: [.plainText]) { _ in
							_ = handle(.paste(NSPasteboard.general.string(forType: .string) ?? ""))
						}
				} else {
					content
				}
			}
		#endif
	}

	#if canImport(UIKit)
		private struct KeyInput: UIViewRepresentable {
			let proxy: InputProxy
			let handle: (InputEvent) -> Bool

			func makeUIView(context: Context) -> KeyInputView {
				let view = KeyInputView()
				proxy.view = view
				return view
			}

			func updateUIView(_ view: KeyInputView, context: Context) {
				view.handle = handle
			}
		}

		/// Reads keys for the terminal: from the on-screen keyboard as text, and
		/// from a hardware keyboard as presses.
		private final class KeyInputView: UIView, UIKeyInput {
			var handle: (InputEvent) -> Bool = { _ in false }

			override var canBecomeFirstResponder: Bool { true }

			// What's typed is sent as it is: nothing is corrected or completed.
			var autocapitalizationType = UITextAutocapitalizationType.none
			var autocorrectionType = UITextAutocorrectionType.no
			var spellCheckingType = UITextSpellCheckingType.no
			var smartQuotesType = UITextSmartQuotesType.no
			var smartDashesType = UITextSmartDashesType.no
			var smartInsertDeleteType = UITextSmartInsertDeleteType.no

			var hasText: Bool { true }

			func insertText(_ text: String) {
				// The on-screen keyboard's Return is the Enter key.
				_ = handle(text == "\n" ? .key(TerminalKey(.enter)) : .text(text))
			}

			func deleteBackward() {
				_ = handle(.key(TerminalKey(.backspace)))
			}

			override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
				var unhandled: Set<UIPress> = []
				for press in presses {
					guard let key = press.key.map(TerminalKey.init), !key.typesText,
						handle(.key(key))
					else {
						// Keys that just type text go on to the system, which types it
						// through `insertText`, composing dead keys on the way.
						unhandled.insert(press)
						continue
					}
				}
				if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
			}

			override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
				action == #selector(paste(_:)) && UIPasteboard.general.hasStrings
			}

			override func paste(_ sender: Any?) {
				_ = handle(.paste(UIPasteboard.general.string ?? ""))
			}
		}

		extension TerminalKey {
			/// Whether the key only types its text, with nothing to encode.
			fileprivate var typesText: Bool {
				if case .character = key { return !control && !command && !option }
				return false
			}

			@MainActor fileprivate init(_ key: UIKey) {
				let flags = key.modifierFlags
				let code = key.keyCode
				var keypad: Character?
				var physical: Character?

				let named: Key? =
					switch code {
					case .keyboardReturnOrEnter: .enter
					case .keypadEnter: .enter
					case .keyboardDeleteOrBackspace: .backspace
					case .keyboardTab: .tab
					case .keyboardEscape: .escape
					case .keyboardUpArrow: .up
					case .keyboardDownArrow: .down
					case .keyboardLeftArrow: .left
					case .keyboardRightArrow: .right
					case .keyboardHome: .home
					case .keyboardEnd: .end
					case .keyboardInsert: .insert
					case .keyboardDeleteForward: .delete
					case .keyboardPageUp: .pageUp
					case .keyboardPageDown: .pageDown
					default: nil
					}

				let value = code.rawValue
				if value >= UIKeyboardHIDUsage.keyboardA.rawValue
					&& value <= UIKeyboardHIDUsage.keyboardZ.rawValue
				{
					let offset = UInt32(value - UIKeyboardHIDUsage.keyboardA.rawValue)
					physical = Character(Unicode.Scalar(65 + offset)!)
				} else if value >= UIKeyboardHIDUsage.keyboard1.rawValue
					&& value <= UIKeyboardHIDUsage.keyboard0.rawValue
				{
					physical = Array("1234567890")[value - UIKeyboardHIDUsage.keyboard1.rawValue]
				} else if value >= UIKeyboardHIDUsage.keypadSlash.rawValue
					&& value <= UIKeyboardHIDUsage.keypadPeriod.rawValue
				{
					keypad = Array("/*-+\r1234567890.")[value - UIKeyboardHIDUsage.keypadSlash.rawValue]
				}

				let function = value - UIKeyboardHIDUsage.keyboardF1.rawValue + 1
				let resolved: Key
				if let named {
					resolved = named
				} else if (1...12).contains(function) {
					resolved = .function(function)
				} else if flags.contains(.control) {
					// With Control, the characters are the control character itself.
					resolved = .character(key.charactersIgnoringModifiers)
				} else {
					resolved = .character(key.characters)
				}

				self.init(
					resolved, keypad: keypad, physical: physical, shift: flags.contains(.shift),
					option: flags.contains(.alternate), control: flags.contains(.control),
					command: flags.contains(.command))
			}
		}
	#else
		extension TerminalKey {
			fileprivate init(_ press: KeyPress) {
				let modifiers = press.modifiers
				let character = press.key.character
				let scalar = character.unicodeScalars.first?.value ?? 0

				// The function keys arrive as AppKit's private-use characters.
				let function = Int(scalar) - 0xf704 + 1
				let named: Key? =
					switch press.key {
					case .return: .enter
					case .delete: .backspace
					case .deleteForward: .delete
					case .tab: .tab
					case .escape: .escape
					case .upArrow: .up
					case .downArrow: .down
					case .leftArrow: .left
					case .rightArrow: .right
					case .home: .home
					case .end: .end
					case .pageUp: .pageUp
					case .pageDown: .pageDown
					default:
						if scalar == 0x03 {
							.enter  // The keypad's Enter.
						} else if scalar == 0x19 {
							.tab  // Shift+Tab arrives as a backtab.
						} else if scalar == 0xf727 || scalar == 0xf746 {
							.insert  // Insert, or Help on a Mac keyboard.
						} else if (1...12).contains(function) {
							.function(function)
						} else {
							nil
						}
					}

				var keypad: Character?
				if modifiers.contains(.numericPad) {
					if scalar == 0x03 {
						keypad = "\r"
					} else if "0123456789.+-*/".contains(character) {
						keypad = character
					}
				}

				var physical: Character?
				if character.isASCII, character.isLetter || character.isNumber {
					physical = Character(character.uppercased())
				}

				// With Control, the characters are the control character itself.
				let text = modifiers.contains(.control) ? String(character) : press.characters
				self.init(
					named ?? .character(text), keypad: keypad, physical: physical,
					shift: modifiers.contains(.shift), option: modifiers.contains(.option),
					control: modifiers.contains(.control), command: modifiers.contains(.command))
			}
		}
	#endif
#endif
