const std = @import("std");
const terminal = @import("terminal.zig");
const Pacer = @import("pacer.zig").Pacer;

const default_fps = 240.0;
const default_duration_ms: u64 = 8000;
const default_seed: u64 = 0x504f_4953_4f4e;
const default_cols: u16 = 80;
const default_rows: u16 = 24;
const max_dimension: u16 = 4096;
const max_cells: usize = 1024 * 1024;
const max_dose: u16 = 4096;
const sample_capacity = 4096;
const sync_begin = "\x1b[?2026h";
const sync_end = "\x1b[?2026l";
const alnum_glyphs = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

const GlyphSet = enum {
    printable,
    alnum,
};

const Config = struct {
    fps: f64 = default_fps,
    duration_ms: u64 = default_duration_ms,
    seed: u64 = default_seed,
    cols: ?u16 = null,
    rows: ?u16 = null,
    dose: u16 = 1,
    glyph_set: GlyphSet = .printable,
    synchronized_output: bool = false,
    alternate_screen: bool = true,
};

const Samples = struct {
    values: [sample_capacity]u64 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    fn add(self: *Samples, value: u64) void {
        self.values[self.cursor] = value;
        self.cursor = (self.cursor + 1) % self.values.len;
        if (self.len < self.values.len) self.len += 1;
    }

    fn sorted(self: *const Samples, scratch: *[sample_capacity]u64) []u64 {
        if (self.len == 0) return scratch[0..0];
        if (self.len < self.values.len) {
            @memcpy(scratch[0..self.len], self.values[0..self.len]);
        } else {
            const tail = self.values.len - self.cursor;
            @memcpy(scratch[0..tail], self.values[self.cursor..]);
            @memcpy(scratch[tail..self.len], self.values[0..self.cursor]);
        }
        std.mem.sort(u64, scratch[0..self.len], {}, struct {
            fn lessThan(_: void, a: u64, b: u64) bool {
                return a < b;
            }
        }.lessThan);
        return scratch[0..self.len];
    }
};

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const config = try parseArgs(args);
    const size = resolvedSize(config);
    _ = try cellCount(size.cols, size.rows);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var input = terminal.Input.enter();
    defer input.restore();
    terminal.installStopHandlers();
    try enterScreen(out, config.alternate_screen);
    var screen_active = true;
    defer if (screen_active) leaveScreen(out, config.alternate_screen);

    var pacer = try Pacer.init(init.io, config.fps);
    const started = std.Io.Clock.Timestamp.now(init.io, .awake);
    var prng = std.Random.DefaultPrng.init(config.seed);
    const random = prng.random();
    var frames: u64 = 0;
    var writes: u64 = 0;
    var frame_samples = Samples{};
    var late_samples = Samples{};

    while (!terminal.stopRequested()) {
        const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds;
        if (elapsed >= @as(i96, config.duration_ms) * std.time.ns_per_ms) break;
        if (input.wantsQuit()) break;

        const frame_started = std.Io.Clock.Timestamp.now(init.io, .awake);
        if (config.synchronized_output) try out.writeAll(sync_begin);
        var operation: u16 = 0;
        while (operation < config.dose) : (operation += 1) {
            const row = 1 + random.uintLessThan(u16, size.rows);
            const col = 1 + random.uintLessThan(u16, size.cols);
            const color = 16 + random.uintLessThan(u8, 216);
            const glyph = randomGlyph(random, config.glyph_set);
            try out.print("\x1b[{d};{d}H\x1b[38;5;{d}m", .{ row, col, color });
            try out.writeByte(glyph);
            writes += 1;
        }
        try out.writeAll("\x1b[0m");
        if (config.synchronized_output) try out.writeAll(sync_end);
        try out.flush();
        const frame_done = std.Io.Clock.Timestamp.now(init.io, .awake);
        const build_ns = frame_started.durationTo(frame_done).raw.nanoseconds;
        frame_samples.add(if (build_ns > 0) @intCast(build_ns) else 0);
        late_samples.add(try pacer.wait());
        frames += 1;
    }

    leaveScreen(out, config.alternate_screen);
    screen_active = false;
    input.restore();
    const finished = std.Io.Clock.Timestamp.now(init.io, .awake);
    const elapsed_i = started.durationTo(finished).raw.nanoseconds;
    const elapsed_ns: u64 = if (elapsed_i > 0) @intCast(elapsed_i) else 0;
    report(config, size, frames, writes, elapsed_ns, pacer.skipped_slots, &frame_samples, &late_samples);
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--fps")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.fps = std.fmt.parseFloat(f64, args[i]) catch return error.InvalidArgs;
            if (!std.math.isFinite(config.fps) or config.fps <= 0 or config.fps > 2000) return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--duration-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.duration_ms = std.fmt.parseUnsigned(u64, args[i], 10) catch return error.InvalidArgs;
            if (config.duration_ms == 0 or config.duration_ms > 60_000) return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.seed = std.fmt.parseInt(u64, args[i], 0) catch return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.cols = try parseDimension(args[i]);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.rows = try parseDimension(args[i]);
        } else if (std.mem.eql(u8, arg, "--dose")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.dose = std.fmt.parseUnsigned(u16, args[i], 10) catch return error.InvalidArgs;
            if (config.dose == 0 or config.dose > max_dose) return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--glyph-set")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.glyph_set = std.meta.stringToEnum(GlyphSet, args[i]) orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--synchronized-output")) {
            config.synchronized_output = true;
        } else if (std.mem.eql(u8, arg, "--no-alt-screen")) {
            config.alternate_screen = false;
        } else return error.InvalidArgs;
    }
    return config;
}

fn randomGlyph(random: std.Random, glyph_set: GlyphSet) u8 {
    return switch (glyph_set) {
        .printable => '!' + random.uintLessThan(u8, 94),
        .alnum => alnum_glyphs[random.uintLessThan(usize, alnum_glyphs.len)],
    };
}

fn parseDimension(text: []const u8) !u16 {
    const value = std.fmt.parseUnsigned(u16, text, 10) catch return error.InvalidArgs;
    if (value == 0 or value > max_dimension) return error.InvalidArgs;
    return value;
}

fn resolvedSize(config: Config) terminal.Size {
    const live = terminal.querySize(std.posix.STDOUT_FILENO) orelse terminal.Size{ .cols = default_cols, .rows = default_rows };
    return .{ .cols = config.cols orelse live.cols, .rows = config.rows orelse live.rows };
}

fn cellCount(cols: u16, rows: u16) !usize {
    const count = try std.math.mul(usize, @as(usize, cols), @as(usize, rows));
    if (count > max_cells) return error.GeometryTooLarge;
    return count;
}

fn enterScreen(out: anytype, alternate: bool) !void {
    if (alternate) try out.writeAll("\x1b[?1049h");
    try out.writeAll("\x1b[?25l\x1b[0m\x1b[2J\x1b[H");
    try out.flush();
}

fn leaveScreen(out: anytype, alternate: bool) void {
    out.writeAll("\x1b[0m\x1b[2J\x1b[H\x1b[?25h") catch {};
    if (alternate) out.writeAll("\x1b[?1049l") catch {};
    out.flush() catch {};
}

fn report(config: Config, size: terminal.Size, frames: u64, writes: u64, elapsed_ns: u64, skipped: u64, frame_samples: *const Samples, late_samples: *const Samples) void {
    var frame_scratch: [sample_capacity]u64 = undefined;
    var late_scratch: [sample_capacity]u64 = undefined;
    const f = frame_samples.sorted(&frame_scratch);
    const l = late_samples.sorted(&late_scratch);
    const fps = if (elapsed_ns == 0) 0.0 else @as(f64, @floatFromInt(frames)) / (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
    std.debug.print(
        "{{\"type\":\"tui_zoo.poison/v1\",\"dose\":{d},\"glyph_set\":\"{s}\",\"target_fps\":{d:.6},\"actual_fps\":{d:.3},\"frames\":{d},\"skipped_slots\":{d},\"writes\":{d},\"cols\":{d},\"rows\":{d},\"synchronized_output\":{},\"frame_p50_us\":{d},\"frame_p95_us\":{d},\"frame_p99_us\":{d},\"frame_max_us\":{d},\"late_p50_us\":{d},\"late_p95_us\":{d},\"late_p99_us\":{d},\"late_max_us\":{d}}}\n",
        .{ config.dose, @tagName(config.glyph_set), config.fps, fps, frames, skipped, writes, size.cols, size.rows, config.synchronized_output, percentileUs(f, 50), percentileUs(f, 95), percentileUs(f, 99), percentileUs(f, 100), percentileUs(l, 50), percentileUs(l, 95), percentileUs(l, 99), percentileUs(l, 100) },
    );
}

fn percentileUs(sorted: []const u64, pct: u8) u64 {
    if (sorted.len == 0) return 0;
    return sorted[(@as(usize, pct) * (sorted.len - 1)) / 100] / std.time.ns_per_us;
}

fn usage() void {
    std.debug.print(
        \\usage: tui-zoo poison [options]
        \\
        \\Random-cell poison: each frame performs exactly dose independent cursor/color/glyph writes.
        \\Increase dose to move terminal parser/state/render pressure while geometry and cadence stay fixed.
        \\
        \\options:
        \\  --dose N             writes per semantic frame (1..4096, default 1)
        \\  --fps N              target semantic-frame cadence (max 2000)
        \\  --duration-ms N      bounded duration (max 60000)
        \\  --seed N             deterministic PRNG seed
        \\  --glyph-set NAME      printable (default) or alnum
        \\  --cols N --rows N    fixed geometry
        \\  --synchronized-output bracket each frame with CSI ?2026
        \\  --no-alt-screen      render in current screen
        \\
    , .{});
}

test "poison configuration and geometry are bounded" {
    try std.testing.expectEqual(@as(u16, 64), (try parseArgs(&.{ "--dose", "64" })).dose);
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "--dose", "0" }));
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "--dose", "4097" }));
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "--fps", "2001" }));
    try std.testing.expectEqual(GlyphSet.alnum, (try parseArgs(&.{ "--glyph-set", "alnum" })).glyph_set);
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "--glyph-set", "emoji" }));
    try std.testing.expectError(error.GeometryTooLarge, cellCount(4096, 4096));
}

test "poison seed drives deterministic operation stream" {
    var a = std.Random.DefaultPrng.init(default_seed);
    var b = std.Random.DefaultPrng.init(default_seed);
    const ar = a.random();
    const br = b.random();
    for (0..128) |_| {
        try std.testing.expectEqual(ar.uintLessThan(u16, 192), br.uintLessThan(u16, 192));
        try std.testing.expectEqual(ar.uintLessThan(u16, 47), br.uintLessThan(u16, 47));
        try std.testing.expectEqual(ar.uintLessThan(u8, 216), br.uintLessThan(u8, 216));
        try std.testing.expectEqual(ar.uintLessThan(u8, 94), br.uintLessThan(u8, 94));
    }
}

test "poison glyph sets stay deterministic and bounded" {
    var a = std.Random.DefaultPrng.init(default_seed);
    var b = std.Random.DefaultPrng.init(default_seed);
    const ar = a.random();
    const br = b.random();
    for (0..128) |_| {
        try std.testing.expectEqual(randomGlyph(ar, .printable), randomGlyph(br, .printable));
        const left = randomGlyph(ar, .alnum);
        const right = randomGlyph(br, .alnum);
        try std.testing.expectEqual(left, right);
        try std.testing.expect(std.mem.indexOfScalar(u8, alnum_glyphs, left) != null);
    }
}
