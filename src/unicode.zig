//! Deterministic Unicode payloads and equal two-cell-slot operations.
//! Widths are workload expectations, never a terminal screen-state oracle.
const std = @import("std");
const terminal = @import("terminal.zig");

/// Names independent text-pressure cases; mixed preserves its seven-case corpus.
pub const Case = enum {
    ascii,
    utf8,
    combining,
    wide,
    emoji,
    scripts,
    presentation,
    churn,
    @"grapheme-churn",
    @"grapheme-repeat",
    @"emoji-zwj",
    @"indic-conjunct",
    @"arabic-join",
    @"hangul-nfc",
    @"hangul-nfd",
    @"world-scripts",
    mixed,
};
/// Selects random slot edits or a continuous row-major slot sweep.
pub const Pattern = enum { random, sequential };
/// Changes colors independently from positions and text.
pub const Config = struct {
    case: Case = .mixed,
    pattern: Pattern = .random,
    foreground: bool = false,
    digest: bool = false,
};

const Sample = struct { bytes: []const u8, scalars: u16 };
fn sample(comptime bytes: []const u8) Sample {
    const count = std.unicode.utf8CountCodepoints(bytes) catch @compileError("invalid corpus UTF-8");
    if (bytes.len > 192 or count > 48) @compileError("Unicode slot exceeds its fixed bound");
    return .{ .bytes = bytes, .scalars = count };
}
const ascii = [_]Sample{ sample("Aa"), sample("B7"), sample("qZ"), sample("09"), sample("mn"), sample("XY"), sample("k2"), sample("rS") };
const utf8 = [_]Sample{ sample("Ωλ"), sample("ЖЯ"), sample("éñ"), sample("øß"), sample("€₹"), sample("Łđ"), sample("πδ"), sample("ДФ") };
fn stacked(comptime count: usize) [2 + 4 * count]u8 {
    var bytes: [2 + 4 * count]u8 = undefined;
    bytes[0] = 'a';
    bytes[1 + 2 * count] = 'b';
    for (0..count) |index| {
        bytes[1 + 2 * index ..][0..2].* = .{ 0xcc, 0x81 };
        bytes[2 + 2 * count + 2 * index ..][0..2].* = .{ 0xcc, 0xa3 };
    }
    return bytes;
}
const stacked_short = stacked(7);
const stacked_long = stacked(23);
const combining = [_]Sample{
    sample("e\u{301}a\u{308}"),               sample("o\u{302}u\u{303}"),                             sample("n\u{303}c\u{327}"), sample("a\u{323}\u{301}e\u{328}\u{304}"),
    sample("A\u{30a}\u{301}o\u{308}\u{304}"), sample("e\u{301}\u{300}\u{302}x\u{323}\u{327}\u{328}"), sample(&stacked_short),     sample(&stacked_long),
};
const wide = [_]Sample{ sample("界"), sample("語"), sample("漢"), sample("字"), sample("한"), sample("글"), sample("か"), sample("𠀀") };
const emoji = [_]Sample{ sample("🙂"), sample("🚀"), sample("👩‍💻"), sample("👨‍👩‍👧‍👦"), sample("👍🏽"), sample("🇿🇦"), sample("1️⃣"), sample("🏳️‍🌈") };
const scripts = [_]Sample{ sample("Աբ"), sample("აბ"), sample("ሀለ"), sample("กข"), sample("אב"), sample("بج"), sample("कख"), sample("αЖ") };
const presentation = [_]Sample{ sample("♥︎ "), sample("♥️"), sample("☀︎ "), sample("☀️"), sample("✈︎ "), sample("✈️"), sample("©︎ "), sample("©️") };
// Dedicated grapheme/shaping probes. Each sample occupies a nominal two-cell
// slot, but font coverage and width policy remain terminal qualifications.
const emoji_zwj = [_]Sample{
    sample("👩‍💻"),
    sample("👨‍🔬"),
    sample("🧑‍🚀"),
    sample("👩‍⚕️"),
    sample("👨‍👩‍👧‍👦"),
    sample("🏳️‍🌈"),
    sample("🏴‍☠️"),
    sample("❤️‍🔥"),
};
const indic_conjunct = [_]Sample{
    sample("क्ष "),
    sample("क्‍ष "),
    sample("त्र "),
    sample("श्र "),
    sample("स्त "),
    sample("प्रि "),
    sample("ক্ষ "),
    sample("ক্ত "),
};
const arabic_join = [_]Sample{
    sample("لا"),
    sample("لب"),
    sample("بج"),
    sample("مش"),
    sample("سَ "),
    sample("بّ "),
    sample("عِ "),
    sample("آم"),
};
// The two corpora use matching indices for canonically equivalent syllables.
// Hangul Jamo clusters exert joining pressure absent from precomposed syllables.
const hangul_nfc = [_]Sample{
    sample("가"),
    sample("난"),
    sample("한"),
    sample("영"),
    sample("물"),
    sample("서"),
    sample("글"),
    sample("린"),
};
const hangul_nfd = [_]Sample{
    sample("가"),
    sample("난"),
    sample("한"),
    sample("영"),
    sample("물"),
    sample("서"),
    sample("글"),
    sample("린"),
};

// Deliberately outside the fixed desktop fallback recipe: these independent
// scripts exercise on-demand font selection and combining/complex shaping.
// Each value occupies a nominal two-cell slot, with a trailing space when
// the visible cluster is expected to occupy one terminal cell.
const world_scripts = [_]Sample{
    sample("கி "), // Tamil combining vowel
    sample("ก้ "), // Thai tone mark
    sample("ក្រ "), // Khmer coeng conjunct
    sample("කි "), // Sinhala dependent vowel
    sample("ሀለ"), // Ethiopic
    sample("שׁ "), // Hebrew point
    sample("𒀀 "), // Cuneiform
    sample("𓀀 "), // Egyptian hieroglyph
};

// Two single-cell clusters per slot. The 112-mark alphabet has enough ordered
// triples for 262,144 distinct scalar sequences without any retained corpus.
const grapheme_churn_count: u32 = 262_144;
const grapheme_mark_count: u32 = 0x70;
const grapheme_repeat_count: u32 = 64;

fn encodeChurnCluster(bytes: []u8, base: u8, index: u32) void {
    std.debug.assert(bytes.len == 7 and index < grapheme_churn_count);
    bytes[0] = base;
    var remaining = index;
    for (0..3) |mark_index| {
        const mark: u16 = @intCast(0x300 + remaining % grapheme_mark_count);
        remaining /= grapheme_mark_count;
        bytes[1 + mark_index * 2] = @intCast(0xc0 | (mark >> 6));
        bytes[2 + mark_index * 2] = @intCast(0x80 | (mark & 0x3f));
    }
}

fn corpus(case: Case) []const Sample {
    return switch (case) {
        .ascii => &ascii,
        .utf8 => &utf8,
        .combining => &combining,
        .wide => &wide,
        .emoji => &emoji,
        .scripts => &scripts,
        .presentation => &presentation,
        .@"emoji-zwj" => &emoji_zwj,
        .@"indic-conjunct" => &indic_conjunct,
        .@"arabic-join" => &arabic_join,
        .@"hangul-nfc" => &hangul_nfc,
        .@"hangul-nfd" => &hangul_nfd,
        .@"world-scripts" => &world_scripts,
        .mixed, .churn, .@"grapheme-churn", .@"grapheme-repeat" => &.{},
    };
}

/// One two-cell-slot write; generated text borrows its Planner until next().
pub const Operation = struct {
    row: u16,
    col: u16,
    text: []const u8,
    scalars: u16,
    foreground: u8,
    background: u8,
};

/// Owns bounded independent streams; color flags never perturb coordinates/text.
pub const Planner = struct {
    positions: std.Random.DefaultPrng,
    text: std.Random.DefaultPrng,
    foreground: std.Random.DefaultPrng,
    background: std.Random.DefaultPrng,
    config: Config,
    slots_per_row: u16,
    slot_count: usize,
    next_slot: usize = 0,
    next_glyph: u16,
    next_grapheme: u32,
    grapheme_base: u32,
    grapheme_repeat_offset: u32 = 0,
    generated: [14]u8 = undefined,

    /// Validates two-column slots without requiring storage proportional to the grid.
    pub fn init(seed: u64, size: terminal.Size, config: Config) error{InvalidArgs}!Planner {
        if (size.cols < 2 or size.rows == 0) return error.InvalidArgs;
        const slots = size.cols / 2;
        return .{
            .positions = .init(seed ^ 0x706f736974696f6e),
            .text = .init(seed ^ 0x746578742d736565),
            .foreground = .init(seed ^ 0x666f726567726f75),
            .background = .init(seed ^ 0x6261636b67726f75),
            .config = config,
            .slots_per_row = slots,
            .slot_count = @as(usize, slots) * size.rows,
            .next_glyph = @intCast(seed % 4096),
            .next_grapheme = @intCast(seed % grapheme_churn_count),
            .grapheme_base = @intCast(seed % grapheme_churn_count),
        };
    }

    /// Advances every random domain once, irrespective of painting flags.
    pub fn next(self: *Planner) Operation {
        const random_slot = self.positions.random().uintLessThan(usize, self.slot_count);
        const slot = if (self.config.pattern == .random) random_slot else self.next_slot;
        self.next_slot += 1;
        if (self.next_slot == self.slot_count) self.next_slot = 0;
        const case = if (self.config.case == .mixed) blk: {
            const cases = [_]Case{ .utf8, .combining, .wide, .emoji, .scripts, .presentation, .churn };
            break :blk cases[self.text.random().uintLessThan(usize, cases.len)];
        } else self.config.case;
        const value = if (case == .churn) blk: {
            // U+4E00..U+5DFF: valid three-byte CJK scalars, nominal width two.
            const cp: u16 = 0x4e00 + self.next_glyph;
            self.next_glyph = (self.next_glyph + 1) % 4096;
            self.generated[0..3].* = .{
                @intCast(0xe0 | (cp >> 12)),
                @intCast(0x80 | ((cp >> 6) & 0x3f)),
                @intCast(0x80 | (cp & 0x3f)),
            };
            break :blk Sample{ .bytes = self.generated[0..3], .scalars = 1 };
        } else if (case == .@"grapheme-churn" or case == .@"grapheme-repeat") blk: {
            const first = if (case == .@"grapheme-churn") self.next_grapheme else (self.grapheme_base + self.grapheme_repeat_offset) % grapheme_churn_count;
            encodeChurnCluster(self.generated[0..7], 'a', first);
            encodeChurnCluster(self.generated[7..14], 'b', (first + 1) % grapheme_churn_count);
            if (case == .@"grapheme-churn") {
                self.next_grapheme = (first + 2) % grapheme_churn_count;
            } else {
                self.grapheme_repeat_offset = (self.grapheme_repeat_offset + 2) % grapheme_repeat_count;
            }
            break :blk Sample{ .bytes = &self.generated, .scalars = 8 };
        } else blk: {
            const values = corpus(case);
            break :blk values[self.text.random().uintLessThan(usize, values.len)];
        };
        return .{
            .row = @intCast(slot / self.slots_per_row + 1),
            .col = @intCast((slot % self.slots_per_row) * 2 + 1),
            .text = value.bytes,
            .scalars = value.scalars,
            .foreground = 16 + self.foreground.random().uintLessThan(u8, 216),
            .background = 16 + self.background.random().uintLessThan(u8, 216),
        };
    }
};

/// Emits fixed-color setup for channels not varied by this workload.
pub fn beginFrame(out: *std.Io.Writer, config: Config, background: bool) !usize {
    var bytes: usize = 0;
    if (!config.foreground) {
        try out.writeAll("\x1b[38;5;7m");
        bytes += 9;
    }
    if (!background) {
        try out.writeAll("\x1b[49m");
        bytes += 5;
    }
    return bytes;
}

/// Buffers one bounded cursor/style/payload operation without adding a flush.
pub fn emit(out: *std.Io.Writer, op: Operation, foreground: bool, background: bool) !usize {
    var storage: [256]u8 = undefined;
    var command = std.Io.Writer.fixed(&storage);
    try command.print("\x1b[{d};{d}H", .{ op.row, op.col });
    if (foreground) try command.print("\x1b[38;5;{d}m", .{op.foreground});
    if (background) try command.print("\x1b[48;5;{d}m", .{op.background});
    try command.writeAll(op.text);
    try out.writeAll(command.buffered());
    return command.buffered().len;
}

/// Optional fixed-frame input digests; neither hash asserts terminal rendering.
pub const Digest = struct {
    positions: std.crypto.hash.sha2.Sha256 = .init(.{}),
    text: std.crypto.hash.sha2.Sha256 = .init(.{}),

    /// Includes geometry in the position namespace, independent of glyph/color case.
    pub fn init(size: terminal.Size) Digest {
        var self = Digest{};
        self.positions.update("tui-zoo.unicode.positions/v1");
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u16, bytes[0..2], size.cols, .big);
        std.mem.writeInt(u16, bytes[2..4], size.rows, .big);
        self.positions.update(&bytes);
        self.text.update("tui-zoo.unicode.text/v1");
        return self;
    }

    /// Hashes unambiguous coordinates and length-delimited payload bytes.
    pub fn record(self: *Digest, op: Operation) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u16, bytes[0..2], op.row, .big);
        std.mem.writeInt(u16, bytes[2..4], op.col, .big);
        self.positions.update(&bytes);
        var length: [2]u8 = undefined;
        std.mem.writeInt(u16, &length, @intCast(op.text.len), .big);
        self.text.update(&length);
        self.text.update(op.text);
    }
};

test "Unicode corpus has valid bounded text and intentional 24-scalar clusters" {
    inline for (@typeInfo(Case).@"enum".field_names) |name| {
        const case = std.meta.stringToEnum(Case, name).?;
        for (corpus(case)) |value| {
            try std.testing.expect(std.unicode.utf8ValidateSlice(value.bytes));
            try std.testing.expect(value.bytes.len <= 192);
            try std.testing.expectEqual(value.scalars, try std.unicode.utf8CountCodepoints(value.bytes));
            for (value.bytes) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
        }
    }
    try std.testing.expectEqual(@as(u16, 48), combining[7].scalars);
}

test "Unicode joining corpora hold deliberate fixed samples" {
    inline for (.{ .@"emoji-zwj", .@"indic-conjunct", .@"arabic-join", .@"hangul-nfc", .@"hangul-nfd" }) |case| {
        const values = corpus(case);
        try std.testing.expectEqual(@as(usize, 8), values.len);
        for (values) |value| try std.testing.expect(value.scalars > 0);
    }
    for (emoji_zwj) |value| try std.testing.expect(std.mem.indexOf(u8, value.bytes, "\u{200d}") != null);
    for (hangul_nfc, hangul_nfd) |composed, decomposed| {
        try std.testing.expectEqual(@as(u16, 1), composed.scalars);
        try std.testing.expect(decomposed.scalars == 2 or decomposed.scalars == 3);
    }
}

test "world scripts are a bounded opt-in fixed eight-sample corpus" {
    try std.testing.expectEqual(@as(usize, 8), corpus(.@"world-scripts").len);
    for (world_scripts) |value| {
        try std.testing.expect(value.scalars > 0 and value.scalars <= 6);
    }
}

test "Unicode slots cover odd geometry without wrapping and sequentially repeat" {
    try std.testing.expectError(error.InvalidArgs, Planner.init(1, .{ .cols = 1, .rows = 1 }, .{}));
    var plan = try Planner.init(1, .{ .cols = 5, .rows = 2 }, .{ .pattern = .sequential });
    const expected = [_][2]u16{ .{ 1, 1 }, .{ 1, 3 }, .{ 2, 1 }, .{ 2, 3 }, .{ 1, 1 } };
    for (expected) |coordinate| {
        const op = plan.next();
        try std.testing.expectEqual(coordinate[0], op.row);
        try std.testing.expectEqual(coordinate[1], op.col);
    }
    var maximum = try Planner.init(1, .{ .cols = 4096, .rows = 256 }, .{});
    for (0..1000) |_| {
        const op = maximum.next();
        try std.testing.expect(op.row <= 256 and op.col + 1 <= 4096 and op.col % 2 == 1);
    }
}

test "Unicode position and color streams survive corpus and traversal changes" {
    var a = try Planner.init(7, .{ .cols = 80, .rows = 24 }, .{ .case = .ascii });
    var b = try Planner.init(7, .{ .cols = 80, .rows = 24 }, .{ .case = .mixed, .foreground = true });
    var c = try Planner.init(7, .{ .cols = 80, .rows = 24 }, .{ .case = .mixed, .pattern = .sequential });
    for (0..1000) |_| {
        const x = a.next();
        const y = b.next();
        const z = c.next();
        try std.testing.expectEqual(x.row, y.row);
        try std.testing.expectEqual(x.col, y.col);
        try std.testing.expectEqual(x.foreground, y.foreground);
        try std.testing.expectEqual(x.background, y.background);
        try std.testing.expectEqualStrings(y.text, z.text);
        try std.testing.expectEqual(y.foreground, z.foreground);
    }
}

test "Unicode emission color channels alter only SGR and fit fixed scratch" {
    var out_storage: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_storage);
    const op = Operation{ .row = 4096, .col = 4095, .text = combining[7].bytes, .scalars = 48, .foreground = 231, .background = 230 };
    const fixed = try beginFrame(&out, .{}, false);
    try std.testing.expectEqual(fixed, out.buffered().len);
    const before = out.buffered().len;
    const bytes = try emit(&out, op, true, true);
    try std.testing.expectEqual(bytes, out.buffered().len - before);
    try std.testing.expect(bytes < 256);
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), op.text));
}

test "Unicode churn visits exactly 4096 valid CJK scalars before repeating" {
    var plan = try Planner.init(7, .{ .cols = 80, .rows = 24 }, .{ .case = .churn });
    var seen: [4096]bool = @splat(false);
    for (0..4096) |_| {
        const op = plan.next();
        const cp = try std.unicode.utf8Decode(op.text);
        try std.testing.expect(cp >= 0x4e00 and cp <= 0x5dff);
        const index = cp - 0x4e00;
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    try std.testing.expectEqual(@as(u21, 0x4e07), try std.unicode.utf8Decode(plan.next().text));
}

fn churnClusterIndex(cluster: []const u8) !u32 {
    try std.testing.expectEqual(@as(usize, 7), cluster.len);
    var result: u32 = 0;
    var place: u32 = 1;
    for (0..3) |i| {
        const mark = try std.unicode.utf8Decode(cluster[1 + 2 * i ..][0..2]);
        try std.testing.expect(mark >= 0x300 and mark < 0x370);
        result += @as(u32, mark - 0x300) * place;
        place *= grapheme_mark_count;
    }
    return result;
}

test "Unicode grapheme churn visits 262144 unique four-scalar clusters before repeating" {
    var plan = try Planner.init(7, .{ .cols = 80, .rows = 24 }, .{ .case = .@"grapheme-churn" });
    var seen: [grapheme_churn_count]bool = @splat(false);
    for (0..grapheme_churn_count / 2) |_| {
        const op = plan.next();
        try std.testing.expectEqual(@as(usize, 14), op.text.len);
        try std.testing.expectEqual(@as(u16, 8), op.scalars);
        try std.testing.expect(std.unicode.utf8ValidateSlice(op.text));
        for (0..2) |i| {
            const cluster = op.text[i * 7 ..][0..7];
            try std.testing.expectEqual(@as(u8, if (i == 0) 'a' else 'b'), cluster[0]);
            const index: usize = @intCast(try churnClusterIndex(cluster));
            try std.testing.expect(index < seen.len and !seen[index]);
            seen[index] = true;
        }
    }
    const repeated = plan.next();
    try std.testing.expectEqual(@as(u32, 7), try churnClusterIndex(repeated.text[0..7]));
    try std.testing.expectEqual(@as(u32, 8), try churnClusterIndex(repeated.text[7..14]));
}

test "Unicode grapheme churn preserves text across patterns and color settings" {
    var random = try Planner.init(123, .{ .cols = 79, .rows = 23 }, .{ .case = .@"grapheme-churn" });
    var sequential = try Planner.init(123, .{ .cols = 79, .rows = 23 }, .{
        .case = .@"grapheme-churn",
        .pattern = .sequential,
        .foreground = true,
    });
    for (0..1000) |_| {
        const a = random.next();
        const b = sequential.next();
        try std.testing.expectEqualStrings(a.text, b.text);
        try std.testing.expectEqual(a.foreground, b.foreground);
        try std.testing.expectEqual(a.background, b.background);
    }
}

test "Unicode grapheme repeat matches churn for 64 clusters then repeats exactly" {
    var churn = try Planner.init(20261115, .{ .cols = 80, .rows = 24 }, .{ .case = .@"grapheme-churn" });
    var repeat = try Planner.init(20261115, .{ .cols = 80, .rows = 24 }, .{ .case = .@"grapheme-repeat" });
    var first_pair: [14]u8 = undefined;
    for (0..grapheme_repeat_count / 2) |i| {
        const a = churn.next();
        const b = repeat.next();
        try std.testing.expectEqualStrings(a.text, b.text);
        try std.testing.expectEqual(a.scalars, b.scalars);
        if (i == 0) @memcpy(&first_pair, b.text);
    }
    try std.testing.expectEqualSlices(u8, &first_pair, repeat.next().text);
    try std.testing.expect(!std.mem.eql(u8, &first_pair, churn.next().text));
}
