//! Non-installed Developer Verification, Fuzzing & Profiling Runner (`zig build prove|fuzz|bench|profile`).
//!
//! Kept completely separate from the production `zig_vcs` CLI binary (`src/main.zig` / `src/cli.zig`)
//! so that the final built executable (`zig-out/bin/zig_vcs`) contains only real version control
//! commands and does not bundle model-checking, fuzzing, or benchmark harnesses.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zig_vcs = @import("zig_vcs");

const tla = zig_vcs.tla;
const vcs_model = zig_vcs.vcs_model;
const visualize = zig_vcs.visualize;
const conformance_fuzzer = zig_vcs.conformance_fuzzer;
const perf_profiler = zig_vcs.perf_profiler;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name

    const mode = args_iter.next() orelse "prove";

    if (std.mem.eql(u8, mode, "prove")) {
        try runFormalVerificationAndDemo(gpa, io, stdout);
    } else if (std.mem.eql(u8, mode, "bench") or std.mem.eql(u8, mode, "profile")) {
        var use_macos_profiler = std.mem.eql(u8, mode, "profile");
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--macos-profile") or
                std.mem.eql(u8, arg, "--profile") or
                std.mem.eql(u8, arg, "-p"))
            {
                use_macos_profiler = true;
            }
        }
        try perf_profiler.runAndPrintBenchmarks(gpa, io, stdout, use_macos_profiler);
    } else if (std.mem.eql(u8, mode, "fuzz")) {
        const stats = try conformance_fuzzer.runDifferentialFuzzCampaign(gpa, 0xC0FFEE_2026, 25, 60);
        try stdout.print(
            \\=== Differential Conformance Fuzzer & Torn-Write Crash Recovery ===
            \\  Trials Executed           : {d}
            \\  Total Randomized Steps    : {d}
            \\  Commits / Merges / Rebases: {d} / {d} / {d}
            \\  Branch Switches & Undos   : {d} / {d}
            \\  Torn-Write Crash Recoveries: {d} (100% recovered via Dual-Superblock)
            \\  >>> ALL 6 FORMAL INVARIANTS (INV-1..INV-6) HELD AT EVERY STEP <<<
            \\
        , .{
            stats.trials_run,
            stats.total_steps_executed,
            stats.commits_created,
            stats.merges_executed,
            stats.rebases_executed,
            stats.switches_executed,
            stats.undos_executed,
            stats.crash_recoveries_verified,
        });
    } else {
        try stdout.print("Usage: verify_runner <prove|fuzz|bench|profile>\n", .{});
    }

    try stdout.flush();
}

fn runFormalVerificationAndDemo(gpa: Allocator, io: Io, stdout: *Io.Writer) !void {
    const SafeChecker = tla.ModelChecker(vcs_model.SafeVcsSpec);
    var safe_res = try SafeChecker.check(gpa, .{
        .max_states = 3000,
        .max_depth = 7,
        .check_deadlocks = true,
    });
    defer safe_res.deinit();

    try visualize.printModelCheckSummary(
        "SafeVcsSpec (Fossil Single-DB + Git Worktrees/Branches + Auto-Draft + Oplog)",
        &vcs_model.SafeVcsSpec.invariants,
        safe_res,
        stdout,
    );

    const NaiveChecker = tla.ModelChecker(vcs_model.NaiveVcsSpec);
    var naive_res = try NaiveChecker.check(gpa, .{
        .max_states = 3000,
        .max_depth = 7,
        .check_deadlocks = true,
    });
    defer naive_res.deinit();

    try visualize.printModelCheckSummary(
        "NaiveVcsSpec (Branch Switch Without Single-DB Auto-Draft)",
        &vcs_model.NaiveVcsSpec.invariants,
        naive_res,
        stdout,
    );

    const fuzz_stats = try conformance_fuzzer.runDifferentialFuzzCampaign(gpa, 0xC0FFEE_2026, 20, 50);
    try stdout.print(
        \\
        \\========================================================================
        \\  DIFFERENTIAL CONFORMANCE FUZZER & DUAL-SUPERBLOCK CRASH RECOVERY
        \\========================================================================
        \\  Randomized Trials / Steps : {d} trials / {d} steps
        \\  Commits / Merges / Rebases: {d} / {d} / {d}
        \\  Branch Switches & Undos   : {d} / {d}
        \\  Torn-Write Crash Faults   : {d} injected & 100% recovered (Slot A/B fallback)
        \\  >>> STATUS: ALL 6 FORMAL INVARIANTS (INV-1..INV-6) VERIFIED <<<
        \\
    , .{
        fuzz_stats.trials_run,
        fuzz_stats.total_steps_executed,
        fuzz_stats.commits_created,
        fuzz_stats.merges_executed,
        fuzz_stats.rebases_executed,
        fuzz_stats.switches_executed,
        fuzz_stats.undos_executed,
        fuzz_stats.crash_recoveries_verified,
    });

    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    const html_file = try Io.Dir.cwd().createFile(io, "zig-out/vcs-model-explorer.html", .{});
    defer html_file.close(io);

    var html_buf: [4096]u8 = undefined;
    var html_writer: Io.File.Writer = .init(html_file, io, &html_buf);
    try visualize.writeInteractiveHtml(safe_res, naive_res, 80, &html_writer.interface);
    try html_writer.interface.flush();

    try stdout.print("\n[Visualizer] Generated interactive Single-DB + TLA+ state explorer:\n", .{});
    try stdout.print("             zig-out/vcs-model-explorer.html\n\n", .{});
}
