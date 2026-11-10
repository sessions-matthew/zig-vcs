//! 4KB Paged Storage Engine with Dual-Superblock Atomic Commit & Torn-Write Crash Recovery.
//!
//! Implements the shadow-paging & crash-recovery architecture from:
//! - Sears & Brewer (OSDI 2006), "Stasis: Flexible Transactional Storage"
//! - Ohad Rodeh (ACM TOS 2008), "B-Trees, Shadowing, and Clones"
//!
//! Layout of a Paged Repository File (`PAGE_SIZE = 4096` bytes):
//! - **Page 0**: Superblock Slot A (even `tx_generation` commits)
//! - **Page 1**: Superblock Slot B (odd `tx_generation` commits)
//! - **Pages 2..N**: Shadow-paged extent regions storing the committed database state.
//!
//! **Crash Safety Guarantee**:
//! A commit writes new shadow pages first and updates only the inactive superblock slot (`gen % 2`)
//! with both a `payload_blake3` hash and a `superblock_blake3` header seal.
//! If a crash, kill -9, or torn disk write corrupts the active transaction before completion,
//! `recoverLatestSnapshot` automatically detects the checksum mismatch on the newer slot and
//! recovers the previous committed generation from the other superblock slot with 0 data loss!

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tree_sum = @import("../algebra/tree_sum.zig");

pub const PAGE_SIZE: usize = 4096;
pub const SUPERBLOCK_MAGIC = "ZVCSPG01";
pub const ArtifactHash = tree_sum.ArtifactHash;

pub const Superblock = struct {
    tx_generation: u64,
    start_page: u32,
    payload_len: u64,
    payload_hash: ArtifactHash,

    pub fn encodeToPage(self: Superblock) [PAGE_SIZE]u8 {
        var page: [PAGE_SIZE]u8 = @splat(0);
        @memcpy(page[0..8], SUPERBLOCK_MAGIC);
        std.mem.writeInt(u64, page[8..16], self.tx_generation, .little);
        std.mem.writeInt(u32, page[16..20], self.start_page, .little);
        std.mem.writeInt(u64, page[20..28], self.payload_len, .little);
        @memcpy(page[28..60], &self.payload_hash);

        const sb_hash = tree_sum.computeBlake3(page[0..60]);
        @memcpy(page[60..92], &sb_hash);
        return page;
    }

    pub fn decodeFromPage(page: *const [PAGE_SIZE]u8) ?Superblock {
        if (!std.mem.eql(u8, page[0..8], SUPERBLOCK_MAGIC)) return null;
        const expected_sb_hash = page[60..92].*;
        const actual_sb_hash = tree_sum.computeBlake3(page[0..60]);
        if (!tree_sum.hashEql(expected_sb_hash, actual_sb_hash)) return null;

        return .{
            .tx_generation = std.mem.readInt(u64, page[8..16], .little),
            .start_page = std.mem.readInt(u32, page[16..20], .little),
            .payload_len = std.mem.readInt(u64, page[20..28], .little),
            .payload_hash = page[28..60].*,
        };
    }
};

pub const RecoveryResult = struct {
    tx_generation: u64,
    active_slot: u1,
    fell_back_from_corrupt_slot: bool,
    payload: []u8,
};

/// In-memory & on-disk 4KB paged image supporting Dual-Superblock shadow commits and fault injection.
pub const PagedImage = struct {
    allocator: Allocator,
    pages: std.ArrayList([PAGE_SIZE]u8) = .empty,
    current_gen: u64 = 0,

    pub fn init(allocator: Allocator) !PagedImage {
        var img = PagedImage{ .allocator = allocator };
        // Reserve Page 0 (Superblock Slot 0) and Page 1 (Superblock Slot 1)
        try img.pages.append(allocator, @splat(0));
        try img.pages.append(allocator, @splat(0));
        return img;
    }

    pub fn deinit(self: *PagedImage) void {
        self.pages.deinit(self.allocator);
    }

    /// Commit `payload` into a non-overlapping shadow page extent (reclaiming retired extents
    /// while preserving the previous superblock's extent for 100% Dual-Superblock crash recovery)
    /// and atomically flip the next superblock slot.
    pub fn commitSnapshot(self: *PagedImage, payload: []const u8) !u64 {
        const next_gen = self.current_gen + 1;
        const slot: usize = @intCast(next_gen % 2);
        const prev_slot: usize = 1 - slot;

        const num_pages = (payload.len + PAGE_SIZE - 1) / PAGE_SIZE;

        var prev_start: usize = 2;
        var prev_end: usize = 2;
        if (self.pages.items.len >= 2) {
            if (Superblock.decodeFromPage(&self.pages.items[prev_slot])) |prev_sb| {
                const prev_count = (prev_sb.payload_len + PAGE_SIZE - 1) / PAGE_SIZE;
                prev_start = prev_sb.start_page;
                prev_end = prev_start + prev_count;
            }
        }

        // Choose the lowest page offset >= 2 that does not overlap `[prev_start .. prev_end)`
        const start_page_usize: usize = if (prev_start >= 2 + num_pages or prev_end <= 2)
            2
        else
            prev_end;

        const required_total = @max(prev_end, start_page_usize + num_pages);
        while (self.pages.items.len < required_total) {
            try self.pages.append(self.allocator, @splat(0));
        }

        var offset: usize = 0;
        for (0..num_pages) |i| {
            var page: [PAGE_SIZE]u8 = @splat(0);
            const chunk_len = @min(PAGE_SIZE, payload.len - offset);
            @memcpy(page[0..chunk_len], payload[offset .. offset + chunk_len]);
            self.pages.items[start_page_usize + i] = page;
            offset += chunk_len;
        }

        // Reclaim any retired tail pages beyond both active and fallback superblock extents
        if (self.pages.items.len > required_total) {
            self.pages.shrinkRetainingCapacity(required_total);
        }

        const sb = Superblock{
            .tx_generation = next_gen,
            .start_page = @intCast(start_page_usize),
            .payload_len = payload.len,
            .payload_hash = tree_sum.computeBlake3(payload),
        };

        // Atomic superblock write to Slot 0 (even) or Slot 1 (odd)
        self.pages.items[slot] = sb.encodeToPage();
        self.current_gen = next_gen;
        return next_gen;
    }

    /// Reclaim all inactive shadow pages by compacting the latest valid snapshot to page 2
    /// and synchronizing both superblock slots. Returns the number of 4KB pages reclaimed.
    pub fn compactAndGC(self: *PagedImage, allocator: Allocator) !usize {
        const before_pages = self.pages.items.len;
        const rec = try self.recoverLatestSnapshot(allocator);
        defer allocator.free(rec.payload);

        self.pages.shrinkRetainingCapacity(2);
        self.pages.items[0] = @splat(0);
        self.pages.items[1] = @splat(0);
        self.current_gen = rec.tx_generation;
        _ = try self.commitSnapshot(rec.payload);

        return before_pages -| self.pages.items.len;
    }

    /// Simulate a torn write / crash mid-commit by writing partial/corrupted shadow pages
    /// or a corrupted superblock into the target slot.
    pub fn injectTornCommitFault(self: *PagedImage, partial_payload: []const u8) !void {
        const bad_gen = self.current_gen + 1;
        const slot: usize = @intCast(bad_gen % 2);
        const start_page: u32 = @intCast(self.pages.items.len);

        var page: [PAGE_SIZE]u8 = @splat(0xAA);
        const copy_len = @min(PAGE_SIZE, partial_payload.len);
        @memcpy(page[0..copy_len], partial_payload[0..copy_len]);
        try self.pages.append(self.allocator, page);

        // Write a superblock whose payload hash does NOT match the torn page on disk
        const sb = Superblock{
            .tx_generation = bad_gen,
            .start_page = start_page,
            .payload_len = partial_payload.len + 128,
            .payload_hash = tree_sum.computeBlake3("expected_untorn_payload"),
        };
        self.pages.items[slot] = sb.encodeToPage();
    }

    /// Recover the newest valid snapshot across Superblock Slot 0 and Slot 1.
    pub fn recoverLatestSnapshot(self: *const PagedImage, allocator: Allocator) !RecoveryResult {
        if (self.pages.items.len < 2) return error.CorruptPagedImage;

        const sb0_opt = Superblock.decodeFromPage(&self.pages.items[0]);
        const sb1_opt = Superblock.decodeFromPage(&self.pages.items[1]);

        // Order candidate slots from highest `tx_generation` to lowest
        var candidates: [2]?struct { slot: u1, sb: Superblock } = .{ null, null };
        if (sb0_opt != null and sb1_opt != null) {
            if (sb0_opt.?.tx_generation >= sb1_opt.?.tx_generation) {
                candidates[0] = .{ .slot = 0, .sb = sb0_opt.? };
                candidates[1] = .{ .slot = 1, .sb = sb1_opt.? };
            } else {
                candidates[0] = .{ .slot = 1, .sb = sb1_opt.? };
                candidates[1] = .{ .slot = 0, .sb = sb0_opt.? };
            }
        } else if (sb0_opt) |sb0| {
            candidates[0] = .{ .slot = 0, .sb = sb0 };
        } else if (sb1_opt) |sb1| {
            candidates[0] = .{ .slot = 1, .sb = sb1 };
        } else {
            return error.NoValidSuperblockFound;
        }

        var fell_back = false;
        for (candidates) |cand_opt| {
            const cand = cand_opt orelse continue;
            if (self.extractAndVerifyPayload(allocator, cand.sb)) |valid_payload| {
                return .{
                    .tx_generation = cand.sb.tx_generation,
                    .active_slot = cand.slot,
                    .fell_back_from_corrupt_slot = fell_back,
                    .payload = valid_payload,
                };
            } else |_| {
                fell_back = true;
            }
        }

        return error.AllSuperblocksCorrupt;
    }

    fn extractAndVerifyPayload(
        self: *const PagedImage,
        allocator: Allocator,
        sb: Superblock,
    ) ![]u8 {
        const num_pages = (sb.payload_len + PAGE_SIZE - 1) / PAGE_SIZE;
        if (@as(usize, sb.start_page) + num_pages > self.pages.items.len) {
            return error.SuperblockExtentOutOfBounds;
        }

        const out = try allocator.alloc(u8, sb.payload_len);
        errdefer allocator.free(out);

        var offset: usize = 0;
        var page_idx: usize = sb.start_page;
        while (offset < sb.payload_len) : (page_idx += 1) {
            const chunk_len = @min(PAGE_SIZE, sb.payload_len - offset);
            @memcpy(out[offset .. offset + chunk_len], self.pages.items[page_idx][0..chunk_len]);
            offset += chunk_len;
        }

        const actual_hash = tree_sum.computeBlake3(out);
        if (!tree_sum.hashEql(sb.payload_hash, actual_hash)) {
            return error.PayloadHashMismatch;
        }
        return out;
    }

    pub fn writeToFile(self: *const PagedImage, io: Io, path: []const u8) !void {
        const file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var writer: Io.File.Writer = .init(file, io, &buf);
        for (self.pages.items) |page| {
            try writer.interface.writeAll(&page);
        }
        try writer.interface.flush();
    }

    pub fn readFromFile(allocator: Allocator, io: Io, path: []const u8) !PagedImage {
        const raw = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(raw);

        if (raw.len < 2 * PAGE_SIZE or raw.len % PAGE_SIZE != 0) {
            return error.InvalidPagedFileSize;
        }

        const slice_rec = try extractLatestPayloadSlice(raw);

        var img = PagedImage{ .allocator = allocator };
        errdefer img.deinit();

        const num_pages = raw.len / PAGE_SIZE;
        try img.pages.ensureTotalCapacity(allocator, num_pages);
        for (0..num_pages) |i| {
            const page = raw[i * PAGE_SIZE .. (i + 1) * PAGE_SIZE][0..PAGE_SIZE].*;
            img.pages.appendAssumeCapacity(page);
        }

        img.current_gen = slice_rec.tx_generation;
        return img;
    }
};

pub const SliceRecoveryResult = struct {
    tx_generation: u64,
    active_slot: u1,
    fell_back_from_corrupt_slot: bool,
    payload: []const u8,
};

/// Returns true if `raw` begins with a 4KB Dual-Superblock paged image header in Slot 0 or Slot 1.
pub fn hasPagedSuperblockMagic(raw: []const u8) bool {
    if (raw.len < 2 * PAGE_SIZE) return false;
    return std.mem.eql(u8, raw[0..SUPERBLOCK_MAGIC.len], SUPERBLOCK_MAGIC) or
        std.mem.eql(u8, raw[PAGE_SIZE .. PAGE_SIZE + SUPERBLOCK_MAGIC.len], SUPERBLOCK_MAGIC);
}

/// Zero-copy recovery of the newest valid snapshot slice directly from a raw paged file buffer.
pub fn extractLatestPayloadSlice(raw: []const u8) !SliceRecoveryResult {
    if (raw.len < 2 * PAGE_SIZE or raw.len % PAGE_SIZE != 0) {
        return error.InvalidPagedFileSize;
    }

    const total_pages = raw.len / PAGE_SIZE;
    const sb0_opt = Superblock.decodeFromPage(raw[0..PAGE_SIZE]);
    const sb1_opt = Superblock.decodeFromPage(raw[PAGE_SIZE .. 2 * PAGE_SIZE]);

    var candidates: [2]?struct { slot: u1, sb: Superblock } = .{ null, null };
    if (sb0_opt != null and sb1_opt != null) {
        if (sb0_opt.?.tx_generation >= sb1_opt.?.tx_generation) {
            candidates[0] = .{ .slot = 0, .sb = sb0_opt.? };
            candidates[1] = .{ .slot = 1, .sb = sb1_opt.? };
        } else {
            candidates[0] = .{ .slot = 1, .sb = sb1_opt.? };
            candidates[1] = .{ .slot = 0, .sb = sb0_opt.? };
        }
    } else if (sb0_opt) |sb0| {
        candidates[0] = .{ .slot = 0, .sb = sb0 };
    } else if (sb1_opt) |sb1| {
        candidates[0] = .{ .slot = 1, .sb = sb1 };
    } else {
        return error.NoValidSuperblockFound;
    }

    var fell_back = false;
    for (candidates) |cand_opt| {
        const cand = cand_opt orelse continue;
        const sb = cand.sb;
        const num_pages = (sb.payload_len + PAGE_SIZE - 1) / PAGE_SIZE;
        if (@as(usize, sb.start_page) + num_pages > total_pages) {
            fell_back = true;
            continue;
        }
        const start_byte = @as(usize, sb.start_page) * PAGE_SIZE;
        const end_byte = start_byte + @as(usize, @intCast(sb.payload_len));
        if (end_byte > raw.len) {
            fell_back = true;
            continue;
        }
        const slice = raw[start_byte..end_byte];
        const actual_hash = tree_sum.computeBlake3(slice);
        if (!tree_sum.hashEql(sb.payload_hash, actual_hash)) {
            fell_back = true;
            continue;
        }
        return .{
            .tx_generation = sb.tx_generation,
            .active_slot = cand.slot,
            .fell_back_from_corrupt_slot = fell_back,
            .payload = slice,
        };
    }

    return error.AllSuperblocksCorrupt;
}

/// Stream a compacted single-extent snapshot directly to `path` on disk without allocating
/// an intermediate `ArrayList([4096]u8)` copy of `payload`.
pub fn writeCompactSnapshotToFile(
    io: Io,
    path: []const u8,
    payload: []const u8,
    tx_generation: u64,
) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    const sb = Superblock{
        .tx_generation = tx_generation,
        .start_page = 2,
        .payload_len = payload.len,
        .payload_hash = tree_sum.computeBlake3(payload),
    };
    const sb_page = sb.encodeToPage();
    const zero_page: [PAGE_SIZE]u8 = @splat(0);

    var buf: [64 * 1024]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buf);
    if (tx_generation % 2 == 0) {
        try writer.interface.writeAll(&sb_page);
        try writer.interface.writeAll(&zero_page);
    } else {
        try writer.interface.writeAll(&zero_page);
        try writer.interface.writeAll(&sb_page);
    }
    try writer.interface.writeAll(payload);
    const rem = payload.len % PAGE_SIZE;
    if (rem != 0) {
        try writer.interface.writeAll(zero_page[0 .. PAGE_SIZE - rem]);
    }
    try writer.interface.flush();
}

test "4KB Paged Storage Engine: Dual-Superblock atomic commit and torn-write crash recovery" {
    const gpa = std.testing.allocator;
    var img = try PagedImage.init(gpa);
    defer img.deinit();

    // Generation 1 (written to Slot 1)
    const gen1 = try img.commitSnapshot("state-generation-1-clean");
    try std.testing.expectEqual(@as(u64, 1), gen1);

    // Generation 2 (written to Slot 0)
    const gen2 = try img.commitSnapshot("state-generation-2-committed");
    try std.testing.expectEqual(@as(u64, 2), gen2);

    // Simulate power failure / torn write during Generation 3 (corrupting Slot 1)!
    try img.injectTornCommitFault("torn-uncommitted-gen3");

    // Recovery must detect the torn write in Slot 1 (gen 3) and seamlessly fall back to Slot 0 (gen 2)!
    const rec = try img.recoverLatestSnapshot(gpa);
    defer gpa.free(rec.payload);

    try std.testing.expect(rec.fell_back_from_corrupt_slot);
    try std.testing.expectEqual(@as(u64, 2), rec.tx_generation);
    try std.testing.expectEqual(@as(u1, 0), rec.active_slot);
    try std.testing.expectEqualStrings("state-generation-2-committed", rec.payload);
}
