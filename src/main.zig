const std = @import("std");
const latency = @import("latency.zig");
const cells = @import("cells.zig");
const rain = @import("rain.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 1 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        usage();
        return;
    }

    if (std.mem.eql(u8, args[1], "build-info")) {
        if (args.len != 2) {
            std.debug.print("{{\"error\":\"invalid_args\",\"workload\":\"build-info\"}}\n", .{});
            std.process.exit(2);
        }
        const builtin = @import("builtin");
        std.debug.print(
            "{{\"type\":\"tui_zoo.build/v1\",\"zig_version\":\"{s}\",\"optimize\":\"{s}\",\"zig_backend\":\"{s}\"}}\n",
            .{ builtin.zig_version_string, @tagName(builtin.optimize), @tagName(builtin.zig_backend) },
        );
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

    if (std.mem.eql(u8, args[1], "cells")) {
        cells.run(init, args[2..]) catch |err| switch (err) {
            error.HelpRequested => {},
            error.InvalidArgs => {
                std.debug.print("{{\"error\":\"invalid_args\",\"workload\":\"cells\"}}\n", .{});
                std.process.exit(2);
            },
            else => return err,
        };
        return;
    }

    if (std.mem.eql(u8, args[1], "latency")) {
        latency.run(init, args[2..]) catch |err| switch (err) {
            error.HelpRequested => {},
            error.InvalidArgs => {
                std.debug.print("{{\"error\":\"invalid_args\",\"workload\":\"latency\"}}\n", .{});
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
        \\usage: tui-zoo <command> [options]
        \\
        \\commands:
        \\  build-info compiler and optimization identity as JSON on stderr
        \\  rain    deterministic visual rain with explicit frame cadence
        \\  latency immediate one-cell reaction to each input byte
        \\  cells   deterministic random-cell dose curve for parser/render pressure
        \\
        \\run tui-zoo <workload> --help for workload options.
        \\
    , .{});
}

test {
    _ = latency;
    _ = cells;
    _ = rain;
}
