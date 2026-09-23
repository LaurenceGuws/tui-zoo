const std = @import("std");
const rain = @import("rain.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 1 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        usage();
        return;
    }

    if (std.mem.eql(u8, args[1], "rain")) {
        rain.run(init, args[2..]) catch |err| switch (err) {
            error.HelpRequested => {},
            error.InvalidArgs => {
                std.debug.print("{{\"error\":\"invalid_args\",\"workload\":\"rain\"}}\n", .{});
                std.process.exit(2);
            },
            else => return err,
        };
        return;
    }

    std.debug.print("{{\"error\":\"unknown_workload\",\"value\":\"{s}\"}}\n", .{args[1]});
    std.process.exit(2);
}

fn usage() void {
    std.debug.print(
        \\usage: tui-zoo <workload> [options]
        \\
        \\workloads:
        \\  rain    deterministic visual rain with explicit frame cadence
        \\
        \\run tui-zoo rain --help for workload options.
        \\
    , .{});
}

test {
    _ = rain;
}
