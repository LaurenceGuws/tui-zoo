# TUI Zoo

Small deterministic terminal programs for correctness and performance pressure.

This repository is intentionally independent of any terminal emulator. A workload knows only its PTY/TTY, terminal geometry, monotonic clock, and the bytes it emits.

## Rain

rain is a Zig reimplementation of the visual behavior of nkleemann/ascii-rain (MIT), with a benchmark-grade timing contract:

- deterministic PRNG seed;
- live terminal geometry or explicit fixed geometry;
- upstream-compatible drop count, speed, shape, and visible color model;
- diffed cell output rather than clearing the entire screen every frame;
- absolute monotonic frame deadlines;
- arbitrary bounded target cadence chosen by the caller;
- optional synchronized-output framing (`CSI ?2026`) so one simulation frame
  can be presented as one semantic terminal update;
- bounded producer timing samples;
- final JSON receipt on stderr.

Build:

    zig build -Doptimize=ReleaseSafe

Validation (official Zig version from `.zigversion`, plus `zig-audit` ruleset 3):

    zig fmt --check build.zig src
    zig build test
    zig build audit
    zig build check

`check` compiles the workload, runs its unit tests, and checks all maintained
`build.zig` and `src/*.zig` source with the strict schema-2 audit policy.
`test` remains available independently. Python 3 is used only by the emitted-byte
and PTY cleanup proofs in `tests/unicode.py`; the executable has no Python dependency. Terminal write/flush and normal cleanup
failures terminate with an error rather than producing a successful workload
receipt. On error exits, synchronized-output closure and screen/termios restoration
are attempted; any cleanup failure is reported on stderr because a broken output
stream cannot guarantee delivery of the terminal restoration bytes.

Run at upstream Rain's nominal 30 ms tick:

    zig build run -- rain

Run a caller-selected canary for ten seconds:

    zig build run -Doptimize=ReleaseFast -- rain --fps 173 --duration-ms 10000 --seed 0x5241494e

Useful fixed benchmark geometry:

    zig build run -Doptimize=ReleaseFast -- rain --fps 173 --duration-ms 10000 --cols 85 --rows 79

Ask a terminal to withhold intermediate paint while each semantic frame is
being emitted:

    zig build run -Doptimize=ReleaseFast -- rain --fps 173 --synchronized-output

Press q or Ctrl-C to exit an interactive run.

The producer receipt does not claim displayed FPS. It proves how many frames the workload emitted, whether stdout backpressure made it skip cadence slots, whether semantic frame bracketing was enabled, and how much producer-side frame work occurred. Presentation FPS remains the terminal or benchmark host's measurement.


## Cells

`cells` is the first explicit dose-curve workload. Each semantic frame performs exactly N independent cursor + 256-color + glyph writes at deterministic random coordinates. Geometry and cadence remain fixed while `--dose` increases parser, canonical-state, and rendering pressure.

    tui-zoo cells --dose 64 --fps 240 --duration-ms 8000 --cols 192 --rows 47

Use `--synchronized-output` to bracket each dose as one application frame. `--glyph-set printable` keeps the broad punctuation-heavy default; `--glyph-set alnum` isolates ordinary independent glyph cells so tiny-delta and retained-cell paths can be pressured without contextual-operator shaping becoming the workload. `--frames N` selects an exact semantic-frame count; with fixed seed, geometry, dose, glyph set and synchronization mode this makes the emitted operation stream deterministic for correctness canaries as well as dose sweeps. `--oracle` additionally models the workload's own final row-major cell state and adds `oracle_sha256` to the stderr JSON receipt. The oracle currently covers ASCII foreground writes only; Unicode and background modes reject `--oracle`. Oracle mode requires exact `--frames` and `--no-alt-screen`, and leaves the final cells visible after restoring SGR/cursor state so an external terminal host can independently compare its observed cells. When neither `--frames` nor `--duration-ms` is supplied, the existing 8-second default remains. The JSON receipt names the glyph set together with producer cadence, skipped slots, writes, geometry and producer-side timing. The workload intentionally does not know which terminal is running it and does not define a terminal tap out itself; the benchmark host owns resource usage, presentation, responsiveness, and saturation policy.

A useful cell sweep holds seed/geometry/fps constant and increases dose geometrically, for example 1, 4, 16, 64, 256, 1024, 4096. This produces a dose curve instead of a single benchmark score.

Use `--background` to add independently changing 256-color backgrounds. Use
--glyph-set unicode for Greek/Cyrillic text, box drawing, a combining accent,
CJK wide glyphs and emoji. Unicode mode requires at least two columns and reserves
the rightmost column to keep two-column clusters from wrapping. These are byte
and rendering pressure canaries, with no claim of Unicode screen-state validation.

    tui-zoo cells --glyph-set unicode --background --dose 4096 --fps 240 --duration-ms 8000 --synchronized-output

The command and receipt are now named `cells` (`tui_zoo.cells/v1`); the default
seed and ASCII stdout stream are unchanged. The oracle hash namespace is now
`tui-zoo.cells.oracle/v1`. No legacy command alias is retained.


## Unicode torture track

`unicode` separates text cases, traversal, and foreground/background variation.
It shares Cells' pacing, terminal I/O, signal cleanup and producer timing lane.
It does not inspect or configure the terminal under test.

    tui-zoo unicode --case mixed --dose 256 --fps 240 --duration-ms 10000 --synchronized-output

Each operation fills one nominal **two-cell slot**. ASCII writes two narrow
characters, CJK writes one wide character, and combining/emoji cases write
complete sequences. Odd-width grids leave the final column unused. Slots keep
the intended changed area equal across cases and keep wide text away from
accidental wrapping. Dose counts slot writes, including repeated writes to a slot;
it does not count unique dirty cells or match the old one-cell ASCII dose.

| Case | Pressure |
| --- | --- |
| `ascii` | Two ASCII letters/digits; control case |
| `utf8` | Two narrow non-ASCII characters, including two/three-byte UTF-8 |
| `combining` | Two combining clusters, ranging up to 24 codepoints each |
| `wide` | CJK/Korean/Japanese wide text, including supplementary CJK |
| `emoji` | Emoji, skin tone, flags, keycap and ZWJ sequences |
| `scripts` | Armenian, Georgian, Ethiopic, Thai, Hebrew, Arabic and Devanagari font-coverage pressure |
| `presentation` | Text/emoji selectors alternating nominal one-cell-plus-space and two-cell forms |
| `churn` | Cycle all 4,096 CJK scalars U+4E00..U+5DFF before repeating |
| `mixed` | Sample all seven non-ASCII cases, including churn; default |

`--pattern random` edits seeded random slots. `--pattern sequential` sweeps slots
in row-major order continuously across frames. Coordinates, text, foreground and
background use independent random streams. Changing case preserves coordinates;
changing traversal preserves text; toggling colors preserves both.

Colors are fixed by default: indexed foreground 7 and the terminal's default
background. Add `--foreground`, `--background`, or both independently. A useful
matrix holds seed, geometry, pattern, dose, cadence and duration constant:

    tui-zoo unicode --case ascii --pattern random --dose 1024 --fps 240 --duration-ms 8000 --cols 384 --rows 83 --synchronized-output
    tui-zoo unicode --case utf8  --pattern random --dose 1024 --fps 240 --duration-ms 8000 --cols 384 --rows 83 --synchronized-output

Repeat each with `--background`; add `--foreground` to both when variable text
color is the intended test. Then repeat for combining/wide/emoji/scripts/
presentation/churn/mixed and the sequential pattern. The terminal/benchmark host
owns fresh-process ordering, CPU/memory observation and visual qualification.
TUI Zoo supplies one named case per process rather than silently blending scores.

For deterministic input canaries:

    tui-zoo unicode --case mixed --frames 64 --dose 256 --seed 7 --cols 80 --rows 24 --digest --synchronized-output

`--digest` requires exact `--frames` without a duration limit. It adds independent
position and length-delimited text SHA-256 hashes. Background/foreground toggles
must preserve both hashes. Digests are off by default; leave them off for timing
to avoid measuring hashing overhead. They validate emitted input, not terminal
screen state.

The `tui_zoo.unicode/v1` stderr receipt records case, pattern, seed, color flags,
slot writes, payload bytes, codepoints, nominal cells, complete semantic-frame
bytes, geometry, target/producer cadence, skipped slots and bounded timing samples.
Frame bytes include cursor/style/text output, frame SGR reset and optional
synchronized-output markers; startup/cleanup bytes are excluded.

Widths are nominal expectations. Ambiguous-width policy, Unicode support, font
coverage and emoji presentation differ between terminals. `scripts` pressures
coverage but cannot guarantee a fallback with every font. These cases include
shaping/rasterization as well as decoding; they do not isolate decoder CPU alone.
A host must qualify rendering before interpreting performance. Producer FPS is
not displayed FPS, and the receipt makes no Unicode cell-state oracle claim.

Common cadence/dose/geometry controls match Cells. Unicode geometry requires at
least two columns, dimensions at most 4096 and at most 1,048,576 cells. Fixed
frame counts are bounded to 1,000,000; dose is at most 65,536. Geometry is fixed
at startup. Restart the case after resizing when making controlled comparisons.

## Provenance

The visual model is based on nkleemann/ascii-rain, MIT licensed. The implementation here is new Zig code and does not use ncurses.

## Latency

`latency` is a deliberately tiny input-response workload. It enters raw mode,
waits for input bytes, and toggles one visible cell immediately for each byte.
The workload writes JSONL timing receipts to stderr after the terminal bytes have
been flushed.

    zig build run -Doptimize=ReleaseFast -- latency --samples 32

Use `--synchronized-output` when the benchmark wants each marker mutation
bracketed by CSI `?2026`. The workload's `read_to_flush_us` metric measures only
successful stdin read to stdout flush. Each sample also exposes the existing
read and flush timestamps as read_monotonic_ns and flush_monotonic_ns:
nanoseconds from the same system monotonic clock (CLOCK_MONOTONIC on Linux).
These let an independent host correlate the response with its own observations.
A benchmark host must independently
measure compositor delivery and presentation; TUI Zoo does not claim
input-to-photon latency.

Cursor movement can be isolated from cell writes with `cells --cursor-only`.
It primes the requested viewport once with ASCII `x` in color 7, then each
operation only moves a visible steady block cursor. Geometry, seed, pacing,
dose and synchronized-output controls remain the same. Priming precedes measured
producer frames; host samples may include that startup cost. The mode pressures
presentation of retained content with tiny protocol input, not glyph shaping or
bulk parser throughput. Background and Unicode glyph modes are rejected.
The default cursor policy is restored on exit, and the existing fixed-frame
ASCII cell oracle covers the unchanged primed viewport.

`tui-zoo build-info` writes one JSON record to stderr with the exact compiler
version, optimization mode and compiler backend of that executable. It writes
no terminal bytes. Record this alongside the binary hash when comparing canary
results: producer generation cost can otherwise masquerade as a consumer limit.
