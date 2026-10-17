const std = @import("std");
const posix = std.posix;

/// Terminal viewport in cells; successful queries always have nonzero dimensions.
pub const Size = struct {
    cols: u16,
    rows: u16,
};

var stop_requested: std.atomic.Value(bool) = .init(false);

fn requestStop(_: posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

/// Installs signal-safe stop flags so the workload can restore the terminal normally.
pub fn installStopHandlers() void {
    stop_requested.store(false, .release);
    const action = posix.Sigaction{
        .handler = .{ .handler = requestStop },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &action, null);
    posix.sigaction(posix.SIG.TERM, &action, null);
    posix.sigaction(posix.SIG.HUP, &action, null);
}

/// Returns whether SIGINT, SIGTERM or SIGHUP requested graceful termination.
pub fn stopRequested() bool {
    return stop_requested.load(.acquire);
}

/// Reads a nonzero terminal viewport, or null when ioctl cannot provide one.
pub fn querySize(fd: posix.fd_t) ?Size {
    var winsize = posix.winsize{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const result = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (posix.errno(result) != .SUCCESS or winsize.col == 0 or winsize.row == 0) return null;
    return .{ .cols = winsize.col, .rows = winsize.row };
}

/// RAII-like raw-input guard; an inactive guard makes piped/non-TTY input safe.
pub const Input = struct {
    original: ?posix.termios = null,

    /// Disables line editing and echo on stdin, retaining the original mode for restore.
    /// If stdin is not a TTY or mode switching fails, returns an inactive guard.
    pub fn enter() Input {
        const original = posix.tcgetattr(posix.STDIN_FILENO) catch return .{};
        var raw = original;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        // Keep ISIG enabled so Ctrl-C remains a real terminal signal.
        raw.cc[@backingInt(posix.V.MIN)] = 0;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch return .{};
        return .{ .original = original };
    }

    /// Restores the original termios, retaining it for a retry if tcsetattr fails.
    pub fn restore(self: *Input) !void {
        if (self.original) |original| {
            try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original);
            self.original = null;
        }
    }

    /// Consumes available stdin bytes and detects an explicit q/Q request.
    pub fn wantsQuit(_: *const Input) bool {
        var descriptors = [_]posix.pollfd{.{
            .fd = posix.STDIN_FILENO,
            .events = posix.POLL.IN | posix.POLL.HUP,
            .revents = 0,
        }};
        const ready = posix.poll(&descriptors, 0) catch return false;
        if (ready == 0 or descriptors[0].revents & posix.POLL.IN == 0) return false;

        var bytes: [32]u8 = undefined;
        const read_count = posix.read(posix.STDIN_FILENO, &bytes) catch return false;
        for (bytes[0..read_count]) |byte| {
            if (byte == 'q' or byte == 'Q') return true;
        }
        return false;
    }
};

/// A semantic frame that closes synchronized-output mode even on write failure.
/// Only a successful stdout flush completes a frame; abort reports recovery failure.
pub const Frame = struct {
    out: *std.Io.Writer,
    synchronized: bool,
    opened: bool = false,

    /// Starts optional CSI ?2026 framing, recording ownership before the first write.
    pub fn begin(self: *Frame) !void {
        if (!self.synchronized) return;
        self.opened = true;
        try self.out.writeAll("\x1b[?2026h");
    }

    /// Closes the frame and flushes its bytes, propagating any output failure.
    pub fn finish(self: *Frame) !void {
        if (self.opened) try self.out.writeAll("\x1b[?2026l");
        try self.out.flush();
        self.opened = false;
    }

    /// Error-exit recovery only: attempt a closing marker and flush, logging failures.
    /// A broken stdout cannot guarantee closure and must not produce a success receipt.
    pub fn abort(self: *Frame) void {
        if (!self.opened) return;
        var closed = true;
        self.out.writeAll("\x1b[?2026l") catch |err| {
            reportCleanupError("sync_end", @errorName(err));
            closed = false;
        };
        self.out.flush() catch |err| {
            reportCleanupError("sync_flush", @errorName(err));
            closed = false;
        };
        if (closed) self.opened = false;
    }
};

/// Writes a structured stderr diagnostic when best-effort error cleanup also fails.
/// Stage and cause are internal constants/error names, never unescaped user text.
pub fn reportCleanupError(stage: []const u8, cause: []const u8) void {
    std.debug.print("{{\"error\":\"terminal_cleanup_failed\",\"stage\":\"{s}\",\"cause\":\"{s}\"}}\n", .{ stage, cause });
}

test "size invariant excludes zero geometry" {
    const good = Size{ .cols = 1, .rows = 1 };
    try std.testing.expect(good.cols != 0 and good.rows != 0);
}

test "synchronized frame closes after ordinary and error-exit paths" {
    var storage: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    var frame = Frame{ .out = &out, .synchronized = true };
    try frame.begin();
    try out.writeByte('x');
    try frame.finish();
    frame.abort(); // Completed frames must not emit duplicate closers.
    try std.testing.expectEqualStrings("\x1b[?2026hx\x1b[?2026l", out.buffered());

    var error_storage: [64]u8 = undefined;
    var error_out = std.Io.Writer.fixed(&error_storage);
    var failed = Frame{ .out = &error_out, .synchronized = true };
    try failed.begin();
    try error_out.writeByte('x');
    failed.abort();
    try std.testing.expect(!failed.opened);
    try std.testing.expectEqualStrings("\x1b[?2026hx\x1b[?2026l", error_out.buffered());
}

test "failed frame closure remains an error and leaves recovery pending" {
    var storage: [8]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    var frame = Frame{ .out = &out, .synchronized = true };
    try frame.begin();
    try std.testing.expectError(error.WriteFailed, frame.finish());
    try std.testing.expect(frame.opened);
}
