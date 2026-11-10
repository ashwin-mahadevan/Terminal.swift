import Testing

@testable import Terminal

@Suite struct PaletteTests {
	private func hex(_ index: Int) -> String {
		let (red, green, blue) = TerminalPalette.defaultColor(index)
		return [red, green, blue].map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
	}

	@Test func hasXtermsColors() {
		#expect(hex(0) == "000000")
		#expect(hex(1) == "cd0000")
		#expect(hex(12) == "5c5cff")
		#expect(hex(15) == "ffffff")
	}

	@Test func hasTheColorCube() {
		#expect(hex(16) == "000000")
		#expect(hex(21) == "0000ff")
		#expect(hex(196) == "ff0000")
		#expect(hex(110) == "87afd7")
		#expect(hex(231) == "ffffff")
	}

	@Test func hasTheGrayscaleRamp() {
		#expect(hex(232) == "080808")
		#expect(hex(255) == "eeeeee")
	}
}
