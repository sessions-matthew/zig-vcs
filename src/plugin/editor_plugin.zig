//! Editor Source Control Plugin (`zig-vcs` + Git Dual-Provider UI Adapter).
//!
//! Implements the capability-driven view models and safety guardrails for integrating
//! `zig-vcs` alongside Git inside `../editor`:
//! 1. **Safe Defaults for Checkboxes, Sub-File Hunks & Branch-Switch Toasts**:
//!    - Conflicted (`⚡ U`) files default to `checked = false`; checking a conflicted file
//!      morphs the commit button into `.amber_conflict_warning` (`Commit Checked (Includes K Conflict ⚡)`)
//!      and requires `allow_conflicted_commit = true`.
//!    - Sub-file line/hunk selection (`commitWithSubfileLineSelections`) constructs an ephemeral
//!      partial blob in memory without requiring a Git staging area.
//!    - 1-click branch switch (`switchBranchWithToast`) emits an actionable toast when dirty edits
//!      are auto-shelved (`"Shelved N files on <branch> • [Bring Changes Here]"`).
//! 2. **Human-First Provenance Labels & Laptop-Friendly 2-Column Conflict Delta View**:
//!    - Replaces ambiguous `Ours` / `Theirs` labels with concrete branch/commit provenance
//!      (`"Keep main (c29)"` vs. `"Take feat (c28)"`, `"Undo Merge Commit"`).
//!    - Produces a 2-column delta view (`left_delta_lines` vs. `right_delta_lines` relative to `Base`)
//!      with `Base` available as an `Alt`-to-peek overlay and raw $\mathbb{Z}[\mathcal{A}_\bot]$
//!      basis formulas tucked into `math_formula_badge`.
//! 3. **Time-Travel & Cascade Guardrails**:
//!    - Single-line collapsed Oplog footer bar (`OplogFooterBarModel`), read-only jump preview diff
//!      (`previewOplogJumpDiff`), and unsaved editor buffer protection (`executeOplogJumpGuarded`).
//!    - Immutable/pushed commit phase protection (`error.CommitIsImmutablePushed`) and in-memory
//!      cascade conflict dry-run (`previewAmendCascadeDryRun`) across downstream commits, open/closed
//!      worktrees, and shelved drafts.
//! 4. **State-Aware Git Sync Bridge Gating**:
//!    - Computes live bridge health (`inspectGitBridgeHealth`) and blocks `git-export` on committed
//!      algebraic conflicts unless an explicit fallback policy (`GitConflictExportPolicy`) is chosen.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const repo_db = @import("../storage/repo_db.zig");
const tree_sum = @import("../algebra/tree_sum.zig");
const diff3 = @import("../algebra/diff3_anchors.zig");
const git_interop = @import("../interop/git_interop.zig");

pub const RepoDb = repo_db.RepoDb;
pub const CommitId = repo_db.CommitId;
pub const TreeId = repo_db.TreeId;
pub const BranchId = repo_db.BranchId;
pub const WorktreeId = repo_db.WorktreeId;
pub const ArtifactHash = repo_db.ArtifactHash;

// ============================================================================
// 0. Dual-Provider Detection & Capabilities
// ============================================================================

pub const VcsBackendKind = enum {
    none,
    git_only,
    zig_vcs_only,
    hybrid_zig_vcs_and_git,
};

pub const VcsCapabilities = struct {
    requires_staging_area: bool,
    supports_subfile_hunk_selection: bool,
    supports_auto_drafts: bool,
    supports_provenance_conflict_lens: bool,
    supports_oplog_footer_scrubber: bool,
    supports_cascade_dry_run: bool,
    supports_git_bridge_gating: bool,

    pub fn forBackend(kind: VcsBackendKind) VcsCapabilities {
        return switch (kind) {
            .zig_vcs_only, .hybrid_zig_vcs_and_git => .{
                .requires_staging_area = false,
                .supports_subfile_hunk_selection = true,
                .supports_auto_drafts = true,
                .supports_provenance_conflict_lens = true,
                .supports_oplog_footer_scrubber = true,
                .supports_cascade_dry_run = true,
                .supports_git_bridge_gating = (kind == .hybrid_zig_vcs_and_git),
            },
            .git_only => .{
                .requires_staging_area = true,
                .supports_subfile_hunk_selection = true,
                .supports_auto_drafts = false,
                .supports_provenance_conflict_lens = false,
                .supports_oplog_footer_scrubber = false,
                .supports_cascade_dry_run = false,
                .supports_git_bridge_gating = false,
            },
            .none => .{
                .requires_staging_area = false,
                .supports_subfile_hunk_selection = false,
                .supports_auto_drafts = false,
                .supports_provenance_conflict_lens = false,
                .supports_oplog_footer_scrubber = false,
                .supports_cascade_dry_run = false,
                .supports_git_bridge_gating = false,
            },
        };
    }
};

/// Detect whether `workspace_dir` uses `.vcs/db.vcs` (or `.vcs-link`), `.git`, or both.
pub fn detectWorkspaceVcs(io: Io, workspace_dir: []const u8) VcsBackendKind {
    var dir = Io.Dir.cwd().openDir(io, workspace_dir, .{}) catch return .none;
    defer dir.close(io);

    const has_vcs_db = (dir.statFile(io, ".vcs/db.vcs", .{}) catch null) != null;
    const has_vcs_link = (dir.statFile(io, ".vcs-link", .{}) catch null) != null;
    const has_zvcs = has_vcs_db or has_vcs_link;

    var has_git = (dir.statFile(io, ".git", .{}) catch null) != null;
    if (!has_git) {
        if (dir.openDir(io, ".git", .{})) | mut_gdir| {
            var gdir = mut_gdir;
            gdir.close(io);
            has_git = true;
        } else |_| {}
    }

    if (has_zvcs and has_git) return .hybrid_zig_vcs_and_git;
    if (has_zvcs) return .zig_vcs_only;
    if (has_git) return .git_only;
    return .none;
}

// ============================================================================
// 1. Safe Defaults for Checkboxes, Sub-File Hunks & Branch-Switch Toasts
// ============================================================================

pub const FileChangeStatus = enum {
    added,
    modified,
    deleted,
    conflicted,
};

pub const WorkingFileCheckboxItem = struct {
    path: []u8,
    status: FileChangeStatus,
    /// Defaults to `true` for clean changes (`.added`, `.modified`, `.deleted`) and
    /// `false` for `.conflicted` files (`⚡ U`) to prevent accidental conflict commits!
    checked: bool,
    term_count: usize,

    pub fn deinit(self: *WorkingFileCheckboxItem, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

pub const CommitButtonStyle = enum {
    disabled,
    primary_clean,
    amber_conflict_warning,
};

pub const CommitActionModel = struct {
    style: CommitButtonStyle,
    checked_total: usize,
    checked_conflicts: usize,
    label: []u8,

    pub fn deinit(self: *CommitActionModel, allocator: Allocator) void {
        allocator.free(self.label);
    }
};

/// Build the working changes checkbox list for `wt_id`, automatically unchecking any conflicted
/// (`⚡ U`) files by default so pressing `Cmd+Enter` never commits an unresolved conflict by accident.
pub fn buildWorkingChangesList(
    allocator: Allocator,
    db: *const RepoDb,
    wt_id: WorktreeId,
) ![]WorkingFileCheckboxItem {
    var items: std.ArrayList(WorkingFileCheckboxItem) = .empty;
    errdefer {
        for (items.items) |*it| it.deinit(allocator);
        items.deinit(allocator);
    }

    const wt = db.worktrees.items[wt_id];
    const br = db.branches.items[wt.branch_id];
    const head_items = db.trees.items[db.commits.items[br.head_commit].root_tree_id].entries.items;
    const work_items = db.trees.items[wt.working_tree_id].entries.items;

    var ih: usize = 0;
    var iw: usize = 0;
    while (ih < head_items.len or iw < work_items.len) {
        const ord: std.math.Order = if (ih < head_items.len and iw < work_items.len)
            std.mem.order(u8, head_items[ih].path, work_items[iw].path)
        else if (ih < head_items.len)
            .lt
        else
            .gt;

        switch (ord) {
            .lt => {
                const path_dup = try allocator.dupe(u8, head_items[ih].path);
                errdefer allocator.free(path_dup);
                try items.append(allocator, .{
                    .path = path_dup,
                    .status = .deleted,
                    .checked = true,
                    .term_count = 0,
                });
                ih += 1;
            },
            .gt => {
                const we = work_items[iw];
                const is_conf = we.sum.isConflicted();
                const path_dup = try allocator.dupe(u8, we.path);
                errdefer allocator.free(path_dup);
                try items.append(allocator, .{
                    .path = path_dup,
                    .status = if (is_conf) .conflicted else .added,
                    .checked = !is_conf,
                    .term_count = we.sum.terms.items.len,
                });
                iw += 1;
            },
            .eq => {
                const he = head_items[ih];
                const we = work_items[iw];
                if (we.sum.isConflicted()) {
                    const path_dup = try allocator.dupe(u8, we.path);
                    errdefer allocator.free(path_dup);
                    try items.append(allocator, .{
                        .path = path_dup,
                        .status = .conflicted,
                        .checked = false,
                        .term_count = we.sum.terms.items.len,
                    });
                } else if (he.mode != we.mode or !he.sum.eql(we.sum)) {
                    const path_dup = try allocator.dupe(u8, we.path);
                    errdefer allocator.free(path_dup);
                    try items.append(allocator, .{
                        .path = path_dup,
                        .status = .modified,
                        .checked = true,
                        .term_count = 1,
                    });
                }
                ih += 1;
                iw += 1;
            },
        }
    }

    return items.toOwnedSlice(allocator);
}

pub fn freeWorkingChangesList(allocator: Allocator, items: []WorkingFileCheckboxItem) void {
    for (items) |*it| it.deinit(allocator);
    allocator.free(items);
}

/// Compute the commit button state (`disabled`, `primary_clean`, or `amber_conflict_warning`)
/// from the current checkbox states.
pub fn computeCommitActionModel(
    allocator: Allocator,
    items: []const WorkingFileCheckboxItem,
) !CommitActionModel {
    var checked_total: usize = 0;
    var checked_conflicts: usize = 0;

    for (items) |it| {
        if (it.checked) {
            checked_total += 1;
            if (it.status == .conflicted) {
                checked_conflicts += 1;
            }
        }
    }

    if (checked_total == 0) {
        return .{
            .style = .disabled,
            .checked_total = 0,
            .checked_conflicts = 0,
            .label = try allocator.dupe(u8, "Commit Checked (0)"),
        };
    }

    if (checked_conflicts > 0) {
        return .{
            .style = .amber_conflict_warning,
            .checked_total = checked_total,
            .checked_conflicts = checked_conflicts,
            .label = try std.fmt.allocPrint(
                allocator,
                "Commit Checked (Includes {d} Conflict{s} ⚡)",
                .{ checked_conflicts, if (checked_conflicts == 1) "" else "s" },
            ),
        };
    }

    return .{
        .style = .primary_clean,
        .checked_total = checked_total,
        .checked_conflicts = 0,
        .label = try std.fmt.allocPrint(allocator, "Commit Checked ({d})", .{checked_total}),
    };
}

/// Commit the checked items in `items`.
/// Returns `error.UnacknowledgedConflictInCommit` if any checked item is `.conflicted` and
/// `allow_conflicted_commit` is `false`.
pub fn commitCheckedItems(
    allocator: Allocator,
    db: *RepoDb,
    wt_id: WorktreeId,
    items: []const WorkingFileCheckboxItem,
    author: []const u8,
    message: []const u8,
    allow_conflicted_commit: bool,
) !CommitId {
    var selected_paths: std.ArrayList([]const u8) = .empty;
    defer selected_paths.deinit(allocator);

    var all_checked = true;
    for (items) |it| {
        if (it.checked) {
            if (it.status == .conflicted and !allow_conflicted_commit) {
                return error.UnacknowledgedConflictInCommit;
            }
            try selected_paths.append(allocator, it.path);
        } else {
            all_checked = false;
        }
    }

    if (selected_paths.items.len == 0) return error.NoFilesCheckedForCommit;
    if (all_checked) {
        return db.commitWorktree(wt_id, author, message);
    }
    return db.commitWorktreePaths(wt_id, author, message, selected_paths.items);
}

pub const LineRangeSelection = struct {
    /// 1-based inclusive start line in the working file (`1 <= start_line <= end_line`).
    start_line: usize,
    /// 1-based inclusive end line in the working file.
    end_line: usize,
};

fn isLineSelected(line_1based: usize, ranges: []const LineRangeSelection) bool {
    for (ranges) |r| {
        if (line_1based >= r.start_line and line_1based <= r.end_line) return true;
    }
    return false;
}

/// Construct an ephemeral partial blob in memory from `base_bytes` and `working_bytes` where only
/// the modified lines in `working_bytes` falling within `selected_working_ranges` are included,
/// while unselected modified/added lines revert to `base_bytes` (so temporary debug logging stays
/// uncommitted in the working tree!).
pub fn buildPartialBlobFromSelectedLines(
    allocator: Allocator,
    base_bytes: []const u8,
    working_bytes: []const u8,
    selected_working_ranges: []const LineRangeSelection,
) ![]u8 {
    const base_lines = try diff3.splitLines(allocator, base_bytes);
    defer allocator.free(base_lines);
    const work_lines = try diff3.splitLines(allocator, working_bytes);
    defer allocator.free(work_lines);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var ib: usize = 0;
    var iw: usize = 0;
    while (iw < work_lines.len) {
        const w_line = work_lines[iw];
        const w_line_no = iw + 1;

        if (ib < base_lines.len and std.mem.eql(u8, base_lines[ib], w_line)) {
            // Unchanged line present in both base and working tree
            try out.appendSlice(allocator, w_line);
            ib += 1;
            iw += 1;
            continue;
        }

        // Check if `w_line` is an insertion before `base_lines[ib]` (i.e. `base_lines[ib]` appears later in `work_lines`)
        var base_appears_later = false;
        if (ib < base_lines.len) {
            for ((iw + 1)..work_lines.len) |lookahead| {
                if (std.mem.eql(u8, work_lines[lookahead], base_lines[ib])) {
                    base_appears_later = true;
                    break;
                }
            }
        }

        if (base_appears_later) {
            // Pure insertion at `w_line_no`: include iff selected
            if (isLineSelected(w_line_no, selected_working_ranges)) {
                try out.appendSlice(allocator, w_line);
            }
            iw += 1;
        } else {
            // Replacement/modification of `base_lines[ib]` by `w_line`
            if (isLineSelected(w_line_no, selected_working_ranges)) {
                try out.appendSlice(allocator, w_line);
            } else if (ib < base_lines.len) {
                try out.appendSlice(allocator, base_lines[ib]);
            }
            if (ib < base_lines.len) ib += 1;
            iw += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Sub-File Hunk/Line Commit (`commitWithSubfileLineSelections`):
/// Commits only the selected line ranges (`selected_working_ranges`) of `path` while leaving
/// unselected edits in `path` intact inside `wt_id`'s working tree!
pub fn commitWithSubfileLineSelections(
    allocator: Allocator,
    db: *RepoDb,
    wt_id: WorktreeId,
    path: []const u8,
    selected_working_ranges: []const LineRangeSelection,
    author: []const u8,
    message: []const u8,
) !CommitId {
    const norm_path = try tree_sum.validateAndNormalizePath(allocator, path);
    defer allocator.free(norm_path);

    const full_work_tid = db.worktrees.items[wt_id].working_tree_id;
    const br_id = db.worktrees.items[wt_id].branch_id;
    const head_cid = db.branches.items[br_id].head_commit;
    const head_tid = db.commits.items[head_cid].root_tree_id;

    const head_tree = db.trees.items[head_tid];
    const work_tree = db.trees.items[full_work_tid];

    const work_sum = work_tree.getPathSum(norm_path) orelse return error.FileNotFound;
    const work_hash = work_sum.getCleanHash() orelse return error.CannotSubfileSelectConflictedFile;
    const work_bytes = db.getBlob(work_hash) orelse "";
    const work_mode = work_tree.getPathMode(norm_path) orelse .regular;

    const base_bytes: []const u8 = if (head_tree.getPathSum(norm_path)) |hs|
        (if (hs.getCleanHash()) |hh| (db.getBlob(hh) orelse "") else "")
    else
        "";

    const partial_bytes = try buildPartialBlobFromSelectedLines(
        allocator,
        base_bytes,
        work_bytes,
        selected_working_ranges,
    );
    defer allocator.free(partial_bytes);

    // Temporarily stage `partial_bytes` into `wt_id`, commit `norm_path`, and restore `full_work_tid`!
    const partial_hash = try db.putBlob(partial_bytes);
    var commit_manifest = try head_tree.clone(allocator);
    var manifest_owned = true;
    errdefer if (manifest_owned) commit_manifest.deinit(allocator);

    try commit_manifest.setCleanFileWithMode(allocator, norm_path, partial_hash, work_mode);
    manifest_owned = false;
    const partial_tid = try db.internTreeOwned(commit_manifest);

    db.worktrees.items[wt_id].working_tree_id = partial_tid;
    db.worktrees.items[wt_id].is_dirty = (partial_tid != head_tid);

    const new_cid = try db.commitWorktreePaths(wt_id, author, message, &.{norm_path});

    // Restore the full working tree so unselected lines (e.g. debug logs) remain in the editor!
    const committed_tid = db.commits.items[new_cid].root_tree_id;
    db.worktrees.items[wt_id].working_tree_id = full_work_tid;
    db.worktrees.items[wt_id].is_dirty = (full_work_tid != committed_tid);
    return new_cid;
}

pub const SwitchBranchToast = struct {
    old_branch: []u8,
    new_branch: []u8,
    shelved_file_count: usize,
    restored_draft_file_count: usize,
    can_bring_changes_here: bool,
    toast_message: ?[]u8,

    pub fn deinit(self: *SwitchBranchToast, allocator: Allocator) void {
        allocator.free(self.old_branch);
        allocator.free(self.new_branch);
        if (self.toast_message) |msg| allocator.free(msg);
    }
};

/// Switch `wt_id` to `target_branch` and return an inline toast notification whenever dirty
/// files were auto-shelved into `db.drafts`, offering a 1-click `[Bring Changes Here]` action.
pub fn switchBranchWithToast(
    allocator: Allocator,
    db: *RepoDb,
    wt_id: WorktreeId,
    target_branch: []const u8,
) !SwitchBranchToast {
    const old_br_id = db.worktrees.items[wt_id].branch_id;
    const old_branch_dup = try allocator.dupe(u8, db.branches.items[old_br_id].name);
    errdefer allocator.free(old_branch_dup);
    const new_branch_dup = try allocator.dupe(u8, target_branch);
    errdefer allocator.free(new_branch_dup);

    var shelved_count: usize = 0;
    if (db.worktrees.items[wt_id].is_dirty and !std.mem.eql(u8, old_branch_dup, target_branch)) {
        const pre_items = try buildWorkingChangesList(allocator, db, wt_id);
        defer freeWorkingChangesList(allocator, pre_items);
        shelved_count = pre_items.len;
    }

    _ = try db.switchBranch(wt_id, target_branch);

    var restored_count: usize = 0;
    if (db.worktrees.items[wt_id].is_dirty) {
        const post_items = try buildWorkingChangesList(allocator, db, wt_id);
        defer freeWorkingChangesList(allocator, post_items);
        restored_count = post_items.len;
    }

    const toast_msg: ?[]u8 = if (shelved_count > 0)
        try std.fmt.allocPrint(
            allocator,
            "Shelved {d} file{s} on {s} • [Bring Changes Here]",
            .{ shelved_count, if (shelved_count == 1) "" else "s", old_branch_dup },
        )
    else
        null;

    return .{
        .old_branch = old_branch_dup,
        .new_branch = new_branch_dup,
        .shelved_file_count = shelved_count,
        .restored_draft_file_count = restored_count,
        .can_bring_changes_here = (shelved_count > 0),
        .toast_message = toast_msg,
    };
}

/// 1-click handler for `[Bring Changes Here]` on the branch-switch toast: algebraically grafts
/// the shelved draft from `source_branch` onto `wt_id`'s current branch via `applyBranchDraft`
/// and drops the shelved draft from `source_branch`.
pub fn bringShelvedChangesHere(
    db: *RepoDb,
    wt_id: WorktreeId,
    source_branch: []const u8,
) !TreeId {
    const merged_tid = try db.applyBranchDraft(wt_id, source_branch);
    _ = try db.dropBranchDraft(wt_id, source_branch);
    return merged_tid;
}

// ============================================================================
// 2. Human-First Provenance Labels & 2-Column Laptop Conflict Delta View
// ============================================================================

pub const ConflictDeltaLineKind = enum {
    unchanged_from_base,
    added_vs_base,
    deleted_from_base,
};

pub const ConflictPaneDeltaLine = struct {
    text: []u8,
    kind: ConflictDeltaLineKind,

    pub fn deinit(self: *ConflictPaneDeltaLine, allocator: Allocator) void {
        allocator.free(self.text);
    }
};

pub const TwoPaneConflictViewModel = struct {
    path: []u8,
    /// Concrete provenance button label for the left/current side (e.g. `"Keep main (c29)"`).
    keep_left_label: []u8,
    /// Concrete provenance button label for the right/incoming side (e.g. `"Take feat (c28)"`).
    take_right_label: []u8,
    /// Concrete provenance label for resetting to base / backing out the merge.
    reset_base_label: []u8,
    /// Left pane (`Keep`) lines annotated with additions/deletions relative to `Base`.
    left_delta_lines: []ConflictPaneDeltaLine,
    /// Right pane (`Take`) lines annotated with additions/deletions relative to `Base`.
    right_delta_lines: []ConflictPaneDeltaLine,
    /// Raw `Base` content for the 1-key (`Alt`) hold-to-peek overlay.
    base_peek_bytes: []u8,
    /// Exact $\mathbb{Z}[\mathcal{A}_\bot]$ formula tucked into hover tooltip / Math Mode toggle.
    math_formula_badge: []u8,

    pub fn deinit(self: *TwoPaneConflictViewModel, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.keep_left_label);
        allocator.free(self.take_right_label);
        allocator.free(self.reset_base_label);
        for (self.left_delta_lines) |*l| l.deinit(allocator);
        allocator.free(self.left_delta_lines);
        for (self.right_delta_lines) |*r| r.deinit(allocator);
        allocator.free(self.right_delta_lines);
        allocator.free(self.base_peek_bytes);
        allocator.free(self.math_formula_badge);
    }
};

fn computeSideDeltaAgainstBase(
    allocator: Allocator,
    base_bytes: []const u8,
    side_bytes: []const u8,
) ![]ConflictPaneDeltaLine {
    const base_lines = try diff3.splitLines(allocator, base_bytes);
    defer allocator.free(base_lines);
    const side_lines = try diff3.splitLines(allocator, side_bytes);
    defer allocator.free(side_lines);

    var list: std.ArrayList(ConflictPaneDeltaLine) = .empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    // Emit any lines present in `base` that were deleted from `side`
    for (base_lines) |b_line| {
        var found = false;
        for (side_lines) |s_line| {
            if (std.mem.eql(u8, b_line, s_line)) {
                found = true;
                break;
            }
        }
        if (!found) {
            const copy = try allocator.dupe(u8, std.mem.trimEnd(u8, b_line, "\r\n"));
            errdefer allocator.free(copy);
            try list.append(allocator, .{ .text = copy, .kind = .deleted_from_base });
        }
    }

    // Emit all lines in `side`, marking whether each is unchanged or added relative to `base`
    for (side_lines) |s_line| {
        var in_base = false;
        for (base_lines) |b_line| {
            if (std.mem.eql(u8, b_line, s_line)) {
                in_base = true;
                break;
            }
        }
        const copy = try allocator.dupe(u8, std.mem.trimEnd(u8, s_line, "\r\n"));
        errdefer allocator.free(copy);
        try list.append(allocator, .{
            .text = copy,
            .kind = if (in_base) .unchanged_from_base else .added_vs_base,
        });
    }

    return list.toOwnedSlice(allocator);
}

fn findBranchLabelForCommit(db: *const RepoDb, cid: CommitId) ?[]const u8 {
    for (db.branches.items) |br| {
        if (br.head_commit == cid) return br.name;
    }
    return null;
}

/// Build the 2-column laptop-friendly conflict delta view model with concrete branch/commit
/// provenance labels (`"Keep main (c29)"` vs `"Take feat (c28)"`) and `Alt`-to-peek `Base`.
pub fn buildTwoPaneConflictViewModel(
    allocator: Allocator,
    db: *const RepoDb,
    wt_id: WorktreeId,
    path: []const u8,
) !TwoPaneConflictViewModel {
    const norm_path = try tree_sum.validateAndNormalizePath(allocator, path);
    defer allocator.free(norm_path);

    const wt = db.worktrees.items[wt_id];
    const br = db.branches.items[wt.branch_id];
    const head_cid = br.head_commit;
    const head_rec = db.commits.items[head_cid];

    const work_tree = db.trees.items[wt.working_tree_id];
    const sum = work_tree.getPathSum(norm_path) orelse return error.FileNotFound;
    if (!sum.isConflicted()) return error.FileNotConflicted;

    var ours_hash: ArtifactHash = repo_db.ABSENT_HASH;
    var theirs_hash: ArtifactHash = repo_db.ABSENT_HASH;
    var base_hash: ArtifactHash = repo_db.ABSENT_HASH;

    if (sum.extractTwoSidedConflict()) |two| {
        ours_hash = two.ours;
        theirs_hash = two.theirs;
        base_hash = two.base;

        const ref_cid: CommitId = if (head_rec.parent2 != null and head_rec.parent1 != null)
            head_rec.parent1.?
        else
            head_cid;
        const ref_tree = db.trees.items[db.commits.items[ref_cid].root_tree_id];
        const ref_hash: ArtifactHash = if (ref_tree.getPathSum(norm_path)) |s|
            (s.getCleanHash() orelse repo_db.ABSENT_HASH)
        else
            repo_db.ABSENT_HASH;

        if (tree_sum.hashEql(ref_hash, two.theirs)) {
            ours_hash = two.theirs;
            theirs_hash = two.ours;
        }
    } else {
        var first_pos = true;
        for (sum.terms.items) |t| {
            if (t.coeff > 0) {
                if (first_pos) {
                    ours_hash = t.hash;
                    first_pos = false;
                } else {
                    theirs_hash = t.hash;
                }
            } else if (t.coeff < 0) {
                base_hash = t.hash;
            }
        }
    }

    const left_cid: CommitId = if (head_rec.parent2 != null and head_rec.parent1 != null)
        head_rec.parent1.?
    else
        head_cid;
    const right_cid: ?CommitId = head_rec.parent2;

    const keep_left_label = try std.fmt.allocPrint(allocator, "Keep {s} (c{d})", .{ br.name, left_cid });
    errdefer allocator.free(keep_left_label);

    const take_right_label = if (right_cid) |rcid| blk: {
        if (findBranchLabelForCommit(db, rcid)) |rbr| {
            break :blk try std.fmt.allocPrint(allocator, "Take {s} (c{d})", .{ rbr, rcid });
        }
        break :blk try std.fmt.allocPrint(allocator, "Take incoming (c{d})", .{rcid});
    } else try allocator.dupe(u8, "Take incoming changes");
    errdefer allocator.free(take_right_label);

    const reset_base_label = if (head_rec.parent2 != null)
        try std.fmt.allocPrint(allocator, "Undo Merge Commit (c{d})", .{head_cid})
    else
        try allocator.dupe(u8, "Reset to Base");
    errdefer allocator.free(reset_base_label);

    const base_bytes = db.getBlob(base_hash) orelse "";
    const ours_bytes = db.getBlob(ours_hash) orelse "";
    const theirs_bytes = db.getBlob(theirs_hash) orelse "";

    const left_delta = try computeSideDeltaAgainstBase(allocator, base_bytes, ours_bytes);
    errdefer {
        for (left_delta) |*l| l.deinit(allocator);
        allocator.free(left_delta);
    }
    const right_delta = try computeSideDeltaAgainstBase(allocator, base_bytes, theirs_bytes);
    errdefer {
        for (right_delta) |*r| r.deinit(allocator);
        allocator.free(right_delta);
    }

    const base_peek_dup = try allocator.dupe(u8, base_bytes);
    errdefer allocator.free(base_peek_dup);

    const math_badge = try std.fmt.allocPrint(
        allocator,
        "+1·e_{{{x:0>2}{x:0>2}}} + 1·e_{{{x:0>2}{x:0>2}}} - 1·e_{{{x:0>2}{x:0>2}}} ∈ Z[A_bot]",
        .{
            ours_hash[0],   ours_hash[1],
            theirs_hash[0], theirs_hash[1],
            base_hash[0],   base_hash[1],
        },
    );
    errdefer allocator.free(math_badge);

    const path_dup = try allocator.dupe(u8, norm_path);
    return .{
        .path = path_dup,
        .keep_left_label = keep_left_label,
        .take_right_label = take_right_label,
        .reset_base_label = reset_base_label,
        .left_delta_lines = left_delta,
        .right_delta_lines = right_delta,
        .base_peek_bytes = base_peek_dup,
        .math_formula_badge = math_badge,
    };
}

// ============================================================================
// 3. Guardrails on Time-Travel & Historical Cascades
// ============================================================================

pub const OplogFooterBarModel = struct {
    is_expanded: bool = false,
    total_entries: usize,
    latest_index: ?usize,
    collapsed_summary: []u8,

    pub fn deinit(self: *OplogFooterBarModel, allocator: Allocator) void {
        allocator.free(self.collapsed_summary);
    }
};

/// Build the compact single-line Oplog footer bar (`↶ Undo: <cmd> • #<idx> [Scrub ▴]`).
pub fn buildOplogFooterBarModel(
    allocator: Allocator,
    db: *const RepoDb,
    is_expanded: bool,
) !OplogFooterBarModel {
    const count = db.oplog.items.len;
    if (count == 0) {
        return .{
            .is_expanded = is_expanded,
            .total_entries = 0,
            .latest_index = null,
            .collapsed_summary = try allocator.dupe(u8, "Oplog: Initial State (0 entries)"),
        };
    }
    const last_idx = count - 1;
    const last_op = db.oplog.items[last_idx];
    const toggle_glyph = if (is_expanded) "[Collapse ▾]" else "[Scrub ▴]";
    return .{
        .is_expanded = is_expanded,
        .total_entries = count,
        .latest_index = last_idx,
        .collapsed_summary = try std.fmt.allocPrint(
            allocator,
            "↶ Undo: {s} • #{d} {s}",
            .{ last_op.command_desc, last_idx, toggle_glyph },
        ),
    };
}

/// Compute a read-only unified diff preview of what `wt_id` would look like if restored to
/// `oplog[target_oplog_idx]`, WITHOUT mutating `db` or writing to disk!
pub fn previewOplogJumpDiff(
    allocator: Allocator,
    db: *const RepoDb,
    wt_id: WorktreeId,
    target_oplog_idx: usize,
) ![]u8 {
    if (target_oplog_idx >= db.oplog.items.len) return error.InvalidOplogIndex;
    const cur_tid = db.worktrees.items[wt_id].working_tree_id;
    const snap = db.oplog.items[target_oplog_idx];
    const snap_tid = if (wt_id < snap.worktrees.items.len)
        snap.worktrees.items[wt_id].working_tree_id
    else
        0;
    return db.diffTreesUnified(allocator, cur_tid, snap_tid);
}

/// Restore `oplog[target_oplog_idx]` only after verifying that no unsaved in-memory editor
/// buffers would be clobbered by materializing the snapshot to disk.
pub fn executeOplogJumpGuarded(
    db: *RepoDb,
    target_oplog_idx: usize,
    has_unsaved_editor_buffers: bool,
) !void {
    if (has_unsaved_editor_buffers) {
        return error.UnsavedEditorBuffersWouldBeClobbered;
    }
    try db.restoreOplogAtIndex(target_oplog_idx);
}

pub const CascadeTargetKind = enum {
    descendant_commit,
    open_worktree,
    closed_worktree,
    shelved_draft,
};

pub const CascadeTargetImpact = struct {
    kind: CascadeTargetKind,
    label: []u8,
    creates_conflict_count: usize,

    pub fn deinit(self: *CascadeTargetImpact, allocator: Allocator) void {
        allocator.free(self.label);
    }
};

pub const CascadeDryRunReport = struct {
    target_cid: CommitId,
    is_immutable_pushed: bool,
    total_new_conflicts: usize,
    impacts: []CascadeTargetImpact,

    pub fn deinit(self: *CascadeDryRunReport, allocator: Allocator) void {
        for (self.impacts) |*imp| imp.deinit(allocator);
        allocator.free(self.impacts);
    }
};

fn countConflictedPaths(tree: tree_sum.TreeManifest) usize {
    var count: usize = 0;
    for (tree.entries.items) |e| {
        if (e.sum.isConflicted()) count += 1;
    }
    return count;
}

/// Run an in-memory dry-run of amending `target_cid` (with any dirty working-tree changes in `wt_id`),
/// without mutating `db`. Reports whether `target_cid` is immutable/pushed (`<= max_pushed_cid`)
/// and badges every downstream commit, open/closed worktree, and shelved draft as clean (`0`)
/// or conflicting (`> 0`).
pub fn previewAmendCascadeDryRun(
    allocator: Allocator,
    db: *const RepoDb,
    wt_id: WorktreeId,
    target_cid: CommitId,
    max_pushed_cid: ?CommitId,
) !CascadeDryRunReport {
    if (target_cid == 0 or target_cid >= db.commits.items.len) return error.InvalidCommitId;

    const bytes = try db.serializeToBytesCompact(allocator);
    defer allocator.free(bytes);
    var clone_db = try RepoDb.deserializeFromBytes(allocator, bytes);
    defer clone_db.deinit();

    const pre_commit_count = clone_db.commits.items.len;
    _ = try clone_db.amendCommit(wt_id, target_cid, null);

    var impacts: std.ArrayList(CascadeTargetImpact) = .empty;
    errdefer {
        for (impacts.items) |*imp| imp.deinit(allocator);
        impacts.deinit(allocator);
    }

    var total_new_conflicts: usize = 0;

    // 1. Inspect rewritten target commit `C'` and all cascaded descendant commits (`pre_commit_count .. clone_db.commits.items.len`)
    for (pre_commit_count..clone_db.commits.items.len) |new_cid_usize| {
        const new_cid: CommitId = @intCast(new_cid_usize);
        const rec = clone_db.commits.items[new_cid];
        const conf_count = countConflictedPaths(clone_db.trees.items[rec.root_tree_id]);
        total_new_conflicts += conf_count;
        const lbl = try std.fmt.allocPrint(allocator, "commit c{d}: {s}", .{ new_cid, rec.message });
        errdefer allocator.free(lbl);
        try impacts.append(allocator, .{
            .kind = .descendant_commit,
            .label = lbl,
            .creates_conflict_count = conf_count,
        });
    }

    // 2. Inspect open and closed worktrees
    for (clone_db.worktrees.items) |wt| {
        const conf_count = countConflictedPaths(clone_db.trees.items[wt.working_tree_id]);
        total_new_conflicts += conf_count;
        const lbl = try std.fmt.allocPrint(allocator, "worktree {s}", .{wt.name});
        errdefer allocator.free(lbl);
        try impacts.append(allocator, .{
            .kind = if (wt.is_open) .open_worktree else .closed_worktree,
            .label = lbl,
            .creates_conflict_count = conf_count,
        });
    }

    // 3. Inspect shelved per-branch drafts
    for (clone_db.drafts.items) |d| {
        const conf_count = countConflictedPaths(clone_db.trees.items[d.tree_id]);
        total_new_conflicts += conf_count;
        const br_name = clone_db.branches.items[d.branch_id].name;
        const lbl = try std.fmt.allocPrint(allocator, "draft:{s}", .{br_name});
        errdefer allocator.free(lbl);
        try impacts.append(allocator, .{
            .kind = .shelved_draft,
            .label = lbl,
            .creates_conflict_count = conf_count,
        });
    }

    const is_immutable = if (max_pushed_cid) |mp| (target_cid <= mp) else false;
    return .{
        .target_cid = target_cid,
        .is_immutable_pushed = is_immutable,
        .total_new_conflicts = total_new_conflicts,
        .impacts = try impacts.toOwnedSlice(allocator),
    };
}

/// Amend `target_cid` with an explicit guardrail blocking rewrites of pushed/immutable commits
/// (`target_cid <= max_pushed_cid`) unless `allow_rewrite_immutable` is `true`.
pub fn amendCommitGuarded(
    db: *RepoDb,
    wt_id: WorktreeId,
    target_cid: CommitId,
    new_message: ?[]const u8,
    max_pushed_cid: ?CommitId,
    allow_rewrite_immutable: bool,
) !CommitId {
    if (max_pushed_cid) |mp| {
        if (target_cid <= mp and !allow_rewrite_immutable) {
            return error.CommitIsImmutablePushed;
        }
    }
    return db.amendCommit(wt_id, target_cid, new_message);
}

// ============================================================================
// 4. Lossless Boundaries on the Git Sync Bridge
// ============================================================================

pub const GitBridgeStatusKind = enum {
    in_sync,
    ahead_clean,
    export_blocked_conflicts,
};

pub const GitConflictExportPolicy = enum {
    block_if_conflicted,
    export_clean_ancestors_only,
    allow_partial_positive_basis,
};

pub const GitBridgeHealthReport = struct {
    status: GitBridgeStatusKind,
    first_conflicted_cid: ?CommitId,
    conflicted_commit_count: usize,
    shelved_draft_count: usize,
    pill_label: []u8,

    pub fn deinit(self: *GitBridgeHealthReport, allocator: Allocator) void {
        allocator.free(self.pill_label);
    }
};

/// Inspect the health of the `zig-vcs` $\leftrightarrow$ Git bridge, detecting any reachable
/// commits that contain unresolved algebraic `PathSum` conflicts (`B + C - A`) or shelved drafts
/// that standard Git cannot represent natively.
pub fn inspectGitBridgeHealth(
    allocator: Allocator,
    db: *const RepoDb,
    last_synced_cid: ?CommitId,
) !GitBridgeHealthReport {
    var first_conf_cid: ?CommitId = null;
    var conf_commits: usize = 0;

    for (db.commits.items, 0..) |c, cid_usize| {
        if (cid_usize == 0) continue;
        const cid: CommitId = @intCast(cid_usize);
        // Check if `cid` is reachable from any branch head
        var reachable = false;
        for (db.branches.items) |br| {
            if (db.isCommitAncestor(cid, br.head_commit)) {
                reachable = true;
                break;
            }
        }
        if (!reachable) continue;

        if (db.trees.items[c.root_tree_id].hasConflicts()) {
            conf_commits += 1;
            if (first_conf_cid == null) first_conf_cid = cid;
        }
    }

    const drafts_count = db.drafts.items.len;
    if (conf_commits > 0) {
        return .{
            .status = .export_blocked_conflicts,
            .first_conflicted_cid = first_conf_cid,
            .conflicted_commit_count = conf_commits,
            .shelved_draft_count = drafts_count,
            .pill_label = try std.fmt.allocPrint(
                allocator,
                "Git Export Blocked: {d} committed conflict{s} in c{d}",
                .{ conf_commits, if (conf_commits == 1) "" else "s", first_conf_cid.? },
            ),
        };
    }

    const head_cid = db.branches.items[0].head_commit;
    if (last_synced_cid != null and last_synced_cid.? == head_cid) {
        return .{
            .status = .in_sync,
            .first_conflicted_cid = null,
            .conflicted_commit_count = 0,
            .shelved_draft_count = drafts_count,
            .pill_label = try allocator.dupe(u8, "Git: In Sync ✓"),
        };
    }

    return .{
        .status = .ahead_clean,
        .first_conflicted_cid = null,
        .conflicted_commit_count = 0,
        .shelved_draft_count = drafts_count,
        .pill_label = try allocator.dupe(u8, "Git: Ready to Export ✓"),
    };
}

/// Export `db` to a `git fast-export` stream with state-aware conflict gating (`policy`).
pub fn exportToGitWithPolicy(
    allocator: Allocator,
    db: *const RepoDb,
    policy: GitConflictExportPolicy,
) ![]u8 {
    var health = try inspectGitBridgeHealth(allocator, db, null);
    defer health.deinit(allocator);

    if (health.status == .export_blocked_conflicts) {
        switch (policy) {
            .block_if_conflicted => return error.GitExportBlockedByCommittedConflict,
            .allow_partial_positive_basis, .export_clean_ancestors_only => {},
        }
    }
    return git_interop.emitFastExportStream(allocator, db);
}

// ============================================================================
// Unit Tests: All 6 UX Refinements & Plugin Guardrails
// ============================================================================

test "EditorPlugin 1: Conflicted files default to unchecked and require deliberate confirmation to commit" {
    const gpa = std.testing.allocator;
    var db = try RepoDb.initNew(gpa, "/tmp/wt-plugin-1");
    defer db.deinit();

    try db.editFile(0, "clean.zig", "const a = 1;\n");
    try db.editFile(0, "conflict.zig", "base line\n");
    _ = try db.commitWorktree(0, "alice", "c1: base");

    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "conflict.zig", "feat line\n");
    _ = try db.commitWorktree(0, "bob", "c2: feat edit");

    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "conflict.zig", "main line\n");
    _ = try db.commitWorktree(0, "alice", "c3: main edit");

    // Merge `feat` into `main` -> `conflict.zig` has a 2-sided PathSum conflict
    _ = try db.mergeBranch(0, "feat", "alice", "c4: merge feat");
    // Now make a new clean edit alongside the conflicted file
    try db.editFile(0, "clean.zig", "const a = 2;\n");

    const items = try buildWorkingChangesList(gpa, &db, 0);
    defer freeWorkingChangesList(gpa, items);

    var found_clean = false;
    var found_conf = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.path, "clean.zig")) {
            found_clean = true;
            try std.testing.expectEqual(FileChangeStatus.modified, it.status);
            try std.testing.expect(it.checked); // Clean file checked by default!
        } else if (std.mem.eql(u8, it.path, "conflict.zig")) {
            found_conf = true;
            try std.testing.expectEqual(FileChangeStatus.conflicted, it.status);
            try std.testing.expect(!it.checked); // Conflicted file UNCHECKED by default!
        }
    }
    try std.testing.expect(found_clean and found_conf);

    // Default button state is clean primary because `conflict.zig` is unchecked
    var btn_default = try computeCommitActionModel(gpa, items);
    defer btn_default.deinit(gpa);
    try std.testing.expectEqual(CommitButtonStyle.primary_clean, btn_default.style);
    try std.testing.expectEqualStrings("Commit Checked (1)", btn_default.label);

    // If user explicitly checks `conflict.zig`, button morphs into amber warning and blocks accidental commit!
    for (items) |*it| {
        if (std.mem.eql(u8, it.path, "conflict.zig")) it.checked = true;
    }
    var btn_warn = try computeCommitActionModel(gpa, items);
    defer btn_warn.deinit(gpa);
    try std.testing.expectEqual(CommitButtonStyle.amber_conflict_warning, btn_warn.style);
    try std.testing.expectEqualStrings("Commit Checked (Includes 1 Conflict ⚡)", btn_warn.label);

    try std.testing.expectError(
        error.UnacknowledgedConflictInCommit,
        commitCheckedItems(gpa, &db, 0, items, "alice", "accidental commit", false),
    );
}

test "EditorPlugin 2: Sub-file line/hunk selection commits bugfix while leaving debug logs in working tree" {
    const gpa = std.testing.allocator;
    var db = try RepoDb.initNew(gpa, "/tmp/wt-plugin-2");
    defer db.deinit();

    try db.editFile(0, "server.zig", "const port = 8080;\nconst debug = false;\n");
    _ = try db.commitWorktree(0, "alice", "c1: initial server");

    // Developer edits both line 1 (bugfix: port 9090) and line 2 (temporary debug log)
    try db.editFile(0, "server.zig", "const port = 9090;\nconst debug = true;\n");

    // Check only line 1 (`1..1`) for commit
    const c2 = try commitWithSubfileLineSelections(
        gpa,
        &db,
        0,
        "server.zig",
        &.{.{ .start_line = 1, .end_line = 1 }},
        "alice",
        "c2: fix port only",
    );

    // Verify commit `c2` has `port = 9090` and `debug = false`!
    const c2_tree = db.trees.items[db.commits.items[c2].root_tree_id];
    const c2_hash = c2_tree.getPathSum("server.zig").?.getCleanHash().?;
    try std.testing.expectEqualStrings(
        "const port = 9090;\nconst debug = false;\n",
        db.getBlob(c2_hash).?,
    );

    // Verify the working tree still has `const debug = true;` as a dirty edit!
    try std.testing.expect(db.worktrees.items[0].is_dirty);
    const work_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    const work_hash = work_tree.getPathSum("server.zig").?.getCleanHash().?;
    try std.testing.expectEqualStrings(
        "const port = 9090;\nconst debug = true;\n",
        db.getBlob(work_hash).?,
    );
}

test "EditorPlugin 3: Branch-switch toast and 1-click Bring Changes Here" {
    const gpa = std.testing.allocator;
    var db = try RepoDb.initNew(gpa, "/tmp/wt-plugin-3");
    defer db.deinit();

    try db.editFile(0, "app.zig", "v1\n");
    _ = try db.commitWorktree(0, "alice", "c1");

    // Make 2 uncommitted changes on `main` and switch to `feat`
    try db.editFile(0, "app.zig", "v2-uncommitted\n");
    try db.editFile(0, "new_helper.zig", "helper\n");

    var toast = try switchBranchWithToast(gpa, &db, 0, "feat");
    defer toast.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), toast.shelved_file_count);
    try std.testing.expect(toast.can_bring_changes_here);
    try std.testing.expectEqualStrings(
        "Shelved 2 files on main • [Bring Changes Here]",
        toast.toast_message.?,
    );

    // Click `[Bring Changes Here]` -> algebraically grafts the 2 shelved files onto `feat`!
    _ = try bringShelvedChangesHere(&db, 0, "main");
    try std.testing.expect(db.worktrees.items[0].is_dirty);
    const feat_work = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expect(feat_work.getPathSum("new_helper.zig") != null);
}

test "EditorPlugin 4: Human-first provenance labels and 2-pane conflict delta view" {
    const gpa = std.testing.allocator;
    var db = try RepoDb.initNew(gpa, "/tmp/wt-plugin-4");
    defer db.deinit();

    try db.editFile(0, "config.zig", "shared_header\ntimeout = 10\n");
    _ = try db.commitWorktree(0, "alice", "c1: base");

    _ = try db.switchBranch(0, "feat/ui-panel");
    try db.editFile(0, "config.zig", "shared_header\ntimeout = 30\n");
    _ = try db.commitWorktree(0, "bob", "c2: feat timeout");

    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "config.zig", "shared_header\ntimeout = 60\n");
    _ = try db.commitWorktree(0, "alice", "c3: main timeout");

    _ = try db.mergeBranch(0, "feat/ui-panel", "alice", "c4: merge");

    var vm = try buildTwoPaneConflictViewModel(gpa, &db, 0, "config.zig");
    defer vm.deinit(gpa);

    try std.testing.expectEqualStrings("Keep main (c3)", vm.keep_left_label);
    try std.testing.expectEqualStrings("Take feat/ui-panel (c2)", vm.take_right_label);
    try std.testing.expectEqualStrings("Undo Merge Commit (c4)", vm.reset_base_label);
    try std.testing.expectEqualStrings("shared_header\ntimeout = 10\n", vm.base_peek_bytes);
    try std.testing.expect(std.mem.indexOf(u8, vm.math_formula_badge, "Z[A_bot]") != null);
}

test "EditorPlugin 5: Oplog footer bar, read-only jump preview, cascade conflict dry-run, and Git export gating" {
    const gpa = std.testing.allocator;
    var db = try RepoDb.initNew(gpa, "/tmp/wt-plugin-5");
    defer db.deinit();

    try db.editFile(0, "main.zig", "line1\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: base");

    try db.editFile(0, "main.zig", "line2\n");
    const c2 = try db.commitWorktree(0, "alice", "c2: child");

    // 1. Collapsed single-line Oplog footer bar
    var footer = try buildOplogFooterBarModel(gpa, &db, false);
    defer footer.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, footer.collapsed_summary, "[Scrub ▴]") != null);

    // 2. Read-only Oplog jump diff preview + unsaved buffer guardrail
    const preview_diff = try previewOplogJumpDiff(gpa, &db, 0, 0);
    defer gpa.free(preview_diff);
    try std.testing.expect(preview_diff.len > 0);
    try std.testing.expectError(
        error.UnsavedEditorBuffersWouldBeClobbered,
        executeOplogJumpGuarded(&db, 0, true),
    );

    // 3. Immutable pushed commit guardrail & in-memory cascade conflict dry-run
    try std.testing.expectError(
        error.CommitIsImmutablePushed,
        amendCommitGuarded(&db, 0, c1, "rewrite pushed c1", c1, false),
    );

    // Edit `main.zig` in `wt0` so amending `c1` will conflict with `c2`!
    try db.editFile(0, "main.zig", "conflicting_amend_line\n");
    var dry_run = try previewAmendCascadeDryRun(gpa, &db, 0, c1, c1);
    defer dry_run.deinit(gpa);
    try std.testing.expect(dry_run.is_immutable_pushed);
    try std.testing.expect(dry_run.total_new_conflicts > 0);
    // Ensure dry-run did not mutate `db` (`main` head is still `c2`)
    try std.testing.expectEqual(c2, db.branches.items[0].head_commit);

    // 4. Actually amend `c1` (with override) -> creates conflicted `c2'`, which blocks Git export by default!
    _ = try amendCommitGuarded(&db, 0, c1, "rewrite c1", c1, true);
    var health = try inspectGitBridgeHealth(gpa, &db, null);
    defer health.deinit(gpa);
    try std.testing.expectEqual(GitBridgeStatusKind.export_blocked_conflicts, health.status);
    try std.testing.expectError(
        error.GitExportBlockedByCommittedConflict,
        exportToGitWithPolicy(gpa, &db, .block_if_conflicted),
    );
}
