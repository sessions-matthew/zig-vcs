//! Layer 3: Filesystem Materializer, Automatic Working-Directory Scanner, Stat Cache & Marker Round-Trip.
//!
//! Bridges the pure algebraic `RepoDb` (`FormalTreeSum` `B + C - A`) with a checkout directory:
//! 1. **Automatic Working-Directory Scanner (`syncWorktreeFromDisk`)**:
//!    - Recursively walks the worktree directory respecting `.vcsignore` (`IgnoreMatcher`).
//!    - Uses `RepoDb.stat_cache` (`mtime_ns`, `size_bytes`) to skip reading/hashing unchanged files.
//!    - Automatically detects newly created files, modified files, deleted files (`rm`), and
//!      user-resolved conflict files (when `<<<<<<<` markers are removed).
//! 2. **Lazy Checkout Rendering & Stale Tracked File Cleanup (`materializeWorktreeToDir`)**:
//!    - Materializes clean files directly and synthesizes diff3 conflict markers on the fly for
//!      conflicted `PathSum` entries while keeping `RepoDb.blobs` 100% marker-free.
//!    - Unlinks tracked files that were present in the previous working tree (`stat_cache`) but
//!      are absent in the target tree (e.g., when switching branches or undoing).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const repo_db = @import("../storage/repo_db.zig");
const diff3 = @import("../algebra/diff3_anchors.zig");
const tree_sum = @import("../algebra/tree_sum.zig");
const ignore_mod = @import("ignore.zig");

pub const RepoDb = repo_db.RepoDb;
pub const WorktreeId = repo_db.WorktreeId;
pub const PathSum = tree_sum.PathSum;
pub const TreeManifest = tree_sum.TreeManifest;
pub const IgnoreMatcher = ignore_mod.IgnoreMatcher;

pub const SyncStats = struct {
    stat_cache_hits: usize = 0,
    files_hashed: usize = 0,
    files_deleted: usize = 0,
    conflicts_resolved: usize = 0,
    tree_changed: bool = false,
};

pub const WorkspaceContext = struct {
    db_path: []u8,
    wt_id: WorktreeId,
    worktree_dir: []u8,

    pub fn deinit(self: *WorkspaceContext, allocator: Allocator) void {
        allocator.free(self.db_path);
        allocator.free(self.worktree_dir);
    }
};

/// Resolve the active `(db_path, wt_id, worktree_dir)` from `dir_path` (or any nested subdirectory):
/// - Walks upward from `dir_path` (up to 8 parent levels) looking for `.vcs-link` or `.vcs/db.vcs`.
/// - If `<cand_dir>/.vcs-link` exists, parses `db_path=<...>` and `wt_id=<...>` for a linked worktree.
/// - If `<cand_dir>/.vcs/db.vcs` exists, resolves primary worktree `wt_id = 0` at `<cand_dir>`.
pub fn resolveWorkspaceContext(
    allocator: Allocator,
    io: Io,
    dir_path: []const u8,
) !WorkspaceContext {
    var cand_dir = try allocator.dupe(u8, dir_path);
    defer allocator.free(cand_dir);

    for (0..8) |_| {
        // 1. Check `<cand_dir>/.vcs-link`
        const link_path = if (std.mem.eql(u8, cand_dir, "."))
            try allocator.dupe(u8, ".vcs-link")
        else
            try std.fmt.allocPrint(allocator, "{s}/.vcs-link", .{cand_dir});
        defer allocator.free(link_path);

        if (Io.Dir.cwd().readFileAlloc(io, link_path, allocator, .limited(64 * 1024))) |link_bytes| {
            defer allocator.free(link_bytes);
            var parsed_db: ?[]const u8 = null;
            var parsed_wt: WorktreeId = 0;

            var it = std.mem.splitScalar(u8, link_bytes, '\n');
            while (it.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (std.mem.startsWith(u8, line, "db_path=")) {
                    parsed_db = line["db_path=".len..];
                } else if (std.mem.startsWith(u8, line, "wt_id=")) {
                    parsed_wt = std.fmt.parseInt(WorktreeId, line["wt_id=".len..], 10) catch 0;
                }
            }
            if (parsed_db) |db_p| {
                const dup_db = try allocator.dupe(u8, db_p);
                errdefer allocator.free(dup_db);
                const dup_wt = try allocator.dupe(u8, cand_dir);
                return .{
                    .db_path = dup_db,
                    .wt_id = parsed_wt,
                    .worktree_dir = dup_wt,
                };
            }
        } else |_| {}

        // 2. Check `<cand_dir>/.vcs/db.vcs`
        const cand_db = if (std.mem.eql(u8, cand_dir, "."))
            try allocator.dupe(u8, ".vcs/db.vcs")
        else
            try std.fmt.allocPrint(allocator, "{s}/.vcs/db.vcs", .{cand_dir});
        defer allocator.free(cand_db);

        if (Io.Dir.cwd().statFile(io, cand_db, .{})) |_| {
            const dup_db = try allocator.dupe(u8, cand_db);
            errdefer allocator.free(dup_db);
            const dup_wt = try allocator.dupe(u8, cand_dir);
            return .{
                .db_path = dup_db,
                .wt_id = 0,
                .worktree_dir = dup_wt,
            };
        } else |_| {}

        // 3. Step up to parent directory
        if (std.fs.path.dirname(cand_dir)) |parent| {
            if (!std.mem.eql(u8, parent, cand_dir) and parent.len > 0) {
                const next_cand = try allocator.dupe(u8, parent);
                allocator.free(cand_dir);
                cand_dir = next_cand;
                continue;
            }
        }
        const next_cand = if (std.mem.eql(u8, cand_dir, "."))
            try allocator.dupe(u8, "..")
        else
            try std.fmt.allocPrint(allocator, "{s}/..", .{cand_dir});
        allocator.free(cand_dir);
        cand_dir = next_cand;
    }

    const default_db = if (std.mem.eql(u8, dir_path, "."))
        try allocator.dupe(u8, ".vcs/db.vcs")
    else
        try std.fmt.allocPrint(allocator, "{s}/.vcs/db.vcs", .{dir_path});
    errdefer allocator.free(default_db);

    const dup_wt = try allocator.dupe(u8, dir_path);
    return .{
        .db_path = default_db,
        .wt_id = 0,
        .worktree_dir = dup_wt,
    };
}

/// Create a new linked worktree directory at `fs_path`, write its `.vcs-link` pointer file
/// referencing `db_path` and `wt_id`, and materialize its checked-out branch onto disk!
pub fn createLinkedWorktreeOnDisk(
    allocator: Allocator,
    io: Io,
    db: *RepoDb,
    db_path: []const u8,
    name: []const u8,
    fs_path: []const u8,
    branch_name: []const u8,
) !WorktreeId {
    const wt_id = try db.addWorktree(name, fs_path, branch_name);
    try Io.Dir.cwd().createDirPath(io, fs_path);

    const link_file_path = try std.fmt.allocPrint(allocator, "{s}/.vcs-link", .{fs_path});
    defer allocator.free(link_file_path);

    const link_content = try std.fmt.allocPrint(
        allocator,
        "db_path={s}\nwt_id={d}\n",
        .{ db_path, wt_id },
    );
    defer allocator.free(link_content);

    const file = try Io.Dir.cwd().createFile(io, link_file_path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buf);
    try writer.interface.writeAll(link_content);
    try writer.interface.flush();

    try materializeWorktreeToDir(allocator, io, db, wt_id, fs_path);
    return wt_id;
}

/// Render the working-copy bytes for `path` in `wt_id` (clean bytes if conflict-free,
/// or synthesized diff3 conflict markers if `PathSum` is conflicted).
pub fn renderPathForCheckout(
    allocator: Allocator,
    db: *const RepoDb,
    wt_id: WorktreeId,
    path: []const u8,
) !?[]u8 {
    const wt = db.worktrees.items[wt_id];
    const manifest = db.trees.items[wt.working_tree_id];
    const sum = manifest.getPathSum(path) orelse return null;

    if (sum.getCleanHash()) |clean_hash| {
        const bytes = db.getBlob(clean_hash) orelse return error.MissingArtifactBlob;
        return try allocator.dupe(u8, bytes);
    }

    if (sum.extractTwoSidedConflict()) |two_sided| {
        const base_bytes = db.getBlob(two_sided.base) orelse "";
        const ours_bytes = db.getBlob(two_sided.ours) orelse "";
        const theirs_bytes = db.getBlob(two_sided.theirs) orelse "";

        const rendered = try diff3.mergeTextAnchorDiff3(
            allocator,
            base_bytes,
            ours_bytes,
            theirs_bytes,
            "side-1",
            "base",
            "side-2",
        );
        return rendered.bytes;
    }

    // General N-way conflict fallback rendering
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<<<<<<< algebraic-conflict\n");
    for (sum.terms.items) |t| {
        const blob = db.getBlob(t.hash) orelse "";
        if (t.coeff > 0) {
            try out.appendSlice(allocator, "+++++++ (+)\n");
        } else {
            try out.appendSlice(allocator, "------- (-)\n");
        }
        try out.appendSlice(allocator, blob);
    }
    try out.appendSlice(allocator, "=======\n>>>>>>> end-conflict\n");
    return try out.toOwnedSlice(allocator);
}

fn deleteEmptyParentDirs(dir: Io.Dir, io: Io, rel_path: []const u8) void {
    var current = std.fs.path.dirname(rel_path);
    while (current) |parent| {
        dir.deleteDir(io, parent) catch break;
        current = std.fs.path.dirname(parent);
    }
}

/// Ensure all path components of `parent_dir` can be created as directories by unlinking
/// any stale regular file blocking a directory component.
fn ensureParentDirSafe(dir: Io.Dir, io: Io, parent_dir: []const u8) !void {
    var end: usize = 0;
    while (end < parent_dir.len) {
        if (std.mem.indexOfScalarPos(u8, parent_dir, end, '/')) |slash_idx| {
            end = slash_idx;
        } else {
            end = parent_dir.len;
        }
        const prefix = parent_dir[0..end];
        if (prefix.len > 0) {
            if (dir.statFile(io, prefix, .{})) |st| {
                if (st.kind != .directory) {
                    dir.deleteFile(io, prefix) catch {};
                }
            } else |_| {}
        }
        end += 1;
    }
    try dir.createDirPath(io, parent_dir);
}

/// Materialize all files in worktree `wt_id` into directory `dir_path` on disk,
/// removing any previously tracked files that are no longer in `wt_id`'s working tree,
/// safely handling File-vs-Directory (D/F) path prefix collisions, and updating `db.stat_cache`.
pub fn materializeWorktreeToDir(
    allocator: Allocator,
    io: Io,
    db: *RepoDb,
    wt_id: WorktreeId,
    dir_path: []const u8,
) !void {
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    const wt = db.worktrees.items[wt_id];
    const manifest = db.trees.items[wt.working_tree_id];

    // 1. Unlink any previously tracked files in `stat_cache` for `wt_id` that are absent in `manifest`
    //    (including conflicted files and `~df-conflict` shadow files) and prune empty parent directories.
    var idx: usize = db.stat_cache.items.len;
    while (idx > 0) {
        idx -= 1;
        const sc = db.stat_cache.items[idx];
        if (sc.worktree_id != wt_id) continue;

        const should_remove = if (std.mem.endsWith(u8, sc.path, "~df-conflict")) blk: {
            const logical = sc.path[0 .. sc.path.len - "~df-conflict".len];
            break :blk (manifest.getPathSum(logical) == null or !manifest.isFileShadowedBySubpath(logical));
        } else blk: {
            break :blk (manifest.getPathSum(sc.path) == null or manifest.isFileShadowedBySubpath(sc.path));
        };

        if (should_remove) {
            dir.deleteFile(io, sc.path) catch {};
            deleteEmptyParentDirs(dir, io, sc.path);
            var removed = db.stat_cache.orderedRemove(idx);
            removed.deinit(allocator);
        }
    }

    // 2. Write all entries in `manifest` to disk and refresh `stat_cache`
    const has_any_df_conflict = manifest.hasDirectoryFileConflicts();
    var last_parent_dir: ?[]const u8 = null;

    for (manifest.entries.items) |entry| {
        const is_df_shadowed = if (has_any_df_conflict) manifest.isFileShadowedBySubpath(entry.path) else false;
        const target_disk_path = if (is_df_shadowed)
            try std.fmt.allocPrint(allocator, "{s}~df-conflict", .{entry.path})
        else
            entry.path;
        defer if (is_df_shadowed) allocator.free(target_disk_path);

        if (is_df_shadowed) {
            // Ensure `entry.path` is not lingering as a regular file blocking subpaths
            dir.deleteFile(io, entry.path) catch {};
        } else if (has_any_df_conflict) {
            // If `target_disk_path` was previously an empty directory, remove it before creating the file
            dir.deleteDir(io, target_disk_path) catch {};
        }

        if (std.fs.path.dirname(target_disk_path)) |parent_dir| {
            if (last_parent_dir == null or !std.mem.eql(u8, last_parent_dir.?, parent_dir)) {
                try ensureParentDirSafe(dir, io, parent_dir);
                if (!is_df_shadowed) last_parent_dir = parent_dir;
            }
        }

        var owned_rendered: ?[]u8 = null;
        defer if (owned_rendered) |r| allocator.free(r);

        const rendered: []const u8 = if (entry.sum.getCleanHash()) |clean_hash|
            (db.getBlob(clean_hash) orelse continue)
        else blk_conf: {
            owned_rendered = (try renderPathForCheckout(allocator, db, wt_id, entry.path)) orelse continue;
            break :blk_conf owned_rendered.?;
        };

        if (entry.mode == .symlink and !entry.sum.isConflicted() and comptime @hasDecl(Io.Dir, "symLink")) {
            dir.deleteFile(io, target_disk_path) catch {};
            dir.symLink(io, rendered, target_disk_path, .{}) catch {
                const file = try dir.createFile(io, target_disk_path, .{ .permissions = .default_file });
                defer file.close(io);
                var buf: [4096]u8 = undefined;
                var writer: Io.File.Writer = .init(file, io, &buf);
                try writer.interface.writeAll(rendered);
                try writer.interface.flush();
            };
        } else {
            dir.deleteFile(io, target_disk_path) catch {};
            const file = try dir.createFile(io, target_disk_path, .{
                .permissions = if (entry.mode == .executable) .fromMode(0o755) else .default_file,
            });
            defer file.close(io);

            var buf: [4096]u8 = undefined;
            var writer: Io.File.Writer = .init(file, io, &buf);
            try writer.interface.writeAll(rendered);
            try writer.interface.flush();
        }

        if (!is_df_shadowed) {
            if (entry.sum.getCleanHash()) |clean_hash| {
                if (dir.statFile(io, target_disk_path, .{})) |st| {
                    const mtime_ns: i64 = @truncate(st.mtime.nanoseconds);
                    // Mark `verified_stable = false` on freshly materialized files to close the
                    // racy stat-cache window (same-timestamp, same-size immediate overwrites)!
                    try db.upsertStatCache(wt_id, entry.path, mtime_ns, st.size, clean_hash, false);
                } else |_| {}
            } else {
                // Record conflicted file path in `stat_cache` with `ABSENT_HASH` and `verified_stable = false`
                // so it is never treated as a clean stat hit, yet is ALWAYS unlinked on branch switch!
                try db.upsertStatCache(wt_id, entry.path, 0, 0, repo_db.ABSENT_HASH, false);
            }
        } else {
            // Record `~df-conflict` disk path in `stat_cache` so it is unlinked when D/F conflict resolves
            try db.upsertStatCache(wt_id, target_disk_path, 0, 0, repo_db.ABSENT_HASH, false);
        }
    }
}

/// Automatically scan `dir_path` on disk, respecting `.vcsignore` and `db.stat_cache`,
/// and synchronize any added, edited, deleted, or resolved files into `db.worktrees[wt_id]`.
pub fn syncWorktreeFromDisk(
    allocator: Allocator,
    io: Io,
    db: *RepoDb,
    wt_id: WorktreeId,
    dir_path: []const u8,
) !SyncStats {
    var stats: SyncStats = .{};

    var root_dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return stats;
    defer root_dir.close(io);

    // 1. Load `.gitignore` and `.vcsignore` if present in the worktree root
    var ignore = IgnoreMatcher.init(allocator);
    defer ignore.deinit();

    if (root_dir.readFileAlloc(io, ".gitignore", allocator, .limited(1024 * 1024))) |git_ignore_bytes| {
        defer allocator.free(git_ignore_bytes);
        try ignore.addRulesFromText(git_ignore_bytes);
    } else |_| {}

    if (root_dir.readFileAlloc(io, ".vcsignore", allocator, .limited(1024 * 1024))) |ignore_bytes| {
        defer allocator.free(ignore_bytes);
        try ignore.addRulesFromText(ignore_bytes);
    } else |_| {}

    const old_tid = db.worktrees.items[wt_id].working_tree_id;
    var old_manifest = try db.trees.items[old_tid].clone(allocator);
    defer old_manifest.deinit(allocator);

    var new_manifest: TreeManifest = .{};
    var new_manifest_owned = true;
    errdefer if (new_manifest_owned) new_manifest.deinit(allocator);

    var seen_paths: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen_paths.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen_paths.deinit(allocator);
    }

    // 2. Recursively walk `root_dir`
    try scanDirectoryRecursive(
        allocator,
        io,
        root_dir,
        "",
        &ignore,
        db,
        wt_id,
        &old_manifest,
        &new_manifest,
        &seen_paths,
        &stats,
    );

    // 3. Count deleted files (present in `old_manifest` but no longer on disk)
    for (old_manifest.entries.items) |old_entry| {
        if (!seen_paths.contains(old_entry.path)) {
            stats.files_deleted += 1;
            db.removeStatCache(wt_id, old_entry.path);
        }
    }

    // 4. Intern `new_manifest` and apply atomic sync to `db`
    if (new_manifest.eql(old_manifest)) {
        new_manifest.deinit(allocator);
        new_manifest_owned = false;
        stats.tree_changed = false;
        return stats;
    }

    new_manifest_owned = false;
    const new_tid = try db.internTreeOwned(new_manifest);
    stats.tree_changed = try db.applyWorkingTreeSync(wt_id, new_tid);
    return stats;
}

fn scanDirectoryRecursive(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    prefix: []const u8,
    ignore: *const IgnoreMatcher,
    db: *RepoDb,
    wt_id: WorktreeId,
    old_manifest: *const TreeManifest,
    new_manifest: *TreeManifest,
    seen_paths: *std.StringHashMapUnmanaged(void),
    stats: *SyncStats,
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const rel_path = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(rel_path);

        const is_dir = (entry.kind == .directory);
        if (std.mem.eql(u8, entry.name, ".vcs") or
            std.mem.eql(u8, entry.name, ".git") or
            std.mem.eql(u8, entry.name, ".vcs-link") or
            std.mem.eql(u8, entry.name, ".vcs-wt"))
        {
            continue;
        }
        const is_tracked = if (is_dir)
            old_manifest.isFileShadowedBySubpath(rel_path)
        else
            (old_manifest.getPathSum(rel_path) != null);

        if (!is_tracked and ignore.isIgnored(rel_path, is_dir)) continue;

        if (is_dir) {
            var sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub_dir.close(io);
            try scanDirectoryRecursive(
                allocator,
                io,
                sub_dir,
                rel_path,
                ignore,
                db,
                wt_id,
                old_manifest,
                new_manifest,
                seen_paths,
                stats,
            );
        } else if (entry.kind == .sym_link and comptime @hasDecl(Io.Dir, "readLink")) {
            if (!seen_paths.contains(rel_path)) {
                const duped_key = try allocator.dupe(u8, rel_path);
                errdefer allocator.free(duped_key);
                try seen_paths.put(allocator, duped_key, {});
            }
            var link_buf: [4096]u8 = undefined;
            const link_len_or_slice = dir.readLink(io, entry.name, &link_buf) catch continue;
            const target_slice: []const u8 = if (@TypeOf(link_len_or_slice) == usize)
                link_buf[0..link_len_or_slice]
            else
                link_len_or_slice;
            stats.files_hashed += 1;
            const blob_hash = try db.putBlob(target_slice);
            try new_manifest.setCleanFileWithMode(allocator, rel_path, blob_hash, .symlink);
            try db.upsertStatCache(wt_id, rel_path, 0, target_slice.len, blob_hash, false);
        } else if (entry.kind == .file) {
            const logical_path = if (std.mem.endsWith(u8, rel_path, "~df-conflict")) blk: {
                const cand = rel_path[0 .. rel_path.len - "~df-conflict".len];
                if (old_manifest.getPathSum(cand) != null and old_manifest.isFileShadowedBySubpath(cand)) {
                    break :blk cand;
                }
                break :blk rel_path;
            } else rel_path;

            if (!seen_paths.contains(logical_path)) {
                const duped_key = try allocator.dupe(u8, logical_path);
                errdefer allocator.free(duped_key);
                try seen_paths.put(allocator, duped_key, {});
            }

            const st = try dir.statFile(io, entry.name, .{});
            const mtime_ns: i64 = @truncate(st.mtime.nanoseconds);
            const size_bytes: u64 = st.size;
            const disk_mode: tree_sum.FileMode = if (comptime @hasDecl(Io.File.Permissions, "toMode"))
                (if ((st.permissions.toMode() & 0o111) != 0) .executable else .regular)
            else
                (old_manifest.getPathMode(logical_path) orelse .regular);

            if (old_manifest.getPathSum(logical_path)) |existing_sum| {
                const old_mode = old_manifest.getPathMode(logical_path) orelse .regular;
                if (existing_sum.getCleanHash()) |clean_hash| {
                    // Check stat cache hit (only if verified_stable == true and mode unchanged)!
                    if (db.getStatCache(wt_id, logical_path)) |sc| {
                        if (sc.verified_stable and
                            old_mode == disk_mode and
                            sc.mtime_ns == mtime_ns and
                            sc.size_bytes == size_bytes and
                            tree_sum.hashEql(sc.hash, clean_hash))
                        {
                            stats.stat_cache_hits += 1;
                            try new_manifest.setCleanFileWithMode(allocator, logical_path, clean_hash, disk_mode);
                            continue;
                        }
                    }
                }
            }

            // Stat cache miss or conflicted file: read bytes from disk
            const file_bytes = try dir.readFileAlloc(io, entry.name, allocator, .limited(64 * 1024 * 1024));
            defer allocator.free(file_bytes);

            if (old_manifest.getPathSum(logical_path)) |existing_sum| {
                if (existing_sum.isConflicted()) {
                    if (diff3.hasConflictMarkers(file_bytes)) {
                        // Still has unresolved conflict markers: preserve structured B + C - A term!
                        const cloned_sum = try existing_sum.clone(allocator);
                        try new_manifest.setPathSumWithModeOwned(allocator, logical_path, cloned_sum, disk_mode);
                        continue;
                    } else {
                        // User removed the conflict markers -> collapse to clean basis term!
                        stats.conflicts_resolved += 1;
                    }
                }
            }

            stats.files_hashed += 1;
            const blob_hash = try db.putBlob(file_bytes);
            try new_manifest.setCleanFileWithMode(allocator, logical_path, blob_hash, disk_mode);
            if (std.mem.eql(u8, logical_path, rel_path)) {
                try db.upsertStatCache(wt_id, logical_path, mtime_ns, size_bytes, blob_hash, true);
            }
        }
    }
}

/// Ingest a file from in-memory bytes into worktree `wt_id` (used for programmatic tests).
pub fn ingestWorkingFileFromBytes(
    db: *RepoDb,
    wt_id: WorktreeId,
    path: []const u8,
    disk_bytes: []const u8,
) !bool {
    const wt = db.worktrees.items[wt_id];
    const manifest = db.trees.items[wt.working_tree_id];

    if (manifest.getPathSum(path)) |existing_sum| {
        if (existing_sum.isConflicted()) {
            if (diff3.hasConflictMarkers(disk_bytes)) {
                return false;
            }
            try db.resolveFile(wt_id, path, disk_bytes);
            return true;
        } else if (existing_sum.getCleanHash()) |clean_hash| {
            const disk_hash = tree_sum.computeBlake3(disk_bytes);
            if (tree_sum.hashEql(clean_hash, disk_hash)) {
                return false;
            }
        }
    }

    try db.editFile(wt_id, path, disk_bytes);
    return true;
}

test "Materializer: renders first-class conflict markers only on checkout and resolves when markers removed" {
    const gpa = std.testing.allocator;
    var db = try RepoDb.initNew(gpa, "/tmp/wt_mat");
    defer db.deinit();

    // 1. Commit base on `main`
    try db.editFile(0, "config.toml", "mode = \"dev\"\n");
    _ = try db.commitWorktree(0, "alice", "Base config");

    // 2. Branch `feat` modifies same line
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "config.toml", "mode = \"staging\"\n");
    _ = try db.commitWorktree(0, "bob", "Staging mode");

    // 3. Switch back to `main` and modify same line differently
    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "config.toml", "mode = \"production\"\n");
    _ = try db.commitWorktree(0, "alice", "Production mode");

    // 4. Merge `feat` into `main` -> produces structured conflict `B + C - A` in DB!
    _ = try db.mergeBranch(0, "feat", "alice", "Merge feat with conflict");
    const wt_tid = db.worktrees.items[0].working_tree_id;
    try std.testing.expect(db.trees.items[wt_tid].hasConflicts());

    // Verify NO blob in `db.blobs` contains `<<<<<<<` conflict markers!
    for (db.blobs.items) |blob| {
        try std.testing.expect(!diff3.hasConflictMarkers(blob.bytes));
    }

    // 5. Render for checkout -> produces diff3 markers on the fly
    const checkout_bytes = (try renderPathForCheckout(gpa, &db, 0, "config.toml")).?;
    defer gpa.free(checkout_bytes);
    try std.testing.expect(diff3.hasConflictMarkers(checkout_bytes));

    // 6. If user leaves markers untouched on disk, `ingestWorkingFileFromBytes` preserves algebraic conflict
    const changed_while_marked = try ingestWorkingFileFromBytes(&db, 0, "config.toml", checkout_bytes);
    try std.testing.expect(!changed_while_marked);
    try std.testing.expect(db.trees.items[db.worktrees.items[0].working_tree_id].hasConflicts());

    // 7. User edits file to remove markers -> automatically collapses to clean basis term!
    const changed_after_resolve = try ingestWorkingFileFromBytes(&db, 0, "config.toml", "mode = \"production-verified\"\n");
    try std.testing.expect(changed_after_resolve);
    try std.testing.expect(!db.trees.items[db.worktrees.items[0].working_tree_id].hasConflicts());
}

test "Automatic Worktree Scanner + .vcsignore + Stat Cache: detects edits, deletes, ignores, and stat hits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wt_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(wt_rel);

    var db = try RepoDb.initNew(gpa, wt_rel);
    defer db.deinit();

    // 1. Write `.vcsignore`, `src/main.zig`, and an ignored `build.log` directly to disk (like an editor/compiler)
    try tmp.dir.writeFile(io, .{ .sub_path = ".vcsignore", .data = "*.log\n" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.log", .data = "ignored compiler output\n" });

    // 2. First scan: hashes `.vcsignore` and `src/main.zig`, skips `build.log`
    const s1 = try syncWorktreeFromDisk(gpa, io, &db, 0, wt_rel);
    try std.testing.expect(s1.tree_changed);
    try std.testing.expectEqual(@as(usize, 2), s1.files_hashed);
    try std.testing.expectEqual(@as(usize, 0), s1.stat_cache_hits);
    try std.testing.expect(db.worktrees.items[0].is_dirty);

    // Verify `build.log` was ignored and `src/main.zig` was tracked
    const tree1 = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expect(tree1.getPathSum("src/main.zig") != null);
    try std.testing.expect(tree1.getPathSum("build.log") == null);

    // 3. Second scan with no disk changes: 100% Stat Cache hits (0 files hashed)!
    const s2 = try syncWorktreeFromDisk(gpa, io, &db, 0, wt_rel);
    try std.testing.expect(!s2.tree_changed);
    try std.testing.expectEqual(@as(usize, 0), s2.files_hashed);
    try std.testing.expectEqual(@as(usize, 2), s2.stat_cache_hits);

    // 4. Commit on `main`, switch to `feat`, create `feat_only.txt`, then switch back to `main`:
    //    `materializeWorktreeToDir` must automatically unlink `feat_only.txt` from disk!
    _ = try db.commitWorktree(0, "alice", "Initial commit");
    _ = try db.switchBranch(0, "feat");
    try tmp.dir.writeFile(io, .{ .sub_path = "feat_only.txt", .data = "dirty draft on feat\n" });
    _ = try syncWorktreeFromDisk(gpa, io, &db, 0, wt_rel);

    _ = try db.switchBranch(0, "main");
    try materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);

    // Verify `feat_only.txt` was cleanly removed from the working directory on `main`,
    // and switching back to `feat` restores `feat_only.txt` to disk!
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "feat_only.txt", .{}));

    _ = try db.switchBranch(0, "feat");
    try materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);
    const restored_st = try tmp.dir.statFile(io, "feat_only.txt", .{});
    try std.testing.expectEqual(@as(u64, 20), restored_st.size);
}
