//! High-Resolution CPU Profiler & Complex Repository Benchmark Suite (`zig build run -- bench`).
//!
//! Profiles wall-clock latency (`ms` / `us`) and throughput (`ops/sec`) across complex,
//! large-scale repository workloads while verifying all 6 formal invariants (`INV-1`..`INV-6`):
//! 1. **Workload A (Complex Multi-Branch / Multi-Worktree DAG Stress Suite)**:
//!    - 500 tracked files across 25 nested directories (`src/mod_00/` .. `src/mod_24/`).
//!    - 80 commits across 6 concurrent branches (`main`, `feat-alpha`, `feat-beta`, `feat-gamma`,
//!      `hotfix`, `release`) and 3 isolated worktrees (`wt0`, `wt1`, `wt2`).
//!    - Exercises 3-way algebraic merges (`B + C - A`), Crisscross virtual merge bases, Pierce
//!      anchor-separated hunk lifting, multi-commit `rebase`, `cherry-pick` + `backout` cancellation,
//!      historical `amend` and `squash` with topological descendant cascade, path-selective commit,
//!      `mv` rename tracking, `diff` / `formatDiffStat`, `blame`, `bisect`, `verifyIntegrity` (`fsck`),
//!      and 4KB Dual-Superblock `saveToFile` / `loadFromFile` roundtrip.
//! 2. **Workload B (Real-World Large Source Tree Native `.git` Clone & Materialization)**:
//!    - Benchmarks native `.git` import (`loadRepoDbFromGitDir`), disk materialization
//!      (`materializeWorktreeToDir`), and warm `stat_cache` worktree scanning (`syncWorktreeFromDisk`)
//!      against `ref/fossil` (988 real C/Tcl files, ~37 MB) when present on disk.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const repo_db = @import("../storage/repo_db.zig");
const tree_sum = @import("../algebra/tree_sum.zig");
const materializer = @import("../worktree/materializer.zig");
const git_interop = @import("../interop/git_interop.zig");
const conformance_fuzzer = @import("conformance_fuzzer.zig");

pub const RepoDb = repo_db.RepoDb;
pub const CommitId = repo_db.CommitId;

pub const PhaseMeasurement = struct {
    name: []const u8,
    operations: usize,
    elapsed_ns: u64,

    pub fn elapsedMs(self: PhaseMeasurement) f64 {
        return @as(f64, @floatFromInt(self.elapsed_ns)) / 1_000_000.0;
    }

    pub fn usPerOp(self: PhaseMeasurement) f64 {
        if (self.operations == 0) return 0.0;
        return (@as(f64, @floatFromInt(self.elapsed_ns)) / 1_000.0) / @as(f64, @floatFromInt(self.operations));
    }
};

pub const ComplexBenchReport = struct {
    num_files: usize,
    total_commits: usize,
    total_trees: usize,
    total_blobs: usize,
    serialized_bytes: usize,
    phases: [8]PhaseMeasurement,
    total_elapsed_ns: u64,
};

fn nowNs(io: Io) u64 {
    const ts = Io.Clock.awake.now(io);
    return @intCast(@max(0, ts.nanoseconds));
}

/// Execute the Complex Multi-Branch / Multi-Worktree DAG Stress Benchmark and verify `INV-1`..`INV-6`.
pub fn runComplexRepoBenchmark(
    allocator: Allocator,
    io: Io,
    num_files: usize,
    num_branch_commits: usize,
) !ComplexBenchReport {
    const suite_start = nowNs(io);
    var phases: [8]PhaseMeasurement = undefined;

    var db = try RepoDb.initNew(allocator, "/tmp/bench-wt0");
    defer db.deinit();

    // ========================================================================
    // Phase 1: Seed `num_files` nested files across 25 module directories
    // ========================================================================
    const p1_start = nowNs(io);
    {
        var base_manifest: tree_sum.TreeManifest = .{};
        errdefer base_manifest.deinit(allocator);
        try base_manifest.entries.ensureTotalCapacity(allocator, num_files);

        for (0..num_files) |f_idx| {
            const mod_idx = f_idx / 20;
            const path = try std.fmt.allocPrint(allocator, "src/mod_{d:0>2}/file_{d:0>4}.zig", .{ mod_idx, f_idx });
            errdefer allocator.free(path);

            const content = try std.fmt.allocPrint(
                allocator,
                "// Module {d} File {d}\npub const HEADER_{d}: u32 = {d};\n// === UNIQUE_ANCHOR_ALPHA_{d} ===\npub const MIDDLE_{d}: u32 = 100;\n// === UNIQUE_ANCHOR_BETA_{d} ===\npub const FOOTER_{d}: u32 = {d};\n",
                .{ mod_idx, f_idx, f_idx, f_idx * 7, f_idx, f_idx, f_idx, f_idx, f_idx * 13 },
            );
            defer allocator.free(content);

            const blob_hash = try db.putBlob(content);
            const sum = try tree_sum.PathSum.fromClean(allocator, blob_hash);
            base_manifest.entries.appendAssumeCapacity(.{
                .path = path,
                .sum = sum,
                .mode = .regular,
            });
        }
        base_manifest.sortEntries();
        const seed_tid = try db.internTreeOwned(base_manifest);
        _ = try db.applyWorkingTreeSync(0, seed_tid);
        _ = try db.commitWorktree(0, "architect", "Seed initial 500-file modular codebase");
    }
    phases[0] = .{
        .name = "Seed Nested Tree + Initial Commit",
        .operations = num_files,
        .elapsed_ns = nowNs(io) -| p1_start,
    };

    // ========================================================================
    // Phase 2: Multi-Branch Commits, Worktree Isolation & Draft Shelving
    // ========================================================================
    const p2_start = nowNs(io);
    const branch_names = [_][]const u8{
        "main",
        "feat-alpha",
        "feat-beta",
        "feat-gamma",
        "hotfix",
        "release",
    };
    const wt1 = try db.addWorktree("wt1", "/tmp/bench-wt1", "feat-alpha");
    const wt2 = try db.addWorktree("wt2", "/tmp/bench-wt2", "feat-beta");

    for (0..num_branch_commits) |step| {
        const br_name = branch_names[step % branch_names.len];
        const active_wt: repo_db.WorktreeId = switch (step % 3) {
            0 => 0,
            1 => wt1,
            else => wt2,
        };
        _ = try db.switchBranch(active_wt, br_name);

        // Modify 2 files per commit in different regions around the unique anchors
        const f1 = (step * 17) % num_files;
        const f2 = (step * 31 + 7) % num_files;
        const mod1 = f1 / 20;
        const mod2 = f2 / 20;

        const path1 = try std.fmt.allocPrint(allocator, "src/mod_{d:0>2}/file_{d:0>4}.zig", .{ mod1, f1 });
        defer allocator.free(path1);
        const body1 = try std.fmt.allocPrint(
            allocator,
            "// Module {d} File {d}\npub const HEADER_{d}: u32 = {d};\n// === UNIQUE_ANCHOR_ALPHA_{d} ===\npub const MIDDLE_{d}: u32 = 100;\n// === UNIQUE_ANCHOR_BETA_{d} ===\npub const FOOTER_{d}: u32 = {d};\n",
            .{ mod1, f1, f1, step + 1000, f1, f1, f1, f1, f1 * 13 },
        );
        defer allocator.free(body1);
        try db.editFile(active_wt, path1, body1);

        const path2 = try std.fmt.allocPrint(allocator, "src/mod_{d:0>2}/file_{d:0>4}.zig", .{ mod2, f2 });
        defer allocator.free(path2);
        const body2 = try std.fmt.allocPrint(
            allocator,
            "// Module {d} File {d}\npub const HEADER_{d}: u32 = {d};\n// === UNIQUE_ANCHOR_ALPHA_{d} ===\npub const MIDDLE_{d}: u32 = 100;\n// === UNIQUE_ANCHOR_BETA_{d} ===\npub const FOOTER_{d}: u32 = {d};\n",
            .{ mod2, f2, f2, f2 * 7, f2, f2, f2, f2, step + 5000 },
        );
        defer allocator.free(body2);
        try db.editFile(active_wt, path2, body2);

        const msg = try std.fmt.allocPrint(allocator, "Commit #{d} on {s}", .{ step + 1, br_name });
        defer allocator.free(msg);

        if (step % 7 == 0) {
            // Path-selective commit: commit only `path1`, leaving `path2` as an uncommitted draft,
            // then commit the remaining draft so both paths are preserved!
            const filters = [_][]const u8{path1};
            _ = try db.commitWorktreePaths(active_wt, "dev", msg, &filters);
            _ = try db.commitWorktree(active_wt, "dev", "Follow-up commit for remaining draft");
        } else {
            _ = try db.commitWorktree(active_wt, "dev", msg);
        }
    }
    phases[1] = .{
        .name = "Multi-Branch Commits & Worktree Switches",
        .operations = num_branch_commits,
        .elapsed_ns = nowNs(io) -| p2_start,
    };

    // ========================================================================
    // Phase 3: 3-Way Algebraic Merges (B + C - A), Crisscross & Anchor Lifting
    // ========================================================================
    const p3_start = nowNs(io);
    _ = try db.switchBranch(0, "main");
    _ = try db.mergeBranch(0, "feat-alpha", "merger", "Merge feat-alpha into main");
    _ = try db.mergeBranch(0, "feat-beta", "merger", "Merge feat-beta into main");
    _ = try db.switchBranch(wt1, "feat-gamma");
    _ = try db.mergeBranch(wt1, "hotfix", "merger", "Merge hotfix into feat-gamma");
    _ = try db.switchBranch(0, "main");
    const octopus_sources = [_][]const u8{ "feat-gamma", "release" };
    _ = try db.mergeMultipleBranches(0, &octopus_sources, "merger", "Octopus merge feat-gamma and release");
    phases[2] = .{
        .name = "3-Way Algebraic & Octopus Merges (B+C-A)",
        .operations = 5,
        .elapsed_ns = nowNs(io) -| p3_start,
    };

    // ========================================================================
    // Phase 4: Rebase + Cherry-Pick + Backout Cancellation
    // ========================================================================
    const p4_start = nowNs(io);
    _ = try db.rebaseCommitOnto("hotfix", "main");
    const head_before_cp = db.branches.items[db.worktrees.items[0].branch_id].head_commit;
    const head_tree_before_cp = db.commits.items[head_before_cp].root_tree_id;
    const cp_cid = try db.cherryPickCommit(0, 2, "picker", "Cherry-pick c2 onto main");
    _ = try db.backoutCommit(0, cp_cid, "picker", "Backout cherry-picked commit");
    const head_after_bo = db.branches.items[db.worktrees.items[0].branch_id].head_commit;
    if (db.commits.items[head_after_bo].root_tree_id != head_tree_before_cp) {
        return error.CherryPickBackoutIdentityViolated;
    }
    phases[3] = .{
        .name = "Multi-Commit Rebase + CherryPick/Backout",
        .operations = 3,
        .elapsed_ns = nowNs(io) -| p4_start,
    };

    // ========================================================================
    // Phase 5: Historical Amend & Squash with Topological Descendant Cascade
    // ========================================================================
    const p5_start = nowNs(io);
    try db.editFile(0, "src/mod_00/file_0000.zig", "// Amended header on main\npub const AMENDED: bool = true;\n");
    _ = try db.amendCommit(0, null, "Amended tip commit on main");
    _ = try db.squashCommit(0, null, "Squashed tip commit into parent on main");
    phases[4] = .{
        .name = "Amend + Squash with Descendant Cascade",
        .operations = 2,
        .elapsed_ns = nowNs(io) -| p5_start,
    };

    // ========================================================================
    // Phase 6: Unified Diff, DiffStat, Log Graph, Blame & Bisect
    // ========================================================================
    const p6_start = nowNs(io);
    {
        const main_cid = db.branches.items[0].head_commit;
        const main_tid = db.commits.items[main_cid].root_tree_id;
        const root_tid = db.commits.items[1].root_tree_id;

        const diff_txt = try db.diffTreesUnified(allocator, root_tid, main_tid);
        defer allocator.free(diff_txt);

        const stat_txt = try db.formatDiffStat(allocator, root_tid, main_tid);
        defer allocator.free(stat_txt);

        const log_txt = try db.formatCommitLogFiltered(allocator, main_cid, 15, true);
        defer allocator.free(log_txt);

        const blame_txt = try db.blameFile(allocator, main_cid, "src/mod_00/file_0000.zig");
        defer allocator.free(blame_txt);

        _ = try db.bisectCommitRange(allocator, 1, main_cid, "src/mod_00/file_0000.zig", "AMENDED");
    }
    phases[5] = .{
        .name = "Diff + DiffStat + Log --stat + Blame + Bisect",
        .operations = 5,
        .elapsed_ns = nowNs(io) -| p6_start,
    };

    // ========================================================================
    // Phase 7: Cryptographic & Algebraic Integrity Verification (`fsck`) + `INV-1..6`
    // ========================================================================
    const p7_start = nowNs(io);
    const fsck_rep = try db.verifyIntegrity();
    if (fsck_rep.commits_verified != db.commits.items.len) return error.FsckMismatch;
    try conformance_fuzzer.checkAllFormalInvariants(&db, 0, 0);
    phases[6] = .{
        .name = "Full Cryptographic & Algebraic fsck (INV-1..6)",
        .operations = db.commits.items.len + db.trees.items.len + db.blobs.items.len,
        .elapsed_ns = nowNs(io) -| p7_start,
    };

    // ========================================================================
    // Phase 8: Compact ZDL1 Serialization & Deserialization Roundtrip
    // ========================================================================
    const p8_start = nowNs(io);
    const compact_bytes = try db.serializeToBytesCompact(allocator);
    defer allocator.free(compact_bytes);

    var reloaded = try RepoDb.deserializeFromBytes(allocator, compact_bytes);
    defer reloaded.deinit();
    if (reloaded.commits.items.len != db.commits.items.len or
        reloaded.trees.items.len != db.trees.items.len)
    {
        return error.RoundtripCountMismatch;
    }
    phases[7] = .{
        .name = "Compact ZDL1 Serialize + Zero-Copy Load",
        .operations = 2,
        .elapsed_ns = nowNs(io) -| p8_start,
    };

    return .{
        .num_files = num_files,
        .total_commits = db.commits.items.len,
        .total_trees = db.trees.items.len,
        .total_blobs = db.blobs.items.len,
        .serialized_bytes = compact_bytes.len,
        .phases = phases,
        .total_elapsed_ns = nowNs(io) -| suite_start,
    };
}

/// Print the formatted CPU Profile & Complex Repository Benchmark report to `writer`.
/// When `use_macos_profiler == true`, also attaches macOS's native `/usr/bin/sample` 1ms call-stack
/// profiler (`1000 Hz`), saves the full symbolicated call graph to `zig-out/macos-cpu-profile.txt`,
/// and prints the top hot stack frames.
pub fn runAndPrintBenchmarks(
    allocator: Allocator,
    io: Io,
    writer: *Io.Writer,
    use_macos_profiler: bool,
) !void {
    const rep = try runComplexRepoBenchmark(allocator, io, 500, 80);

    try writer.writeAll("\n========================================================================================\n");
    try writer.writeAll("  ZIG-VCS CPU PROFILER & COMPLEX REPOSITORY BENCHMARK SUITE\n");
    try writer.writeAll("========================================================================================\n");
    try writer.print(
        "  Repository Scale : {d} tracked files | {d} commits | {d} trees | {d} blobs\n",
        .{ rep.num_files, rep.total_commits, rep.total_trees, rep.total_blobs },
    );
    try writer.print(
        "  Compact DB Size  : {d:.2} MB ({d} bytes, ZIGVCS02 + ZDL1 delta compression)\n",
        .{ @as(f64, @floatFromInt(rep.serialized_bytes)) / (1024.0 * 1024.0), rep.serialized_bytes },
    );
    try writer.writeAll("----------------------------------------------------------------------------------------\n");
    try writer.writeAll("  Phase                                              Ops      Time (ms)     us / op\n");
    try writer.writeAll("----------------------------------------------------------------------------------------\n");
    for (rep.phases) |p| {
        try writer.print(
            "  {s:<48} {d:>5}    {d:>9.2} ms   {d:>8.1} us\n",
            .{ p.name, p.operations, p.elapsedMs(), p.usPerOp() },
        );
    }
    try writer.writeAll("----------------------------------------------------------------------------------------\n");
    try writer.print(
        "  TOTAL COMPLEX WORKLOAD TIME                      {d:>18.2} ms\n",
        .{@as(f64, @floatFromInt(rep.total_elapsed_ns)) / 1_000_000.0},
    );
    try writer.writeAll("  Formal Invariants (INV-1..INV-6) & fsck          100% VERIFIED\n");
    try writer.writeAll("========================================================================================\n");

    // Optional Workload B: Profile real-world `ref/fossil` repository (988 files, 37 MB) if present
    if (Io.Dir.cwd().statFile(io, "ref/fossil/.git/HEAD", .{})) |_| {
        try writer.writeAll("\n========================================================================================\n");
        try writer.writeAll("  REAL-WORLD REPOSITORY PROFILE: ref/fossil (988 files, ~37 MB C/Tcl source tree)\n");
        try writer.writeAll("========================================================================================\n");

        const t0 = nowNs(io);
        var fossil_db = try git_interop.loadRepoDbFromGitRemote(allocator, io, ".zig-cache/tmp", "ref/fossil");
        defer fossil_db.deinit();
        const t1 = nowNs(io);

        const tmp_dir = ".zig-cache/tmp/bench-fossil-checkout";
        Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
        defer Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

        try materializer.materializeWorktreeToDir(allocator, io, &fossil_db, 0, tmp_dir);
        const t2 = nowNs(io);

        // First scan after checkout verifies stability; second scan measures warm stat_cache hits
        _ = try materializer.syncWorktreeFromDisk(allocator, io, &fossil_db, 0, tmp_dir);
        const t3 = nowNs(io);
        const warm_stats = try materializer.syncWorktreeFromDisk(allocator, io, &fossil_db, 0, tmp_dir);
        const t4 = nowNs(io);

        const db_file = ".zig-cache/tmp/bench-fossil.vcs";
        defer Io.Dir.cwd().deleteFile(io, db_file) catch {};
        try fossil_db.saveToFile(io, db_file);
        const t5 = nowNs(io);

        var loaded_fossil = try RepoDb.loadFromFile(allocator, io, db_file);
        defer loaded_fossil.deinit();
        const t6 = nowNs(io);

        try writer.print(
            "  1. Native .git Fast-Export Import ({d} blobs)    : {d:>8.2} ms\n",
            .{ fossil_db.blobs.items.len, @as(f64, @floatFromInt(t1 -| t0)) / 1_000_000.0 },
        );
        try writer.print(
            "  2. Zero-Copy Worktree Checkout (988 files)       : {d:>8.2} ms\n",
            .{@as(f64, @floatFromInt(t2 -| t1)) / 1_000_000.0},
        );
        try writer.print(
            "  3. Initial Racy-Guard Verification Scan          : {d:>8.2} ms\n",
            .{@as(f64, @floatFromInt(t3 -| t2)) / 1_000_000.0},
        );
        try writer.print(
            "  4. Warm stat_cache Worktree Scan ({d} hits)      : {d:>8.2} ms\n",
            .{ warm_stats.stat_cache_hits, @as(f64, @floatFromInt(t4 -| t3)) / 1_000_000.0 },
        );
        try writer.print(
            "  5. 4KB Shadow-Paged DB Save (ZDL1 compact)       : {d:>8.2} ms\n",
            .{@as(f64, @floatFromInt(t5 -| t4)) / 1_000_000.0},
        );
        try writer.print(
            "  6. Zero-Copy Superblock DB Load                  : {d:>8.2} ms\n",
            .{@as(f64, @floatFromInt(t6 -| t5)) / 1_000_000.0},
        );
        try writer.writeAll("========================================================================================\n");
    } else |_| {}

    if (use_macos_profiler) {
        try runMacosSampleProfile(allocator, io, writer);
    }
}

/// Attach macOS's native `/usr/bin/sample` profiler (`1 ms` interval = 1,000 Hz) to the current
/// process while running sustained complex-repository benchmark iterations, write the full
/// symbolicated call graph to `zig-out/macos-cpu-profile.txt`, and print the hottest stack frames.
pub fn runMacosSampleProfile(allocator: Allocator, io: Io, writer: *Io.Writer) !void {
    if (comptime builtin.os.tag != .macos) {
        try writer.writeAll("\n[macOS Profiler] `/usr/bin/sample` is only available on macOS.\n");
        return;
    }

    try Io.Dir.cwd().createDirPath(io, "zig-out");
    const profile_path = "zig-out/macos-cpu-profile.txt";
    Io.Dir.cwd().deleteFile(io, profile_path) catch {};

    const pid = std.c.getpid();
    const pid_str = try std.fmt.allocPrint(allocator, "{d}", .{pid});
    defer allocator.free(pid_str);

    try writer.writeAll("\n========================================================================================\n");
    try writer.print("  MACOS NATIVE CALL-STACK PROFILER (/usr/bin/sample, PID={d}, 1ms / 1000Hz)\n", .{pid});
    try writer.writeAll("========================================================================================\n");
    try writer.flush();

    var sampler = try std.process.spawn(io, .{
        .argv = &.{
            "/usr/bin/sample",
            pid_str,
            "2",
            "1",
            "-mayDie",
            "-fullPaths",
            "-file",
            profile_path,
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    const loop_start = nowNs(io);
    var iterations: usize = 0;
    while (nowNs(io) -| loop_start < 2_300_000_000) {
        _ = try runComplexRepoBenchmark(allocator, io, 500, 80);
        iterations += 1;
    }

    _ = try sampler.wait(io);

    const profile_bytes = Io.Dir.cwd().readFileAlloc(io, profile_path, allocator, .unlimited) catch |err| {
        try writer.print("  [Warning] Failed to read {s}: {}\n", .{ profile_path, err });
        return;
    };
    defer allocator.free(profile_bytes);

    try writer.print("  Sustained Workload : {d} full 500-file / 118-commit DAG iterations during 2s capture\n", .{iterations});
    try writer.print("  Full Call Graph    : {s} ({d} KB)\n", .{ profile_path, profile_bytes.len / 1024 });

    // Extract and print the `Analysis of sampling` summary line
    if (std.mem.indexOf(u8, profile_bytes, "Analysis of sampling")) |idx| {
        const line_end = std.mem.indexOfScalarPos(u8, profile_bytes, idx, '\n') orelse profile_bytes.len;
        try writer.print("  Sampler Summary    : {s}\n", .{std.mem.trim(u8, profile_bytes[idx..line_end], " \r\n")});
    }

    // Extract and print the top 20 hot stack frames from `Sort by top of stack, same collapsed`
    const marker = "Sort by top of stack, same collapsed";
    if (std.mem.indexOf(u8, profile_bytes, marker)) |m_idx| {
        try writer.writeAll("----------------------------------------------------------------------------------------\n");
        try writer.writeAll("  Top Symbolicated Hot Functions (by leaf stack samples):\n");
        try writer.writeAll("----------------------------------------------------------------------------------------\n");

        const after_header = std.mem.indexOfScalarPos(u8, profile_bytes, m_idx, '\n') orelse profile_bytes.len;
        var line_it = std.mem.splitScalar(u8, profile_bytes[after_header..], '\n');
        var shown: usize = 0;
        while (line_it.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, " \t\r");
            if (trimmed.len == 0) {
                if (shown > 0) break;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "Binary Images:")) break;
            try writer.print("    {s}\n", .{trimmed});
            shown += 1;
            if (shown >= 20) break;
        }
    }
    try writer.writeAll("========================================================================================\n");
}

test "CPU Profiler & Complex Repository Stress Suite: 200-file 40-commit multi-branch DAG" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const rep = try runComplexRepoBenchmark(gpa, io, 200, 40);
    try std.testing.expectEqual(@as(usize, 200), rep.num_files);
    try std.testing.expect(rep.total_commits >= 45);
    try std.testing.expect(rep.serialized_bytes > 0);
}
