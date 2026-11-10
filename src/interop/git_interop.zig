//! Milestone 4: Bi-Directional Git Interop (`git fast-export` / `git fast-import` Engine).
//!
//! Enables seamless dogfooding of `zig-vcs` on existing Git repositories (inspired by Fossil's
//! `fossil import --git` and `fossil export --git`):
//! - **`emitFastExportStream`**: Exports all blobs, multi-path trees, commits (including merge
//!   parents), and branches from `RepoDb` into a standard Git `fast-import` stream.
//! - **`importFastExportStream`**: Parses a standard `git fast-export` stream (`blob`, `commit`,
//!   `mark`, `data`, `from`, `merge`, `M`, `D`, `deleteall`, `reset`) into `RepoDb`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const repo_db = @import("../storage/repo_db.zig");
const tree_sum = @import("../algebra/tree_sum.zig");
const materializer = @import("../worktree/materializer.zig");

pub const RepoDb = repo_db.RepoDb;
pub const ArtifactHash = repo_db.ArtifactHash;
pub const CommitId = repo_db.CommitId;
pub const TreeId = repo_db.TreeId;
pub const TreeManifest = tree_sum.TreeManifest;

/// Emit a standard `git fast-import` stream representing all blobs, commits, and branches in `db`.
pub fn emitFastExportStream(allocator: Allocator, db: *const RepoDb) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // 1. Emit all blobs with mark IDs `1 .. db.blobs.items.len`
    for (db.blobs.items, 0..) |blob, idx| {
        const mark_id = idx + 1;
        const header = try std.fmt.allocPrint(
            allocator,
            "blob\nmark :{d}\ndata {d}\n",
            .{ mark_id, blob.bytes.len },
        );
        defer allocator.free(header);
        try out.appendSlice(allocator, header);
        try out.appendSlice(allocator, blob.bytes);
        try out.append(allocator, '\n');
    }

    // Helper offset for commit marks so they never collide with blob marks
    const commit_mark_base: usize = db.blobs.items.len + 1000;

    // 2. Emit all commits starting from `c1` (since `c0` is the synthetic empty root commit)
    for (db.commits.items, 0..) |c, cid| {
        if (cid == 0) continue;

        const c_mark = commit_mark_base + cid;
        const committer_ident = try formatFastExportIdentAlloc(allocator, c.author);
        defer allocator.free(committer_ident);
        const hdr = try std.fmt.allocPrint(
            allocator,
            "commit refs/heads/main\nmark :{d}\ncommitter {s} {d} +0000\ndata {d}\n{s}\n",
            .{ c_mark, committer_ident, c.timestamp_sec, c.message.len, c.message },
        );
        defer allocator.free(hdr);
        try out.appendSlice(allocator, hdr);

        if (c.parent1) |p1| {
            if (p1 > 0) {
                const p1_line = try std.fmt.allocPrint(allocator, "from :{d}\n", .{commit_mark_base + p1});
                defer allocator.free(p1_line);
                try out.appendSlice(allocator, p1_line);
            }
        }
        if (c.parent2) |p2| {
            if (p2 > 0) {
                const p2_line = try std.fmt.allocPrint(allocator, "merge :{d}\n", .{commit_mark_base + p2});
                defer allocator.free(p2_line);
                try out.appendSlice(allocator, p2_line);
            }
        }

        try out.appendSlice(allocator, "deleteall\n");
        const tree = db.trees.items[c.root_tree_id];
        for (tree.entries.items) |entry| {
            if (entry.sum.getCleanHash()) |clean_hash| {
                if (findBlobMark(db, clean_hash)) |b_mark| {
                    const m_line = try std.fmt.allocPrint(
                        allocator,
                        "M {o} :{d} {s}\n",
                        .{ @intFromEnum(entry.mode), b_mark, entry.path },
                    );
                    defer allocator.free(m_line);
                    try out.appendSlice(allocator, m_line);
                }
            } else {
                // Conflicted PathSum in Z[A_bot]:
                // 1. Emit the first positive basis blob as `M` so standard `git fast-import` sees the file.
                for (entry.sum.terms.items) |term| {
                    if (term.coeff > 0) {
                        if (findBlobMark(db, term.hash)) |b_mark| {
                            const m_line = try std.fmt.allocPrint(
                                allocator,
                                "M {o} :{d} {s}\n",
                                .{ @intFromEnum(entry.mode), b_mark, entry.path },
                            );
                            defer allocator.free(m_line);
                            try out.appendSlice(allocator, m_line);
                            break;
                        }
                    }
                }
                // 2. Emit `# zig-vcs-conflict <mode_octal> <path>\t<coeff>:<mark>,...` comment
                //    (valid `git fast-import` comment syntax) for lossless algebraic PathSum restoration!
                try out.print(
                    allocator,
                    "# zig-vcs-conflict {o} {s}\t",
                    .{ @intFromEnum(entry.mode), entry.path },
                );
                for (entry.sum.terms.items, 0..) |term, tidx| {
                    if (tidx > 0) try out.append(allocator, ',');
                    const b_mark: usize = if (tree_sum.hashEql(term.hash, repo_db.ABSENT_HASH))
                        0
                    else
                        (findBlobMark(db, term.hash) orelse 0);
                    try out.print(allocator, "{d}:{d}", .{ term.coeff, b_mark });
                }
                try out.append(allocator, '\n');
            }
        }
        try out.append(allocator, '\n');
    }

    // 3. Emit branch ref resets for every branch with head_commit > 0
    for (db.branches.items) |br| {
        if (br.head_commit > 0) {
            const ref_block = try std.fmt.allocPrint(
                allocator,
                "reset refs/heads/{s}\nfrom :{d}\n\n",
                .{ br.name, commit_mark_base + br.head_commit },
            );
            defer allocator.free(ref_block);
            try out.appendSlice(allocator, ref_block);
        }
    }

    // 4. Emit tag ref resets for every tag in `db.tags`
    for (db.tags.items) |t| {
        if (t.target_commit > 0) {
            const tag_block = try std.fmt.allocPrint(
                allocator,
                "reset refs/tags/{s}\nfrom :{d}\n\n",
                .{ t.name, commit_mark_base + t.target_commit },
            );
            defer allocator.free(tag_block);
            try out.appendSlice(allocator, tag_block);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn findBlobMark(db: *const RepoDb, hash: ArtifactHash) ?usize {
    if (db.blob_index.get(hash)) |idx| {
        return @as(usize, idx) + 1;
    }
    for (db.blobs.items, 0..) |b, idx| {
        if (tree_sum.hashEql(b.hash, hash)) return idx + 1;
    }
    return null;
}

fn formatFastExportIdentAlloc(allocator: Allocator, author: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, author, '<') != null and std.mem.indexOfScalar(u8, author, '>') != null) {
        return allocator.dupe(u8, author);
    }
    var has_space = false;
    for (author) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '<' or ch == '>') {
            has_space = true;
            break;
        }
    }
    if (!has_space and author.len > 0) {
        return std.fmt.allocPrint(allocator, "{s} <{s}@zig-vcs.local>", .{ author, author });
    }
    return std.fmt.allocPrint(allocator, "{s} <user@zig-vcs.local>", .{if (author.len > 0) author else "user"});
}

/// Parse a `git fast-export` stream into `db`, populating blobs, trees, commits, and branches!
pub fn importFastExportStream(allocator: Allocator, db: *RepoDb, stream: []const u8) !void {
    var blob_marks = std.AutoHashMap(u64, ArtifactHash).init(allocator);
    defer blob_marks.deinit();

    var commit_marks = std.AutoHashMap(u64, CommitId).init(allocator);
    defer commit_marks.deinit();

    var pos: usize = 0;
    while (pos < stream.len) {
        const line = readLine(stream, &pos) orelse break;
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "blob")) {
            var mark_id: ?u64 = null;
            while (pos < stream.len) {
                const sub = readLine(stream, &pos) orelse break;
                if (std.mem.startsWith(u8, sub, "mark :")) {
                    mark_id = try std.fmt.parseInt(u64, sub["mark :".len..], 10);
                } else if (std.mem.startsWith(u8, sub, "data ")) {
                    const data_len = try std.fmt.parseInt(usize, sub["data ".len..], 10);
                    if (pos + data_len > stream.len) return error.UnexpectedEofInFastImport;
                    const blob_bytes = stream[pos .. pos + data_len];
                    pos += data_len;
                    if (pos < stream.len and stream[pos] == '\n') pos += 1;

                    const hash = try db.putBlob(blob_bytes);
                    if (mark_id) |m| try blob_marks.put(m, hash);
                    break;
                }
            }
        } else if (std.mem.startsWith(u8, line, "commit ")) {
            const ref_name = line["commit ".len..];
            const is_tag_commit = std.mem.startsWith(u8, ref_name, "refs/tags/");
            const branch_name = if (is_tag_commit) "main" else extractBranchName(ref_name);

            var mark_id: ?u64 = null;
            var author_name: []const u8 = "git-user";
            var commit_ts: i64 = 1700000000;
            var message: []const u8 = "";
            var parent1_cid: ?CommitId = null;
            var parent2_cid: ?CommitId = null;

            const br_id = try db.getOrCreateBranch(branch_name, 0);
            const current_head = db.branches.items[br_id].head_commit;
            var manifest: TreeManifest = .{};
            var manifest_initialized = false;
            var manifest_owned = true;
            errdefer if (manifest_owned) manifest.deinit(allocator);

            while (pos < stream.len) {
                const peek_pos = pos;
                const sub = readLine(stream, &pos) orelse break;
                if (sub.len == 0) break;

                if (std.mem.startsWith(u8, sub, "mark :")) {
                    mark_id = try std.fmt.parseInt(u64, sub["mark :".len..], 10);
                } else if (std.mem.startsWith(u8, sub, "author ")) {
                    author_name = parsePersonName(sub["author ".len..]);
                    if (parsePersonTimestamp(sub["author ".len..])) |ts| commit_ts = ts;
                } else if (std.mem.startsWith(u8, sub, "committer ")) {
                    if (std.mem.eql(u8, author_name, "git-user")) {
                        author_name = parsePersonName(sub["committer ".len..]);
                    }
                    if (parsePersonTimestamp(sub["committer ".len..])) |ts| commit_ts = ts;
                } else if (std.mem.startsWith(u8, sub, "data ")) {
                    const data_len = try std.fmt.parseInt(usize, sub["data ".len..], 10);
                    if (pos + data_len > stream.len) return error.UnexpectedEofInFastImport;
                    message = std.mem.trimEnd(u8, stream[pos .. pos + data_len], "\r\n");
                    pos += data_len;
                    if ((data_len == 0 or stream[pos - 1] != '\n') and pos < stream.len and stream[pos] == '\n') {
                        pos += 1;
                    }
                } else if (std.mem.startsWith(u8, sub, "from :")) {
                    const p_mark = try std.fmt.parseInt(u64, sub["from :".len..], 10);
                    if (commit_marks.get(p_mark)) |p_cid| {
                        parent1_cid = p_cid;
                        if (manifest_initialized) {
                            manifest.deinit(allocator);
                            manifest = .{};
                            manifest_initialized = false;
                        }
                    }
                } else if (std.mem.startsWith(u8, sub, "merge :")) {
                    const m_mark = try std.fmt.parseInt(u64, sub["merge :".len..], 10);
                    if (commit_marks.get(m_mark)) |m_cid| {
                        parent2_cid = m_cid;
                    }
                } else if (std.mem.eql(u8, sub, "deleteall")) {
                    manifest.deinit(allocator);
                    manifest = .{};
                    manifest_initialized = true;
                } else if (std.mem.startsWith(u8, sub, "M ")) {
                    if (!manifest_initialized) {
                        const base_cid = parent1_cid orelse current_head;
                        manifest = try db.trees.items[db.commits.items[base_cid].root_tree_id].clone(allocator);
                        manifest_initialized = true;
                    }
                    // Format: `M <mode> :<mark> <path>`
                    const rest = sub["M ".len..];
                    const sp1 = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
                    const mode_str = rest[0..sp1];
                    const mode_octal = std.fmt.parseInt(u32, mode_str, 8) catch 0o100644;
                    const file_mode = tree_sum.FileMode.fromGitOctal(mode_octal);
                    const after_mode = rest[sp1 + 1 ..];
                    const sp2 = std.mem.indexOfScalar(u8, after_mode, ' ') orelse continue;
                    const dataref = after_mode[0..sp2];
                    const file_path = std.mem.trim(u8, after_mode[sp2 + 1 ..], "\"");

                    if (std.mem.startsWith(u8, dataref, ":")) {
                        const b_mark = try std.fmt.parseInt(u64, dataref[1..], 10);
                        if (blob_marks.get(b_mark)) |b_hash| {
                            manifest.setCleanFileWithMode(allocator, file_path, b_hash, file_mode) catch {};
                        }
                    }
                } else if (std.mem.startsWith(u8, sub, "# zig-vcs-conflict ")) {
                    if (!manifest_initialized) {
                        const base_cid = parent1_cid orelse current_head;
                        manifest = try db.trees.items[db.commits.items[base_cid].root_tree_id].clone(allocator);
                        manifest_initialized = true;
                    }
                    // Format: `# zig-vcs-conflict <mode_octal> <path>\t<coeff>:<mark>,...`
                    const rest = sub["# zig-vcs-conflict ".len..];
                    const sp1 = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
                    const mode_octal = std.fmt.parseInt(u32, rest[0..sp1], 8) catch 0o100644;
                    const file_mode = tree_sum.FileMode.fromGitOctal(mode_octal);
                    const after_mode = rest[sp1 + 1 ..];
                    const tab_idx = std.mem.indexOfScalar(u8, after_mode, '\t') orelse continue;
                    const file_path = after_mode[0..tab_idx];
                    const terms_str = after_mode[tab_idx + 1 ..];

                    var sum: tree_sum.PathSum = .{};
                    var sum_owned = true;
                    errdefer if (sum_owned) sum.deinit(allocator);

                    var term_it = std.mem.splitScalar(u8, terms_str, ',');
                    while (term_it.next()) |t_tok| {
                        if (t_tok.len == 0) continue;
                        const colon = std.mem.indexOfScalar(u8, t_tok, ':') orelse continue;
                        const coeff = try std.fmt.parseInt(i32, t_tok[0..colon], 10);
                        const b_mark = try std.fmt.parseInt(u64, t_tok[colon + 1 ..], 10);
                        const thash: ArtifactHash = if (b_mark == 0)
                            repo_db.ABSENT_HASH
                        else
                            (blob_marks.get(b_mark) orelse continue);
                        try sum.addTermRaw(allocator, thash, coeff);
                    }
                    sum.normalize();
                    if (sum.terms.items.len > 0) {
                        sum_owned = false;
                        try manifest.setPathSumWithModeOwned(allocator, file_path, sum, file_mode);
                    } else {
                        sum.deinit(allocator);
                    }
                } else if (std.mem.startsWith(u8, sub, "D ")) {
                    if (!manifest_initialized) {
                        const base_cid = parent1_cid orelse current_head;
                        manifest = try db.trees.items[db.commits.items[base_cid].root_tree_id].clone(allocator);
                        manifest_initialized = true;
                    }
                    const file_path = std.mem.trim(u8, sub["D ".len..], "\"");
                    manifest.removePath(allocator, file_path);
                } else if (std.mem.eql(u8, sub, "blob") or
                    std.mem.startsWith(u8, sub, "commit ") or
                    std.mem.startsWith(u8, sub, "reset ") or
                    std.mem.startsWith(u8, sub, "tag "))
                {
                    pos = peek_pos;
                    break;
                }
            }

            const actual_p1 = parent1_cid orelse current_head;
            const tree_id: TreeId = if (!manifest_initialized) blk_tid: {
                manifest_owned = false;
                break :blk_tid db.commits.items[actual_p1].root_tree_id;
            } else blk_tid: {
                manifest_owned = false;
                break :blk_tid try db.internTreeOwned(manifest);
            };
            const cid: CommitId = @intCast(db.commits.items.len);
            const author_dup = try allocator.dupe(u8, author_name);
            errdefer allocator.free(author_dup);
            const msg_dup = try allocator.dupe(u8, message);
            errdefer allocator.free(msg_dup);
            try db.commits.append(allocator, .{
                .id = cid,
                .parent1 = actual_p1,
                .parent2 = parent2_cid,
                .root_tree_id = tree_id,
                .author = author_dup,
                .message = msg_dup,
                .timestamp_sec = commit_ts,
            });

            if (mark_id) |m| try commit_marks.put(m, cid);
            if (is_tag_commit) {
                try db.createTag(ref_name["refs/tags/".len..], cid);
            } else {
                db.branches.items[br_id].head_commit = cid;
            }
        } else if (std.mem.startsWith(u8, line, "reset ")) {
            const ref_name = line["reset ".len..];
            const is_tag = std.mem.startsWith(u8, ref_name, "refs/tags/");
            const short_name = if (is_tag)
                ref_name["refs/tags/".len..]
            else
                extractBranchName(ref_name);

            if (pos < stream.len) {
                const peek_pos = pos;
                if (readLine(stream, &pos)) |sub| {
                    if (std.mem.startsWith(u8, sub, "from :")) {
                        const c_mark = try std.fmt.parseInt(u64, sub["from :".len..], 10);
                        if (commit_marks.get(c_mark)) |cid| {
                            if (is_tag) {
                                try db.createTag(short_name, cid);
                            } else {
                                const br_id = try db.getOrCreateBranch(short_name, 0);
                                db.branches.items[br_id].head_commit = cid;
                            }
                        }
                    } else {
                        pos = peek_pos;
                    }
                } else if (!is_tag) {
                    _ = try db.getOrCreateBranch(short_name, 0);
                }
            } else if (!is_tag) {
                _ = try db.getOrCreateBranch(short_name, 0);
            }
        } else if (std.mem.startsWith(u8, line, "tag ")) {
            const tag_name = line["tag ".len..];
            while (pos < stream.len) {
                const sub = readLine(stream, &pos) orelse break;
                if (sub.len == 0) break;
                if (std.mem.startsWith(u8, sub, "from :")) {
                    const c_mark = try std.fmt.parseInt(u64, sub["from :".len..], 10);
                    if (commit_marks.get(c_mark)) |cid| {
                        try db.createTag(tag_name, cid);
                    }
                } else if (std.mem.startsWith(u8, sub, "data ")) {
                    const data_len = try std.fmt.parseInt(usize, sub["data ".len..], 10);
                    if (pos + data_len > stream.len) return error.UnexpectedEofInFastImport;
                    pos += data_len;
                    if ((data_len == 0 or stream[pos - 1] != '\n') and pos < stream.len and stream[pos] == '\n') {
                        pos += 1;
                    }
                    break;
                }
            }
        }
    }

    // If the repository was initialized with a synthetic empty `main` branch (`head_commit == 0`),
    // and the imported stream populated other branch(es) (e.g. `master`), remove the unused empty `main`.
    if (db.branches.items.len > 1 and db.branches.items[0].head_commit == 0) {
        var has_non_empty = false;
        for (db.branches.items[1..]) |br| {
            if (br.head_commit > 0) {
                has_non_empty = true;
                break;
            }
        }
        if (has_non_empty) {
            var removed = db.branches.orderedRemove(0);
            removed.deinit(allocator);
            for (db.branches.items, 0..) |*b, idx| {
                b.id = @intCast(idx);
            }
            for (db.worktrees.items) |*wt| {
                if (wt.branch_id > 0) wt.branch_id -= 1;
            }
        }
    }

    // Sync primary worktree `wt0` to its checked-out branch's new head commit
    if (db.worktrees.items.len > 0) {
        const wt0 = &db.worktrees.items[0];
        if (wt0.branch_id >= db.branches.items.len) wt0.branch_id = 0;
        if (db.branches.items[wt0.branch_id].head_commit == 0) {
            for (db.branches.items, 0..) |br, idx| {
                if (br.head_commit > 0) {
                    wt0.branch_id = @intCast(idx);
                    break;
                }
            }
        }
        const head_cid = db.branches.items[wt0.branch_id].head_commit;
        wt0.working_tree_id = db.commits.items[head_cid].root_tree_id;
        wt0.is_dirty = false;
    }
}

fn readLine(stream: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= stream.len) return null;
    const start = pos.*;
    while (pos.* < stream.len and stream[pos.*] != '\n') : (pos.* += 1) {}
    const line = std.mem.trimEnd(u8, stream[start..pos.*], "\r");
    if (pos.* < stream.len and stream[pos.*] == '\n') pos.* += 1;
    return line;
}

fn extractBranchName(ref_name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
        return ref_name["refs/heads/".len..];
    }
    return ref_name;
}

fn parsePersonName(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '<')) |lt_idx| {
        return std.mem.trim(u8, s[0..lt_idx], " ");
    }
    return s;
}

fn parsePersonTimestamp(s: []const u8) ?i64 {
    if (std.mem.indexOfScalar(u8, s, '>')) |gt_idx| {
        const after_gt = std.mem.trim(u8, s[gt_idx + 1 ..], " \t");
        if (after_gt.len == 0) return null;
        const ts_slice = if (std.mem.indexOfScalar(u8, after_gt, ' ')) |sp|
            after_gt[0..sp]
        else
            after_gt;
        return std.fmt.parseInt(i64, ts_slice, 10) catch null;
    }
    return null;
}

/// Detect whether `spec` is a network or SCP-style Git URL (`https://`, `http://`, `ssh://`, `git://`,
/// `file://`, or `user@host:path`).
pub fn isRemoteGitUrl(spec: []const u8) bool {
    if (std.mem.startsWith(u8, spec, "https://") or
        std.mem.startsWith(u8, spec, "http://") or
        std.mem.startsWith(u8, spec, "ssh://") or
        std.mem.startsWith(u8, spec, "git://") or
        std.mem.startsWith(u8, spec, "file://") or
        std.mem.startsWith(u8, spec, "git@"))
    {
        return true;
    }
    // Check SCP-style `user@host:org/repo.git` (`:` appears before any `/`)
    if (std.mem.indexOfScalar(u8, spec, ':')) |colon_idx| {
        if (colon_idx > 0) {
            const slash_idx = std.mem.indexOfScalar(u8, spec, '/');
            if (slash_idx == null or colon_idx < slash_idx.?) {
                return true;
            }
        }
    }
    return false;
}

/// Infer the default destination directory name from a clone URL or path (e.g.,
/// `"https://github.com/sessions-matthew/lightning.git"` -> `"lightning"`).
pub fn inferCloneDirName(src_arg: []const u8) []const u8 {
    var s = std.mem.trimEnd(u8, src_arg, "/");
    if (std.mem.endsWith(u8, s, ".git")) {
        s = s[0 .. s.len - ".git".len];
    } else if (std.mem.endsWith(u8, s, ".vcs")) {
        s = s[0 .. s.len - ".vcs".len];
    }
    if (std.mem.lastIndexOfAny(u8, s, "/:")) |idx| {
        const tail = s[idx + 1 ..];
        if (tail.len > 0) return tail;
    }
    return if (s.len > 0) s else "repo";
}

/// Detect whether `path` is a local native Git repository (either a working tree with `.git` or a bare repo
/// with `HEAD` and `objects`), rather than a `.vcs` repository.
pub fn isNativeGitRepo(allocator: Allocator, io: Io, path: []const u8) bool {
    if (std.mem.endsWith(u8, path, ".vcs")) return false;
    const vcs_db = std.fmt.allocPrint(allocator, "{s}/.vcs/db.vcs", .{path}) catch return false;
    defer allocator.free(vcs_db);
    if (Io.Dir.cwd().statFile(io, vcs_db, .{})) |_| return false else |_| {}

    const dot_git_head = std.fmt.allocPrint(allocator, "{s}/.git/HEAD", .{path}) catch return false;
    defer allocator.free(dot_git_head);
    if (Io.Dir.cwd().statFile(io, dot_git_head, .{})) |_| return true else |_| {}

    const bare_head = std.fmt.allocPrint(allocator, "{s}/HEAD", .{path}) catch return false;
    defer allocator.free(bare_head);
    if (Io.Dir.cwd().statFile(io, bare_head, .{})) |_| return true else |_| {}

    return false;
}

/// Detect whether `spec` is either a network Git URL (`https://...`, `git@...`) or a local `.git` repository.
pub fn isGitRemote(allocator: Allocator, io: Io, spec: []const u8) bool {
    return isRemoteGitUrl(spec) or isNativeGitRepo(allocator, io, spec);
}

/// Load a local native Git repository at `git_repo_path` into an in-memory `RepoDb` by running
/// `git -c core.quotePath=false -C <git_repo_path> fast-export --all --signed-tags=strip`
/// and parsing the stream via `importFastExportStream`.
pub fn loadRepoDbFromNativeGit(allocator: Allocator, io: Io, git_repo_path: []const u8) !RepoDb {
    const res = try std.process.run(allocator, io, .{
        .argv = &.{
            "git",
            "-c",
            "core.quotePath=false",
            "-C",
            git_repo_path,
            "fast-export",
            "--all",
            "--signed-tags=strip",
        },
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    var db = try RepoDb.initNew(allocator, git_repo_path);
    errdefer db.deinit();

    // An empty `git init` repo with 0 commits may exit or return empty stdout; only parse if non-empty
    if (res.term == .exited and res.term.exited == 0 and res.stdout.len > 0) {
        try importFastExportStream(allocator, &db, res.stdout);
    }

    // Bind `wt0` to the Git repository's `HEAD` branch if `symbolic-ref --short HEAD` resolves
    if (std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", git_repo_path, "symbolic-ref", "--short", "HEAD" },
    })) |head_res| {
        defer allocator.free(head_res.stdout);
        defer allocator.free(head_res.stderr);
        if (head_res.term == .exited and head_res.term.exited == 0) {
            const head_br_name = std.mem.trim(u8, head_res.stdout, " \t\r\n");
            if (db.findBranchByName(head_br_name)) |br_id| {
                if (db.worktrees.items.len > 0) {
                    db.worktrees.items[0].branch_id = br_id;
                    const hcid = db.branches.items[br_id].head_commit;
                    db.worktrees.items[0].working_tree_id = db.commits.items[hcid].root_tree_id;
                    db.worktrees.items[0].is_dirty = false;
                }
            }
        }
    } else |_| {}

    return db;
}

/// Load a remote or local Git repository (`https://...`, `git@...`, or local `.git` path) into an
/// in-memory `RepoDb`. For remote URLs, maintains a bare Git transport mirror inside `<vcs_dir>/git-remote-cache`.
pub fn loadRepoDbFromGitRemote(
    allocator: Allocator,
    io: Io,
    vcs_dir: []const u8,
    remote_spec: []const u8,
) !RepoDb {
    if (isNativeGitRepo(allocator, io, remote_spec)) {
        return loadRepoDbFromNativeGit(allocator, io, remote_spec);
    }

    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/git-remote-cache", .{vcs_dir});
    defer allocator.free(cache_dir);
    const cache_head = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{cache_dir});
    defer allocator.free(cache_head);

    const has_cache = if (Io.Dir.cwd().statFile(io, cache_head, .{})) |_| true else |_| false;
    if (!has_cache) {
        try Io.Dir.cwd().createDirPath(io, vcs_dir);
        const clone_res = try std.process.run(allocator, io, .{
            .argv = &.{ "git", "clone", "--bare", "--", remote_spec, cache_dir },
        });
        defer allocator.free(clone_res.stdout);
        defer allocator.free(clone_res.stderr);
        if (clone_res.term != .exited or clone_res.term.exited != 0) {
            return error.GitCloneFailed;
        }
    } else {
        const fetch_res = try std.process.run(allocator, io, .{
            .argv = &.{
                "git",
                "-C",
                cache_dir,
                "fetch",
                "--prune",
                "--",
                remote_spec,
                "+refs/heads/*:refs/heads/*",
                "+refs/tags/*:refs/tags/*",
            },
        });
        defer allocator.free(fetch_res.stdout);
        defer allocator.free(fetch_res.stderr);
        if (fetch_res.term != .exited or fetch_res.term.exited != 0) {
            return error.GitFetchFailed;
        }
    }

    return loadRepoDbFromNativeGit(allocator, io, cache_dir);
}

/// Export an in-memory `RepoDb` back to a local `.git` repository OR a remote Git URL (`https://...`, `git@...`).
pub fn exportRepoDbToGitRemote(
    allocator: Allocator,
    io: Io,
    vcs_dir: []const u8,
    db: *const RepoDb,
    remote_spec: []const u8,
    branch_opt: ?[]const u8,
    force: bool,
) !void {
    if (isNativeGitRepo(allocator, io, remote_spec)) {
        return exportRepoDbToNativeGit(allocator, io, db, remote_spec, branch_opt);
    }

    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/git-remote-cache", .{vcs_dir});
    defer allocator.free(cache_dir);
    const cache_head = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{cache_dir});
    defer allocator.free(cache_head);

    if (Io.Dir.cwd().statFile(io, cache_head, .{})) |_| {} else |_| {
        try Io.Dir.cwd().createDirPath(io, cache_dir);
        const init_res = try std.process.run(allocator, io, .{
            .argv = &.{ "git", "init", "--bare", cache_dir },
        });
        defer allocator.free(init_res.stdout);
        defer allocator.free(init_res.stderr);
    }

    try exportRepoDbToNativeGit(allocator, io, db, cache_dir, branch_opt);

    const br = branch_opt orelse "main";
    const refspec = try std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ br, br });
    defer allocator.free(refspec);

    const push_res = if (force)
        try std.process.run(allocator, io, .{
            .argv = &.{ "git", "-C", cache_dir, "push", "--force", "--", remote_spec, refspec },
        })
    else
        try std.process.run(allocator, io, .{
            .argv = &.{ "git", "-C", cache_dir, "push", "--", remote_spec, refspec },
        });
    defer allocator.free(push_res.stdout);
    defer allocator.free(push_res.stderr);
    if (push_res.term != .exited or push_res.term.exited != 0) {
        return error.GitPushFailed;
    }
}

/// Export an in-memory `RepoDb` back into a native Git repository at `git_repo_path` via
/// `git fast-import --force --quiet`, and if the target Git repository is a non-bare working
/// tree, update its checkout for `branch_opt`.
pub fn exportRepoDbToNativeGit(
    allocator: Allocator,
    io: Io,
    db: *const RepoDb,
    git_repo_path: []const u8,
    branch_opt: ?[]const u8,
) !void {
    const stream = try emitFastExportStream(allocator, db);
    defer allocator.free(stream);

    const dot_git_head = try std.fmt.allocPrint(allocator, "{s}/.git/HEAD", .{git_repo_path});
    defer allocator.free(dot_git_head);
    const is_non_bare = if (Io.Dir.cwd().statFile(io, dot_git_head, .{})) |_| true else |_| false;

    const tmp_stream_path = if (is_non_bare)
        try std.fmt.allocPrint(allocator, "{s}/.git/zig_vcs_fast_import.tmp", .{git_repo_path})
    else
        try std.fmt.allocPrint(allocator, "{s}/zig_vcs_fast_import.tmp", .{git_repo_path});
    defer allocator.free(tmp_stream_path);

    {
        var f = try Io.Dir.cwd().createFile(io, tmp_stream_path, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, stream);
    }
    defer Io.Dir.cwd().deleteFile(io, tmp_stream_path) catch {};

    const sh_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" fast-import --force --quiet < \"{s}\"",
        .{ git_repo_path, tmp_stream_path },
    );
    defer allocator.free(sh_cmd);

    const res = try std.process.run(allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", sh_cmd },
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        return error.GitFastImportFailed;
    }

    if (is_non_bare) {
        const target_br = branch_opt orelse "main";
        const co_res = try std.process.run(allocator, io, .{
            .argv = &.{ "git", "-C", git_repo_path, "checkout", "-f", target_br },
        });
        defer allocator.free(co_res.stdout);
        defer allocator.free(co_res.stderr);
    }
}

test "Git Bi-Directional Interop: round-trips commits, branches, merges, and multi-path trees via fast-export stream" {
    const gpa = std.testing.allocator;

    // 1. Build a multi-branch repository with a merge commit in `db1`
    var db1 = try RepoDb.initNew(gpa, "/tmp/git-interop-1");
    defer db1.deinit();

    try db1.editFile(0, "src/lib.zig", "pub const version = 1;\n// ANCHOR\npub const port = 8080;\n");
    try db1.editFile(0, "README.md", "# Project\n");
    _ = try db1.commitWorktree(0, "alice", "Initial project structure");

    _ = try db1.switchBranch(0, "feat");
    try db1.editFile(0, "src/lib.zig", "pub const version = 2;\n// ANCHOR\npub const port = 8080;\n");
    _ = try db1.commitWorktree(0, "bob", "Bump version on feat");

    _ = try db1.switchBranch(0, "main");
    try db1.editFile(0, "src/lib.zig", "pub const version = 1;\n// ANCHOR\npub const port = 9090;\n");
    _ = try db1.commitWorktree(0, "alice", "Update port on main");

    _ = try db1.mergeBranch(0, "feat", "alice", "Merge feat into main");

    // 2. Emit standard `git fast-export` stream from `db1`
    const stream = try emitFastExportStream(gpa, &db1);
    defer gpa.free(stream);

    // 3. Import the stream into a brand-new `db2`
    var db2 = try RepoDb.initNew(gpa, "/tmp/git-interop-2");
    defer db2.deinit();

    try importFastExportStream(gpa, &db2, stream);

    // 4. Verify `db2` has the exact same commits, branches, merge parent links, and merged file content!
    try std.testing.expectEqual(db1.commits.items.len, db2.commits.items.len);
    try std.testing.expectEqual(db1.branches.items.len, db2.branches.items.len);

    const main_br2 = db2.findBranchByName("main").?;
    const feat_br2 = db2.findBranchByName("feat").?;
    const main_head2 = db2.branches.items[main_br2].head_commit;
    try std.testing.expectEqual(@as(CommitId, 4), main_head2);
    try std.testing.expect(db2.commits.items[main_head2].parent2 != null);
    try std.testing.expectEqual(db2.branches.items[feat_br2].head_commit, db2.commits.items[main_head2].parent2.?);

    const merged_tree2 = db2.trees.items[db2.commits.items[main_head2].root_tree_id];
    const lib_hash2 = merged_tree2.getPathSum("src/lib.zig").?.getCleanHash().?;
    try std.testing.expectEqualStrings(
        "pub const version = 2;\n// ANCHOR\npub const port = 9090;\n",
        db2.getBlob(lib_hash2).?,
    );
}
