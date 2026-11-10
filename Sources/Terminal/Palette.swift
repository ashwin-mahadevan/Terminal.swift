#if canImport(SwiftUI)
	import SwiftUI

	/// The colors a terminal is drawn in: xterm's, unless they're replaced.
	///
	///     StreamTerminal(state: state)
	///         .terminalPalette(TerminalPalette(colors: [4: .blue]))
	public struct TerminalPalette: Equatable, Sendable {
		/// The color of text with no SGR color set.
		public var foreground: Color
		/// The color behind text with no SGR color set.
		public var background: Color
		/// Replacements for entries of the 256-color palette, by index.
		public var colors: [Int: Color]

		public init(
			foreground: Color = .white, background: Color = .black, colors: [Int: Color] = [:]
		) {
			self.foreground = foreground
			self.background = background
			self.colors = colors
		}

		/// The color for a 256-color palette index.
		public func color(_ index: Int) -> Color {
			if let color = colors[index] { return color }
			let (red, green, blue) = Self.defaultColor(index)
			return Color(red: red, green: green, blue: blue)
		}

		func color(_ color: CellColor) -> Color {
			switch color {
			case .palette(let index): self.color(Int(index))
			case .rgb(let red, let green, let blue): Color(red: red, green: green, blue: blue)
			}
		}

		// xterm's 16 standard and bright colors.
		private static let ansi: [UInt32] = [
			0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
			0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
		]

		// The six channel levels of the 6x6x6 color cube (indices 16–231).
		private static let cubeLevels: [UInt8] = [0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff]

		/// The default color for a 256-color palette index: the 16 ANSI colors,
		/// then the color cube, then a 24-step grayscale ramp (indices 232–255).
		static func defaultColor(_ index: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
			if index < 16 {
				let color = ansi[max(0, index)]
				return (UInt8(color >> 16), UInt8(color >> 8 & 0xff), UInt8(color & 0xff))
			}
			if index < 232 {
				let cube = index - 16
				return (cubeLevels[cube / 36], cubeLevels[cube / 6 % 6], cubeLevels[cube % 6])
			}
			let gray = UInt8(min(255, 8 + (index - 232) * 10))
			return (gray, gray, gray)
		}
	}

	extension Color {
		fileprivate init(red: UInt8, green: UInt8, blue: UInt8) {
			self.init(
				.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
		}
	}

	extension EnvironmentValues {
		/// The colors terminals are drawn in.
		@Entry public var terminalPalette = TerminalPalette()
	}

	extension View {
		/// Sets the colors terminals in this view are drawn in.
		public func terminalPalette(_ palette: TerminalPalette) -> some View {
			environment(\.terminalPalette, palette)
		}
	}
#endif
