//! Single-File Transactional Repository Database (`RepoDb`).
//!
//! Unifies the three architectural pillars from `ARCHITECTURE.md`:
//! 1. **Pillar 1 (Per-Branch Working State & Multi-Worktree Isolation)**:
//!    - Eliminates the staging area (`index`), `stash`, and detached `HEAD`.
//!    - Auto-saves uncommitted working-tree state per `(WorktreeId, BranchId)` in `drafts`.
//!    - Closing a worktree (`closeWorktree`) preserves all drafts and undo history inside the
//!      main repository database (fixing Fossil's `.fslckout` data loss on `close`).
//! 2. **Pillar 2 (First-Class Conflicts via Formal Sum of Trees `B + C - A`)**:
//!    - Merges and rebases compute `threeWayMergeTrees` (`B + C - A`) + Pierce anchor-separated
//!      hunk lifting (`mergeTextAnchorDiff3`).
//!    - Never writes `<<<<<<<` conflict markers into the artifact store and never halts mid-merge.
//! 3. **Pillar 3 (Single-File Transactional Oplog & Storage)**:
//!    - Strictly append-only `artifacts`, `trees`, and `commits` tables.
//!    - Every mutating command records an `OplogEntry` before modifying `(branches, worktrees, drafts)`,
//!      enabling instant O(1) `undo` and `redo`.
//!    - Serializes and deserializes atomically to a single binary file (`<repo>.vcs`) with a
//!      `"ZIGVCS01"` header and full-file BLAKE3 integrity verification.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tree_sum = @import("../algebra/tree_sum.zig");
const diff3 = @import("../algebra/diff3_anchors.zig");
const delta = @import("delta.zig");
const paged_file = @import("paged_file.zig");

pub const ArtifactHash = tree_sum.ArtifactHash;
pub const ABSENT_HASH = tree_sum.ABSENT_HASH;
pub const PathSum = tree_sum.PathSum;
pub const FileMode = tree_sum.FileMode;
pub const TreeManifest = tree_sum.TreeManifest;

pub const TreeId = u32;
pub const CommitId = u32;
pub const BranchId = u32;
pub const WorktreeId = u32;

pub const MAGIC_HEADER = "ZIGVCS01";
pub const MAGIC_HEADER_V2 = "ZIGVCS02";
pub const TREE_DELTA_FLAG: u32 = 0x8000_0000;

pub const ArtifactBlob = struct {
    hash: ArtifactHash,
    bytes: []u8,
};

pub const CommitRecord = struct {
    id: CommitId,
    parent1: ?CommitId,
    parent2: ?CommitId,
    root_tree_id: TreeId,
    author: []u8,
    message: []u8,
    timestamp_sec: i64 = 0,
    tz_offset_min: i16 = 0,

    pub fn deinit(self: *CommitRecord, allocator: Allocator) void {
        allocator.free(self.author);
        allocator.free(self.message);
    }
};

const PosixTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(timer: *const i64, result: *PosixTm) ?*PosixTm;

/// Returns the current real-world Unix epoch timestamp in seconds via `clock_gettime(.REALTIME)`.
pub fn currentUnixTimestampSec() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
        .SUCCESS => return @intCast(ts.sec),
        else => return 0,
    }
}

/// Returns the local timezone offset (in minutes east of UTC, e.g. `-480` for `-0800` PST)
/// for `timestamp_sec` via `localtime_r` on Darwin/libc targets (or `0` on freestanding targets).
pub fn localTzOffsetMinForTimestamp(timestamp_sec: i64) i16 {
    const builtin = @import("builtin");
    if (builtin.os.tag.isDarwin() or builtin.link_libc) {
        var t: i64 = timestamp_sec;
        var tm: PosixTm = undefined;
        if (localtime_r(&t, &tm) != null) {
            const off_min = @divTrunc(tm.tm_gmtoff, 60);
            return @intCast(std.math.clamp(off_min, -14 * 60, 14 * 60));
        }
    }
    return 0;
}

/// Returns the current local timezone offset in minutes east of UTC (e.g. `-480` for `-0800`).
pub fn currentLocalTzOffsetMin() i16 {
    return localTzOffsetMinForTimestamp(currentUnixTimestampSec());
}

/// Formats a timezone offset in minutes east of UTC as `±HHMM` (e.g., `"-0800"`, `"+0000"`, `"+0530"`).
pub fn formatTzOffsetBuf(tz_offset_min: i16, buf: *[5]u8) []const u8 {
    const sign: u8 = if (tz_offset_min < 0) '-' else '+';
    const abs_min: u16 = @abs(tz_offset_min);
    const hours: u16 = abs_min / 60;
    const mins: u16 = abs_min % 60;
    return std.fmt.bufPrint(buf, "{c}{d:0>2}{d:0>2}", .{ sign, @min(hours, 99), mins }) catch "+0000";
}

/// Parses an ISO-8601 / Git timezone offset string (`"-0800"`, `"+0530"`, `"-08:00"`, `"Z"`, `"UTC"`)
/// into minutes east of UTC (`i16`).
pub fn parseTzOffsetMin(s_raw: []const u8) ?i16 {
    const s = std.mem.trim(u8, s_raw, " \t\r\n");
    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "Z") or std.mem.eql(u8, s, "UTC") or std.mem.eql(u8, s, "GMT")) {
        return 0;
    }
    if (s[0] != '+' and s[0] != '-') return null;
    const sign: i16 = if (s[0] == '-') -1 else 1;
    const rest = s[1..];
    if (rest.len == 4) {
        const hh = std.fmt.parseInt(i16, rest[0..2], 10) catch return null;
        const mm = std.fmt.parseInt(i16, rest[2..4], 10) catch return null;
        if (hh > 14 or mm >= 60) return null;
        return sign * (hh * 60 + mm);
    } else if (rest.len == 5 and rest[2] == ':') {
        const hh = std.fmt.parseInt(i16, rest[0..2], 10) catch return null;
        const mm = std.fmt.parseInt(i16, rest[3..5], 10) catch return null;
        if (hh > 14 or mm >= 60) return null;
        return sign * (hh * 60 + mm);
    }
    return null;
}

/// Formats a Unix epoch timestamp (in seconds) with `tz_offset_min` (in minutes east of UTC)
/// as `YYYY-MM-DD HH:MM:SS ±HHMM` (25 bytes, e.g. `"2026-11-10 17:14:43 -0800"`).
pub fn formatTimestampWithOffsetBuf(timestamp_sec: i64, tz_offset_min: i16, buf: *[25]u8) []const u8 {
    const adjusted: i64 = timestamp_sec + @as(i64, tz_offset_min) * 60;
    const secs: u64 = if (adjusted > 0) @intCast(adjusted) else 0;
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var tz_buf: [5]u8 = undefined;
    const tz_str = formatTzOffsetBuf(tz_offset_min, &tz_buf);
    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}",
        .{
            year_day.year,
            month_day.month.numeric(),
            @as(u8, month_day.day_index) + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
            tz_str,
        },
    ) catch "1970-01-01 00:00:00 +0000";
}

/// Formats a Unix epoch timestamp (in seconds) as `YYYY-MM-DD HH:MM:SS UTC`.
pub fn formatTimestampUtcBuf(timestamp_sec: i64, buf: *[23]u8) []const u8 {
    const secs: u64 = if (timestamp_sec > 0) @intCast(timestamp_sec) else 0;
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC",
        .{
            year_day.year,
            month_day.month.numeric(),
            @as(u8, month_day.day_index) + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        },
    ) catch "1970-01-01 00:00:00 UTC";
}

pub const BranchRecord = struct {
    id: BranchId,
    name: []u8,
    head_commit: CommitId,

    pub fn clone(self: BranchRecord, allocator: Allocator) !BranchRecord {
        return .{
            .id = self.id,
            .name = try allocator.dupe(u8, self.name),
            .head_commit = self.head_commit,
        };
    }

    pub fn deinit(self: *BranchRecord, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

pub const WorktreeRecord = struct {
    id: WorktreeId,
    name: []u8,
    fs_path: []u8,
    branch_id: BranchId,
    working_tree_id: TreeId,
    is_dirty: bool,
    is_open: bool,

    pub fn clone(self: WorktreeRecord, allocator: Allocator) !WorktreeRecord {
        const name_dup = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name_dup);
        const fs_path_dup = try allocator.dupe(u8, self.fs_path);
        return .{
            .id = self.id,
            .name = name_dup,
            .fs_path = fs_path_dup,
            .branch_id = self.branch_id,
            .working_tree_id = self.working_tree_id,
            .is_dirty = self.is_dirty,
            .is_open = self.is_open,
        };
    }

    pub fn deinit(self: *WorktreeRecord, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.fs_path);
    }
};

pub const DraftEntry = struct {
    worktree_id: WorktreeId,
    branch_id: BranchId,
    tree_id: TreeId,
};

pub const TagRecord = struct {
    name: []u8,
    target_commit: CommitId,

    pub fn clone(self: TagRecord, allocator: Allocator) !TagRecord {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .target_commit = self.target_commit,
        };
    }

    pub fn deinit(self: *TagRecord, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

pub const RemoteRecord = struct {
    name: []u8,
    path: []u8,

    pub fn clone(self: RemoteRecord, allocator: Allocator) !RemoteRecord {
        const name_dup = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name_dup);
        const path_dup = try allocator.dupe(u8, self.path);
        return .{
            .name = name_dup,
            .path = path_dup,
        };
    }

    pub fn deinit(self: *RemoteRecord, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub const ResolveStrategy = enum {
    ours,
    theirs,
    base,
};

pub const FsckReport = struct {
    blobs_verified: usize,
    trees_verified: usize,
    commits_verified: usize,
    branches_verified: usize,
    worktrees_verified: usize,
    oplog_verified: usize,
};

pub const StatCacheEntry = struct {
    worktree_id: WorktreeId,
    path: []u8,
    mtime_ns: i64,
    size_bytes: u64,
    hash: ArtifactHash,
    /// Racy-stat-cache guard: set to `false` when freshly materialized to disk so the first
    /// subsequent scan verifies BLAKE3 content before trusting `(mtime_ns, size_bytes)`.
    verified_stable: bool = false,

    pub fn deinit(self: *StatCacheEntry, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

pub const OplogEntry = struct {
    command_desc: []u8,
    branches: std.ArrayList(BranchRecord) = .empty,
    worktrees: std.ArrayList(WorktreeRecord) = .empty,
    drafts: std.ArrayList(DraftEntry) = .empty,
    tags: std.ArrayList(TagRecord) = .empty,
    remotes: std.ArrayList(RemoteRecord) = .empty,

    pub fn deinit(self: *OplogEntry, allocator: Allocator) void {
        allocator.free(self.command_desc);
        for (self.branches.items) |*b| b.deinit(allocator);
        self.branches.deinit(allocator);
        for (self.worktrees.items) |*w| w.deinit(allocator);
        self.worktrees.deinit(allocator);
        self.drafts.deinit(allocator);
        for (self.tags.items) |*t| t.deinit(allocator);
        self.tags.deinit(allocator);
        for (self.remotes.items) |*r| r.deinit(allocator);
        self.remotes.deinit(allocator);
    }
};

pub const RepoDb = struct {
    allocator: Allocator,

    /// Enduring Append-Only Tables
    blobs: std.ArrayList(ArtifactBlob) = .empty,
    blob_index: std.AutoHashMapUnmanaged(ArtifactHash, u32) = .empty,
    trees: std.ArrayList(TreeManifest) = .empty,
    tree_hashes: std.ArrayList(ArtifactHash) = .empty,
    tree_index: std.AutoHashMapUnmanaged(ArtifactHash, TreeId) = .empty,
    commits: std.ArrayList(CommitRecord) = .empty,

    /// Transactional MVCC View Tables
    branches: std.ArrayList(BranchRecord) = .empty,
    worktrees: std.ArrayList(WorktreeRecord) = .empty,
    drafts: std.ArrayList(DraftEntry) = .empty,
    tags: std.ArrayList(TagRecord) = .empty,
    remotes: std.ArrayList(RemoteRecord) = .empty,
    configs: std.ArrayList(RemoteRecord) = .empty,
    stat_cache: std.ArrayList(StatCacheEntry) = .empty,

    /// Transactional Oplog & Redo Stack
    oplog: std.ArrayList(OplogEntry) = .empty,
    redo_stack: std.ArrayList(OplogEntry) = .empty,

    /// Initialize a fresh single-file repository with an empty root commit `c0`,
    /// default branch `main` (`br0`), and primary worktree `wt0` at `default_wt_path`.
    pub fn initNew(allocator: Allocator, default_wt_path: []const u8) !RepoDb {
        var db = RepoDb{ .allocator = allocator };
        errdefer db.deinit();

        const empty_tree: TreeManifest = .{};
        const root_tree_id = try db.internTreeOwned(empty_tree);

        _ = try db.appendCommit(null, null, root_tree_id, "system", "Initial empty root commit");

        {
            const main_name = try allocator.dupe(u8, "main");
            errdefer allocator.free(main_name);
            try db.branches.append(allocator, .{
                .id = 0,
                .name = main_name,
                .head_commit = 0,
            });
        }

        {
            const wt_name = try allocator.dupe(u8, "main-wt");
            errdefer allocator.free(wt_name);
            const wt_path = try allocator.dupe(u8, default_wt_path);
            errdefer allocator.free(wt_path);
            try db.worktrees.append(allocator, .{
                .id = 0,
                .name = wt_name,
                .fs_path = wt_path,
                .branch_id = 0,
                .working_tree_id = root_tree_id,
                .is_dirty = false,
                .is_open = true,
            });
        }

        return db;
    }

    pub fn deinit(self: *RepoDb) void {
        for (self.blobs.items) |b| self.allocator.free(b.bytes);
        self.blobs.deinit(self.allocator);
        self.blob_index.deinit(self.allocator);

        for (self.trees.items) |*t| t.deinit(self.allocator);
        self.trees.deinit(self.allocator);
        self.tree_hashes.deinit(self.allocator);
        self.tree_index.deinit(self.allocator);

        for (self.commits.items) |*c| c.deinit(self.allocator);
        self.commits.deinit(self.allocator);

        for (self.branches.items) |*b| b.deinit(self.allocator);
        self.branches.deinit(self.allocator);

        for (self.worktrees.items) |*w| w.deinit(self.allocator);
        self.worktrees.deinit(self.allocator);

        self.drafts.deinit(self.allocator);

        for (self.tags.items) |*t| t.deinit(self.allocator);
        self.tags.deinit(self.allocator);

        for (self.remotes.items) |*r| r.deinit(self.allocator);
        self.remotes.deinit(self.allocator);

        for (self.configs.items) |*cfg| cfg.deinit(self.allocator);
        self.configs.deinit(self.allocator);

        for (self.stat_cache.items) |*sc| sc.deinit(self.allocator);
        self.stat_cache.deinit(self.allocator);

        for (self.oplog.items) |*op| op.deinit(self.allocator);
        self.oplog.deinit(self.allocator);

        for (self.redo_stack.items) |*op| op.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }

    // ========================================================================
    // 1. Enduring Append-Only Artifact Store Operations
    // ========================================================================

    pub fn putBlob(self: *RepoDb, bytes: []const u8) !ArtifactHash {
        const hash = tree_sum.computeBlake3(bytes);
        if (self.blob_index.contains(hash)) return hash;
        try self.blobs.ensureUnusedCapacity(self.allocator, 1);
        try self.blob_index.ensureUnusedCapacity(self.allocator, 1);
        const duped = try self.allocator.dupe(u8, bytes);
        const idx: u32 = @intCast(self.blobs.items.len);
        self.blobs.appendAssumeCapacity(.{
            .hash = hash,
            .bytes = duped,
        });
        self.blob_index.putAssumeCapacity(hash, idx);
        return hash;
    }

    pub fn getBlob(self: *const RepoDb, hash: ArtifactHash) ?[]const u8 {
        if (tree_sum.hashEql(hash, ABSENT_HASH)) return "";
        if (self.blob_index.get(hash)) |idx| {
            if (idx < self.blobs.items.len and tree_sum.hashEql(self.blobs.items[idx].hash, hash)) {
                return self.blobs.items[idx].bytes;
            }
        }
        for (self.blobs.items) |b| {
            if (tree_sum.hashEql(b.hash, hash)) return b.bytes;
        }
        return null;
    }

    fn ensureTreeIndexPopulated(self: *RepoDb) !void {
        if (self.tree_hashes.items.len >= self.trees.items.len) return;
        const start = self.tree_hashes.items.len;
        const needed = self.trees.items.len - start;
        try self.tree_hashes.ensureUnusedCapacity(self.allocator, needed);
        try self.tree_index.ensureUnusedCapacity(self.allocator, @intCast(needed));
        for (start..self.trees.items.len) |idx| {
            const h = self.trees.items[idx].computeTreeHash();
            self.tree_hashes.appendAssumeCapacity(h);
            self.tree_index.putAssumeCapacity(h, @intCast(idx));
        }
    }

    pub fn internTreeOwned(self: *RepoDb, manifest_in: TreeManifest) !TreeId {
        var manifest = manifest_in;
        errdefer manifest.deinit(self.allocator);
        try self.ensureTreeIndexPopulated();
        manifest.sortEntries();
        const target_hash = manifest.computeTreeHash();
        if (self.tree_index.get(target_hash)) |existing_tid| {
            manifest.deinit(self.allocator);
            return existing_tid;
        }
        try self.trees.ensureUnusedCapacity(self.allocator, 1);
        try self.tree_hashes.ensureUnusedCapacity(self.allocator, 1);
        try self.tree_index.ensureUnusedCapacity(self.allocator, 1);
        const tid: TreeId = @intCast(self.trees.items.len);
        self.trees.appendAssumeCapacity(manifest);
        self.tree_hashes.appendAssumeCapacity(target_hash);
        self.tree_index.putAssumeCapacity(target_hash, tid);
        return tid;
    }

    fn appendCommit(
        self: *RepoDb,
        parent1: ?CommitId,
        parent2: ?CommitId,
        root_tree_id: TreeId,
        author: []const u8,
        message: []const u8,
    ) !CommitId {
        const cid: CommitId = @intCast(self.commits.items.len);
        var ts: i64 = if (cid == 0) 0 else currentUnixTimestampSec();
        if (cid > 0) {
            if (parent1) |p1| {
                if (p1 < self.commits.items.len) {
                    ts = @max(ts, self.commits.items[p1].timestamp_sec);
                }
            }
            if (parent2) |p2| {
                if (p2 < self.commits.items.len) {
                    ts = @max(ts, self.commits.items[p2].timestamp_sec);
                }
            }
        }
        const tz_min: i16 = if (cid == 0) 0 else localTzOffsetMinForTimestamp(ts);
        return self.appendCommitWithTimestampAndTz(parent1, parent2, root_tree_id, author, message, ts, tz_min);
    }

    pub fn appendCommitWithTimestamp(
        self: *RepoDb,
        parent1: ?CommitId,
        parent2: ?CommitId,
        root_tree_id: TreeId,
        author: []const u8,
        message: []const u8,
        timestamp_sec: i64,
    ) !CommitId {
        const cid: CommitId = @intCast(self.commits.items.len);
        const tz_min: i16 = if (cid == 0 or timestamp_sec <= 0) 0 else localTzOffsetMinForTimestamp(timestamp_sec);
        return self.appendCommitWithTimestampAndTz(parent1, parent2, root_tree_id, author, message, timestamp_sec, tz_min);
    }

    pub fn appendCommitWithTimestampAndTz(
        self: *RepoDb,
        parent1: ?CommitId,
        parent2: ?CommitId,
        root_tree_id: TreeId,
        author: []const u8,
        message: []const u8,
        timestamp_sec: i64,
        tz_offset_min: i16,
    ) !CommitId {
        const cid: CommitId = @intCast(self.commits.items.len);
        const author_dup = try self.allocator.dupe(u8, author);
        errdefer self.allocator.free(author_dup);
        const message_dup = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(message_dup);
        try self.commits.append(self.allocator, .{
            .id = cid,
            .parent1 = parent1,
            .parent2 = parent2,
            .root_tree_id = root_tree_id,
            .author = author_dup,
            .message = message_dup,
            .timestamp_sec = timestamp_sec,
            .tz_offset_min = tz_offset_min,
        });
        return cid;
    }

    /// Compute a deterministic BLAKE3 structural hash for commit `cid` across its causal parent
    /// structural hashes, `root_tree_id` content hash, `author`, and `message`.
    /// Enables content-addressed commit negotiation across distributed clones (`fetch`, `pull`, `push`).
    pub fn computeCommitStructuralHash(self: *const RepoDb, cid: CommitId) ArtifactHash {
        if (cid == 0 or cid >= self.commits.items.len) return ABSENT_HASH;
        const c = self.commits.items[cid];
        const p1_hash = if (c.parent1) |p1| self.computeCommitStructuralHash(p1) else ABSENT_HASH;
        const p2_hash = if (c.parent2) |p2| self.computeCommitStructuralHash(p2) else ABSENT_HASH;
        const tree_hash = if (c.root_tree_id < self.tree_hashes.items.len)
            self.tree_hashes.items[c.root_tree_id]
        else
            self.trees.items[c.root_tree_id].computeTreeHash();

        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update("ZIGVCS_COMMIT_V1\n");
        hasher.update(&p1_hash);
        hasher.update(&p2_hash);
        hasher.update(&tree_hash);

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(c.author.len), .little);
        hasher.update(&len_buf);
        hasher.update(c.author);

        std.mem.writeInt(u32, &len_buf, @intCast(c.message.len), .little);
        hasher.update(&len_buf);
        hasher.update(c.message);

        var out: ArtifactHash = undefined;
        hasher.final(&out);
        return out;
    }

    // ========================================================================
    // 2. Oplog Snapshot & Atomic Undo / Redo
    // ========================================================================

    fn captureSnapshot(self: *const RepoDb, desc: []const u8) !OplogEntry {
        var entry: OplogEntry = .{
            .command_desc = try self.allocator.dupe(u8, desc),
        };
        errdefer entry.deinit(self.allocator);

        for (self.branches.items) |b| {
            var b_clone = try b.clone(self.allocator);
            errdefer b_clone.deinit(self.allocator);
            try entry.branches.append(self.allocator, b_clone);
        }
        for (self.worktrees.items) |w| {
            var w_clone = try w.clone(self.allocator);
            errdefer w_clone.deinit(self.allocator);
            try entry.worktrees.append(self.allocator, w_clone);
        }
        try entry.drafts.appendSlice(self.allocator, self.drafts.items);
        for (self.tags.items) |t| {
            var t_clone = try t.clone(self.allocator);
            errdefer t_clone.deinit(self.allocator);
            try entry.tags.append(self.allocator, t_clone);
        }
        for (self.remotes.items) |r| {
            var r_clone = try r.clone(self.allocator);
            errdefer r_clone.deinit(self.allocator);
            try entry.remotes.append(self.allocator, r_clone);
        }
        return entry;
    }

    fn clearRedoStack(self: *RepoDb) void {
        for (self.redo_stack.items) |*r| r.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();
    }

    fn recordOplog(self: *RepoDb, desc: []const u8) !void {
        var snap = try self.captureSnapshot(desc);
        errdefer snap.deinit(self.allocator);
        try self.oplog.append(self.allocator, snap);
    }

    fn abortLastOplog(self: *RepoDb) void {
        if (self.oplog.pop()) |last| {
            var mut_last = last;
            mut_last.deinit(self.allocator);
        }
    }

    fn restoreFromSnapshot(self: *RepoDb, snap: OplogEntry) !void {
        var new_branches: std.ArrayList(BranchRecord) = .empty;
        errdefer {
            for (new_branches.items) |*b| b.deinit(self.allocator);
            new_branches.deinit(self.allocator);
        }
        for (snap.branches.items) |b| {
            var b_clone = try b.clone(self.allocator);
            errdefer b_clone.deinit(self.allocator);
            try new_branches.append(self.allocator, b_clone);
        }

        var new_worktrees: std.ArrayList(WorktreeRecord) = .empty;
        errdefer {
            for (new_worktrees.items) |*w| w.deinit(self.allocator);
            new_worktrees.deinit(self.allocator);
        }
        for (snap.worktrees.items) |w| {
            var w_clone = try w.clone(self.allocator);
            errdefer w_clone.deinit(self.allocator);
            try new_worktrees.append(self.allocator, w_clone);
        }

        var new_drafts: std.ArrayList(DraftEntry) = .empty;
        errdefer new_drafts.deinit(self.allocator);
        try new_drafts.appendSlice(self.allocator, snap.drafts.items);

        var new_tags: std.ArrayList(TagRecord) = .empty;
        errdefer {
            for (new_tags.items) |*t| t.deinit(self.allocator);
            new_tags.deinit(self.allocator);
        }
        for (snap.tags.items) |t| {
            var t_clone = try t.clone(self.allocator);
            errdefer t_clone.deinit(self.allocator);
            try new_tags.append(self.allocator, t_clone);
        }

        var new_remotes: std.ArrayList(RemoteRecord) = .empty;
        errdefer {
            for (new_remotes.items) |*r| r.deinit(self.allocator);
            new_remotes.deinit(self.allocator);
        }
        for (snap.remotes.items) |r| {
            var r_clone = try r.clone(self.allocator);
            errdefer r_clone.deinit(self.allocator);
            try new_remotes.append(self.allocator, r_clone);
        }

        // Swap in atomically now that all allocations have succeeded
        for (self.branches.items) |*b| b.deinit(self.allocator);
        self.branches.deinit(self.allocator);
        self.branches = new_branches;

        for (self.worktrees.items) |*w| w.deinit(self.allocator);
        self.worktrees.deinit(self.allocator);
        self.worktrees = new_worktrees;

        self.drafts.deinit(self.allocator);
        self.drafts = new_drafts;

        for (self.tags.items) |*t| t.deinit(self.allocator);
        self.tags.deinit(self.allocator);
        self.tags = new_tags;

        for (self.remotes.items) |*r| r.deinit(self.allocator);
        self.remotes.deinit(self.allocator);
        self.remotes = new_remotes;
    }

    /// Atomic O(1) Undo: restores `(branches, worktrees, drafts)` from the top of `oplog`
    /// while keeping all `blobs`, `trees`, and `commits` strictly monotonic!
    pub fn undo(self: *RepoDb) !bool {
        if (self.oplog.items.len == 0) return false;
        const top_idx = self.oplog.items.len - 1;
        const target_snap = self.oplog.items[top_idx];

        var redo_snap = try self.captureSnapshot(target_snap.command_desc);
        var redo_pushed = false;
        errdefer if (!redo_pushed) redo_snap.deinit(self.allocator);

        try self.redo_stack.append(self.allocator, redo_snap);
        redo_pushed = true;
        errdefer {
            var popped = self.redo_stack.pop().?;
            popped.deinit(self.allocator);
        }

        try self.restoreFromSnapshot(target_snap);

        var last = self.oplog.pop().?;
        last.deinit(self.allocator);
        return true;
    }

    /// Atomic O(1) Redo: re-applies the most recently undone state transition.
    pub fn redo(self: *RepoDb) !bool {
        if (self.redo_stack.items.len == 0) return false;
        const top_idx = self.redo_stack.items.len - 1;
        const target_snap = self.redo_stack.items[top_idx];

        var undo_snap = try self.captureSnapshot(target_snap.command_desc);
        var undo_pushed = false;
        errdefer if (!undo_pushed) undo_snap.deinit(self.allocator);

        try self.oplog.append(self.allocator, undo_snap);
        undo_pushed = true;
        errdefer {
            var popped = self.oplog.pop().?;
            popped.deinit(self.allocator);
        }

        try self.restoreFromSnapshot(target_snap);

        var next_snap = self.redo_stack.pop().?;
        next_snap.deinit(self.allocator);
        return true;
    }

    // ========================================================================
    // 3. Lookups & Draft Table Helpers
    // ========================================================================

    pub fn findBranchByName(self: *const RepoDb, name: []const u8) ?BranchId {
        for (self.branches.items) |b| {
            if (std.mem.eql(u8, b.name, name)) return b.id;
        }
        return null;
    }

    pub fn getOrCreateBranch(self: *RepoDb, name: []const u8, default_head: CommitId) !BranchId {
        if (self.findBranchByName(name)) |bid| return bid;
        const bid: BranchId = @intCast(self.branches.items.len);
        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);
        try self.branches.append(self.allocator, .{
            .id = bid,
            .name = name_dup,
            .head_commit = default_head,
        });
        return bid;
    }

    pub fn getDraft(self: *const RepoDb, wt_id: WorktreeId, br_id: BranchId) ?TreeId {
        for (self.drafts.items) |d| {
            if (d.worktree_id == wt_id and d.branch_id == br_id) return d.tree_id;
        }
        return null;
    }

    fn setDraft(self: *RepoDb, wt_id: WorktreeId, br_id: BranchId, tree_id: ?TreeId) !void {
        for (self.drafts.items, 0..) |*d, idx| {
            if (d.worktree_id == wt_id and d.branch_id == br_id) {
                if (tree_id) |tid| {
                    d.tree_id = tid;
                } else {
                    _ = self.drafts.orderedRemove(idx);
                }
                return;
            }
        }
        if (tree_id) |tid| {
            try self.drafts.append(self.allocator, .{
                .worktree_id = wt_id,
                .branch_id = br_id,
                .tree_id = tid,
            });
        }
    }

    fn statCacheOrder(a_wt: WorktreeId, a_path: []const u8, b_wt: WorktreeId, b_path: []const u8) std.math.Order {
        if (a_wt < b_wt) return .lt;
        if (a_wt > b_wt) return .gt;
        return std.mem.order(u8, a_path, b_path);
    }

    fn findStatCacheIndex(self: *const RepoDb, wt_id: WorktreeId, path: []const u8) struct { found: bool, index: usize } {
        var lo: usize = 0;
        var hi: usize = self.stat_cache.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const item = self.stat_cache.items[mid];
            switch (statCacheOrder(item.worktree_id, item.path, wt_id, path)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return .{ .found = true, .index = mid },
            }
        }
        return .{ .found = false, .index = lo };
    }

    pub fn getStatCache(self: *const RepoDb, wt_id: WorktreeId, path: []const u8) ?StatCacheEntry {
        const loc = self.findStatCacheIndex(wt_id, path);
        if (loc.found) return self.stat_cache.items[loc.index];
        return null;
    }

    pub fn upsertStatCache(
        self: *RepoDb,
        wt_id: WorktreeId,
        path: []const u8,
        mtime_ns: i64,
        size_bytes: u64,
        hash: ArtifactHash,
        verified_stable: bool,
    ) !void {
        const loc = self.findStatCacheIndex(wt_id, path);
        if (loc.found) {
            var sc = &self.stat_cache.items[loc.index];
            sc.mtime_ns = mtime_ns;
            sc.size_bytes = size_bytes;
            sc.hash = hash;
            sc.verified_stable = verified_stable;
            return;
        }
        const path_dup = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_dup);
        try self.stat_cache.insert(self.allocator, loc.index, .{
            .worktree_id = wt_id,
            .path = path_dup,
            .mtime_ns = mtime_ns,
            .size_bytes = size_bytes,
            .hash = hash,
            .verified_stable = verified_stable,
        });
    }

    pub fn removeStatCache(self: *RepoDb, wt_id: WorktreeId, path: []const u8) void {
        const loc = self.findStatCacheIndex(wt_id, path);
        if (loc.found) {
            self.stat_cache.items[loc.index].deinit(self.allocator);
            _ = self.stat_cache.orderedRemove(loc.index);
        }
    }

    /// Atomically apply a scanned working-tree manifest (`new_tid`) to worktree `wt_id`.
    /// Records an `oplog` entry if and only if the working tree actually changed!
    pub fn applyWorkingTreeSync(self: *RepoDb, wt_id: WorktreeId, new_tid: TreeId) !bool {
        const old_tid = self.worktrees.items[wt_id].working_tree_id;
        if (old_tid == new_tid) return false;

        try self.recordOplog("sync-worktree");
        self.clearRedoStack();
        const wt = &self.worktrees.items[wt_id];
        const head_cid = self.branches.items[wt.branch_id].head_commit;
        const head_tid = self.commits.items[head_cid].root_tree_id;

        wt.working_tree_id = new_tid;
        wt.is_dirty = (new_tid != head_tid);
        return true;
    }

    // ========================================================================
    // 4. Verified VCS State Machine Transitions
    // ========================================================================

    /// Edit or create a file at `path` inside worktree `wt_id`.
    pub fn editFile(self: *RepoDb, wt_id: WorktreeId, path: []const u8, content: []const u8) !void {
        return self.editFileWithMode(wt_id, path, content, .regular);
    }

    /// Edit or create a file at `path` with an explicit `FileMode` (`regular`, `executable`, `symlink`).
    pub fn editFileWithMode(
        self: *RepoDb,
        wt_id: WorktreeId,
        path: []const u8,
        content: []const u8,
        mode: FileMode,
    ) !void {
        const hash = try self.putBlob(content);
        const cur_tid = self.worktrees.items[wt_id].working_tree_id;
        var manifest = try self.trees.items[cur_tid].clone(self.allocator);
        var manifest_owned = true;
        errdefer if (manifest_owned) manifest.deinit(self.allocator);

        try manifest.setCleanFileWithMode(self.allocator, path, hash, mode);
        manifest_owned = false;
        const new_tid = try self.internTreeOwned(manifest);

        try self.recordOplog("edit");
        self.clearRedoStack();
        const wt = &self.worktrees.items[wt_id];
        wt.working_tree_id = new_tid;
        wt.is_dirty = true;
    }

    /// Delete a file at `path` inside worktree `wt_id`.
    pub fn deleteFile(self: *RepoDb, wt_id: WorktreeId, path: []const u8) !void {
        const cur_tid = self.worktrees.items[wt_id].working_tree_id;
        var manifest = try self.trees.items[cur_tid].clone(self.allocator);
        var manifest_owned = true;
        errdefer if (manifest_owned) manifest.deinit(self.allocator);

        manifest.removePath(self.allocator, path);
        manifest_owned = false;
        const new_tid = try self.internTreeOwned(manifest);

        try self.recordOplog("delete");
        self.clearRedoStack();
        const wt = &self.worktrees.items[wt_id];
        wt.working_tree_id = new_tid;
        wt.is_dirty = true;
    }

    /// Commit a new `new_head_tid` from `wt_id` onto `br_id` while automatically updating or
    /// algebraically rebasing any *other* worktree (`wt_other != wt_id`) or shelved draft on `br_id`.
    fn finalizeWorktreeCommitOnBranch(
        self: *RepoDb,
        wt_id: WorktreeId,
        br_id: BranchId,
        old_head_cid: CommitId,
        parent2_cid: ?CommitId,
        new_head_tid: TreeId,
        author: []const u8,
        message: []const u8,
        oplog_desc: []const u8,
    ) !CommitId {
        const old_head_tid = self.commits.items[old_head_cid].root_tree_id;

        var has_other_on_branch = false;
        for (self.worktrees.items) |wt| {
            if (wt.id != wt_id and wt.branch_id == br_id) {
                has_other_on_branch = true;
                break;
            }
        }
        if (!has_other_on_branch) {
            for (self.drafts.items) |d| {
                if (d.worktree_id != wt_id and d.branch_id == br_id) {
                    has_other_on_branch = true;
                    break;
                }
            }
        }

        var other_wt_trees: ?[]TreeId = null;
        defer if (other_wt_trees) |s| self.allocator.free(s);
        var other_draft_trees: ?[]TreeId = null;
        defer if (other_draft_trees) |s| self.allocator.free(s);

        if (has_other_on_branch) {
            const wt_slice = try self.allocator.alloc(TreeId, self.worktrees.items.len);
            other_wt_trees = wt_slice;
            for (self.worktrees.items, 0..) |wt, idx| {
                if (wt.id != wt_id and wt.branch_id == br_id) {
                    if (!wt.is_dirty) {
                        wt_slice[idx] = new_head_tid;
                    } else {
                        wt_slice[idx] = try self.mergeTreeIds(old_head_tid, wt.working_tree_id, new_head_tid);
                    }
                } else {
                    wt_slice[idx] = wt.working_tree_id;
                }
            }

            const draft_slice = try self.allocator.alloc(TreeId, self.drafts.items.len);
            other_draft_trees = draft_slice;
            for (self.drafts.items, 0..) |d, idx| {
                if (d.worktree_id != wt_id and d.branch_id == br_id) {
                    draft_slice[idx] = try self.mergeTreeIds(old_head_tid, d.tree_id, new_head_tid);
                } else {
                    draft_slice[idx] = d.tree_id;
                }
            }
        }

        try self.recordOplog(oplog_desc);
        errdefer self.abortLastOplog();

        const new_cid = try self.appendCommit(
            old_head_cid,
            parent2_cid,
            new_head_tid,
            author,
            message,
        );

        self.branches.items[br_id].head_commit = new_cid;
        self.worktrees.items[wt_id].working_tree_id = new_head_tid;
        self.worktrees.items[wt_id].is_dirty = false;
        try self.setDraft(wt_id, br_id, null);

        if (other_wt_trees) |wt_slice| {
            for (self.worktrees.items, 0..) |*wt, idx| {
                if (wt.id != wt_id and wt.branch_id == br_id) {
                    wt.working_tree_id = wt_slice[idx];
                }
            }
        }
        if (other_draft_trees) |draft_slice| {
            for (self.drafts.items, 0..) |*d, idx| {
                if (d.worktree_id != wt_id and d.branch_id == br_id) {
                    d.tree_id = draft_slice[idx];
                }
            }
        }

        self.clearRedoStack();
        return new_cid;
    }

    /// Commit the working tree of `wt_id` to its checked-out branch.
    pub fn commitWorktree(
        self: *RepoDb,
        wt_id: WorktreeId,
        author: []const u8,
        message: []const u8,
    ) !CommitId {
        const wt = self.worktrees.items[wt_id];
        const br_id = wt.branch_id;
        const parent_cid = self.branches.items[br_id].head_commit;
        return self.finalizeWorktreeCommitOnBranch(
            wt_id,
            br_id,
            parent_cid,
            null,
            wt.working_tree_id,
            author,
            message,
            "commit",
        );
    }

    /// Safe Branch Switch (Pillar 1):
    /// Automatically shelves any dirty working tree into `drafts[wt_id][old_branch]` and
    /// restores `drafts[wt_id][target_branch]` (or the branch's head commit tree if clean).
    pub fn switchBranch(self: *RepoDb, wt_id: WorktreeId, target_branch_name: []const u8) !BranchId {
        try self.drafts.ensureUnusedCapacity(self.allocator, 1);
        try self.recordOplog("switch");
        errdefer self.abortLastOplog();

        const old_br = self.worktrees.items[wt_id].branch_id;
        const current_head = self.branches.items[old_br].head_commit;
        const target_br = try self.getOrCreateBranch(target_branch_name, current_head);

        if (old_br == target_br) {
            self.clearRedoStack();
            return target_br;
        }

        const wt_old = self.worktrees.items[wt_id];
        if (wt_old.is_dirty) {
            try self.setDraft(wt_id, old_br, wt_old.working_tree_id);
        } else {
            try self.setDraft(wt_id, old_br, null);
        }

        if (self.getDraft(wt_id, target_br)) |saved_draft_tid| {
            self.worktrees.items[wt_id].branch_id = target_br;
            self.worktrees.items[wt_id].working_tree_id = saved_draft_tid;
            self.worktrees.items[wt_id].is_dirty = true;
        } else {
            const head_cid = self.branches.items[target_br].head_commit;
            const head_tree_id = self.commits.items[head_cid].root_tree_id;
            self.worktrees.items[wt_id].branch_id = target_br;
            self.worktrees.items[wt_id].working_tree_id = head_tree_id;
            self.worktrees.items[wt_id].is_dirty = false;
        }
        self.clearRedoStack();
        return target_br;
    }

    /// Find Lowest Common Ancestor (LCA) commit in the commit DAG.
    pub fn findLowestCommonAncestor(self: *const RepoDb, c1: CommitId, c2: CommitId) CommitId {
        if (c1 == c2) return c1;
        var anc1 = std.AutoHashMap(CommitId, void).init(self.allocator);
        defer anc1.deinit();

        var queue: std.ArrayList(CommitId) = .empty;
        defer queue.deinit(self.allocator);

        queue.append(self.allocator, c1) catch return 0;
        while (queue.items.len > 0) {
            const curr = queue.pop().?;
            if (anc1.contains(curr)) continue;
            anc1.put(curr, {}) catch return 0;
            const rec = self.commits.items[curr];
            if (rec.parent1) |p1| queue.append(self.allocator, p1) catch return 0;
            if (rec.parent2) |p2| queue.append(self.allocator, p2) catch return 0;
        }

        // Walk down from max commit ID to 0 to find highest-ID common ancestor
        var anc2 = std.AutoHashMap(CommitId, void).init(self.allocator);
        defer anc2.deinit();
        queue.clearRetainingCapacity();
        queue.append(self.allocator, c2) catch return 0;

        var best_lca: CommitId = 0;
        while (queue.items.len > 0) {
            const curr = queue.pop().?;
            if (anc2.contains(curr)) continue;
            anc2.put(curr, {}) catch return 0;
            if (anc1.contains(curr)) {
                if (curr > best_lca) best_lca = curr;
            }
            const rec = self.commits.items[curr];
            if (rec.parent1) |p1| queue.append(self.allocator, p1) catch return 0;
            if (rec.parent2) |p2| queue.append(self.allocator, p2) catch return 0;
        }
        return best_lca;
    }

    /// Find all Minimal Common Ancestors (MCAs / lowest common ancestors) of `c1` and `c2`:
    /// common ancestors `a` such that no other common ancestor `a'` has `a` as a strict ancestor.
    /// In a crisscross merge DAG, there can be 2 or more incomparable MCAs.
    pub fn findMinimalCommonAncestors(
        self: *const RepoDb,
        allocator: Allocator,
        c1: CommitId,
        c2: CommitId,
    ) ![]CommitId {
        if (c1 == c2) {
            const out = try allocator.alloc(CommitId, 1);
            out[0] = c1;
            return out;
        }

        var anc1 = std.AutoHashMap(CommitId, void).init(allocator);
        defer anc1.deinit();
        var queue: std.ArrayList(CommitId) = .empty;
        defer queue.deinit(allocator);

        try queue.append(allocator, c1);
        while (queue.items.len > 0) {
            const curr = queue.pop().?;
            if (anc1.contains(curr)) continue;
            try anc1.put(curr, {});
            const rec = self.commits.items[curr];
            if (rec.parent1) |p1| try queue.append(allocator, p1);
            if (rec.parent2) |p2| try queue.append(allocator, p2);
        }

        var anc2 = std.AutoHashMap(CommitId, void).init(allocator);
        defer anc2.deinit();
        var common: std.ArrayList(CommitId) = .empty;
        defer common.deinit(allocator);

        queue.clearRetainingCapacity();
        try queue.append(allocator, c2);
        while (queue.items.len > 0) {
            const curr = queue.pop().?;
            if (anc2.contains(curr)) continue;
            try anc2.put(curr, {});
            if (anc1.contains(curr)) {
                try common.append(allocator, curr);
            }
            const rec = self.commits.items[curr];
            if (rec.parent1) |p1| try queue.append(allocator, p1);
            if (rec.parent2) |p2| try queue.append(allocator, p2);
        }

        // Filter `common` down to minimal common ancestors (no strict descendant in `common`)
        var mcas: std.ArrayList(CommitId) = .empty;
        errdefer mcas.deinit(allocator);
        for (common.items) |cand| {
            var dominated = false;
            for (common.items) |other| {
                if (other != cand and self.isCommitAncestor(cand, other)) {
                    dominated = true;
                    break;
                }
            }
            if (!dominated) {
                try mcas.append(allocator, cand);
            }
        }
        if (mcas.items.len == 0) {
            try mcas.append(allocator, 0);
        }
        std.mem.sort(CommitId, mcas.items, {}, std.sort.asc(CommitId));
        return mcas.toOwnedSlice(allocator);
    }

    /// Compute the Virtual Merge Base Tree for `c1` and `c2` (Recursive / Crisscross Merge):
    /// - If `c1` and `c2` have a unique LCA `l_0`, returns `commits[l_0].root_tree_id`.
    /// - If `c1` and `c2` form a Crisscross Merge with multiple incomparable MCAs `{l_0, l_1, ...}`,
    ///   recursively merges the MCA trees over their own LCA so that changes shared by all MCAs
    ///   (and subsequently reverted on one branch) are accurately represented in the virtual base!
    pub fn computeVirtualMergeBaseTree(self: *RepoDb, c1: CommitId, c2: CommitId) !TreeId {
        const mcas = try self.findMinimalCommonAncestors(self.allocator, c1, c2);
        defer self.allocator.free(mcas);

        var virtual_tid = self.commits.items[mcas[0]].root_tree_id;
        var prev_mca = mcas[0];
        for (mcas[1..]) |next_mca| {
            const meta_lca = self.findLowestCommonAncestor(prev_mca, next_mca);
            const meta_base_tid = self.commits.items[meta_lca].root_tree_id;
            const next_tid = self.commits.items[next_mca].root_tree_id;
            virtual_tid = try self.mergeTreeIds(meta_base_tid, virtual_tid, next_tid);
            prev_mca = next_mca;
        }
        return virtual_tid;
    }

    /// Check whether `base_bytes` and `cand_bytes` share >= 50% line similarity (or exact hash)
    /// for automatic rename/move detection across 3-way merges.
    fn areBlobsRenameSimilar(base_bytes: []const u8, cand_bytes: []const u8) bool {
        if (std.mem.eql(u8, base_bytes, cand_bytes)) return true;
        if (base_bytes.len < 8 or cand_bytes.len < 8) return false;
        if (diff3.isBinaryBlob(base_bytes) or diff3.isBinaryBlob(cand_bytes)) return false;

        var total_base_lines: usize = 0;
        var matched_lines: usize = 0;

        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, base_bytes, "\n"), '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            total_base_lines += 1;
            if (std.mem.indexOf(u8, cand_bytes, trimmed) != null) {
                matched_lines += 1;
            }
        }
        return total_base_lines > 0 and (matched_lines * 2 >= total_base_lines);
    }

    /// Detect file renames where one side moved `old_path -> new_path` (with >= 50% similarity)
    /// while the other side modified `old_path`, lifting the 3-way merge onto `new_path` (`B_new + C_old - A_old`)!
    fn applySimilarityRenameDetection(
        self: *const RepoDb,
        base_tree: TreeManifest,
        ours_tree: TreeManifest,
        theirs_tree: TreeManifest,
        merged: *TreeManifest,
    ) !void {
        const DeletedMod = struct {
            old_path: []const u8,
            hash_a: ArtifactHash,
            hash_other: ArtifactHash,
        };

        var del_in_ours: std.ArrayList(DeletedMod) = .empty;
        defer del_in_ours.deinit(self.allocator);
        var del_in_theirs: std.ArrayList(DeletedMod) = .empty;
        defer del_in_theirs.deinit(self.allocator);
        var added_in_ours: std.ArrayList(tree_sum.PathEntry) = .empty;
        defer added_in_ours.deinit(self.allocator);
        var added_in_theirs: std.ArrayList(tree_sum.PathEntry) = .empty;
        defer added_in_theirs.deinit(self.allocator);

        const a_items = base_tree.entries.items;
        const b_items = ours_tree.entries.items;
        const c_items = theirs_tree.entries.items;

        var ia: usize = 0;
        var ib: usize = 0;
        var ic: usize = 0;

        while (ia < a_items.len or ib < b_items.len or ic < c_items.len) {
            var min_path: []const u8 = undefined;
            var has_min = false;
            if (ia < a_items.len) {
                min_path = a_items[ia].path;
                has_min = true;
            }
            if (ib < b_items.len and (!has_min or std.mem.order(u8, b_items[ib].path, min_path) == .lt)) {
                min_path = b_items[ib].path;
                has_min = true;
            }
            if (ic < c_items.len and (!has_min or std.mem.order(u8, c_items[ic].path, min_path) == .lt)) {
                min_path = c_items[ic].path;
                has_min = true;
            }

            const ea: ?tree_sum.PathEntry = if (ia < a_items.len and std.mem.eql(u8, a_items[ia].path, min_path)) blk: {
                const e = a_items[ia];
                ia += 1;
                break :blk e;
            } else null;

            const eb: ?tree_sum.PathEntry = if (ib < b_items.len and std.mem.eql(u8, b_items[ib].path, min_path)) blk: {
                const e = b_items[ib];
                ib += 1;
                break :blk e;
            } else null;

            const ec: ?tree_sum.PathEntry = if (ic < c_items.len and std.mem.eql(u8, c_items[ic].path, min_path)) blk: {
                const e = c_items[ic];
                ic += 1;
                break :blk e;
            } else null;

            if (ea) |base_e| {
                const hash_a = base_e.sum.getCleanHash() orelse continue;
                if (eb == null and ec != null) {
                    const hash_c = ec.?.sum.getCleanHash() orelse continue;
                    if (!tree_sum.hashEql(hash_c, hash_a)) {
                        try del_in_ours.append(self.allocator, .{
                            .old_path = base_e.path,
                            .hash_a = hash_a,
                            .hash_other = hash_c,
                        });
                    }
                } else if (ec == null and eb != null) {
                    const hash_b = eb.?.sum.getCleanHash() orelse continue;
                    if (!tree_sum.hashEql(hash_b, hash_a)) {
                        try del_in_theirs.append(self.allocator, .{
                            .old_path = base_e.path,
                            .hash_a = hash_a,
                            .hash_other = hash_b,
                        });
                    }
                }
            } else {
                if (eb != null and ec == null) {
                    try added_in_ours.append(self.allocator, eb.?);
                } else if (ec != null and eb == null) {
                    try added_in_theirs.append(self.allocator, ec.?);
                }
            }
        }

        // Case 1: `ours` deleted `old_path` and added a similar `new_path`; `theirs` edited `old_path`
        for (del_in_ours.items) |dm| {
            const bytes_a = self.getBlob(dm.hash_a) orelse continue;
            for (added_in_ours.items) |ours_cand| {
                const hash_b = ours_cand.sum.getCleanHash() orelse continue;
                const bytes_b = self.getBlob(hash_b) orelse continue;

                if (tree_sum.hashEql(dm.hash_a, hash_b) or areBlobsRenameSimilar(bytes_a, bytes_b)) {
                    const sum_a = try PathSum.fromClean(self.allocator, dm.hash_a);
                    defer {
                        var mut_a = sum_a;
                        mut_a.deinit(self.allocator);
                    }
                    const sum_b = try PathSum.fromClean(self.allocator, hash_b);
                    defer {
                        var mut_b = sum_b;
                        mut_b.deinit(self.allocator);
                    }
                    const sum_c = try PathSum.fromClean(self.allocator, dm.hash_other);
                    defer {
                        var mut_c = sum_c;
                        mut_c.deinit(self.allocator);
                    }
                    const renamed_sum = try PathSum.threeWayMerge(self.allocator, sum_a, sum_b, sum_c);
                    try merged.setPathSumWithModeOwned(self.allocator, ours_cand.path, renamed_sum, ours_cand.mode);
                    merged.removePath(self.allocator, dm.old_path);
                    break;
                }
            }
        }

        // Case 2: `theirs` deleted `old_path` and added a similar `new_path`; `ours` edited `old_path`
        for (del_in_theirs.items) |dm| {
            const bytes_a = self.getBlob(dm.hash_a) orelse continue;
            for (added_in_theirs.items) |theirs_cand| {
                const hash_c = theirs_cand.sum.getCleanHash() orelse continue;
                const bytes_c = self.getBlob(hash_c) orelse continue;

                if (tree_sum.hashEql(dm.hash_a, hash_c) or areBlobsRenameSimilar(bytes_a, bytes_c)) {
                    const sum_a = try PathSum.fromClean(self.allocator, dm.hash_a);
                    defer {
                        var mut_a = sum_a;
                        mut_a.deinit(self.allocator);
                    }
                    const sum_b = try PathSum.fromClean(self.allocator, dm.hash_other);
                    defer {
                        var mut_b = sum_b;
                        mut_b.deinit(self.allocator);
                    }
                    const sum_c = try PathSum.fromClean(self.allocator, hash_c);
                    defer {
                        var mut_c = sum_c;
                        mut_c.deinit(self.allocator);
                    }
                    const renamed_sum = try PathSum.threeWayMerge(self.allocator, sum_a, sum_b, sum_c);
                    try merged.setPathSumWithModeOwned(self.allocator, theirs_cand.path, renamed_sum, theirs_cand.mode);
                    merged.removePath(self.allocator, dm.old_path);
                    break;
                }
            }
        }
    }

    /// Compute 3-way algebraic tree merge (`B + C - A`) plus similarity rename detection and
    /// Pierce anchor-separated text hunk lifting!
    pub fn mergeTreeIds(
        self: *RepoDb,
        base_tid: TreeId,
        ours_tid: TreeId,
        theirs_tid: TreeId,
    ) !TreeId {
        if (base_tid == ours_tid) return theirs_tid;
        if (base_tid == theirs_tid) return ours_tid;

        const base_tree = self.trees.items[base_tid];
        const ours_tree = self.trees.items[ours_tid];
        const theirs_tree = self.trees.items[theirs_tid];

        var merged = try tree_sum.threeWayMergeTrees(
            self.allocator,
            base_tree,
            ours_tree,
            theirs_tree,
        );
        var merged_owned = true;
        errdefer if (merged_owned) merged.deinit(self.allocator);

        // 1. Similarity-Based Rename & Move Detection (`old_path -> new_path`)
        try self.applySimilarityRenameDetection(base_tree, ours_tree, theirs_tree, &merged);

        // 2. Sub-File Hunk Lifting: for any path with a 2-sided conflict (B + C - A),
        // run Pierce's anchor-separated 3-way text merger. If all regions between unique
        // anchors resolve cleanly, store the merged clean blob and collapse to `1 * M_clean`!
        for (merged.entries.items) |*entry| {
            if (entry.sum.extractTwoSidedConflict()) |two_sided| {
                const base_bytes = self.getBlob(two_sided.base) orelse continue;
                const ours_bytes = self.getBlob(two_sided.ours) orelse continue;
                const theirs_bytes = self.getBlob(two_sided.theirs) orelse continue;

                const hunk_res = try diff3.mergeTextAnchorDiff3(
                    self.allocator,
                    base_bytes,
                    ours_bytes,
                    theirs_bytes,
                    "ours",
                    "base",
                    "theirs",
                );
                defer self.allocator.free(hunk_res.bytes);

                if (hunk_res.is_clean) {
                    const clean_hash = try self.putBlob(hunk_res.bytes);
                    const clean_sum = try PathSum.fromClean(self.allocator, clean_hash);
                    entry.sum.deinit(self.allocator);
                    entry.sum = clean_sum;
                }
            }
        }

        merged_owned = false;
        return self.internTreeOwned(merged);
    }

    /// Total First-Class Conflict Merge (Pillar 2):
    /// Merges `source_branch_name` into `wt_id`'s current branch.
    /// Always creates a valid merge commit and never leaves the worktree wedged!
    pub fn mergeBranch(
        self: *RepoDb,
        wt_id: WorktreeId,
        source_branch_name: []const u8,
        author: []const u8,
        message: []const u8,
    ) !CommitId {
        const src_br = self.findBranchByName(source_branch_name) orelse return error.BranchNotFound;
        const target_br = self.worktrees.items[wt_id].branch_id;
        const ours_cid = self.branches.items[target_br].head_commit;
        const theirs_cid = self.branches.items[src_br].head_commit;

        // Compute virtual merge base tree (handles both standard LCA and Crisscross Merges!)
        const base_tid = try self.computeVirtualMergeBaseTree(ours_cid, theirs_cid);
        const ours_tid = self.worktrees.items[wt_id].working_tree_id;
        const theirs_tid = self.commits.items[theirs_cid].root_tree_id;

        const merged_tid = try self.mergeTreeIds(base_tid, ours_tid, theirs_tid);
        return self.finalizeWorktreeCommitOnBranch(
            wt_id,
            target_br,
            ours_cid,
            theirs_cid,
            merged_tid,
            author,
            message,
            "merge",
        );
    }

    /// Check whether `ancestor` is in the ancestor set of `descendant`.
    pub fn isCommitAncestor(self: *const RepoDb, ancestor: CommitId, descendant: CommitId) bool {
        if (ancestor == descendant) return true;
        if (ancestor > descendant) return false;
        var visited = std.AutoHashMap(CommitId, void).init(self.allocator);
        defer visited.deinit();
        var queue: std.ArrayList(CommitId) = .empty;
        defer queue.deinit(self.allocator);

        queue.append(self.allocator, descendant) catch return false;
        while (queue.items.len > 0) {
            const curr = queue.pop().?;
            if (curr == ancestor) return true;
            if (visited.contains(curr)) continue;
            visited.put(curr, {}) catch return false;
            const rec = self.commits.items[curr];
            if (rec.parent1) |p1| queue.append(self.allocator, p1) catch return false;
            if (rec.parent2) |p2| queue.append(self.allocator, p2) catch return false;
        }
        return false;
    }

    /// Atomically move `br_id` from `old_head_cid` to `new_head_cid` while algebraically
    /// auto-rebasing any dirty worktree (`wt.is_dirty`) or shelved draft (`db.drafts`) on `br_id`
    /// via `T_draft + T_new - T_old` (`dirty_draft_rebase_preserves_delta`).
    fn transitionBranchAndRebaseDrafts(
        self: *RepoDb,
        br_id: BranchId,
        old_head_cid: CommitId,
        new_head_cid: CommitId,
        oplog_desc: []const u8,
    ) !void {
        const old_head_tid = self.commits.items[old_head_cid].root_tree_id;
        const new_head_tid = self.commits.items[new_head_cid].root_tree_id;

        var new_wt_trees = try self.allocator.alloc(TreeId, self.worktrees.items.len);
        defer self.allocator.free(new_wt_trees);
        for (self.worktrees.items, 0..) |wt, idx| {
            if (wt.branch_id == br_id) {
                if (!wt.is_dirty) {
                    new_wt_trees[idx] = new_head_tid;
                } else {
                    new_wt_trees[idx] = try self.mergeTreeIds(old_head_tid, wt.working_tree_id, new_head_tid);
                }
            } else {
                new_wt_trees[idx] = wt.working_tree_id;
            }
        }

        var new_draft_trees = try self.allocator.alloc(TreeId, self.drafts.items.len);
        defer self.allocator.free(new_draft_trees);
        for (self.drafts.items, 0..) |d, idx| {
            if (d.branch_id == br_id) {
                new_draft_trees[idx] = try self.mergeTreeIds(old_head_tid, d.tree_id, new_head_tid);
            } else {
                new_draft_trees[idx] = d.tree_id;
            }
        }

        try self.recordOplog(oplog_desc);
        self.clearRedoStack();
        self.branches.items[br_id].head_commit = new_head_cid;
        for (self.worktrees.items, 0..) |*wt, idx| {
            wt.working_tree_id = new_wt_trees[idx];
        }
        for (self.drafts.items, 0..) |*d, idx| {
            d.tree_id = new_draft_trees[idx];
        }
    }

    /// Algebraic Rebase (Pillar 2):
    /// Rebases the commit chain on `branch_name` onto `onto_branch_name` via `B + C - A`.
    /// - If `old_head_cid` is a merge commit whose `parent2` is an ancestor of `onto_head_cid`,
    ///   rebases the merge commit relative to `parent2` (`(B + C - A) + D - C = B + D - A`).
    /// - Otherwise, collects the full first-parent topological commit chain `(lca .. old_head_cid]`
    ///   and replays every commit in order onto `onto_head_cid`!
    /// - Any dirty worktree or shelved draft on `branch_name` is automatically rebased onto the new head!
    pub fn rebaseCommitOnto(
        self: *RepoDb,
        branch_name: []const u8,
        onto_branch_name: []const u8,
    ) !CommitId {
        const br_id = self.findBranchByName(branch_name) orelse return error.BranchNotFound;
        const onto_br_id = self.findBranchByName(onto_branch_name) orelse return error.BranchNotFound;

        const old_head_cid = self.branches.items[br_id].head_commit;
        const onto_head_cid = self.branches.items[onto_br_id].head_commit;
        const old_commit = self.commits.items[old_head_cid];

        // Case 1: Rebasing a merge commit relative to its second parent `parent2`
        if (old_commit.parent2) |p2| {
            if (self.isCommitAncestor(p2, onto_head_cid)) {
                const parent_tid = self.commits.items[p2].root_tree_id;
                const commit_tid = old_commit.root_tree_id;
                const onto_tid = self.commits.items[onto_head_cid].root_tree_id;

                const rebased_tid = try self.mergeTreeIds(parent_tid, commit_tid, onto_tid);
                const author_copy = try self.allocator.dupe(u8, old_commit.author);
                defer self.allocator.free(author_copy);
                const msg_copy = try self.allocator.dupe(u8, old_commit.message);
                defer self.allocator.free(msg_copy);

                const new_cid = try self.appendCommit(
                    onto_head_cid,
                    null,
                    rebased_tid,
                    author_copy,
                    msg_copy,
                );
                try self.transitionBranchAndRebaseDrafts(br_id, old_head_cid, new_cid, "rebase");
                return new_cid;
            }
        }

        // Case 2: Collect topological first-parent chain `(lca .. old_head_cid]`
        const lca = self.findLowestCommonAncestor(old_head_cid, onto_head_cid);
        var chain: std.ArrayList(CommitId) = .empty;
        defer chain.deinit(self.allocator);

        var curr_opt: ?CommitId = old_head_cid;
        while (curr_opt) |cid| {
            if (cid == lca) break;
            try chain.append(self.allocator, cid);
            curr_opt = self.commits.items[cid].parent1;
        }
        // If `old_head_cid == lca` (e.g., rebasing a branch that is an ancestor of `onto`),
        // replay `old_head_cid` itself so the branch advances onto `onto_head_cid`.
        if (chain.items.len == 0) {
            try chain.append(self.allocator, old_head_cid);
        }

        // Reverse `chain` so we replay from oldest commit (just above `lca`) to `old_head_cid`
        std.mem.reverse(CommitId, chain.items);

        var current_onto_cid: CommitId = onto_head_cid;
        for (chain.items) |src_cid| {
            const src_rec = self.commits.items[src_cid];
            const src_parent_cid = src_rec.parent1 orelse 0;
            const parent_tid = self.commits.items[src_parent_cid].root_tree_id;
            const commit_tid = src_rec.root_tree_id;
            const onto_tid = self.commits.items[current_onto_cid].root_tree_id;

            const rebased_tid = try self.mergeTreeIds(parent_tid, commit_tid, onto_tid);
            const author_copy = try self.allocator.dupe(u8, src_rec.author);
            defer self.allocator.free(author_copy);
            const msg_copy = try self.allocator.dupe(u8, src_rec.message);
            defer self.allocator.free(msg_copy);

            current_onto_cid = try self.appendCommit(
                current_onto_cid,
                null,
                rebased_tid,
                author_copy,
                msg_copy,
            );
        }

        try self.transitionBranchAndRebaseDrafts(br_id, old_head_cid, current_onto_cid, "rebase");
        return current_onto_cid;
    }

    /// Resolve a conflicted path in `wt_id` to `resolved_bytes`, collapsing its `PathSum`
    /// to a single positive basis term `1 * hash(resolved_bytes)`.
    pub fn resolveFile(
        self: *RepoDb,
        wt_id: WorktreeId,
        path: []const u8,
        resolved_bytes: []const u8,
    ) !void {
        const clean_hash = try self.putBlob(resolved_bytes);
        const cur_tid = self.worktrees.items[wt_id].working_tree_id;
        var manifest = try self.trees.items[cur_tid].clone(self.allocator);
        var manifest_owned = true;
        errdefer if (manifest_owned) manifest.deinit(self.allocator);

        try manifest.setCleanFile(self.allocator, path, clean_hash);
        manifest_owned = false;
        const new_tid = try self.internTreeOwned(manifest);

        try self.recordOplog("resolve");
        self.clearRedoStack();
        const wt = &self.worktrees.items[wt_id];
        wt.working_tree_id = new_tid;
        wt.is_dirty = true;
    }

    /// Attach a new isolated worktree to the single-file repository database.
    pub fn addWorktree(
        self: *RepoDb,
        name: []const u8,
        fs_path: []const u8,
        branch_name: []const u8,
    ) !WorktreeId {
        try self.worktrees.ensureUnusedCapacity(self.allocator, 1);
        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);
        const path_dup = try self.allocator.dupe(u8, fs_path);
        errdefer self.allocator.free(path_dup);

        try self.recordOplog("worktree-add");
        errdefer self.abortLastOplog();

        const current_head = self.branches.items[0].head_commit;
        const br_id = try self.getOrCreateBranch(branch_name, current_head);
        const head_cid = self.branches.items[br_id].head_commit;
        const head_tid = self.commits.items[head_cid].root_tree_id;

        const wt_id: WorktreeId = @intCast(self.worktrees.items.len);
        self.worktrees.appendAssumeCapacity(.{
            .id = wt_id,
            .name = name_dup,
            .fs_path = path_dup,
            .branch_id = br_id,
            .working_tree_id = head_tid,
            .is_dirty = false,
            .is_open = true,
        });
        self.clearRedoStack();
        return wt_id;
    }

    /// Close a worktree without losing uncommitted drafts or undo history!
    /// (Fixes Fossil's `.fslckout` flaw documented in `fossil_tech_overview.wiki` §2.3.)
    pub fn closeWorktree(self: *RepoDb, wt_id: WorktreeId) !void {
        try self.drafts.ensureUnusedCapacity(self.allocator, 1);
        try self.recordOplog("worktree-close");
        self.clearRedoStack();
        const wt = self.worktrees.items[wt_id];
        if (wt.is_dirty) {
            try self.setDraft(wt_id, wt.branch_id, wt.working_tree_id);
        }
        self.worktrees.items[wt_id].is_open = false;
    }

    /// Reopen a previously closed worktree, automatically restoring its saved draft if any.
    pub fn reopenWorktree(self: *RepoDb, wt_id: WorktreeId) !void {
        try self.recordOplog("worktree-reopen");
        self.clearRedoStack();
        var wt = &self.worktrees.items[wt_id];
        wt.is_open = true;
        if (self.getDraft(wt_id, wt.branch_id)) |draft_tid| {
            wt.working_tree_id = draft_tid;
            wt.is_dirty = true;
        }
    }

    /// Find a worktree by its logical name (e.g. `"main-wt"`, `"wt1"`).
    pub fn findWorktreeByName(self: *const RepoDb, name: []const u8) ?WorktreeId {
        for (self.worktrees.items) |wt| {
            if (std.mem.eql(u8, wt.name, name)) return wt.id;
        }
        return null;
    }

    /// Algebraic Backout (`T_ours + T_parent(C) - T_C`, Pillar 2 `backout_conflict_cancels`):
    /// Reverts the changes introduced by `target_cid` (relative to its first parent) on `wt_id`.
    /// Even if `target_cid` was a conflicted merge commit (`B + C - A` over parent `B`),
    /// backing it out algebraically cancels the conflict back to clean `B`!
    pub fn backoutCommit(
        self: *RepoDb,
        wt_id: WorktreeId,
        target_cid: CommitId,
        author: []const u8,
        message: []const u8,
    ) !CommitId {
        if (target_cid >= self.commits.items.len) return error.InvalidCommitId;
        const target_rec = self.commits.items[target_cid];
        const parent_cid = target_rec.parent1 orelse 0;

        const target_tid = target_rec.root_tree_id;
        const parent_tid = self.commits.items[parent_cid].root_tree_id;
        const ours_tid = self.worktrees.items[wt_id].working_tree_id;

        // Compute `T_ours + T_parent(C) - T_C`
        const backed_out_tid = try self.mergeTreeIds(target_tid, ours_tid, parent_tid);
        const br_id = self.worktrees.items[wt_id].branch_id;
        const head_cid = self.branches.items[br_id].head_commit;
        return self.finalizeWorktreeCommitOnBranch(
            wt_id,
            br_id,
            head_cid,
            null,
            backed_out_tid,
            author,
            message,
            "backout",
        );
    }

    /// Algebraic Cherry-Pick (`T_ours + T_C - T_parent(C)`, Pillar 2 `cherryPick_then_backout_inv`):
    /// Applies the delta of `target_cid` (relative to its first parent) onto `wt_id`.
    /// By Theorem 6f (`cherryPick_then_backout_inv`), `cherryPickCommit(C)` followed by
    /// `backoutCommit(C)` is an exact algebraic identity!
    pub fn cherryPickCommit(
        self: *RepoDb,
        wt_id: WorktreeId,
        target_cid: CommitId,
        author: []const u8,
        message: []const u8,
    ) !CommitId {
        if (target_cid >= self.commits.items.len) return error.InvalidCommitId;
        const target_rec = self.commits.items[target_cid];
        const parent_cid = target_rec.parent1 orelse 0;

        const parent_tid = self.commits.items[parent_cid].root_tree_id;
        const target_tid = target_rec.root_tree_id;
        const ours_tid = self.worktrees.items[wt_id].working_tree_id;

        // Compute `T_ours + T_C - T_parent(C)`
        const picked_tid = try self.mergeTreeIds(parent_tid, ours_tid, target_tid);
        const br_id = self.worktrees.items[wt_id].branch_id;
        const head_cid = self.branches.items[br_id].head_commit;
        return self.finalizeWorktreeCommitOnBranch(
            wt_id,
            br_id,
            head_cid,
            null,
            picked_tid,
            author,
            message,
            "cherry-pick",
        );
    }

    /// Telescoping Multi-Commit Range Cherry-Pick (`zig-vcs cherry-pick A..B`, Lean 4 Theorem 12a
    /// `telescoping_range_cherry_pick_exact`):
    /// Forward-ports the entire net delta of commit range `(base_cid .. tip_cid]` onto `wt_id`
    /// in a single $O(F)$ algebraic merge `T_ours + T_{tip} - T_{base}`!
    pub fn cherryPickCommitRange(
        self: *RepoDb,
        wt_id: WorktreeId,
        base_cid: CommitId,
        tip_cid: CommitId,
        author: []const u8,
        message: []const u8,
    ) !CommitId {
        if (base_cid >= self.commits.items.len or tip_cid >= self.commits.items.len) {
            return error.InvalidCommitId;
        }
        const base_tid = self.commits.items[base_cid].root_tree_id;
        const tip_tid = self.commits.items[tip_cid].root_tree_id;
        const ours_tid = self.worktrees.items[wt_id].working_tree_id;

        const picked_tid = try self.mergeTreeIds(base_tid, ours_tid, tip_tid);
        const br_id = self.worktrees.items[wt_id].branch_id;
        const head_cid = self.branches.items[br_id].head_commit;
        return self.finalizeWorktreeCommitOnBranch(
            wt_id,
            br_id,
            head_cid,
            null,
            picked_tid,
            author,
            message,
            "cherry-pick-range",
        );
    }

    /// Telescoping Multi-Commit Range Backout (`zig-vcs backout A..B`, Lean 4 Theorem 12b
    /// `telescoping_range_backout_inverse`):
    /// Reverts the entire net delta of commit range `(base_cid .. tip_cid]` from `wt_id`
    /// in a single $O(F)$ algebraic merge `T_ours + T_{base} - T_{tip}`!
    pub fn backoutCommitRange(
        self: *RepoDb,
        wt_id: WorktreeId,
        base_cid: CommitId,
        tip_cid: CommitId,
        author: []const u8,
        message: []const u8,
    ) !CommitId {
        if (base_cid >= self.commits.items.len or tip_cid >= self.commits.items.len) {
            return error.InvalidCommitId;
        }
        const base_tid = self.commits.items[base_cid].root_tree_id;
        const tip_tid = self.commits.items[tip_cid].root_tree_id;
        const ours_tid = self.worktrees.items[wt_id].working_tree_id;

        const backed_out_tid = try self.mergeTreeIds(tip_tid, ours_tid, base_tid);
        const br_id = self.worktrees.items[wt_id].branch_id;
        const head_cid = self.branches.items[br_id].head_commit;
        return self.finalizeWorktreeCommitOnBranch(
            wt_id,
            br_id,
            head_cid,
            null,
            backed_out_tid,
            author,
            message,
            "backout-range",
        );
    }

    /// Jujutsu-Style Historical Commit Amend + Automatic Topological Descendant Cascade
    /// (`amend_cascade_reversible` & `amend_cascade_two_level_transitivity`):
    /// - Rewrites `target_cid_opt orelse head_commit` by folding in any dirty working-tree delta from `wt_id`
    ///   (and/or updating its commit message to `new_message`).
    /// - Automatically rebases every descendant commit `D` (`parent1` or `parent2`), branch pointer,
    ///   worktree, and saved draft via `T_D + T_{C'} - T_C` in a single atomic oplog transaction!
    pub fn amendCommit(
        self: *RepoDb,
        wt_id: WorktreeId,
        target_cid_opt: ?CommitId,
        new_message: ?[]const u8,
    ) !CommitId {
        const br_id = self.worktrees.items[wt_id].branch_id;
        const head_cid = self.branches.items[br_id].head_commit;
        const target_cid = target_cid_opt orelse head_cid;
        if (target_cid == 0 or target_cid >= self.commits.items.len) return error.InvalidCommitId;

        const old_target_tid = self.commits.items[target_cid].root_tree_id;
        const head_tid = self.commits.items[head_cid].root_tree_id;
        const wt_dirty = self.worktrees.items[wt_id].is_dirty;
        const working_tid = self.worktrees.items[wt_id].working_tree_id;

        const new_target_tid = if (wt_dirty)
            try self.mergeTreeIds(head_tid, old_target_tid, working_tid)
        else
            old_target_tid;

        return self.rewriteCommitAndCascadeDescendants(
            target_cid,
            new_target_tid,
            new_message,
            if (wt_dirty) wt_id else null,
        );
    }

    /// Rewrite `target_cid` with `new_target_tid` (and optional `new_message`) and topologically
    /// cascade the algebraic delta `T_{new} - T_{old}` to all descendant commits, branches, worktrees, and drafts.
    pub fn rewriteCommitAndCascadeDescendants(
        self: *RepoDb,
        target_cid: CommitId,
        new_target_tid: TreeId,
        new_message: ?[]const u8,
        absorbed_wt_id: ?WorktreeId,
    ) !CommitId {
        if (target_cid == 0 or target_cid >= self.commits.items.len) return error.InvalidCommitId;

        var remap = std.AutoHashMap(CommitId, CommitId).init(self.allocator);
        defer remap.deinit();

        const initial_commit_count = self.commits.items.len;

        // 1. Append the rewritten target commit `C'`
        const target_rec = self.commits.items[target_cid];
        const target_author = try self.allocator.dupe(u8, target_rec.author);
        defer self.allocator.free(target_author);
        const target_msg = try self.allocator.dupe(u8, new_message orelse target_rec.message);
        defer self.allocator.free(target_msg);

        const new_target_cid = try self.appendCommit(
            target_rec.parent1,
            target_rec.parent2,
            new_target_tid,
            target_author,
            target_msg,
        );
        try remap.put(target_cid, new_target_cid);

        // 2. Topologically scan `(target_cid + 1) .. initial_commit_count` and cascade to all descendants
        for ((target_cid + 1)..initial_commit_count) |cid_usize| {
            const cid: CommitId = @intCast(cid_usize);
            const rec = self.commits.items[cid];

            const mapped_p1 = if (rec.parent1) |p1| remap.get(p1) else null;
            const mapped_p2 = if (rec.parent2) |p2| remap.get(p2) else null;
            if (mapped_p1 == null and mapped_p2 == null) continue;

            var cascaded_tid = rec.root_tree_id;
            if (mapped_p1) |new_p1| {
                const old_p1 = rec.parent1.?;
                const old_p1_tid = self.commits.items[old_p1].root_tree_id;
                const new_p1_tid = self.commits.items[new_p1].root_tree_id;
                cascaded_tid = try self.mergeTreeIds(old_p1_tid, cascaded_tid, new_p1_tid);
            }
            if (mapped_p2) |new_p2| {
                const old_p2 = rec.parent2.?;
                const old_p2_tid = self.commits.items[old_p2].root_tree_id;
                const new_p2_tid = self.commits.items[new_p2].root_tree_id;
                cascaded_tid = try self.mergeTreeIds(old_p2_tid, cascaded_tid, new_p2_tid);
            }

            const a_copy = try self.allocator.dupe(u8, rec.author);
            defer self.allocator.free(a_copy);
            const m_copy = try self.allocator.dupe(u8, rec.message);
            defer self.allocator.free(m_copy);

            const is_legacy_ts = (rec.timestamp_sec >= 1700000000 and rec.timestamp_sec < 1700010000);
            const cascaded_ts: i64 = if (is_legacy_ts)
                currentUnixTimestampSec()
            else
                rec.timestamp_sec;
            const cascaded_tz: i16 = if (is_legacy_ts)
                localTzOffsetMinForTimestamp(cascaded_ts)
            else
                rec.tz_offset_min;
            const new_cid = try self.appendCommitWithTimestampAndTz(
                mapped_p1 orelse rec.parent1,
                mapped_p2 orelse rec.parent2,
                cascaded_tid,
                a_copy,
                m_copy,
                cascaded_ts,
                cascaded_tz,
            );
            try remap.put(cid, new_cid);
        }

        // 3. Pre-compute rebased trees for any dirty worktrees or drafts on affected branches
        var new_wt_trees = try self.allocator.alloc(TreeId, self.worktrees.items.len);
        defer self.allocator.free(new_wt_trees);
        for (self.worktrees.items, 0..) |wt, idx| {
            const old_head = self.branches.items[wt.branch_id].head_commit;
            if (remap.get(old_head)) |new_head| {
                const new_head_tid = self.commits.items[new_head].root_tree_id;
                if (!wt.is_dirty or (absorbed_wt_id != null and absorbed_wt_id.? == wt.id)) {
                    new_wt_trees[idx] = new_head_tid;
                } else {
                    const old_head_tid = self.commits.items[old_head].root_tree_id;
                    new_wt_trees[idx] = try self.mergeTreeIds(old_head_tid, wt.working_tree_id, new_head_tid);
                }
            } else {
                new_wt_trees[idx] = wt.working_tree_id;
            }
        }

        var new_draft_trees = try self.allocator.alloc(TreeId, self.drafts.items.len);
        defer self.allocator.free(new_draft_trees);
        for (self.drafts.items, 0..) |d, idx| {
            const old_head = self.branches.items[d.branch_id].head_commit;
            if (remap.get(old_head)) |new_head| {
                const old_head_tid = self.commits.items[old_head].root_tree_id;
                const new_head_tid = self.commits.items[new_head].root_tree_id;
                new_draft_trees[idx] = try self.mergeTreeIds(old_head_tid, d.tree_id, new_head_tid);
            } else {
                new_draft_trees[idx] = d.tree_id;
            }
        }

        // 4. Record atomic oplog snapshot and commit all remapped pointers
        try self.recordOplog("amend");
        errdefer self.abortLastOplog();

        for (self.branches.items) |*br| {
            if (remap.get(br.head_commit)) |new_head| {
                br.head_commit = new_head;
            }
        }
        for (self.worktrees.items, 0..) |*wt, idx| {
            wt.working_tree_id = new_wt_trees[idx];
            if (absorbed_wt_id != null and absorbed_wt_id.? == wt.id) {
                wt.is_dirty = false;
                try self.setDraft(wt.id, wt.branch_id, null);
            }
        }
        for (self.drafts.items, 0..) |*d, idx| {
            d.tree_id = new_draft_trees[idx];
        }
        for (self.tags.items) |*t| {
            if (remap.get(t.target_commit)) |new_cid| {
                t.target_commit = new_cid;
            }
        }

        self.clearRedoStack();
        return new_target_cid;
    }

    // ========================================================================
    // 4b. Transactional Tags, Revision Specifier Resolver, Bisect & Search
    // ========================================================================

    /// Find the commit pointed to by tag `name`, if any.
    pub fn findTagByName(self: *const RepoDb, name: []const u8) ?CommitId {
        for (self.tags.items) |t| {
            if (std.mem.eql(u8, t.name, name)) return t.target_commit;
        }
        return null;
    }

    /// Create or update a named tag pointing to `target_cid` (with atomic oplog undo/redo).
    pub fn createTag(self: *RepoDb, name: []const u8, target_cid: CommitId) !void {
        if (name.len == 0) return error.InvalidTagName;
        if (target_cid >= self.commits.items.len) return error.InvalidCommitId;

        for (self.tags.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) {
                try self.recordOplog("tag-update");
                self.clearRedoStack();
                t.target_commit = target_cid;
                return;
            }
        }

        try self.tags.ensureUnusedCapacity(self.allocator, 1);
        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);

        try self.recordOplog("tag-create");
        self.clearRedoStack();
        self.tags.appendAssumeCapacity(.{
            .name = name_dup,
            .target_commit = target_cid,
        });
    }

    /// Delete a named tag (with atomic oplog undo/redo).
    pub fn deleteTag(self: *RepoDb, name: []const u8) !bool {
        for (self.tags.items, 0..) |t, idx| {
            if (std.mem.eql(u8, t.name, name)) {
                try self.recordOplog("tag-delete");
                self.clearRedoStack();
                var removed = self.tags.orderedRemove(idx);
                removed.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    /// Resolve a revision specifier (`HEAD`, `@`, `<branch>`, `<tag>`, `c<id>`, `<id>`)
    /// with optional chained ancestry operators (`~N`, `^`, `^1`, `^2`), e.g.:
    /// - `"HEAD~2"` -> 2nd first-parent ancestor of `wt_id`'s branch head
    /// - `"main^2"` -> second merge parent of `main`
    /// - `"v1.0.0~1"` -> parent of tag `v1.0.0`
    pub fn resolveRevision(self: *const RepoDb, wt_id: WorktreeId, spec: []const u8) !CommitId {
        if (spec.len == 0) return error.InvalidRevisionSpec;

        const mod_idx: usize = if (std.mem.startsWith(u8, spec, "@-"))
            1
        else
            (std.mem.indexOfAny(u8, spec, "~^") orelse spec.len);
        const base_str = spec[0..mod_idx];
        const mods = spec[mod_idx..];

        var curr_cid: CommitId = blk: {
            if (std.mem.eql(u8, base_str, "HEAD") or std.mem.eql(u8, base_str, "@")) {
                const bid = self.worktrees.items[wt_id].branch_id;
                break :blk self.branches.items[bid].head_commit;
            }
            if (self.findBranchByName(base_str)) |bid| {
                break :blk self.branches.items[bid].head_commit;
            }
            if (self.findTagByName(base_str)) |tcid| {
                break :blk tcid;
            }
            const stripped = if (std.mem.startsWith(u8, base_str, "c")) base_str[1..] else base_str;
            const parsed = std.fmt.parseInt(CommitId, stripped, 10) catch return error.UnknownRevision;
            if (parsed >= self.commits.items.len) return error.InvalidCommitId;
            break :blk parsed;
        };

        var pos: usize = 0;
        while (pos < mods.len) {
            const op = mods[pos];
            pos += 1;
            const num_start = pos;
            while (pos < mods.len and std.ascii.isDigit(mods[pos])) : (pos += 1) {}
            const count: u32 = if (pos > num_start)
                try std.fmt.parseInt(u32, mods[num_start..pos], 10)
            else
                1;

            if (op == '~' or op == '-') {
                for (0..count) |_| {
                    curr_cid = self.commits.items[curr_cid].parent1 orelse return error.RevisionAncestorOutOfBounds;
                }
            } else if (op == '^') {
                if (count == 0) {
                    // `rev^0` is `rev` itself
                } else if (count == 1) {
                    curr_cid = self.commits.items[curr_cid].parent1 orelse return error.RevisionAncestorOutOfBounds;
                } else if (count == 2) {
                    curr_cid = self.commits.items[curr_cid].parent2 orelse return error.RevisionAncestorOutOfBounds;
                } else {
                    return error.UnsupportedParentIndex;
                }
            } else {
                return error.InvalidRevisionSpec;
            }
        }

        return curr_cid;
    }

    /// Zero-Checkout In-Memory Binary Search (`zig-vcs bisect <good_rev> <bad_rev> <path> <needle>`):
    /// Walks the first-parent commit lineage `(good_cid .. bad_cid]` and performs an $O(\log N)$
    /// binary search in memory (without touching the working directory on disk!) to find the
    /// exact first commit that introduced `needle` into `path` (or introduced a conflict if `needle == "CONFLICT"`).
    pub fn bisectCommitRange(
        self: *const RepoDb,
        allocator: Allocator,
        good_cid: CommitId,
        bad_cid: CommitId,
        path: []const u8,
        needle: []const u8,
    ) !CommitId {
        if (good_cid >= self.commits.items.len or bad_cid >= self.commits.items.len) {
            return error.InvalidCommitId;
        }
        const norm_path = try tree_sum.validateAndNormalizePath(allocator, path);
        defer allocator.free(norm_path);

        var lineage: std.ArrayList(CommitId) = .empty;
        defer lineage.deinit(allocator);

        var curr_opt: ?CommitId = bad_cid;
        var found_good = false;
        while (curr_opt) |cid| {
            if (cid == good_cid) {
                found_good = true;
                break;
            }
            try lineage.append(allocator, cid);
            curr_opt = self.commits.items[cid].parent1;
        }
        if (!found_good or lineage.items.len == 0) return error.InvalidBisectRange;

        // Reverse so `lineage[0]` is the oldest child of `good_cid` and `lineage[len-1] == bad_cid`
        std.mem.reverse(CommitId, lineage.items);

        var lo: usize = 0;
        var hi: usize = lineage.items.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const mid_cid = lineage.items[mid];
            if (self.commitMatchesBisectPredicate(mid_cid, norm_path, needle)) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }

        return lineage.items[lo];
    }

    fn commitMatchesBisectPredicate(
        self: *const RepoDb,
        cid: CommitId,
        norm_path: []const u8,
        needle: []const u8,
    ) bool {
        const tree = self.trees.items[self.commits.items[cid].root_tree_id];
        const sum = tree.getPathSum(norm_path) orelse return false;
        if (std.mem.eql(u8, needle, "CONFLICT")) {
            return sum.isConflicted();
        }
        if (sum.getCleanHash()) |h| {
            const bytes = self.getBlob(h) orelse return false;
            return std.mem.indexOf(u8, bytes, needle) != null;
        }
        for (sum.terms.items) |t| {
            if (t.coeff > 0) {
                const bytes = self.getBlob(t.hash) orelse continue;
                if (std.mem.indexOf(u8, bytes, needle) != null) return true;
            }
        }
        return false;
    }

    /// Instant Pickaxe History Search (`zig-vcs search <needle>`):
    /// Scans all commits in topological order and reports every commit `(c<id>, author, message, path)`
    /// that newly introduced a line containing `needle`.
    pub fn searchHistory(
        self: *const RepoDb,
        allocator: Allocator,
        needle: []const u8,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        for (self.commits.items, 0..) |c, cid| {
            if (cid == 0) continue;
            const cur_tree = self.trees.items[c.root_tree_id];
            const parent_cid = c.parent1 orelse 0;
            const parent_tree = self.trees.items[self.commits.items[parent_cid].root_tree_id];

            for (cur_tree.entries.items) |entry| {
                const cur_hash = entry.sum.getCleanHash() orelse continue;
                const parent_hash = if (parent_tree.getPathSum(entry.path)) |ps| ps.getCleanHash() else null;
                if (parent_hash != null and tree_sum.hashEql(cur_hash, parent_hash.?)) continue;

                const cur_bytes = self.getBlob(cur_hash) orelse continue;
                const parent_bytes = if (parent_hash) |ph| (self.getBlob(ph) orelse "") else "";

                if (std.mem.indexOf(u8, cur_bytes, needle) != null and
                    std.mem.indexOf(u8, parent_bytes, needle) == null)
                {
                    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, cur_bytes, "\n"), '\n');
                    while (it.next()) |line| {
                        if (std.mem.indexOf(u8, line, needle) != null and !containsExactLine(parent_bytes, line)) {
                            try out.print(
                                allocator,
                                "c{d} ({s}: \"{s}\") {s}: {s}\n",
                                .{ c.id, c.author, c.message, entry.path, line },
                            );
                        }
                    }
                }
            }
        }

        return out.toOwnedSlice(allocator);
    }

    fn pathMatchesOrIsUnderPrefix(path: []const u8, prefix: []const u8) bool {
        if (std.mem.eql(u8, path, prefix)) return true;
        if (path.len > prefix.len and
            std.mem.startsWith(u8, path, prefix) and
            path[prefix.len] == '/')
        {
            return true;
        }
        return false;
    }

    /// Selectively restore `path_or_prefix` (a single file path or a directory prefix) in `wt_id`
    /// from `source_cid_opt orelse head_commit` with full atomic `oplog` undo/redo (`INV-6`).
    pub fn restorePathFromRevision(
        self: *RepoDb,
        wt_id: WorktreeId,
        path_or_prefix: []const u8,
        source_cid_opt: ?CommitId,
    ) !usize {
        const br_id = self.worktrees.items[wt_id].branch_id;
        const head_cid = self.branches.items[br_id].head_commit;
        const source_cid = source_cid_opt orelse head_cid;
        if (source_cid >= self.commits.items.len) return error.InvalidCommitId;

        const norm_prefix = try tree_sum.validateAndNormalizePath(self.allocator, path_or_prefix);
        defer self.allocator.free(norm_prefix);

        const cur_tid = self.worktrees.items[wt_id].working_tree_id;
        const source_tid = self.commits.items[source_cid].root_tree_id;
        const source_tree = self.trees.items[source_tid];

        var manifest = try self.trees.items[cur_tid].clone(self.allocator);
        var manifest_owned = true;
        errdefer if (manifest_owned) manifest.deinit(self.allocator);

        var paths_affected: usize = 0;

        // 1. Remove any matching path in `manifest` that is absent from `source_tree`
        var idx = manifest.entries.items.len;
        while (idx > 0) {
            idx -= 1;
            const e_path = manifest.entries.items[idx].path;
            if (pathMatchesOrIsUnderPrefix(e_path, norm_prefix)) {
                if (source_tree.getPathSum(e_path) == null) {
                    self.allocator.free(manifest.entries.items[idx].path);
                    manifest.entries.items[idx].sum.deinit(self.allocator);
                    _ = manifest.entries.orderedRemove(idx);
                    paths_affected += 1;
                }
            }
        }

        // 2. Copy all matching entries from `source_tree` into `manifest`
        for (source_tree.entries.items) |src_entry| {
            if (pathMatchesOrIsUnderPrefix(src_entry.path, norm_prefix)) {
                const cloned_sum = try src_entry.sum.clone(self.allocator);
                try manifest.setPathSumWithModeOwned(
                    self.allocator,
                    src_entry.path,
                    cloned_sum,
                    src_entry.mode,
                );
                paths_affected += 1;
            }
        }

        manifest_owned = false;
        const new_tid = try self.internTreeOwned(manifest);
        const head_tid = self.commits.items[head_cid].root_tree_id;

        try self.recordOplog("restore");
        self.clearRedoStack();
        self.worktrees.items[wt_id].working_tree_id = new_tid;
        self.worktrees.items[wt_id].is_dirty = (new_tid != head_tid);
        return paths_affected;
    }

    /// Algebraic Octopus (`N`-Way) Merge (`threeWayMerge_assoc` + `threeWayMerge_comm`):
    /// Merges multiple `source_branches` simultaneously into `wt_id`'s current branch in `Z[A_bot]`.
    /// Never halts even if 3 or more branches conflict on the same file!
    pub fn mergeMultipleBranches(
        self: *RepoDb,
        wt_id: WorktreeId,
        source_branches: []const []const u8,
        author: []const u8,
        message: []const u8,
    ) !CommitId {
        if (source_branches.len == 0) return error.NoBranchesProvided;
        if (source_branches.len == 1) {
            return self.mergeBranch(wt_id, source_branches[0], author, message);
        }

        const target_br = self.worktrees.items[wt_id].branch_id;
        const ours_cid = self.branches.items[target_br].head_commit;
        var acc_tid = self.worktrees.items[wt_id].working_tree_id;
        var last_theirs_cid: ?CommitId = null;

        for (source_branches) |src_name| {
            const src_br = self.findBranchByName(src_name) orelse return error.BranchNotFound;
            const theirs_cid = self.branches.items[src_br].head_commit;
            const base_tid = try self.computeVirtualMergeBaseTree(ours_cid, theirs_cid);
            const theirs_tid = self.commits.items[theirs_cid].root_tree_id;
            acc_tid = try self.mergeTreeIds(base_tid, acc_tid, theirs_tid);
            last_theirs_cid = theirs_cid;
        }

        return self.finalizeWorktreeCommitOnBranch(
            wt_id,
            target_br,
            ours_cid,
            last_theirs_cid,
            acc_tid,
            author,
            message,
            "octopus-merge",
        );
    }

    /// Find the earliest commit in the repository that introduced `(path, target_hash)`.
    fn findCommitIntroducingBlob(self: *const RepoDb, path: []const u8, target_hash: ArtifactHash) CommitId {
        for (self.commits.items) |c| {
            const tree = self.trees.items[c.root_tree_id];
            if (tree.getPathSum(path)) |sum| {
                for (sum.terms.items) |term| {
                    if (term.coeff > 0 and tree_sum.hashEql(term.hash, target_hash)) {
                        return c.id;
                    }
                }
            }
        }
        return 0;
    }

    /// Line-level provenance & conflict-aware `blame` (`zig-vcs blame <path>`):
    /// Walks the commit history up to `commit_id` and attributes every line of `path` to the
    /// exact `(CommitId, author)` that introduced it. For conflicted `PathSum` files, annotates
    /// each algebraic basis term with its originating commit!
    pub fn blameFile(
        self: *const RepoDb,
        allocator: Allocator,
        commit_id: CommitId,
        path: []const u8,
    ) ![]u8 {
        if (commit_id >= self.commits.items.len) return error.InvalidCommitId;
        const norm_path = try tree_sum.validateAndNormalizePath(allocator, path);
        defer allocator.free(norm_path);

        const target_tree = self.trees.items[self.commits.items[commit_id].root_tree_id];
        const sum = target_tree.getPathSum(norm_path) orelse return error.FileNotFound;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        // If `path` is in a conflicted state (`B + C - A`), attribute each algebraic basis term
        if (sum.isConflicted()) {
            try out.print(allocator, "=== Algebraic Conflict Blame for '{s}' ({d} terms) ===\n", .{ norm_path, sum.terms.items.len });
            for (sum.terms.items) |term| {
                const origin_cid = self.findCommitIntroducingBlob(norm_path, term.hash);
                const origin_rec = self.commits.items[origin_cid];
                const sign_str = if (term.coeff > 0) "+" else "-";
                try out.print(
                    allocator,
                    "--- Term {s}{d} from c{d} ({s}: \"{s}\") ---\n",
                    .{ sign_str, @abs(term.coeff), origin_cid, origin_rec.author, origin_rec.message },
                );
                const blob_bytes = self.getBlob(term.hash) orelse "";
                if (blob_bytes.len > 0) {
                    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, blob_bytes, "\n"), '\n');
                    while (it.next()) |line| {
                        try out.print(allocator, "c{d} ({s}): {s}\n", .{ origin_cid, origin_rec.author, line });
                    }
                }
            }
            return out.toOwnedSlice(allocator);
        }

        const clean_hash = sum.getCleanHash().?;
        const current_bytes = self.getBlob(clean_hash) orelse "";
        if (current_bytes.len == 0) return out.toOwnedSlice(allocator);

        // Collect first-parent ancestry chain from `commit_id` back to root
        var chain: std.ArrayList(CommitId) = .empty;
        defer chain.deinit(allocator);
        var curr_opt: ?CommitId = commit_id;
        while (curr_opt) |cid| {
            try chain.append(allocator, cid);
            curr_opt = self.commits.items[cid].parent1;
        }
        std.mem.reverse(CommitId, chain.items);

        // Split current file into lines
        var cur_lines: std.ArrayList([]const u8) = .empty;
        defer cur_lines.deinit(allocator);
        var it_cur = std.mem.splitScalar(u8, std.mem.trimEnd(u8, current_bytes, "\n"), '\n');
        while (it_cur.next()) |line| {
            try cur_lines.append(allocator, line);
        }

        // Pre-resolve distinct ancestor blob snapshots along `chain` once
        const AncSnapshot = struct {
            cid: CommitId,
            bytes: []const u8,
        };
        var anc_snaps: std.ArrayList(AncSnapshot) = .empty;
        defer anc_snaps.deinit(allocator);
        var prev_hash: ?ArtifactHash = null;
        for (chain.items) |anc_cid| {
            if (anc_cid == 0) continue;
            const anc_tree = self.trees.items[self.commits.items[anc_cid].root_tree_id];
            if (anc_tree.getPathSum(norm_path)) |anc_sum| {
                if (anc_sum.getCleanHash()) |anc_hash| {
                    if (prev_hash != null and tree_sum.hashEql(prev_hash.?, anc_hash)) continue;
                    prev_hash = anc_hash;
                    const anc_bytes = self.getBlob(anc_hash) orelse "";
                    try anc_snaps.append(allocator, .{ .cid = anc_cid, .bytes = anc_bytes });
                }
            }
        }

        // For each line in `cur_lines`, find the earliest commit in `anc_snaps` that contains that exact line
        for (cur_lines.items, 0..) |line, line_idx| {
            var attributed_cid: CommitId = commit_id;
            for (anc_snaps.items) |snap| {
                if (containsExactLine(snap.bytes, line)) {
                    attributed_cid = snap.cid;
                    break;
                }
            }
            const rec = self.commits.items[attributed_cid];
            try out.print(allocator, "c{d} ({s}) L{d}: {s}\n", .{
                attributed_cid,
                rec.author,
                line_idx + 1,
                line,
            });
        }

        return out.toOwnedSlice(allocator);
    }

    fn containsExactLine(blob: []const u8, target_line: []const u8) bool {
        if (blob.len == 0) return false;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, blob, "\n"), '\n');
        while (it.next()) |l| {
            if (std.mem.eql(u8, l, target_line)) return true;
        }
        return false;
    }

    /// Generate a unified diff (`--- a/<path>`, `+++ b/<path>`, `@@ -l,c +l,c @@`) between two `TreeId`s.
    pub fn diffTreesUnified(
        self: *const RepoDb,
        allocator: Allocator,
        old_tid: TreeId,
        new_tid: TreeId,
    ) ![]u8 {
        return self.diffTreesUnifiedFiltered(allocator, old_tid, new_tid, null);
    }

    /// Generate a unified diff between two `TreeId`s in O(F) sorted-cursor time, optionally filtered to paths matching `path_prefix`.
    pub fn diffTreesUnifiedFiltered(
        self: *const RepoDb,
        allocator: Allocator,
        old_tid: TreeId,
        new_tid: TreeId,
        path_prefix: ?[]const u8,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (old_tid == new_tid) return out.toOwnedSlice(allocator);

        const old_items = self.trees.items[old_tid].entries.items;
        const new_items = self.trees.items[new_tid].entries.items;

        var i_old: usize = 0;
        var i_new: usize = 0;

        while (i_old < old_items.len or i_new < new_items.len) {
            const ord: std.math.Order = if (i_old < old_items.len and i_new < new_items.len)
                std.mem.order(u8, old_items[i_old].path, new_items[i_new].path)
            else if (i_old < old_items.len)
                .lt
            else
                .gt;

            const path: []const u8 = switch (ord) {
                .lt => old_items[i_old].path,
                .gt => new_items[i_new].path,
                .eq => old_items[i_old].path,
            };
            const old_entry: ?tree_sum.PathEntry = switch (ord) {
                .lt, .eq => blk: {
                    const e = old_items[i_old];
                    i_old += 1;
                    break :blk e;
                },
                .gt => null,
            };
            const new_entry: ?tree_sum.PathEntry = switch (ord) {
                .gt, .eq => blk: {
                    const e = new_items[i_new];
                    i_new += 1;
                    break :blk e;
                },
                .lt => null,
            };

            if (path_prefix) |prefix| {
                if (!std.mem.startsWith(u8, path, prefix)) continue;
            }

            const old_sum: ?PathSum = if (old_entry) |e| e.sum else null;
            const new_sum: ?PathSum = if (new_entry) |e| e.sum else null;
            const old_mode: FileMode = if (old_entry) |e| e.mode else .regular;
            const new_mode: FileMode = if (new_entry) |e| e.mode else .regular;

            if (old_sum != null and new_sum != null and old_sum.?.eql(new_sum.?) and old_mode == new_mode) {
                continue;
            }

            try out.print(allocator, "--- a/{s}\n+++ b/{s}\n", .{ path, path });
            if (old_mode != new_mode and old_sum != null and new_sum != null) {
                try out.print(allocator, "old mode {o}\nnew mode {o}\n", .{ @intFromEnum(old_mode), @intFromEnum(new_mode) });
            }

            if (new_sum != null and new_sum.?.isConflicted()) {
                try out.print(allocator, "@@ algebraic conflict ({d} basis terms in Z[A_bot]) @@\n", .{new_sum.?.terms.items.len});
                continue;
            }

            const old_bytes: []const u8 = if (old_sum) |os|
                (if (os.getCleanHash()) |h| (self.getBlob(h) orelse "") else "<conflicted>\n")
            else
                "";
            const new_bytes: []const u8 = if (new_sum) |ns|
                (if (ns.getCleanHash()) |h| (self.getBlob(h) orelse "") else "<conflicted>\n")
            else
                "";

            if (diff3.isBinaryBlob(old_bytes) or diff3.isBinaryBlob(new_bytes)) {
                try out.print(allocator, "Binary files a/{s} and b/{s} differ\n", .{ path, path });
                continue;
            }

            const hunks = try diff3.renderUnifiedDiffHunks(allocator, old_bytes, new_bytes);
            defer allocator.free(hunks);
            try out.appendSlice(allocator, hunks);
        }

        return out.toOwnedSlice(allocator);
    }

    /// Format the commit DAG in reverse topological order with branch & worktree annotations.
    pub fn formatCommitLogGraph(self: *const RepoDb, allocator: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var idx = self.commits.items.len;
        while (idx > 0) {
            idx -= 1;
            const c = self.commits.items[idx];
            const tree = self.trees.items[c.root_tree_id];
            const conf_tag = if (tree.hasConflicts()) " [CONFLICTED]" else "";

            try out.print(allocator, "* commit c{d}", .{c.id});

            // Collect branch/tag decorations pointing to `c.id`
            var first_dec = true;
            for (self.branches.items) |br| {
                if (br.head_commit == c.id) {
                    if (first_dec) {
                        try out.appendSlice(allocator, " (");
                        first_dec = false;
                    } else {
                        try out.appendSlice(allocator, ", ");
                    }
                    try out.print(allocator, "{s}", .{br.name});
                }
            }
            for (self.tags.items) |t| {
                if (t.target_commit == c.id) {
                    if (first_dec) {
                        try out.appendSlice(allocator, " (");
                        first_dec = false;
                    } else {
                        try out.appendSlice(allocator, ", ");
                    }
                    try out.print(allocator, "tag: {s}", .{t.name});
                }
            }
            if (!first_dec) try out.appendSlice(allocator, ")");

            if (c.parent1) |p1| {
                if (c.parent2) |p2| {
                    try out.print(allocator, " [merge: c{d} + c{d}]{s}\n", .{ p1, p2, conf_tag });
                } else {
                    try out.print(allocator, " [parent: c{d}]{s}\n", .{ p1, conf_tag });
                }
            } else {
                try out.print(allocator, " [root]{s}\n", .{conf_tag});
            }
            var date_buf: [25]u8 = undefined;
            const date_str = formatTimestampWithOffsetBuf(c.timestamp_sec, c.tz_offset_min, &date_buf);
            try out.print(allocator, "| Author: {s}\n| Date:   {s}\n|     {s}\n|\n", .{ c.author, date_str, c.message });
        }

        return out.toOwnedSlice(allocator);
    }

    // ========================================================================
    // 4b. Distributed Sync (`fetch`, `pull`, `push`), Branch Ops, & `mv`/`show`
    // ========================================================================

    /// Content-addressed topological object fetch (`zig-vcs fetch`):
    /// Imports all missing blobs, trees, and commits from `remote` into `self` while deduplicating
    /// shared commits via `computeCommitStructuralHash`. Returns the local `CommitId` in `self`
    /// corresponding to `remote`'s head commit on `branch_name`.
    pub fn fetchFromRemote(
        self: *RepoDb,
        remote: *const RepoDb,
        branch_name: []const u8,
    ) !CommitId {
        const remote_br_id = remote.findBranchByName(branch_name) orelse return error.BranchNotFound;
        const remote_head_cid = remote.branches.items[remote_br_id].head_commit;

        // 1. Import all missing blobs (content-addressed by BLAKE3)
        for (remote.blobs.items) |b| {
            _ = try self.putBlob(b.bytes);
        }

        // 2. Map every remote TreeId to its interned local TreeId
        var remote_to_local_tree = try self.allocator.alloc(TreeId, remote.trees.items.len);
        defer self.allocator.free(remote_to_local_tree);
        for (remote.trees.items, 0..) |rt, rt_idx| {
            const cloned_tree = try rt.clone(self.allocator);
            remote_to_local_tree[rt_idx] = try self.internTreeOwned(cloned_tree);
        }

        // 3. Precompute structural hashes for all existing local commits
        var local_hashes: std.ArrayList(ArtifactHash) = .empty;
        defer local_hashes.deinit(self.allocator);
        try local_hashes.ensureTotalCapacity(self.allocator, self.commits.items.len + remote.commits.items.len);
        for (0..self.commits.items.len) |cid| {
            local_hashes.appendAssumeCapacity(self.computeCommitStructuralHash(@intCast(cid)));
        }

        // 4. Map remote commits in topological order (0 .. remote.commits.items.len)
        var remote_to_local_commit = try self.allocator.alloc(CommitId, remote.commits.items.len);
        defer self.allocator.free(remote_to_local_commit);
        remote_to_local_commit[0] = 0;

        for (1..remote.commits.items.len) |rc_idx| {
            const rc_hash = remote.computeCommitStructuralHash(@intCast(rc_idx));
            var found_local: ?CommitId = null;
            for (local_hashes.items, 0..) |lh, l_idx| {
                if (l_idx > 0 and tree_sum.hashEql(lh, rc_hash)) {
                    found_local = @intCast(l_idx);
                    break;
                }
            }
            if (found_local) |existing_cid| {
                if (remote.commits.items[rc_idx].timestamp_sec >= 1700010000) {
                    if (self.commits.items[existing_cid].timestamp_sec != remote.commits.items[rc_idx].timestamp_sec) {
                        self.commits.items[existing_cid].timestamp_sec = remote.commits.items[rc_idx].timestamp_sec;
                    }
                    if (self.commits.items[existing_cid].tz_offset_min != remote.commits.items[rc_idx].tz_offset_min) {
                        self.commits.items[existing_cid].tz_offset_min = remote.commits.items[rc_idx].tz_offset_min;
                    }
                }
                remote_to_local_commit[rc_idx] = existing_cid;
            } else {
                const rc = remote.commits.items[rc_idx];
                const local_p1 = if (rc.parent1) |p1| remote_to_local_commit[p1] else null;
                const local_p2 = if (rc.parent2) |p2| remote_to_local_commit[p2] else null;
                const local_tid = remote_to_local_tree[rc.root_tree_id];
                const new_cid = try self.appendCommitWithTimestampAndTz(
                    local_p1,
                    local_p2,
                    local_tid,
                    rc.author,
                    rc.message,
                    rc.timestamp_sec,
                    rc.tz_offset_min,
                );
                try local_hashes.append(self.allocator, self.computeCommitStructuralHash(new_cid));
                remote_to_local_commit[rc_idx] = new_cid;
            }
        }

        return remote_to_local_commit[remote_head_cid];
    }

    /// Distributed Algebraic Pull (`zig-vcs pull`, Theorem 7a `pull_symmetric_commutativity` &
    /// Theorem 7b `fast_forward_pull_is_exact_remote`):
    /// Fetches `branch_name` from `remote`, fast-forwards if `local_head` is an ancestor of
    /// `remote_head`, or performs an algebraic 3-way merge (`B + C - A`) over the virtual merge base!
    pub fn pullFromRemote(
        self: *RepoDb,
        wt_id: WorktreeId,
        remote: *const RepoDb,
        branch_name: []const u8,
        author: []const u8,
    ) !CommitId {
        _ = wt_id;
        const fetched_cid = try self.fetchFromRemote(remote, branch_name);

        if (self.findBranchByName(branch_name) == null) {
            try self.recordOplog("pull-new-branch");
            errdefer self.abortLastOplog();
            _ = try self.getOrCreateBranch(branch_name, fetched_cid);
            self.clearRedoStack();
            return fetched_cid;
        }

        const br_id = self.findBranchByName(branch_name).?;
        const local_head_cid = self.branches.items[br_id].head_commit;

        // Already up-to-date (remote commit is already an ancestor of local head)
        if (fetched_cid == local_head_cid or self.isCommitAncestor(fetched_cid, local_head_cid)) {
            return local_head_cid;
        }

        // Fast-forward (`local_head_cid` is an ancestor of `fetched_cid`, Theorem 7b)
        if (self.isCommitAncestor(local_head_cid, fetched_cid)) {
            try self.transitionBranchAndRebaseDrafts(br_id, local_head_cid, fetched_cid, "pull-ff");
            return fetched_cid;
        }

        // Divergent histories: compute virtual merge base `A` and merge `B + C - A` (Theorem 7a)
        const base_tid = try self.computeVirtualMergeBaseTree(local_head_cid, fetched_cid);
        const local_tid = self.commits.items[local_head_cid].root_tree_id;
        const remote_tid = self.commits.items[fetched_cid].root_tree_id;
        const merged_tid = try self.mergeTreeIds(base_tid, local_tid, remote_tid);

        const new_cid = try self.appendCommit(
            local_head_cid,
            fetched_cid,
            merged_tid,
            author,
            "Merge remote branch via pull",
        );
        try self.transitionBranchAndRebaseDrafts(br_id, local_head_cid, new_cid, "pull-merge");
        return new_cid;
    }

    /// Distributed Push (`zig-vcs push`):
    /// Transfers missing objects from `self` into `remote` for `branch_name`.
    /// Enforces fast-forward safety on `remote` (returning `error.NonFastForwardPush` if `remote`
    /// has diverged and `!force`), and auto-rebases any dirty worktree/draft on `remote`!
    pub fn pushToRemote(
        self: *const RepoDb,
        remote: *RepoDb,
        branch_name: []const u8,
        force: bool,
    ) !CommitId {
        if (self.findBranchByName(branch_name) == null) return error.BranchNotFound;
        const new_remote_cid = try remote.fetchFromRemote(self, branch_name);

        if (remote.findBranchByName(branch_name)) |remote_br_id| {
            const old_remote_cid = remote.branches.items[remote_br_id].head_commit;
            if (old_remote_cid == new_remote_cid) return new_remote_cid;
            if (!force and !remote.isCommitAncestor(old_remote_cid, new_remote_cid)) {
                return error.NonFastForwardPush;
            }
            try remote.transitionBranchAndRebaseDrafts(remote_br_id, old_remote_cid, new_remote_cid, "push-receive");
            return new_remote_cid;
        } else {
            try remote.recordOplog("push-receive-new-branch");
            errdefer remote.abortLastOplog();
            _ = try remote.getOrCreateBranch(branch_name, new_remote_cid);
            remote.clearRedoStack();
            return new_remote_cid;
        }
    }

    /// Rename branch `old_name` to `new_name` with full atomic `oplog` undo/redo (`INV-6`).
    pub fn renameBranch(self: *RepoDb, old_name: []const u8, new_name: []const u8) !void {
        if (new_name.len == 0) return error.InvalidBranchName;
        const br_id = self.findBranchByName(old_name) orelse return error.BranchNotFound;
        if (std.mem.eql(u8, old_name, new_name)) return;
        if (self.findBranchByName(new_name) != null) return error.BranchAlreadyExists;

        const new_name_dup = try self.allocator.dupe(u8, new_name);
        errdefer self.allocator.free(new_name_dup);

        try self.recordOplog("branch-rename");
        self.clearRedoStack();
        self.allocator.free(self.branches.items[br_id].name);
        self.branches.items[br_id].name = new_name_dup;
    }

    /// Delete branch `name` (if not currently checked out in any worktree) with full atomic `oplog` undo/redo (`INV-6`).
    pub fn deleteBranch(self: *RepoDb, name: []const u8) !void {
        const br_id = self.findBranchByName(name) orelse return error.BranchNotFound;
        if (self.branches.items.len <= 1) return error.CannotDeleteCheckedOutBranch;
        for (self.worktrees.items) |wt| {
            if (wt.branch_id == br_id) return error.CannotDeleteCheckedOutBranch;
        }

        try self.recordOplog("branch-delete");
        self.clearRedoStack();

        var removed = self.branches.orderedRemove(br_id);
        removed.deinit(self.allocator);

        for (self.branches.items, 0..) |*b, idx| {
            b.id = @intCast(idx);
        }
        for (self.worktrees.items) |*wt| {
            if (wt.branch_id > br_id) wt.branch_id -= 1;
        }

        var d_idx = self.drafts.items.len;
        while (d_idx > 0) {
            d_idx -= 1;
            if (self.drafts.items[d_idx].branch_id == br_id) {
                _ = self.drafts.orderedRemove(d_idx);
            } else if (self.drafts.items[d_idx].branch_id > br_id) {
                self.drafts.items[d_idx].branch_id -= 1;
            }
        }
    }

    /// Move or rename `src_path -> dst_path` inside `wt_id` (preserving its `PathSum` and `FileMode`)
    /// with a single atomic `"mv"` oplog entry.
    pub fn moveFile(
        self: *RepoDb,
        wt_id: WorktreeId,
        src_path: []const u8,
        dst_path: []const u8,
    ) !void {
        const norm_src = try tree_sum.validateAndNormalizePath(self.allocator, src_path);
        defer self.allocator.free(norm_src);
        const norm_dst = try tree_sum.validateAndNormalizePath(self.allocator, dst_path);
        defer self.allocator.free(norm_dst);

        const cur_tid = self.worktrees.items[wt_id].working_tree_id;
        const cur_tree = self.trees.items[cur_tid];
        const src_sum = cur_tree.getPathSum(norm_src) orelse return error.FileNotFound;
        const src_mode = cur_tree.getPathMode(norm_src) orelse .regular;

        if (std.mem.eql(u8, norm_src, norm_dst)) return;

        var manifest = try cur_tree.clone(self.allocator);
        var manifest_owned = true;
        errdefer if (manifest_owned) manifest.deinit(self.allocator);

        const cloned_sum = try src_sum.clone(self.allocator);
        try manifest.setPathSumWithModeOwned(self.allocator, norm_dst, cloned_sum, src_mode);
        manifest.removePath(self.allocator, norm_src);

        manifest_owned = false;
        const new_tid = try self.internTreeOwned(manifest);
        const br_id = self.worktrees.items[wt_id].branch_id;
        const head_tid = self.commits.items[self.branches.items[br_id].head_commit].root_tree_id;

        try self.recordOplog("mv");
        self.clearRedoStack();
        self.worktrees.items[wt_id].working_tree_id = new_tid;
        self.worktrees.items[wt_id].is_dirty = (new_tid != head_tid);
    }

    /// Inspect a commit or a file at a revision (`zig-vcs show [rev[:path]] [path_filter]`):
    /// - If `spec` contains `:` (`<rev>:<path>`), returns the exact file content (or algebraic
    ///   conflict summary) at `<path>` in `<rev>`.
    /// - Otherwise, returns the commit metadata header (`commit`, `Author`, `Timestamp`, message)
    ///   followed by the unified diff against its first parent (optionally filtered to `path_filter_opt`).
    pub fn showRevision(
        self: *const RepoDb,
        allocator: Allocator,
        wt_id: WorktreeId,
        spec: []const u8,
    ) ![]u8 {
        return self.showRevisionFiltered(allocator, wt_id, spec, null);
    }

    pub fn showRevisionFiltered(
        self: *const RepoDb,
        allocator: Allocator,
        wt_id: WorktreeId,
        spec: []const u8,
        path_filter_opt: ?[]const u8,
    ) ![]u8 {
        if (std.mem.indexOfScalar(u8, spec, ':')) |colon_idx| {
            const rev_part = if (colon_idx == 0) "HEAD" else spec[0..colon_idx];
            const path_part = spec[colon_idx + 1 ..];
            const cid = try self.resolveRevision(wt_id, rev_part);
            const norm_path = try tree_sum.validateAndNormalizePath(allocator, path_part);
            defer allocator.free(norm_path);

            const tree = self.trees.items[self.commits.items[cid].root_tree_id];
            const sum = tree.getPathSum(norm_path) orelse return error.FileNotFound;
            if (sum.getCleanHash()) |clean_hash| {
                return allocator.dupe(u8, self.getBlob(clean_hash) orelse "");
            }
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.print(allocator, "<conflicted PathSum ({d} terms in Z[A_bot])>\n", .{sum.terms.items.len});
            return out.toOwnedSlice(allocator);
        }

        const cid = try self.resolveRevision(wt_id, spec);
        const c = self.commits.items[cid];
        const parent_cid = c.parent1 orelse 0;
        const parent_tid = self.commits.items[parent_cid].root_tree_id;
        const diff_txt = if (cid == 0)
            try allocator.dupe(u8, "")
        else
            try self.diffTreesUnifiedFiltered(allocator, parent_tid, c.root_tree_id, path_filter_opt);
        defer allocator.free(diff_txt);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var date_buf: [25]u8 = undefined;
        const date_str = formatTimestampWithOffsetBuf(c.timestamp_sec, c.tz_offset_min, &date_buf);
        try out.print(
            allocator,
            "commit c{d}\nAuthor: {s}\nDate:   {s} ({d})\n\n    {s}\n\n{s}",
            .{ c.id, c.author, date_str, c.timestamp_sec, c.message, diff_txt },
        );
        return out.toOwnedSlice(allocator);
    }

    /// Add or update a named remote (`zig-vcs remote add <name> <path>` or `remote set-url <name> <path>`)
    /// with full atomic `oplog` undo/redo (`INV-6`).
    pub fn setRemote(self: *RepoDb, name: []const u8, path: []const u8) !void {
        if (name.len == 0 or path.len == 0) return error.InvalidRemoteSpec;
        const path_dup = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_dup);

        for (self.remotes.items, 0..) |r, idx| {
            if (std.mem.eql(u8, r.name, name)) {
                try self.recordOplog("remote-set");
                self.clearRedoStack();
                self.allocator.free(self.remotes.items[idx].path);
                self.remotes.items[idx].path = path_dup;
                return;
            }
        }

        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);
        try self.remotes.ensureUnusedCapacity(self.allocator, 1);

        try self.recordOplog("remote-add");
        self.clearRedoStack();
        self.remotes.appendAssumeCapacity(.{
            .name = name_dup,
            .path = path_dup,
        });
    }

    /// Remove a named remote (`zig-vcs remote remove <name>`) with full atomic `oplog` undo/redo.
    pub fn removeRemote(self: *RepoDb, name: []const u8) !bool {
        for (self.remotes.items, 0..) |r, idx| {
            if (std.mem.eql(u8, r.name, name)) {
                try self.recordOplog("remote-remove");
                self.clearRedoStack();
                var removed = self.remotes.orderedRemove(idx);
                removed.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    pub fn findRemotePath(self: *const RepoDb, name: []const u8) ?[]const u8 {
        for (self.remotes.items) |r| {
            if (std.mem.eql(u8, r.name, name)) return r.path;
        }
        return null;
    }

    pub fn resolveRemoteOrPath(self: *const RepoDb, name_or_path: []const u8) []const u8 {
        return self.findRemotePath(name_or_path) orelse name_or_path;
    }

    /// Set a repository configuration key-value pair (`zig_vcs config <key> <value>`).
    pub fn setConfig(self: *RepoDb, key: []const u8, value: []const u8) !void {
        if (key.len == 0) return error.MissingConfigKey;
        const val_dup = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val_dup);

        for (self.configs.items, 0..) |cfg, idx| {
            if (std.mem.eql(u8, cfg.name, key)) {
                self.allocator.free(self.configs.items[idx].path);
                self.configs.items[idx].path = val_dup;
                return;
            }
        }

        const key_dup = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_dup);
        try self.configs.append(self.allocator, .{
            .name = key_dup,
            .path = val_dup,
        });
    }

    /// Look up a repository configuration value by `key` (`zig_vcs config <key>`).
    pub fn getConfig(self: *const RepoDb, key: []const u8) ?[]const u8 {
        for (self.configs.items) |cfg| {
            if (std.mem.eql(u8, cfg.name, key)) return cfg.path;
        }
        return null;
    }

    /// Remove a repository configuration key (`zig_vcs config --unset <key>`).
    pub fn unsetConfig(self: *RepoDb, key: []const u8) bool {
        for (self.configs.items, 0..) |cfg, idx| {
            if (std.mem.eql(u8, cfg.name, key)) {
                var removed = self.configs.orderedRemove(idx);
                removed.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    /// Resolve the commit author string from:
    /// 1. `explicit_author` (`--author "<author>"`)
    /// 2. `db.getConfig("user.name")` + optional `db.getConfig("user.email")`
    /// 3. Fallback `"user"`.
    pub fn resolveCommitAuthorAlloc(
        self: *const RepoDb,
        allocator: Allocator,
        explicit_author: ?[]const u8,
    ) ![]u8 {
        if (explicit_author) |ea| {
            return allocator.dupe(u8, ea);
        }
        if (self.getConfig("user.name")) |uname| {
            if (self.getConfig("user.email")) |uemail| {
                return std.fmt.allocPrint(allocator, "{s} <{s}>", .{ uname, uemail });
            }
            return allocator.dupe(u8, uname);
        }
        if (self.getConfig("user.email")) |uemail| {
            return allocator.dupe(u8, uemail);
        }
        return allocator.dupe(u8, "user");
    }

    /// Resolve a conflicted path in `wt_id` using an algebraic side projection strategy
    /// (`--ours` -> $B$, `--theirs` -> $C$, `--base` -> $A$, Lean 4 Theorem 8d `resolve_strategy_projects_ours_theirs_base`).
    pub fn resolveFileWithStrategy(
        self: *RepoDb,
        wt_id: WorktreeId,
        path: []const u8,
        strategy: ResolveStrategy,
    ) !void {
        const norm_path = try tree_sum.validateAndNormalizePath(self.allocator, path);
        defer self.allocator.free(norm_path);

        const cur_tid = self.worktrees.items[wt_id].working_tree_id;
        const cur_tree = self.trees.items[cur_tid];
        const sum = cur_tree.getPathSum(norm_path) orelse return error.FileNotFound;
        const mode = cur_tree.getPathMode(norm_path) orelse .regular;

        if (!sum.isConflicted()) return;

        const br_id = self.worktrees.items[wt_id].branch_id;
        const head_cid = self.branches.items[br_id].head_commit;
        const head_rec = self.commits.items[head_cid];

        const target_hash: ArtifactHash = if (sum.extractTwoSidedConflict()) |two_sided| blk_two: {
            if (strategy == .base) break :blk_two two_sided.base;

            // Identify which of the two `+1` terms in `B + C - A` is `ours` (`B`) vs `theirs` (`C`)
            // using the branch head commit (or its first parent `parent1` when `head_cid` is a merge commit).
            var ours_hash = two_sided.ours;
            var theirs_hash = two_sided.theirs;

            const ref_cid: CommitId = if (head_rec.parent2 != null and head_rec.parent1 != null)
                head_rec.parent1.?
            else
                head_cid;
            const ref_tree = self.trees.items[self.commits.items[ref_cid].root_tree_id];
            const ref_hash: ArtifactHash = if (ref_tree.getPathSum(norm_path)) |s|
                (s.getCleanHash() orelse ABSENT_HASH)
            else
                ABSENT_HASH;

            if (tree_sum.hashEql(ref_hash, two_sided.theirs)) {
                ours_hash = two_sided.theirs;
                theirs_hash = two_sided.ours;
            } else if (head_rec.parent2) |p2| {
                const p2_tree = self.trees.items[self.commits.items[p2].root_tree_id];
                const p2_hash: ArtifactHash = if (p2_tree.getPathSum(norm_path)) |s|
                    (s.getCleanHash() orelse ABSENT_HASH)
                else
                    ABSENT_HASH;
                if (tree_sum.hashEql(p2_hash, two_sided.ours)) {
                    ours_hash = two_sided.theirs;
                    theirs_hash = two_sided.ours;
                }
            }

            break :blk_two switch (strategy) {
                .ours => ours_hash,
                .theirs => theirs_hash,
                .base => two_sided.base,
            };
        } else blk: {
            switch (strategy) {
                .ours => {
                    for (sum.terms.items) |t| {
                        if (t.coeff > 0) break :blk t.hash;
                    }
                    break :blk ABSENT_HASH;
                },
                .theirs => {
                    var chosen: ArtifactHash = ABSENT_HASH;
                    for (sum.terms.items) |t| {
                        if (t.coeff > 0) chosen = t.hash;
                    }
                    break :blk chosen;
                },
                .base => {
                    for (sum.terms.items) |t| {
                        if (t.coeff < 0) break :blk t.hash;
                    }
                    break :blk ABSENT_HASH;
                },
            }
        };

        var manifest = try cur_tree.clone(self.allocator);
        var manifest_owned = true;
        errdefer if (manifest_owned) manifest.deinit(self.allocator);

        if (tree_sum.hashEql(target_hash, ABSENT_HASH)) {
            manifest.removePath(self.allocator, norm_path);
        } else {
            try manifest.setCleanFileWithMode(self.allocator, norm_path, target_hash, mode);
        }

        manifest_owned = false;
        const new_tid = try self.internTreeOwned(manifest);
        const head_tid = head_rec.root_tree_id;

        try self.recordOplog("resolve-strategy");
        self.clearRedoStack();
        self.worktrees.items[wt_id].working_tree_id = new_tid;
        self.worktrees.items[wt_id].is_dirty = (new_tid != head_tid);
    }

    /// Generate a per-file and total diffstat summary (`+insertions -deletions`) between `old_tid` and `new_tid` in O(F) sorted-cursor time.
    pub fn formatDiffStat(
        self: *const RepoDb,
        allocator: Allocator,
        old_tid: TreeId,
        new_tid: TreeId,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        const old_items = self.trees.items[old_tid].entries.items;
        const new_items = self.trees.items[new_tid].entries.items;

        var files_changed: usize = 0;
        var total_added: usize = 0;
        var total_deleted: usize = 0;

        var i_old: usize = 0;
        var i_new: usize = 0;

        while (i_old < old_items.len or i_new < new_items.len) {
            const ord: std.math.Order = if (i_old < old_items.len and i_new < new_items.len)
                std.mem.order(u8, old_items[i_old].path, new_items[i_new].path)
            else if (i_old < old_items.len)
                .lt
            else
                .gt;

            const path: []const u8 = switch (ord) {
                .lt => old_items[i_old].path,
                .gt => new_items[i_new].path,
                .eq => old_items[i_old].path,
            };
            const old_entry: ?tree_sum.PathEntry = switch (ord) {
                .lt, .eq => blk: {
                    const e = old_items[i_old];
                    i_old += 1;
                    break :blk e;
                },
                .gt => null,
            };
            const new_entry: ?tree_sum.PathEntry = switch (ord) {
                .gt, .eq => blk: {
                    const e = new_items[i_new];
                    i_new += 1;
                    break :blk e;
                },
                .lt => null,
            };

            const old_sum: ?PathSum = if (old_entry) |e| e.sum else null;
            const new_sum: ?PathSum = if (new_entry) |e| e.sum else null;
            const old_mode: FileMode = if (old_entry) |e| e.mode else .regular;
            const new_mode: FileMode = if (new_entry) |e| e.mode else .regular;

            if (old_sum != null and new_sum != null and old_sum.?.eql(new_sum.?) and old_mode == new_mode) {
                continue;
            }
            files_changed += 1;

            const old_bytes: []const u8 = if (old_sum) |os|
                (if (os.getCleanHash()) |h| (self.getBlob(h) orelse "") else "")
            else
                "";
            const new_bytes: []const u8 = if (new_sum) |ns|
                (if (ns.getCleanHash()) |h| (self.getBlob(h) orelse "") else "")
            else
                "";

            var file_added: usize = 0;
            var file_deleted: usize = 0;

            if (new_bytes.len > 0) {
                var it_new = std.mem.splitScalar(u8, std.mem.trimEnd(u8, new_bytes, "\n"), '\n');
                while (it_new.next()) |nl| {
                    if (!containsExactLine(old_bytes, nl)) file_added += 1;
                }
            }
            if (old_bytes.len > 0) {
                var it_old = std.mem.splitScalar(u8, std.mem.trimEnd(u8, old_bytes, "\n"), '\n');
                while (it_old.next()) |ol| {
                    if (!containsExactLine(new_bytes, ol)) file_deleted += 1;
                }
            }

            total_added += file_added;
            total_deleted += file_deleted;
            try out.print(allocator, " {s} | +{d} -{d}\n", .{ path, file_added, file_deleted });
        }

        try out.print(
            allocator,
            " {d} file(s) changed, {d} insertion(s)(+), {d} deletion(s)(-)\n",
            .{ files_changed, total_added, total_deleted },
        );
        return out.toOwnedSlice(allocator);
    }

    /// Zero-allocation O(F) 2-way sorted-cursor check testing whether `new_tid` modified, added,
    /// or deleted at least one file matching `path_filter` relative to `old_tid`
    /// (Lean 4 Theorem 10b `path_filtered_log_sound_and_complete`).
    pub fn treeModifiedUnderPathFilter(
        self: *const RepoDb,
        old_tid: TreeId,
        new_tid: TreeId,
        path_filter: []const u8,
    ) bool {
        if (old_tid == new_tid) return false;
        const old_items = self.trees.items[old_tid].entries.items;
        const new_items = self.trees.items[new_tid].entries.items;

        var i_old: usize = 0;
        var i_new: usize = 0;

        while (i_old < old_items.len or i_new < new_items.len) {
            const ord: std.math.Order = if (i_old < old_items.len and i_new < new_items.len)
                std.mem.order(u8, old_items[i_old].path, new_items[i_new].path)
            else if (i_old < old_items.len)
                .lt
            else
                .gt;

            switch (ord) {
                .lt => {
                    const p = old_items[i_old].path;
                    i_old += 1;
                    if (pathMatchesFilter(p, path_filter)) return true;
                },
                .gt => {
                    const p = new_items[i_new].path;
                    i_new += 1;
                    if (pathMatchesFilter(p, path_filter)) return true;
                },
                .eq => {
                    const oe = old_items[i_old];
                    const ne = new_items[i_new];
                    i_old += 1;
                    i_new += 1;
                    if (pathMatchesFilter(oe.path, path_filter)) {
                        if (oe.mode != ne.mode or !oe.sum.eql(ne.sum)) return true;
                    }
                },
            }
        }
        return false;
    }

    /// Format commit log with optional starting revision (`start_cid_opt`), maximum commit limit
    /// (`max_count_opt`), and per-commit diffstat (`include_stat`).
    pub fn formatCommitLogFiltered(
        self: *const RepoDb,
        allocator: Allocator,
        start_cid_opt: ?CommitId,
        max_count_opt: ?usize,
        include_stat: bool,
    ) ![]u8 {
        return self.formatCommitLogFilteredWithPath(
            allocator,
            start_cid_opt,
            max_count_opt,
            include_stat,
            null,
        );
    }

    /// Format commit log with optional starting revision (`start_cid_opt`), maximum commit limit
    /// (`max_count_opt`), per-commit diffstat (`include_stat`), and path prefix filter (`path_filter_opt`).
    pub fn formatCommitLogFilteredWithPath(
        self: *const RepoDb,
        allocator: Allocator,
        start_cid_opt: ?CommitId,
        max_count_opt: ?usize,
        include_stat: bool,
        path_filter_opt: ?[]const u8,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var emitted: usize = 0;
        var idx = if (start_cid_opt) |scid| (@min(scid, @as(CommitId, @intCast(self.commits.items.len - 1))) + 1) else self.commits.items.len;

        while (idx > 0) {
            idx -= 1;
            const cid: CommitId = @intCast(idx);
            if (start_cid_opt) |scid| {
                if (!self.isCommitAncestor(cid, scid)) continue;
            }
            const c = self.commits.items[idx];
            if (path_filter_opt) |pf| {
                if (c.id == 0) continue;
                const parent_cid = c.parent1 orelse 0;
                const parent_tid = self.commits.items[parent_cid].root_tree_id;
                if (!self.treeModifiedUnderPathFilter(parent_tid, c.root_tree_id, pf)) continue;
            }
            if (max_count_opt) |limit| {
                if (emitted >= limit) break;
            }
            emitted += 1;

            const tree = self.trees.items[c.root_tree_id];
            const conf_tag = if (tree.hasConflicts()) " [CONFLICTED]" else "";

            try out.print(allocator, "* commit c{d}", .{c.id});

            var first_dec = true;
            for (self.branches.items) |br| {
                if (br.head_commit == c.id) {
                    if (first_dec) {
                        try out.appendSlice(allocator, " (");
                        first_dec = false;
                    } else {
                        try out.appendSlice(allocator, ", ");
                    }
                    try out.print(allocator, "{s}", .{br.name});
                }
            }
            for (self.tags.items) |t| {
                if (t.target_commit == c.id) {
                    if (first_dec) {
                        try out.appendSlice(allocator, " (");
                        first_dec = false;
                    } else {
                        try out.appendSlice(allocator, ", ");
                    }
                    try out.print(allocator, "tag: {s}", .{t.name});
                }
            }
            if (!first_dec) try out.appendSlice(allocator, ")");

            if (c.parent1) |p1| {
                if (c.parent2) |p2| {
                    try out.print(allocator, " [merge: c{d} + c{d}]{s}\n", .{ p1, p2, conf_tag });
                } else {
                    try out.print(allocator, " [parent: c{d}]{s}\n", .{ p1, conf_tag });
                }
            } else {
                try out.print(allocator, " [root]{s}\n", .{conf_tag});
            }
            var date_buf: [25]u8 = undefined;
            const date_str = formatTimestampWithOffsetBuf(c.timestamp_sec, c.tz_offset_min, &date_buf);
            try out.print(allocator, "| Author: {s}\n| Date:   {s}\n|     {s}\n", .{ c.author, date_str, c.message });
            if (include_stat and c.id > 0) {
                const parent_cid = c.parent1 orelse 0;
                const stat_txt = try self.formatDiffStat(allocator, self.commits.items[parent_cid].root_tree_id, c.root_tree_id);
                defer allocator.free(stat_txt);
                try out.appendSlice(allocator, stat_txt);
            }
            try out.appendSlice(allocator, "|\n");
        }

        return out.toOwnedSlice(allocator);
    }

    fn appendJsonEscapedInner(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
        for (s) |ch| {
            switch (ch) {
                '"' => try out.appendSlice(allocator, "\\\""),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => {
                    if (ch < 0x20) {
                        try out.print(allocator, "\\u{x:0>4}", .{ch});
                    } else {
                        try out.append(allocator, ch);
                    }
                },
            }
        }
    }

    fn appendJsonEscaped(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
        try out.append(allocator, '"');
        try appendJsonEscapedInner(allocator, out, s);
        try out.append(allocator, '"');
    }

    /// Format repository & worktree status as machine-readable JSON (`zig-vcs status --json`).
    pub fn formatStatusJson(
        self: *const RepoDb,
        allocator: Allocator,
        wt_id: WorktreeId,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        const wt = self.worktrees.items[wt_id];
        const br = self.branches.items[wt.branch_id];
        const work_tree = self.trees.items[wt.working_tree_id];
        const head_tree = self.trees.items[self.commits.items[br.head_commit].root_tree_id];

        try out.print(
            allocator,
            "{{\"commits\":{d},\"trees\":{d},\"blobs\":{d},\"oplog\":{d},\"worktree\":{{\"id\":{d},\"name\":",
            .{
                self.commits.items.len,
                self.trees.items.len,
                self.blobs.items.len,
                self.oplog.items.len,
                wt.id,
            },
        );
        try appendJsonEscaped(allocator, &out, wt.name);
        try out.appendSlice(allocator, ",\"branch\":");
        try appendJsonEscaped(allocator, &out, br.name);
        try out.print(
            allocator,
            ",\"head_commit\":{d},\"is_dirty\":{s},\"is_open\":{s},\"has_conflicts\":{s},\"files\":[",
            .{
                br.head_commit,
                if (wt.is_dirty) "true" else "false",
                if (wt.is_open) "true" else "false",
                if (work_tree.hasConflicts()) "true" else "false",
            },
        );

        var first_f = true;
        for (work_tree.entries.items) |e| {
            if (!first_f) try out.append(allocator, ',');
            first_f = false;

            const status_str: []const u8 = if (e.sum.isConflicted())
                "conflicted"
            else if (head_tree.getPathSum(e.path)) |hs|
                (if (hs.eql(e.sum)) "clean" else "modified")
            else
                "added";

            try out.appendSlice(allocator, "{\"path\":");
            try appendJsonEscaped(allocator, &out, e.path);
            try out.print(
                allocator,
                ",\"status\":\"{s}\",\"mode\":{d},\"terms\":{d}}}",
                .{ status_str, @intFromEnum(e.mode), e.sum.terms.items.len },
            );
        }
        try out.appendSlice(allocator, "]}}\n");
        return out.toOwnedSlice(allocator);
    }

    /// Format compact 1-line-per-changed-file status (`zig-vcs status -s` / `--short`),
    /// using an $O(F)$ 2-way sorted cursor over `head_tree` and `work_tree`.
    pub fn formatStatusShort(
        self: *const RepoDb,
        allocator: Allocator,
        wt_id: WorktreeId,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        const wt = self.worktrees.items[wt_id];
        const br = self.branches.items[wt.branch_id];
        const work_items = self.trees.items[wt.working_tree_id].entries.items;
        const head_items = self.trees.items[self.commits.items[br.head_commit].root_tree_id].entries.items;

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
                    try out.print(allocator, "D  {s}\n", .{head_items[ih].path});
                    ih += 1;
                },
                .gt => {
                    const we = work_items[iw];
                    if (we.sum.isConflicted()) {
                        try out.print(allocator, "U  {s} ({d} terms)\n", .{ we.path, we.sum.terms.items.len });
                    } else {
                        try out.print(allocator, "A  {s}\n", .{we.path});
                    }
                    iw += 1;
                },
                .eq => {
                    const he = head_items[ih];
                    const we = work_items[iw];
                    if (we.sum.isConflicted()) {
                        try out.print(allocator, "U  {s} ({d} terms)\n", .{ we.path, we.sum.terms.items.len });
                    } else if (he.mode != we.mode or !he.sum.eql(we.sum)) {
                        try out.print(allocator, "M  {s}\n", .{we.path});
                    }
                    ih += 1;
                    iw += 1;
                },
            }
        }
        return out.toOwnedSlice(allocator);
    }

    /// Format compact 1-line-per-commit log (`zig-vcs log --oneline`) with optional range and path filter.
    pub fn formatCommitLogOneline(
        self: *const RepoDb,
        allocator: Allocator,
        base_cid_opt: ?CommitId,
        start_cid_opt: ?CommitId,
        max_count_opt: ?usize,
        path_filter_opt: ?[]const u8,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var emitted: usize = 0;
        var idx = if (start_cid_opt) |scid| (@min(scid, @as(CommitId, @intCast(self.commits.items.len - 1))) + 1) else self.commits.items.len;

        while (idx > 0) {
            idx -= 1;
            const cid: CommitId = @intCast(idx);
            if (start_cid_opt) |scid| {
                if (!self.isCommitAncestor(cid, scid)) continue;
            }
            if (base_cid_opt) |bcid| {
                if (self.isCommitAncestor(cid, bcid)) continue;
            }
            const c = self.commits.items[idx];
            if (path_filter_opt) |pf| {
                if (c.id == 0) continue;
                const parent_cid = c.parent1 orelse 0;
                const parent_tid = self.commits.items[parent_cid].root_tree_id;
                if (!self.treeModifiedUnderPathFilter(parent_tid, c.root_tree_id, pf)) continue;
            }
            if (max_count_opt) |limit| {
                if (emitted >= limit) break;
            }
            emitted += 1;

            try out.print(allocator, "c{d}", .{c.id});

            var first_dec = true;
            for (self.branches.items) |br| {
                if (br.head_commit == c.id) {
                    if (first_dec) {
                        try out.appendSlice(allocator, " (");
                        first_dec = false;
                    } else {
                        try out.appendSlice(allocator, ", ");
                    }
                    try out.print(allocator, "{s}", .{br.name});
                }
            }
            for (self.tags.items) |t| {
                if (t.target_commit == c.id) {
                    if (first_dec) {
                        try out.appendSlice(allocator, " (");
                        first_dec = false;
                    } else {
                        try out.appendSlice(allocator, ", ");
                    }
                    try out.print(allocator, "tag: {s}", .{t.name});
                }
            }
            if (!first_dec) try out.appendSlice(allocator, ")");
            if (self.trees.items[c.root_tree_id].hasConflicts()) {
                try out.appendSlice(allocator, " [CONFLICTED]");
            }
            try out.print(allocator, " {s}\n", .{c.message});
        }
        return out.toOwnedSlice(allocator);
    }

    /// Format commit log as machine-readable JSON (`zig-vcs log --json`).
    pub fn formatCommitLogJson(
        self: *const RepoDb,
        allocator: Allocator,
        start_cid_opt: ?CommitId,
        max_count_opt: ?usize,
        path_filter_opt: ?[]const u8,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "{\"commits\":[");
        var emitted: usize = 0;
        var idx = if (start_cid_opt) |scid| (@min(scid, @as(CommitId, @intCast(self.commits.items.len - 1))) + 1) else self.commits.items.len;

        while (idx > 0) {
            idx -= 1;
            const cid: CommitId = @intCast(idx);
            if (start_cid_opt) |scid| {
                if (!self.isCommitAncestor(cid, scid)) continue;
            }
            const c = self.commits.items[idx];
            if (path_filter_opt) |pf| {
                if (c.id == 0) continue;
                const parent_cid = c.parent1 orelse 0;
                const parent_tid = self.commits.items[parent_cid].root_tree_id;
                if (!self.treeModifiedUnderPathFilter(parent_tid, c.root_tree_id, pf)) continue;
            }
            if (max_count_opt) |limit| {
                if (emitted >= limit) break;
            }
            if (emitted > 0) try out.append(allocator, ',');
            emitted += 1;

            const tree = self.trees.items[c.root_tree_id];
            try out.print(allocator, "{{\"id\":{d},\"parent1\":", .{c.id});
            if (c.parent1) |p1| {
                try out.print(allocator, "{d}", .{p1});
            } else {
                try out.appendSlice(allocator, "null");
            }
            try out.appendSlice(allocator, ",\"parent2\":");
            if (c.parent2) |p2| {
                try out.print(allocator, "{d}", .{p2});
            } else {
                try out.appendSlice(allocator, "null");
            }
            try out.appendSlice(allocator, ",\"author\":");
            try appendJsonEscaped(allocator, &out, c.author);
            try out.appendSlice(allocator, ",\"message\":");
            try appendJsonEscaped(allocator, &out, c.message);
            try out.print(
                allocator,
                ",\"timestamp\":{d},\"has_conflicts\":{s},\"files\":[",
                .{ c.timestamp_sec, if (tree.hasConflicts()) "true" else "false" },
            );
            if (c.id > 0) {
                const parent_cid = c.parent1 orelse 0;
                const parent_tid = self.commits.items[parent_cid].root_tree_id;
                const old_items = self.trees.items[parent_tid].entries.items;
                const new_items = tree.entries.items;
                var i_old: usize = 0;
                var i_new: usize = 0;
                var file_emitted: usize = 0;
                while ((i_old < old_items.len or i_new < new_items.len) and file_emitted < 16) {
                    const ord: std.math.Order = if (i_old < old_items.len and i_new < new_items.len)
                        std.mem.order(u8, old_items[i_old].path, new_items[i_new].path)
                    else if (i_old < old_items.len)
                        .lt
                    else
                        .gt;
                    switch (ord) {
                        .lt => {
                            if (file_emitted > 0) try out.append(allocator, ',');
                            file_emitted += 1;
                            try out.appendSlice(allocator, "\"D:");
                            try appendJsonEscapedInner(allocator, &out, old_items[i_old].path);
                            try out.append(allocator, '"');
                            i_old += 1;
                        },
                        .gt => {
                            if (file_emitted > 0) try out.append(allocator, ',');
                            file_emitted += 1;
                            const st_ch: u8 = if (new_items[i_new].sum.isConflicted()) 'U' else 'A';
                            try out.print(allocator, "\"{c}:", .{st_ch});
                            try appendJsonEscapedInner(allocator, &out, new_items[i_new].path);
                            try out.append(allocator, '"');
                            i_new += 1;
                        },
                        .eq => {
                            const oe = old_items[i_old];
                            const ne = new_items[i_new];
                            i_old += 1;
                            i_new += 1;
                            if (!oe.sum.eql(ne.sum) or oe.mode != ne.mode) {
                                if (file_emitted > 0) try out.append(allocator, ',');
                                file_emitted += 1;
                                const st_ch: u8 = if (ne.sum.isConflicted()) 'U' else 'M';
                                try out.print(allocator, "\"{c}:", .{st_ch});
                                try appendJsonEscapedInner(allocator, &out, ne.path);
                                try out.append(allocator, '"');
                            }
                        },
                    }
                }
            }
            try out.appendSlice(allocator, "]}");
        }
        try out.appendSlice(allocator, "]}\n");
        return out.toOwnedSlice(allocator);
    }

    /// Format branches as machine-readable JSON (`zig-vcs branch --json`).
    pub fn formatBranchesJson(
        self: *const RepoDb,
        allocator: Allocator,
        active_wt_id: WorktreeId,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        const active_br = self.worktrees.items[active_wt_id].branch_id;
        try out.appendSlice(allocator, "{\"branches\":[");
        for (self.branches.items, 0..) |br, idx| {
            if (idx > 0) try out.append(allocator, ',');
            try out.print(allocator, "{{\"id\":{d},\"name\":", .{br.id});
            try appendJsonEscaped(allocator, &out, br.name);
            try out.print(
                allocator,
                ",\"head_commit\":{d},\"is_current\":{s}}}",
                .{ br.head_commit, if (br.id == active_br) "true" else "false" },
            );
        }
        try out.appendSlice(allocator, "]}\n");
        return out.toOwnedSlice(allocator);
    }

    /// Format worktrees as machine-readable JSON (`zig-vcs worktree --json`).
    pub fn formatWorktreesJson(self: *const RepoDb, allocator: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "{\"worktrees\":[");
        for (self.worktrees.items, 0..) |wt, idx| {
            if (idx > 0) try out.append(allocator, ',');
            const br_name = self.branches.items[wt.branch_id].name;
            try out.print(allocator, "{{\"id\":{d},\"name\":", .{wt.id});
            try appendJsonEscaped(allocator, &out, wt.name);
            try out.appendSlice(allocator, ",\"path\":");
            try appendJsonEscaped(allocator, &out, wt.fs_path);
            try out.appendSlice(allocator, ",\"branch\":");
            try appendJsonEscaped(allocator, &out, br_name);
            try out.print(
                allocator,
                ",\"is_dirty\":{s},\"is_open\":{s}}}",
                .{
                    if (wt.is_dirty) "true" else "false",
                    if (wt.is_open) "true" else "false",
                },
            );
        }
        try out.appendSlice(allocator, "]}\n");
        return out.toOwnedSlice(allocator);
    }

    /// Format commit log with optional revision range (`base_cid..head_cid`, Lean 4 Theorem 11b),
    /// maximum commit limit (`max_count_opt`), per-commit diffstat (`include_stat`), and path filter.
    pub fn formatCommitLogRange(
        self: *const RepoDb,
        allocator: Allocator,
        base_cid_opt: ?CommitId,
        start_cid_opt: ?CommitId,
        max_count_opt: ?usize,
        include_stat: bool,
        path_filter_opt: ?[]const u8,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var emitted: usize = 0;
        var idx = if (start_cid_opt) |scid| (@min(scid, @as(CommitId, @intCast(self.commits.items.len - 1))) + 1) else self.commits.items.len;

        while (idx > 0) {
            idx -= 1;
            const cid: CommitId = @intCast(idx);
            if (start_cid_opt) |scid| {
                if (!self.isCommitAncestor(cid, scid)) continue;
            }
            if (base_cid_opt) |bcid| {
                if (self.isCommitAncestor(cid, bcid)) continue;
            }
            const c = self.commits.items[idx];
            if (path_filter_opt) |pf| {
                if (c.id == 0) continue;
                const parent_cid = c.parent1 orelse 0;
                const parent_tid = self.commits.items[parent_cid].root_tree_id;
                if (!self.treeModifiedUnderPathFilter(parent_tid, c.root_tree_id, pf)) continue;
            }
            if (max_count_opt) |limit| {
                if (emitted >= limit) break;
            }
            emitted += 1;

            const tree = self.trees.items[c.root_tree_id];
            const conf_tag = if (tree.hasConflicts()) " [CONFLICTED]" else "";

            try out.print(allocator, "* commit c{d}", .{c.id});

            var first_dec = true;
            for (self.branches.items) |br| {
                if (br.head_commit == c.id) {
                    if (first_dec) {
                        try out.appendSlice(allocator, " (");
                        first_dec = false;
                    } else {
                        try out.appendSlice(allocator, ", ");
                    }
                    try out.print(allocator, "{s}", .{br.name});
                }
            }
            for (self.tags.items) |t| {
                if (t.target_commit == c.id) {
                    if (first_dec) {
                        try out.appendSlice(allocator, " (");
                        first_dec = false;
                    } else {
                        try out.appendSlice(allocator, ", ");
                    }
                    try out.print(allocator, "tag: {s}", .{t.name});
                }
            }
            if (!first_dec) try out.appendSlice(allocator, ")");

            if (c.parent1) |p1| {
                if (c.parent2) |p2| {
                    try out.print(allocator, " [merge: c{d} + c{d}]{s}\n", .{ p1, p2, conf_tag });
                } else {
                    try out.print(allocator, " [parent: c{d}]{s}\n", .{ p1, conf_tag });
                }
            } else {
                try out.print(allocator, " [root]{s}\n", .{conf_tag});
            }
            var date_buf: [25]u8 = undefined;
            const date_str = formatTimestampWithOffsetBuf(c.timestamp_sec, c.tz_offset_min, &date_buf);
            try out.print(allocator, "| Author: {s}\n| Date:   {s}\n|     {s}\n", .{ c.author, date_str, c.message });
            if (include_stat and c.id > 0) {
                const parent_cid = c.parent1 orelse 0;
                const stat_txt = try self.formatDiffStat(allocator, self.commits.items[parent_cid].root_tree_id, c.root_tree_id);
                defer allocator.free(stat_txt);
                try out.appendSlice(allocator, stat_txt);
            }
            try out.appendSlice(allocator, "|\n");
        }

        return out.toOwnedSlice(allocator);
    }

    /// Format commit log as machine-readable JSON with optional revision range (`base_cid..head_cid`).
    pub fn formatCommitLogJsonRange(
        self: *const RepoDb,
        allocator: Allocator,
        base_cid_opt: ?CommitId,
        start_cid_opt: ?CommitId,
        max_count_opt: ?usize,
        path_filter_opt: ?[]const u8,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "{\"commits\":[");
        var emitted: usize = 0;
        var idx = if (start_cid_opt) |scid| (@min(scid, @as(CommitId, @intCast(self.commits.items.len - 1))) + 1) else self.commits.items.len;

        while (idx > 0) {
            idx -= 1;
            const cid: CommitId = @intCast(idx);
            if (start_cid_opt) |scid| {
                if (!self.isCommitAncestor(cid, scid)) continue;
            }
            if (base_cid_opt) |bcid| {
                if (self.isCommitAncestor(cid, bcid)) continue;
            }
            const c = self.commits.items[idx];
            if (path_filter_opt) |pf| {
                if (c.id == 0) continue;
                const parent_cid = c.parent1 orelse 0;
                const parent_tid = self.commits.items[parent_cid].root_tree_id;
                if (!self.treeModifiedUnderPathFilter(parent_tid, c.root_tree_id, pf)) continue;
            }
            if (max_count_opt) |limit| {
                if (emitted >= limit) break;
            }
            if (emitted > 0) try out.append(allocator, ',');
            emitted += 1;

            const tree = self.trees.items[c.root_tree_id];
            try out.print(allocator, "{{\"id\":{d},\"parent1\":", .{c.id});
            if (c.parent1) |p1| {
                try out.print(allocator, "{d}", .{p1});
            } else {
                try out.appendSlice(allocator, "null");
            }
            try out.appendSlice(allocator, ",\"parent2\":");
            if (c.parent2) |p2| {
                try out.print(allocator, "{d}", .{p2});
            } else {
                try out.appendSlice(allocator, "null");
            }
            try out.appendSlice(allocator, ",\"author\":");
            try appendJsonEscaped(allocator, &out, c.author);
            try out.appendSlice(allocator, ",\"message\":");
            try appendJsonEscaped(allocator, &out, c.message);
            try out.print(
                allocator,
                ",\"timestamp\":{d},\"has_conflicts\":{s},\"files\":[",
                .{ c.timestamp_sec, if (tree.hasConflicts()) "true" else "false" },
            );
            if (c.id > 0) {
                const parent_cid = c.parent1 orelse 0;
                const parent_tid = self.commits.items[parent_cid].root_tree_id;
                const old_items = self.trees.items[parent_tid].entries.items;
                const new_items = tree.entries.items;
                var i_old: usize = 0;
                var i_new: usize = 0;
                var file_emitted: usize = 0;
                while ((i_old < old_items.len or i_new < new_items.len) and file_emitted < 16) {
                    const ord: std.math.Order = if (i_old < old_items.len and i_new < new_items.len)
                        std.mem.order(u8, old_items[i_old].path, new_items[i_new].path)
                    else if (i_old < old_items.len)
                        .lt
                    else
                        .gt;
                    switch (ord) {
                        .lt => {
                            if (file_emitted > 0) try out.append(allocator, ',');
                            file_emitted += 1;
                            try out.appendSlice(allocator, "\"D:");
                            try appendJsonEscapedInner(allocator, &out, old_items[i_old].path);
                            try out.append(allocator, '"');
                            i_old += 1;
                        },
                        .gt => {
                            if (file_emitted > 0) try out.append(allocator, ',');
                            file_emitted += 1;
                            const st_ch: u8 = if (new_items[i_new].sum.isConflicted()) 'U' else 'A';
                            try out.print(allocator, "\"{c}:", .{st_ch});
                            try appendJsonEscapedInner(allocator, &out, new_items[i_new].path);
                            try out.append(allocator, '"');
                            i_new += 1;
                        },
                        .eq => {
                            const oe = old_items[i_old];
                            const ne = new_items[i_new];
                            i_old += 1;
                            i_new += 1;
                            if (!oe.sum.eql(ne.sum) or oe.mode != ne.mode) {
                                if (file_emitted > 0) try out.append(allocator, ',');
                                file_emitted += 1;
                                const st_ch: u8 = if (ne.sum.isConflicted()) 'U' else 'M';
                                try out.print(allocator, "\"{c}:", .{st_ch});
                                try appendJsonEscapedInner(allocator, &out, ne.path);
                                try out.append(allocator, '"');
                            }
                        },
                    }
                }
            }
            try out.appendSlice(allocator, "]}");
        }
        try out.appendSlice(allocator, "]}\n");
        return out.toOwnedSlice(allocator);
    }

    /// Format saved per-`(worktree_id, branch_id)` drafts as human-readable text (`zig-vcs draft list`).
    pub fn formatDraftsList(self: *const RepoDb, allocator: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        if (self.drafts.items.len == 0) {
            try out.appendSlice(allocator, "No shelved drafts in repository.\n");
            return out.toOwnedSlice(allocator);
        }

        for (self.drafts.items) |d| {
            const wt_name = self.worktrees.items[d.worktree_id].name;
            const br = self.branches.items[d.branch_id];
            const head_tid = self.commits.items[br.head_commit].root_tree_id;
            const counts = countTreeDeltaOps(self.trees.items[head_tid], self.trees.items[d.tree_id]);
            try out.print(
                allocator,
                "wt{d} ({s})\tbranch={s} (base=c{d})\ttree=#{d}\tchanges={d} (+/~{d} -{d})\n",
                .{
                    d.worktree_id,
                    wt_name,
                    br.name,
                    br.head_commit,
                    d.tree_id,
                    counts.upserts + counts.deletes,
                    counts.upserts,
                    counts.deletes,
                },
            );
        }
        return out.toOwnedSlice(allocator);
    }

    /// Format saved per-`(worktree_id, branch_id)` drafts as machine-readable JSON (`zig-vcs draft list --json`).
    pub fn formatDraftsJson(self: *const RepoDb, allocator: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "{\"drafts\":[");
        for (self.drafts.items, 0..) |d, idx| {
            if (idx > 0) try out.append(allocator, ',');
            const wt_name = self.worktrees.items[d.worktree_id].name;
            const br = self.branches.items[d.branch_id];
            const head_tid = self.commits.items[br.head_commit].root_tree_id;
            const counts = countTreeDeltaOps(self.trees.items[head_tid], self.trees.items[d.tree_id]);
            try out.print(allocator, "{{\"worktree_id\":{d},\"worktree\":", .{d.worktree_id});
            try appendJsonEscaped(allocator, &out, wt_name);
            try out.appendSlice(allocator, ",\"branch\":");
            try appendJsonEscaped(allocator, &out, br.name);
            try out.print(
                allocator,
                ",\"base_commit\":{d},\"tree_id\":{d},\"upserts\":{d},\"deletes\":{d}}}",
                .{ br.head_commit, d.tree_id, counts.upserts, counts.deletes },
            );
        }
        try out.appendSlice(allocator, "]}\n");
        return out.toOwnedSlice(allocator);
    }

    /// Show unified diff of a shelved draft on `branch_name` relative to its branch `head_commit`
    /// (`zig-vcs draft show [branch]`).
    pub fn showBranchDraftDiff(
        self: *const RepoDb,
        allocator: Allocator,
        wt_id: WorktreeId,
        branch_name: []const u8,
    ) ![]u8 {
        const br_id = self.findBranchByName(branch_name) orelse return error.BranchNotFound;
        const draft_tid = self.getDraft(wt_id, br_id) orelse blk: {
            for (self.drafts.items) |d| {
                if (d.branch_id == br_id) break :blk d.tree_id;
            }
            return error.DraftNotFound;
        };
        const head_cid = self.branches.items[br_id].head_commit;
        const head_tid = self.commits.items[head_cid].root_tree_id;
        return self.diffTreesUnifiedFiltered(allocator, head_tid, draft_tid, null);
    }

    /// Algebraically apply a shelved draft from `src_branch_name` onto `wt_id`'s active working tree
    /// (`T_active + T_draft(b) - T_head(b)` in `Z[A_bot]`, Lean 4 Theorem 11a `draft_apply_identity_and_inverse`).
    pub fn applyBranchDraft(
        self: *RepoDb,
        wt_id: WorktreeId,
        src_branch_name: []const u8,
    ) !TreeId {
        if (wt_id >= self.worktrees.items.len) return error.InvalidWorktreeId;
        const src_br_id = self.findBranchByName(src_branch_name) orelse return error.BranchNotFound;

        const draft_tid = self.getDraft(wt_id, src_br_id) orelse blk: {
            for (self.drafts.items) |d| {
                if (d.branch_id == src_br_id) break :blk d.tree_id;
            }
            return error.DraftNotFound;
        };

        try self.recordOplog("draft-apply");

        const src_head_cid = self.branches.items[src_br_id].head_commit;
        const src_head_tid = self.commits.items[src_head_cid].root_tree_id;
        const active_tid = self.worktrees.items[wt_id].working_tree_id;

        const merged_tid = try self.mergeTreeIds(src_head_tid, active_tid, draft_tid);
        const cur_br_id = self.worktrees.items[wt_id].branch_id;
        const cur_head_tid = self.commits.items[self.branches.items[cur_br_id].head_commit].root_tree_id;

        self.worktrees.items[wt_id].working_tree_id = merged_tid;
        self.worktrees.items[wt_id].is_dirty = (merged_tid != cur_head_tid);
        return merged_tid;
    }

    /// Discard a shelved draft for `branch_name` (`zig-vcs draft drop <branch>`) with atomic
    /// `oplog` undo/redo invertibility (`INV-6`).
    pub fn dropBranchDraft(
        self: *RepoDb,
        wt_id: WorktreeId,
        branch_name: []const u8,
    ) !bool {
        const br_id = self.findBranchByName(branch_name) orelse return error.BranchNotFound;
        var found_wt: ?WorktreeId = if (self.getDraft(wt_id, br_id) != null) wt_id else null;
        if (found_wt == null) {
            for (self.drafts.items) |d| {
                if (d.branch_id == br_id) {
                    found_wt = d.worktree_id;
                    break;
                }
            }
        }
        const target_wt = found_wt orelse return false;
        try self.recordOplog("draft-drop");
        try self.setDraft(target_wt, br_id, null);
        return true;
    }

    /// Restore any arbitrary historical `OplogEntry` at `index` (`zig-vcs oplog restore <index>`,
    /// Lean 4 Theorem 13b `oplog_restore_idx_invertible`):
    /// Prepends the current mutable view to `oplog` prior to adopting `oplog[index]`, making
    /// the time-travel jump itself immediately undoable via a single `zig-vcs undo` (`INV-6`).
    pub fn restoreOplogAtIndex(self: *RepoDb, index: usize) !void {
        if (index >= self.oplog.items.len) return error.InvalidOplogIndex;
        try self.recordOplog("oplog-restore");
        errdefer self.abortLastOplog();
        try self.restoreFromSnapshot(self.oplog.items[index]);
        self.clearRedoStack();
    }

    /// Format the transactional operation log as machine-readable JSON (`zig-vcs oplog --json`).
    pub fn formatOplogJson(
        self: *const RepoDb,
        allocator: Allocator,
        max_count_opt: ?usize,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "{\"oplog\":[");
        var emitted: usize = 0;
        var idx = self.oplog.items.len;
        while (idx > 0) {
            idx -= 1;
            if (max_count_opt) |limit| {
                if (emitted >= limit) break;
            }
            if (emitted > 0) try out.append(allocator, ',');
            emitted += 1;

            const op = self.oplog.items[idx];
            try out.print(allocator, "{{\"index\":{d},\"command\":", .{idx});
            try appendJsonEscaped(allocator, &out, op.command_desc);
            try out.print(
                allocator,
                ",\"branches\":{d},\"worktrees\":{d},\"drafts\":{d}}}",
                .{ op.branches.items.len, op.worktrees.items.len, op.drafts.items.len },
            );
        }
        try out.appendSlice(allocator, "]}\n");
        return out.toOwnedSlice(allocator);
    }

    /// Zero-Checkout Deterministic POSIX USTAR `.tar` Archive Exporter
    /// (`zig-vcs archive <output.tar> [rev] [--prefix <dir>/]`):
    /// Exports any commit, branch, or tag tree directly from `.vcs/db.vcs` into a standard
    /// 512-byte blocked POSIX `ustar` archive, preserving `FileMode` (`0644`, `0755`, `0120000`
    /// symlinks) and commit timestamp deterministically.
    pub fn exportRevisionTarBytes(
        self: *const RepoDb,
        allocator: Allocator,
        cid: CommitId,
        prefix_raw: []const u8,
    ) ![]u8 {
        if (cid >= self.commits.items.len) return error.InvalidCommitId;
        const c = self.commits.items[cid];
        const tree = self.trees.items[c.root_tree_id];
        const mtime: u64 = if (c.timestamp_sec > 0) @intCast(c.timestamp_sec) else 1700000000;
        const prefix = std.mem.trim(u8, prefix_raw, "/");

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        for (tree.entries.items) |e| {
            var full_path_buf: std.ArrayList(u8) = .empty;
            defer full_path_buf.deinit(allocator);
            if (prefix.len > 0) {
                try full_path_buf.print(allocator, "{s}/{s}", .{ prefix, e.path });
            } else {
                try full_path_buf.appendSlice(allocator, e.path);
            }
            const tar_path = full_path_buf.items;
            if (tar_path.len > 99) return error.TarPathTooLong;

            var rendered_owned: ?[]u8 = null;
            defer if (rendered_owned) |ro| allocator.free(ro);

            const content: []const u8 = if (e.sum.getCleanHash()) |h|
                (self.getBlob(h) orelse "")
            else blk: {
                var cbuf: std.ArrayList(u8) = .empty;
                errdefer cbuf.deinit(allocator);
                try cbuf.print(allocator, "<conflicted PathSum ({d} terms in Z[A_bot])>\n", .{e.sum.terms.items.len});
                const r = try cbuf.toOwnedSlice(allocator);
                rendered_owned = r;
                break :blk r;
            };

            var hdr: [512]u8 = @splat(0);
            @memcpy(hdr[0..tar_path.len], tar_path);

            const is_symlink = (e.mode == .symlink and tar_path.len <= 99 and content.len <= 99);
            const mode_octal: u32 = switch (e.mode) {
                .executable => 0o755,
                .symlink => 0o777,
                .regular => 0o644,
            };
            _ = std.fmt.bufPrint(hdr[100..107], "{o:0>7}", .{mode_octal}) catch unreachable;
            _ = std.fmt.bufPrint(hdr[108..115], "{o:0>7}", .{@as(u32, 0)}) catch unreachable;
            _ = std.fmt.bufPrint(hdr[116..123], "{o:0>7}", .{@as(u32, 0)}) catch unreachable;

            const payload_size: usize = if (is_symlink) 0 else content.len;
            _ = std.fmt.bufPrint(hdr[124..135], "{o:0>11}", .{payload_size}) catch unreachable;
            _ = std.fmt.bufPrint(hdr[136..147], "{o:0>11}", .{mtime}) catch unreachable;

            // Fill checksum field `[148..156]` with spaces before summing
            @memset(hdr[148..156], ' ');
            hdr[156] = if (is_symlink) '2' else '0';
            if (is_symlink) {
                @memcpy(hdr[157 .. 157 + content.len], content);
            }
            @memcpy(hdr[257..263], "ustar\x00");
            @memcpy(hdr[263..265], "00");

            var chksum: u32 = 0;
            for (hdr) |b| chksum += b;
            _ = std.fmt.bufPrint(hdr[148..154], "{o:0>6}", .{chksum}) catch unreachable;
            hdr[154] = 0;
            hdr[155] = ' ';

            try out.appendSlice(allocator, &hdr);
            if (payload_size > 0) {
                try out.appendSlice(allocator, content);
                const rem = payload_size % 512;
                if (rem != 0) {
                    const pad = 512 - rem;
                    try out.appendNTimes(allocator, 0, pad);
                }
            }
        }

        // Standard 2x512-byte zero EOF blocks
        try out.appendNTimes(allocator, 0, 1024);
        return out.toOwnedSlice(allocator);
    }

    fn pathMatchesFilter(path: []const u8, filter_raw: []const u8) bool {
        const filter = std.mem.trim(u8, filter_raw, "/");
        if (filter.len == 0) return true;
        if (std.mem.eql(u8, path, filter)) return true;
        if (std.mem.startsWith(u8, path, filter) and path.len > filter.len and path[filter.len] == '/') {
            return true;
        }
        return false;
    }

    fn pathMatchesAnyFilter(path: []const u8, filters: []const []const u8) bool {
        for (filters) |f| {
            if (pathMatchesFilter(path, f)) return true;
        }
        return false;
    }

    /// Path-Selective Commit (`zig-vcs commit "<message>" <path1> [path2 ...]`, Lean 4 Theorem 9a
    /// `selective_commit_partition_conservation`):
    /// Commits only the paths matching `path_filters` from `wt_id`'s working tree while leaving
    /// all other uncommitted edits intact in `wt_id` (`wt.working_tree_id` remains unchanged,
    /// and `wt.is_dirty` is updated to `wt.working_tree_id != commit_tid`).
    pub fn commitWorktreePaths(
        self: *RepoDb,
        wt_id: WorktreeId,
        author: []const u8,
        message: []const u8,
        path_filters: []const []const u8,
    ) !CommitId {
        if (path_filters.len == 0) {
            return self.commitWorktree(wt_id, author, message);
        }

        const wt = self.worktrees.items[wt_id];
        const br_id = wt.branch_id;
        const old_head_cid = self.branches.items[br_id].head_commit;
        const head_tid = self.commits.items[old_head_cid].root_tree_id;
        const work_tid = wt.working_tree_id;

        const head_tree = self.trees.items[head_tid];
        const work_tree = self.trees.items[work_tid];

        var commit_manifest = try head_tree.clone(self.allocator);
        var manifest_owned = true;
        errdefer if (manifest_owned) commit_manifest.deinit(self.allocator);

        // 1. Remove any path in `head_tree` matching `path_filters` that was deleted in `work_tree`
        for (head_tree.entries.items) |he| {
            if (pathMatchesAnyFilter(he.path, path_filters)) {
                if (work_tree.getPathSum(he.path) == null) {
                    commit_manifest.removePath(self.allocator, he.path);
                }
            }
        }

        // 2. Copy any path in `work_tree` matching `path_filters` into `commit_manifest`
        for (work_tree.entries.items) |we| {
            if (pathMatchesAnyFilter(we.path, path_filters)) {
                const cloned_sum = try we.sum.clone(self.allocator);
                try commit_manifest.setPathSumWithModeOwned(self.allocator, we.path, cloned_sum, we.mode);
            }
        }

        manifest_owned = false;
        const commit_tid = try self.internTreeOwned(commit_manifest);

        // 3. Commit `commit_tid` onto `br_id` while preserving `work_tid` as `wt_id`'s working tree!
        const new_cid = try self.finalizeWorktreeCommitOnBranch(
            wt_id,
            br_id,
            old_head_cid,
            null,
            commit_tid,
            author,
            message,
            "commit-paths",
        );

        // Restore `wt_id`'s remaining uncommitted changes (`work_tid`) if any paths were left uncommitted
        self.worktrees.items[wt_id].working_tree_id = work_tid;
        self.worktrees.items[wt_id].is_dirty = (work_tid != commit_tid);
        return new_cid;
    }

    /// Algebraic Commit Squash (`zig-vcs squash [commit_id] [message]`, Lean 4 Theorem 9b
    /// `squash_cascade_preserves_descendants`):
    /// Folds `child_cid` (defaults to the current branch head commit) into its first parent
    /// `parent_cid`, automatically cascading and rebasing all descendant commits, branches,
    /// tags, worktrees, and shelved drafts in a single atomic `"squash"` oplog entry (`INV-1`..`INV-6`).
    pub fn squashCommit(
        self: *RepoDb,
        wt_id: WorktreeId,
        target_cid_opt: ?CommitId,
        new_message_opt: ?[]const u8,
    ) !CommitId {
        const br_id = self.worktrees.items[wt_id].branch_id;
        const child_cid = target_cid_opt orelse self.branches.items[br_id].head_commit;
        if (child_cid == 0 or child_cid >= self.commits.items.len) return error.CannotSquashRootCommit;

        const child_rec = self.commits.items[child_cid];
        const parent_cid = child_rec.parent1 orelse return error.CannotSquashRootCommit;
        if (parent_cid == 0) return error.CannotSquashRootCommit;

        const parent_rec = self.commits.items[parent_cid];
        const parent_tid = parent_rec.root_tree_id;
        const child_tid = child_rec.root_tree_id;

        // If `child_cid` had a different parent than `parent_cid`, algebraically fold `child` onto `parent`;
        // when `child.parent1 == parent_cid`, `mergeTreeIds(parent_tid, parent_tid, child_tid) == child_tid` (Theorem 9b).
        const squashed_tid = try self.mergeTreeIds(parent_tid, parent_tid, child_tid);

        const sq_author = try self.allocator.dupe(u8, parent_rec.author);
        defer self.allocator.free(sq_author);
        const sq_msg = if (new_message_opt) |m|
            try self.allocator.dupe(u8, m)
        else
            try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ parent_rec.message, child_rec.message });
        defer self.allocator.free(sq_msg);

        var remap = std.AutoHashMap(CommitId, CommitId).init(self.allocator);
        defer remap.deinit();

        const initial_commit_count = self.commits.items.len;
        const new_sq_cid = try self.appendCommit(
            parent_rec.parent1,
            parent_rec.parent2,
            squashed_tid,
            sq_author,
            sq_msg,
        );
        try remap.put(parent_cid, new_sq_cid);
        try remap.put(child_cid, new_sq_cid);

        // Cascade to all descendants of `parent_cid` or `child_cid`
        for ((parent_cid + 1)..initial_commit_count) |cid_usize| {
            const cid: CommitId = @intCast(cid_usize);
            if (cid == child_cid) continue;

            const rec = self.commits.items[cid];
            const mapped_p1 = if (rec.parent1) |p1| remap.get(p1) else null;
            const mapped_p2 = if (rec.parent2) |p2| remap.get(p2) else null;
            if (mapped_p1 == null and mapped_p2 == null) continue;

            var cascaded_tid = rec.root_tree_id;
            if (mapped_p1) |new_p1| {
                const old_p1 = rec.parent1.?;
                const old_p1_tid = self.commits.items[old_p1].root_tree_id;
                const new_p1_tid = self.commits.items[new_p1].root_tree_id;
                cascaded_tid = try self.mergeTreeIds(old_p1_tid, cascaded_tid, new_p1_tid);
            }
            if (mapped_p2) |new_p2| {
                const old_p2 = rec.parent2.?;
                const old_p2_tid = self.commits.items[old_p2].root_tree_id;
                const new_p2_tid = self.commits.items[new_p2].root_tree_id;
                cascaded_tid = try self.mergeTreeIds(old_p2_tid, cascaded_tid, new_p2_tid);
            }

            const a_copy = try self.allocator.dupe(u8, rec.author);
            defer self.allocator.free(a_copy);
            const m_copy = try self.allocator.dupe(u8, rec.message);
            defer self.allocator.free(m_copy);

            const is_legacy_ts = (rec.timestamp_sec >= 1700000000 and rec.timestamp_sec < 1700010000);
            const cascaded_ts: i64 = if (is_legacy_ts)
                currentUnixTimestampSec()
            else
                rec.timestamp_sec;
            const cascaded_tz: i16 = if (is_legacy_ts)
                localTzOffsetMinForTimestamp(cascaded_ts)
            else
                rec.tz_offset_min;
            const new_cid = try self.appendCommitWithTimestampAndTz(
                mapped_p1 orelse rec.parent1,
                mapped_p2 orelse rec.parent2,
                cascaded_tid,
                a_copy,
                m_copy,
                cascaded_ts,
                cascaded_tz,
            );
            try remap.put(cid, new_cid);
        }

        var new_wt_trees = try self.allocator.alloc(TreeId, self.worktrees.items.len);
        defer self.allocator.free(new_wt_trees);
        for (self.worktrees.items, 0..) |wt, idx| {
            const old_head = self.branches.items[wt.branch_id].head_commit;
            if (remap.get(old_head)) |new_head| {
                const new_head_tid = self.commits.items[new_head].root_tree_id;
                if (!wt.is_dirty) {
                    new_wt_trees[idx] = new_head_tid;
                } else {
                    const old_head_tid = self.commits.items[old_head].root_tree_id;
                    new_wt_trees[idx] = try self.mergeTreeIds(old_head_tid, wt.working_tree_id, new_head_tid);
                }
            } else {
                new_wt_trees[idx] = wt.working_tree_id;
            }
        }

        var new_draft_trees = try self.allocator.alloc(TreeId, self.drafts.items.len);
        defer self.allocator.free(new_draft_trees);
        for (self.drafts.items, 0..) |d, idx| {
            const old_head = self.branches.items[d.branch_id].head_commit;
            if (remap.get(old_head)) |new_head| {
                const old_head_tid = self.commits.items[old_head].root_tree_id;
                const new_head_tid = self.commits.items[new_head].root_tree_id;
                new_draft_trees[idx] = try self.mergeTreeIds(old_head_tid, d.tree_id, new_head_tid);
            } else {
                new_draft_trees[idx] = d.tree_id;
            }
        }

        try self.recordOplog("squash");
        errdefer self.abortLastOplog();

        for (self.branches.items) |*br| {
            if (remap.get(br.head_commit)) |new_head| {
                br.head_commit = new_head;
            }
        }
        for (self.worktrees.items, 0..) |*wt, idx| {
            wt.working_tree_id = new_wt_trees[idx];
        }
        for (self.drafts.items, 0..) |*d, idx| {
            d.tree_id = new_draft_trees[idx];
        }
        for (self.tags.items) |*t| {
            if (remap.get(t.target_commit)) |new_cid| {
                t.target_commit = new_cid;
            }
        }

        self.clearRedoStack();
        return new_sq_cid;
    }

    /// Cryptographic, Algebraic, and Referential Integrity Verifier (`zig-vcs fsck`):
    /// Verifies:
    /// 1. Every blob's BLAKE3 hash matches its content bytes and contains zero `<<<<<<<` conflict markers (`INV-5`).
    /// 2. Every `TreeManifest` is strictly sorted by path, every `PathSum` has non-zero coefficients summing
    ///    to `1` in $\mathbb{Z}[\mathcal{A}_\bot]$ (`INV-5`), and every non-absent blob hash exists in `db.blobs`.
    /// 3. Every commit's `root_tree_id` is in bounds and `parent1, parent2 < cid` (`INV-2` DAG acyclicity).
    /// 4. Every branch, tag, worktree, draft, and `oplog`/`redo_stack` snapshot references valid IDs (`INV-2`, `INV-6`).
    pub fn verifyIntegrity(self: *const RepoDb) !FsckReport {
        // 1. Verify blobs (BLAKE3 hash + storage purity INV-5)
        for (self.blobs.items) |blob| {
            const computed = tree_sum.computeBlake3(blob.bytes);
            if (!tree_sum.hashEql(computed, blob.hash)) return error.CorruptBlobHash;
            if (diff3.hasConflictMarkers(blob.bytes)) return error.ConflictMarkersInBlobStore;
        }

        // 2. Verify trees (`Z[A_bot]` coefficient conservation + blob referential integrity)
        for (self.trees.items) |tree| {
            for (tree.entries.items, 0..) |entry, e_idx| {
                if (e_idx > 0) {
                    const prev_path = tree.entries.items[e_idx - 1].path;
                    if (std.mem.order(u8, prev_path, entry.path) != .lt) {
                        return error.UnsortedTreeEntries;
                    }
                }
                if (entry.sum.terms.items.len == 0) return error.EmptyPathSum;
                for (entry.sum.terms.items) |term| {
                    if (term.coeff == 0) return error.ZeroCoefficientInPathSum;
                    if (!tree_sum.hashEql(term.hash, ABSENT_HASH)) {
                        if (self.getBlob(term.hash) == null) return error.DanglingBlobHashInTree;
                    }
                }
                if (entry.sum.sumCoefficients() != 1) return error.InvalidPathSumCoefficientConservation;
            }
        }

        // 3. Verify commits (DAG acyclicity + tree bounds `INV-2`)
        if (self.commits.items.len == 0) return error.EmptyCommitTable;
        for (self.commits.items, 0..) |c, cid_usize| {
            const cid: CommitId = @intCast(cid_usize);
            if (c.id != cid) return error.CorruptCommitId;
            if (c.root_tree_id >= self.trees.items.len) return error.DanglingTreeInCommit;
            if (c.parent1) |p1| {
                if (p1 >= cid) return error.CommitDagCycleDetected;
            }
            if (c.parent2) |p2| {
                if (p2 >= cid) return error.CommitDagCycleDetected;
            }
        }

        // 4. Verify branches, tags, worktrees, drafts, and oplog snapshots
        if (self.branches.items.len == 0) return error.EmptyBranchTable;
        for (self.branches.items, 0..) |b, bid_usize| {
            const bid: BranchId = @intCast(bid_usize);
            if (b.id != bid) return error.CorruptBranchId;
            if (b.head_commit >= self.commits.items.len) return error.DanglingCommitInBranch;
        }

        for (self.tags.items) |t| {
            if (t.target_commit >= self.commits.items.len) return error.DanglingCommitInTag;
        }

        for (self.worktrees.items, 0..) |wt, wid_usize| {
            const wid: WorktreeId = @intCast(wid_usize);
            if (wt.id != wid) return error.CorruptWorktreeId;
            if (wt.branch_id >= self.branches.items.len) return error.DanglingBranchInWorktree;
            if (wt.working_tree_id >= self.trees.items.len) return error.DanglingTreeInWorktree;
        }

        for (self.drafts.items) |d| {
            if (d.worktree_id >= self.worktrees.items.len) return error.DanglingWorktreeInDraft;
            if (d.branch_id >= self.branches.items.len) return error.DanglingBranchInDraft;
            if (d.tree_id >= self.trees.items.len) return error.DanglingTreeInDraft;
        }

        for (self.oplog.items) |op| {
            for (op.branches.items) |b| {
                if (b.head_commit >= self.commits.items.len) return error.DanglingCommitInOplog;
            }
            for (op.worktrees.items) |wt| {
                if (wt.branch_id >= op.branches.items.len) return error.DanglingBranchInOplog;
                if (wt.working_tree_id >= self.trees.items.len) return error.DanglingTreeInOplog;
            }
            for (op.drafts.items) |d| {
                if (d.worktree_id >= op.worktrees.items.len) return error.DanglingWorktreeInOplog;
                if (d.branch_id >= op.branches.items.len) return error.DanglingBranchInOplog;
                if (d.tree_id >= self.trees.items.len) return error.DanglingTreeInOplog;
            }
            for (op.tags.items) |t| {
                if (t.target_commit >= self.commits.items.len) return error.DanglingCommitInOplog;
            }
        }

        return .{
            .blobs_verified = self.blobs.items.len,
            .trees_verified = self.trees.items.len,
            .commits_verified = self.commits.items.len,
            .branches_verified = self.branches.items.len,
            .worktrees_verified = self.worktrees.items.len,
            .oplog_verified = self.oplog.items.len,
        };
    }

    // ========================================================================
    // 5. Single-File Binary Serialization (`ZIGVCS01`/`ZIGVCS02` + `PagedFile`)
    // ========================================================================

    pub fn serializeToBytes(self: *const RepoDb, allocator: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        // 1. Magic Header
        try out.appendSlice(allocator, MAGIC_HEADER);

        // 2. Blobs
        try writeU32(allocator, &out, @intCast(self.blobs.items.len));
        for (self.blobs.items) |b| {
            try out.appendSlice(allocator, &b.hash);
            try writeSlice(allocator, &out, b.bytes);
        }

        // 3. Trees
        try writeU32(allocator, &out, @intCast(self.trees.items.len));
        for (self.trees.items) |t| {
            try writeU32(allocator, &out, @intCast(t.entries.items.len));
            for (t.entries.items) |e| {
                try writeSlice(allocator, &out, e.path);
                try writeU32(allocator, &out, @intCast(e.sum.terms.items.len));
                for (e.sum.terms.items) |term| {
                    try out.appendSlice(allocator, &term.hash);
                    try writeI32(allocator, &out, term.coeff);
                }
            }
        }

        // 4. Commits
        try writeU32(allocator, &out, @intCast(self.commits.items.len));
        for (self.commits.items) |c| {
            try writeU32(allocator, &out, c.id);
            try writeOptU32(allocator, &out, c.parent1);
            try writeOptU32(allocator, &out, c.parent2);
            try writeU32(allocator, &out, c.root_tree_id);
            try writeSlice(allocator, &out, c.author);
            try writeSlice(allocator, &out, c.message);
        }

        // 5. Current Mutable View (`branches`, `worktrees`, `drafts`)
        try writeMutableView(allocator, &out, self.branches.items, self.worktrees.items, self.drafts.items);

        // 6. Oplog
        try writeU32(allocator, &out, @intCast(self.oplog.items.len));
        for (self.oplog.items) |op| {
            try writeSlice(allocator, &out, op.command_desc);
            try writeMutableView(allocator, &out, op.branches.items, op.worktrees.items, op.drafts.items);
        }

        // 7. Stat Cache
        try writeU32(allocator, &out, @intCast(self.stat_cache.items.len));
        for (self.stat_cache.items) |sc| {
            try writeU32(allocator, &out, sc.worktree_id);
            try writeSlice(allocator, &out, sc.path);
            try writeI64(allocator, &out, sc.mtime_ns);
            try writeU64(allocator, &out, sc.size_bytes);
            try out.appendSlice(allocator, &sc.hash);
            try out.append(allocator, if (sc.verified_stable) 1 else 0);
        }

        // 7b. Tags & Oplog Tags
        try writeTagsList(allocator, &out, self.tags.items);
        for (self.oplog.items) |op| {
            try writeTagsList(allocator, &out, op.tags.items);
        }

        // 7c. Commit Timestamps
        try writeU32(allocator, &out, @intCast(self.commits.items.len));
        for (self.commits.items) |c| {
            try writeI64(allocator, &out, c.timestamp_sec);
        }

        // 7d. Remotes & Oplog Remotes
        try writeRemotesList(allocator, &out, self.remotes.items);
        for (self.oplog.items) |op| {
            try writeRemotesList(allocator, &out, op.remotes.items);
        }

        // 7e. Redo Stack
        try writeU32(allocator, &out, @intCast(self.redo_stack.items.len));
        for (self.redo_stack.items) |op| {
            try writeSlice(allocator, &out, op.command_desc);
            try writeMutableView(allocator, &out, op.branches.items, op.worktrees.items, op.drafts.items);
            try writeTagsList(allocator, &out, op.tags.items);
            try writeRemotesList(allocator, &out, op.remotes.items);
        }

        // 7f. Config Key-Value Pairs
        try writeRemotesList(allocator, &out, self.configs.items);

        // 7g. Commit Timezone Offsets (in minutes east of UTC)
        try writeU32(allocator, &out, @intCast(self.commits.items.len));
        for (self.commits.items) |c| {
            try writeI16(allocator, &out, c.tz_offset_min);
        }

        // 8. Full-file BLAKE3 checksum footer (32 bytes)
        const checksum = tree_sum.computeBlake3(out.items);
        try out.appendSlice(allocator, &checksum);

        return out.toOwnedSlice(allocator);
    }

    /// Compact V2 serializer (`ZIGVCS02`):
    /// Automatically encodes blobs using Fossil-style `ZDL1` rolling-hash byte deltas against prior
    /// blobs whenever the delta representation is smaller than the raw blob, and persists `FileMode`.
    pub fn serializeToBytesCompact(self: *const RepoDb, allocator: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        // Pre-estimate capacity to avoid repeated reallocations and `memmove`s
        {
            var est_bytes: usize = 4096 + self.commits.items.len * 96 + self.stat_cache.items.len * 80;
            for (self.blobs.items) |b| est_bytes += 40 + b.bytes.len;
            try out.ensureTotalCapacity(allocator, est_bytes);
        }

        // 1. Magic Header V2
        try out.appendSlice(allocator, MAGIC_HEADER_V2);

        // 2. Blobs (with automatic `ZDL1` rolling-hash delta compression!)
        try writeU32(allocator, &out, @intCast(self.blobs.items.len));
        for (self.blobs.items, 0..) |b, idx| {
            try out.appendSlice(allocator, &b.hash);

            var best_delta: ?[]u8 = null;
            var best_base_idx: u32 = 0;
            defer if (best_delta) |bd| allocator.free(bd);

            if (idx > 0 and b.bytes.len >= 32 and b.bytes.len <= 32 * 1024) {
                const window: usize = if (self.blobs.items.len > 128) 1 else 4;
                const start_idx = if (idx > window) idx - window else 0;
                for (start_idx..idx) |cand_idx| {
                    const cand_base = self.blobs.items[cand_idx].bytes;
                    if (cand_base.len < 16 or cand_base.len > 32 * 1024) continue;
                    if (@max(cand_base.len, b.bytes.len) > @min(cand_base.len, b.bytes.len) * 2) continue;
                    if (self.blobs.items.len > 128 and !std.mem.eql(u8, cand_base[0..8], b.bytes[0..8])) continue;
                    const d_bytes = try delta.encodeDelta(allocator, cand_base, b.bytes);
                    const limit = if (best_delta) |bd| bd.len else b.bytes.len -| 6;
                    if (d_bytes.len < limit) {
                        if (best_delta) |bd| allocator.free(bd);
                        best_delta = d_bytes;
                        best_base_idx = @intCast(cand_idx);
                    } else {
                        allocator.free(d_bytes);
                    }
                }
            }

            if (best_delta) |bd| {
                try out.append(allocator, 1); // delta-compressed blob
                try writeU32(allocator, &out, best_base_idx);
                try writeSlice(allocator, &out, bd);
            } else {
                try out.append(allocator, 0); // raw blob
                try writeSlice(allocator, &out, b.bytes);
            }
        }

        // 3. Trees (with `FileMode` & Commit-Parent-Aware Incremental Tree Delta Compression, Lean 4 Theorem 10a)
        const num_trees = self.trees.items.len;
        const parent_tree_hints = try allocator.alloc(?usize, num_trees);
        defer allocator.free(parent_tree_hints);
        @memset(parent_tree_hints, null);

        for (self.commits.items) |c| {
            if (c.parent1) |p1| {
                if (p1 < self.commits.items.len) {
                    const p_tid: usize = self.commits.items[p1].root_tree_id;
                    const c_tid: usize = c.root_tree_id;
                    if (p_tid < c_tid and c_tid < num_trees) {
                        parent_tree_hints[c_tid] = p_tid;
                    }
                }
            }
        }
        for (self.worktrees.items) |wt| {
            if (wt.branch_id < self.branches.items.len) {
                const head_cid = self.branches.items[wt.branch_id].head_commit;
                if (head_cid < self.commits.items.len) {
                    const h_tid: usize = self.commits.items[head_cid].root_tree_id;
                    const w_tid: usize = wt.working_tree_id;
                    if (h_tid < w_tid and w_tid < num_trees and parent_tree_hints[w_tid] == null) {
                        parent_tree_hints[w_tid] = h_tid;
                    }
                }
            }
        }
        for (self.drafts.items) |d| {
            if (d.branch_id < self.branches.items.len) {
                const head_cid = self.branches.items[d.branch_id].head_commit;
                if (head_cid < self.commits.items.len) {
                    const h_tid: usize = self.commits.items[head_cid].root_tree_id;
                    const d_tid: usize = d.tree_id;
                    if (h_tid < d_tid and d_tid < num_trees and parent_tree_hints[d_tid] == null) {
                        parent_tree_hints[d_tid] = h_tid;
                    }
                }
            }
        }

        try writeU32(allocator, &out, @intCast(num_trees));
        for (self.trees.items, 0..) |t, t_idx| {
            var use_delta = false;
            var best_base_tid: usize = 0;
            var best_counts: TreeDeltaCounts = .{ .upserts = 0, .deletes = 0 };

            if (t_idx > 0 and t.entries.items.len >= 4) {
                var min_ops: usize = std.math.maxInt(usize);

                // First check commit/worktree/draft parent tree hint (`parent1.root_tree_id`)
                if (parent_tree_hints[t_idx]) |hint_idx| {
                    const cand_tree = self.trees.items[hint_idx];
                    if (cand_tree.entries.items.len >= 2) {
                        const counts = countTreeDeltaOps(cand_tree, t);
                        const total_ops = counts.upserts + counts.deletes;
                        min_ops = total_ops;
                        best_base_tid = hint_idx;
                        best_counts = counts;
                    }
                }

                // Only scan preceding window if parent hint didn't already find a tiny delta (<= 4 ops)
                if (min_ops > 4) {
                    const start_cand = if (t_idx > 3) t_idx - 3 else 0;
                    for (start_cand..t_idx) |cand_idx| {
                        if (parent_tree_hints[t_idx] != null and cand_idx == parent_tree_hints[t_idx].?) continue;
                        const cand_tree = self.trees.items[cand_idx];
                        if (cand_tree.entries.items.len < 2) continue;
                        const counts = countTreeDeltaOps(cand_tree, t);
                        const total_ops = counts.upserts + counts.deletes;
                        if (total_ops < min_ops) {
                            min_ops = total_ops;
                            best_base_tid = cand_idx;
                            best_counts = counts;
                        }
                    }
                }
                if (min_ops < std.math.maxInt(usize) and min_ops * 2 < t.entries.items.len) {
                    use_delta = true;
                }
            }

            if (use_delta) {
                try writeU32(allocator, &out, TREE_DELTA_FLAG | @as(u32, @intCast(best_base_tid)));
                try writeU32(allocator, &out, @intCast(best_counts.upserts));
                try writeU32(allocator, &out, @intCast(best_counts.deletes));

                const b_items = self.trees.items[best_base_tid].entries.items;
                const c_items = t.entries.items;

                // Pass 1: write upserted entries (`path`, `mode`, `terms`)
                {
                    var ib: usize = 0;
                    var ic: usize = 0;
                    while (ib < b_items.len or ic < c_items.len) {
                        const ord: std.math.Order = if (ib < b_items.len and ic < c_items.len)
                            std.mem.order(u8, b_items[ib].path, c_items[ic].path)
                        else if (ib < b_items.len)
                            .lt
                        else
                            .gt;

                        switch (ord) {
                            .lt => ib += 1,
                            .gt => {
                                try writeTreeEntryV2(allocator, &out, c_items[ic]);
                                ic += 1;
                            },
                            .eq => {
                                const be = b_items[ib];
                                const ce = c_items[ic];
                                if (be.mode != ce.mode or !be.sum.eql(ce.sum)) {
                                    try writeTreeEntryV2(allocator, &out, ce);
                                }
                                ib += 1;
                                ic += 1;
                            },
                        }
                    }
                }

                // Pass 2: write deleted paths
                {
                    var ib: usize = 0;
                    var ic: usize = 0;
                    while (ib < b_items.len or ic < c_items.len) {
                        const ord: std.math.Order = if (ib < b_items.len and ic < c_items.len)
                            std.mem.order(u8, b_items[ib].path, c_items[ic].path)
                        else if (ib < b_items.len)
                            .lt
                        else
                            .gt;

                        switch (ord) {
                            .lt => {
                                try writeSlice(allocator, &out, b_items[ib].path);
                                ib += 1;
                            },
                            .gt => ic += 1,
                            .eq => {
                                ib += 1;
                                ic += 1;
                            },
                        }
                    }
                }
            } else {
                try writeU32(allocator, &out, @intCast(t.entries.items.len));
                for (t.entries.items) |e| {
                    try writeTreeEntryV2(allocator, &out, e);
                }
            }
        }

        // 4. Commits
        try writeU32(allocator, &out, @intCast(self.commits.items.len));
        for (self.commits.items) |c| {
            try writeU32(allocator, &out, c.id);
            try writeOptU32(allocator, &out, c.parent1);
            try writeOptU32(allocator, &out, c.parent2);
            try writeU32(allocator, &out, c.root_tree_id);
            try writeSlice(allocator, &out, c.author);
            try writeSlice(allocator, &out, c.message);
        }

        // 5. Current Mutable View (`branches`, `worktrees`, `drafts`)
        try writeMutableView(allocator, &out, self.branches.items, self.worktrees.items, self.drafts.items);

        // 6. Oplog
        try writeU32(allocator, &out, @intCast(self.oplog.items.len));
        for (self.oplog.items) |op| {
            try writeSlice(allocator, &out, op.command_desc);
            try writeMutableView(allocator, &out, op.branches.items, op.worktrees.items, op.drafts.items);
        }

        // 7. Stat Cache
        try writeU32(allocator, &out, @intCast(self.stat_cache.items.len));
        for (self.stat_cache.items) |sc| {
            try writeU32(allocator, &out, sc.worktree_id);
            try writeSlice(allocator, &out, sc.path);
            try writeI64(allocator, &out, sc.mtime_ns);
            try writeU64(allocator, &out, sc.size_bytes);
            try out.appendSlice(allocator, &sc.hash);
            try out.append(allocator, if (sc.verified_stable) 1 else 0);
        }

        // 7b. Tags & Oplog Tags
        try writeTagsList(allocator, &out, self.tags.items);
        for (self.oplog.items) |op| {
            try writeTagsList(allocator, &out, op.tags.items);
        }

        // 7c. Commit Timestamps
        try writeU32(allocator, &out, @intCast(self.commits.items.len));
        for (self.commits.items) |c| {
            try writeI64(allocator, &out, c.timestamp_sec);
        }

        // 7d. Remotes & Oplog Remotes
        try writeRemotesList(allocator, &out, self.remotes.items);
        for (self.oplog.items) |op| {
            try writeRemotesList(allocator, &out, op.remotes.items);
        }

        // 7e. Redo Stack
        try writeU32(allocator, &out, @intCast(self.redo_stack.items.len));
        for (self.redo_stack.items) |op| {
            try writeSlice(allocator, &out, op.command_desc);
            try writeMutableView(allocator, &out, op.branches.items, op.worktrees.items, op.drafts.items);
            try writeTagsList(allocator, &out, op.tags.items);
            try writeRemotesList(allocator, &out, op.remotes.items);
        }

        // 7f. Config Key-Value Pairs
        try writeRemotesList(allocator, &out, self.configs.items);

        // 7g. Commit Timezone Offsets (in minutes east of UTC)
        try writeU32(allocator, &out, @intCast(self.commits.items.len));
        for (self.commits.items) |c| {
            try writeI16(allocator, &out, c.tz_offset_min);
        }

        // 8. Full-file BLAKE3 checksum footer (32 bytes)
        const checksum = tree_sum.computeBlake3(out.items);
        try out.appendSlice(allocator, &checksum);

        return out.toOwnedSlice(allocator);
    }

    pub fn deserializeFromBytes(allocator: Allocator, data: []const u8) !RepoDb {
        if (data.len < MAGIC_HEADER.len + 32) return error.CorruptDatabase;
        const is_v1 = std.mem.eql(u8, data[0..MAGIC_HEADER.len], MAGIC_HEADER);
        const is_v2 = std.mem.eql(u8, data[0..MAGIC_HEADER_V2.len], MAGIC_HEADER_V2);
        if (!is_v1 and !is_v2) return error.InvalidMagicHeader;

        const payload = data[0 .. data.len - 32];
        const expected_checksum = data[data.len - 32 ..][0..32].*;
        const actual_checksum = tree_sum.computeBlake3(payload);
        if (!tree_sum.hashEql(expected_checksum, actual_checksum)) return error.ChecksumMismatch;

        var pos: usize = MAGIC_HEADER.len;
        var db = RepoDb{ .allocator = allocator };
        errdefer db.deinit();

        // Blobs
        const num_blobs = try readU32(payload, &pos);
        try db.blobs.ensureUnusedCapacity(allocator, num_blobs);
        try db.blob_index.ensureUnusedCapacity(allocator, num_blobs);
        for (0..num_blobs) |b_idx| {
            const hash = try readHash(payload, &pos);
            if (is_v2) {
                if (payload.len - pos < 1) return error.CorruptDatabase;
                const is_delta = payload[pos] != 0;
                pos += 1;
                if (is_delta) {
                    const base_idx = try readU32(payload, &pos);
                    if (base_idx >= db.blobs.items.len) return error.CorruptDatabase;
                    const delta_slice = try readSliceView(payload, &pos);
                    const reconstructed = delta.applyDelta(
                        allocator,
                        db.blobs.items[base_idx].bytes,
                        delta_slice,
                    ) catch return error.CorruptDatabase;
                    errdefer allocator.free(reconstructed);
                    if (!tree_sum.hashEql(tree_sum.computeBlake3(reconstructed), hash)) {
                        return error.CorruptDatabase;
                    }
                    db.blobs.appendAssumeCapacity(.{ .hash = hash, .bytes = reconstructed });
                } else {
                    const bytes = try readSliceAlloc(allocator, payload, &pos);
                    errdefer allocator.free(bytes);
                    db.blobs.appendAssumeCapacity(.{ .hash = hash, .bytes = bytes });
                }
            } else {
                const bytes = try readSliceAlloc(allocator, payload, &pos);
                errdefer allocator.free(bytes);
                db.blobs.appendAssumeCapacity(.{ .hash = hash, .bytes = bytes });
            }
            db.blob_index.putAssumeCapacity(hash, @intCast(b_idx));
        }

        // Trees (tree hashes & `tree_index` are computed lazily on demand via `ensureTreeIndexPopulated`)
        const num_trees = try readU32(payload, &pos);
        try db.trees.ensureUnusedCapacity(allocator, num_trees);
        for (0..num_trees) |_| {
            var manifest: TreeManifest = .{};
            errdefer manifest.deinit(allocator);
            const header_word = try readU32(payload, &pos);

            if (is_v2 and (header_word & TREE_DELTA_FLAG) != 0) {
                const base_tid = header_word & (~TREE_DELTA_FLAG);
                if (base_tid >= db.trees.items.len) return error.CorruptDatabase;
                const num_upserts = try readU32(payload, &pos);
                const num_deletes = try readU32(payload, &pos);

                var upserts: std.ArrayList(UpsertView) = .empty;
                defer upserts.deinit(allocator);
                try upserts.ensureUnusedCapacity(allocator, num_upserts);
                for (0..num_upserts) |_| {
                    const up_path = try readSliceView(payload, &pos);
                    if (!tree_sum.isValidNormalizedPath(up_path)) return error.CorruptDatabase;
                    const up_mode = FileMode.fromGitOctal(try readU32(payload, &pos));
                    const num_terms = try readU32(payload, &pos);
                    if (num_terms == 0) return error.CorruptDatabase;
                    const terms_byte_len = @as(usize, num_terms) * 36;
                    if (payload.len - pos < terms_byte_len) return error.CorruptDatabase;
                    const terms_pos = pos;
                    var coeff_sum: i64 = 0;
                    for (0..num_terms) |_| {
                        _ = try readHash(payload, &pos);
                        const coeff = try readI32(payload, &pos);
                        if (coeff == 0 or @abs(coeff) > 1000) return error.CorruptDatabase;
                        coeff_sum += coeff;
                    }
                    if (coeff_sum != 1) return error.CorruptDatabase;
                    upserts.appendAssumeCapacity(.{
                        .path = up_path,
                        .mode = up_mode,
                        .num_terms = num_terms,
                        .terms_pos = terms_pos,
                    });
                }

                var deletes: std.ArrayList([]const u8) = .empty;
                defer deletes.deinit(allocator);
                try deletes.ensureUnusedCapacity(allocator, num_deletes);
                for (0..num_deletes) |_| {
                    const del_path = try readSliceView(payload, &pos);
                    deletes.appendAssumeCapacity(del_path);
                }

                const base_items = db.trees.items[base_tid].entries.items;
                const up_items = upserts.items;
                const del_items = deletes.items;

                try manifest.entries.ensureUnusedCapacity(allocator, base_items.len + up_items.len);
                var ib: usize = 0;
                var iu: usize = 0;
                var idel: usize = 0;

                while (ib < base_items.len or iu < up_items.len) {
                    const ord: std.math.Order = if (ib < base_items.len and iu < up_items.len)
                        std.mem.order(u8, base_items[ib].path, up_items[iu].path)
                    else if (ib < base_items.len)
                        .lt
                    else
                        .gt;

                    switch (ord) {
                        .lt => {
                            const b_path = base_items[ib].path;
                            while (idel < del_items.len and std.mem.order(u8, del_items[idel], b_path) == .lt) {
                                idel += 1;
                            }
                            if (idel < del_items.len and std.mem.eql(u8, del_items[idel], b_path)) {
                                idel += 1;
                                ib += 1;
                            } else {
                                const path_copy = try allocator.dupe(u8, b_path);
                                errdefer allocator.free(path_copy);
                                const sum_copy = try base_items[ib].sum.clone(allocator);
                                manifest.entries.appendAssumeCapacity(.{
                                    .path = path_copy,
                                    .sum = sum_copy,
                                    .mode = base_items[ib].mode,
                                });
                                ib += 1;
                            }
                        },
                        .gt => {
                            const entry = try materializeUpsertView(allocator, payload, up_items[iu]);
                            manifest.entries.appendAssumeCapacity(entry);
                            iu += 1;
                        },
                        .eq => {
                            const entry = try materializeUpsertView(allocator, payload, up_items[iu]);
                            manifest.entries.appendAssumeCapacity(entry);
                            ib += 1;
                            iu += 1;
                        },
                    }
                }
            } else {
                const num_entries = header_word;
                try manifest.entries.ensureUnusedCapacity(allocator, num_entries);
                for (0..num_entries) |_| {
                    const path = try readSliceAlloc(allocator, payload, &pos);
                    errdefer allocator.free(path);
                    if (!tree_sum.isValidNormalizedPath(path)) return error.CorruptDatabase;
                    const mode: FileMode = if (is_v2)
                        FileMode.fromGitOctal(try readU32(payload, &pos))
                    else
                        .regular;
                    var sum: PathSum = .{};
                    errdefer sum.deinit(allocator);
                    const num_terms = try readU32(payload, &pos);
                    if (num_terms == 0) return error.CorruptDatabase;
                    try sum.terms.ensureUnusedCapacity(allocator, num_terms);
                    var coeff_sum: i64 = 0;
                    for (0..num_terms) |_| {
                        const thash = try readHash(payload, &pos);
                        const coeff = try readI32(payload, &pos);
                        if (coeff == 0 or @abs(coeff) > 1000) return error.CorruptDatabase;
                        coeff_sum += coeff;
                        sum.terms.appendAssumeCapacity(.{ .hash = thash, .coeff = coeff });
                    }
                    if (coeff_sum != 1) return error.CorruptDatabase;
                    manifest.entries.appendAssumeCapacity(.{ .path = path, .sum = sum, .mode = mode });
                }
            }
            db.trees.appendAssumeCapacity(manifest);
        }

        // Commits
        const num_commits = try readU32(payload, &pos);
        for (0..num_commits) |_| {
            const cid = try readU32(payload, &pos);
            const p1 = try readOptU32(payload, &pos);
            const p2 = try readOptU32(payload, &pos);
            const rtid = try readU32(payload, &pos);
            const author = try readSliceAlloc(allocator, payload, &pos);
            errdefer allocator.free(author);
            const message = try readSliceAlloc(allocator, payload, &pos);
            errdefer allocator.free(message);
            try db.commits.append(allocator, .{
                .id = cid,
                .parent1 = p1,
                .parent2 = p2,
                .root_tree_id = rtid,
                .author = author,
                .message = message,
            });
        }

        // Mutable View
        try readMutableView(allocator, payload, &pos, &db.branches, &db.worktrees, &db.drafts);

        // Oplog
        const num_ops = try readU32(payload, &pos);
        for (0..num_ops) |_| {
            var op: OplogEntry = .{
                .command_desc = try readSliceAlloc(allocator, payload, &pos),
            };
            errdefer op.deinit(allocator);
            try readMutableView(allocator, payload, &pos, &op.branches, &op.worktrees, &op.drafts);
            try db.oplog.append(allocator, op);
        }

        // Stat Cache
        if (pos < payload.len) {
            const num_sc = try readU32(payload, &pos);
            for (0..num_sc) |_| {
                const wid = try readU32(payload, &pos);
                const path = try readSliceAlloc(allocator, payload, &pos);
                errdefer allocator.free(path);
                const mtime_ns = try readI64(payload, &pos);
                const size_bytes = try readU64(payload, &pos);
                const hash = try readHash(payload, &pos);
                if (payload.len - pos < 1) return error.CorruptDatabase;
                const verified_stable = payload[pos] != 0;
                pos += 1;
                try db.stat_cache.append(allocator, .{
                    .worktree_id = wid,
                    .path = path,
                    .mtime_ns = mtime_ns,
                    .size_bytes = size_bytes,
                    .hash = hash,
                    .verified_stable = verified_stable,
                });
            }
        }

        // 7b. Tags & Oplog Tags (if present)
        if (pos < payload.len) {
            try readTagsList(allocator, payload, &pos, &db.tags);
            for (db.oplog.items) |*op| {
                if (pos < payload.len) {
                    try readTagsList(allocator, payload, &pos, &op.tags);
                }
            }
        }

        // 7c. Commit Timestamps (if present)
        if (pos < payload.len) {
            const num_ts = try readU32(payload, &pos);
            if (num_ts != db.commits.items.len) return error.CorruptDatabase;
            for (db.commits.items) |*c| {
                c.timestamp_sec = try readI64(payload, &pos);
            }
        }

        // 7d. Remotes & Oplog Remotes (if present)
        if (pos < payload.len) {
            try readRemotesList(allocator, payload, &pos, &db.remotes);
            for (db.oplog.items) |*op| {
                if (pos < payload.len) {
                    try readRemotesList(allocator, payload, &pos, &op.remotes);
                }
            }
        }

        // 7e. Redo Stack (if present)
        if (pos < payload.len) {
            const num_redo = try readU32(payload, &pos);
            for (0..num_redo) |_| {
                var op: OplogEntry = .{
                    .command_desc = try readSliceAlloc(allocator, payload, &pos),
                };
                errdefer op.deinit(allocator);
                try readMutableView(allocator, payload, &pos, &op.branches, &op.worktrees, &op.drafts);
                try readTagsList(allocator, payload, &pos, &op.tags);
                try readRemotesList(allocator, payload, &pos, &op.remotes);
                try db.redo_stack.append(allocator, op);
            }
        }

        // 7f. Config Key-Value Pairs (if present)
        if (pos < payload.len) {
            try readRemotesList(allocator, payload, &pos, &db.configs);
        }

        // 7g. Commit Timezone Offsets (if present; otherwise infer local timezone offset for non-root commits)
        if (pos < payload.len) {
            const num_tz = try readU32(payload, &pos);
            if (num_tz != db.commits.items.len) return error.CorruptDatabase;
            for (db.commits.items) |*c| {
                c.tz_offset_min = try readI16(payload, &pos);
            }
        } else {
            for (db.commits.items) |*c| {
                if (c.id > 0 and c.timestamp_sec > 0) {
                    c.tz_offset_min = localTzOffsetMinForTimestamp(c.timestamp_sec);
                }
            }
        }

        // Ensure `stat_cache` is sorted by `(worktree_id, path)` for O(log F) binary search
        if (db.stat_cache.items.len > 1) {
            var is_sorted = true;
            for (1..db.stat_cache.items.len) |i| {
                const prev = db.stat_cache.items[i - 1];
                const curr = db.stat_cache.items[i];
                if (statCacheOrder(prev.worktree_id, prev.path, curr.worktree_id, curr.path) != .lt) {
                    is_sorted = false;
                    break;
                }
            }
            if (!is_sorted) {
                const SortCtx = struct {
                    pub fn lessThan(_: void, a: StatCacheEntry, b: StatCacheEntry) bool {
                        return statCacheOrder(a.worktree_id, a.path, b.worktree_id, b.path) == .lt;
                    }
                };
                std.mem.sort(StatCacheEntry, db.stat_cache.items, {}, SortCtx.lessThan);
            }
        }

        // Validate internal foreign keys and DAG invariants (`INV-2`)
        // Note: Algebraic Tree Purity (`INV-5`) is validated inline when decoding each tree entry.
        if (db.commits.items.len == 0 or db.trees.items.len == 0 or db.branches.items.len == 0) {
            return error.CorruptDatabase;
        }
        for (db.commits.items, 0..) |c, idx| {
            if (c.id != idx or c.root_tree_id >= db.trees.items.len) return error.CorruptDatabase;
            if (c.parent1) |p1| if (p1 >= c.id) return error.CorruptDatabase;
            if (c.parent2) |p2| if (p2 >= c.id) return error.CorruptDatabase;
        }
        for (db.branches.items, 0..) |b, idx| {
            if (b.id != idx or b.head_commit >= db.commits.items.len) return error.CorruptDatabase;
        }
        for (db.worktrees.items, 0..) |w, idx| {
            if (w.id != idx or w.branch_id >= db.branches.items.len or w.working_tree_id >= db.trees.items.len) {
                return error.CorruptDatabase;
            }
        }
        for (db.drafts.items) |d| {
            if (d.worktree_id >= db.worktrees.items.len or
                d.branch_id >= db.branches.items.len or
                d.tree_id >= db.trees.items.len)
            {
                return error.CorruptDatabase;
            }
        }
        for (db.tags.items) |t| {
            if (t.name.len == 0 or t.target_commit >= db.commits.items.len) {
                return error.CorruptDatabase;
            }
        }

        return db;
    }

    pub fn saveToFile(self: *const RepoDb, io: Io, path: []const u8) !void {
        const compact_bytes = try self.serializeToBytesCompact(self.allocator);
        defer self.allocator.free(compact_bytes);

        if (compact_bytes.len > 2 * 1024 * 1024) {
            try paged_file.writeCompactSnapshotToFile(io, path, compact_bytes, 1);
            return;
        }

        var img: paged_file.PagedImage = paged_file.PagedImage.readFromFile(self.allocator, io, path) catch
            try paged_file.PagedImage.init(self.allocator);
        defer img.deinit();

        _ = try img.commitSnapshot(compact_bytes);
        try img.writeToFile(io, path);
    }

    pub fn loadFromFile(allocator: Allocator, io: Io, path: []const u8) !RepoDb {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(bytes);

        if (paged_file.hasPagedSuperblockMagic(bytes)) {
            const slice_rec = try paged_file.extractLatestPayloadSlice(bytes);
            return deserializeFromBytes(allocator, slice_rec.payload);
        }

        return deserializeFromBytes(allocator, bytes);
    }

    /// Reset a loaded remote `RepoDb` into a clean local clone bound to `dst_worktree_path`
    /// with `"origin"` pointing to `origin_url`, preserving 100% of `blobs`, `trees`, `commits`,
    /// `branches`, and `tags` while resetting worktrees/drafts/oplog for the fresh local workspace.
    pub fn prepareAsFreshClone(
        self: *RepoDb,
        dst_worktree_path: []const u8,
        origin_url: []const u8,
    ) !void {
        var active_br: BranchId = 0;
        if (self.worktrees.items.len > 0 and self.worktrees.items[0].branch_id < self.branches.items.len) {
            const cand = self.worktrees.items[0].branch_id;
            if (self.branches.items[cand].head_commit > 0) {
                active_br = cand;
            }
        }
        if (self.branches.items[active_br].head_commit == 0) {
            if (self.findBranchByName("main")) |m_id| {
                if (self.branches.items[m_id].head_commit > 0) active_br = m_id;
            }
        }
        if (self.branches.items[active_br].head_commit == 0) {
            for (self.branches.items, 0..) |br, idx| {
                if (br.head_commit > 0) {
                    active_br = @intCast(idx);
                    break;
                }
            }
        }

        const wt_name = try self.allocator.dupe(u8, "main-wt");
        errdefer self.allocator.free(wt_name);
        const wt_path = try self.allocator.dupe(u8, dst_worktree_path);
        errdefer self.allocator.free(wt_path);

        const orig_name = try self.allocator.dupe(u8, "origin");
        errdefer self.allocator.free(orig_name);
        const orig_path = try self.allocator.dupe(u8, origin_url);
        errdefer self.allocator.free(orig_path);

        for (self.worktrees.items) |*w| w.deinit(self.allocator);
        self.worktrees.clearRetainingCapacity();
        self.drafts.clearRetainingCapacity();
        for (self.stat_cache.items) |*sc| sc.deinit(self.allocator);
        self.stat_cache.clearRetainingCapacity();
        for (self.oplog.items) |*op| op.deinit(self.allocator);
        self.oplog.clearRetainingCapacity();
        for (self.redo_stack.items) |*op| op.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();
        for (self.remotes.items) |*r| r.deinit(self.allocator);
        self.remotes.clearRetainingCapacity();
        for (self.configs.items) |*cfg| cfg.deinit(self.allocator);
        self.configs.clearRetainingCapacity();

        const head_cid = self.branches.items[active_br].head_commit;
        const head_tid = self.commits.items[head_cid].root_tree_id;
        try self.worktrees.append(self.allocator, .{
            .id = 0,
            .name = wt_name,
            .fs_path = wt_path,
            .branch_id = active_br,
            .working_tree_id = head_tid,
            .is_dirty = false,
            .is_open = true,
        });
        try self.remotes.append(self.allocator, .{
            .name = orig_name,
            .path = orig_path,
        });
    }
};

const TreeDeltaCounts = struct {
    upserts: usize,
    deletes: usize,
};

fn countTreeDeltaOps(base: TreeManifest, curr: TreeManifest) TreeDeltaCounts {
    const b_items = base.entries.items;
    const c_items = curr.entries.items;
    var ib: usize = 0;
    var ic: usize = 0;
    var upserts: usize = 0;
    var deletes: usize = 0;

    while (ib < b_items.len or ic < c_items.len) {
        const ord: std.math.Order = if (ib < b_items.len and ic < c_items.len)
            std.mem.order(u8, b_items[ib].path, c_items[ic].path)
        else if (ib < b_items.len)
            .lt
        else
            .gt;

        switch (ord) {
            .lt => {
                deletes += 1;
                ib += 1;
            },
            .gt => {
                upserts += 1;
                ic += 1;
            },
            .eq => {
                const be = b_items[ib];
                const ce = c_items[ic];
                if (be.mode != ce.mode or !be.sum.eql(ce.sum)) {
                    upserts += 1;
                }
                ib += 1;
                ic += 1;
            },
        }
    }
    return .{ .upserts = upserts, .deletes = deletes };
}

fn writeTreeEntryV2(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    e: tree_sum.PathEntry,
) !void {
    try writeSlice(allocator, out, e.path);
    try writeU32(allocator, out, @intFromEnum(e.mode));
    try writeU32(allocator, out, @intCast(e.sum.terms.items.len));
    for (e.sum.terms.items) |term| {
        try out.appendSlice(allocator, &term.hash);
        try writeI32(allocator, out, term.coeff);
    }
}

const UpsertView = struct {
    path: []const u8,
    mode: FileMode,
    num_terms: u32,
    terms_pos: usize,
};

fn materializeUpsertView(
    allocator: Allocator,
    payload: []const u8,
    uv: UpsertView,
) !tree_sum.PathEntry {
    const path_copy = try allocator.dupe(u8, uv.path);
    errdefer allocator.free(path_copy);
    var sum: PathSum = .{};
    errdefer sum.deinit(allocator);
    try sum.terms.ensureUnusedCapacity(allocator, uv.num_terms);
    var tpos = uv.terms_pos;
    for (0..uv.num_terms) |_| {
        const thash = try readHash(payload, &tpos);
        const coeff = try readI32(payload, &tpos);
        sum.terms.appendAssumeCapacity(.{ .hash = thash, .coeff = coeff });
    }
    return .{
        .path = path_copy,
        .sum = sum,
        .mode = uv.mode,
    };
}

fn writeI16(allocator: Allocator, out: *std.ArrayList(u8), v: i16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(i16, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

fn writeU32(allocator: Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

fn writeI32(allocator: Allocator, out: *std.ArrayList(u8), v: i32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

fn writeI64(allocator: Allocator, out: *std.ArrayList(u8), v: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

fn writeU64(allocator: Allocator, out: *std.ArrayList(u8), v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

fn writeOptU32(allocator: Allocator, out: *std.ArrayList(u8), v: ?u32) !void {
    if (v) |val| {
        try out.append(allocator, 1);
        try writeU32(allocator, out, val);
    } else {
        try out.append(allocator, 0);
    }
}

fn writeSlice(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try writeU32(allocator, out, @intCast(s.len));
    try out.appendSlice(allocator, s);
}

fn writeMutableView(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    branches: []const BranchRecord,
    worktrees: []const WorktreeRecord,
    drafts: []const DraftEntry,
) !void {
    try writeU32(allocator, out, @intCast(branches.len));
    for (branches) |b| {
        try writeU32(allocator, out, b.id);
        try writeSlice(allocator, out, b.name);
        try writeU32(allocator, out, b.head_commit);
    }
    try writeU32(allocator, out, @intCast(worktrees.len));
    for (worktrees) |w| {
        try writeU32(allocator, out, w.id);
        try writeSlice(allocator, out, w.name);
        try writeSlice(allocator, out, w.fs_path);
        try writeU32(allocator, out, w.branch_id);
        try writeU32(allocator, out, w.working_tree_id);
        try out.append(allocator, if (w.is_dirty) 1 else 0);
        try out.append(allocator, if (w.is_open) 1 else 0);
    }
    try writeU32(allocator, out, @intCast(drafts.len));
    for (drafts) |d| {
        try writeU32(allocator, out, d.worktree_id);
        try writeU32(allocator, out, d.branch_id);
        try writeU32(allocator, out, d.tree_id);
    }
}

fn writeTagsList(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    tags: []const TagRecord,
) !void {
    try writeU32(allocator, out, @intCast(tags.len));
    for (tags) |t| {
        try writeSlice(allocator, out, t.name);
        try writeU32(allocator, out, t.target_commit);
    }
}

fn readTagsList(
    allocator: Allocator,
    data: []const u8,
    pos: *usize,
    tags: *std.ArrayList(TagRecord),
) !void {
    const num_tags = try readU32(data, pos);
    for (0..num_tags) |_| {
        const name = try readSliceAlloc(allocator, data, pos);
        errdefer allocator.free(name);
        const target = try readU32(data, pos);
        try tags.append(allocator, .{ .name = name, .target_commit = target });
    }
}

fn writeRemotesList(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    remotes: []const RemoteRecord,
) !void {
    try writeU32(allocator, out, @intCast(remotes.len));
    for (remotes) |r| {
        try writeSlice(allocator, out, r.name);
        try writeSlice(allocator, out, r.path);
    }
}

fn readRemotesList(
    allocator: Allocator,
    data: []const u8,
    pos: *usize,
    remotes: *std.ArrayList(RemoteRecord),
) !void {
    const num_remotes = try readU32(data, pos);
    for (0..num_remotes) |_| {
        const name = try readSliceAlloc(allocator, data, pos);
        errdefer allocator.free(name);
        const path = try readSliceAlloc(allocator, data, pos);
        errdefer allocator.free(path);
        try remotes.append(allocator, .{ .name = name, .path = path });
    }
}

fn readI16(data: []const u8, pos: *usize) !i16 {
    if (data.len - pos.* < 2) return error.CorruptDatabase;
    const v = std.mem.readInt(i16, data[pos.*..][0..2], .little);
    pos.* += 2;
    return v;
}

fn readU32(data: []const u8, pos: *usize) !u32 {
    if (data.len - pos.* < 4) return error.CorruptDatabase;
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn readI32(data: []const u8, pos: *usize) !i32 {
    if (data.len - pos.* < 4) return error.CorruptDatabase;
    const v = std.mem.readInt(i32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn readI64(data: []const u8, pos: *usize) !i64 {
    if (data.len - pos.* < 8) return error.CorruptDatabase;
    const v = std.mem.readInt(i64, data[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}

fn readU64(data: []const u8, pos: *usize) !u64 {
    if (data.len - pos.* < 8) return error.CorruptDatabase;
    const v = std.mem.readInt(u64, data[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}

fn readOptU32(data: []const u8, pos: *usize) !?u32 {
    if (data.len - pos.* < 1) return error.CorruptDatabase;
    const flag = data[pos.*];
    pos.* += 1;
    if (flag == 0) return null;
    return try readU32(data, pos);
}

fn readHash(data: []const u8, pos: *usize) !ArtifactHash {
    if (data.len - pos.* < 32) return error.CorruptDatabase;
    const h = data[pos.*..][0..32].*;
    pos.* += 32;
    return h;
}

fn readSliceView(data: []const u8, pos: *usize) ![]const u8 {
    const len = try readU32(data, pos);
    if (data.len - pos.* < len) return error.CorruptDatabase;
    const out = data[pos.* .. pos.* + len];
    pos.* += len;
    return out;
}

fn readSliceAlloc(allocator: Allocator, data: []const u8, pos: *usize) ![]u8 {
    const slice = try readSliceView(data, pos);
    return allocator.dupe(u8, slice);
}

fn readMutableView(
    allocator: Allocator,
    data: []const u8,
    pos: *usize,
    branches: *std.ArrayList(BranchRecord),
    worktrees: *std.ArrayList(WorktreeRecord),
    drafts: *std.ArrayList(DraftEntry),
) !void {
    const num_branches = try readU32(data, pos);
    for (0..num_branches) |_| {
        const bid = try readU32(data, pos);
        const name = try readSliceAlloc(allocator, data, pos);
        errdefer allocator.free(name);
        const head = try readU32(data, pos);
        try branches.append(allocator, .{ .id = bid, .name = name, .head_commit = head });
    }
    const num_wt = try readU32(data, pos);
    for (0..num_wt) |_| {
        const wid = try readU32(data, pos);
        const name = try readSliceAlloc(allocator, data, pos);
        errdefer allocator.free(name);
        const fs_path = try readSliceAlloc(allocator, data, pos);
        errdefer allocator.free(fs_path);
        const bid = try readU32(data, pos);
        const wtid = try readU32(data, pos);
        if (pos.* + 2 > data.len) return error.CorruptDatabase;
        const is_dirty = data[pos.*] != 0;
        const is_open = data[pos.* + 1] != 0;
        pos.* += 2;
        try worktrees.append(allocator, .{
            .id = wid,
            .name = name,
            .fs_path = fs_path,
            .branch_id = bid,
            .working_tree_id = wtid,
            .is_dirty = is_dirty,
            .is_open = is_open,
        });
    }
    const num_drafts = try readU32(data, pos);
    for (0..num_drafts) |_| {
        const wid = try readU32(data, pos);
        const bid = try readU32(data, pos);
        const tid = try readU32(data, pos);
        try drafts.append(allocator, .{ .worktree_id = wid, .branch_id = bid, .tree_id = tid });
    }
}

test "RepoDb: End-to-End Pillar 1 (Switch/Close Drafts), Pillar 2 (B+C-A Merge/Rebase), Pillar 3 (Oplog Undo & Binary Serialization)" {
    const gpa = std.testing.allocator;
    var db = try RepoDb.initNew(gpa, "/tmp/wt0");
    defer db.deinit();

    // 1. Edit & commit base file on `main`
    try db.editFile(0, "src/app.zig", "const port = 8000;\n// UNIQUE_ANCHOR\nconst workers = 4;\n");
    const c1 = try db.commitWorktree(0, "alice", "Base app config");
    try std.testing.expectEqual(@as(CommitId, 1), c1);

    // 2. Switch to `feat`, edit top region, and commit
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "src/app.zig", "const port = 9000;\n// UNIQUE_ANCHOR\nconst workers = 4;\n");
    _ = try db.commitWorktree(0, "bob", "Change port on feat");

    // 3. Make uncommitted dirty edit on `feat`, switch to `main`, and verify `feat` draft is preserved!
    try db.editFile(0, "README.md", "Work in progress on feat");
    try std.testing.expect(db.worktrees.items[0].is_dirty);

    _ = try db.switchBranch(0, "main");
    try std.testing.expect(!db.worktrees.items[0].is_dirty);
    try std.testing.expect(db.trees.items[db.worktrees.items[0].working_tree_id].getPathSum("README.md") == null);

    // Switch back to `feat` -> dirty `README.md` is automatically restored!
    _ = try db.switchBranch(0, "feat");
    try std.testing.expect(db.worktrees.items[0].is_dirty);
    try std.testing.expect(db.trees.items[db.worktrees.items[0].working_tree_id].getPathSum("README.md") != null);

    // Undo the switch back -> returns to `main`!
    try std.testing.expect(try db.undo());
    try std.testing.expectEqual(@as(BranchId, 0), db.worktrees.items[0].branch_id);

    // 4. Edit bottom region on `main` and commit
    try db.editFile(0, "src/app.zig", "const port = 8000;\n// UNIQUE_ANCHOR\nconst workers = 16;\n");
    _ = try db.commitWorktree(0, "alice", "Scale workers on main");

    // 5. Merge `feat` into `main` -> Pierce anchor-separated hunk lifting merges BOTH edits cleanly!
    _ = try db.mergeBranch(0, "feat", "alice", "Merge feat into main");
    const merged_tid = db.worktrees.items[0].working_tree_id;
    try std.testing.expect(!db.trees.items[merged_tid].hasConflicts());
    const merged_sum = db.trees.items[merged_tid].getPathSum("src/app.zig").?;
    const merged_hash = merged_sum.getCleanHash().?;
    try std.testing.expectEqualStrings(
        "const port = 9000;\n// UNIQUE_ANCHOR\nconst workers = 16;\n",
        db.getBlob(merged_hash).?,
    );

    // 6. Test Worktree Close & Reopen preserves uncommitted drafts (fixing Fossil's .fslckout bug)
    const wt1 = try db.addWorktree("wt1", "/tmp/wt1", "feat");
    try db.editFile(wt1, "notes.txt", "Draft inside wt1 before closing");
    try db.closeWorktree(wt1);
    try std.testing.expect(!db.worktrees.items[wt1].is_open);
    try db.reopenWorktree(wt1);
    try std.testing.expect(db.worktrees.items[wt1].is_open);
    try std.testing.expect(db.worktrees.items[wt1].is_dirty);

    // 7. Test Single-File Binary Serialization & BLAKE3 Checksum Verification
    const bytes = try db.serializeToBytes(gpa);
    defer gpa.free(bytes);

    var loaded = try RepoDb.deserializeFromBytes(gpa, bytes);
    defer loaded.deinit();

    try std.testing.expectEqual(db.commits.items.len, loaded.commits.items.len);
    try std.testing.expectEqual(db.branches.items.len, loaded.branches.items.len);
    try std.testing.expectEqual(db.worktrees.items.len, loaded.worktrees.items.len);
    try std.testing.expectEqual(db.oplog.items.len, loaded.oplog.items.len);
}
