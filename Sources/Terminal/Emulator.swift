import Foundation

/// Parses a program's output and applies it to a `TerminalState`.
///
/// Feed it a PTY's output as bytes with `write`. Chunks may split anywhere,
/// even inside an escape sequence or a UTF-8 character.
@MainActor
public final class Emulator {
	public let state: TerminalState

	/// Called when the output rings the bell (BEL).
	public var onBell: (() -> Void)?

	/// Called with the replies to the program's queries, such as device
	/// attributes. Send them to the PTY.
	public var onData: ((Data) -> Void)?

	private var parser = Parser()

	public init(
		state: TerminalState, onBell: (() -> Void)? = nil, onData: ((Data) -> Void)? = nil
	) {
		self.state = state
		self.onBell = onBell
		self.onData = onData
	}

	/// Parse a chunk of output.
	public func write(_ chunk: Data) {
		chunk.withUnsafeBytes { write($0.bindMemory(to: UInt8.self)) }
	}

	/// Parse a chunk of output.
	public func write(_ chunk: [UInt8]) {
		chunk.withUnsafeBufferPointer { write($0) }
	}

	/// Parse a chunk of output, as UTF-8.
	public func write(_ chunk: String) {
		var chunk = chunk
		chunk.withUTF8 { write($0) }
	}

	private func write(_ chunk: UnsafeBufferPointer<UInt8>) {
		guard !chunk.isEmpty else { return }
		state.mutate { parser.write(chunk, to: &$0) }

		// The handlers run once the state is settled, so they can read it.
		let events = parser.events
		parser.events = []
		for event in events {
			switch event {
			case .bell: onBell?()
			case .data(let bytes): onData?(Data(bytes))
			}
		}
	}
}
