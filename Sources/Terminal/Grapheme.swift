// Grapheme cluster segmentation per UAX #29 (Unicode 17.0), operating on
// decoded code points as a streaming state machine.
enum Grapheme {
	// Grapheme_Cluster_Break property values (bits 0-3 of a packed table entry).
	private static let carriageReturn = 1
	private static let lineFeed = 2
	private static let control = 3
	private static let extend = 4
	private static let zeroWidthJoiner = 5
	private static let regionalIndicator = 6
	private static let prepend = 7
	private static let spacingMark = 8
	private static let hangulLeading = 9
	private static let hangulVowel = 10
	private static let hangulTrailing = 11
	private static let hangulLVSyllable = 12
	private static let hangulLVTSyllable = 13

	// Indic_Conjunct_Break property values, as stored per code point (bits 4-5).
	private static let conjunctConsonant = 1
	private static let conjunctExtend = 2
	private static let conjunctLinker = 3

	// Running Indic-conjunct state carried between code points (state bits
	// 4-5): have we seen `Consonant [Extend Linker]*` (the consonant state) and
	// has a Linker appeared in that run yet (the linker state)? A following
	// Consonant joins only from the linker state (GB9c).
	private static let conjunctStateNone = 0
	private static let conjunctStateConsonant = 1
	private static let conjunctStateLinker = 2

	// Running emoji state carried between code points (state bits 6-7): are we
	// inside `\p{Extended_Pictographic} Extend*` (the pictographic state), and
	// has it been closed by a ZWJ (the pictographic-ZWJ state)? A following
	// Extended_Pictographic joins only from the pictographic-ZWJ state (GB11).
	private static let emojiStateNone = 0
	private static let emojiStatePictographic = 1
	private static let emojiStatePictographicZWJ = 2

	/// A resume token: a packed integer holding the previous code point's
	/// Grapheme_Cluster_Break value and the running conjunct, emoji and
	/// regional indicator context.
	typealias State = Int

	/// The start-of-text state.
	static let initial: State = 0

	/// The packed property value for a code point (0 is the default:
	/// Other, None, not an emoji).
	static func property(of scalar: Unicode.Scalar) -> Int {
		UnicodeTable.grapheme[scalar.value]
	}

	/// Whether there is a grapheme boundary between the code point summarised
	/// by `state` (the left side) and the code point whose packed property is
	/// `property` (the right side). Rules are evaluated in UAX #29 order; the
	/// first that applies decides.
	static func isBreak(_ state: State, _ property: Int) -> Bool {
		let left = state & 0xf
		let right = property & 0xf

		if left == carriageReturn && right == lineFeed { return false }  // GB3
		if left == carriageReturn || left == lineFeed || left == control { return true }  // GB4
		if right == carriageReturn || right == lineFeed || right == control { return true }  // GB5
		if left == hangulLeading
			&& (right == hangulLeading || right == hangulVowel || right == hangulLVSyllable
				|| right == hangulLVTSyllable)
		{
			return false  // GB6
		}
		if (left == hangulLVSyllable || left == hangulVowel)
			&& (right == hangulVowel || right == hangulTrailing)
		{
			return false  // GB7
		}
		if (left == hangulLVTSyllable || left == hangulTrailing) && right == hangulTrailing {
			return false  // GB8
		}
		if right == extend || right == zeroWidthJoiner { return false }  // GB9
		if right == spacingMark { return false }  // GB9a
		if left == prepend { return false }  // GB9b
		if (state >> 4) & 3 == conjunctStateLinker && (property >> 4) & 3 == conjunctConsonant {
			return false  // GB9c
		}
		if (state >> 6) & 3 == emojiStatePictographicZWJ && (property >> 6) & 1 == 1 {
			return false  // GB11
		}
		if right == regionalIndicator && (state >> 8) & 1 == 1 { return false }  // GB12, GB13
		return true  // GB999
	}

	/// Fold the code point with packed property `property` into the running
	/// `state`.
	static func advance(_ state: State, _ property: Int) -> State {
		let right = property & 0xf
		let incomingConjunct = (property >> 4) & 3

		var conjunct = (state >> 4) & 3
		if incomingConjunct == conjunctConsonant {
			conjunct = conjunctStateConsonant
		} else if conjunct != conjunctStateNone
			&& (incomingConjunct == conjunctExtend || incomingConjunct == conjunctLinker)
		{
			conjunct = incomingConjunct == conjunctLinker ? conjunctStateLinker : conjunct
		} else {
			conjunct = conjunctStateNone
		}

		var emoji = (state >> 6) & 3
		if (property >> 6) & 1 == 1 {
			emoji = emojiStatePictographic
		} else if right == extend && emoji == emojiStatePictographic {
			emoji = emojiStatePictographic
		} else if right == zeroWidthJoiner && emoji == emojiStatePictographic {
			emoji = emojiStatePictographicZWJ
		} else {
			emoji = emojiStateNone
		}

		let regionalParity = right == regionalIndicator ? ((state >> 8) & 1) ^ 1 : 0

		return right | (conjunct << 4) | (emoji << 6) | (regionalParity << 8)
	}
}
