//! Zig-VCS Core Library & Formal Model Checking Suite.
const std = @import("std");
const Io = std.Io;

pub const tla = @import("tla.zig");
pub const vcs_model = @import("vcs_model.zig");
pub const visualize = @import("visualize.zig");
pub const diff3_anchors = @import("algebra/diff3_anchors.zig");
pub const tree_sum = @import("algebra/tree_sum.zig");
pub const cow_btree = @import("storage/cow_btree.zig");
pub const delta = @import("storage/delta.zig");
pub const paged_file = @import("storage/paged_file.zig");
pub const repo_db = @import("storage/repo_db.zig");
pub const materializer = @import("worktree/materializer.zig");
pub const ignore = @import("worktree/ignore.zig");
pub const conformance_fuzzer = @import("testing/conformance_fuzzer.zig");
pub const adversarial_tests = @import("testing/adversarial_tests.zig");
pub const git_parity_oracle = @import("testing/git_parity_oracle.zig");
pub const perf_profiler = @import("testing/perf_profiler.zig");
pub const cli_e2e_tests = @import("testing/cli_e2e_tests.zig");
pub const git_interop = @import("interop/git_interop.zig");
pub const cli = @import("cli.zig");
pub const editor_plugin = @import("plugin/editor_plugin.zig");

test {
    std.testing.refAllDecls(@This());
}

test "Zig TLA+ Model Checker: SafeVcsSpec satisfies all invariants across reachable state space" {
    const gpa = std.testing.allocator;
    const Checker = tla.ModelChecker(vcs_model.SafeVcsSpec);
    var res = try Checker.check(gpa, .{
        .max_states = 4000,
        .max_depth = 8,
        .check_deadlocks = true,
    });
    defer res.deinit();

    try std.testing.expect(res.violation == null);
    try std.testing.expect(res.nodes.items.len > 100);
    try std.testing.expect(res.transitions_explored > 500);
}

test "Zig TLA+ Model Checker: NaiveVcsSpec catches uncommitted data loss and produces minimal trace" {
    const gpa = std.testing.allocator;
    const Checker = tla.ModelChecker(vcs_model.NaiveVcsSpec);
    var res = try Checker.check(gpa, .{
        .max_states = 4000,
        .max_depth = 8,
        .check_deadlocks = true,
    });
    defer res.deinit();

    try std.testing.expect(res.violation != null);
    const v = res.violation.?;
    try std.testing.expectEqualStrings("Inv_NoUncommittedWorkLost", v.invariant_name);
    // Minimal trace: Init (S0) -> Edit(wt0, v1) -> Switch(wt0 -> br1) = 3 states (depth 2)
    try std.testing.expectEqual(@as(usize, 3), v.trace_state_ids.len);
}

test "FormalTreeSum (B + C - A) Merge Algebra: commutativity, rebase conflict cancellation, and backout" {
    const FormalTreeSum = vcs_model.FormalTreeSum;
    for (0..FormalTreeSum.MAX_VERSIONS) |a_idx| {
        for (0..FormalTreeSum.MAX_VERSIONS) |b_idx| {
            for (0..FormalTreeSum.MAX_VERSIONS) |c_idx| {
                const A = FormalTreeSum.fromClean(@intCast(a_idx));
                const B = FormalTreeSum.fromClean(@intCast(b_idx));
                const C = FormalTreeSum.fromClean(@intCast(c_idx));

                // 1. Commutativity: merge(A, B, C) == merge(A, C, B)
                const m_bc = FormalTreeSum.threeWayMerge(A, B, C);
                const m_cb = FormalTreeSum.threeWayMerge(A, C, B);
                try std.testing.expect(m_bc.eql(m_cb));

                // 2. Unchanged side resolution: merge(A, B, A) == B (clean!)
                const m_ba = FormalTreeSum.threeWayMerge(A, B, A);
                try std.testing.expect(m_ba.eql(B));
                try std.testing.expectEqual(@as(?u8, @intCast(b_idx)), m_ba.isClean());

                // 3. Rebase conflict simplification:
                // Rebasing conflicted M = (B + C - A) from C onto D yields (B + D - A)
                for (0..FormalTreeSum.MAX_VERSIONS) |d_idx| {
                    const D = FormalTreeSum.fromClean(@intCast(d_idx));
                    const rebased = FormalTreeSum.threeWayMerge(C, m_bc, D);
                    const direct = FormalTreeSum.threeWayMerge(A, B, D);
                    try std.testing.expect(rebased.eql(direct));
                }

                // 4. Backout cancellation: merge(M, M, C) == C
                const backed_out = FormalTreeSum.threeWayMerge(m_bc, m_bc, C);
                try std.testing.expect(backed_out.eql(C));
                try std.testing.expectEqual(@as(?u8, @intCast(c_idx)), backed_out.isClean());
            }
        }
    }
}
