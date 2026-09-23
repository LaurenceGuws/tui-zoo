const std = @import("std");
const terminal = @import("terminal.zig");
const Pacer = @import("pacer.zig").Pacer;

const default_fps = 1000.0 / 30.0;
const default_seed: u64 = 0x5241_494e;
const default_cols: u16 = 80;
const default_rows: u16 = 24;
const sample_capacity = 4096;
const max_cells: usize = 1024 * 1024;
const max_dimension: u16 = 4096;

const Config = struct {
    fps: f64 = default_fps,
    duration_ms: ?u64 = null,
    frames: ?u64 = null,
    seed: u64 = default_seed,
    cols: ?u16 = null,
    rows: ?u16 = null,
    alternate_screen: bool = true,
    metrics: bool = true,
    assert_min_fps: ?f64 = null,
};

const Drop = struct {
    col: u16,
    row: u16,
    speed: u8,
    color: u8,
    shape: u8,
};

const Cell = struct {
    glyph: u8 = ' ',
    color: u8 = 0,
    occupied: bool = false,
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

const State = struct {
    allocator: std.mem.Allocator,
    random: std.Random,
    cols: u16,
    rows: u16,
    drops: []Drop,
    previous: []Cell,
    current: []Cell,

    fn init(allocator: std.mem.Allocator, random: std.Random, cols: u16, rows: u16) !State {
        if (cols == 0 or rows == 0) return error.InvalidGeometry;
        const drops = try allocator.alloc(Drop, @intCast(dropCount(cols, rows)));
        errdefer allocator.free(drops);
        const cells = try cellCount(cols, rows);
        const previous = try allocator.alloc(Cell, cells);
        errdefer allocator.free(previous);
        const current = try allocator.alloc(Cell, cells);
        errdefer allocator.free(current);

        @memset(previous, .{});
        @memset(current, .{});
        const slow = slowerDrops(cols, rows);
        for (drops) |*drop| drop.* = createDrop(random, cols, rows, slow);

        return .{
            .allocator = allocator,
            .random = random,
            .cols = cols,
            .rows = rows,
            .drops = drops,
            .previous = previous,
            .current = current,
        };
    }

    fn deinit(self: *State) void {
        self.allocator.free(self.drops);
        self.allocator.free(self.previous);
        self.allocator.free(self.current);
    }

    fn resize(self: *State, cols: u16, rows: u16) !void {
        const replacement = try State.init(self.allocator, self.random, cols, rows);
        self.deinit();
        self.* = replacement;
    }

    fn advance(self: *State) void {
        @memset(self.current, .{});
        for (self.drops) |*drop| {
            fall(drop, self.random, self.rows);
            const index = @as(usize, drop.row) * @as(usize, self.cols) + @as(usize, drop.col);
            self.current[index] = .{
                .glyph = drop.shape,
                .color = drop.color,
                .occupied = true,
            };
        }
    }

    fn swap(self: *State) void {
        const old = self.previous;
        self.previous = self.current;
        self.current = old;
    }
};

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const config = try parseArgs(args);
    const allocator = std.heap.page_allocator;

    const initial_size = resolvedSize(config);
    var prng = std.Random.DefaultPrng.init(config.seed);
    var state = try State.init(allocator, prng.random(), initial_size.cols, initial_size.rows);
    defer state.deinit();

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
    var emitted: u64 = 0;
    var changed_cells: u64 = 0;
    var frame_samples = Samples{};
    var late_samples = Samples{};

    while (!terminal.stopRequested()) {
        if (config.frames) |limit| {
            if (emitted >= limit) break;
        }
        if (config.duration_ms) |duration_ms| {
            const elapsed_ns = started.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds;
            if (elapsed_ns >= @as(i96, duration_ms) * std.time.ns_per_ms) break;
        }
        if (input.wantsQuit()) break;

        if (liveSize(config)) |size| {
            if (size.cols != state.cols or size.rows != state.rows) {
                try state.resize(size.cols, size.rows);
                try out.writeAll("\x1b[0m\x1b[2J\x1b[H");
            }
        }

        const frame_started = std.Io.Clock.Timestamp.now(init.io, .awake);
        state.advance();
        changed_cells += try emitDiff(out, state.previous, state.current, state.cols);
        try out.flush();
        state.swap();

        const frame_done = std.Io.Clock.Timestamp.now(init.io, .awake);
        const build_ns = frame_started.durationTo(frame_done).raw.nanoseconds;
        frame_samples.add(if (build_ns > 0) @intCast(build_ns) else 0);

        late_samples.add(try pacer.wait());
        emitted += 1;
    }

    leaveScreen(out, config.alternate_screen);
    screen_active = false;
    input.restore();

    const finished = std.Io.Clock.Timestamp.now(init.io, .awake);
    const elapsed_ns_i = started.durationTo(finished).raw.nanoseconds;
    const elapsed_ns: u64 = if (elapsed_ns_i > 0) @intCast(elapsed_ns_i) else 0;
    const actual_fps = if (elapsed_ns == 0)
        0.0
    else
        @as(f64, @floatFromInt(emitted)) /
            (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));

    if (config.metrics) report(config, emitted, actual_fps, pacer.skipped_slots, changed_cells, &frame_samples, &late_samples);

    if (config.assert_min_fps) |minimum| {
        if (actual_fps < minimum) {
            std.debug.print(
                "{{\"error\":\"producer_fps_below_assertion\",\"actual_fps\":{d:.3},\"minimum_fps\":{d:.3}}}\n",
                .{ actual_fps, minimum },
            );
            std.process.exit(3);
        }
    }
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
            config.fps = try parseFps(args[i]);
        } else if (std.mem.eql(u8, arg, "--duration-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.duration_ms = try parseU64(args[i], 10);
        } else if (std.mem.eql(u8, arg, "--frames")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.frames = try parseU64(args[i], 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.seed = try parseU64(args[i], 0);
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.cols = try parseDimension(args[i]);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.rows = try parseDimension(args[i]);
        } else if (std.mem.eql(u8, arg, "--no-alt-screen")) {
            config.alternate_screen = false;
        } else if (std.mem.eql(u8, arg, "--no-metrics")) {
            config.metrics = false;
        } else if (std.mem.eql(u8, arg, "--assert-min-fps")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            config.assert_min_fps = try parseFps(args[i]);
        } else {
            return error.InvalidArgs;
        }
    }
    return config;
}

fn parseFps(text: []const u8) !f64 {
    const fps = std.fmt.parseFloat(f64, text) catch return error.InvalidArgs;
    if (!std.math.isFinite(fps) or fps <= 0.0 or fps > 1000.0) return error.InvalidArgs;
    return fps;
}

fn parseU64(text: []const u8, base: u8) !u64 {
    return std.fmt.parseInt(u64, text, base) catch error.InvalidArgs;
}

fn parseDimension(text: []const u8) !u16 {
    const value = std.fmt.parseInt(u16, text, 10) catch return error.InvalidArgs;
    if (value == 0 or value > max_dimension) return error.InvalidArgs;
    return value;
}

fn usage() void {
    std.debug.print(
        \\usage: tui-zoo rain [options]
        \\
        \\options:
        \\  --fps N             target cadence; default is upstream 30 ms tick
        \\  --duration-ms N     stop after wall-clock duration
        \\  --frames N          stop after emitted frame count
        \\  --seed N            deterministic PRNG seed
        \\  --cols N            fixed columns; otherwise follow terminal
        \\  --rows N            fixed rows; otherwise follow terminal
        \\  --assert-min-fps N  exit 3 if producer throughput falls below N
        \\  --no-alt-screen     render in the current screen
        \\  --no-metrics        suppress final JSON receipt
        \\
        \\Press q or Ctrl-C to stop an interactive run.
        \\
    , .{});
}

fn resolvedSize(config: Config) terminal.Size {
    const live = terminal.querySize(std.posix.STDOUT_FILENO) orelse terminal.Size{
        .cols = default_cols,
        .rows = default_rows,
    };
    return .{
        .cols = config.cols orelse live.cols,
        .rows = config.rows orelse live.rows,
    };
}

fn liveSize(config: Config) ?terminal.Size {
    if (config.cols != null and config.rows != null) return null;
    const live = terminal.querySize(std.posix.STDOUT_FILENO) orelse return null;
    return .{
        .cols = config.cols orelse live.cols,
        .rows = config.rows orelse live.rows,
    };
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

fn emitDiff(out: anytype, previous: []const Cell, current: []const Cell, cols: u16) !u64 {
    std.debug.assert(previous.len == current.len);
    const width: usize = cols;
    var changed: u64 = 0;
    var active_color: ?u8 = null;

    for (current, previous, 0..) |next, old, index| {
        if (std.meta.eql(next, old)) continue;
        changed += 1;
        const row = index / width + 1;
        const col = index % width + 1;
        try out.print("\x1b[{d};{d}H", .{ row, col });
        if (!next.occupied) {
            if (active_color != null) {
                try out.writeAll("\x1b[0m");
                active_color = null;
            }
            try out.writeByte(' ');
            continue;
        }
        if (active_color == null or active_color.? != next.color) {
            try out.print("\x1b[38;5;{d}m", .{next.color});
            active_color = next.color;
        }
        try out.writeByte(next.glyph);
    }
    if (active_color != null) try out.writeAll("\x1b[0m");
    return changed;
}

fn cellCount(cols: u16, rows: u16) !usize {
    const count = try std.math.mul(usize, @as(usize, cols), @as(usize, rows));
    if (count > max_cells) return error.GeometryTooLarge;
    return count;
}

fn slowerDrops(cols: u16, rows: u16) bool {
    return (rows < 20 and cols > 100) or (cols < 100 and rows < 40);
}

fn dropCount(cols: u16, rows: u16) u32 {
    if (slowerDrops(cols, rows)) return (@as(u32, cols) * 3) / 4;
    return (@as(u32, cols) * 3) / 2;
}

fn createDrop(random: std.Random, cols: u16, rows: u16, slower: bool) Drop {
    const speed = if (slower)
        1 + random.uintLessThan(u8, 3)
    else
        1 + random.uintLessThan(u8, 6);
    const shape_threshold: u8 = if (slower) 2 else 3;
    return .{
        .col = random.uintLessThan(u16, cols),
        .row = random.uintLessThan(u16, rows),
        .speed = speed,
        .color = visibleColor(speed),
        .shape = if (speed < shape_threshold) '|' else ':',
    };
}

fn fall(drop: *Drop, random: std.Random, rows: u16) void {
    drop.row +|= drop.speed;
    if (drop.row >= rows -| 1) drop.row = random.uintLessThan(u16, @min(rows, 10));
}

fn upstreamPair(speed: u8) u8 {
    const x: f64 = @floatFromInt(speed);
    const color = (0.0416 * (x - 4.0) * (x - 3.0) * (x - 2.0) - 4.0) * (x - 1.0) + 255.0;
    return @intFromFloat(@max(1.0, @min(255.0, color)));
}

fn visibleColor(speed: u8) u8 {
    // Upstream initializes curses pair i+1 with foreground color i.
    return upstreamPair(speed) - 1;
}

fn report(
    config: Config,
    frames: u64,
    actual_fps: f64,
    skipped_slots: u64,
    changed_cells: u64,
    frame_samples: *const Samples,
    late_samples: *const Samples,
) void {
    var frame_scratch: [sample_capacity]u64 = undefined;
    var late_scratch: [sample_capacity]u64 = undefined;
    const frame_sorted = frame_samples.sorted(&frame_scratch);
    const late_sorted = late_samples.sorted(&late_scratch);

    std.debug.print(
        "{{\"type\":\"tui_zoo.rain/v1\",\"target_fps\":{d:.6},\"actual_fps\":{d:.3},\"frames\":{d},\"skipped_slots\":{d},\"changed_cells\":{d},\"frame_p50_us\":{d},\"frame_p95_us\":{d},\"frame_p99_us\":{d},\"frame_max_us\":{d},\"late_p50_us\":{d},\"late_p95_us\":{d},\"late_p99_us\":{d},\"late_max_us\":{d}}}\n",
        .{
            config.fps,
            actual_fps,
            frames,
            skipped_slots,
            changed_cells,
            percentileUs(frame_sorted, 50),
            percentileUs(frame_sorted, 95),
            percentileUs(frame_sorted, 99),
            percentileUs(frame_sorted, 100),
            percentileUs(late_sorted, 50),
            percentileUs(late_sorted, 95),
            percentileUs(late_sorted, 99),
            percentileUs(late_sorted, 100),
        },
    );
}

fn percentileUs(sorted_ns: []const u64, pct: u8) u64 {
    if (sorted_ns.len == 0) return 0;
    const index = (@as(usize, pct) * (sorted_ns.len - 1)) / 100;
    return sorted_ns[index] / std.time.ns_per_us;
}

test "rain sizing matches upstream" {
    try std.testing.expectEqual(@as(u32, 60), dropCount(80, 24));
    try std.testing.expectEqual(@as(u32, 180), dropCount(120, 40));
}

test "upstream visible speed colors include curses pair offset" {
    try std.testing.expectEqual(@as(u8, 254), visibleColor(1));
    try std.testing.expectEqual(@as(u8, 250), visibleColor(2));
    try std.testing.expectEqual(@as(u8, 238), visibleColor(5));
    try std.testing.expectEqual(@as(u8, 238), visibleColor(6));
}

test "fixed geometry disables live resize" {
    const config = Config{ .cols = 85, .rows = 79 };
    try std.testing.expectEqual(@as(?terminal.Size, null), liveSize(config));
}

test "cell count is explicitly bounded" {
    try std.testing.expectEqual(@as(usize, 6715), try cellCount(85, 79));
    try std.testing.expectError(error.GeometryTooLarge, cellCount(4096, 4096));
}

test "malformed CLI numbers are ordinary invalid args" {
    try std.testing.expectError(error.InvalidArgs, parseDimension("wat"));
    try std.testing.expectError(error.InvalidArgs, parseDimension("0"));
    try std.testing.expectError(error.InvalidArgs, parseDimension("4097"));
    try std.testing.expectError(error.InvalidArgs, parseFps("nope"));
    try std.testing.expectError(error.InvalidArgs, parseFps("0"));
}

test "sample ring retains newest values" {
    var samples = Samples{};
    var i: u64 = 0;
    while (i < sample_capacity + 10) : (i += 1) samples.add(i);
    var scratch: [sample_capacity]u64 = undefined;
    const sorted = samples.sorted(&scratch);
    try std.testing.expectEqual(@as(usize, sample_capacity), sorted.len);
    try std.testing.expectEqual(@as(u64, 10), sorted[0]);
    try std.testing.expectEqual(@as(u64, sample_capacity + 9), sorted[sorted.len - 1]);
}
