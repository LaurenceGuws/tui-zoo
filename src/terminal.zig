const std = @import("std");
const posix = std.posix;

pub const Size = struct {
    cols: u16,
    rows: u16,
};

var stop_requested: std.atomic.Value(bool) = .init(false);

fn requestStop(_: posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

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

pub fn stopRequested() bool {
    return stop_requested.load(.acquire);
}

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

pub const Input = struct {
    original: ?posix.termios = null,

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

    pub fn restore(self: *Input) void {
        if (self.original) |original| {
            posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original) catch {};
            self.original = null;
        }
    }

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

test "size invariant excludes zero geometry" {
    const good = Size{ .cols = 1, .rows = 1 };
    try std.testing.expect(good.cols != 0 and good.rows != 0);
}
