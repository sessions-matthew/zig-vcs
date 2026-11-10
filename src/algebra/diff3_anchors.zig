//! Anchor-Separated 3-Way Line Merger & Conflict Marker Renderer/Parser.
//!
//! Implements Khanna, Kunal, & Pierce (FSTTCS 2007), "A Formal Investigation of Diff3":
//! - **Theorem 4 (Anchor Separation)**: Unique anchor lines (occurring exactly once in Base A,
//!   Ours B, and Theirs C in monotonically increasing order) partition files into independent
//!   regions that can be merged locally without false alignments.
//! - **Same-Change Idempotence (`B + C - A`)**: Within each region between anchors:
//!   - If `B_i == A_i`, result is cleanly `C_i` (`A + C - A = C`).
//!   - If `C_i == A_i`, result is cleanly `B_i` (`B + A - A = B`).
//!   - If `B_i == C_i`, result is cleanly `B_i` (both branches made the exact same edit).
//!   - Otherwise, the region is a true conflict (`has_conflict = true`).
//! - **Storage Purity**: `<<<<<<<` markers are NEVER stored in the artifact table; they are
//!   only materialized when rendering a conflicted `FormalTreeSum` to a worktree on disk.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MergeOutcome = struct {
    /// True if all anchor-separated regions resolved cleanly into `merged_bytes`.
    is_clean: bool,
    /// If `is_clean == true`, contains the clean merged file content.
    /// If `is_clean == false`, contains the rendered diff3 conflict markers for checkout display.
    bytes: []u8,
};

const AnchorMatch = struct {
    idx_a: usize,
    idx_b: usize,
    idx_c: usize,
};

/// Split text into lines (preserving empty trailing semantics cleanly via line slices).
pub fn splitLines(allocator: Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    if (text.len == 0) return list.toOwnedSlice(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            try list.append(allocator, text[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < text.len) {
        try list.append(allocator, text[start..text.len]);
    }
    return list.toOwnedSlice(allocator);
}

fn linesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |la, lb| {
        if (!std.mem.eql(u8, la, lb)) return false;
    }
    return true;
}

/// Find unique anchor lines occurring once in `lines_a`, `lines_b`, and `lines_c`,
/// and extract their longest common monotonically increasing subsequence in B and C.
fn findMonotonicUniqueAnchors(
    allocator: Allocator,
    lines_a: []const []const u8,
    lines_b: []const []const u8,
    lines_c: []const []const u8,
) ![]AnchorMatch {
    var candidates: std.ArrayList(AnchorMatch) = .empty;
    defer candidates.deinit(allocator);

    for (lines_a, 0..) |line, ia| {
        // Count occurrences in A
        var count_a: usize = 0;
        for (lines_a) |other| {
            if (std.mem.eql(u8, line, other)) count_a += 1;
        }
        if (count_a != 1) continue;

        // Count occurrences in B
        var count_b: usize = 0;
        var ib_found: usize = 0;
        for (lines_b, 0..) |other, ib| {
            if (std.mem.eql(u8, line, other)) {
                count_b += 1;
                ib_found = ib;
            }
        }
        if (count_b != 1) continue;

        // Count occurrences in C
        var count_c: usize = 0;
        var ic_found: usize = 0;
        for (lines_c, 0..) |other, ic| {
            if (std.mem.eql(u8, line, other)) {
                count_c += 1;
                ic_found = ic;
            }
        }
        if (count_c != 1) continue;

        try candidates.append(allocator, .{
            .idx_a = ia,
            .idx_b = ib_found,
            .idx_c = ic_found,
        });
    }

    if (candidates.items.len == 0) {
        return allocator.alloc(AnchorMatch, 0);
    }

    // Dynamic programming for longest increasing subsequence in both idx_b and idx_c
    const n = candidates.items.len;
    const dp = try allocator.alloc(usize, n);
    defer allocator.free(dp);
    const prev = try allocator.alloc(?usize, n);
    defer allocator.free(prev);

    var best_len: usize = 0;
    var best_end: usize = 0;

    for (0..n) |i| {
        dp[i] = 1;
        prev[i] = null;
        for (0..i) |j| {
            if (candidates.items[j].idx_b < candidates.items[i].idx_b and
                candidates.items[j].idx_c < candidates.items[i].idx_c)
            {
                if (dp[j] + 1 > dp[i]) {
                    dp[i] = dp[j] + 1;
                    prev[i] = j;
                }
            }
        }
        if (dp[i] > best_len) {
            best_len = dp[i];
            best_end = i;
        }
    }

    const result = try allocator.alloc(AnchorMatch, best_len);
    var curr: ?usize = best_end;
    var out_idx: usize = best_len;
    while (curr) |idx| {
        out_idx -= 1;
        result[out_idx] = candidates.items[idx];
        curr = prev[idx];
    }
    return result;
}

fn appendLines(allocator: Allocator, out: *std.ArrayList(u8), slice: []const []const u8) !void {
    for (slice) |line| {
        try out.appendSlice(allocator, line);
    }
}

fn ensureTrailingNewline(allocator: Allocator, out: *std.ArrayList(u8)) !void {
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
}

/// Detect whether a blob is binary (contains NUL `\x00` bytes or invalid UTF-8).
/// Line-based diff3 splicing must never be applied to binary blobs!
pub fn isBinaryBlob(bytes: []const u8) bool {
    const check_len = @min(bytes.len, 8192);
    if (std.mem.indexOfScalar(u8, bytes[0..check_len], 0) != null) return true;
    return !std.unicode.utf8ValidateSlice(bytes);
}

/// Perform Pierce anchor-separated 3-way text merge of `ours` (B) and `theirs` (C) over `base` (A).
/// - If all regions between unique anchors resolve via `B + C - A`, returns `.is_clean = true`
///   and the clean merged text.
/// - If any region conflicts (or if any input is a binary blob), returns `.is_clean = false`
///   and renders diff3 markers for checkout.
pub fn mergeTextAnchorDiff3(
    allocator: Allocator,
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
    ours_label: []const u8,
    base_label: []const u8,
    theirs_label: []const u8,
) !MergeOutcome {
    // Fast-path exact blob algebraic cancellations (safe for both text and binary!)
    if (std.mem.eql(u8, ours, base)) {
        return .{ .is_clean = true, .bytes = try allocator.dupe(u8, theirs) };
    }
    if (std.mem.eql(u8, theirs, base) or std.mem.eql(u8, ours, theirs)) {
        return .{ .is_clean = true, .bytes = try allocator.dupe(u8, ours) };
    }

    // Never splice binary blobs line-by-line!
    if (isBinaryBlob(base) or isBinaryBlob(ours) or isBinaryBlob(theirs)) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "<<<<<<< {s} (binary blob, {d} bytes)\n||||||| {s} (binary blob, {d} bytes)\n=======\n>>>>>>> {s} (binary blob, {d} bytes)\n",
            .{ ours_label, ours.len, base_label, base.len, theirs_label, theirs.len },
        );
        return .{ .is_clean = false, .bytes = msg };
    }

    const lines_a = try splitLines(allocator, base);
    defer allocator.free(lines_a);
    const lines_b = try splitLines(allocator, ours);
    defer allocator.free(lines_b);
    const lines_c = try splitLines(allocator, theirs);
    defer allocator.free(lines_c);

    const anchors = try findMonotonicUniqueAnchors(allocator, lines_a, lines_b, lines_c);
    defer allocator.free(anchors);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var has_conflict = false;
    var pos_a: usize = 0;
    var pos_b: usize = 0;
    var pos_c: usize = 0;

    for (anchors) |anchor| {
        const reg_a = lines_a[pos_a..anchor.idx_a];
        const reg_b = lines_b[pos_b..anchor.idx_b];
        const reg_c = lines_c[pos_c..anchor.idx_c];

        try mergeRegion(
            allocator,
            &out,
            &has_conflict,
            reg_a,
            reg_b,
            reg_c,
            ours_label,
            base_label,
            theirs_label,
        );

        // Emit the shared unique anchor line itself
        try out.appendSlice(allocator, lines_a[anchor.idx_a]);

        pos_a = anchor.idx_a + 1;
        pos_b = anchor.idx_b + 1;
        pos_c = anchor.idx_c + 1;
    }

    // Merge trailing region after the final anchor
    try mergeRegion(
        allocator,
        &out,
        &has_conflict,
        lines_a[pos_a..],
        lines_b[pos_b..],
        lines_c[pos_c..],
        ours_label,
        base_label,
        theirs_label,
    );

    return .{
        .is_clean = !has_conflict,
        .bytes = try out.toOwnedSlice(allocator),
    };
}

fn mergeRegion(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    has_conflict: *bool,
    reg_a: []const []const u8,
    reg_b: []const []const u8,
    reg_c: []const []const u8,
    ours_label: []const u8,
    base_label: []const u8,
    theirs_label: []const u8,
) !void {
    if (linesEqual(reg_b, reg_a)) {
        // B == A => A + C - A = C
        try appendLines(allocator, out, reg_c);
    } else if (linesEqual(reg_c, reg_a) or linesEqual(reg_b, reg_c)) {
        // C == A or B == C => B
        try appendLines(allocator, out, reg_b);
    } else {
        // True conflict in this region: render diff3 markers for working-copy checkout
        has_conflict.* = true;
        try ensureTrailingNewline(allocator, out);
        try out.appendSlice(allocator, "<<<<<<< ");
        try out.appendSlice(allocator, ours_label);
        try out.append(allocator, '\n');
        try appendLines(allocator, out, reg_b);
        try ensureTrailingNewline(allocator, out);

        try out.appendSlice(allocator, "||||||| ");
        try out.appendSlice(allocator, base_label);
        try out.append(allocator, '\n');
        try appendLines(allocator, out, reg_a);
        try ensureTrailingNewline(allocator, out);

        try out.appendSlice(allocator, "=======\n");
        try appendLines(allocator, out, reg_c);
        try ensureTrailingNewline(allocator, out);

        try out.appendSlice(allocator, ">>>>>>> ");
        try out.appendSlice(allocator, theirs_label);
        try out.append(allocator, '\n');
    }
}

/// Check whether a working-copy file still contains unresolved conflict markers.
pub fn hasConflictMarkers(content: []const u8) bool {
    var has_open = false;
    var has_sep = false;
    var has_close = false;

    var start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i == content.len or content[i] == '\n') {
            const line = content[start..i];
            if (std.mem.startsWith(u8, line, "<<<<<<< ")) has_open = true;
            if (std.mem.eql(u8, line, "=======") or std.mem.eql(u8, line, "=======\r")) has_sep = true;
            if (std.mem.startsWith(u8, line, ">>>>>>> ")) has_close = true;
            start = i + 1;
        }
    }
    return has_open and has_sep and has_close;
}

/// Render minimal unified diff hunks (`@@ -old_start,old_len +new_start,new_len @@` with context lines)
/// between `old_bytes` and `new_bytes` using unique-anchor LCS partitioning + common prefix/suffix trimming.
pub fn renderUnifiedDiffHunks(
    allocator: Allocator,
    old_bytes: []const u8,
    new_bytes: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (std.mem.eql(u8, old_bytes, new_bytes)) return out.toOwnedSlice(allocator);

    const lines_old = try splitLines(allocator, old_bytes);
    defer allocator.free(lines_old);
    const lines_new = try splitLines(allocator, new_bytes);
    defer allocator.free(lines_new);

    const anchors = try findMonotonicUniqueAnchors(allocator, lines_old, lines_old, lines_new);
    defer allocator.free(anchors);

    var pos_o: usize = 0;
    var pos_n: usize = 0;

    for (anchors) |anc| {
        try emitRegionHunk(allocator, &out, lines_old, lines_new, pos_o, anc.idx_a, pos_n, anc.idx_c);
        pos_o = anc.idx_a + 1;
        pos_n = anc.idx_c + 1;
    }
    try emitRegionHunk(allocator, &out, lines_old, lines_new, pos_o, lines_old.len, pos_n, lines_new.len);

    return out.toOwnedSlice(allocator);
}

fn emitRegionHunk(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    lines_old: []const []const u8,
    lines_new: []const []const u8,
    o_start: usize,
    o_end: usize,
    n_start: usize,
    n_end: usize,
) !void {
    var o0 = o_start;
    var o1 = o_end;
    var n0 = n_start;
    var n1 = n_end;

    // Trim identical leading lines within the region
    while (o0 < o1 and n0 < n1 and std.mem.eql(u8, lines_old[o0], lines_new[n0])) {
        o0 += 1;
        n0 += 1;
    }
    // Trim identical trailing lines within the region
    while (o1 > o0 and n1 > n0 and std.mem.eql(u8, lines_old[o1 - 1], lines_new[n1 - 1])) {
        o1 -= 1;
        n1 -= 1;
    }

    if (o0 == o1 and n0 == n1) return;

    const ctx_before = @min(@as(usize, 2), o0);
    const ctx_after = @min(@as(usize, 2), lines_old.len - o1);

    const hunk_o_start = (o0 - ctx_before) + 1;
    const hunk_o_len = (o1 - o0) + ctx_before + ctx_after;
    const hunk_n_start = (n0 -| ctx_before) + 1;
    const hunk_n_len = (n1 - n0) + ctx_before + ctx_after;

    try out.print(
        allocator,
        "@@ -{d},{d} +{d},{d} @@\n",
        .{ hunk_o_start, hunk_o_len, hunk_n_start, hunk_n_len },
    );

    // Leading context lines
    for ((o0 - ctx_before)..o0) |idx| {
        const clean_line = std.mem.trimEnd(u8, lines_old[idx], "\r\n");
        try out.print(allocator, " {s}\n", .{clean_line});
    }
    // Removed lines
    for (o0..o1) |idx| {
        const clean_line = std.mem.trimEnd(u8, lines_old[idx], "\r\n");
        try out.print(allocator, "-{s}\n", .{clean_line});
    }
    // Added lines
    for (n0..n1) |idx| {
        const clean_line = std.mem.trimEnd(u8, lines_new[idx], "\r\n");
        try out.print(allocator, "+{s}\n", .{clean_line});
    }
    // Trailing context lines
    for (o1..(o1 + ctx_after)) |idx| {
        const clean_line = std.mem.trimEnd(u8, lines_old[idx], "\r\n");
        try out.print(allocator, " {s}\n", .{clean_line});
    }
}

test "Anchor-Separated Diff3: merges non-overlapping edits cleanly across unique anchor" {
    const gpa = std.testing.allocator;
    const base =
        "fn header() u32 { return 1; }\n" ++
        "// UNIQUE_ANCHOR_SEPARATOR\n" ++
        "fn footer() u32 { return 10; }\n";
    const ours =
        "fn header() u32 { return 2; }\n" ++
        "// UNIQUE_ANCHOR_SEPARATOR\n" ++
        "fn footer() u32 { return 10; }\n";
    const theirs =
        "fn header() u32 { return 1; }\n" ++
        "// UNIQUE_ANCHOR_SEPARATOR\n" ++
        "fn footer() u32 { return 20; }\n";

    const res = try mergeTextAnchorDiff3(gpa, base, ours, theirs, "ours", "base", "theirs");
    defer gpa.free(res.bytes);

    try std.testing.expect(res.is_clean);
    try std.testing.expect(!hasConflictMarkers(res.bytes));
    try std.testing.expectEqualStrings(
        "fn header() u32 { return 2; }\n" ++
            "// UNIQUE_ANCHOR_SEPARATOR\n" ++
            "fn footer() u32 { return 20; }\n",
        res.bytes,
    );
}

test "Anchor-Separated Diff3: detects overlapping conflict and renders diff3 markers" {
    const gpa = std.testing.allocator;
    const base = "timeout = 1000\n";
    const ours = "timeout = 5000\n";
    const theirs = "timeout = 2500\n";

    const res = try mergeTextAnchorDiff3(gpa, base, ours, theirs, "main", "base", "feat");
    defer gpa.free(res.bytes);

    try std.testing.expect(!res.is_clean);
    try std.testing.expect(hasConflictMarkers(res.bytes));
}
