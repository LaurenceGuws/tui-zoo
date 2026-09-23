const std = @import("std");

pub const Pacer = struct {
    io: std.Io,
    interval: std.Io.Duration,
    next: std.Io.Clock.Timestamp,
    skipped_slots: u64 = 0,

    pub fn init(io: std.Io, fps: f64) !Pacer {
        const interval_ns = try intervalNanoseconds(fps);
        const interval = std.Io.Duration.fromNanoseconds(interval_ns);
        const clock_interval = std.Io.Clock.Duration{ .raw = interval, .clock = .awake };
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        return .{
            .io = io,
            .interval = interval,
            .next = now.addDuration(clock_interval),
        };
    }

    pub fn wait(self: *Pacer) !u64 {
        var now = std.Io.Clock.Timestamp.now(self.io, .awake);
        const interval = std.Io.Clock.Duration{ .raw = self.interval, .clock = .awake };

        if (now.compare(.lt, self.next)) {
            try self.next.wait(self.io);
            now = std.Io.Clock.Timestamp.now(self.io, .awake);
        }

        const late_ns_i = self.next.durationTo(now).raw.nanoseconds;
        const late_ns: u64 = if (late_ns_i > 0) @intCast(late_ns_i) else 0;

        self.next = self.next.addDuration(interval);
        while (!now.compare(.lt, self.next)) {
            self.skipped_slots += 1;
            self.next = self.next.addDuration(interval);
        }
        return late_ns;
    }
};

pub fn intervalNanoseconds(fps: f64) !i64 {
    if (!std.math.isFinite(fps) or fps <= 0.0 or fps > 1000.0) return error.InvalidRate;
    return @intFromFloat(@round(@as(f64, @floatFromInt(std.time.ns_per_s)) / fps));
}

test "60 Hz interval is nearest nanosecond" {
    try std.testing.expectEqual(@as(i64, 16_666_667), try intervalNanoseconds(60.0));
}

test "upstream 30 ms rain cadence is exact" {
    try std.testing.expectEqual(@as(i64, 30_000_000), try intervalNanoseconds(1000.0 / 30.0));
}

test "invalid rates are rejected" {
    try std.testing.expectError(error.InvalidRate, intervalNanoseconds(0.0));
    try std.testing.expectError(error.InvalidRate, intervalNanoseconds(1001.0));
}
