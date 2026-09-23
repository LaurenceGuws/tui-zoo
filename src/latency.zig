const std = @import("std");
const posix = std.posix;
const terminal = @import("terminal.zig");

pub const Error = error{
    HelpRequested,
    InvalidArgs,
    Stdout,
    Stderr,
    Poll,
    Read,
};

const default_samples: u16 = 32;
const maximum_samples: u16 = 4096;
const sync_begin = "\x1b[?2026h";
const sync_end = "\x1b[?2026l";

const Config = struct {
    samples: u16 = default_samples,
    alternate_screen: bool = true,
    synchronized_output: bool = false,
};

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const config = parseArgs(args) catch |err| switch (err) {
        error.HelpRequested => {
            usage();
            return error.HelpRequested;
        },
        else => return err,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const metrics = &stderr_writer.interface;

    var input = terminal.Input.enter();
    defer input.restore();
    terminal.installStopHandlers();

    try enterScreen(out, config.alternate_screen);
    var screen_active = true;
    defer if (screen_active) leaveScreen(out, config.alternate_screen);

    try metrics.print(
        "{{\"type\":\"tui_zoo.latency_ready/v1\",\"samples\":{d},\"synchronized_output\":{}}}\n",
        .{ config.samples, config.synchronized_output },
    );
    try metrics.flush();

    var emitted: u16 = 0;
    var marker = false;
    var reaction_us: [maximum_samples]u64 = undefined;

    while (emitted < config.samples and !terminal.stopRequested()) {
        const byte = try readOneByte() orelse continue;

        const started = std.Io.Clock.Timestamp.now(init.io, .awake);
        marker = !marker;
        try emitMarker(out, marker, config.synchronized_output);
        const finished = std.Io.Clock.Timestamp.now(init.io, .awake);
        const elapsed = started.durationTo(finished).raw.nanoseconds;
        const elapsed_us: u64 = if (elapsed > 0) @intCast(@divTrunc(elapsed, std.time.ns_per_us)) else 0;
        reaction_us[emitted] = elapsed_us;

        try metrics.print(
            "{{\"type\":\"tui_zoo.latency_sample/v1\",\"sequence\":{d},\"byte\":{d},\"read_to_flush_us\":{d}}}\n",
            .{ emitted + 1, byte, elapsed_us },
        );
        try metrics.flush();
        emitted += 1;
    }

    leaveScreen(out, config.alternate_screen);
    screen_active = false;
    input.restore();

    std.mem.sort(u64, reaction_us[0..emitted], {}, struct {
        fn lessThan(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lessThan);
    const samples = reaction_us[0..emitted];
    try metrics.print(
        "{{\"type\":\"tui_zoo.latency/v1\",\"samples\":{d},\"read_to_flush_p50_us\":{d},\"read_to_flush_p95_us\":{d},\"read_to_flush_p99_us\":{d},\"read_to_flush_max_us\":{d}}}\n",
        .{
            emitted,
            percentile(samples, 50),
            percentile(samples, 95),
            percentile(samples, 99),
            percentile(samples, 100),
        },
    );
    try metrics.flush();
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return error.HelpRequested;
        if (std.mem.eql(u8, arg, "--samples")) {
            index += 1;
            if (index >= args.len) return error.InvalidArgs;
            config.samples = std.fmt.parseUnsigned(u16, args[index], 10) catch return error.InvalidArgs;
            if (config.samples == 0 or config.samples > maximum_samples) return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--no-alt-screen")) {
            config.alternate_screen = false;
        } else if (std.mem.eql(u8, arg, "--synchronized-output")) {
            config.synchronized_output = true;
        } else {
            return error.InvalidArgs;
        }
    }
    return config;
}

fn readOneByte() !?u8 {
    var descriptors = [_]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN | posix.POLL.HUP,
        .revents = 0,
    }};
    const ready = posix.poll(&descriptors, 100) catch return error.Poll;
    if (ready == 0) return null;
    if (descriptors[0].revents & posix.POLL.IN == 0) return null;
    var byte: [1]u8 = undefined;
    const count = posix.read(posix.STDIN_FILENO, &byte) catch return error.Read;
    if (count == 0) return null;
    return byte[0];
}

fn emitMarker(out: anytype, marker: bool, synchronized_output: bool) !void {
    if (synchronized_output) try out.writeAll(sync_begin);
    try out.writeAll("\x1b[1;1H");
    try out.writeByte(if (marker) '1' else '0');
    if (synchronized_output) try out.writeAll(sync_end);
    try out.flush();
}

fn enterScreen(out: anytype, alternate: bool) !void {
    if (alternate) try out.writeAll("\x1b[?1049h");
    try out.writeAll("\x1b[?25l\x1b[2J\x1b[H0");
    try out.flush();
}

fn leaveScreen(out: anytype, alternate: bool) void {
    out.writeAll("\x1b[0m\x1b[?25h") catch {};
    if (alternate) out.writeAll("\x1b[?1049l") catch {};
    out.flush() catch {};
}

fn percentile(sorted: []const u64, pct: u8) u64 {
    if (sorted.len == 0) return 0;
    return sorted[(@as(usize, pct) * (sorted.len - 1)) / 100];
}

fn usage() void {
    std.debug.print(
        \\usage: tui-zoo latency [options]
        \\
        \\options:
        \\  --samples N            stop after N input bytes (default 32, max 4096)
        \\  --synchronized-output  bracket each marker mutation with CSI ?2026
        \\  --no-alt-screen        render in the current screen
        \\
        \\The workload measures its own input-read to stdout-flush reaction time only.
        \\A benchmark host must measure terminal/compositor presentation separately.
        \\
    , .{});
}

test "latency config is bounded" {
    try std.testing.expectEqual(@as(u16, 17), (try parseArgs(&.{ "--samples", "17" })).samples);
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "--samples", "0" }));
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "--samples", "4097" }));
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{"--bogus"}));
}

test "latency marker is one deterministic cell mutation" {
    var storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try emitMarker(&writer, true, false);
    try std.testing.expectEqualStrings("\x1b[1;1H1", writer.buffered());

    var sync_storage: [128]u8 = undefined;
    var sync_writer: std.Io.Writer = .fixed(&sync_storage);
    try emitMarker(&sync_writer, false, true);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[1;1H0\x1b[?2026l",
        sync_writer.buffered(),
    );
}
