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
successful stdin read to stdout flush. A benchmark host must independently
measure compositor delivery and presentation; TUI Zoo does not claim
input-to-photon latency.
