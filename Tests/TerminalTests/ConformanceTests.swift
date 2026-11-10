import Foundation
import Testing

@testable import Terminal

// Replays the cases in Fixtures/conformance.json, which record the state
// terminal.svelte's emulator ends up in after parsing some output, and expects
// the very same state. See Conformance/README.md for how they're generated.

private struct Fixtures: Decodable {
	let probe: String
	let cases: [Case]
}

private struct Case: Decodable {
	let name: String
	let columns: Int
	let rows: Int
	let scrollbackLimit: Int
	let operations: [Operation]
	let after: Snapshot
	let probed: Snapshot
}

private struct Operation: Decodable {
	let write: String?
	let resize: [Double]?
}

private struct Snapshot: Decodable, Equatable {
	var columns: Int
	var rows: Int
	var column: Int
	var row: Int
	var style: String
	var blink: Bool
	var visible: Bool
	var alternate: Bool
	var title: String
	var autowrap: Bool
	var applicationCursor: Bool
	var applicationKeypad: Bool
	var bracketedPaste: Bool
	var buffer: [SnapshotLine]
	var scrollback: [SnapshotLine]
	var replies: String
	var bells: Int
}

private struct SnapshotLine: Decodable, Equatable {
	var wrapped: Bool
	var cells: [SnapshotCell]
}

// A number for a run of empty cells, or [text, attributes, width].
private enum SnapshotCell: Decodable, Equatable {
	case empty(Int)
	case written(String, String, Int)

	init(from decoder: Decoder) throws {
		if let count = try? decoder.singleValueContainer().decode(Int.self) {
			self = .empty(count)
			return
		}
		var container = try decoder.unkeyedContainer()
		self = .written(
			try container.decode(String.self), try container.decode(String.self),
			try container.decode(Int.self))
	}
}

private func bytes(_ hex: String) -> [UInt8] {
	var result: [UInt8] = []
	var index = hex.startIndex
	while index < hex.endIndex {
		let next = hex.index(index, offsetBy: 2)
		result.append(UInt8(hex[index..<next], radix: 16)!)
		index = next
	}
	return result
}

private func hex(_ bytes: [UInt8]) -> String {
	bytes.map { String($0, radix: 16).leftPadded() }.joined()
}

extension String {
	fileprivate func leftPadded() -> String { count < 2 ? "0" + self : self }
}

private func encode(_ color: CellColor?) -> String {
	switch color {
	case nil: ""
	case .palette(let index): "p\(index)"
	case .rgb(let red, let green, let blue): "r\(red),\(green),\(blue)"
	}
}

private func encode(_ attributes: Attributes) -> String {
	let flags = [
		attributes.bold, attributes.dim, attributes.italic, attributes.underline, attributes.blink,
		attributes.inverse, attributes.invisible, attributes.strikethrough,
	]
	let bits = flags.enumerated().reduce(0) { $0 | ($1.element ? 1 << $1.offset : 0) }
	return "\(encode(attributes.foreground))/\(encode(attributes.background))/\(bits)"
}

private func encode(_ line: Line) -> SnapshotLine {
	var cells: [SnapshotCell] = []
	for cell in line.cells {
		if let cell {
			cells.append(.written(cell.text, encode(cell.attributes), cell.width))
		} else if case .empty(let count) = cells.last {
			cells[cells.count - 1] = .empty(count + 1)
		} else {
			cells.append(.empty(1))
		}
	}
	return SnapshotLine(wrapped: line.wrapped, cells: cells)
}

@MainActor
private func snapshot(_ state: TerminalState, _ replies: [UInt8], _ bells: Int) -> Snapshot {
	Snapshot(
		columns: state.columns,
		rows: state.rows,
		column: state.column,
		row: state.row,
		style: state.cursorStyle == .block ? "block" : state.cursorStyle == .bar ? "bar" : "underline",
		blink: state.cursorBlink,
		visible: state.cursorVisible,
		alternate: state.alternate,
		title: state.title,
		autowrap: state.autowrap,
		applicationCursor: state.applicationCursor,
		applicationKeypad: state.applicationKeypad,
		bracketedPaste: state.bracketedPaste,
		buffer: state.buffer.map(encode),
		scrollback: state.scrollback.map(encode),
		replies: hex(replies),
		bells: bells)
}

/// What differs between two snapshots, in a few words.
private func difference(_ actual: Snapshot, _ expected: Snapshot) -> String {
	var fields: [String] = []
	func compare<Value: Equatable>(_ name: String, _ keyPath: KeyPath<Snapshot, Value>) {
		if actual[keyPath: keyPath] != expected[keyPath: keyPath] {
			fields.append("\(name): \(actual[keyPath: keyPath]) != \(expected[keyPath: keyPath])")
		}
	}
	compare("columns", \.columns)
	compare("rows", \.rows)
	compare("column", \.column)
	compare("row", \.row)
	compare("style", \.style)
	compare("blink", \.blink)
	compare("visible", \.visible)
	compare("alternate", \.alternate)
	compare("title", \.title)
	compare("autowrap", \.autowrap)
	compare("applicationCursor", \.applicationCursor)
	compare("applicationKeypad", \.applicationKeypad)
	compare("bracketedPaste", \.bracketedPaste)
	compare("replies", \.replies)
	compare("bells", \.bells)
	for (name, keyPath) in [("buffer", \Snapshot.buffer), ("scrollback", \Snapshot.scrollback)] {
		let (a, e) = (actual[keyPath: keyPath], expected[keyPath: keyPath])
		if a.count != e.count {
			fields.append("\(name): \(a.count) lines != \(e.count)")
		} else if let row = a.indices.first(where: { a[$0] != e[$0] }) {
			fields.append("\(name)[\(row)]: \(a[row]) != \(e[row])")
		}
	}
	return fields.joined(separator: "\n")
}

private let fixtures: Fixtures = {
	let url = Bundle.module.url(forResource: "Fixtures/conformance", withExtension: "json")!
	return try! JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
}()

@MainActor
@Suite struct ConformanceTests {
	/// Replay a case, writing each chunk whole or a byte at a time.
	private func replay(_ fixture: Case, bytewise: Bool) -> (after: Snapshot, probed: Snapshot) {
		var replies: [UInt8] = []
		var bells = 0
		let state = TerminalState(
			columns: fixture.columns, rows: fixture.rows, scrollbackLimit: fixture.scrollbackLimit)
		let emulator = Emulator(
			state: state, onBell: { bells += 1 }, onData: { replies.append(contentsOf: $0) })

		func write(_ chunk: [UInt8]) {
			if bytewise {
				for byte in chunk { emulator.write([byte]) }
			} else {
				emulator.write(chunk)
			}
		}

		for operation in fixture.operations {
			if let chunk = operation.write {
				write(bytes(chunk))
			} else if let size = operation.resize {
				state.resize(columns: Int(size[0].rounded(.down)), rows: Int(size[1].rounded(.down)))
			}
		}
		let after = snapshot(state, replies, bells)
		write(bytes(fixtures.probe))
		return (after, snapshot(state, replies, bells))
	}

	@Test func matchesTerminalSvelte() {
		#expect(fixtures.cases.count > 700)

		var failures = 0
		for fixture in fixtures.cases {
			for bytewise in [false, true] {
				let (after, probed) = replay(fixture, bytewise: bytewise)
				let mode = bytewise ? " (a byte at a time)" : ""
				if after != fixture.after {
					failures += 1
					if failures <= 10 {
						Issue.record("\(fixture.name)\(mode):\n\(difference(after, fixture.after))")
					}
				} else if probed != fixture.probed {
					failures += 1
					if failures <= 10 {
						Issue.record(
							"\(fixture.name)\(mode), after the probe:\n\(difference(probed, fixture.probed))")
					}
				}
			}
		}
		#expect(failures == 0)
	}
}
