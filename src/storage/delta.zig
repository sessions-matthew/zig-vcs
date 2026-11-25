//! Fossil-Style Byte-Level Delta Compression (`encodeDelta` / `applyDelta`).
//!
//! Inspired by D. Richard Hipp's Fossil delta format (`fossil_tech_overview.wiki` §2.1):
//! Encodes a `target` byte slice relative to a `base` byte slice as a sequence of compact
//! instructions:
//! - **Opcode `0x01` (COPY)**: Copy `len: u32` bytes starting at `offset: u32` from `base`.
//! - **Opcode `0x02` (LITERAL)**: Emit `len: u32` literal bytes directly from the delta stream.
//! Header stores:
//! - Magic `"ZDL1"` (4 bytes)
//! - `target_len: u32` (4 bytes)
//! - `target_blake3: [32]u8` (32 bytes, end-to-end integrity check on decode!)
//!
//! Uses a fast 8-byte rolling fingerprint table (`MIN_MATCH = 8`) to find longest matches in `base`
//! in O(N) time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tree_sum = @import("../algebra/tree_sum.zig");

pub const ArtifactHash = tree_sum.ArtifactHash;
pub const DELTA_MAGIC = "ZDL1";
pub const MIN_MATCH: usize = 8;
const HASH_BITS = 13;
const HASH_SIZE = 1 << HASH_BITS;

const OpKind = enum(u8) {
    copy = 1,
    literal = 2,
};

fn hash8(bytes: []const u8) usize {
    std.debug.assert(bytes.len >= MIN_MATCH);
    const val = std.mem.readInt(u64, bytes[0..8], .little);
    const mult: u64 = 0x9E3779B97F4A7C15;
    return @intCast((val *% mult) >> (64 - HASH_BITS));
}

/// Encode `target` as a compact delta relative to `base`.
pub fn encodeDelta(allocator: Allocator, base: []const u8, target: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // 1. Write 40-byte header: "ZDL1" + target_len (u32) + target_blake3 ([32]u8)
    try out.appendSlice(allocator, DELTA_MAGIC);
    try writeU32(allocator, &out, @intCast(target.len));
    const target_hash = tree_sum.computeBlake3(target);
    try out.appendSlice(allocator, &target_hash);

    if (target.len == 0) {
        return out.toOwnedSlice(allocator);
    }

    if (base.len < MIN_MATCH or target.len < MIN_MATCH) {
        try emitLiteral(allocator, &out, target);
        return out.toOwnedSlice(allocator);
    }

    const raw_prefix = std.mem.indexOfDiff(u8, base, target) orelse @min(base.len, target.len);
    if (raw_prefix == target.len and base.len == target.len) {
        try emitCopy(allocator, &out, 0, @intCast(target.len));
        return out.toOwnedSlice(allocator);
    }
    const prefix_len: usize = if (raw_prefix >= MIN_MATCH) raw_prefix else 0;

    const max_suffix = @min(base.len - prefix_len, target.len - prefix_len);
    var raw_suffix: usize = 0;
    while (raw_suffix < max_suffix and
        base[base.len - 1 - raw_suffix] == target[target.len - 1 - raw_suffix]) : (raw_suffix += 1)
    {}
    const suffix_len: usize = if (raw_suffix >= MIN_MATCH) raw_suffix else 0;

    if (prefix_len > 0) {
        try emitCopy(allocator, &out, 0, @intCast(prefix_len));
    }

    const mid_base = base[prefix_len .. base.len - suffix_len];
    const mid_target = target[prefix_len .. target.len - suffix_len];

    if (mid_target.len > 0) {
        if (mid_base.len < MIN_MATCH or mid_target.len < MIN_MATCH) {
            try emitLiteral(allocator, &out, mid_target);
        } else {
            // Index 8-byte substrings of `mid_base` with 2 slots (first + latest occurrence)
            const NO_POS = std.math.maxInt(u32);
            var table: [HASH_SIZE][2]u32 = @splat(@splat(NO_POS));
            const limit_base = mid_base.len - MIN_MATCH;
            const step: usize = @max(1, (mid_base.len - MIN_MATCH + 1) / (HASH_SIZE * 2));
            var bi: usize = 0;
            while (bi <= limit_base) : (bi += step) {
                const h = hash8(mid_base[bi .. bi + MIN_MATCH]);
                if (table[h][0] == NO_POS) {
                    table[h][0] = @intCast(bi);
                } else {
                    table[h][1] = @intCast(bi);
                }
            }

            var lit_start: usize = 0;
            var ti: usize = 0;
            var diag_offset: isize = 0;
            const limit_target = mid_target.len - MIN_MATCH;

            while (ti <= limit_target) {
                const pred_isize = @as(isize, @intCast(ti)) + diag_offset;
                var matched_base_pos: ?usize = null;
                if (pred_isize >= 0) {
                    const pred_pos: usize = @intCast(pred_isize);
                    if (pred_pos <= limit_base and
                        std.mem.eql(u8, mid_base[pred_pos .. pred_pos + MIN_MATCH], mid_target[ti .. ti + MIN_MATCH]))
                    {
                        matched_base_pos = pred_pos;
                    }
                }
                if (matched_base_pos == null) {
                    const h = hash8(mid_target[ti .. ti + MIN_MATCH]);
                    var best_dist: usize = std.math.maxInt(usize);
                    for (table[h]) |cand_u32| {
                        if (cand_u32 == NO_POS) continue;
                        const cand: usize = cand_u32;
                        if (std.mem.eql(u8, mid_base[cand .. cand + MIN_MATCH], mid_target[ti .. ti + MIN_MATCH])) {
                            const dist = @abs(@as(isize, @intCast(cand)) - pred_isize);
                            if (matched_base_pos == null or dist < best_dist) {
                                matched_base_pos = cand;
                                best_dist = dist;
                            }
                        }
                    }
                }

                if (matched_base_pos) |base_pos| {
                    if (ti > lit_start) {
                        try emitLiteral(allocator, &out, mid_target[lit_start..ti]);
                    }

                    const rem_base = mid_base[base_pos + MIN_MATCH ..];
                    const rem_target = mid_target[ti + MIN_MATCH ..];
                    const rem_len = @min(rem_base.len, rem_target.len);
                    const extra = std.mem.indexOfDiff(u8, rem_base[0..rem_len], rem_target[0..rem_len]) orelse rem_len;
                    const match_len = MIN_MATCH + extra;

                    try emitCopy(allocator, &out, @intCast(prefix_len + base_pos), @intCast(match_len));
                    diag_offset = @as(isize, @intCast(base_pos)) - @as(isize, @intCast(ti));
                    ti += match_len;
                    lit_start = ti;
                    continue;
                }
                ti += 1;
            }

            if (lit_start < mid_target.len) {
                try emitLiteral(allocator, &out, mid_target[lit_start..]);
            }
        }
    }

    if (suffix_len > 0) {
        try emitCopy(allocator, &out, @intCast(base.len - suffix_len), @intCast(suffix_len));
    }

    return out.toOwnedSlice(allocator);
}

/// Apply `delta` to `base` and verify the reconstructed target's BLAKE3 hash!
pub fn applyDelta(allocator: Allocator, base: []const u8, delta: []const u8) ![]u8 {
    if (delta.len < 40) return error.CorruptDelta;
    if (!std.mem.eql(u8, delta[0..4], DELTA_MAGIC)) return error.InvalidDeltaMagic;

    var pos: usize = 4;
    const target_len = try readU32(delta, &pos);
    if (target_len > 64 * 1024 * 1024) return error.CorruptDelta;
    const expected_hash = delta[pos..][0..32].*;
    pos += 32;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, @min(target_len, 65536));

    while (pos < delta.len) {
        const op_byte = delta[pos];
        pos += 1;
        switch (op_byte) {
            @intFromEnum(OpKind.copy) => {
                const offset = try readU32(delta, &pos);
                const len = try readU32(delta, &pos);
                if (offset > base.len or len > base.len - offset) return error.DeltaCopyOutOfBounds;
                if (len > target_len - out.items.len) return error.DeltaLengthMismatch;
                try out.appendSlice(allocator, base[offset .. offset + len]);
            },
            @intFromEnum(OpKind.literal) => {
                const len = try readU32(delta, &pos);
                if (len > delta.len - pos) return error.DeltaLiteralOutOfBounds;
                if (len > target_len - out.items.len) return error.DeltaLengthMismatch;
                try out.appendSlice(allocator, delta[pos .. pos + len]);
                pos += len;
            },
            else => return error.UnknownDeltaOpcode,
        }
    }

    if (out.items.len != target_len) return error.DeltaLengthMismatch;
    const actual_hash = tree_sum.computeBlake3(out.items);
    if (!tree_sum.hashEql(expected_hash, actual_hash)) return error.DeltaHashMismatch;

    return out.toOwnedSlice(allocator);
}

fn emitCopy(allocator: Allocator, out: *std.ArrayList(u8), offset: u32, len: u32) !void {
    try out.append(allocator, @intFromEnum(OpKind.copy));
    try writeU32(allocator, out, offset);
    try writeU32(allocator, out, len);
}

fn emitLiteral(allocator: Allocator, out: *std.ArrayList(u8), slice: []const u8) !void {
    try out.append(allocator, @intFromEnum(OpKind.literal));
    try writeU32(allocator, out, @intCast(slice.len));
    try out.appendSlice(allocator, slice);
}

fn writeU32(allocator: Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

fn readU32(data: []const u8, pos: *usize) !u32 {
    if (data.len - pos.* < 4) return error.CorruptDelta;
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

test "Fossil-Style Byte Delta: compresses large edited source file and verifies BLAKE3 on decode" {
    const gpa = std.testing.allocator;

    var base_buf: std.ArrayList(u8) = .empty;
    defer base_buf.deinit(gpa);
    for (0..100) |i| {
        const line = try std.fmt.allocPrint(gpa, "pub fn handler_{d}(ctx: *Context) !void {{ return ctx.run({d}); }}\n", .{ i, i });
        defer gpa.free(line);
        try base_buf.appendSlice(gpa, line);
    }

    var target_buf: std.ArrayList(u8) = .empty;
    defer target_buf.deinit(gpa);
    try target_buf.appendSlice(gpa, "// Added header comment in v2\n");
    try target_buf.appendSlice(gpa, base_buf.items[0..1200]);
    try target_buf.appendSlice(gpa, "pub fn custom_inserted_hook() void {}\n");
    try target_buf.appendSlice(gpa, base_buf.items[1200..]);

    const delta = try encodeDelta(gpa, base_buf.items, target_buf.items);
    defer gpa.free(delta);

    // Delta should be a tiny fraction (< 5%) of the full target size!
    try std.testing.expect(delta.len < target_buf.items.len / 15);

    const decoded = try applyDelta(gpa, base_buf.items, delta);
    defer gpa.free(decoded);

    try std.testing.expectEqualSlices(u8, target_buf.items, decoded);
}
