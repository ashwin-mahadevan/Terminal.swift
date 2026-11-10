# Conformance

Terminal.swift is meant to behave exactly as
[terminal.svelte](https://github.com/ashwin-mahadevan/terminal.svelte) does.
`generate.unit.ts` runs terminal.svelte's emulator over cases written by hand
and several hundred random ones (output split anywhere, resizes, bytes that
aren't UTF-8) and records the state it ends up in: the screen, the scrollback,
the cursor, the modes, the title and the replies. `ConformanceTests.swift`
replays every case, whole and a byte at a time, and expects the same state.

Each case is followed by a probe: a run of queries and movements that brings
out the state a snapshot can't see, such as the tab stops, the scroll region
and the saved cursor.

## Regenerating the fixtures

Do this whenever terminal.svelte's emulator changes, then port the change until
the tests pass again. In a checkout of terminal.svelte:

```sh
cp path/to/Terminal.swift/Conformance/generate.unit.ts src/lib/conformance.unit.ts
CONFORMANCE_OUTPUT=path/to/Terminal.swift/Tests/TerminalTests/Fixtures/conformance.json \
	pnpm exec vitest run --project unit src/lib/conformance.unit.ts
rm src/lib/conformance.unit.ts
```

The cases are seeded, so the file only changes when the generator or the
emulator does.
