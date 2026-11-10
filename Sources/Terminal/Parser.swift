import Foundation

/// Something the output asked of the terminal, other than changing the screen.
enum Event: Equatable, Sendable {
	/// BEL.
	case bell
	/// A reply to one of the program's queries, such as device attributes.
	case data([UInt8])
}

// CSI ? 62 ; 22 c: the primary device attributes report, claiming a VT220
// (conformance level 2) with ANSI color.
private let deviceAttributesResponse = Array("\u{1b}[?62;22c".utf8)

// CSI > 1 ; 0 ; 0 c: the secondary device attributes report, claiming a VT220
// with no firmware version and no ROM cartridge.
private let secondaryDeviceAttributesResponse = Array("\u{1b}[>1;0;0c".utf8)

// Parameters stop growing here, far past any value that means something, so a
// long run of digits can't overflow.
private let parameterLimit = 1 << 32

/// The streaming parser for a terminal's output. Each mode has a function
/// that parses as many bytes as it can, starting at `start`, sets `mode` to
/// the one needed to continue, and returns the number of bytes it consumed.
/// Chunks may split anywhere, even inside an escape sequence or a UTF-8
/// character.
struct Parser: Sendable {
	enum Mode: Sendable {
		case ground
		case grapheme
		case escape
		case escapeIntermediate
		case csi
		case csiIntermediate
		case csiParam
		case osc
		case oscEscape
		case string
	}

	private(set) var mode = Mode.ground

	private var privateMarker: UInt8?
	private var parameters: [Int?] = []
	// Whether each parameter followed a colon, which makes it a sub-parameter
	// of the one before, like the 3 of SGR 4:3 (curly underline).
	private var subParameters: [Bool] = []
	private var intermediates: [UInt8] = []
	private var oscString: [UInt8] = []

	// The UTF-8 decoder's progress through a multi-byte sequence: the bits of
	// the code point so far, how many continuation bytes it needs and has seen,
	// and the range the next one must be in.
	private var codePoint: UInt32 = 0
	private var needed = 0
	private var seen = 0
	private var lower: UInt8 = 0x80
	private var upper: UInt8 = 0xbf

	/// Bells and replies, in the order the output asked for them. The caller
	/// takes them once the chunk is parsed.
	var events: [Event] = []

	mutating func write(_ chunk: UnsafeBufferPointer<UInt8>, to screen: inout Screen) {
		var index = 0
		while index < chunk.count {
			switch mode {
			case .ground: index += ground(chunk, index, &screen)
			case .grapheme: index += grapheme(chunk, index, &screen)
			case .escape: index += escape(chunk[index], &screen)
			case .escapeIntermediate: index += escapeIntermediate(chunk[index], &screen)
			case .csi: index += csi(chunk[index], &screen)
			case .csiIntermediate: index += csiIntermediate(chunk, index)
			case .csiParam: index += csiParam(chunk, index)
			case .osc: index += osc(chunk, index, &screen)
			case .oscEscape: index += oscEscape(chunk[index], &screen)
			case .string: index += string(chunk, index)
			}
		}
	}

	// MARK: Ground

	private mutating func ground(
		_ chunk: UnsafeBufferPointer<UInt8>, _ start: Int, _ screen: inout Screen
	) -> Int {
		var index = 0

		repeat {
			let byte = chunk[start + index]

			switch byte {
			// Intentionally ignored: NUL, SOH, STX, ETX, EOT, ENQ, ACK, DLE, DC1
			// (XON), DC2, DC3 (XOFF), DC4, NAK, SYN, ETB, CAN, EM, SUB, FS, GS, RS,
			// US and DEL.
			case 0x00...0x06, 0x10...0x1a, 0x1c...0x1f, 0x7f:
				break

			// BEL (bell)
			case 0x07:
				events.append(.bell)

			// BS (backspace)
			case 0x08:
				screen.backspace()

			// HT (horizontal tab)
			case 0x09:
				screen.tab()

			// LF (line feed), VT (vertical tab), FF (form feed)
			case 0x0a, 0x0b, 0x0c:
				screen.linefeed()

			// CR (carriage return)
			case 0x0d:
				screen.column = 0

			// SO (shift out): print with G1.
			case 0x0e:
				screen.shift = 1

			// SI (shift in): print with G0.
			case 0x0f:
				screen.shift = 0

			// ESC (escape)
			case 0x1b:
				mode = .escape
				return index + 1

			// Printable character
			default:
				if byte & 0x80 != 0 {
					mode = .grapheme
					return index
				}
				screen.print(Unicode.Scalar(byte))
			}

			index += 1
		} while start + index < chunk.count

		return index
	}

	// MARK: UTF-8

	private static let replacementCharacter: Unicode.Scalar = "\u{fffd}"

	/// Decode UTF-8, printing each code point. A sequence may be split across
	/// chunks: the parser keeps the decoder's progress until the rest arrives.
	/// Malformed input is replaced as the WHATWG UTF-8 decoder does: each
	/// invalid byte, or truncated sequence, prints U+FFFD, and a byte that
	/// interrupts a sequence is then parsed on its own. `Screen.print` joins
	/// the code points into grapheme clusters.
	private mutating func grapheme(
		_ chunk: UnsafeBufferPointer<UInt8>, _ start: Int, _ screen: inout Screen
	) -> Int {
		var index = 0

		repeat {
			let byte = chunk[start + index]

			if needed == 0 {
				// ASCII belongs to the ground parser.
				if byte < 0x80 {
					mode = .ground
					return index
				}

				// A lead byte: how many continuation bytes follow, and the range the
				// first one must be in, which rules out overlong forms, surrogates and
				// code points past U+10FFFF.
				switch byte {
				case 0xc2...0xdf:
					needed = 1
					codePoint = UInt32(byte & 0x1f)
				case 0xe0...0xef:
					if byte == 0xe0 { lower = 0xa0 }
					if byte == 0xed { upper = 0x9f }
					needed = 2
					codePoint = UInt32(byte & 0x0f)
				case 0xf0...0xf4:
					if byte == 0xf0 { lower = 0x90 }
					if byte == 0xf4 { upper = 0x8f }
					needed = 3
					codePoint = UInt32(byte & 0x07)
				default:
					// A continuation byte with no lead, or a byte UTF-8 never uses.
					screen.print(Self.replacementCharacter)
				}
				index += 1
				continue
			}

			// A byte that can't continue the sequence ends it early. It's parsed
			// again, as the start of whatever comes next.
			if byte < lower || byte > upper {
				resetDecoder()
				screen.print(Self.replacementCharacter)
				continue
			}

			lower = 0x80
			upper = 0xbf
			codePoint = (codePoint << 6) | UInt32(byte & 0x3f)
			seen += 1
			index += 1

			if seen == needed {
				let scalar = Unicode.Scalar(codePoint) ?? Self.replacementCharacter
				resetDecoder()
				screen.print(scalar)
			}
		} while start + index < chunk.count

		return index
	}

	private mutating func resetDecoder() {
		codePoint = 0
		needed = 0
		seen = 0
		lower = 0x80
		upper = 0xbf
	}

	// MARK: Escape

	private mutating func escape(_ byte: UInt8, _ screen: inout Screen) -> Int {
		switch byte {
		// ESC 7 → DECSC (Save Cursor)
		case 0x37:
			screen.saveCursor()

		// ESC 8 → DECRC (Restore Cursor)
		case 0x38:
			screen.restoreCursor()

		// ESC = → DECKPAM (Application Keypad Mode)
		case 0x3d:
			screen.applicationKeypad = true

		// ESC > → DECKPNM (Normal Keypad Mode)
		case 0x3e:
			screen.applicationKeypad = false

		// ESC D → IND (Index)
		case 0x44:
			screen.linefeed()

		// ESC E → NEL (Next Line)
		case 0x45:
			screen.column = 0
			screen.linefeed()

		// ESC H → HTS (Horizontal Tab Set)
		case 0x48:
			screen.setTabStop()

		// ESC I → HTJ (Horizontal Tab with Justification), treated as HT
		case 0x49:
			screen.tab()

		// ESC M → RI (Reverse Index)
		case 0x4d:
			screen.reverseLinefeed()

		// ESC N → SS2 (Single Shift 2): print the next character with G2.
		case 0x4e:
			screen.singleShift = 2

		// ESC O → SS3 (Single Shift 3): print the next character with G3.
		case 0x4f:
			screen.singleShift = 3

		// ESC Z → DECID (Identify Terminal), answered like primary DA
		case 0x5a:
			events.append(.data(deviceAttributesResponse))

		// ESC [ → CSI (Control Sequence Introducer)
		case 0x5b:
			privateMarker = nil
			parameters = []
			subParameters = []
			intermediates = []
			mode = .csi
			return 1

		// ESC ] → OSC (Operating System Command)
		case 0x5d:
			oscString = []
			mode = .osc
			return 1

		// ESC ^ → PM (Privacy Message), ESC _ → APC (Application Program Command)
		case 0x5e, 0x5f:
			mode = .string
			return 1

		// ESC c → RIS (Reset to Initial State)
		case 0x63:
			screen.reset()

		// 0x20–0x2f: intermediate bytes, like the ( of SCS, which a final byte
		// follows.
		case 0x20...0x2f:
			intermediates = [byte]
			mode = .escapeIntermediate
			return 1

		// Everything else is ignored: the C1 controls with no effect here (PAD,
		// HOP, BPH, NBH, SSA, ESA, VTS, PLD, PLU, PU1, PU2, STS, CCH, MW, SPA,
		// EPA, ST), DCS, which isn't supported, and bytes with no meaning.
		default:
			break
		}

		mode = .ground
		return 1
	}

	/// ESC, intermediate bytes, then a final byte, which may arrive in a later
	/// chunk.
	private mutating func escapeIntermediate(_ byte: UInt8, _ screen: inout Screen) -> Int {
		switch byte {
		// 0x20–0x2f: another intermediate byte.
		case 0x20...0x2f:
			intermediates.append(byte)
			return 1

		// 0x30–0x7e: the final byte.
		case 0x30...0x7e:
			// ESC ( ) * + → SCS (Select Character Set): designate a set into G0–G3.
			// Other sequences aren't supported.
			if intermediates.count == 1, (0x28...0x2b).contains(intermediates[0]),
				let charset = Charset(designation: byte)
			{
				screen.charsets[Int(intermediates[0]) - 0x28] = charset
			}
			mode = .ground
			return 1

		// CAN, SUB: abort the sequence.
		case 0x18, 0x1a:
			mode = .ground
			return 1

		// ESC: abort and begin a new escape sequence.
		case 0x1b:
			mode = .escape
			return 1

		// Other C0 controls and DEL are ignored.
		case 0x00...0x1f, 0x7f:
			return 1

		// 0x80 and above: abort, and leave the byte to the ground parser.
		default:
			mode = .ground
			return 0
		}
	}

	// MARK: CSI

	/// A count parameter: absent, empty and 0 all mean 1.
	private func count(_ index: Int) -> Int {
		guard index < parameters.count, let value = parameters[index], value != 0 else { return 1 }
		return value
	}

	/// The first parameter, or 0 if it's absent or empty.
	private var selector: Int { (parameters.first ?? nil) ?? 0 }

	/// Whether the sequence has no private marker and no intermediate bytes.
	private var plain: Bool { privateMarker == nil && intermediates.isEmpty }

	/// Cursor movement, editing and scrolling.
	private func edit(_ final: UInt8, _ screen: inout Screen) {
		let n = count(0)

		switch final {
		case 0x40: screen.insertCharacters(n)  // ICH
		case 0x41: screen.moveBy(-n, 0)  // CUU
		case 0x42, 0x65: screen.moveBy(n, 0)  // CUD, VPR
		case 0x43, 0x61: screen.moveBy(0, n)  // CUF, HPR
		case 0x44: screen.moveBy(0, -n)  // CUB
		case 0x45:  // CNL
			screen.moveBy(n, 0)
			screen.column = 0
		case 0x46:  // CPL
			screen.moveBy(-n, 0)
			screen.column = 0
		case 0x47, 0x60: screen.moveTo(screen.row, n - 1)  // CHA, HPA
		case 0x48, 0x66: screen.setCursorPosition(n - 1, count(1) - 1)  // CUP, HVP
		case 0x4a: screen.eraseInDisplay(selector)  // ED
		case 0x4b: screen.eraseInLine(selector)  // EL
		case 0x4c: screen.insertLines(n)  // IL
		case 0x4d: screen.deleteLines(n)  // DL
		case 0x50: screen.deleteCharacters(n)  // DCH
		case 0x58: screen.eraseCharacters(n)  // ECH
		case 0x53: screen.scrollUp(n)  // SU
		case 0x54: screen.scrollDown(n)  // SD
		case 0x64: screen.setCursorPosition(n - 1, screen.cursorColumn)  // VPA
		case 0x72:  // DECSTBM
			let bottom = parameters.count > 1 ? parameters[1] ?? 0 : 0
			screen.setScrollRegion(n - 1, (bottom != 0 ? bottom : screen.rows) - 1)
		case 0x49:  // CHT
			for _ in 0..<min(n, screen.columns) { screen.tab() }
		case 0x5a:  // CBT
			for _ in 0..<min(n, screen.columns) { screen.backTab() }
		case 0x62: screen.repeat(n)  // REP
		case 0x67: screen.clearTabStops(selector)  // TBC
		default: break
		}
	}

	/// SGR's parameters, each with the sub-parameters that follow it.
	private var groups: [[Int?]] {
		var result: [[Int?]] = []
		for (index, parameter) in parameters.enumerated() {
			if subParameters[index] && !result.isEmpty {
				result[result.count - 1].append(parameter)
			} else {
				result.append([parameter])
			}
		}
		return result
	}

	private mutating func csi(_ byte: UInt8, _ screen: inout Screen) -> Int {
		// Only SGR takes sub-parameters. Any other sequence with them is ignored.
		if byte >= 0x40 && byte <= 0x7e && byte != 0x6d && subParameters.contains(true) {
			mode = .ground
			return 1
		}

		switch byte {
		// Intentionally ignored: NUL, SOH, STX, ETX, EOT, ENQ, ACK, DLE, DC1
		// (XON), DC2, DC3 (XOFF), DC4, NAK, SYN, ETB, EM, FS, GS, RS, US and DEL.
		case 0x00...0x06, 0x10...0x17, 0x19, 0x1c...0x1f, 0x7f:
			break

		// BEL (bell)
		case 0x07:
			events.append(.bell)

		// BS (backspace)
		case 0x08:
			screen.backspace()

		// HT (horizontal tab)
		case 0x09:
			screen.tab()

		// LF (line feed), VT (vertical tab), FF (form feed)
		case 0x0a, 0x0b, 0x0c:
			screen.linefeed()

		// CR (carriage return)
		case 0x0d:
			screen.column = 0

		// SO (shift out): print with G1.
		case 0x0e:
			screen.shift = 1

		// SI (shift in): print with G0.
		case 0x0f:
			screen.shift = 0

		// CAN (cancel), SUB (substitute): abort the sequence.
		case 0x18, 0x1a:
			mode = .ground

		// ESC (escape): abort and begin a new escape sequence.
		case 0x1b:
			mode = .escape

		// Cursor movement, editing and scrolling. Marked and intermediate forms,
		// like DECSED (CSI ? J) and XTRESTORE (CSI ? r), are something else
		// entirely and are ignored.

		// CSI T → SD (Scroll Down). With more than one parameter, it's xterm's
		// mouse highlight tracking instead, which is ignored.
		case 0x54:
			if plain && parameters.count <= 1 { edit(byte, &screen) }
			mode = .ground

		// ICH, CUU, CUD, CUF, CUB, CNL, CPL, CHA, CUP, CHT, ED, EL, IL, DL, DCH,
		// SU, ECH, CBT, HPA, HPR, REP, VPA, VPR, HVP, TBC and DECSTBM.
		case 0x40...0x4d, 0x50, 0x53, 0x58, 0x5a, 0x60...0x62, 0x64...0x67, 0x72:
			if plain { edit(byte, &screen) }
			mode = .ground

		// CSI s → SCOSC (Save Cursor), CSI u → SCORC (Restore Cursor): like
		// DECSC and DECRC. With parameters, CSI s is DECSLRM (Set Left and Right
		// Margins), which isn't supported; the marked forms of CSI u are the
		// kitty keyboard protocol's, which are ignored.
		case 0x73, 0x75:
			if plain && parameters.isEmpty {
				if byte == 0x73 { screen.saveCursor() } else { screen.restoreCursor() }
			}
			mode = .ground

		// CSI t → XTWINOPS (Window Manipulation). Only 22 and 23 are supported:
		// they save and restore the title. Their second parameter picks the
		// icon name (1), the title (2) or both (0, the default); there's no icon
		// name, so 1 does nothing. The rest, like resizing the window or
		// reporting its size, are ignored.
		case 0x74:
			if plain {
				let operation = parameters.first ?? nil
				let which = parameters.count > 1 ? parameters[1] ?? 0 : 0
				if which != 1 {
					if operation == 22 {
						screen.pushTitle()
					} else if operation == 23 {
						screen.popTitle()
					}
				}
			}
			mode = .ground

		// CSI SP q → DECSCUSR (Set Cursor Style). Other forms of CSI q, like
		// XTVERSION (CSI > q), are ignored.
		case 0x71:
			if privateMarker == nil && intermediates == [0x20] && parameters.count <= 1 {
				screen.setCursorStyle(selector)
			}
			mode = .ground

		// CSI m → SGR (Select Graphic Rendition). Marked forms, like XTMODKEYS
		// (CSI > m), are something else entirely and are ignored.
		case 0x6d:
			if plain { screen.selectGraphicRendition(groups) }
			mode = .ground

		// CSI h → SM (Set Mode), CSI l → RM (Reset Mode). Only the private (?)
		// forms, DECSET and DECRST, are supported.
		case 0x68, 0x6c:
			if privateMarker == 0x3f && intermediates.isEmpty {
				for case let parameter? in parameters {
					screen.setPrivateMode(parameter, byte == 0x68)
				}
			}
			mode = .ground

		// CSI n → DSR (Device Status Report): 5 asks if the terminal is OK, and 6
		// for the cursor position. Marked forms are different reports and are
		// ignored.
		case 0x6e:
			if plain {
				let report = parameters.first ?? nil
				if report == 5 {
					events.append(.data(Array("\u{1b}[0n".utf8)))
				} else if report == 6 {
					let position = "\u{1b}[\(screen.cursorRow + 1);\(screen.cursorColumn + 1)R"
					events.append(.data(Array(position.utf8)))
				}
			}
			mode = .ground

		// CSI c → DA (Device Attributes), only for a request with parameter 0:
		// plain for the primary report, marked with > for the secondary one.
		case 0x63:
			if intermediates.isEmpty && selector == 0 {
				if privateMarker == nil {
					events.append(.data(deviceAttributesResponse))
				} else if privateMarker == 0x3e {
					events.append(.data(secondaryDeviceAttributesResponse))
				}
			}
			mode = .ground

		// Intentionally ignored: the other final bytes, which have no assigned
		// meaning.
		case 0x40...0x7e:
			mode = .ground

		// 0x20–0x2f: intermediate bytes.
		case 0x20...0x2f:
			mode = .csiIntermediate
			return 0

		// 0x30–0x3b: parameter bytes, malformed after an intermediate.
		case 0x30...0x3b:
			mode = intermediates.isEmpty ? .csiParam : .ground
			return 0

		// 0x3c–0x3f: private markers, only valid before anything else.
		case 0x3c...0x3f:
			if privateMarker != nil || !parameters.isEmpty || !intermediates.isEmpty {
				mode = .ground
				return 0
			}
			privateMarker = byte
			mode = .csiParam

		// 0x80 and above: unexpected byte within the sequence.
		default:
			mode = .ground
		}

		return 1
	}

	private mutating func csiIntermediate(_ chunk: UnsafeBufferPointer<UInt8>, _ start: Int) -> Int {
		var index = 0

		repeat {
			let byte = chunk[start + index]

			// 0x20–0x2f: collect intermediate bytes.
			if byte >= 0x20 && byte <= 0x2f {
				intermediates.append(byte)
				index += 1
				continue
			}

			// 0x30–0x3f: parameter bytes may not follow intermediates. Malformed.
			if byte >= 0x30 && byte <= 0x3f {
				mode = .ground
				return index
			}

			// Anything else belongs to the csi parser.
			mode = .csi
			return index
		} while start + index < chunk.count

		return index
	}

	private mutating func csiParam(_ chunk: UnsafeBufferPointer<UInt8>, _ start: Int) -> Int {
		var index = 0

		repeat {
			let byte = chunk[start + index]

			// 0x30–0x39: a digit of the current parameter.
			if byte >= 0x30 && byte <= 0x39 {
				if parameters.isEmpty {
					parameters.append(nil)
					subParameters.append(false)
				}
				let last = parameters.count - 1
				parameters[last] = min((parameters[last] ?? 0) * 10 + Int(byte - 0x30), parameterLimit)
				index += 1
				continue
			}

			// 0x3b: the parameter separator, and 0x3a, the sub-parameter separator.
			if byte == 0x3b || byte == 0x3a {
				if parameters.isEmpty {
					parameters.append(nil)
					subParameters.append(false)
				}
				parameters.append(nil)
				subParameters.append(byte == 0x3a)
				index += 1
				continue
			}

			// Anything else belongs to the csi parser.
			mode = .csi
			return index
		} while start + index < chunk.count

		return index
	}

	// MARK: OSC

	/// Run a complete OSC string: a number, then ; and its text.
	private mutating func dispatchOSC(_ screen: inout Screen) {
		mode = .ground

		let string = String(decoding: oscString, as: UTF8.self)
		guard let separator = string.firstIndex(of: ";") else { return }

		// OSC 0 sets the icon name and the window title, and OSC 2 just the
		// title. There's no icon name to set, so both set the title, and OSC 1,
		// which sets just the icon name, does nothing. A bare number, with no ;
		// for the text to follow, is ignored. So are the other commands.
		let command = string[..<separator]
		if command == "0" || command == "2" {
			screen.title = String(string[string.index(after: separator)...])
		}
	}

	private mutating func osc(
		_ chunk: UnsafeBufferPointer<UInt8>, _ start: Int, _ screen: inout Screen
	) -> Int {
		var index = 0

		repeat {
			let byte = chunk[start + index]

			// 0x20 and above: collect string bytes.
			if byte >= 0x20 {
				oscString.append(byte)
				index += 1
				continue
			}

			// BEL: terminates the string like ST does (an xterm extension).
			if byte == 0x07 {
				dispatchOSC(&screen)
				return index + 1
			}

			// CAN, SUB: abort the string.
			if byte == 0x18 || byte == 0x1a {
				mode = .ground
				return index + 1
			}

			// ESC: either ST or an escape sequence that aborts the string.
			if byte == 0x1b {
				mode = .oscEscape
				return index + 1
			}

			// Other C0 controls are ignored.
			index += 1
		} while start + index < chunk.count

		return index
	}

	private mutating func oscEscape(_ byte: UInt8, _ screen: inout Screen) -> Int {
		// ESC \ → ST (String Terminator): the string is complete.
		if byte == 0x5c {
			dispatchOSC(&screen)
			return 1
		}

		// Anything else aborts the string and belongs to the escape parser.
		mode = .escape
		return 0
	}

	// MARK: PM and APC strings

	private mutating func string(_ chunk: UnsafeBufferPointer<UInt8>, _ start: Int) -> Int {
		var index = 0

		repeat {
			let byte = chunk[start + index]

			// CAN, SUB: abort the string.
			if byte == 0x18 || byte == 0x1a {
				mode = .ground
				return index + 1
			}

			// ESC: ends the string, whether as ST or as another escape sequence.
			if byte == 0x1b {
				mode = .escape
				return index + 1
			}

			// Everything else is consumed and discarded.
			index += 1
		} while start + index < chunk.count

		return index
	}
}
