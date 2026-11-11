//! CLI Command Dispatcher & Output Formatter (`zig_vcs <subcommand> [args...]`).
//!
//! Exposes a pure, workspace-parameterized entry point (`executeCommandInDir`) so that both
//! the native CLI (`src/main.zig`) and the Exhaustive CLI End-to-End Test Matrix
//! (`src/testing/cli_e2e_tests.zig`) execute the exact same argument parser, disk syncer,
//! materializer, and single-file `.vcs/db.vcs` storage paths under `std.testing.allocator`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const repo_db = @import("storage/repo_db.zig");
const paged_file = @import("storage/paged_file.zig");
const materializer = @import("worktree/materializer.zig");
const git_interop = @import("interop/git_interop.zig");

const SliceArgIter = struct {
    args: []const []const u8,
    idx: usize = 0,

    pub fn next(self: *SliceArgIter) ?[]const u8 {
        if (self.idx >= self.args.len) return null;
        const out = self.args[self.idx];
        self.idx += 1;
        return out;
    }
};

pub fn resolveCommandAlias(cmd: []const u8) []const u8 {
    if (std.mem.eql(u8, cmd, "st")) return "status";
    if (std.mem.eql(u8, cmd, "co") or std.mem.eql(u8, cmd, "checkout")) return "switch";
    if (std.mem.eql(u8, cmd, "ci")) return "commit";
    if (std.mem.eql(u8, cmd, "br")) return "branch";
    if (std.mem.eql(u8, cmd, "cp")) return "cherry-pick";
    if (std.mem.eql(u8, cmd, "wt")) return "worktree";
    if (std.mem.eql(u8, cmd, "up")) return "pull";
    if (std.mem.eql(u8, cmd, "cfg")) return "config";
    return cmd;
}

/// Execute a CLI command with `args` (where `args[0]` is the subcommand, e.g. `"init"`, `"status"`, etc.)
/// rooted at `workspace_dir` (`"."` when invoked from `main`), returning the captured stdout text.
pub fn executeCommandAlloc(
    gpa: Allocator,
    io: Io,
    workspace_dir: []const u8,
    args: []const []const u8,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try executeCommandInDir(gpa, io, workspace_dir, args, &aw.writer);
    return aw.toOwnedSlice();
}

/// Execute a CLI command with `args` rooted at `workspace_dir`, streaming output to `stdout`.
pub fn executeCommandInDir(
    gpa: Allocator,
    io: Io,
    workspace_dir: []const u8,
    args: []const []const u8,
    stdout: *Io.Writer,
) !void {
    var args_iter = SliceArgIter{ .args = args };
    const subcmd_opt = args_iter.next();
    if (subcmd_opt == null) {
        try printRootOverview(gpa, io, workspace_dir, null, stdout);
        try stdout.flush();
        return;
    }
    const raw_subcmd = subcmd_opt.?;
    const subcmd = resolveCommandAlias(raw_subcmd);

    // Check if `<subcmd> --help` or `<subcmd> -h` was passed for any subcommand
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try printCommandHelp(gpa, io, workspace_dir, subcmd, stdout);
            try stdout.flush();
            return;
        }
    }

    if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        if (args_iter.next()) |raw_topic| {
            const topic = resolveCommandAlias(raw_topic);
            if (std.mem.eql(u8, topic, "advanced") or std.mem.eql(u8, topic, "plumbing")) {
                try printAdvancedOverview(stdout, false);
            } else if (std.mem.eql(u8, topic, "--all") or std.mem.eql(u8, topic, "-a") or std.mem.eql(u8, topic, "all")) {
                try printRootOverview(gpa, io, workspace_dir, null, stdout);
                try stdout.writeByte('\n');
                try printAdvancedOverview(stdout, true);
            } else {
                try printCommandHelp(gpa, io, workspace_dir, topic, stdout);
            }
        } else {
            try printRootOverview(gpa, io, workspace_dir, null, stdout);
        }
        try stdout.flush();
        return;
    } else if (std.mem.eql(u8, subcmd, "--help-all") or std.mem.eql(u8, subcmd, "help-all")) {
        try printRootOverview(gpa, io, workspace_dir, null, stdout);
        try stdout.writeByte('\n');
        try printAdvancedOverview(stdout, true);
        try stdout.flush();
        return;
    } else if (std.mem.eql(u8, subcmd, "version") or std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "-v")) {
        try stdout.writeAll("zig_vcs 0.1.0 (Zig 0.17 | Single-File ZIGVCS02 + ZVCSPG01 | Lean 4 & TLA+ Verified)\n");
        try stdout.flush();
        return;
    } else if (std.mem.eql(u8, subcmd, "init")) {
        const vcs_dir = if (std.mem.eql(u8, workspace_dir, "."))
            try gpa.dupe(u8, ".vcs")
        else
            try std.fmt.allocPrint(gpa, "{s}/.vcs", .{workspace_dir});
        defer gpa.free(vcs_dir);

        const db_path = if (std.mem.eql(u8, workspace_dir, "."))
            try gpa.dupe(u8, ".vcs/db.vcs")
        else
            try std.fmt.allocPrint(gpa, "{s}/.vcs/db.vcs", .{workspace_dir});
        defer gpa.free(db_path);

        try Io.Dir.cwd().createDirPath(io, vcs_dir);
        var db = try repo_db.RepoDb.initNew(gpa, workspace_dir);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, 0, workspace_dir);
        try db.saveToFile(io, db_path);
        try stdout.print("Initialized single-file repository at {s} (branch: main, worktree: main-wt)\n", .{db_path});
    } else if (std.mem.eql(u8, subcmd, "status")) {
        var json_mode = false;
        var short_mode = false;
        var verbose_mode = false;
        var color_opt: ?bool = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                json_mode = true;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--short")) {
                short_mode = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                verbose_mode = true;
            } else if (parseColorFlag(arg)) |cval| {
                color_opt = cval;
            }
        }
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        const sync_stats = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.saveToFile(io, ctx.db_path);
        const use_color = resolveUseColor(&db, color_opt);
        if (json_mode) {
            const json_txt = try db.formatStatusJson(gpa, ctx.wt_id);
            defer gpa.free(json_txt);
            try stdout.writeAll(json_txt);
        } else if (short_mode) {
            const short_txt = try db.formatStatusShort(gpa, ctx.wt_id);
            defer gpa.free(short_txt);
            try stdout.writeAll(short_txt);
        } else {
            try printStatus(&db, ctx.wt_id, sync_stats, verbose_mode, use_color, stdout);
        }
    } else if (std.mem.eql(u8, subcmd, "switch")) {
        const target = args_iter.next() orelse return error.MissingBranchName;
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        _ = try db.switchBranch(ctx.wt_id, target);
        try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.saveToFile(io, ctx.db_path);
        try stdout.print("Switched worktree wt{d} to branch '{s}' (dirty state auto-shelved/restored)\n", .{ ctx.wt_id, target });
    } else if (std.mem.eql(u8, subcmd, "commit")) {
        var msg_opt: ?[]const u8 = null;
        var flag_msg = false;
        var author_opt: ?[]const u8 = null;
        var positional_args: std.ArrayList([]const u8) = .empty;
        defer positional_args.deinit(gpa);

        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                msg_opt = args_iter.next() orelse return error.MissingCommitMessage;
                flag_msg = true;
            } else if (std.mem.startsWith(u8, arg, "--message=")) {
                msg_opt = arg["--message=".len..];
                flag_msg = true;
            } else if (std.mem.eql(u8, arg, "--author")) {
                author_opt = args_iter.next() orelse return error.MissingAuthor;
            } else if (std.mem.startsWith(u8, arg, "--author=")) {
                author_opt = arg["--author=".len..];
            } else {
                try positional_args.append(gpa, arg);
            }
        }

        const msg: []const u8 = if (flag_msg)
            (msg_opt orelse "Snapshot commit")
        else if (positional_args.items.len > 0)
            positional_args.items[0]
        else
            "Snapshot commit";

        const path_filters: []const []const u8 = if (flag_msg)
            positional_args.items
        else if (positional_args.items.len > 1)
            positional_args.items[1..]
        else
            &.{};

        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        const author = try db.resolveCommitAuthorAlloc(gpa, author_opt);
        defer gpa.free(author);
        const cid = try db.commitWorktreePaths(ctx.wt_id, author, msg, path_filters);
        try db.saveToFile(io, ctx.db_path);
        try stdout.print("Created commit c{d}: {s}\n", .{ cid, msg });
    } else if (std.mem.eql(u8, subcmd, "squash")) {
        var flag_msg_opt: ?[]const u8 = null;
        var pos_args: std.ArrayList([]const u8) = .empty;
        defer pos_args.deinit(gpa);
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                flag_msg_opt = args_iter.next() orelse return error.MissingCommitMessage;
            } else if (std.mem.startsWith(u8, arg, "--message=")) {
                flag_msg_opt = arg["--message=".len..];
            } else {
                try pos_args.append(gpa, arg);
            }
        }
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        var target_cid_opt: ?repo_db.CommitId = null;
        var new_msg_opt: ?[]const u8 = flag_msg_opt;
        if (pos_args.items.len > 0) {
            const a1 = pos_args.items[0];
            if (db.resolveRevision(ctx.wt_id, a1)) |resolved_cid| {
                target_cid_opt = resolved_cid;
                if (new_msg_opt == null and pos_args.items.len > 1) {
                    new_msg_opt = pos_args.items[1];
                }
            } else |_| {
                if (new_msg_opt == null) new_msg_opt = a1;
            }
        }
        const new_cid = try db.squashCommit(ctx.wt_id, target_cid_opt, new_msg_opt);
        try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.saveToFile(io, ctx.db_path);
        try stdout.print("Squashed commit into parent (with descendant auto-rebase) -> commit c{d}\n", .{new_cid});
    } else if (std.mem.eql(u8, subcmd, "fsck")) {
        var json_mode = false;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) json_mode = true;
        }
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        const report = try db.verifyIntegrity();
        if (json_mode) {
            try stdout.print(
                "{{\"status\":\"ok\",\"blobs\":{d},\"trees\":{d},\"commits\":{d},\"branches\":{d},\"worktrees\":{d},\"oplog\":{d}}}\n",
                .{
                    report.blobs_verified,
                    report.trees_verified,
                    report.commits_verified,
                    report.branches_verified,
                    report.worktrees_verified,
                    report.oplog_verified,
                },
            );
        } else {
            try stdout.print(
                "fsck ok: blobs={d} (BLAKE3+INV-5), trees={d} (Z[A_bot] sum=1), commits={d} (DAG acyclic), branches={d}, worktrees={d}, oplog={d}\n",
                .{
                    report.blobs_verified,
                    report.trees_verified,
                    report.commits_verified,
                    report.branches_verified,
                    report.worktrees_verified,
                    report.oplog_verified,
                },
            );
        }
    } else if (std.mem.eql(u8, subcmd, "merge")) {
        var src_branches: std.ArrayList([]const u8) = .empty;
        defer src_branches.deinit(gpa);
        var merge_msg_opt: ?[]const u8 = null;
        var author_opt: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                merge_msg_opt = args_iter.next() orelse return error.MissingCommitMessage;
            } else if (std.mem.startsWith(u8, arg, "--message=")) {
                merge_msg_opt = arg["--message=".len..];
            } else if (std.mem.eql(u8, arg, "--author")) {
                author_opt = args_iter.next() orelse return error.MissingAuthor;
            } else if (std.mem.startsWith(u8, arg, "--author=")) {
                author_opt = arg["--author=".len..];
            } else {
                try src_branches.append(gpa, arg);
            }
        }
        if (src_branches.items.len == 0) return error.MissingSourceBranch;
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        const author = try db.resolveCommitAuthorAlloc(gpa, author_opt);
        defer gpa.free(author);
        const cid = try db.mergeMultipleBranches(
            ctx.wt_id,
            src_branches.items,
            author,
            merge_msg_opt orelse "Algebraic B+C-A merge",
        );
        try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.saveToFile(io, ctx.db_path);
        const has_conf = db.trees.items[db.worktrees.items[ctx.wt_id].working_tree_id].hasConflicts();
        try stdout.print("Merged {d} branch(es) -> commit c{d} (conflicts={any})\n", .{ src_branches.items.len, cid, has_conf });
    } else if (std.mem.eql(u8, subcmd, "amend")) {
        var flag_msg_opt: ?[]const u8 = null;
        var pos_args: std.ArrayList([]const u8) = .empty;
        defer pos_args.deinit(gpa);
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                flag_msg_opt = args_iter.next() orelse return error.MissingCommitMessage;
            } else if (std.mem.startsWith(u8, arg, "--message=")) {
                flag_msg_opt = arg["--message=".len..];
            } else {
                try pos_args.append(gpa, arg);
            }
        }
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        var target_cid_opt: ?repo_db.CommitId = null;
        var new_msg_opt: ?[]const u8 = flag_msg_opt;
        if (pos_args.items.len > 0) {
            const a1 = pos_args.items[0];
            if (db.resolveRevision(ctx.wt_id, a1)) |resolved_cid| {
                target_cid_opt = resolved_cid;
                if (new_msg_opt == null and pos_args.items.len > 1) {
                    new_msg_opt = pos_args.items[1];
                }
            } else |_| {
                if (new_msg_opt == null) new_msg_opt = a1;
            }
        }
        const new_cid = try db.amendCommit(ctx.wt_id, target_cid_opt, new_msg_opt);
        try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.saveToFile(io, ctx.db_path);
        try stdout.print("Amended commit (with descendant auto-rebase) -> commit c{d}\n", .{new_cid});
    } else if (std.mem.eql(u8, subcmd, "blame")) {
        const path = args_iter.next() orelse return error.MissingFilePath;
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        const cid = if (args_iter.next()) |rev_arg|
            try db.resolveRevision(ctx.wt_id, rev_arg)
        else
            db.branches.items[db.worktrees.items[ctx.wt_id].branch_id].head_commit;
        const blame_out = try db.blameFile(gpa, cid, path);
        defer gpa.free(blame_out);
        try stdout.writeAll(blame_out);
    } else if (std.mem.eql(u8, subcmd, "rebase")) {
        const br = args_iter.next() orelse return error.MissingBranchName;
        const onto = args_iter.next() orelse return error.MissingOntoBranch;
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        const cid = try db.rebaseCommitOnto(br, onto);
        try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.saveToFile(io, ctx.db_path);
        try stdout.print("Rebased '{s}' onto '{s}' -> commit c{d}\n", .{ br, onto, cid });
    } else if (std.mem.eql(u8, subcmd, "resolve")) {
        const path = args_iter.next() orelse return error.MissingFilePath;
        const arg2 = args_iter.next() orelse return error.MissingContent;
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        if (std.mem.eql(u8, arg2, "--ours")) {
            try db.resolveFileWithStrategy(ctx.wt_id, path, .ours);
        } else if (std.mem.eql(u8, arg2, "--theirs")) {
            try db.resolveFileWithStrategy(ctx.wt_id, path, .theirs);
        } else if (std.mem.eql(u8, arg2, "--base")) {
            try db.resolveFileWithStrategy(ctx.wt_id, path, .base);
        } else {
            try db.resolveFile(ctx.wt_id, path, arg2);
        }
        try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.saveToFile(io, ctx.db_path);
        try stdout.print("Resolved conflict on '{s}' to clean basis term\n", .{path});
    } else if (std.mem.eql(u8, subcmd, "restore")) {
        const path = args_iter.next() orelse return error.MissingFilePath;
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        const rev_cid: ?repo_db.CommitId = if (args_iter.next()) |rev_arg|
            try db.resolveRevision(ctx.wt_id, rev_arg)
        else
            null;
        const count = try db.restorePathFromRevision(ctx.wt_id, path, rev_cid);
        try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.saveToFile(io, ctx.db_path);
        try stdout.print("Restored {d} path(s) matching '{s}'\n", .{ count, path });
    } else if (std.mem.eql(u8, subcmd, "cherry-pick")) {
        var rev_opt: ?[]const u8 = null;
        var msg_opt: ?[]const u8 = null;
        var author_opt: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                msg_opt = args_iter.next() orelse return error.MissingCommitMessage;
            } else if (std.mem.startsWith(u8, arg, "--message=")) {
                msg_opt = arg["--message=".len..];
            } else if (std.mem.eql(u8, arg, "--author")) {
                author_opt = args_iter.next() orelse return error.MissingAuthor;
            } else if (std.mem.startsWith(u8, arg, "--author=")) {
                author_opt = arg["--author=".len..];
            } else if (rev_opt == null) {
                rev_opt = arg;
            } else if (msg_opt == null) {
                msg_opt = arg;
            }
        }
        const rev_arg = rev_opt orelse return error.MissingCommitId;
        const msg = msg_opt orelse "Algebraic cherry-pick";
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        const author = try db.resolveCommitAuthorAlloc(gpa, author_opt);
        defer gpa.free(author);
        if (std.mem.indexOf(u8, rev_arg, "..")) |dot_idx| {
            const lhs = rev_arg[0..dot_idx];
            const rhs = rev_arg[dot_idx + 2 ..];
            const base_cid = try db.resolveRevision(ctx.wt_id, lhs);
            const tip_cid = try db.resolveRevision(ctx.wt_id, rhs);
            const new_cid = try db.cherryPickCommitRange(ctx.wt_id, base_cid, tip_cid, author, msg);
            try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Cherry-picked range c{d}..c{d} -> created commit c{d}\n", .{ base_cid, tip_cid, new_cid });
        } else {
            const target_cid = try db.resolveRevision(ctx.wt_id, rev_arg);
            const new_cid = try db.cherryPickCommit(ctx.wt_id, target_cid, author, msg);
            try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Cherry-picked commit c{d} -> created commit c{d}\n", .{ target_cid, new_cid });
        }
    } else if (std.mem.eql(u8, subcmd, "backout")) {
        var rev_opt: ?[]const u8 = null;
        var msg_opt: ?[]const u8 = null;
        var author_opt: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                msg_opt = args_iter.next() orelse return error.MissingCommitMessage;
            } else if (std.mem.startsWith(u8, arg, "--message=")) {
                msg_opt = arg["--message=".len..];
            } else if (std.mem.eql(u8, arg, "--author")) {
                author_opt = args_iter.next() orelse return error.MissingAuthor;
            } else if (std.mem.startsWith(u8, arg, "--author=")) {
                author_opt = arg["--author=".len..];
            } else if (rev_opt == null) {
                rev_opt = arg;
            } else if (msg_opt == null) {
                msg_opt = arg;
            }
        }
        const rev_arg = rev_opt orelse return error.MissingCommitId;
        const msg = msg_opt orelse "Algebraic backout";
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        const author = try db.resolveCommitAuthorAlloc(gpa, author_opt);
        defer gpa.free(author);
        if (std.mem.indexOf(u8, rev_arg, "..")) |dot_idx| {
            const lhs = rev_arg[0..dot_idx];
            const rhs = rev_arg[dot_idx + 2 ..];
            const base_cid = try db.resolveRevision(ctx.wt_id, lhs);
            const tip_cid = try db.resolveRevision(ctx.wt_id, rhs);
            const new_cid = try db.backoutCommitRange(ctx.wt_id, base_cid, tip_cid, author, msg);
            try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Backed out range c{d}..c{d} -> created commit c{d}\n", .{ base_cid, tip_cid, new_cid });
        } else {
            const target_cid = try db.resolveRevision(ctx.wt_id, rev_arg);
            const new_cid = try db.backoutCommit(ctx.wt_id, target_cid, author, msg);
            try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Backed out commit c{d} -> created commit c{d}\n", .{ target_cid, new_cid });
        }
    } else if (std.mem.eql(u8, subcmd, "tag")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();

        if (args_iter.next()) |arg1| {
            if (std.mem.eql(u8, arg1, "-d") or std.mem.eql(u8, arg1, "delete")) {
                const tag_name = args_iter.next() orelse return error.MissingTagName;
                if (try db.deleteTag(tag_name)) {
                    try db.saveToFile(io, ctx.db_path);
                    try stdout.print("Deleted tag '{s}'\n", .{tag_name});
                } else {
                    return error.TagNotFound;
                }
            } else {
                const target_cid = if (args_iter.next()) |rev_arg|
                    try db.resolveRevision(ctx.wt_id, rev_arg)
                else
                    db.branches.items[db.worktrees.items[ctx.wt_id].branch_id].head_commit;
                try db.createTag(arg1, target_cid);
                try db.saveToFile(io, ctx.db_path);
                try stdout.print("Tagged commit c{d} as '{s}'\n", .{ target_cid, arg1 });
            }
        } else {
            for (db.tags.items) |t| {
                try stdout.print("{s}\tc{d}\n", .{ t.name, t.target_commit });
            }
        }
    } else if (std.mem.eql(u8, subcmd, "bisect")) {
        const good_rev = args_iter.next() orelse return error.MissingGoodRevision;
        const bad_rev = args_iter.next() orelse return error.MissingBadRevision;
        const path = args_iter.next() orelse return error.MissingFilePath;
        const needle = args_iter.next() orelse return error.MissingSearchNeedle;
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        const good_cid = try db.resolveRevision(ctx.wt_id, good_rev);
        const bad_cid = try db.resolveRevision(ctx.wt_id, bad_rev);
        const culprit_cid = try db.bisectCommitRange(gpa, good_cid, bad_cid, path, needle);
        const rec = db.commits.items[culprit_cid];
        try stdout.print("c{d} is the first bad commit ({s}: \"{s}\")\n", .{ culprit_cid, rec.author, rec.message });
    } else if (std.mem.eql(u8, subcmd, "search")) {
        const needle = args_iter.next() orelse return error.MissingSearchNeedle;
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        const results = try db.searchHistory(gpa, needle);
        defer gpa.free(results);
        try stdout.writeAll(results);
    } else if (std.mem.eql(u8, subcmd, "gc")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var img = try paged_file.PagedImage.readFromFile(gpa, io, ctx.db_path);
        defer img.deinit();
        const reclaimed = try img.compactAndGC(gpa);
        try img.writeToFile(io, ctx.db_path);
        try stdout.print("Compacted {s}: reclaimed {d} shadow pages ({d} KB)\n", .{
            ctx.db_path,
            reclaimed,
            reclaimed * 4,
        });
    } else if (std.mem.eql(u8, subcmd, "log")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        var base_cid: ?repo_db.CommitId = null;
        var start_cid: ?repo_db.CommitId = db.branches.items[db.worktrees.items[ctx.wt_id].branch_id].head_commit;
        var max_count: ?usize = null;
        var include_stat = false;
        var json_mode = false;
        var oneline_mode = false;
        var color_opt: ?bool = null;
        var path_filter: ?[]const u8 = null;
        var after_dashdash = false;
        while (args_iter.next()) |arg| {
            if (after_dashdash) {
                path_filter = arg;
            } else if (std.mem.eql(u8, arg, "--")) {
                after_dashdash = true;
            } else if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
                start_cid = null;
            } else if (std.mem.eql(u8, arg, "--stat")) {
                include_stat = true;
            } else if (std.mem.eql(u8, arg, "--json")) {
                json_mode = true;
            } else if (std.mem.eql(u8, arg, "--oneline")) {
                oneline_mode = true;
            } else if (parseColorFlag(arg)) |cval| {
                color_opt = cval;
            } else if (std.mem.eql(u8, arg, "-n")) {
                const n_str = args_iter.next() orelse return error.MissingCount;
                max_count = try std.fmt.parseInt(usize, n_str, 10);
            } else if (std.mem.indexOf(u8, arg, "..")) |dot_idx| {
                const lhs = arg[0..dot_idx];
                const rhs = arg[dot_idx + 2 ..];
                base_cid = if (lhs.len > 0) try db.resolveRevision(ctx.wt_id, lhs) else null;
                start_cid = if (rhs.len > 0) try db.resolveRevision(ctx.wt_id, rhs) else null;
            } else if (db.resolveRevision(ctx.wt_id, arg)) |resolved_cid| {
                start_cid = resolved_cid;
            } else |_| {
                path_filter = arg;
            }
        }
        const log_text = if (json_mode)
            try db.formatCommitLogJsonRange(gpa, base_cid, start_cid, max_count, path_filter)
        else if (oneline_mode)
            try db.formatCommitLogOneline(gpa, base_cid, start_cid, max_count, path_filter)
        else
            try db.formatCommitLogRange(gpa, base_cid, start_cid, max_count, include_stat, path_filter);
        defer gpa.free(log_text);
        if (!json_mode and resolveUseColor(&db, color_opt)) {
            try writeColorizedCommitLog(log_text, stdout);
        } else {
            try stdout.writeAll(log_text);
        }
    } else if (std.mem.eql(u8, subcmd, "diff")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        const wt = db.worktrees.items[ctx.wt_id];
        const head_cid = db.branches.items[wt.branch_id].head_commit;
        var base_tid = db.commits.items[head_cid].root_tree_id;
        var target_tid = wt.working_tree_id;
        var path_filter: ?[]const u8 = null;
        var stat_only = false;
        var color_opt: ?bool = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--stat")) {
                stat_only = true;
            } else if (parseColorFlag(arg)) |cval| {
                color_opt = cval;
            } else if (std.mem.indexOf(u8, arg, "..")) |dot_idx| {
                const lhs = arg[0..dot_idx];
                const rhs = arg[dot_idx + 2 ..];
                const lhs_cid = if (lhs.len > 0) try db.resolveRevision(ctx.wt_id, lhs) else head_cid;
                const rhs_cid = if (rhs.len > 0) try db.resolveRevision(ctx.wt_id, rhs) else head_cid;
                base_tid = db.commits.items[lhs_cid].root_tree_id;
                target_tid = db.commits.items[rhs_cid].root_tree_id;
            } else if (db.resolveRevision(ctx.wt_id, arg)) |resolved_cid| {
                base_tid = db.commits.items[resolved_cid].root_tree_id;
            } else |_| {
                path_filter = arg;
            }
        }

        const diff_text = if (stat_only)
            try db.formatDiffStat(gpa, base_tid, target_tid)
        else
            try db.diffTreesUnifiedFiltered(gpa, base_tid, target_tid, path_filter);
        defer gpa.free(diff_text);
        if (!stat_only and resolveUseColor(&db, color_opt)) {
            try writeColorizedUnifiedDiff(diff_text, stdout);
        } else {
            try stdout.writeAll(diff_text);
        }
    } else if (std.mem.eql(u8, subcmd, "draft")) {
        const draft_action = args_iter.next() orelse "list";
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();

        if (std.mem.eql(u8, draft_action, "list") or std.mem.eql(u8, draft_action, "--json")) {
            var json_mode = std.mem.eql(u8, draft_action, "--json");
            if (!json_mode) {
                if (args_iter.next()) |next_arg| {
                    if (std.mem.eql(u8, next_arg, "--json")) json_mode = true;
                }
            }
            const out_txt = if (json_mode)
                try db.formatDraftsJson(gpa)
            else
                try db.formatDraftsList(gpa);
            defer gpa.free(out_txt);
            try stdout.writeAll(out_txt);
        } else if (std.mem.eql(u8, draft_action, "show")) {
            const br_name = args_iter.next() orelse db.branches.items[db.worktrees.items[ctx.wt_id].branch_id].name;
            const diff_txt = try db.showBranchDraftDiff(gpa, ctx.wt_id, br_name);
            defer gpa.free(diff_txt);
            try stdout.writeAll(diff_txt);
        } else if (std.mem.eql(u8, draft_action, "apply")) {
            const br_name = args_iter.next() orelse return error.MissingBranchName;
            _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
            _ = try db.applyBranchDraft(ctx.wt_id, br_name);
            try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Algebraically applied draft from branch '{s}' onto worktree wt{d}\n", .{ br_name, ctx.wt_id });
        } else if (std.mem.eql(u8, draft_action, "drop")) {
            const br_name = args_iter.next() orelse return error.MissingBranchName;
            if (try db.dropBranchDraft(ctx.wt_id, br_name)) {
                try db.saveToFile(io, ctx.db_path);
                try stdout.print("Dropped shelved draft for branch '{s}' (recoverable via undo)\n", .{br_name});
            } else {
                try stdout.print("No shelved draft found for branch '{s}'\n", .{br_name});
            }
        } else {
            return error.UnknownDraftAction;
        }
    } else if (std.mem.eql(u8, subcmd, "worktree")) {
        const wt_action = args_iter.next() orelse "list";
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();

        if (std.mem.eql(u8, wt_action, "list") or std.mem.eql(u8, wt_action, "--json")) {
            var json_mode = std.mem.eql(u8, wt_action, "--json");
            if (!json_mode) {
                if (args_iter.next()) |next_arg| {
                    if (std.mem.eql(u8, next_arg, "--json")) json_mode = true;
                }
            }
            if (json_mode) {
                const json_txt = try db.formatWorktreesJson(gpa);
                defer gpa.free(json_txt);
                try stdout.writeAll(json_txt);
            } else {
                for (db.worktrees.items) |wt| {
                    const br = db.branches.items[wt.branch_id];
                    try stdout.print("wt{d}\t{s}\tpath={s}\tbranch={s}\topen={any}\tdirty={any}\n", .{
                        wt.id,
                        wt.name,
                        wt.fs_path,
                        br.name,
                        wt.is_open,
                        wt.is_dirty,
                    });
                }
            }
        } else if (std.mem.eql(u8, wt_action, "add")) {
            const name = args_iter.next() orelse return error.MissingWorktreeName;
            const fs_path = args_iter.next() orelse return error.MissingWorktreePath;
            const br_name = args_iter.next() orelse name;
            const new_wt_id = try materializer.createLinkedWorktreeOnDisk(
                gpa,
                io,
                &db,
                ctx.db_path,
                name,
                fs_path,
                br_name,
            );
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Created linked worktree wt{d} ('{s}') at {s} on branch '{s}'\n", .{
                new_wt_id,
                name,
                fs_path,
                br_name,
            });
        } else if (std.mem.eql(u8, wt_action, "close")) {
            const name = args_iter.next() orelse return error.MissingWorktreeName;
            const wid = db.findWorktreeByName(name) orelse return error.WorktreeNotFound;
            _ = materializer.syncWorktreeFromDisk(gpa, io, &db, wid, db.worktrees.items[wid].fs_path) catch {};
            try db.closeWorktree(wid);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Closed worktree wt{d} ('{s}') (uncommitted drafts preserved in single DB)\n", .{ wid, name });
        } else if (std.mem.eql(u8, wt_action, "reopen")) {
            const name = args_iter.next() orelse return error.MissingWorktreeName;
            const wid = db.findWorktreeByName(name) orelse return error.WorktreeNotFound;
            try db.reopenWorktree(wid);
            try materializer.materializeWorktreeToDir(gpa, io, &db, wid, db.worktrees.items[wid].fs_path);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Reopened worktree wt{d} ('{s}')\n", .{ wid, name });
        } else {
            return error.UnknownWorktreeAction;
        }
    } else if (std.mem.eql(u8, subcmd, "undo")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        if (try db.undo()) {
            try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Undid last operation via single-DB oplog.\n", .{});
        } else {
            try stdout.print("Oplog is empty; nothing to undo.\n", .{});
        }
    } else if (std.mem.eql(u8, subcmd, "redo")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        if (try db.redo()) {
            try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Redid operation via single-DB redo stack.\n", .{});
        } else {
            try stdout.print("Redo stack is empty; nothing to redo.\n", .{});
        }
    } else if (std.mem.eql(u8, subcmd, "oplog")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();

        var json_mode = false;
        var max_count: ?usize = null;
        var restore_idx_opt: ?usize = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                json_mode = true;
            } else if (std.mem.eql(u8, arg, "-n")) {
                const n_str = args_iter.next() orelse return error.MissingCount;
                max_count = try std.fmt.parseInt(usize, n_str, 10);
            } else if (std.mem.eql(u8, arg, "restore")) {
                const idx_str = args_iter.next() orelse return error.MissingOplogIndex;
                restore_idx_opt = try std.fmt.parseInt(usize, idx_str, 10);
            }
        }

        if (restore_idx_opt) |r_idx| {
            try db.restoreOplogAtIndex(r_idx);
            try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Restored repository state from oplog[{d}] (recoverable via undo).\n", .{r_idx});
        } else if (json_mode) {
            const json_txt = try db.formatOplogJson(gpa, max_count);
            defer gpa.free(json_txt);
            try stdout.writeAll(json_txt);
        } else {
            try stdout.print("Single-DB Oplog ({d} entries):\n", .{db.oplog.items.len});
            var emitted: usize = 0;
            var idx = db.oplog.items.len;
            while (idx > 0) {
                idx -= 1;
                if (max_count) |limit| {
                    if (emitted >= limit) break;
                }
                emitted += 1;
                const op = db.oplog.items[idx];
                try stdout.print("  [{d}] {s}\n", .{ idx, op.command_desc });
            }
        }
    } else if (std.mem.eql(u8, subcmd, "archive")) {
        const out_path = args_iter.next() orelse return error.MissingOutputPath;
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();

        var rev_cid = db.branches.items[db.worktrees.items[ctx.wt_id].branch_id].head_commit;
        var prefix: []const u8 = "";
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--prefix")) {
                prefix = args_iter.next() orelse return error.MissingPrefix;
            } else if (std.mem.startsWith(u8, arg, "--prefix=")) {
                prefix = arg["--prefix=".len..];
            } else {
                rev_cid = try db.resolveRevision(ctx.wt_id, arg);
            }
        }

        const tar_bytes = try db.exportRevisionTarBytes(gpa, rev_cid, prefix);
        defer gpa.free(tar_bytes);

        const f = try Io.Dir.cwd().createFile(io, out_path, .{});
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var w: Io.File.Writer = .init(f, io, &buf);
        try w.interface.writeAll(tar_bytes);
        try w.interface.flush();
        try stdout.print("Exported POSIX tar archive for c{d} ({d} bytes) to {s}\n", .{ rev_cid, tar_bytes.len, out_path });
    } else if (std.mem.eql(u8, subcmd, "git-export")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        const stream = try git_interop.emitFastExportStream(gpa, &db);
        defer gpa.free(stream);
        if (args_iter.next()) |out_path| {
            const f = try Io.Dir.cwd().createFile(io, out_path, .{});
            defer f.close(io);
            var buf: [4096]u8 = undefined;
            var w: Io.File.Writer = .init(f, io, &buf);
            try w.interface.writeAll(stream);
            try w.interface.flush();
            try stdout.print("Exported git fast-import stream ({d} bytes) to {s}\n", .{ stream.len, out_path });
        } else {
            try stdout.writeAll(stream);
        }
    } else if (std.mem.eql(u8, subcmd, "git-import")) {
        const in_path = args_iter.next() orelse return error.MissingFastExportFile;
        const stream = try Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .limited(64 * 1024 * 1024));
        defer gpa.free(stream);

        const vcs_dir = if (std.mem.eql(u8, workspace_dir, "."))
            try gpa.dupe(u8, ".vcs")
        else
            try std.fmt.allocPrint(gpa, "{s}/.vcs", .{workspace_dir});
        defer gpa.free(vcs_dir);

        const db_path = if (std.mem.eql(u8, workspace_dir, "."))
            try gpa.dupe(u8, ".vcs/db.vcs")
        else
            try std.fmt.allocPrint(gpa, "{s}/.vcs/db.vcs", .{workspace_dir});
        defer gpa.free(db_path);

        var db = repo_db.RepoDb.loadFromFile(gpa, io, db_path) catch blk: {
            try Io.Dir.cwd().createDirPath(io, vcs_dir);
            break :blk try repo_db.RepoDb.initNew(gpa, workspace_dir);
        };
        defer db.deinit();

        try git_interop.importFastExportStream(gpa, &db, stream);
        try materializer.materializeWorktreeToDir(gpa, io, &db, 0, workspace_dir);
        try db.saveToFile(io, db_path);
        try stdout.print("Imported git fast-export stream from {s} (commits={d}, branches={d})\n", .{
            in_path,
            db.commits.items.len,
            db.branches.items.len,
        });
    } else if (std.mem.eql(u8, subcmd, "clone")) {
        const src_arg = args_iter.next() orelse return error.MissingRemotePath;
        const dst_dir_raw = args_iter.next() orelse git_interop.inferCloneDirName(src_arg);
        const trimmed_dst = std.mem.trimEnd(u8, dst_dir_raw, "/");
        const dst_dir = if (trimmed_dst.len == 0 or std.mem.eql(u8, trimmed_dst, "."))
            workspace_dir
        else
            trimmed_dst;

        const dst_vcs_dir = try std.fmt.allocPrint(gpa, "{s}/.vcs", .{dst_dir});
        defer gpa.free(dst_vcs_dir);
        const dst_db_path = try std.fmt.allocPrint(gpa, "{s}/.vcs/db.vcs", .{dst_dir});
        defer gpa.free(dst_db_path);

        try Io.Dir.cwd().createDirPath(io, dst_vcs_dir);

        var cloned_db = if (git_interop.isGitRemote(gpa, io, src_arg))
            try git_interop.loadRepoDbFromGitRemote(gpa, io, dst_vcs_dir, src_arg)
        else blk: {
            const src_db_path = try resolveRemoteDbPath(gpa, io, src_arg);
            defer gpa.free(src_db_path);
            break :blk try repo_db.RepoDb.loadFromFile(gpa, io, src_db_path);
        };
        defer cloned_db.deinit();

        try cloned_db.prepareAsFreshClone(dst_dir, src_arg);
        try materializer.materializeWorktreeToDir(gpa, io, &cloned_db, 0, dst_dir);
        try cloned_db.saveToFile(io, dst_db_path);
        try stdout.print("Cloned {s} into {s} (origin='{s}', commits={d}, branches={d})\n", .{
            src_arg,
            dst_dir,
            src_arg,
            cloned_db.commits.items.len,
            cloned_db.branches.items.len,
        });
    } else if (std.mem.eql(u8, subcmd, "remote")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();

        const action = args_iter.next() orelse "list";
        if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "-v")) {
            for (db.remotes.items) |r| {
                try stdout.print("{s}\t{s}\n", .{ r.name, r.path });
            }
        } else if (std.mem.eql(u8, action, "add") or std.mem.eql(u8, action, "set-url")) {
            const name = args_iter.next() orelse return error.MissingRemoteName;
            const path = args_iter.next() orelse return error.MissingRemotePath;
            try db.setRemote(name, path);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Configured remote '{s}' -> '{s}'\n", .{ name, path });
        } else if (std.mem.eql(u8, action, "remove") or std.mem.eql(u8, action, "rm")) {
            const name = args_iter.next() orelse return error.MissingRemoteName;
            if (try db.removeRemote(name)) {
                try db.saveToFile(io, ctx.db_path);
                try stdout.print("Removed remote '{s}'\n", .{name});
            } else {
                return error.RemoteNotFound;
            }
        } else {
            return error.UnknownRemoteAction;
        }
    } else if (std.mem.eql(u8, subcmd, "fetch")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();

        const vcs_dir = std.fs.path.dirname(ctx.db_path) orelse ".vcs";
        const remote_arg = args_iter.next() orelse "origin";
        const resolved_remote = db.resolveRemoteOrPath(remote_arg);

        var remote_db = if (git_interop.isGitRemote(gpa, io, resolved_remote))
            try git_interop.loadRepoDbFromGitRemote(gpa, io, vcs_dir, resolved_remote)
        else blk: {
            const remote_db_path = try resolveRemoteDbPath(gpa, io, resolved_remote);
            defer gpa.free(remote_db_path);
            break :blk try repo_db.RepoDb.loadFromFile(gpa, io, remote_db_path);
        };
        defer remote_db.deinit();

        const br_name = args_iter.next() orelse db.branches.items[db.worktrees.items[ctx.wt_id].branch_id].name;
        const fetched_cid = try db.fetchFromRemote(&remote_db, br_name);
        try db.saveToFile(io, ctx.db_path);
        try stdout.print("Fetched '{s}' from {s} -> local commit c{d}\n", .{ br_name, remote_arg, fetched_cid });
    } else if (std.mem.eql(u8, subcmd, "pull")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);

        const vcs_dir = std.fs.path.dirname(ctx.db_path) orelse ".vcs";
        const remote_arg = args_iter.next() orelse "origin";
        const resolved_remote = db.resolveRemoteOrPath(remote_arg);

        var remote_db = if (git_interop.isGitRemote(gpa, io, resolved_remote))
            try git_interop.loadRepoDbFromGitRemote(gpa, io, vcs_dir, resolved_remote)
        else blk: {
            const remote_db_path = try resolveRemoteDbPath(gpa, io, resolved_remote);
            defer gpa.free(remote_db_path);
            break :blk try repo_db.RepoDb.loadFromFile(gpa, io, remote_db_path);
        };
        defer remote_db.deinit();

        const br_name = args_iter.next() orelse db.branches.items[db.worktrees.items[ctx.wt_id].branch_id].name;
        const author = try db.resolveCommitAuthorAlloc(gpa, null);
        defer gpa.free(author);
        const pulled_cid = try db.pullFromRemote(ctx.wt_id, &remote_db, br_name, author);
        try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.saveToFile(io, ctx.db_path);
        try stdout.print("Pulled '{s}' from {s} -> commit c{d}\n", .{ br_name, remote_arg, pulled_cid });
    } else if (std.mem.eql(u8, subcmd, "push")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();

        const vcs_dir = std.fs.path.dirname(ctx.db_path) orelse ".vcs";
        const remote_arg = args_iter.next() orelse "origin";
        const resolved_remote = db.resolveRemoteOrPath(remote_arg);
        const is_git_remote = git_interop.isGitRemote(gpa, io, resolved_remote);

        var remote_db = if (is_git_remote)
            try git_interop.loadRepoDbFromGitRemote(gpa, io, vcs_dir, resolved_remote)
        else blk: {
            const remote_db_path = try resolveRemoteDbPath(gpa, io, resolved_remote);
            defer gpa.free(remote_db_path);
            break :blk try repo_db.RepoDb.loadFromFile(gpa, io, remote_db_path);
        };
        defer remote_db.deinit();

        var br_name: []const u8 = db.branches.items[db.worktrees.items[ctx.wt_id].branch_id].name;
        var force = false;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
                force = true;
            } else {
                br_name = arg;
            }
        }
        const pushed_cid = try db.pushToRemote(&remote_db, br_name, force);
        if (is_git_remote) {
            try git_interop.exportRepoDbToGitRemote(gpa, io, vcs_dir, &remote_db, resolved_remote, br_name, force);
        } else {
            const remote_db_path = try resolveRemoteDbPath(gpa, io, resolved_remote);
            defer gpa.free(remote_db_path);
            try remote_db.saveToFile(io, remote_db_path);
        }
        try stdout.print("Pushed '{s}' to {s} -> remote commit c{d}\n", .{ br_name, remote_arg, pushed_cid });
    } else if (std.mem.eql(u8, subcmd, "branch")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();

        if (args_iter.next()) |arg1| {
            if (std.mem.eql(u8, arg1, "--json")) {
                const json_txt = try db.formatBranchesJson(gpa, ctx.wt_id);
                defer gpa.free(json_txt);
                try stdout.writeAll(json_txt);
            } else if (std.mem.eql(u8, arg1, "list")) {
                if (args_iter.next()) |arg2| {
                    if (std.mem.eql(u8, arg2, "--json")) {
                        const json_txt = try db.formatBranchesJson(gpa, ctx.wt_id);
                        defer gpa.free(json_txt);
                        try stdout.writeAll(json_txt);
                        try stdout.flush();
                        return;
                    }
                }
                const cur_br = db.worktrees.items[ctx.wt_id].branch_id;
                for (db.branches.items) |br| {
                    const mark = if (br.id == cur_br) "* " else "  ";
                    try stdout.print("{s}{s}\tc{d}\n", .{ mark, br.name, br.head_commit });
                }
            } else if (std.mem.eql(u8, arg1, "-m") or std.mem.eql(u8, arg1, "rename")) {
                const old_name = args_iter.next() orelse return error.MissingBranchName;
                const new_name = args_iter.next() orelse return error.MissingBranchName;
                try db.renameBranch(old_name, new_name);
                try db.saveToFile(io, ctx.db_path);
                try stdout.print("Renamed branch '{s}' -> '{s}'\n", .{ old_name, new_name });
            } else if (std.mem.eql(u8, arg1, "-d") or std.mem.eql(u8, arg1, "delete")) {
                const name = args_iter.next() orelse return error.MissingBranchName;
                try db.deleteBranch(name);
                try db.saveToFile(io, ctx.db_path);
                try stdout.print("Deleted branch '{s}'\n", .{name});
            } else {
                const cur_head = db.branches.items[db.worktrees.items[ctx.wt_id].branch_id].head_commit;
                _ = try db.getOrCreateBranch(arg1, cur_head);
                try db.saveToFile(io, ctx.db_path);
                try stdout.print("Created branch '{s}' at c{d}\n", .{ arg1, cur_head });
            }
        } else {
            const cur_br = db.worktrees.items[ctx.wt_id].branch_id;
            for (db.branches.items) |br| {
                const mark = if (br.id == cur_br) "* " else "  ";
                try stdout.print("{s}{s}\tc{d}\n", .{ mark, br.name, br.head_commit });
            }
        }
    } else if (std.mem.eql(u8, subcmd, "show")) {
        var spec: []const u8 = "HEAD";
        var has_spec = false;
        var path_filter: ?[]const u8 = null;
        var after_dashdash = false;
        var color_opt: ?bool = null;
        while (args_iter.next()) |arg| {
            if (after_dashdash) {
                path_filter = arg;
            } else if (std.mem.eql(u8, arg, "--")) {
                after_dashdash = true;
            } else if (parseColorFlag(arg)) |cval| {
                color_opt = cval;
            } else if (!has_spec) {
                spec = arg;
                has_spec = true;
            } else {
                path_filter = arg;
            }
        }
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        const out = try db.showRevisionFiltered(gpa, ctx.wt_id, spec, path_filter);
        defer gpa.free(out);
        if (std.mem.indexOfScalar(u8, spec, ':') == null and resolveUseColor(&db, color_opt)) {
            try writeColorizedUnifiedDiff(out, stdout);
        } else {
            try stdout.writeAll(out);
        }
    } else if (std.mem.eql(u8, subcmd, "config")) {
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();

        const first_opt = args_iter.next();
        if (first_opt == null or std.mem.eql(u8, first_opt.?, "list") or std.mem.eql(u8, first_opt.?, "-l") or std.mem.eql(u8, first_opt.?, "--list")) {
            for (db.configs.items) |cfg| {
                try stdout.print("{s}={s}\n", .{ cfg.name, cfg.path });
            }
        } else if (std.mem.eql(u8, first_opt.?, "get")) {
            const key = args_iter.next() orelse return error.MissingConfigKey;
            const val = db.getConfig(key) orelse return error.ConfigKeyNotFound;
            try stdout.print("{s}\n", .{val});
        } else if (std.mem.eql(u8, first_opt.?, "set")) {
            const key = args_iter.next() orelse return error.MissingConfigKey;
            const val = args_iter.next() orelse return error.MissingConfigValue;
            try db.setConfig(key, val);
            try db.saveToFile(io, ctx.db_path);
            try stdout.print("Configured {s}={s}\n", .{ key, val });
        } else if (std.mem.eql(u8, first_opt.?, "--unset") or std.mem.eql(u8, first_opt.?, "unset")) {
            const key = args_iter.next() orelse return error.MissingConfigKey;
            if (db.unsetConfig(key)) {
                try db.saveToFile(io, ctx.db_path);
                try stdout.print("Unset {s}\n", .{key});
            } else {
                return error.ConfigKeyNotFound;
            }
        } else {
            const key = first_opt.?;
            if (args_iter.next()) |val| {
                try db.setConfig(key, val);
                try db.saveToFile(io, ctx.db_path);
                try stdout.print("Configured {s}={s}\n", .{ key, val });
            } else {
                const val = db.getConfig(key) orelse return error.ConfigKeyNotFound;
                try stdout.print("{s}\n", .{val});
            }
        }
    } else if (std.mem.eql(u8, subcmd, "mv")) {
        const src_path = args_iter.next() orelse return error.MissingFilePath;
        const dst_path = args_iter.next() orelse return error.MissingFilePath;
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.moveFile(ctx.wt_id, src_path, dst_path);
        try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.saveToFile(io, ctx.db_path);
        try stdout.print("Moved '{s}' -> '{s}'\n", .{ src_path, dst_path });
    } else if (std.mem.eql(u8, subcmd, "rm")) {
        const path = args_iter.next() orelse return error.MissingFilePath;
        var ctx = try materializer.resolveWorkspaceContext(gpa, io, workspace_dir);
        defer ctx.deinit(gpa);
        var db = try repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path);
        defer db.deinit();
        _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.deleteFile(ctx.wt_id, path);
        try materializer.materializeWorktreeToDir(gpa, io, &db, ctx.wt_id, ctx.worktree_dir);
        try db.saveToFile(io, ctx.db_path);
        try stdout.print("Removed '{s}'\n", .{path});
    } else {
        try printRootOverview(gpa, io, workspace_dir, subcmd, stdout);
    }

    try stdout.flush();
}

fn resolveRemoteDbPath(gpa: Allocator, io: Io, raw_path: []const u8) ![]u8 {
    const cand = try std.fmt.allocPrint(gpa, "{s}/.vcs/db.vcs", .{raw_path});
    if (Io.Dir.cwd().statFile(io, cand, .{})) |_| {
        return cand;
    } else |_| {
        gpa.free(cand);
        return gpa.dupe(u8, raw_path);
    }
}

const TreeDiffCounts = struct {
    added: usize = 0,
    modified: usize = 0,
    deleted: usize = 0,
    conflicted: usize = 0,
    unchanged: usize = 0,

    pub fn totalChanged(self: TreeDiffCounts) usize {
        return self.added + self.modified + self.deleted + self.conflicted;
    }
};

fn computeTreeDiffCounts(
    head_tree: repo_db.TreeManifest,
    work_tree: repo_db.TreeManifest,
) TreeDiffCounts {
    var counts: TreeDiffCounts = .{};
    const head_items = head_tree.entries.items;
    const work_items = work_tree.entries.items;

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
                counts.deleted += 1;
                ih += 1;
            },
            .gt => {
                if (work_items[iw].sum.isConflicted()) {
                    counts.conflicted += 1;
                } else {
                    counts.added += 1;
                }
                iw += 1;
            },
            .eq => {
                const he = head_items[ih];
                const we = work_items[iw];
                if (we.sum.isConflicted()) {
                    counts.conflicted += 1;
                } else if (he.mode != we.mode or !he.sum.eql(we.sum)) {
                    counts.modified += 1;
                } else {
                    counts.unchanged += 1;
                }
                ih += 1;
                iw += 1;
            },
        }
    }
    return counts;
}

fn formatModeSuffix(mode: repo_db.FileMode) []const u8 {
    return switch (mode) {
        .regular => "",
        .executable => " (executable)",
        .symlink => " (symlink)",
    };
}

fn printStatus(
    db: *const repo_db.RepoDb,
    active_wt_id: repo_db.WorktreeId,
    stats: materializer.SyncStats,
    verbose_mode: bool,
    use_color: bool,
    writer: *Io.Writer,
) !void {
    const wt = db.worktrees.items[active_wt_id];
    const br = db.branches.items[wt.branch_id];
    const head_commit = db.commits.items[br.head_commit];
    const head_tree = db.trees.items[head_commit.root_tree_id];
    const work_tree = db.trees.items[wt.working_tree_id];

    const c_reset = if (use_color) "\x1b[0m" else "";
    const c_bold_cyan = if (use_color) "\x1b[1;36m" else "";
    const c_bold_yellow = if (use_color) "\x1b[1;33m" else "";
    const c_green = if (use_color) "\x1b[32m" else "";
    const c_yellow = if (use_color) "\x1b[33m" else "";
    const c_red = if (use_color) "\x1b[31m" else "";
    const c_bold_red = if (use_color) "\x1b[1;31m" else "";

    // 1. Active Branch, Worktree & HEAD Header
    try writer.print("On branch {s}{s}{s} (worktree '{s}' at {s})\n", .{
        c_bold_cyan,
        br.name,
        c_reset,
        wt.name,
        wt.fs_path,
    });
    try writer.print("HEAD: {s}c{d}{s} ({s}) \"{s}\"", .{
        c_bold_yellow,
        head_commit.id,
        c_reset,
        head_commit.author,
        head_commit.message,
    });
    var has_tag = false;
    for (db.tags.items) |t| {
        if (t.target_commit == head_commit.id) {
            if (!has_tag) {
                try writer.writeAll(" [tags: ");
                has_tag = true;
            } else {
                try writer.writeAll(", ");
            }
            try writer.writeAll(t.name);
        }
    }
    if (has_tag) try writer.writeAll("]");
    try writer.writeByte('\n');

    if (db.remotes.items.len > 0) {
        const r0 = db.remotes.items[0];
        try writer.print("Remote: {s} -> {s}\n", .{ r0.name, r0.path });
    }

    const counts = computeTreeDiffCounts(head_tree, work_tree);

    // 2. Unresolved Algebraic Conflicts (`B + C - A`)
    if (counts.conflicted > 0) {
        try writer.print("\n{s}Unresolved Algebraic Conflicts ({d} file(s) in B + C - A state):{s}\n", .{ c_bold_red, counts.conflicted, c_reset });
        try writer.writeAll("  (use \"zig_vcs resolve <path> <--ours|--theirs|--base>\" or edit markers on disk and \"zig_vcs commit\")\n");
        for (work_tree.entries.items) |we| {
            if (we.sum.isConflicted()) {
                try writer.print("    {s}conflicted: {s}{s} ({d} algebraic terms)\n", .{
                    c_bold_red,
                    we.path,
                    c_reset,
                    we.sum.terms.items.len,
                });
            }
        }
    }

    // 3. Added / Modified / Deleted Working Tree Changes vs HEAD
    const non_conflict_changes = counts.added + counts.modified + counts.deleted;
    if (non_conflict_changes > 0) {
        try writer.print("\nUncommitted Changes ({d} file(s) changed — auto-tracked, no staging area needed):\n", .{non_conflict_changes});
        try writer.writeAll("  (use \"zig_vcs commit \\\"<msg>\\\" [paths...]\" to commit, \"zig_vcs diff\" to inspect, or \"zig_vcs restore <path>\" to discard)\n");

        const head_items = head_tree.entries.items;
        const work_items = work_tree.entries.items;
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
                    try writer.print("    {s}deleted:    {s}{s}\n", .{ c_red, head_items[ih].path, c_reset });
                    ih += 1;
                },
                .gt => {
                    const we = work_items[iw];
                    if (!we.sum.isConflicted()) {
                        try writer.print("    {s}added:      {s}{s}{s}\n", .{ c_green, we.path, formatModeSuffix(we.mode), c_reset });
                    }
                    iw += 1;
                },
                .eq => {
                    const he = head_items[ih];
                    const we = work_items[iw];
                    if (!we.sum.isConflicted() and (he.mode != we.mode or !he.sum.eql(we.sum))) {
                        if (he.mode != we.mode) {
                            try writer.print("    {s}modified:   {s}{s}{s}\n", .{ c_yellow, we.path, formatModeSuffix(we.mode), c_reset });
                        } else {
                            try writer.print("    {s}modified:   {s}{s}\n", .{ c_yellow, we.path, c_reset });
                        }
                    }
                    ih += 1;
                    iw += 1;
                },
            }
        }
    }

    if (counts.totalChanged() == 0) {
        try writer.print("\n{s}Working tree clean{s} ({d} tracked file(s) match HEAD c{d}).\n", .{
            c_green,
            c_reset,
            work_tree.entries.items.len,
            head_commit.id,
        });
    } else {
        try writer.print(
            "\nSummary: {d} changed ({d} added, {d} modified, {d} deleted, {d} conflicted), {d} unchanged tracked file(s).\n",
            .{
                counts.totalChanged(),
                counts.added,
                counts.modified,
                counts.deleted,
                counts.conflicted,
                counts.unchanged,
            },
        );
    }

    // 4. Shelved Branch Drafts (Pillar 1)
    if (db.drafts.items.len > 0) {
        try writer.writeAll("\nShelved Branch Drafts (auto-saved on branch switch / worktree close):\n");
        for (db.drafts.items) |d| {
            const d_br = db.branches.items[d.branch_id];
            const d_head_tree = db.trees.items[db.commits.items[d_br.head_commit].root_tree_id];
            const d_work_tree = db.trees.items[d.tree_id];
            const d_counts = computeTreeDiffCounts(d_head_tree, d_work_tree);
            try writer.print(
                "    branch '{s}' (wt{d}): {d} uncommitted file change(s) shelved (base c{d})\n",
                .{ d_br.name, d.worktree_id, d_counts.totalChanged(), d_br.head_commit },
            );
        }
        try writer.writeAll("  (use \"zig_vcs switch <branch>\" to resume, \"zig_vcs draft show <branch>\" to inspect, or \"zig_vcs draft apply <branch>\")\n");
    }

    // 5. Other Linked Worktrees
    if (db.worktrees.items.len > 1) {
        try writer.writeAll("\nLinked Worktrees:\n");
        for (db.worktrees.items) |other_wt| {
            const obr = db.branches.items[other_wt.branch_id];
            const active_marker = if (other_wt.id == active_wt_id) "*" else " ";
            const state_str = if (!other_wt.is_open) "closed" else if (other_wt.is_dirty) "dirty" else "clean";
            try writer.print("  {s} wt{d} ({s}): branch '{s}' @ c{d} [{s}] -> {s}\n", .{
                active_marker,
                other_wt.id,
                other_wt.name,
                obr.name,
                obr.head_commit,
                state_str,
                other_wt.fs_path,
            });
        }
    }

    // 6. Recent Oplog Undo Hint
    if (db.oplog.items.len > 0) {
        const last_idx = db.oplog.items.len - 1;
        const last_op = db.oplog.items[last_idx];
        try writer.print("\nLast operation: [{d}] {s} (run \"zig_vcs undo\" to revert)\n", .{
            last_idx,
            last_op.command_desc,
        });
    }

    // 7. Optional Verbose Storage & Scan Diagnostics (`status -v` / `--verbose`)
    if (verbose_mode) {
        try writer.print(
            "\n=== Single-File Repository Diagnostics (commits={d}, trees={d}, blobs={d}, oplog={d}) ===\n",
            .{
                db.commits.items.len,
                db.trees.items.len,
                db.blobs.items.len,
                db.oplog.items.len,
            },
        );
        try writer.print(
            "  Scan Stats: stat_cache_hits={d}, files_hashed={d}, files_deleted={d}, conflicts_resolved={d}\n",
            .{
                stats.stat_cache_hits,
                stats.files_hashed,
                stats.files_deleted,
                stats.conflicts_resolved,
            },
        );
    }
}

fn printRootOverview(
    gpa: Allocator,
    io: Io,
    workspace_dir: []const u8,
    unknown_cmd: ?[]const u8,
    writer: *Io.Writer,
) !void {
    if (unknown_cmd) |uk| {
        if (!std.mem.eql(u8, uk, "help") and !std.mem.eql(u8, uk, "--help") and !std.mem.eql(u8, uk, "-h")) {
            if (suggestClosestCommand(uk)) |suggestion| {
                try writer.print("Unknown command '{s}'. Did you mean '{s}'?\n\n", .{ uk, suggestion });
            } else {
                try writer.print("Unknown command '{s}'.\n\n", .{uk});
            }
        }
    }

    try writer.writeAll(
        \\zig_vcs — Formally Verified, Single-File, Multi-Worktree Version Control System
        \\
    );

    // If invoked inside an initialized workspace, show a live 3-line summary banner
    if (materializer.resolveWorkspaceContext(gpa, io, workspace_dir)) |ctx_val| {
        var ctx = ctx_val;
        defer ctx.deinit(gpa);
        if (repo_db.RepoDb.loadFromFile(gpa, io, ctx.db_path)) |db_val| {
            var db = db_val;
            defer db.deinit();
            _ = materializer.syncWorktreeFromDisk(gpa, io, &db, ctx.wt_id, ctx.worktree_dir) catch {};
            const wt = db.worktrees.items[ctx.wt_id];
            const br = db.branches.items[wt.branch_id];
            const head_c = db.commits.items[br.head_commit];
            const counts = computeTreeDiffCounts(
                db.trees.items[head_c.root_tree_id],
                db.trees.items[wt.working_tree_id],
            );
            try writer.print(
                \\
                \\Active Workspace:
                \\  Repository : {s} ({d} commits, {d} branches, {d} worktrees)
                \\  Branch     : {s} @ c{d} "{s}" (worktree '{s}')
                \\
            , .{
                ctx.db_path,
                db.commits.items.len,
                db.branches.items.len,
                db.worktrees.items.len,
                br.name,
                head_c.id,
                head_c.message,
                wt.name,
            });
            if (counts.totalChanged() == 0) {
                try writer.print("  Status     : Clean ({d} tracked files, {d} shelved drafts)\n", .{
                    db.trees.items[wt.working_tree_id].entries.items.len,
                    db.drafts.items.len,
                });
            } else {
                try writer.print(
                    "  Status     : {d} uncommitted change(s) ({d} added, {d} modified, {d} deleted, {d} conflicted), {d} shelved draft(s)\n",
                    .{
                        counts.totalChanged(),
                        counts.added,
                        counts.modified,
                        counts.deleted,
                        counts.conflicted,
                        db.drafts.items.len,
                    },
                );
            }
        } else |_| {
            try writer.writeAll(
                \\
                \\Workspace: Not inside an initialized repository (run 'zig_vcs init' or 'zig_vcs clone <src> <dst>').
                \\
            );
        }
    } else |_| {
        try writer.writeAll(
            \\
            \\Workspace: Not inside an initialized repository (run 'zig_vcs init' or 'zig_vcs clone <src> <dst>').
            \\
        );
    }

    try writer.writeAll(
        \\
        \\Usage: zig_vcs <command> [args...]
        \\
        \\Everyday Commands:
        \\  Start & Sync:
        \\    init                             Initialize single-file repository (.vcs/db.vcs)
        \\    clone <src_repo> [dst_dir]       Clone .vcs or .git repository into <dst_dir>
        \\    pull [remote] [branch]           Fetch & algebraically merge remote branch
        \\    push [remote] [branch] [--force] Push branch commits to remote
        \\
        \\  Working Tree (Auto-Tracked — No 'git add' Staging Area):
        \\    status [-s|--short] [--json]     Show working tree changes vs HEAD, conflicts & drafts
        \\    diff [--stat] [rev|A..B] [path]  Show unified diff (@@ -l,c +l,c @@) or diffstat
        \\    commit ["<msg>"] [paths...]      Commit all (or selected) working tree changes to branch
        \\    restore <path> [rev]             Restore file or directory prefix from HEAD or <rev>
        \\
        \\  Branches & Merging:
        \\    switch <branch>                  Switch branch (dirty state is auto-shelved & restored)
        \\    branch [list|-m|-d|<name>]       List, create, rename (-m), or delete (-d) branches
        \\    merge <b1> [b2 ...]              Merge 1..N branches via B + C - A algebra + Pierce diff3
        \\
        \\  History & Instant Undo:
        \\    log [-n N] [--stat] [--oneline]  Inspect commit history DAG
        \\    undo                             Revert last operation in O(1) via single-DB oplog
        \\    config [list|get|set] [k] [v]    Get or set repository configuration (user.name, user.email, color.ui)
        \\
        \\Further Help:
        \\  zig_vcs help advanced              Show advanced history rewriting, worktrees, drafts & plumbing
        \\  zig_vcs help --all                 Show all everyday and advanced commands on one page
        \\  zig_vcs help <command>             Show detailed flags, examples & guarantees for a command
        \\
    );
}

fn printAdvancedOverview(writer: *Io.Writer, appended_to_root: bool) !void {
    if (!appended_to_root) {
        try writer.writeAll(
            \\zig_vcs — Advanced, Multi-Worktree, History Rewriting & Maintenance Commands
            \\
            \\Usage: zig_vcs <command> [args...]
            \\
        );
    } else {
        try writer.writeAll("Advanced & Plumbing Commands:\n");
    }

    try writer.writeAll(
        \\  1. Algebraic Conflict Resolution & History Rewriting (Pillar 2 — B + C - A):
        \\    resolve <path> <--ours|--theirs|--base|content> Collapse conflicted PathSum to clean basis term
        \\    rebase <branch> <onto>             Rebase branch or multi-commit chain onto target branch
        \\    amend [rev] ["<msg>"]              Amend commit & automatically cascade-rebase all descendants
        \\    squash [rev] ["<msg>"]             Squash commit into parent & cascade-rebase all descendants
        \\    cherry-pick <rev|A..B> ["<msg>"]   Algebraically forward-port a single commit or range (A..B)
        \\    backout <rev|A..B> ["<msg>"]       Algebraically revert a single commit or range (A..B)
        \\
        \\  2. Multi-Worktree Isolation, Shelved Drafts & File Operations (Pillar 1):
        \\    worktree <list|add|close|reopen>   Manage isolated worktrees sharing the single .vcs/db.vcs
        \\    draft [list|show|apply|drop] [br]  Inspect, algebraically apply (B+C-A), or drop shelved drafts
        \\    mv <src> <dst>                     Move/rename tracked file on disk and in working tree
        \\    rm <path>                          Remove tracked file from working tree and disk
        \\
        \\  3. Code Provenance, Search, Tags & Remotes:
        \\    show [rev[:path]]                  Show commit summary + unified diff, or exact file at <rev>:<path>
        \\    blame <path> [rev]                 Line-by-line commit provenance & conflict-aware blame
        \\    search <needle>                    Pickaxe search across all historical commits & blobs
        \\    bisect <good> <bad> <path> <str>   Zero-checkout O(log N) binary search for commit introducing <str>
        \\    tag [name] [rev] | -d <name>       List, create/update, or delete transactional tags
        \\    remote [list|-v|add|set-url|rm]    Manage named remote repositories (default: origin)
        \\    fetch [remote] [branch]            Fetch missing commits, trees & blobs from remote without merging
        \\
        \\  4. Transactional Oplog, Database Maintenance & Interoperability (Pillar 3):
        \\    redo                               Re-apply last undone operation from persistent redo stack
        \\    oplog [-n N] [--json] | restore N  Inspect operation log or jump directly to oplog[N]
        \\    fsck [--json]                      Verify BLAKE3 hashes, DAG acyclicity & Z[A_bot] sum=1 invariants
        \\    gc                                 Compact 4KB shadow-paged DB image & reclaim inactive pages
        \\    archive <out.tar> [rev] [--prefix] Export revision to deterministic POSIX ustar .tar archive
        \\    git-export [file] / git-import <f> Bi-directional git fast-export / fast-import stream bridge
        \\
        \\Tip: Run 'zig_vcs help <command>' or 'zig_vcs <command> --help' for detailed usage and examples.
        \\
    );
}

fn printCommandHelp(
    gpa: Allocator,
    io: Io,
    workspace_dir: []const u8,
    topic: []const u8,
    writer: *Io.Writer,
) !void {
    if (std.mem.eql(u8, topic, "status")) {
        try writer.writeAll(
            \\Usage: zig_vcs status [-s|--short] [--json] [-v|--verbose]
            \\
            \\Auto-scans the active worktree directory (using mtime/size stat_cache + .vcsignore/.gitignore)
            \\and displays uncommitted changes relative to HEAD, unresolved algebraic conflicts (B + C - A),
            \\and shelved per-branch drafts.
            \\
            \\Flags:
            \\  -s, --short     Compact 1-line-per-changed-file output (A/M/D/U)
            \\  --json          Machine-readable JSON output
            \\  -v, --verbose   Include internal single-DB object counts and stat_cache scan diagnostics
            \\
            \\Examples:
            \\  zig_vcs status
            \\  zig_vcs status -s
            \\  zig_vcs status --json
            \\
        );
    } else if (std.mem.eql(u8, topic, "init")) {
        try writer.writeAll(
            \\Usage: zig_vcs init
            \\
            \\Initializes a new single-file repository at .vcs/db.vcs on branch 'main' (worktree 'main-wt')
            \\and automatically scans existing files in the workspace.
            \\
        );
    } else if (std.mem.eql(u8, topic, "switch")) {
        try writer.writeAll(
            \\Usage: zig_vcs switch <branch>
            \\
            \\Switches the active worktree to <branch> (creating the branch at HEAD if it does not exist).
            \\Guarantee (INV-4): Any uncommitted changes on the current branch are automatically shelved
            \\into the single-DB drafts table and restored when switching back.
            \\
        );
    } else if (std.mem.eql(u8, topic, "branch")) {
        try writer.writeAll(
            \\Usage: zig_vcs branch [list | --json | <new_name> | -m <old> <new> | -d <name>]
            \\
            \\Lists, creates, renames (-m / rename), or deletes (-d / delete) branches in the single DB.
            \\
        );
    } else if (std.mem.eql(u8, topic, "commit")) {
        try writer.writeAll(
            \\Usage: zig_vcs commit ["<message>"] [path_prefix...]
            \\
            \\Auto-scans the active worktree and records a new commit on the current branch without requiring
            \\a separate 'git add' staging step. If path prefixes are provided, only matching paths are committed
            \\while remaining dirty files stay in the working tree.
            \\
        );
    } else if (std.mem.eql(u8, topic, "amend")) {
        try writer.writeAll(
            \\Usage: zig_vcs amend [rev] ["<new_message>"]
            \\
            \\Amends HEAD (or any historical commit <rev>) with current working tree changes and/or a new message,
            \\automatically cascade-rebasing all descendant commits and branches via B + C - A algebra.
            \\
        );
    } else if (std.mem.eql(u8, topic, "squash")) {
        try writer.writeAll(
            \\Usage: zig_vcs squash [rev] ["<new_message>"]
            \\
            \\Squashes HEAD (or commit <rev>) into its parent commit and automatically cascade-rebases
            \\all descendant commits and branches.
            \\
        );
    } else if (std.mem.eql(u8, topic, "merge")) {
        try writer.writeAll(
            \\Usage: zig_vcs merge <branch1> [branch2 ...]
            \\
            \\Merges one or more branches into the active worktree using B + C - A merge algebra in Z[A_bot]
            \\and Pierce (2007) unique-anchor sub-file diff3. Never halts mid-merge and never writes conflict
            \\markers into db.blobs (INV-5).
            \\
        );
    } else if (std.mem.eql(u8, topic, "resolve")) {
        try writer.writeAll(
            \\Usage: zig_vcs resolve <path> <--ours | --theirs | --base | "<custom_content>">
            \\
            \\Resolves an algebraic conflict on <path> by collapsing its PathSum to a single clean basis term.
            \\
        );
    } else if (std.mem.eql(u8, topic, "rebase")) {
        try writer.writeAll(
            \\Usage: zig_vcs rebase <branch> <onto_branch>
            \\
            \\Rebases the commit chain on <branch> onto <onto_branch> using B + C - A algebra, preserving
            \\individual step deltas and cancelling resolved conflicts automatically.
            \\
        );
    } else if (std.mem.eql(u8, topic, "cherry-pick")) {
        try writer.writeAll(
            \\Usage: zig_vcs cherry-pick <rev | A..B> ["<message>"]
            \\
            \\Algebraically forward-ports a single commit <rev> or a telescoping range <A..B> (HEAD + T_B - T_A)
            \\onto the active branch.
            \\
        );
    } else if (std.mem.eql(u8, topic, "backout")) {
        try writer.writeAll(
            \\Usage: zig_vcs backout <rev | A..B> ["<message>"]
            \\
            \\Algebraically reverts the changes introduced by commit <rev> or range <A..B> (HEAD + T_A - T_B).
            \\
        );
    } else if (std.mem.eql(u8, topic, "restore")) {
        try writer.writeAll(
            \\Usage: zig_vcs restore <path_prefix> [rev]
            \\
            \\Restores files matching <path_prefix> in the active working tree from HEAD (or from <rev>).
            \\
        );
    } else if (std.mem.eql(u8, topic, "show")) {
        try writer.writeAll(
            \\Usage: zig_vcs show [rev | rev:path]
            \\
            \\Displays commit metadata and unified diff for <rev> (default: HEAD), or outputs the exact
            \\blob content of <path> at <rev> when invoked as 'zig_vcs show <rev>:<path>'.
            \\
        );
    } else if (std.mem.eql(u8, topic, "mv")) {
        try writer.writeAll(
            \\Usage: zig_vcs mv <src_path> <dst_path>
            \\
            \\Moves/renames a tracked file in the working tree and on disk within a single oplog transaction.
            \\
        );
    } else if (std.mem.eql(u8, topic, "rm")) {
        try writer.writeAll(
            \\Usage: zig_vcs rm <path>
            \\
            \\Removes a tracked file from the working tree and unlinks it from disk (recoverable via 'undo').
            \\
        );
    } else if (std.mem.eql(u8, topic, "blame")) {
        try writer.writeAll(
            \\Usage: zig_vcs blame <path> [rev]
            \\
            \\Annotates each line of <path> at <rev> (default: HEAD) with the originating commit ID and author.
            \\
        );
    } else if (std.mem.eql(u8, topic, "tag")) {
        try writer.writeAll(
            \\Usage: zig_vcs tag [name [rev] | -d <name> | delete <name>]
            \\
            \\Lists all tags, creates/updates a tag pointing to <rev> (default: HEAD), or deletes a tag (-d).
            \\
        );
    } else if (std.mem.eql(u8, topic, "bisect")) {
        try writer.writeAll(
            \\Usage: zig_vcs bisect <good_rev> <bad_rev> <path> <needle>
            \\
            \\Performs a zero-checkout O(log N) binary search across the commit DAG between <good_rev> and
            \\<bad_rev> to find the first commit where <path> contains <needle>.
            \\
        );
    } else if (std.mem.eql(u8, topic, "search")) {
        try writer.writeAll(
            \\Usage: zig_vcs search <needle>
            \\
            \\Scans all commits in the single-file database to report commits and paths matching <needle>.
            \\
        );
    } else if (std.mem.eql(u8, topic, "log")) {
        try writer.writeAll(
            \\Usage: zig_vcs log [-n <limit>] [--stat] [--oneline] [--json] [rev|A..B] [-- <path_prefix>]
            \\
            \\Displays the commit history DAG with optional revision range filtering (A..B), path prefix filtering,
            \\diffstat summaries (--stat), compact 1-line output (--oneline), or JSON (--json).
            \\
        );
    } else if (std.mem.eql(u8, topic, "diff")) {
        try writer.writeAll(
            \\Usage: zig_vcs diff [--stat] [rev|A..B] [path_prefix]
            \\
            \\Displays unified diffs (@@ -l,c +l,c @@) or diffstat (--stat) between HEAD and the working tree,
            \\between <rev> and the working tree, or across a commit range <A..B>.
            \\
        );
    } else if (std.mem.eql(u8, topic, "draft")) {
        try writer.writeAll(
            \\Usage: zig_vcs draft [list|show|apply|drop] [--json] [branch]
            \\
            \\Inspects, algebraically applies (B + C - A), or drops uncommitted drafts shelved during
            \\branch switches or worktree closures.
            \\
        );
    } else if (std.mem.eql(u8, topic, "worktree")) {
        try writer.writeAll(
            \\Usage: zig_vcs worktree [list | --json | add <name> <path> [branch] | close <name> | reopen <name>]
            \\
            \\Manages multiple isolated worktrees on disk backed by the same single-file .vcs/db.vcs database.
            \\
        );
    } else if (std.mem.eql(u8, topic, "undo") or std.mem.eql(u8, topic, "redo")) {
        try writer.writeAll(
            \\Usage: zig_vcs undo | zig_vcs redo
            \\
            \\Atomically reverts ('undo') or re-applies ('redo') the last repository state transition in O(1)
            \\using the persistent single-DB oplog and redo stack (INV-6).
            \\
        );
    } else if (std.mem.eql(u8, topic, "oplog")) {
        try writer.writeAll(
            \\Usage: zig_vcs oplog [-n <limit>] [--json] | zig_vcs oplog restore <index>
            \\
            \\Lists transactional operation log snapshots or restores repository state directly to oplog[<index>].
            \\
        );
    } else if (std.mem.eql(u8, topic, "fsck")) {
        try writer.writeAll(
            \\Usage: zig_vcs fsck [--json]
            \\
            \\Verifies BLAKE3 cryptographic hashes on all blobs/superblocks, commit DAG acyclicity (INV-2),
            \\and Z[A_bot] free abelian group conservation (INV-5).
            \\
        );
    } else if (std.mem.eql(u8, topic, "gc")) {
        try writer.writeAll(
            \\Usage: zig_vcs gc
            \\
            \\Compacts the 4KB shadow-paged database file (.vcs/db.vcs) and reclaims inactive historical pages.
            \\
        );
    } else if (std.mem.eql(u8, topic, "clone")) {
        try writer.writeAll(
            \\Usage: zig_vcs clone <src_repo> [dst_dir]
            \\
            \\Clones a .vcs repository or native .git repository into <dst_dir> and configures 'origin'.
            \\
        );
    } else if (std.mem.eql(u8, topic, "remote")) {
        try writer.writeAll(
            \\Usage: zig_vcs remote [list | -v | add <name> <url> | set-url <name> <url> | rm <name>]
            \\
            \\Lists, adds, updates, or removes named remote repositories.
            \\
        );
    } else if (std.mem.eql(u8, topic, "fetch") or std.mem.eql(u8, topic, "pull") or std.mem.eql(u8, topic, "push")) {
        try writer.writeAll(
            \\Usage:
            \\  zig_vcs fetch [remote] [branch]
            \\  zig_vcs pull  [remote] [branch]
            \\  zig_vcs push  [remote] [branch] [--force|-f]
            \\
            \\Synchronizes commits, trees, and blobs with a .vcs or native .git remote repository.
            \\
        );
    } else if (std.mem.eql(u8, topic, "archive")) {
        try writer.writeAll(
            \\Usage: zig_vcs archive <output.tar> [rev] [--prefix <dir> | --prefix=<dir>]
            \\
            \\Exports any revision (default: HEAD) directly from .vcs/db.vcs into a deterministic POSIX ustar
            \\.tar archive without touching the working tree.
            \\
        );
    } else if (std.mem.eql(u8, topic, "git-export") or std.mem.eql(u8, topic, "git-import")) {
        try writer.writeAll(
            \\Usage:
            \\  zig_vcs git-export [output_stream_file]
            \\  zig_vcs git-import <input_stream_file>
            \\
            \\Exports or imports repository history using the standard Git fast-export / fast-import stream format.
            \\
        );
    } else if (std.mem.eql(u8, topic, "config")) {
        try writer.writeAll(
            \\Usage: zig_vcs config [list | -l | get <key> | set <key> <value> | --unset <key> | <key> [value]]
            \\
            \\Reads or updates repository-scoped configuration stored transactionally inside .vcs/db.vcs.
            \\Common keys:
            \\  user.name     Default author name for commits, merges, cherry-picks, and backouts
            \\  user.email    Default author email (formatted as "Name <email>" when combined with user.name)
            \\  color.ui      Default ANSI color mode ("always", "true", "never", "false", or "auto")
            \\
        );
    } else {
        try printRootOverview(gpa, io, workspace_dir, topic, writer);
    }
}

pub fn parseColorFlag(arg: []const u8) ?bool {
    if (std.mem.eql(u8, arg, "--color") or std.mem.eql(u8, arg, "--color=always") or std.mem.eql(u8, arg, "--color=true")) {
        return true;
    }
    if (std.mem.eql(u8, arg, "--no-color") or std.mem.eql(u8, arg, "--color=never") or std.mem.eql(u8, arg, "--color=false")) {
        return false;
    }
    return null;
}

pub fn resolveUseColor(db: *const repo_db.RepoDb, cli_flag: ?bool) bool {
    if (cli_flag) |val| return val;
    if (db.getConfig("color.ui")) |cfg_val| {
        if (std.mem.eql(u8, cfg_val, "always") or std.mem.eql(u8, cfg_val, "true") or std.mem.eql(u8, cfg_val, "1")) {
            return true;
        }
        if (std.mem.eql(u8, cfg_val, "never") or std.mem.eql(u8, cfg_val, "false") or std.mem.eql(u8, cfg_val, "0")) {
            return false;
        }
    }
    return false;
}

fn writeColorizedUnifiedDiff(diff_text: []const u8, writer: *Io.Writer) !void {
    var line_iter = std.mem.splitScalar(u8, diff_text, '\n');
    var first = true;
    while (line_iter.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "+++ ") or std.mem.startsWith(u8, line, "commit ")) {
            try writer.print("\x1b[1m{s}\x1b[0m", .{line});
        } else if (std.mem.startsWith(u8, line, "@@")) {
            try writer.print("\x1b[36m{s}\x1b[0m", .{line});
        } else if (line[0] == '+') {
            try writer.print("\x1b[32m{s}\x1b[0m", .{line});
        } else if (line[0] == '-') {
            try writer.print("\x1b[31m{s}\x1b[0m", .{line});
        } else {
            try writer.writeAll(line);
        }
    }
}

fn writeColorizedCommitLog(log_text: []const u8, writer: *Io.Writer) !void {
    var line_iter = std.mem.splitScalar(u8, log_text, '\n');
    var first = true;
    while (line_iter.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "commit ")) {
            try writer.print("\x1b[1;33m{s}\x1b[0m", .{line});
        } else if (line[0] == 'c' and line.len > 1 and std.ascii.isDigit(line[1])) {
            if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
                try writer.print("\x1b[1;33m{s}\x1b[0m{s}", .{ line[0..sp], line[sp..] });
            } else {
                try writer.writeAll(line);
            }
        } else {
            try writer.writeAll(line);
        }
    }
}

pub fn levenshteinDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > 32 or b.len > 32) return 99;

    var prev_row: [33]usize = undefined;
    var curr_row: [33]usize = undefined;
    for (0..b.len + 1) |j| {
        prev_row[j] = j;
    }
    for (a, 0..) |ca, i| {
        curr_row[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            const del = prev_row[j + 1] + 1;
            const ins = curr_row[j] + 1;
            const sub = prev_row[j] + cost;
            curr_row[j + 1] = @min(del, @min(ins, sub));
        }
        for (0..b.len + 1) |j| {
            prev_row[j] = curr_row[j];
        }
    }
    return prev_row[b.len];
}

pub fn suggestClosestCommand(unknown: []const u8) ?[]const u8 {
    const known_commands = [_][]const u8{
        "init",
        "clone",
        "remote",
        "fetch",
        "pull",
        "push",
        "status",
        "switch",
        "branch",
        "commit",
        "amend",
        "squash",
        "merge",
        "resolve",
        "rebase",
        "cherry-pick",
        "backout",
        "restore",
        "show",
        "mv",
        "rm",
        "blame",
        "tag",
        "bisect",
        "search",
        "log",
        "diff",
        "draft",
        "fsck",
        "gc",
        "worktree",
        "undo",
        "redo",
        "oplog",
        "archive",
        "config",
        "git-export",
        "git-import",
        "help",
        "version",
    };

    var best_cmd: ?[]const u8 = null;
    var best_dist: usize = 3; // Only suggest when edit distance <= 2
    for (known_commands) |cand| {
        const d = levenshteinDistance(unknown, cand);
        if (d < best_dist) {
            best_dist = d;
            best_cmd = cand;
        }
    }
    return best_cmd;
}

/// Formats any CLI error into a clean, user-friendly diagnostic message with an actionable recovery hint.
pub fn formatCliErrorAlloc(gpa: Allocator, err: anyerror, args: []const []const u8) ![]u8 {
    const raw_cmd = if (args.len > 0) args[0] else "";
    const cmd = resolveCommandAlias(raw_cmd);
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    switch (err) {
        error.FileNotFound => {
            try w.print(
                "error: Not inside an initialized zig_vcs repository (or target file was not found).\n" ++
                    "  hint: Run 'zig_vcs init' to initialize a repository here, or 'zig_vcs clone <src> <dst>'.\n",
                .{},
            );
        },
        error.MissingBranchName => {
            try w.print(
                "error: Missing required <branch> name for 'zig_vcs {s}'.\n" ++
                    "  hint: Run 'zig_vcs branch' to list existing branches or see 'zig_vcs help {s}'.\n",
                .{ cmd, cmd },
            );
        },
        error.MissingOntoBranch => {
            try w.print(
                "error: Missing <onto_branch> target for 'zig_vcs rebase'.\n" ++
                    "  hint: Usage: zig_vcs rebase <branch> <onto_branch>\n",
                .{},
            );
        },
        error.MissingSourceBranch => {
            try w.print(
                "error: Missing source branch name(s) for 'zig_vcs merge'.\n" ++
                    "  hint: Usage: zig_vcs merge <branch1> [branch2 ...]\n",
                .{},
            );
        },
        error.MissingCommitMessage => {
            try w.print(
                "error: Flag '-m' / '--message' requires a commit message argument.\n" ++
                    "  hint: Usage: zig_vcs {s} -m \"<message>\"\n",
                .{cmd},
            );
        },
        error.MissingAuthor => {
            try w.print(
                "error: Flag '--author' requires an author argument.\n" ++
                    "  hint: Usage: zig_vcs {s} --author \"Name <email>\" -m \"<message>\"\n",
                .{cmd},
            );
        },
        error.MissingCommitId => {
            try w.print(
                "error: Missing revision or commit range for 'zig_vcs {s}'.\n" ++
                    "  hint: Usage: zig_vcs {s} <rev|A..B> [-m \"<message>\"]\n",
                .{ cmd, cmd },
            );
        },
        error.MissingFilePath => {
            try w.print(
                "error: Missing required <path> argument for 'zig_vcs {s}'.\n" ++
                    "  hint: See 'zig_vcs help {s}' for usage examples.\n",
                .{ cmd, cmd },
            );
        },
        error.MissingContent => {
            try w.print(
                "error: Missing resolution strategy or replacement content for 'zig_vcs resolve'.\n" ++
                    "  hint: Usage: zig_vcs resolve <path> <--ours | --theirs | --base | \"<content>\">\n",
                .{},
            );
        },
        error.MissingSearchNeedle => {
            try w.print(
                "error: Missing search string <needle> for 'zig_vcs {s}'.\n" ++
                    "  hint: Usage: zig_vcs {s} \"<needle>\"\n",
                .{ cmd, cmd },
            );
        },
        error.MissingConfigKey => {
            try w.print(
                "error: Missing configuration key for 'zig_vcs config'.\n" ++
                    "  hint: Usage: zig_vcs config [list | get <key> | set <key> <value> | --unset <key>]\n",
                .{},
            );
        },
        error.MissingConfigValue => {
            try w.print(
                "error: Missing configuration value for 'zig_vcs config set'.\n" ++
                    "  hint: Usage: zig_vcs config set <key> <value>\n",
                .{},
            );
        },
        error.ConfigKeyNotFound => {
            try w.print(
                "error: Configuration key not found in repository.\n" ++
                    "  hint: Run 'zig_vcs config list' to inspect configured keys.\n",
                .{},
            );
        },
        error.UnresolvedConflictsInTree => {
            try w.print(
                "error: Cannot commit while algebraic conflicts (B + C - A) remain unresolved in the working tree.\n" ++
                    "  hint: Run 'zig_vcs status' to view conflicted files, then resolve via:\n" ++
                    "        zig_vcs resolve <path> <--ours|--theirs|--base> (or edit conflict markers on disk).\n",
                .{},
            );
        },
        error.RevisionNotFound, error.InvalidCommitId => {
            try w.print(
                "error: Revision or commit specifier was not found in the repository.\n" ++
                    "  hint: Use 'zig_vcs log --oneline', 'zig_vcs branch', or 'zig_vcs tag' (or '@', '@-', 'HEAD~1', 'c<N>').\n",
                .{},
            );
        },
        error.BranchNotFound, error.SourceBranchNotFound, error.OntoBranchNotFound => {
            try w.print(
                "error: Specified branch does not exist in the repository.\n" ++
                    "  hint: Run 'zig_vcs branch' to list available branches.\n",
                .{},
            );
        },
        error.BranchAlreadyExists => {
            try w.print(
                "error: Target branch name already exists.\n" ++
                    "  hint: Choose a distinct branch name or switch to it with 'zig_vcs switch <branch>'.\n",
                .{},
            );
        },
        error.CannotDeleteCheckedOutBranch => {
            try w.print(
                "error: Cannot delete a branch that is currently checked out in an open worktree.\n" ++
                    "  hint: Switch to another branch first ('zig_vcs switch main') before deleting.\n",
                .{},
            );
        },
        error.NonFastForwardPushRejected => {
            try w.print(
                "error: Push rejected because remote branch is not a fast-forward ancestor of local branch.\n" ++
                    "  hint: Run 'zig_vcs pull' to algebraically merge remote changes first, or pass '--force'.\n",
                .{},
            );
        },
        else => {
            try w.print(
                "error: Command 'zig_vcs {s}' failed with '{s}'.\n" ++
                    "  hint: Run 'zig_vcs help {s}' for usage details.\n",
                .{ cmd, @errorName(err), cmd },
            );
        },
    }
    return aw.toOwnedSlice();
}

pub fn printCliError(gpa: Allocator, err: anyerror, args: []const []const u8, stderr: *Io.Writer) void {
    if (formatCliErrorAlloc(gpa, err, args)) |msg| {
        defer gpa.free(msg);
        stderr.writeAll(msg) catch {};
        stderr.flush() catch {};
    } else |_| {
        stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
    }
}
