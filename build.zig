const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("bitman", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "bitman",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bitman", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // `zig build eval` evaluates the saved checkpoint snapshots.
    const eval_step = b.step("eval", "Evaluate saved snake checkpoints");
    const eval_cmd = b.addRunArtifact(exe);
    eval_cmd.step.dependOn(b.getInstallStep());
    eval_cmd.addArg("--eval");
    eval_step.dependOn(&eval_cmd.step);

    // `zig build replay` runs the same executable in file-replay mode.
    // snake_replay.rep is read from the process working directory.
    const replay_step = b.step("replay", "Replay saved snake generations");
    const replay_cmd = b.addRunArtifact(exe);
    replay_cmd.step.dependOn(b.getInstallStep());
    replay_cmd.addArg("--replay");
    replay_step.dependOn(&replay_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
