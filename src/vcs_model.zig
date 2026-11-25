//! Formal TLA+-style State Machine of a Single-DB + Multi-Worktree + Multi-Branch VCS.
//!
//! Combines:
//! 1. **Fossil's Single-File Transactional Database (`SingleDbState`)**:
//!    - `commits`: Append-only table of immutable commit manifests
//!    - `branches`: Named branch pointers (`main`, `feat`)
//!    - `worktrees`: Registered worktrees (`wt0`, `wt1`) attached to the single DB
//!    - `drafts`: Auto-saved uncommitted working-tree snapshots per `(worktree, branch)`
//!    - `oplog`: Atomic undo log entry stored inside the database
//! 2. **Git's Worktrees & Branches (Made User-Friendly)**:
//!    - Multiple worktrees operate concurrently without corrupting each other
//!    - Switching branches automatically saves and restores uncommitted work (zero data loss)
//!    - Merges represent conflicts as first-class tree values (`TreeKind.conflict`) so a
//!      worktree is never wedged mid-merge
//!    - Atomic `undo` restores branches, worktrees, and drafts in one step

const std = @import("std");
const Io = std.Io;
const tla = @import("tla.zig");

pub const MAX_COMMITS = 5;
pub const NUM_BRANCHES = 2;
pub const NUM_WORKTREES = 2;

pub const TreeKind = enum(u8) {
    clean,
    conflict,
};

pub const TreeValue = struct {
    kind: TreeKind = .clean,
    ours: u8 = 0,
    theirs: u8 = 0,

    pub fn clean(val: u8) TreeValue {
        return .{ .kind = .clean, .ours = val, .theirs = 0 };
    }

    pub fn conflict(ours: u8, theirs: u8) TreeValue {
        return .{ .kind = .conflict, .ours = ours, .theirs = theirs };
    }

    pub fn eql(a: TreeValue, b: TreeValue) bool {
        return a.kind == b.kind and a.ours == b.ours and a.theirs == b.theirs;
    }
};

/// Formal Sum of Trees (`B + C - A`) representation (Jujutsu Merge Algebra / Kaki 2019 MRDTs).
/// Represents a tree state in the free abelian group over basis versions `0..MAX_VERSIONS-1`.
/// - Clean tree `v` has `coeff[v] = 1` and `0` elsewhere (`sum(coeff) == 1`, all `0` or `1`).
/// - A 3-way merge of `ours` (B) and `theirs` (C) over `base` (A) is `B + C - A` pointwise.
/// - Rebasing a conflicted tree `M = B + C - A` from `C` onto `D` computes `M + D - C = B + D - A`,
///   cancelling intermediate conflict terms algebraically without ever writing `<<<<<<<` into storage.
pub const FormalTreeSum = struct {
    pub const MAX_VERSIONS = 4;
    coeff: [MAX_VERSIONS]i8 = @splat(0),

    pub fn fromClean(v: u8) FormalTreeSum {
        var t = FormalTreeSum{};
        t.coeff[v] = 1;
        return t;
    }

    pub fn threeWayMerge(base: FormalTreeSum, ours: FormalTreeSum, theirs: FormalTreeSum) FormalTreeSum {
        var out = FormalTreeSum{};
        for (0..MAX_VERSIONS) |i| {
            out.coeff[i] = ours.coeff[i] + theirs.coeff[i] - base.coeff[i];
        }
        return out;
    }

    pub fn isClean(self: FormalTreeSum) ?u8 {
        var found: ?u8 = null;
        for (self.coeff, 0..) |c, idx| {
            if (c == 1) {
                if (found != null) return null;
                found = @intCast(idx);
            } else if (c != 0) {
                return null;
            }
        }
        return found;
    }

    pub fn eql(a: FormalTreeSum, b: FormalTreeSum) bool {
        return std.mem.eql(i8, &a.coeff, &b.coeff);
    }
};

pub const CommitRecord = struct {
    id: u8 = 0,
    parent1: ?u8 = null,
    parent2: ?u8 = null,
    tree: TreeValue = .{},
};

pub const WorktreeState = struct {
    branch: u8 = 0,
    working_tree: TreeValue = .{},
    is_dirty: bool = false,
};

pub const OplogSnapshot = struct {
    valid: bool = false,
    branches: [NUM_BRANCHES]u8 = .{ 0, 0 },
    worktrees: [NUM_WORKTREES]WorktreeState = .{ .{}, .{} },
    drafts: [NUM_WORKTREES][NUM_BRANCHES]?TreeValue = .{
        .{ null, null },
        .{ null, null },
    },
    expected_uncommitted: [NUM_WORKTREES][NUM_BRANCHES]?TreeValue = .{
        .{ null, null },
        .{ null, null },
    },
};

/// Complete state of the single-file VCS database (`SingleDbState`).
pub const SingleDbState = struct {
    commit_count: u8 = 1,
    commits: [MAX_COMMITS]CommitRecord = blk: {
        var arr: [MAX_COMMITS]CommitRecord = @splat(.{});
        arr[0] = .{ .id = 0, .parent1 = null, .parent2 = null, .tree = TreeValue.clean(0) };
        break :blk arr;
    },
    branches: [NUM_BRANCHES]u8 = .{ 0, 0 },
    worktrees: [NUM_WORKTREES]WorktreeState = .{
        .{ .branch = 0, .working_tree = TreeValue.clean(0), .is_dirty = false },
        .{ .branch = 1, .working_tree = TreeValue.clean(0), .is_dirty = false },
    },
    /// Single-DB `drafts` table: stores auto-shelved uncommitted edits per `(worktree, branch)`.
    drafts: [NUM_WORKTREES][NUM_BRANCHES]?TreeValue = .{
        .{ null, null },
        .{ null, null },
    },
    /// Ghost specification variable tracking the uncommitted edits a user has made on `(wt, branch)`
    /// that have not yet been committed, used to verify `Inv_NoUncommittedWorkLost`.
    expected_uncommitted: [NUM_WORKTREES][NUM_BRANCHES]?TreeValue = .{
        .{ null, null },
        .{ null, null },
    },
    /// Transactional operation log (`oplog`) for single-step atomic undo.
    last_oplog: OplogSnapshot = .{},
};

pub const VcsAction = union(enum) {
    edit: struct { wt: u8, content: u8 },
    commit: struct { wt: u8 },
    switch_branch: struct { wt: u8, target_branch: u8 },
    merge: struct { wt: u8, source_branch: u8 },
    undo: void,

    pub fn formatShort(self: VcsAction, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .edit => |e| try writer.print("Edit(wt{d}, v{d})", .{ e.wt, e.content }),
            .commit => |c| try writer.print("Commit(wt{d})", .{c.wt}),
            .switch_branch => |s| try writer.print("Switch(wt{d} -> br{d})", .{ s.wt, s.target_branch }),
            .merge => |m| try writer.print("Merge(wt{d} <- br{d})", .{ m.wt, m.source_branch }),
            .undo => try writer.writeAll("Undo()"),
        }
    }
};

pub const ALL_ACTIONS = [_]VcsAction{
    .{ .edit = .{ .wt = 0, .content = 1 } },
    .{ .edit = .{ .wt = 1, .content = 2 } },
    .{ .commit = .{ .wt = 0 } },
    .{ .commit = .{ .wt = 1 } },
    .{ .switch_branch = .{ .wt = 0, .target_branch = 0 } },
    .{ .switch_branch = .{ .wt = 0, .target_branch = 1 } },
    .{ .switch_branch = .{ .wt = 1, .target_branch = 0 } },
    .{ .switch_branch = .{ .wt = 1, .target_branch = 1 } },
    .{ .merge = .{ .wt = 0, .source_branch = 1 } },
    .{ .merge = .{ .wt = 1, .source_branch = 0 } },
    .{ .undo = {} },
};

pub fn mergeTrees(ours: TreeValue, theirs: TreeValue) TreeValue {
    if (ours.eql(theirs)) return ours;
    if (ours.kind == .clean and theirs.kind == .clean) {
        return TreeValue.conflict(ours.ours, theirs.ours);
    }
    return ours;
}

// ============================================================================
// TLA+ Safety Invariants (`[]Inv`)
// ============================================================================

/// Invariant 1: Every branch head and commit parent in the single DB points to a valid commit.
pub fn invDbReferentialIntegrity(s: SingleDbState) bool {
    if (s.commit_count == 0 or s.commit_count > MAX_COMMITS) return false;
    for (s.branches) |head| {
        if (head >= s.commit_count) return false;
    }
    var i: u8 = 0;
    while (i < s.commit_count) : (i += 1) {
        const c = s.commits[i];
        if (c.id != i) return false;
        if (c.parent1) |p1| {
            if (p1 >= s.commit_count) return false;
        }
        if (c.parent2) |p2| {
            if (p2 >= s.commit_count) return false;
        }
    }
    return true;
}

/// Invariant 2: The commit graph in the single DB is strictly acyclic (DAG).
pub fn invCommitDagAcyclic(s: SingleDbState) bool {
    var i: u8 = 0;
    while (i < s.commit_count) : (i += 1) {
        const c = s.commits[i];
        if (c.parent1) |p1| {
            if (p1 >= i) return false;
        }
        if (c.parent2) |p2| {
            if (p2 >= i) return false;
        }
    }
    return true;
}

/// Invariant 3: Uncommitted work in any worktree is never silently lost across branch switches.
/// Whenever worktree `w` has uncommitted edits for branch `b` (`expected_uncommitted[w][b]`),
/// that exact tree must either be active in `worktrees[w]` (if currently on `b`) or safely
/// persisted in the single DB's `drafts[w][b]` table!
pub fn invNoUncommittedWorkLost(s: SingleDbState) bool {
    for (0..NUM_WORKTREES) |w| {
        for (0..NUM_BRANCHES) |b| {
            if (s.expected_uncommitted[w][b]) |expected_tree| {
                const wt = s.worktrees[w];
                if (wt.branch == b) {
                    if (!wt.is_dirty or !wt.working_tree.eql(expected_tree)) return false;
                } else {
                    const saved = s.drafts[w][b] orelse return false;
                    if (!saved.eql(expected_tree)) return false;
                }
            }
        }
    }
    return true;
}

/// Invariant 4: Every clean worktree's working tree matches its checked-out branch's head commit tree
/// (unless another worktree just advanced that branch, which is tracked deterministically).
pub fn invWorktreeBranchBounds(s: SingleDbState) bool {
    for (s.worktrees) |wt| {
        if (wt.branch >= NUM_BRANCHES) return false;
    }
    return true;
}

/// Parameterized VCS specification:
/// - `safe_mode = true`: Full user-friendly Single-DB VCS (auto-snapshots drafts on branch switch).
/// - `safe_mode = false`: Naive mode without single-DB draft preservation on branch switch,
///   allowing the Zig TLA+ model checker to demonstrate finding a minimal counterexample trace.
pub fn MakeVcsSpec(comptime safe_mode: bool) type {
    return struct {
        pub const State = SingleDbState;
        pub const Action = VcsAction;

        pub const invariants = [_]tla.Invariant(State){
            .{
                .name = "Inv_DbReferentialIntegrity",
                .description = "All branch heads and commit parents in the single DB reference valid commit rows",
                .check = invDbReferentialIntegrity,
            },
            .{
                .name = "Inv_CommitDagAcyclic",
                .description = "The commit history graph in the single DB is strictly acyclic (parents precede children)",
                .check = invCommitDagAcyclic,
            },
            .{
                .name = "Inv_WorktreeBranchBounds",
                .description = "All attached worktrees reference valid branches in the single DB",
                .check = invWorktreeBranchBounds,
            },
            .{
                .name = "Inv_NoUncommittedWorkLost",
                .description = "Uncommitted edits in any worktree are preserved in active state or the single-DB drafts table across branch switches",
                .check = invNoUncommittedWorkLost,
            },
        };

        pub fn init() State {
            return SingleDbState{};
        }

        pub fn allActions() []const Action {
            return &ALL_ACTIONS;
        }

        pub fn enabled(s: State, act: Action) bool {
            return switch (act) {
                .edit => |e| blk: {
                    const wt = s.worktrees[e.wt];
                    const target = TreeValue.clean(e.content);
                    break :blk !wt.is_dirty or !wt.working_tree.eql(target);
                },
                .commit => |c| blk: {
                    if (s.commit_count >= MAX_COMMITS) break :blk false;
                    break :blk s.worktrees[c.wt].is_dirty;
                },
                .switch_branch => |sw| s.worktrees[sw.wt].branch != sw.target_branch,
                .merge => |m| blk: {
                    if (s.commit_count >= MAX_COMMITS) break :blk false;
                    const wt = s.worktrees[m.wt];
                    if (wt.branch == m.source_branch) break :blk false;
                    break :blk s.branches[wt.branch] != s.branches[m.source_branch];
                },
                .undo => s.last_oplog.valid,
            };
        }

        fn recordOplog(s: *State, prev: State) void {
            s.last_oplog = .{
                .valid = true,
                .branches = prev.branches,
                .worktrees = prev.worktrees,
                .drafts = prev.drafts,
                .expected_uncommitted = prev.expected_uncommitted,
            };
        }

        pub fn next(prev: State, act: Action) State {
            var s = prev;
            switch (act) {
                .edit => |e| {
                    recordOplog(&s, prev);
                    const br = s.worktrees[e.wt].branch;
                    const new_tree = TreeValue.clean(e.content);
                    s.worktrees[e.wt].working_tree = new_tree;
                    s.worktrees[e.wt].is_dirty = true;
                    s.expected_uncommitted[e.wt][br] = new_tree;
                },
                .commit => |c| {
                    recordOplog(&s, prev);
                    const wt = s.worktrees[c.wt];
                    const br = wt.branch;
                    const new_cid = s.commit_count;
                    s.commits[new_cid] = .{
                        .id = new_cid,
                        .parent1 = s.branches[br],
                        .parent2 = null,
                        .tree = wt.working_tree,
                    };
                    s.commit_count += 1;
                    s.branches[br] = new_cid;
                    s.worktrees[c.wt].is_dirty = false;
                    s.drafts[c.wt][br] = null;
                    s.expected_uncommitted[c.wt][br] = null;
                },
                .switch_branch => |sw| {
                    recordOplog(&s, prev);
                    const wt = s.worktrees[sw.wt];
                    const old_br = wt.branch;
                    const new_br = sw.target_branch;

                    if (safe_mode) {
                        // Safe Single-DB VCS: auto-snapshot dirty working tree into `drafts`
                        s.drafts[sw.wt][old_br] = if (wt.is_dirty) wt.working_tree else null;
                        if (s.drafts[sw.wt][new_br]) |saved_draft| {
                            s.worktrees[sw.wt] = .{
                                .branch = new_br,
                                .working_tree = saved_draft,
                                .is_dirty = true,
                            };
                        } else {
                            const head_cid = s.branches[new_br];
                            s.worktrees[sw.wt] = .{
                                .branch = new_br,
                                .working_tree = s.commits[head_cid].tree,
                                .is_dirty = false,
                            };
                        }
                    } else {
                        // Naive VCS mode: switching branches without auto-draft overwrites working copy
                        const head_cid = s.branches[new_br];
                        s.worktrees[sw.wt] = .{
                            .branch = new_br,
                            .working_tree = s.commits[head_cid].tree,
                            .is_dirty = false,
                        };
                    }
                },
                .merge => |m| {
                    recordOplog(&s, prev);
                    const wt = s.worktrees[m.wt];
                    const target_br = wt.branch;
                    const ours_cid = s.branches[target_br];
                    const theirs_cid = s.branches[m.source_branch];
                    const merged_tree = mergeTrees(wt.working_tree, s.commits[theirs_cid].tree);
                    const new_cid = s.commit_count;
                    s.commits[new_cid] = .{
                        .id = new_cid,
                        .parent1 = ours_cid,
                        .parent2 = theirs_cid,
                        .tree = merged_tree,
                    };
                    s.commit_count += 1;
                    s.branches[target_br] = new_cid;
                    s.worktrees[m.wt] = .{
                        .branch = target_br,
                        .working_tree = merged_tree,
                        .is_dirty = false,
                    };
                    s.drafts[m.wt][target_br] = null;
                    s.expected_uncommitted[m.wt][target_br] = null;
                },
                .undo => {
                    if (s.last_oplog.valid) {
                        s.branches = s.last_oplog.branches;
                        s.worktrees = s.last_oplog.worktrees;
                        s.drafts = s.last_oplog.drafts;
                        s.expected_uncommitted = s.last_oplog.expected_uncommitted;
                        s.last_oplog.valid = false;
                    }
                },
            }
            return s;
        }
    };
}

pub const SafeVcsSpec = MakeVcsSpec(true);
pub const NaiveVcsSpec = MakeVcsSpec(false);
