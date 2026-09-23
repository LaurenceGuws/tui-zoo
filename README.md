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
- explicit target cadence, including 33.333, 60, and 120 Hz;
- bounded producer timing samples;
- final JSON receipt on stderr.

Build:

    zig build -Doptimize=ReleaseSafe

Run at upstream Rain's nominal 30 ms tick:

    zig build run -- rain

Run a fixed 60 Hz canary for ten seconds:

    zig build run -Doptimize=ReleaseFast -- rain --fps 60 --duration-ms 10000 --seed 0x5241494e

Useful fixed benchmark geometry:

    zig build run -Doptimize=ReleaseFast -- rain --fps 60 --duration-ms 10000 --cols 85 --rows 79

Press q or Ctrl-C to exit an interactive run.

The producer receipt does not claim displayed FPS. It proves how many frames the workload emitted, whether stdout backpressure made it skip cadence slots, and how much producer-side frame work occurred. Presentation FPS remains the terminal or benchmark host's measurement.

## Provenance

The visual model is based on nkleemann/ascii-rain, MIT licensed. The implementation here is new Zig code and does not use ncurses.
