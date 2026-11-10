// The terminal cell width of a grapheme cluster (Unicode 17.0), computed as a
// streaming fold over the code points of a single cluster.
//
// A rendered cluster occupies a whole number of terminal cells; in practice
// either one or two. Unicode does not define this number (it is a rendering
// convention), so this implements the behavior Ghostty uses when its grapheme
// mode (DEC mode 2027) is enabled: the cluster takes the width of its spacing
// base, promoted to two cells the moment a second advancing code point joins
// it. It is deliberately not the maximum of its code points' widths: a
// regional flag or an Indic consonant and spacing mark are two individually
// narrow code points that together occupy two cells.
//
// The first code point of a cluster is treated as its spacing base: a wide
// base (CJK, default-presentation emoji, fullwidth forms) opens a two-cell
// cluster, anything else a one-cell cluster. Each subsequent code point can
// only widen the cluster, or narrow it back with a text variation selector:
//
// - VS16 (U+FE0F) after a valid base forces emoji (wide) presentation.
// - VS15 (U+FE0E) after a valid base forces text (narrow) presentation.
// - Any other code point that carries its own advance (a spacing mark, a
//   second regional indicator, a ZWJ-joined pictograph) makes the cluster
//   wide. Combining marks, ZWJ and variation selectors carry no advance and
//   leave the width unchanged.
enum Width {
	// Packed per-code-point property bits (from the table).
	private static let wide = 1  // East_Asian_Width is W or F, or Emoji_Presentation.
	private static let nonContributing = 2  // Extend or ZWJ: carries no advance.
	private static let emojiVariationBase = 4  // In emoji-variation-sequences.txt.

	private static let variationSelector15: UInt32 = 0xfe0e  // Text (narrow) presentation.
	private static let variationSelector16: UInt32 = 0xfe0f  // Emoji (wide) presentation.

	/// A resume token: the cluster width accumulated so far (bits 0-1; 0 marks
	/// the start of a cluster) and whether the previous code point is a valid
	/// emoji variation base (bit 2, gating the variation selectors).
	typealias State = Int

	/// The start-of-cluster state.
	static let initial: State = 0

	/// Fold the code point into the running `state`, returning the next state
	/// and the cluster's width in cells so far. Reset to `initial` at each
	/// cluster boundary; the width returned for the last code point of a
	/// cluster is that cluster's final width.
	static func width(_ state: State, _ scalar: Unicode.Scalar) -> (state: State, cells: Int) {
		let property = UnicodeTable.width[scalar.value]
		let current = state & 3
		let previousIsVariationBase = (state >> 2) & 1 == 1

		let next: Int
		if current == 0 {
			// First code point: the cluster's spacing base sets the initial width.
			next = property & wide != 0 ? 2 : 1
		} else if scalar.value == variationSelector16 && previousIsVariationBase {
			next = 2
		} else if scalar.value == variationSelector15 && previousIsVariationBase {
			next = 1
		} else if property & nonContributing == 0 {
			// A joining code point that carries its own advance widens the cluster.
			next = 2
		} else {
			// A combining mark, ZWJ, or inapplicable variation selector: no change.
			next = current
		}

		return (next | ((property & emojiVariationBase != 0 ? 1 : 0) << 2), next)
	}
}
