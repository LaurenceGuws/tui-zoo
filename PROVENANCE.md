# Provenance

## ascii-rain visual model

Reference:
- upstream: https://github.com/nkleemann/ascii-rain
- reviewed commit: 39396de
- license: MIT, preserved in LICENSES/ascii-rain.txt

TUI Zoo does not copy the ncurses implementation. The rain workload reimplements the visible model in Zig:
- terminal-size-dependent drop count;
- random initial position;
- speed ranges;
- speed-dependent | / : shape choice;
- the upstream speed-to-curses-pair polynomial;
- wrap to the top ten rows;
- nominal 30 ms update cadence.

One fidelity detail is explicit in the Zig implementation: upstream initializes curses pair i+1 with foreground color i, so the direct SGR 256-color index is one less than the computed pair number.

The renderer is intentionally different. Upstream delegates screen diffing to ncurses; TUI Zoo owns a previous/current cell grid and emits changed cells directly. This keeps the workload independent of ncurses while preserving the visual state model.
