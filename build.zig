const std = @import("std");

/// Builds the standalone workload executable and its independent source/test gates.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tui-zoo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run tui-zoo").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit and emitted-byte CLI proofs");
    test_step.dependOn(&run_tests.step);
    const cli_tests = b.addSystemCommand(&.{"python3"});
    cli_tests.addFileArg(b.path("tests/unicode.py"));
    cli_tests.addFileArg(exe.getEmittedBin());
    test_step.dependOn(&cli_tests.step);

    const audit_command = b.addSystemCommand(&.{ "zig-audit", "check" });
    audit_command.setCwd(b.path("."));
    const audit = b.step("audit", "Check maintained Zig source with ruleset 3");
    audit.dependOn(&audit_command.step);

    const check = b.step("check", "Compile, run unit tests, and audit Zig source");
    check.dependOn(&exe.step);
    check.dependOn(&run_tests.step);
    check.dependOn(&cli_tests.step);
    check.dependOn(audit);
}
