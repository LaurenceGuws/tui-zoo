# TUI Zoo agent contract

TUI Zoo owns small, production-grade terminal programs used as deterministic correctness and performance workloads.

## Boundary

- Programs write ordinary terminal protocol bytes to their controlling PTY/TTY.
- Never import, link, inspect, configure, or special-case Howl, Kitty, Ghostty, a renderer, a compositor, a desktop environment, or a benchmark host.
- A terminal under test owns launching the command and observing the result. TUI Zoo must not grow launchers that dictate host architecture.
- Workloads own deterministic simulation, terminal-byte generation, pacing, bounded metrics, resize handling, and cleanup.
- For a fixed workload version, seed, geometry, and configuration, semantic state evolution must be deterministic.
- Timing is driven by monotonic absolute deadlines. Never pace a benchmark with accumulated relative sleeps.
- Metrics go to stderr as JSON. Visual terminal bytes go to stdout only.
- Keep dependencies at zero unless a capability is genuinely not worth owning. Zig std/POSIX is the baseline.
- Linux is the first accepted platform. Platform-specific code must stay below a narrow terminal boundary.

## Quality

TigerBeetle-defensive, Foot-direct:
- bounds and arithmetic are explicit;
- cleanup restores terminal state;
- allocations are bounded and resize-safe;
- malformed CLI input fails cleanly;
- tests cover deterministic state, edge geometry, pacing arithmetic, and output-diff semantics;
- every workload explains what terminal behavior it pressures and what it intentionally does not measure.

## Git

Work directly on main. Commit coherent green checkpoints. Use the exact compiler in .zigversion.
