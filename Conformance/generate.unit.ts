// Generates Tests/TerminalTests/Fixtures/conformance.json: terminal output,
// and the state terminal.svelte's emulator ends up in after parsing it. The
// Swift tests replay each case and expect the very same state.
//
// It runs inside a checkout of terminal.svelte, as one of its unit tests. See
// Conformance/README.md.
import { writeFileSync } from 'node:fs';
import { expect, it } from 'vitest';
import { Parser } from './parser/state-machine.svelte';
import { State } from './state.svelte';
import type { Attributes, Color, Line } from './state.svelte';

type Operation = { write: string } | { resize: [number, number] };

const encoder = new TextEncoder();
const hex = (bytes: Uint8Array | Array<number>) =>
	Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');

// A color as p<index> or r<red>,<green>,<blue>, and nothing for the default.
const color = (c: Color) =>
	c === null ? '' : c.type === 'palette' ? `p${c.index}` : `r${c.r},${c.g},${c.b}`;

const FLAGS = [
	'bold',
	'dim',
	'italic',
	'underline',
	'blink',
	'inverse',
	'invisible',
	'strikethrough'
] as const;

// Attributes as <foreground>/<background>/<flags>, the flags a bit set in the
// order above.
const attributes = (a: Attributes) =>
	`${color(a.foreground)}/${color(a.background)}/${FLAGS.reduce(
		(bits, flag, index) => bits | (a[flag] ? 1 << index : 0),
		0
	)}`;

// A line as whether it wraps, then its cells: a number for a run of empty
// cells, and [text, attributes, width] for a written one.
function line(l: Line) {
	const cells: Array<number | [string, string, number]> = [];
	for (let column = 0; column < l.cells.length; column += 1) {
		const cell = l.cells[column];
		const last = cells[cells.length - 1];
		if (cell === undefined) {
			if (typeof last === 'number') cells[cells.length - 1] = last + 1;
			else cells.push(1);
		} else {
			cells.push([cell.text, attributes(cell.attrs), cell.width ?? 1]);
		}
	}
	return { wrapped: l.break, cells };
}

function snapshot(state: State, replies: Array<number>, bells: number) {
	return {
		columns: state.columns,
		rows: state.rows,
		column: state.column,
		row: state.row,
		style: state.style,
		blink: state.cursorBlink,
		visible: state.cursorVisible,
		alternate: state.alternate,
		title: state.title,
		autowrap: state.autowrap,
		applicationCursor: state.applicationCursor,
		applicationKeypad: state.applicationKeypad,
		bracketedPaste: state.bracketedPaste,
		buffer: state.buffer.map(line),
		scrollback: state.scrollback.map(line),
		replies: hex(replies),
		bells
	};
}

// Written after each case, to bring out the state a snapshot can't see: the
// saved cursor, origin mode, the scroll region, the tab stops, the character
// sets, the last character printed and the title stack.
const PROBE =
	'\x1b[6n\x1b[bq#\x0eq#\x0f\x1bNq\x1bOq\x1b8\x1b[6n\r\t\x1b[6n\t\x1b[6n\t\x1b[6n' +
	'\x1b[99A\x1b[6n\x1b[99B\x1b[6n\n\n\x1b[?6l\x1b[6n\x1b[?47h\x1b8\x1b[6nX\x1b[?47l\x1b[3bY' +
	'\x1b[23t\x1b[23t';

function run(
	name: string,
	columns: number,
	rows: number,
	scrollbackLimit: number,
	operations: Array<Operation>
) {
	const replies: Array<number> = [];
	let bells = 0;
	const state = new State(columns, rows, { scrollbackLimit });
	const parser = new Parser(state, {
		bell: () => (bells += 1),
		ondata: (chunk) => replies.push(...chunk)
	});

	for (const operation of operations) {
		if ('write' in operation) {
			const bytes = operation.write.match(/../g)?.map((byte) => parseInt(byte, 16)) ?? [];
			parser.write(Uint8Array.from(bytes));
		} else {
			state.resize(...operation.resize);
		}
	}
	const after = snapshot(state, replies, bells);
	parser.write(encoder.encode(PROBE));
	const probed = snapshot(state, replies, bells);

	return { name, columns, rows, scrollbackLimit, operations, after, probed };
}

// Scenarios written by hand: [name, columns, rows, scrollback limit, then
// strings to write and [columns, rows] to resize to].
type Scenario = [string, number, number, number, ...Array<string | [number, number]>];

const E = '\x1b';
const SCENARIOS: Array<Scenario> = [
	['plain text', 10, 4, 5, 'hello'],
	['wrap', 4, 4, 5, 'ABCDEFGHIJ'],
	['pending wrap then LF', 4, 4, 5, 'ABCD\nX'],
	['pending wrap then CR', 4, 4, 5, 'ABCD\rX'],
	['pending wrap then BS', 4, 4, 5, 'ABCD\bX'],
	['autowrap off', 4, 4, 5, `${E}[?7lABCDEF${E}[?7hGH`],
	['scrolling into scrollback', 5, 3, 4, '1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9'],
	['no scrollback', 5, 3, 0, '1\r\n2\r\n3\r\n4\r\n5'],
	['controls', 10, 4, 5, 'a\x00b\x07c\x0bd\x0ce\x7ff\x1cg\ti\bj'],
	['tabs', 20, 2, 5, `\tA\tB\tC\tD${E}[2ZE${E}[3IF`],
	['tab stops', 20, 2, 5, `${E}[3g   ${E}H     ${E}H\r\tA\tB\tC\r${E}[5C${E}[g\r\tD`],
	['HTJ and HTS at a pending wrap', 4, 3, 5, `ABCD${E}H${E}IX\r\tY`],
	['save and restore', 10, 4, 5, `ab${E}7${E}[31;1m\r\ncd${E}8ef`],
	['restore with nothing saved', 10, 4, 5, `${E}[31mab\r\ncd${E}8ef`],
	['SCOSC and SCORC', 10, 4, 5, `ab${E}[s\r\ncd${E}[uef${E}[1;2s${E}[?u`],
	['keypad', 10, 4, 5, `${E}=`],
	['device attributes', 10, 4, 5, `${E}[c${E}[0c${E}[1c${E}[>c${E}[>0c${E}[=c${E}Z${E}[ c`],
	['device status', 10, 4, 5, `ab\r\ncd${E}[5n${E}[6n${E}[?6n${E}[2;4r${E}[?6h${E}[2;2H${E}[6n`],
	['private modes', 10, 4, 5, `${E}[?1;25;2004;12;9999h${E}[?25l`],
	['unsupported modes', 10, 4, 5, `${E}[4h${E}[20h${E}[?1000hA${E}[?;1hB`],
	['alternate 47', 6, 3, 5, `abc${E}[?47hXY${E}[?47lZ`],
	['alternate 1047', 6, 3, 5, `abc${E}[?1047hXY${E}[?1047l${E}[?47hW${E}[?47lZ`],
	['alternate 1049', 6, 3, 5, `abc${E}[31m${E}[?1049hXY\r\nQ${E}[0m${E}[?1049lZ`],
	['alternate does not scroll back', 6, 3, 5, `a\r\nb${E}[?1049h1\r\n2\r\n3\r\n4\r\n5${E}[?1049l`],
	['alternate with a background', 6, 3, 5, `${E}[44m${E}[?1049hX${E}[?1049l${E}[?1047h${E}[?1047l`],
	['cursor save 1048', 6, 3, 5, `ab${E}[?1048h\r\ncd${E}[?1048lX`],
	['cursor style', 6, 3, 5, `${E}[5 q${E}[?12l`],
	['cursor style steady underline', 6, 3, 5, `${E}[4 q`],
	['cursor style out of range', 6, 3, 5, `${E}[3 q${E}[7 q${E}[1;2 q${E}[>q${E}[q`],
	['cursor style reset', 6, 3, 5, `${E}[5 q${E}[ q`],
	['repeat', 8, 3, 5, `a${E}[3b${E}[bX${E}[0b`],
	['repeat a wide character', 8, 3, 5, `漢${E}[2b`],
	['repeat a cluster', 8, 3, 5, `é${E}[2b`],
	['repeat after reset', 8, 3, 5, `a${E}c${E}[3bZ`],
	['repeat a huge count', 3, 2, 2, `a${E}[99999999999999999999b`],
	['charsets', 12, 3, 5, `${E}(0lqk${E}(Bx${E})0\x0elq\x0fx${E}(A#a${E}(B#`],
	['single shifts', 12, 3, 5, `${E}*0${E}+A${E}Nqq${E}O##${E}N\r\nq`],
	['unknown charsets', 12, 3, 5, `${E}(Zq${E}(0q${E}( 0q${E}#8q${E}(\x18q${E}(${E}(Bq${E}(\xc3\xa9`],
	['charsets and save', 12, 3, 5, `${E}(0${E}7${E}(B\x0e${E}8q`],
	['sgr', 12, 3, 5, `${E}[1;2;3;4;5;7;8;9mA${E}[22;23;24;25;27;28;29mB${E}[21;6mC${E}[mD`],
	['sgr colors', 12, 3, 5, `${E}[31;42mA${E}[91;102mB${E}[39mC${E}[49mD${E}[37;40;97;107mE`],
	['sgr 256', 12, 3, 5, `${E}[38;5;200;48;5;17mA${E}[38;5;256mB${E}[38;5mC${E}[0;38;5;1;1mD`],
	['sgr rgb', 12, 3, 5, `${E}[38;2;1;2;3mA${E}[48;2;255;0;256mB${E}[38;2;1;2mC${E}[38;9;1mD`],
	['sgr 58', 12, 3, 5, `${E}[58;5;1;1mA${E}[0;58;2;1;2;3;4mB${E}[0;58:5:1;3mC`],
	['sgr colons', 12, 3, 5, `${E}[4:3mA${E}[4:0mB${E}[4:6mC${E}[38:5:9mD${E}[38:2:1:2:3mE`],
	['sgr colon spaces', 12, 3, 5, `${E}[38:2::1:2:3mA${E}[48:2:9:1:2:300mB${E}[38:5mC${E}[1:2mD`],
	['sgr colon edge cases', 12, 3, 5, `${E}[:1mA${E}[38:2:1:2mB${E}[4:mC${E}[0:1mD${E}[38:5:;1mE`],
	['sgr empty parameters', 12, 3, 5, `${E}[1;;3mA${E}[;mB${E}[1;mC${E}[>1mD${E}[1 mE`],
	['colons outside sgr', 12, 3, 5, `ab${E}[1:2Hc${E}[2:1Ad`],
	['cursor movement', 10, 5, 5, `${E}[3;4HA${E}[2AB${E}[BC${E}[3DD${E}[2CE${E}[EF${E}[2FG${E}[5GH`],
	['cursor positions', 10, 5, 5, `${E}[99;99HA${E}[;HB${E}[2dC${E}[4\`D${E}[2aE${E}[eF${E}[2;3fG`],
	['cursor movement from a pending wrap', 4, 3, 5, `ABCD${E}[DX${E}[4GY${E}[CZ${E}[dW`],
	['erase in display', 5, 4, 5, `aaaaa\r\nbbbbb\r\nccccc${E}[2;3H${E}[J${E}[4;1Hddd`],
	['erase in display 1', 5, 4, 5, `aaaaa\r\nbbbbb\r\nccccc${E}[2;3H${E}[1J`],
	['erase in display 2 and 3', 5, 3, 5, `a\r\nb\r\nc\r\nd\r\ne${E}[2J${E}[3J${E}[4J`],
	['erase with a background', 5, 3, 5, `abcde${E}[43m${E}[1;2H${E}[K${E}[2;1H${E}[2K${E}[3;3H${E}[1K`],
	['erase in line', 5, 3, 5, `abcde\r${E}[2C${E}[K\r\nabcde\r${E}[2C${E}[1K\r\nabcde${E}[2K${E}[3K`],
	['erase unwraps', 4, 3, 5, `ABCDEFGH${E}[1;1H${E}[K${E}[2;4H${E}[1K`],
	['erase characters', 6, 3, 5, `abcdef\r${E}[C${E}[2X${E}[99X\r\nabcdef${E}[X`],
	['insert and delete characters', 6, 3, 5, `abcdef\r${E}[C${E}[2@\r\nabcdef\r${E}[C${E}[2P${E}[99@`],
	['insert and delete at a pending wrap', 4, 3, 5, `ABCD${E}[@\r\nABCD${E}[P\r\nABCD${E}[99P`],
	['insert and delete lines', 4, 5, 5, `a\r\nb\r\nc\r\nd\r\ne${E}[2;2H${E}[2L${E}[4;1H${E}[M${E}[99L`],
	['lines in a region', 4, 6, 5, `1\r\n2\r\n3\r\n4\r\n5\r\n6${E}[2;4r${E}[3;1H${E}[L${E}[M${E}[9M${E}[6;1H${E}[L`],
	['scroll region', 4, 5, 5, `1\r\n2\r\n3\r\n4\r\n5${E}[2;4r${E}[4;1H\nX\n\nY${E}[2;1H${E}MZ`],
	['scroll region limits', 4, 5, 5, `${E}[3;3rA${E}[4;2rB${E}[;99rC${E}[0;0rD${E}[2;rE${E}[?2;3rF`],
	['scroll up and down', 4, 4, 5, `1\r\n2\r\n3\r\n4${E}[S${E}[2T${E}[99S${E}[1;2;3;4;5TX`],
	['scrolling a region off the top', 4, 4, 5, `1\r\n2\r\n3\r\n4${E}[1;2r${E}[2;1H\n\n${E}[3S`],
	['linefeed below a region', 4, 5, 5, `${E}[1;2r${E}[5;1HA\nB\n${E}[3A${E}[5BC${E}[9AD`],
	['index, next line and reverse index', 4, 3, 5, `ab${E}Dc${E}Ed${E}M${E}M${E}M${E}Me`],
	['origin mode', 6, 6, 5, `${E}[2;4r${E}[?6hA${E}[9;9HB${E}[2;2HC${E}[6n${E}[?6lD${E}[5dE`],
	['origin mode and save', 6, 6, 5, `${E}[2;4r${E}[?6h${E}7${E}[?6l${E}[r${E}8${E}[1;1HA`],
	['reset', 6, 3, 2, `1\r\n2\r\n3\r\n4${E}[31m${E}[?1049h${E}]0;t\x07${E}[2 q${E}(0${E}cq`],
	['osc titles', 8, 3, 5, `${E}]0;one\x07${E}]2;two${E}\\${E}]1;icon\x07${E}]0\x07${E}]2;a;b\x07`],
	['osc aborts', 8, 3, 5, `${E}]0;no\x18A${E}]0;no\x1aB${E}]0;no${E}[31mC${E}]0;n\x00o\x07`],
	['osc utf-8', 8, 3, 5, `${E}]0;tït漢😀\x07${E}]2;\xff\x07`],
	['osc unknown', 8, 3, 5, `${E}]52;c;aGk=\x07${E}]0;\x07${E}];x\x07`],
	['title stack', 8, 3, 5, `${E}]0;a\x07${E}[22t${E}]0;b\x07${E}[22;2t${E}]0;c\x07${E}[23t${E}[23;1t${E}[23;0t${E}[23t`],
	['title stack limit', 8, 3, 5, Array.from({ length: 12 }, (_, i) => `${E}]0;${i}\x07${E}[22t`).join('') + `${E}[23t`.repeat(11)],
	['strings', 8, 3, 5, `a${E}^secret${E}\\b${E}_apc\x07still${E}\\c${E}Pq${E}\\d${E}^x\x18e${E}^y${E}[31mf`],
	['c1 escapes', 8, 3, 5, `a${E}@b${E}Fc${E}\\d${E}Ve${E}Xf${E}af`],
	['csi aborts', 8, 3, 5, `a${E}[3\x18Cb${E}[3\x1aCc${E}[3${E}[2Cd${E}[1\nCe${E}[\bf`],
	['csi malformed', 8, 4, 5, `${E}[1 2Ca${E}[ ?b${E}[1?c${E}[??d${E}[1;2 \x80e${E}[\xc3\xa9f${E}[ ;g`],
	['csi ignored finals', 8, 3, 5, `${E}[1Na${E}[?Jb${E}[?1Kc${E}[>4;1md${E}[=1ue${E}[!pf${E}[1$~g`],
	['csi controls inside', 8, 3, 5, `ab${E}[\r1Cc${E}[2\tDd${E}[\x0e\x0f\x07e`],
	['utf-8', 10, 3, 5, 'héllo 漢字 €'],
	['utf-8 invalid', 10, 3, 5, [0x61, 0xff, 0x62, 0xc3, 0x63, 0xe2, 0x82, 0x64, 0xc0, 0xaf, 0xed, 0xa0, 0x80, 0xf5].map((b) => String.fromCharCode(b)).join('')],
	['wide characters', 6, 3, 5, '漢字漢字x'],
	['wide at the edge', 5, 3, 5, 'abcd漢e'],
	['wide with autowrap off', 5, 3, 5, `${E}[?7labcd漢e`],
	['wide on one column', 1, 3, 5, 'a漢b', [3, 3]],
	['overwriting halves of a wide character', 6, 3, 5, `漢字\ra\r\n漢字\r${E}[Cb\r\n漢${E}[2D${E}[C字`],
	['erasing halves of a wide character', 6, 4, 5, `漢字\r${E}[C${E}[X\r\n漢字\r${E}[P\r\n漢字\r${E}[C${E}[@\r\n漢字${E}[2D${E}[1K`],
	['combining marks', 6, 3, 5, 'éǟ́x'],
	['a mark with nothing before it', 6, 3, 5, '́a\r\ń'],
	['a mark after an erase', 6, 3, 5, `a${E}[D${E}[X${E}[Ć`],
	['a mark at a pending wrap', 3, 3, 5, 'abćd'],
	['a mark with autowrap off', 3, 3, 5, `${E}[?7labć̂d${E}[2Gx́`],
	['emoji', 8, 3, 5, '😀a❤️b❤︎c☺'],
	['emoji sequences', 8, 3, 5, '👨‍👩‍👧 🇺🇸🇫 👍🏽'],
	['widening at the edge', 4, 3, 5, 'abc❤️d'],
	['widening at the edge, autowrap off', 4, 3, 5, `${E}[?7labc❤️d`],
	['widening over a wide character', 6, 3, 5, `❤漢${E}[3D❤${E}[D${E}[C️`],
	['narrowing', 6, 3, 5, '☺️︎x\r\n😀︎y'],
	['hangul and indic', 8, 3, 5, '각 각 क्ष का'],
	['latin-1 never joins', 6, 3, 5, 'a­b é'],
	['wider', 4, 4, 10, 'ABCDEFGHIJ', [8, 4]],
	['narrower', 8, 4, 10, 'ABCDEFGHIJ', [3, 4]],
	['narrower then wider', 8, 4, 10, 'ABCDEFGHIJ\r\nxy', [3, 4], [5, 4], [20, 4]],
	['shorter', 4, 4, 10, '1\r\n2\r\n3\r\n4', [4, 2]],
	['shorter with blank lines below', 4, 4, 10, '1\r\n2', [4, 2], [4, 1]],
	['taller', 4, 2, 10, '1\r\n2\r\n3\r\n4', [4, 4], [4, 9]],
	['resize at a pending wrap', 4, 3, 10, 'ABCD', [5, 3], [4, 3], [2, 3]],
	['resize with the cursor past the text', 6, 3, 10, `ab${E}[5G`, [3, 3], [8, 3]],
	['resize with a saved cursor', 6, 3, 10, `abcdefgh${E}7\r\nij`, [3, 3], [10, 2]],
	['resize with wide characters', 6, 3, 10, '漢字漢字漢', [5, 3], [3, 3], [1, 3], [7, 3]],
	['resize the alternate screen', 6, 3, 10, `abcdefgh${E}7${E}[?1049hXYZ漢字\r\nw${E}7`, [3, 2], [5, 4], `${E}[?1049l`],
	['resize the alternate screen with blank lines', 6, 4, 10, `${E}[?47hA\r\nB`, [6, 2], [6, 1], [6, 5]],
	['resize a scroll region', 6, 4, 10, `${E}[2;3r${E}[?6h`, [6, 5], 'A\n\n\nB'],
	['resize tab stops', 10, 2, 10, `${E}[3g  ${E}H`, [30, 2], '\r\tA\tB\tC\tD', [4, 2], [12, 2], '\r\tE\tF'],
	['resize with a limited scrollback', 4, 2, 2, 'ABCDEFGHIJKLMNOP', [2, 2], [8, 2]],
	['resize with colors', 6, 3, 10, `${E}[41mab${E}[K\r\n${E}[0mcd`, [3, 3], [9, 3]],
	['resize to nothing', 4, 2, 10, 'abc', [0, 0], [4.7, 2.2]]
];

// Mulberry32: a small seeded generator, so the cases are the same every run.
function random(seed: number) {
	return () => {
		seed = (seed + 0x6d2b79f5) | 0;
		let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
		t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

const TEXT = [
	'a', 'b', 'xyz', 'hello', ' ', '  ', 'q', '#', 'lqqk', '~', 'W',
	'é', '£', '­', '漢', '字漢', 'ｗｉ', '😀',
	'👨‍👩‍👧', '🇺🇸', '🇺',
	'é', '́', '̈̄', '❤️', '❤', '️', '︎', '☺',
	'‍', 'क्ष', 'क', 'ा', 'ᄀ', 'ᅡ', 'ᆨ', '가',
	'👍', '🏽', '€', '─', '​', '؀', '�', '　'
];
const CONTROLS = ['\b', '\t', '\n', '\r', '\r\n', '\r\n', '\x0b', '\x0c', '\x0e', '\x0f', '\x07', '\x18', '\x1a', '\x00', '\x7f'];
const ESCAPES = [
	'7', '8', '=', '>', 'D', 'E', 'H', 'I', 'M', 'M', 'N', 'O', 'Z', 'c', '\\', 'P', 'F', 'a',
	'(0', '(B', '(A', ')0', ')B', '*0', '+A', '(Z', '#8', '^junk\x1b\\', '_x\x07y\x1b\\', '\x1b', ''
];
const FINALS = '@ABCDEFGHIJKLMPSTXZ`abdefgrstumhlnqcJKHHHrrLMSTAB';
const NUMBERS = ['', '', '0', '1', '1', '2', '2', '3', '4', '5', '6', '8', '10', '22', '23', '99', '300', '99999999999'];
const SGR = [
	'', '0', '1', '2', '3', '4', '5', '7', '8', '9', '21', '22', '23', '24', '25', '27', '28', '29',
	'31', '32', '44', '45', '39', '49', '91', '104', '38;5;3', '48;5;200', '38;2;1;2;3',
	'48;2;200;100;0', '38;5;999', '38;5', '38;2;1', '38:5:7', '48:2::9:8:7', '38:2:1:2:3', '4:3',
	'4:0', '58;5;1', '58:2::1:2:3', '1:2', '38', '7;7', '1;31;42'
];
const MODES = ['1', '6', '7', '7', '12', '25', '47', '1047', '1048', '1049', '1049', '2004', '3', '1;7', '6;25'];
const TITLES = ['one', 'two;three', '', 'tït漢', 'x'.repeat(30)];

it('generates the conformance fixtures', () => {
	const cases = [];

	for (const [name, columns, rows, limit, ...steps] of SCENARIOS) {
		const operations = steps.map((step): Operation => {
			if (typeof step !== 'string') return { resize: step };
			// Characters up to U+00FF in a scenario that is all such characters
			// stand for raw bytes; otherwise the text is encoded as UTF-8.
			const raw = name === 'utf-8 invalid' || name === 'unknown charsets' || name === 'csi malformed' || name === 'osc utf-8';
			return {
				write: hex(raw ? Uint8Array.from(encodeMixed(step)) : encoder.encode(step))
			};
		});
		cases.push(run(name, columns, rows, limit, operations));
	}

	const next = random(20260101);
	const integer = (below: number) => Math.floor(next() * below);
	const pick = <T>(items: ArrayLike<T>): T => items[integer(items.length)];

	for (let index = 0; index < 700; index += 1) {
		const small = next() < 0.8;
		const columns = 1 + integer(small ? 9 : 24);
		const rows = 1 + integer(small ? 5 : 8);
		const limit = pick([0, 1, 3, 8, 8, 20]);

		const operations: Array<Operation> = [];
		let bytes: Array<number> = [];
		const flush = () => {
			// Split what's written anywhere, even inside a sequence.
			while (bytes.length > 0) {
				const length = next() < 0.5 ? bytes.length : 1 + integer(bytes.length);
				operations.push({ write: hex(bytes.slice(0, length)) });
				bytes = bytes.slice(length);
			}
		};
		const text = (string: string) => bytes.push(...encoder.encode(string));

		const tokens = 5 + integer(40);
		for (let token = 0; token < tokens; token += 1) {
			const kind = next();
			if (kind < 0.34) text(pick(TEXT));
			else if (kind < 0.46) text(pick(CONTROLS));
			else if (kind < 0.54) text(`\x1b${pick(ESCAPES)}`);
			else if (kind < 0.74) {
				const marker = next() < 0.06 ? pick('?>=') : '';
				const count = pick([0, 1, 1, 1, 2, 2, 3]);
				let parameters = '';
				for (let p = 0; p < count; p += 1) {
					if (p > 0) parameters += next() < 0.05 ? ':' : ';';
					parameters += pick(NUMBERS);
				}
				const intermediate = next() < 0.04 ? pick(' $!') : '';
				text(`\x1b[${marker}${parameters}${intermediate}${pick(FINALS)}`);
			} else if (kind < 0.82) text(`\x1b[${pick(SGR)}${next() < 0.3 ? `;${pick(SGR)}` : ''}m`);
			else if (kind < 0.88) text(`\x1b[?${pick(MODES)}${pick('hl')}`);
			else if (kind < 0.9) text(`\x1b]${pick('0122')}${pick([';', ';', ''])}${pick(TITLES)}${pick(['\x07', '\x1b\\', '\x18'])}`);
			else if (kind < 0.92) text(`\x1b[${pick(['22', '23'])}${pick(['', ';0', ';1', ';2'])}t`);
			else if (kind < 0.93) text(`\x1b[${pick('0123456789')} q`);
			else if (kind < 0.95) {
				// Bytes that aren't UTF-8.
				for (let b = 1 + integer(3); b > 0; b -= 1) bytes.push(0x80 + integer(0x80));
			} else {
				flush();
				operations.push({ resize: [1 + integer(small ? 10 : 28), 1 + integer(small ? 6 : 9)] });
			}
		}
		flush();

		cases.push(run(`random ${index}`, columns, rows, limit, operations));
	}

	writeFileSync(
		process.env.CONFORMANCE_OUTPUT ?? 'conformance.json',
		JSON.stringify({ probe: hex(encoder.encode(PROBE)), cases })
	);
	expect(cases.length).toBeGreaterThan(SCENARIOS.length);
});

// Encode characters up to U+00FF as single bytes, and the rest as UTF-8.
function encodeMixed(string: string): Array<number> {
	const bytes: Array<number> = [];
	for (const character of string) {
		const codePoint = character.codePointAt(0)!;
		if (codePoint <= 0xff) bytes.push(codePoint);
		else bytes.push(...encoder.encode(character));
	}
	return bytes;
}
