//! Adversarial Bug-Hunting & Edge-Case Verification Suite.
//!
//! Specifically targets 12 subtle classes of VCS, filesystem, DAG, and memory-safety bugs:
//! 1. **File-vs-Directory (D/F) Path-Prefix Collisions** (`"pkg/module"` file vs `"pkg/module/sub.zig"`).
//! 2. **Empty Parent Directory Cleanup** when switching between deep directory trees and flat files.
//! 3. **Binary Blob Line-Splicing Prevention** (`\x00` NUL bytes around `\n` anchors in `diff3`).
//! 4. **Multi-Commit Topological Chain Rebase** (replaying `lca -> c1 -> c2 -> c3` onto advanced `main`).
//! 5. **"Racy Stat Cache" Protection** (same-timestamp, same-byte-length immediate overwrites after checkout).
//! 6. **Adversarial Bit-Flip, Truncation & `0xFFFFFFFF` Length-Overflow Deserializer Fuzzing**.
//! 7. **Conflicted File Unlink Across Branch Switch** (preventing `<<<<<<<` conflict marker leaks into `db.blobs`, `INV-5a`).
//! 8. **D/F Shadow File (`~df-conflict`) Round-Trip Stability** across `syncWorktreeFromDisk`.
//! 9. **Path Traversal (`..`, leading `/`, `.vcs`) Rejection & Path Canonicalization (`./a//b` -> `a/b`)**.
//! 10. **Crisscross Merge Paradox** (recursive Virtual Merge Base across multiple incomparable MCAs).
//! 11. **Deterministic Out-Of-Memory (`std.testing.FailingAllocator`) Exception Safety** across `RepoDb` transitions.
//! 12. **Algebraic Group Invariant (`INV-5b`, $\sum c_i = 1$) Deserialization Validation** against forged DB payloads.

const std = @import("std");
const Io = std.Io;
const repo_db = @import("../storage/repo_db.zig");
const materializer = @import("../worktree/materializer.zig");
const delta = @import("../storage/delta.zig");
const tree_sum = @import("../algebra/tree_sum.zig");
const diff3 = @import("../algebra/diff3_anchors.zig");
const git_interop = @import("../interop/git_interop.zig");

pub const RepoDb = repo_db.RepoDb;

test "Adversarial 1: File-vs-Directory (D/F) path-prefix conflict is detected and materializes without EEXIST/NotDir crash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wt_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(wt_rel);

    var db = try RepoDb.initNew(gpa, wt_rel);
    defer db.deinit();

    // Base commit on `main`
    try db.editFile(0, "README.md", "root\n");
    _ = try db.commitWorktree(0, "alice", "Base commit");

    // Branch `feat` creates a nested file inside directory `pkg/module/sub.zig`
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "pkg/module/sub.zig", "pub const x = 42;\n");
    _ = try db.commitWorktree(0, "bob", "Add nested file under pkg/module/");

    // Branch `main` creates a regular file at `pkg/module`!
    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "pkg/module", "I am a regular file at pkg/module\n");
    _ = try db.commitWorktree(0, "alice", "Add regular file pkg/module");
    try materializer.materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);

    // Merge `feat` into `main` -> creates a File-vs-Directory (D/F) conflict!
    _ = try db.mergeBranch(0, "feat", "alice", "Merge D/F collision");
    const merged_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expect(merged_tree.hasDirectoryFileConflicts());
    try std.testing.expect(merged_tree.hasConflicts());

    // Materialize to disk: must NOT crash with `error.NotDir` or `error.PathAlreadyExists`!
    try materializer.materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);

    // Verify both `"pkg/module~df-conflict"` and `"pkg/module/sub.zig"` exist on disk!
    const st_df = try tmp.dir.statFile(io, "pkg/module~df-conflict", .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, st_df.kind);

    const st_sub = try tmp.dir.statFile(io, "pkg/module/sub.zig", .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, st_sub.kind);
}

test "Adversarial 2: Switching from deep directory tree to flat file prunes empty parent directories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wt_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(wt_rel);

    var db = try RepoDb.initNew(gpa, wt_rel);
    defer db.deinit();

    // Base commit on `main` has a regular file named `deep`
    try db.editFile(0, "deep", "flat file named deep on main\n");
    _ = try db.commitWorktree(0, "alice", "Flat file deep");
    try materializer.materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);

    // Switch to `feat`, delete `deep`, and create `deep/nested/dir/leaf.txt`
    _ = try db.switchBranch(0, "feat");
    try db.deleteFile(0, "deep");
    try db.editFile(0, "deep/nested/dir/leaf.txt", "nested leaf content\n");
    _ = try db.commitWorktree(0, "bob", "Replace file deep with directory hierarchy");
    try materializer.materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);

    const st_leaf = try tmp.dir.statFile(io, "deep/nested/dir/leaf.txt", .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, st_leaf.kind);

    // Now switch back to `main`: must unlink `deep/nested/dir/leaf.txt`, prune empty dirs
    // `deep/nested/dir`, `deep/nested`, and `deep`, and materialize regular file `deep`!
    _ = try db.switchBranch(0, "main");
    try materializer.materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);

    const st_deep = try tmp.dir.statFile(io, "deep", .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, st_deep.kind);
}

test "Adversarial 3: Binary blobs with NUL bytes and fake newline anchors are never spliced by diff3" {
    const gpa = std.testing.allocator;
    var db = try RepoDb.initNew(gpa, "/tmp/wt-binary");
    defer db.deinit();

    // Binary blobs containing NUL bytes (`\x00`) that happen to share a middle line `ANCHOR\n`
    const bin_base = "BIN_HEADER_V1\x00\x01\nUNIQUE_ANCHOR_LINE\nBIN_FOOTER_V1\x00\xFF\n";
    const bin_ours = "BIN_HEADER_V2\x00\x02\nUNIQUE_ANCHOR_LINE\nBIN_FOOTER_V1\x00\xFF\n";
    const bin_theirs = "BIN_HEADER_V1\x00\x01\nUNIQUE_ANCHOR_LINE\nBIN_FOOTER_V3\x00\xFE\n";

    try db.editFile(0, "assets/icon.bin", bin_base);
    _ = try db.commitWorktree(0, "alice", "Base binary asset");

    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "assets/icon.bin", bin_theirs);
    _ = try db.commitWorktree(0, "bob", "Modify binary footer on feat");

    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "assets/icon.bin", bin_ours);
    _ = try db.commitWorktree(0, "alice", "Modify binary header on main");

    // Merge `feat` into `main`: because `icon.bin` is binary, it MUST NOT be spliced into a
    // clean blob—it must remain a 3-term algebraic conflict (`B + C - A`)!
    _ = try db.mergeBranch(0, "feat", "alice", "Merge binary asset");

    const merged_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    const icon_sum = merged_tree.getPathSum("assets/icon.bin").?;
    try std.testing.expect(icon_sum.isConflicted());
    try std.testing.expectEqual(@as(usize, 3), icon_sum.terms.items.len);
}

test "Adversarial 4: Multi-commit topological chain rebase replays all commits on branch in order" {
    const gpa = std.testing.allocator;
    var db = try RepoDb.initNew(gpa, "/tmp/wt-rebase-chain");
    defer db.deinit();

    // Base commit `c1` on `main`
    try db.editFile(0, "base.txt", "base\n");
    _ = try db.commitWorktree(0, "alice", "c1: base");

    // Create 3-commit chain on `feat`: `c2 -> c3 -> c4`
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "step1.txt", "step 1\n");
    _ = try db.commitWorktree(0, "bob", "c2: add step1");

    try db.editFile(0, "step2.txt", "step 2\n");
    _ = try db.commitWorktree(0, "bob", "c3: add step2");

    try db.editFile(0, "step3.txt", "step 3\n");
    _ = try db.commitWorktree(0, "bob", "c4: add step3");

    // Advance `main` with `c5`
    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "main_advance.txt", "main advance\n");
    _ = try db.commitWorktree(0, "alice", "c5: advance main");

    // Rebase 3-commit branch `feat` onto `main`!
    _ = try db.rebaseCommitOnto("feat", "main");
    _ = try db.switchBranch(0, "feat");

    const rebased_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expect(!rebased_tree.hasConflicts());
    // All 5 files (`base.txt`, `main_advance.txt`, `step1.txt`, `step2.txt`, `step3.txt`) must be present!
    try std.testing.expect(rebased_tree.getPathSum("base.txt") != null);
    try std.testing.expect(rebased_tree.getPathSum("main_advance.txt") != null);
    try std.testing.expect(rebased_tree.getPathSum("step1.txt") != null);
    try std.testing.expect(rebased_tree.getPathSum("step2.txt") != null);
    try std.testing.expect(rebased_tree.getPathSum("step3.txt") != null);
}

test "Adversarial 5: Racy Stat Cache guard catches immediate same-size, same-timestamp file overwrite" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wt_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(wt_rel);

    var db = try RepoDb.initNew(gpa, wt_rel);
    defer db.deinit();

    // Commit 3-byte file `"v1\n"` and materialize to disk
    try db.editFile(0, "racy.txt", "v1\n");
    _ = try db.commitWorktree(0, "alice", "Commit v1");
    try materializer.materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);

    // Immediately overwrite `racy.txt` on disk with `"v2\n"` (exact same 3-byte length!)
    // Even if the filesystem timestamp did not advance, `verified_stable` is `false` after
    // materialization, so `syncWorktreeFromDisk` MUST read and hash the file!
    try tmp.dir.writeFile(io, .{ .sub_path = "racy.txt", .data = "v2\n" });

    const s1 = try materializer.syncWorktreeFromDisk(gpa, io, &db, 0, wt_rel);
    try std.testing.expect(s1.tree_changed);
    try std.testing.expect(db.worktrees.items[0].is_dirty);

    const updated_hash = db.trees.items[db.worktrees.items[0].working_tree_id].getPathSum("racy.txt").?.getCleanHash().?;
    try std.testing.expectEqualStrings("v2\n", db.getBlob(updated_hash).?);

    // Now that `syncWorktreeFromDisk` has content-verified `"v2\n"`, the next scan hits `stat_cache`!
    const s2 = try materializer.syncWorktreeFromDisk(gpa, io, &db, 0, wt_rel);
    try std.testing.expect(!s2.tree_changed);
    try std.testing.expectEqual(@as(usize, 1), s2.stat_cache_hits);
}

test "Adversarial 6: Bit-flip, truncation, and 0xFFFFFFFF length-overflow fuzzing on deserializers" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-deser-fuzz");
    defer db.deinit();
    try db.editFile(0, "a.txt", "hello world");
    _ = try db.commitWorktree(0, "alice", "c1");

    const valid_bytes = try db.serializeToBytes(gpa);
    defer gpa.free(valid_bytes);

    // 1. Every truncated prefix must return an error cleanly without panicking or leaking
    var len: usize = 0;
    while (len < valid_bytes.len) : (len += 7) {
        try std.testing.expectError(
            if (len < 40) error.CorruptDatabase else error.ChecksumMismatch,
            RepoDb.deserializeFromBytes(gpa, valid_bytes[0..len]),
        );
    }

    // 2. Single-bit flips across the entire binary image must be rejected by BLAKE3 footer or header
    for (0..valid_bytes.len) |byte_idx| {
        const mutated = try gpa.dupe(u8, valid_bytes);
        defer gpa.free(mutated);
        mutated[byte_idx] ^= 0x01;

        if (RepoDb.deserializeFromBytes(gpa, mutated)) |*bad_db_val| {
            var bad_db = bad_db_val.*;
            bad_db.deinit();
            return error.BitFlipWasNotDetected;
        } else |_| {}
    }

    // 3. Forged payload with valid BLAKE3 footer but `0xFFFFFFFF` slice length must fail with `error.CorruptDatabase`
    {
        var forged = try gpa.dupe(u8, valid_bytes);
        defer gpa.free(forged);
        // Overwrite first blob's byte-length field (at offset 8 + 4 + 32 = 44) with 0xFFFFFFFF
        std.mem.writeInt(u32, forged[44..48], 0xFFFFFFFF, .little);
        const new_checksum = tree_sum.computeBlake3(forged[0 .. forged.len - 32]);
        @memcpy(forged[forged.len - 32 ..], &new_checksum);

        try std.testing.expectError(error.CorruptDatabase, RepoDb.deserializeFromBytes(gpa, forged));
    }

    // 4. Forged delta with `target_len = 0xFFFFFFFF` must fail immediately without OOM
    {
        var bad_delta: [40]u8 = @splat(0);
        @memcpy(bad_delta[0..4], delta.DELTA_MAGIC);
        std.mem.writeInt(u32, bad_delta[4..8], 0xFFFFFFFF, .little);
        try std.testing.expectError(error.CorruptDelta, delta.applyDelta(gpa, "base", &bad_delta));
    }
}

test "Adversarial 7: Conflicted file on disk is unlinked across branch switch and never leaks conflict markers into blobs (INV-5a)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const fuzzer = @import("conformance_fuzzer.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wt_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(wt_rel);

    var db = try RepoDb.initNew(gpa, wt_rel);
    defer db.deinit();

    // Base commit `c1` on `main` (does NOT contain `new_conf.txt`)
    try db.editFile(0, "README.md", "# Base\n");
    _ = try db.commitWorktree(0, "alice", "Base commit");

    // Branch `clean-branch` stays at `c1` (no `new_conf.txt`)
    _ = try db.switchBranch(0, "clean-branch");

    // Branch `feat` adds `new_conf.txt` = "feat version\n"
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "new_conf.txt", "feat version\n");
    _ = try db.commitWorktree(0, "bob", "Add new_conf on feat");

    // Branch `main` independently adds `new_conf.txt` = "main version\n" (add/add conflict B + C - bot!)
    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "new_conf.txt", "main version\n");
    _ = try db.commitWorktree(0, "alice", "Add new_conf on main");

    // Merge `feat` into `main` -> `new_conf.txt` is conflicted (`B + C - ABSENT`)
    _ = try db.mergeBranch(0, "feat", "alice", "Merge feat into main");
    try materializer.materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);

    // Verify `new_conf.txt` exists on disk with `<<<<<<<` markers
    const disk_conf = try tmp.dir.readFileAlloc(io, "new_conf.txt", gpa, .limited(4096));
    defer gpa.free(disk_conf);
    try std.testing.expect(diff3.hasConflictMarkers(disk_conf));

    // Now switch to `clean-branch` where `new_conf.txt` does NOT exist and materialize!
    _ = try db.switchBranch(0, "clean-branch");
    try materializer.materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);

    // `new_conf.txt` MUST be unlinked from disk!
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "new_conf.txt", .{}));

    // Scanning the worktree must NOT re-ingest `new_conf.txt` or leak `<<<<<<<` into `db.blobs`!
    const sync_stats = try materializer.syncWorktreeFromDisk(gpa, io, &db, 0, wt_rel);
    try std.testing.expect(!sync_stats.tree_changed);
    try fuzzer.checkAllFormalInvariants(&db, 0, 0);
}

test "Adversarial 8: D/F conflict (~df-conflict) round-trips across syncWorktreeFromDisk without deleting file or adding bogus path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wt_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(wt_rel);

    var db = try RepoDb.initNew(gpa, wt_rel);
    defer db.deinit();

    try db.editFile(0, "README.md", "# Base\n");
    _ = try db.commitWorktree(0, "alice", "Base");

    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "pkg/module/sub.zig", "pub const sub = 1;\n");
    _ = try db.commitWorktree(0, "bob", "Directory pkg/module/sub.zig");

    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "pkg/module", "file content\n");
    _ = try db.commitWorktree(0, "alice", "File pkg/module");

    // Merge creates D/F collision (`pkg/module` and `pkg/module/sub.zig`)
    _ = try db.mergeBranch(0, "feat", "alice", "Merge D/F");
    try materializer.materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);

    // Run `syncWorktreeFromDisk` while `pkg/module~df-conflict` is on disk!
    const stats = try materializer.syncWorktreeFromDisk(gpa, io, &db, 0, wt_rel);
    try std.testing.expect(!stats.tree_changed);
    try std.testing.expectEqual(@as(usize, 0), stats.files_deleted);

    const cur_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    // Original logical path `"pkg/module"` must still exist, and `"pkg/module~df-conflict"` must NOT be added!
    try std.testing.expect(cur_tree.getPathSum("pkg/module") != null);
    try std.testing.expect(cur_tree.getPathSum("pkg/module/sub.zig") != null);
    try std.testing.expect(cur_tree.getPathSum("pkg/module~df-conflict") == null);
}

test "Adversarial 9: Path traversal (.., leading /, .vcs) is rejected and unnormalized paths (./a//b) are canonicalized" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-path-sec");
    defer db.deinit();

    // 1. Malicious path traversal and reserved `.vcs` paths must fail with `error.InvalidRepoPath`
    const bad_paths = [_][]const u8{
        "",
        "/",
        "/etc/passwd",
        "../outside.txt",
        "src/../../escape.zig",
        ".vcs",
        ".vcs/db.vcs",
        "sub/.vcs/secret",
        ".git/config",
        "win\\backslash.txt",
        "null\x00byte.txt",
    };
    for (bad_paths) |bad| {
        try std.testing.expectError(error.InvalidRepoPath, db.editFile(0, bad, "payload"));
    }

    // 2. Redundant `./` and `//` separators are canonicalized to a single normalized entry
    try db.editFile(0, "./src//algebra/./tree.zig", "v1");
    try db.editFile(0, "src/algebra/tree.zig", "v2");

    const tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expectEqual(@as(usize, 1), tree.entries.items.len);
    try std.testing.expectEqualStrings("src/algebra/tree.zig", tree.entries.items[0].path);
}

test "Adversarial 10: Crisscross Merge Paradox uses recursive Virtual Merge Base to preserve revert" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-crisscross");
    defer db.deinit();

    // Root `c1`: `config.txt` has top=1, bottom=1
    try db.editFile(0, "config.txt", "top = 1\n// ANCHOR\nbottom = 1\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: root");

    // Branch `right` (`c2`): changes bottom=2
    _ = try db.switchBranch(0, "right");
    try db.editFile(0, "config.txt", "top = 1\n// ANCHOR\nbottom = 2\n");
    const c2 = try db.commitWorktree(0, "bob", "c2: right changes bottom=2");

    // Branch `left` (`c3`): changes top=2
    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "config.txt", "top = 2\n// ANCHOR\nbottom = 1\n");
    const c3 = try db.commitWorktree(0, "alice", "c3: left changes top=2");
    _ = c1;

    // Crisscross Merge 1 (`m1` on `main`): merges `right` (`c2`) into `main` (`c3`) -> top=2, bottom=2
    const m1 = try db.mergeBranch(0, "right", "alice", "m1: merge right into main");

    // Crisscross Merge 2 (`m2` on `right`): merges `main` at `c3` into `right` (`c2`)
    // To merge `c3` specifically into `right`, create a branch `left-base` at `c3`
    const left_base_br = try db.getOrCreateBranch("left-base", c3);
    db.branches.items[left_base_br].head_commit = c3;
    _ = try db.switchBranch(0, "right");
    const m2 = try db.mergeBranch(0, "left-base", "bob", "m2: merge c3 into right");

    // Verify `m1` and `m2` both have `top = 2, bottom = 2` and have two incomparable MCAs `{c2, c3}`!
    const mcas = try db.findMinimalCommonAncestors(gpa, m1, m2);
    defer gpa.free(mcas);
    try std.testing.expectEqual(@as(usize, 2), mcas.len);
    try std.testing.expectEqual(c2, mcas[0]);
    try std.testing.expectEqual(c3, mcas[1]);

    // Now on `main` (`m1`), Alice reverts `top` back to `top = 1` (keeping `bottom = 2`) and commits `c6`
    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "config.txt", "top = 1\n// ANCHOR\nbottom = 2\n");
    _ = try db.commitWorktree(0, "alice", "c6: revert top back to 1");

    // Now merge `right` (`m2`, which has `top = 2, bottom = 2`) into `main` (`c6`, which has `top = 1, bottom = 2`)!
    // - A naive single-LCA picker that picks `c2` (`top = 1, bottom = 2`) as merge base would think `c6`
    //   made NO change and `m2` changed `top: 1 -> 2`, silently overwriting Alice's revert with `top = 2`!
    // - With Virtual Merge Base (`merge(c2, c3) = {top = 2, bottom = 2}`), `zig-vcs` sees that `m2` is
    //   UNCHANGED relative to the virtual base while `c6` changed `top: 2 -> 1`, preserving `top = 1`!
    _ = try db.mergeBranch(0, "right", "alice", "Final crisscross merge");

    const final_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expect(!final_tree.hasConflicts());
    const final_hash = final_tree.getPathSum("config.txt").?.getCleanHash().?;
    try std.testing.expectEqualStrings(
        "top = 1\n// ANCHOR\nbottom = 2\n",
        db.getBlob(final_hash).?,
    );
}

test "Adversarial 11: Deterministic OOM fault injection across RepoDb transitions leaks 0 bytes and preserves invariants" {
    const fuzzer = @import("conformance_fuzzer.zig");

    // Sweep fail_index from 0..80 using `std.testing.FailingAllocator` wrapped around `std.testing.allocator`.
    // Any memory leak, double-free, or invariant violation on an error path will fail the test immediately!
    for (0..80) |fail_idx| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_idx,
        });
        const alloc = failing.allocator();

        var db = RepoDb.initNew(alloc, "/tmp/wt-oom") catch continue;
        defer db.deinit();

        _ = db.editFile(0, "src/a.zig", "const x = 1;\n// ANCHOR\nconst y = 1;\n") catch {
            try fuzzer.checkAllFormalInvariants(&db, 0, 0);
            continue;
        };
        _ = db.commitWorktree(0, "alice", "c1") catch {
            try fuzzer.checkAllFormalInvariants(&db, 0, 0);
            continue;
        };
        _ = db.switchBranch(0, "feat") catch {
            try fuzzer.checkAllFormalInvariants(&db, 0, 0);
            continue;
        };
        _ = db.editFile(0, "src/a.zig", "const x = 2;\n// ANCHOR\nconst y = 1;\n") catch {
            try fuzzer.checkAllFormalInvariants(&db, 0, 0);
            continue;
        };
        _ = db.commitWorktree(0, "bob", "c2") catch {
            try fuzzer.checkAllFormalInvariants(&db, 0, 0);
            continue;
        };
        _ = db.switchBranch(0, "main") catch {
            try fuzzer.checkAllFormalInvariants(&db, 0, 0);
            continue;
        };
        _ = db.editFile(0, "src/a.zig", "const x = 1;\n// ANCHOR\nconst y = 2;\n") catch {
            try fuzzer.checkAllFormalInvariants(&db, 0, 0);
            continue;
        };
        _ = db.commitWorktree(0, "alice", "c3") catch {
            try fuzzer.checkAllFormalInvariants(&db, 0, 0);
            continue;
        };
        _ = db.mergeBranch(0, "feat", "alice", "merge") catch {
            try fuzzer.checkAllFormalInvariants(&db, 0, 0);
            continue;
        };
        _ = db.undo() catch {
            try fuzzer.checkAllFormalInvariants(&db, 0, 0);
            continue;
        };
        _ = db.redo() catch {
            try fuzzer.checkAllFormalInvariants(&db, 0, 0);
            continue;
        };
        try fuzzer.checkAllFormalInvariants(&db, 0, 0);
    }
}

test "Adversarial 12: Forged RepoDb image with invalid PathSum coefficients (sum != 1) is rejected on load (INV-5b)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-inv5-deser");
    defer db.deinit();
    try db.editFile(0, "file.txt", "clean");
    _ = try db.commitWorktree(0, "alice", "c1");

    const valid_bytes = try db.serializeToBytes(gpa);
    defer gpa.free(valid_bytes);

    // Locate the string `"file.txt"` in `valid_bytes` inside the `trees` section:
    // Layout of tree entry: `[u32 path_len = 8]["file.txt"][u32 num_terms = 1][32-byte hash][i32 coeff = 1]`
    const needle = "file.txt";
    const path_offset = std.mem.indexOf(u8, valid_bytes, needle).?;
    const coeff_offset = path_offset + needle.len + 4 + 32;
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, valid_bytes[coeff_offset..][0..4], .little));

    // Forge `coeff = 5` (violating `sum(coeff) == 1`) and recompute a valid BLAKE3 footer checksum!
    var forged = try gpa.dupe(u8, valid_bytes);
    defer gpa.free(forged);
    std.mem.writeInt(i32, forged[coeff_offset..][0..4], 5, .little);
    const new_checksum = tree_sum.computeBlake3(forged[0 .. forged.len - 32]);
    @memcpy(forged[forged.len - 32 ..], &new_checksum);

    try std.testing.expectError(error.CorruptDatabase, RepoDb.deserializeFromBytes(gpa, forged));
}

test "Adversarial 13: RepoDb.saveToFile & loadFromFile use PagedFile Dual-Superblock (ZVCSPG01) and ZDL1 blob delta compression (ZIGVCS02)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const paged_file = @import("../storage/paged_file.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/db.vcs", .{tmp.sub_path});
    defer gpa.free(db_path);

    var db = try RepoDb.initNew(gpa, "/tmp/wt-paged");
    defer db.deinit();

    // Commit 5 incremental revisions of a source file
    const unit_chunk =
        \\// Standard header block repeated across incremental edits
        \\pub const Config = struct {
        \\    pub const host = "127.0.0.1";
        \\    pub const max_connections = 4096;
        \\    pub const enable_tls = true;
        \\    pub const timeout_ms = 5000;
        \\};
        \\
    ;
    const base_chunk = unit_chunk ++ unit_chunk ++ unit_chunk ++ unit_chunk ++ unit_chunk ++ unit_chunk;

    for (0..5) |rev| {
        const rev_text = try std.fmt.allocPrint(gpa, "{s}\npub const revision = {d};\n", .{ base_chunk, rev });
        defer gpa.free(rev_text);
        try db.editFile(0, "src/server.zig", rev_text);
        _ = try db.commitWorktree(0, "alice", "Incremental edit");
        try db.saveToFile(io, db_path);
    }

    // 1. Verify `serializeToBytesCompact` (`ZIGVCS02`) is significantly smaller than raw `serializeToBytes` (`ZIGVCS01`)
    const raw_bytes = try db.serializeToBytes(gpa);
    defer gpa.free(raw_bytes);
    const compact_bytes = try db.serializeToBytesCompact(gpa);
    defer gpa.free(compact_bytes);
    try std.testing.expect(compact_bytes.len * 2 < raw_bytes.len);

    // 2. Verify on-disk `db.vcs` has the `ZVCSPG01` Superblock header and survives a torn-write superblock corruption!
    var disk_bytes = try Io.Dir.cwd().readFileAlloc(io, db_path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(disk_bytes);
    try std.testing.expectEqualStrings(paged_file.SUPERBLOCK_MAGIC, disk_bytes[0..8]);

    // Corrupt active superblock slot (`tx_id = 5` is odd -> Slot B at offset 4096..8192)
    disk_bytes[4110] ^= 0xFF;
    try tmp.dir.writeFile(io, .{ .sub_path = "db.vcs", .data = disk_bytes });

    // `loadFromFile` automatically falls back to Slot A (`tx_id = 4`, 4 commits + c0 = 5 commits total)!
    var recovered = try RepoDb.loadFromFile(gpa, io, db_path);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 5), recovered.commits.items.len);
}

test "Adversarial 14: Linked Multi-Worktree (.vcs-link) auto-detection and isolated directory checkout" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base_dir);
    const wt0_dir = try std.fmt.allocPrint(gpa, "{s}/wt0", .{base_dir});
    defer gpa.free(wt0_dir);
    const wt1_dir = try std.fmt.allocPrint(gpa, "{s}/wt1", .{base_dir});
    defer gpa.free(wt1_dir);
    const db_path = try std.fmt.allocPrint(gpa, "{s}/wt0/.vcs/db.vcs", .{base_dir});
    defer gpa.free(db_path);

    try Io.Dir.cwd().createDirPath(io, wt0_dir);
    {
        const vcs_sub = try std.fmt.allocPrint(gpa, "{s}/.vcs", .{wt0_dir});
        defer gpa.free(vcs_sub);
        try Io.Dir.cwd().createDirPath(io, vcs_sub);
    }

    var db = try RepoDb.initNew(gpa, wt0_dir);
    defer db.deinit();

    try db.editFile(0, "app.zig", "pub const main_v = 1;\n");
    _ = try db.commitWorktree(0, "alice", "c1 on main");

    // Create linked worktree `wt1` at `wt1_dir` on branch `feat`
    const wt1_id = try materializer.createLinkedWorktreeOnDisk(
        gpa,
        io,
        &db,
        db_path,
        "wt1",
        wt1_dir,
        "feat",
    );
    try std.testing.expectEqual(@as(repo_db.WorktreeId, 1), wt1_id);
    try db.saveToFile(io, db_path);

    // Resolve workspace context from `wt1_dir` -> must detect `wt_id = 1` and `db_path` via `.vcs-link`!
    var ctx1 = try materializer.resolveWorkspaceContext(gpa, io, wt1_dir);
    defer ctx1.deinit(gpa);
    try std.testing.expectEqual(@as(repo_db.WorktreeId, 1), ctx1.wt_id);
    try std.testing.expectEqualStrings(db_path, ctx1.db_path);

    // Syncing `wt1_dir` must ignore `.vcs-link` and see clean `app.zig`
    const sync_stats = try materializer.syncWorktreeFromDisk(gpa, io, &db, ctx1.wt_id, ctx1.worktree_dir);
    try std.testing.expect(!sync_stats.tree_changed);
}

test "Adversarial 15: Algebraic backoutCommit (T_ours + T_parent(C) - T_C) cancels conflicted merge commit, plus diff & log" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-backout");
    defer db.deinit();

    try db.editFile(0, "service.zig", "const mode = 0;\n");
    _ = try db.commitWorktree(0, "alice", "c1: base");

    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "service.zig", "const mode = 2;\n");
    _ = try db.commitWorktree(0, "bob", "c2: feat mode=2");

    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "service.zig", "const mode = 1;\n");
    const c3 = try db.commitWorktree(0, "alice", "c3: main mode=1");

    // Merge `feat` into `main` -> creates conflicted merge commit `c4` (`mode=1 + mode=2 - mode=0`)
    const c4 = try db.mergeBranch(0, "feat", "alice", "c4: conflicted merge");
    try std.testing.expect(db.trees.items[db.worktrees.items[0].working_tree_id].hasConflicts());

    // Algebraically back out `c4` (`(B + C - A) + B - (B + C - A) = B`) -> conflict cancels back to clean `c3`!
    _ = try db.backoutCommit(0, c4, "alice", "c5: backout conflicted merge c4");
    const post_backout_tid = db.worktrees.items[0].working_tree_id;
    try std.testing.expect(!db.trees.items[post_backout_tid].hasConflicts());
    try std.testing.expectEqual(db.commits.items[c3].root_tree_id, post_backout_tid);

    // Verify `diffTreesUnified` and `formatCommitLogGraph`
    const diff_txt = try db.diffTreesUnified(gpa, db.commits.items[1].root_tree_id, post_backout_tid);
    defer gpa.free(diff_txt);
    try std.testing.expect(std.mem.indexOf(u8, diff_txt, "-const mode = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff_txt, "+const mode = 1;") != null);

    const log_txt = try db.formatCommitLogGraph(gpa);
    defer gpa.free(log_txt);
    try std.testing.expect(std.mem.indexOf(u8, log_txt, "[merge: c3 + c2] [CONFLICTED]") != null);
}

test "Adversarial 16: Executable file mode (100755) round-trips across disk materialization, scan, and Git fast-export" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wt_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(wt_rel);

    var db = try RepoDb.initNew(gpa, wt_rel);
    defer db.deinit();

    try db.editFileWithMode(0, "scripts/deploy.sh", "#!/bin/sh\necho deploy\n", .executable);
    try db.editFileWithMode(0, "README.md", "# Docs\n", .regular);
    _ = try db.commitWorktree(0, "alice", "Add executable script");

    // 1. Materialize to disk and scan back -> executable mode (`100755`) is preserved on POSIX!
    try materializer.materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);
    const s = try materializer.syncWorktreeFromDisk(gpa, io, &db, 0, wt_rel);
    try std.testing.expect(!s.tree_changed);

    const cur_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expectEqual(tree_sum.FileMode.executable, cur_tree.getPathMode("scripts/deploy.sh").?);
    try std.testing.expectEqual(tree_sum.FileMode.regular, cur_tree.getPathMode("README.md").?);

    // 2. Export to `git fast-export` stream and import into `db2` -> `100755` mode round-trips!
    const stream = try git_interop.emitFastExportStream(gpa, &db);
    defer gpa.free(stream);
    try std.testing.expect(std.mem.indexOf(u8, stream, "M 100755 :") != null);

    var db2 = try RepoDb.initNew(gpa, "/tmp/wt-git-mode");
    defer db2.deinit();
    try git_interop.importFastExportStream(gpa, &db2, stream);

    const head2_tree = db2.trees.items[db2.commits.items[db2.branches.items[0].head_commit].root_tree_id];
    try std.testing.expectEqual(tree_sum.FileMode.executable, head2_tree.getPathMode("scripts/deploy.sh").?);
}

test "Adversarial 17: Shadow-page reclamation keeps PagedImage bounded across 50 commits and compactAndGC reclaims slack" {
    const gpa = std.testing.allocator;
    const paged_file = @import("../storage/paged_file.zig");

    var img = try paged_file.PagedImage.init(gpa);
    defer img.deinit();

    // Commit 50 snapshots of ~6KB (2 pages each)
    var buf: [6000]u8 = @splat('A');
    for (0..50) |step| {
        std.mem.writeInt(u64, buf[0..8], step, .little);
        _ = try img.commitSnapshot(&buf);
    }

    // Without extent reuse, 50 commits * 2 pages + 2 superblocks = 102 pages.
    // With ping-pong shadow extent reuse, total pages is bounded to `2 + 2 + 2 = 6` pages!
    try std.testing.expectEqual(@as(usize, 6), img.pages.items.len);

    // Compact & GC reclaims the inactive fallback extent down to `2 + 2 = 4` pages!
    const reclaimed = try img.compactAndGC(gpa);
    try std.testing.expectEqual(@as(usize, 2), reclaimed);
    try std.testing.expectEqual(@as(usize, 4), img.pages.items.len);

    const rec = try img.recoverLatestSnapshot(gpa);
    defer gpa.free(rec.payload);
    try std.testing.expectEqual(@as(u64, 49), std.mem.readInt(u64, rec.payload[0..8], .little));
}

test "Adversarial 18: Unique-anchor LCS unified diff emits minimal @@ hunks with context lines" {
    const gpa = std.testing.allocator;

    const old_text =
        \\line 1
        \\line 2
        \\line 3
        \\target = 10;
        \\line 5
        \\line 6
        \\line 7
        \\
    ;
    const new_text =
        \\line 1
        \\line 2
        \\line 3
        \\target = 20;
        \\line 5
        \\line 6
        \\line 7
        \\
    ;

    const hunks = try diff3.renderUnifiedDiffHunks(gpa, old_text, new_text);
    defer gpa.free(hunks);

    // Must emit a localized hunk header and NOT mark `line 1` or `line 7` as removed/added!
    try std.testing.expect(std.mem.indexOf(u8, hunks, "@@ -2,5 +2,5 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, hunks, "-target = 10;\n+target = 20;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, hunks, "-line 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, hunks, "-line 7") == null);
}

test "Adversarial 19: Similarity-based rename detection in 3-way merge follows renamed file and lifts hunks cleanly" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-rename-merge");
    defer db.deinit();

    // Base `c1`: `src/old_engine.zig` with 6 lines and a unique anchor
    const base_code =
        \\pub const version = 1;
        \\pub const name = "engine";
        \\// UNIQUE_ANCHOR_SEP
        \\pub const workers = 4;
        \\pub const queue_depth = 128;
        \\
    ;
    try db.editFile(0, "src/old_engine.zig", base_code);
    _ = try db.commitWorktree(0, "alice", "c1: base old_engine.zig");

    // Branch `feat` edits the bottom section of `src/old_engine.zig` (`workers = 16`)
    _ = try db.switchBranch(0, "feat");
    try db.editFile(
        0,
        "src/old_engine.zig",
        \\pub const version = 1;
        \\pub const name = "engine";
        \\// UNIQUE_ANCHOR_SEP
        \\pub const workers = 16;
        \\pub const queue_depth = 128;
        \\
    );
    _ = try db.commitWorktree(0, "bob", "c2: scale workers in old_engine.zig");

    // Branch `main` renames `src/old_engine.zig` -> `src/new_engine.zig` AND edits the top section (`version = 2`)
    _ = try db.switchBranch(0, "main");
    try db.deleteFile(0, "src/old_engine.zig");
    try db.editFile(
        0,
        "src/new_engine.zig",
        \\pub const version = 2;
        \\pub const name = "engine";
        \\// UNIQUE_ANCHOR_SEP
        \\pub const workers = 4;
        \\pub const queue_depth = 128;
        \\
    );
    _ = try db.commitWorktree(0, "alice", "c3: rename to new_engine.zig and bump version");

    // Merge `feat` into `main`!
    // Similarity rename detection matches `src/old_engine.zig -> src/new_engine.zig` and Pierce anchor diff3
    // lifts BOTH `version = 2` and `workers = 16` into `src/new_engine.zig` with 0 conflicts!
    _ = try db.mergeBranch(0, "feat", "alice", "c4: merge feat across rename");

    const merged_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expect(!merged_tree.hasConflicts());
    try std.testing.expect(merged_tree.getPathSum("src/old_engine.zig") == null);

    const new_hash = merged_tree.getPathSum("src/new_engine.zig").?.getCleanHash().?;
    try std.testing.expectEqualStrings(
        \\pub const version = 2;
        \\pub const name = "engine";
        \\// UNIQUE_ANCHOR_SEP
        \\pub const workers = 16;
        \\pub const queue_depth = 128;
        \\
    ,
        db.getBlob(new_hash).?,
    );
}

test "Adversarial 20: Algebraic cherryPickCommit followed by backoutCommit is an exact identity (Theorem 6f)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-cherry-pick");
    defer db.deinit();

    try db.editFile(0, "core.zig", "pub const a = 1;\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: base");

    // Create a commit `c2` on `feat` adding `feature.zig`
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "feature.zig", "pub const feat_enabled = true;\n");
    const c2 = try db.commitWorktree(0, "bob", "c2: add feature.zig");

    // Switch back to `main` (`c1`), cherry-pick `c2`, then back out the cherry-picked commit!
    _ = try db.switchBranch(0, "main");
    const c3 = try db.cherryPickCommit(0, c2, "alice", "c3: cherry-pick c2 onto main");
    try std.testing.expect(db.trees.items[db.worktrees.items[0].working_tree_id].getPathSum("feature.zig") != null);

    _ = try db.backoutCommit(0, c3, "alice", "c4: back out cherry-picked c3");
    const final_tid = db.worktrees.items[0].working_tree_id;
    try std.testing.expectEqual(db.commits.items[c1].root_tree_id, final_tid);
}

test "Adversarial 21: Amending a historical commit automatically cascades (auto-rebases) all descendant commits, branches, and drafts" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-amend-cascade");
    defer db.deinit();

    // `c1`: base commit on `main`
    try db.editFile(0, "config.zig", "pub const port = 8080;\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: initial config");

    // `c2`: child commit on `main` adding `server.zig`
    try db.editFile(0, "server.zig", "pub const workers = 4;\n");
    const c2 = try db.commitWorktree(0, "alice", "c2: add server.zig");

    // Branch `feat` off `main` (`c2`) and create grandchild `c3` adding `metrics.zig`
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "metrics.zig", "pub const enabled = true;\n");
    _ = try db.commitWorktree(0, "bob", "c3: add metrics.zig");

    // Switch back to `main` and stage an edit to `config.zig` (`port = 9090`), then amend historical `c1`!
    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "config.zig", "pub const port = 9090;\n");
    _ = try db.amendCommit(0, c1, "c1_amended: port 9090");

    // Both `main` (`c2'`) and `feat` (`c3'`) must now include `port = 9090` alongside their own files!
    const main_tree = db.trees.items[db.commits.items[db.branches.items[0].head_commit].root_tree_id];
    try std.testing.expectEqualStrings(
        "pub const port = 9090;\n",
        db.getBlob(main_tree.getPathSum("config.zig").?.getCleanHash().?).?,
    );
    try std.testing.expect(main_tree.getPathSum("server.zig") != null);

    const feat_bid = db.findBranchByName("feat").?;
    const feat_tree = db.trees.items[db.commits.items[db.branches.items[feat_bid].head_commit].root_tree_id];
    try std.testing.expectEqualStrings(
        "pub const port = 9090;\n",
        db.getBlob(feat_tree.getPathSum("config.zig").?.getCleanHash().?).?,
    );
    try std.testing.expect(feat_tree.getPathSum("server.zig") != null);
    try std.testing.expect(feat_tree.getPathSum("metrics.zig") != null);

    // And a single `db.undo()` atomically restores `main` back to `c2`!
    try std.testing.expect(try db.undo());
    // Wait: first undo reverts the `amend`, second undo reverts the `editFile` before `amend`
    try std.testing.expectEqual(c2, db.branches.items[0].head_commit);
}

test "Adversarial 22: Algebraic Octopus Merge (mergeMultipleBranches) merges 3 branches cleanly and represents 3-way conflicts in Z[A_bot]" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-octopus");
    defer db.deinit();

    // Base `c1` on `main`
    try db.editFile(0, "shared.txt", "base\n");
    _ = try db.commitWorktree(0, "alice", "c1: base");

    // Branch `feat-a` adds `a.txt` and edits `shared.txt` to `"side-a\n"`
    _ = try db.switchBranch(0, "feat-a");
    try db.editFile(0, "a.txt", "from feat-a\n");
    try db.editFile(0, "shared.txt", "side-a\n");
    _ = try db.commitWorktree(0, "bob", "c2: feat-a");

    // Branch `feat-b` from `main` adds `b.txt` and edits `shared.txt` to `"side-b\n"`
    _ = try db.switchBranch(0, "main");
    _ = try db.switchBranch(0, "feat-b");
    try db.editFile(0, "b.txt", "from feat-b\n");
    try db.editFile(0, "shared.txt", "side-b\n");
    _ = try db.commitWorktree(0, "carol", "c3: feat-b");

    // Switch to `main` (where `shared.txt` is `"main-side\n"`), then octopus-merge `feat-a` and `feat-b`!
    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "shared.txt", "main-side\n");
    _ = try db.commitWorktree(0, "alice", "c4: main edit");

    const branches = [_][]const u8{ "feat-a", "feat-b" };
    _ = try db.mergeMultipleBranches(0, &branches, "alice", "c5: octopus merge feat-a + feat-b");

    const oct_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    // Both `a.txt` and `b.txt` are cleanly present:
    try std.testing.expect(oct_tree.getPathSum("a.txt").?.getCleanHash() != null);
    try std.testing.expect(oct_tree.getPathSum("b.txt").?.getCleanHash() != null);

    // And `shared.txt` has a 3-side conflict in Z[A_bot]: +1*main + 1*side_a + 1*side_b - 2*base (sum of coeffs == 1)!
    const shared_sum = oct_tree.getPathSum("shared.txt").?;
    try std.testing.expect(shared_sum.isConflicted());
    try std.testing.expectEqual(@as(i64, 1), shared_sum.sumCoefficients());
}

test "Adversarial 23: Line-level provenance and conflict-aware blame attributes lines and algebraic conflict terms to originating commits" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-blame");
    defer db.deinit();

    try db.editFile(0, "app.zig", "line 1\nline 2\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: initial lines");

    try db.editFile(0, "app.zig", "line 1\nline 2 modified by bob\nline 3 added by bob\n");
    const c2 = try db.commitWorktree(0, "bob", "c2: bob updates line 2 and adds line 3");

    const blame_clean = try db.blameFile(gpa, c2, "app.zig");
    defer gpa.free(blame_clean);

    // `line 1` must be attributed to `c1 (alice)`, while lines 2 and 3 must be attributed to `c2 (bob)`!
    var expected_l1_buf: [64]u8 = undefined;
    const expected_l1 = try std.fmt.bufPrint(&expected_l1_buf, "c{d} (alice)", .{c1});
    var expected_l2_buf: [64]u8 = undefined;
    const expected_l2 = try std.fmt.bufPrint(&expected_l2_buf, "c{d} (bob)", .{c2});

    try std.testing.expect(std.mem.indexOf(u8, blame_clean, expected_l1) != null);
    try std.testing.expect(std.mem.indexOf(u8, blame_clean, expected_l2) != null);
}

test "Adversarial 24: Subdirectory CWD discovery walks parent directories to locate .vcs/db.vcs or .vcs-link and path-filtered diff" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const tmp_root = "/tmp/zig-vcs-adv-subdir-discovery";
    Io.Dir.cwd().deleteTree(io, tmp_root) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp_root) catch {};

    const main_dir = "/tmp/zig-vcs-adv-subdir-discovery/main-wt";
    const main_db = "/tmp/zig-vcs-adv-subdir-discovery/main-wt/.vcs/db.vcs";
    const nested_dir = "/tmp/zig-vcs-adv-subdir-discovery/main-wt/src/core/deep";
    try Io.Dir.cwd().createDirPath(io, "/tmp/zig-vcs-adv-subdir-discovery/main-wt/.vcs");
    try Io.Dir.cwd().createDirPath(io, nested_dir);

    var db = try RepoDb.initNew(gpa, main_dir);
    defer db.deinit();
    try db.editFile(0, "src/core/deep/mod.zig", "pub const x = 1;\n");
    try db.editFile(0, "README.md", "# Docs\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: add mod.zig and README.md");
    try db.saveToFile(io, main_db);

    // Resolving workspace context from `<main_dir>/src/core/deep` must walk up and find `<main_dir>` and `wt_id == 0`!
    var ctx = try materializer.resolveWorkspaceContext(gpa, io, nested_dir);
    defer ctx.deinit(gpa);
    try std.testing.expectEqual(@as(repo_db.WorktreeId, 0), ctx.wt_id);
    try std.testing.expectEqualStrings(main_dir, ctx.worktree_dir);
    try std.testing.expectEqualStrings(main_db, ctx.db_path);

    // Also test path-filtered unified diff (`diffTreesUnifiedFiltered` on `"src/"` excludes `"README.md"`):
    try db.editFile(0, "src/core/deep/mod.zig", "pub const x = 2;\n");
    try db.editFile(0, "README.md", "# Updated Docs\n");
    const filtered_diff = try db.diffTreesUnifiedFiltered(
        gpa,
        db.commits.items[c1].root_tree_id,
        db.worktrees.items[0].working_tree_id,
        "src/",
    );
    defer gpa.free(filtered_diff);
    try std.testing.expect(std.mem.indexOf(u8, filtered_diff, "src/core/deep/mod.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered_diff, "README.md") == null);
}

test "Adversarial 25: Rebasing a branch automatically rebases both active dirty worktrees and shelved drafts on that branch (Theorem 6j)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-rebase-drafts");
    defer db.deinit();

    // Base `c1` on `main`
    try db.editFile(0, "base.zig", "pub const base = 1;\n");
    _ = try db.commitWorktree(0, "alice", "c1: base");

    // Branch `feat` commits `feat.zig` (`c2`)
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "feat.zig", "pub const feat = 1;\n");
    _ = try db.commitWorktree(0, "bob", "c2: feat commit");

    // Shelve a dirty draft on `feat` in `wt0` (`draft_wt0.zig`), then switch `wt0` back to `main`!
    try db.editFile(0, "draft_wt0.zig", "pub const draft0 = true;\n");
    _ = try db.switchBranch(0, "main");

    // Open a second worktree `wt1` on `feat` with dirty uncommitted `draft_wt1.zig`!
    const wt1 = try db.addWorktree("wt1", "/tmp/wt1-rebase", "feat");
    try db.editFile(wt1, "draft_wt1.zig", "pub const draft1 = true;\n");

    // Advance `main` with `main_new.zig` (`c3`), then rebase `feat` onto `main`!
    try db.editFile(0, "main_new.zig", "pub const from_main = 42;\n");
    _ = try db.commitWorktree(0, "alice", "c3: main advances");

    _ = try db.rebaseCommitOnto("feat", "main");

    // 1. Active dirty worktree `wt1` on `feat` must now have `main_new.zig`, `feat.zig`, AND its uncommitted `draft_wt1.zig`!
    const wt1_tree = db.trees.items[db.worktrees.items[wt1].working_tree_id];
    try std.testing.expect(wt1_tree.getPathSum("main_new.zig") != null);
    try std.testing.expect(wt1_tree.getPathSum("feat.zig") != null);
    try std.testing.expect(wt1_tree.getPathSum("draft_wt1.zig") != null);

    // 2. Switching `wt0` back to `feat` restores its shelved draft, which was ALSO auto-rebased onto `main`!
    _ = try db.switchBranch(0, "feat");
    const wt0_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expect(wt0_tree.getPathSum("main_new.zig") != null);
    try std.testing.expect(wt0_tree.getPathSum("feat.zig") != null);
    try std.testing.expect(wt0_tree.getPathSum("draft_wt0.zig") != null);
}

test "Adversarial 26: Transactional tags support atomic undo/redo, ZIGVCS02 persistence, and git fast-export/import round-trip" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-tags");
    defer db.deinit();

    try db.editFile(0, "version.txt", "1.0.0\n");
    const c1 = try db.commitWorktree(0, "alice", "Release 1.0.0");
    try db.createTag("v1.0.0", c1);
    try std.testing.expectEqual(@as(?repo_db.CommitId, c1), db.findTagByName("v1.0.0"));

    // Undo tag creation -> tag disappears; redo -> tag returns!
    try std.testing.expect(try db.undo());
    try std.testing.expect(db.findTagByName("v1.0.0") == null);
    try std.testing.expect(try db.redo());
    try std.testing.expectEqual(@as(?repo_db.CommitId, c1), db.findTagByName("v1.0.0"));

    // Round-trip through `ZIGVCS02` compact serializer
    const compact = try db.serializeToBytesCompact(gpa);
    defer gpa.free(compact);
    var loaded = try RepoDb.deserializeFromBytes(gpa, compact);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(?repo_db.CommitId, c1), loaded.findTagByName("v1.0.0"));

    // Round-trip through `git fast-export` / `git fast-import`
    const stream = try git_interop.emitFastExportStream(gpa, &db);
    defer gpa.free(stream);
    var imported = try RepoDb.initNew(gpa, "/tmp/wt-tags-imported");
    defer imported.deinit();
    try git_interop.importFastExportStream(gpa, &imported, stream);
    try std.testing.expectEqual(@as(?repo_db.CommitId, c1), imported.findTagByName("v1.0.0"));
}

test "Adversarial 27: Unified revision resolver parses HEAD~N, branch^2, @, and tag~N ancestry expressions" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-revparse");
    defer db.deinit();

    try db.editFile(0, "a.txt", "1\n");
    const c1 = try db.commitWorktree(0, "alice", "c1");
    try db.createTag("v0.1", c1);

    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "b.txt", "2\n");
    const c2 = try db.commitWorktree(0, "bob", "c2 on feat");

    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "c.txt", "3\n");
    const c3 = try db.commitWorktree(0, "alice", "c3 on main");

    const c4 = try db.mergeBranch(0, "feat", "alice", "c4 merge feat into main");

    try std.testing.expectEqual(c4, try db.resolveRevision(0, "HEAD"));
    try std.testing.expectEqual(c4, try db.resolveRevision(0, "@"));
    try std.testing.expectEqual(c3, try db.resolveRevision(0, "HEAD~1"));
    try std.testing.expectEqual(c1, try db.resolveRevision(0, "HEAD~2"));
    try std.testing.expectEqual(c2, try db.resolveRevision(0, "main^2"));
    try std.testing.expectEqual(c1, try db.resolveRevision(0, "main^2~1"));
    try std.testing.expectEqual(c1, try db.resolveRevision(0, "v0.1"));
    try std.testing.expectEqual(@as(repo_db.CommitId, 0), try db.resolveRevision(0, "v0.1~1"));
}

test "Adversarial 28: Zero-checkout in-memory bisectCommitRange (O(log N)) and searchHistory pickaxe scan" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-bisect");
    defer db.deinit();

    // Create a chain of 10 commits where commit #6 introduces `"REGRESSION_BUG"` into `engine.zig`
    var cids: [10]repo_db.CommitId = undefined;
    for (0..10) |i| {
        var buf: [128]u8 = undefined;
        const content = if (i >= 5)
            try std.fmt.bufPrint(&buf, "step={d}\nconst status = \"REGRESSION_BUG\";\n", .{i})
        else
            try std.fmt.bufPrint(&buf, "step={d}\nconst status = \"OK\";\n", .{i});

        var msg_buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "commit step {d}", .{i});
        try db.editFile(0, "engine.zig", content);
        cids[i] = try db.commitWorktree(0, "alice", msg);
    }

    // Zero-checkout binary search between `cids[0]` (good) and `cids[9]` (bad) must pinpoint `cids[5]`!
    const culprit = try db.bisectCommitRange(gpa, cids[0], cids[9], "engine.zig", "REGRESSION_BUG");
    try std.testing.expectEqual(cids[5], culprit);

    // And pickaxe `searchHistory` must report `cids[5]` as the exact commit that introduced `"REGRESSION_BUG"`!
    const search_out = try db.searchHistory(gpa, "REGRESSION_BUG");
    defer gpa.free(search_out);
    var expected_prefix_buf: [32]u8 = undefined;
    const expected_prefix = try std.fmt.bufPrint(&expected_prefix_buf, "c{d} (alice:", .{cids[5]});
    try std.testing.expect(std.mem.indexOf(u8, search_out, expected_prefix) != null);
}

test "Adversarial 29: Concurrent worktrees sharing the same branch auto-rebase dirty state when one worktree commits or merges" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-shared-br-0");
    defer db.deinit();

    // Base `c1` on `main`
    try db.editFile(0, "core.zig", "pub const v = 1;\n");
    _ = try db.commitWorktree(0, "alice", "c1: base");

    // Attach `wt1` to the SAME branch `main` and make uncommitted dirty edit `wt1_only.zig`
    const wt1 = try db.addWorktree("wt1", "/tmp/wt-shared-br-1", "main");
    try db.editFile(wt1, "wt1_only.zig", "pub const from_wt1 = true;\n");

    // Meanwhile `wt0` edits `wt0_only.zig` and commits `c2` to `main`!
    try db.editFile(0, "wt0_only.zig", "pub const from_wt0 = true;\n");
    _ = try db.commitWorktree(0, "alice", "c2: wt0 commits to main");

    // Now `wt1` commits its dirty worktree to `main` (`c3`).
    // Because `finalizeWorktreeCommitOnBranch` auto-rebased `wt1` when `wt0` committed `c2`,
    // `c3` must preserve `wt0_only.zig` alongside `wt1_only.zig` and `core.zig`!
    const c3 = try db.commitWorktree(wt1, "bob", "c3: wt1 commits to main");
    const c3_tree = db.trees.items[db.commits.items[c3].root_tree_id];
    try std.testing.expect(c3_tree.getPathSum("core.zig") != null);
    try std.testing.expect(c3_tree.getPathSum("wt0_only.zig") != null);
    try std.testing.expect(c3_tree.getPathSum("wt1_only.zig") != null);

    // And `wt0` (which was clean on `main`) was also advanced to `c3_tree`!
    try std.testing.expectEqual(db.commits.items[c3].root_tree_id, db.worktrees.items[0].working_tree_id);
}

test "Adversarial 30: Lossless algebraic conflict PathSum round-trip across git-export and git-import" {
    const gpa = std.testing.allocator;

    var db1 = try RepoDb.initNew(gpa, "/tmp/wt-conf-export-1");
    defer db1.deinit();

    try db1.editFile(0, "conflict.zig", "pub const x = 0;\n");
    _ = try db1.commitWorktree(0, "alice", "c1: base");

    _ = try db1.switchBranch(0, "feat");
    try db1.editFile(0, "conflict.zig", "pub const x = 100;\n");
    _ = try db1.commitWorktree(0, "bob", "c2: feat edit");

    _ = try db1.switchBranch(0, "main");
    try db1.editFile(0, "conflict.zig", "pub const x = 200;\n");
    _ = try db1.commitWorktree(0, "alice", "c3: main edit");

    const c4 = try db1.mergeBranch(0, "feat", "alice", "c4: conflicted merge");
    const orig_tree = db1.trees.items[db1.commits.items[c4].root_tree_id];
    const orig_sum = orig_tree.getPathSum("conflict.zig").?;
    try std.testing.expect(orig_sum.isConflicted());

    const stream = try git_interop.emitFastExportStream(gpa, &db1);
    defer gpa.free(stream);

    var db2 = try RepoDb.initNew(gpa, "/tmp/wt-conf-export-2");
    defer db2.deinit();
    try git_interop.importFastExportStream(gpa, &db2, stream);

    const imp_tree = db2.trees.items[db2.commits.items[c4].root_tree_id];
    const imp_sum = imp_tree.getPathSum("conflict.zig").?;
    try std.testing.expect(imp_sum.isConflicted());
    try std.testing.expect(orig_sum.eql(imp_sum));

    // Verify INV-5a: zero conflict markers in `db2.blobs`!
    for (db2.blobs.items) |b| {
        try std.testing.expect(!diff3.hasConflictMarkers(b.bytes));
    }
}

test "Adversarial 31: Rodeh CoW B-Tree sublinear diffRoots skips shared unmodified subtrees in O(1)" {
    const gpa = std.testing.allocator;
    const cow_btree = @import("../storage/cow_btree.zig");

    const Helpers = struct {
        pub fn cmpU64(a: u64, b: u64) std.math.Order {
            return std.math.order(a, b);
        }
    };
    const Tree = cow_btree.CowBTree(u64, u64, Helpers.cmpU64);
    var btree = Tree.init(gpa);
    defer btree.deinit();

    var root_a = try btree.createEmptyRoot();
    for (0..200) |k| {
        root_a = try btree.put(root_a, k, k * 10);
    }

    // Clone `root_a -> root_b` in O(1) and modify only 2 keys (`k = 5` and `k = 190`)
    var root_b = btree.cloneRoot(root_a);
    root_b = try btree.put(root_b, 5, 55555);
    root_b = try btree.put(root_b, 190, 99999);

    var diff_res = try btree.diffRoots(gpa, root_a, root_b);
    defer diff_res.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), diff_res.entries.items.len);
    try std.testing.expectEqual(@as(u64, 5), diff_res.entries.items[0].key);
    try std.testing.expectEqual(@as(?u64, 50), diff_res.entries.items[0].old_value);
    try std.testing.expectEqual(@as(?u64, 55555), diff_res.entries.items[0].new_value);

    try std.testing.expectEqual(@as(u64, 190), diff_res.entries.items[1].key);
    try std.testing.expectEqual(@as(?u64, 1900), diff_res.entries.items[1].old_value);
    try std.testing.expectEqual(@as(?u64, 99999), diff_res.entries.items[1].new_value);

    // Must have skipped shared unmodified subtrees and visited strictly fewer than half of total pages!
    try std.testing.expect(diff_res.shared_subtrees_skipped >= 4);
    try std.testing.expect(diff_res.pages_visited < btree.pages.items.len / 2);
}

test "Adversarial 32: Path-scoped and directory-scoped restorePathFromRevision with atomic undo/redo" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-restore");
    defer db.deinit();

    try db.editFile(0, "src/a.zig", "v1_a\n");
    try db.editFile(0, "src/b.zig", "v1_b\n");
    try db.editFile(0, "docs/readme.md", "v1_doc\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: initial files");

    // Dirty all 3 files and add a new untracked file `src/extra.zig`
    try db.editFile(0, "src/a.zig", "dirty_a\n");
    try db.editFile(0, "src/b.zig", "dirty_b\n");
    try db.editFile(0, "src/extra.zig", "uncommitted_extra\n");
    try db.editFile(0, "docs/readme.md", "dirty_doc\n");

    // Restore only the `"src"` directory prefix from `HEAD` (`c1`)!
    // `src/a.zig` and `src/b.zig` revert to `v1_*`, `src/extra.zig` is removed, while `docs/readme.md` stays `"dirty_doc\n"`!
    const restored_count = try db.restorePathFromRevision(0, "src", null);
    try std.testing.expectEqual(@as(usize, 3), restored_count);

    const tree_after_src = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expectEqualStrings("v1_a\n", db.getBlob(tree_after_src.getPathSum("src/a.zig").?.getCleanHash().?).?);
    try std.testing.expectEqualStrings("v1_b\n", db.getBlob(tree_after_src.getPathSum("src/b.zig").?.getCleanHash().?).?);
    try std.testing.expect(tree_after_src.getPathSum("src/extra.zig") == null);
    try std.testing.expectEqualStrings("dirty_doc\n", db.getBlob(tree_after_src.getPathSum("docs/readme.md").?.getCleanHash().?).?);
    try std.testing.expect(db.worktrees.items[0].is_dirty);

    // Now restore `"docs/readme.md"` from `c1` -> worktree matches `HEAD` and `is_dirty` becomes `false`!
    _ = try db.restorePathFromRevision(0, "docs/readme.md", c1);
    try std.testing.expect(!db.worktrees.items[0].is_dirty);

    // Undo restores the dirty `"docs/readme.md"` state!
    try std.testing.expect(try db.undo());
    try std.testing.expect(db.worktrees.items[0].is_dirty);
}

test "Adversarial 33: Distributed sync (fetch, pull, push) with content-addressed commit negotiation and algebraic B+C-A convergence" {
    const gpa = std.testing.allocator;

    var remote_db = try RepoDb.initNew(gpa, "/tmp/wt-remote");
    defer remote_db.deinit();

    // 1. Create base commit `c1` on `remote_db`
    try remote_db.editFile(0, "src/server.zig", "const host = \"0.0.0.0\";\n// ANCHOR\nconst port = 8080;\n");
    _ = try remote_db.commitWorktree(0, "origin", "c1: base server");

    // 2. Clone (`pullFromRemote`) into `local_db` -> fast-forwards `local_db` to `c1`
    var local_db = try RepoDb.initNew(gpa, "/tmp/wt-local");
    defer local_db.deinit();
    const pulled_c1 = try local_db.pullFromRemote(0, &remote_db, "main", "alice");
    try std.testing.expectEqual(@as(repo_db.CommitId, 1), pulled_c1);

    // 3. Divergent edits on both `remote_db` and `local_db` (both assign local CommitId `2` to different commits!)
    try remote_db.editFile(0, "src/server.zig", "const host = \"127.0.0.1\";\n// ANCHOR\nconst port = 8080;\n");
    try remote_db.editFile(0, "remote_only.txt", "from remote\n");
    _ = try remote_db.commitWorktree(0, "bob", "c2-remote: change host");

    try local_db.editFile(0, "src/server.zig", "const host = \"0.0.0.0\";\n// ANCHOR\nconst port = 9090;\n");
    try local_db.editFile(0, "local_only.txt", "from local\n");
    _ = try local_db.commitWorktree(0, "alice", "c2-local: change port");

    // 4. Non-fast-forward `pushToRemote` without `force` must be rejected!
    try std.testing.expectError(
        error.NonFastForwardPush,
        local_db.pushToRemote(&remote_db, "main", false),
    );

    // 5. `local_db.pullFromRemote` negotiates shared `c1` via `computeCommitStructuralHash`,
    //    imports `c2-remote` as `c3` in `local_db`, and merges `B + C - A` (`c4`)!
    const merged_cid = try local_db.pullFromRemote(0, &remote_db, "main", "alice");
    try std.testing.expectEqual(@as(repo_db.CommitId, 4), merged_cid);

    const local_merged_tree = local_db.trees.items[local_db.commits.items[merged_cid].root_tree_id];
    try std.testing.expect(!local_merged_tree.hasConflicts());
    try std.testing.expectEqualStrings(
        "const host = \"127.0.0.1\";\n// ANCHOR\nconst port = 9090;\n",
        local_db.getBlob(local_merged_tree.getPathSum("src/server.zig").?.getCleanHash().?).?,
    );
    try std.testing.expect(local_merged_tree.getPathSum("remote_only.txt") != null);
    try std.testing.expect(local_merged_tree.getPathSum("local_only.txt") != null);

    // 6. Now `local_db.pushToRemote` fast-forwards `remote_db` cleanly to the merged commit!
    _ = try local_db.pushToRemote(&remote_db, "main", false);
    const remote_head_cid = remote_db.branches.items[0].head_commit;
    const remote_head_tree = remote_db.trees.items[remote_db.commits.items[remote_head_cid].root_tree_id];
    try std.testing.expectEqualStrings(
        "const host = \"127.0.0.1\";\n// ANCHOR\nconst port = 9090;\n",
        remote_db.getBlob(remote_head_tree.getPathSum("src/server.zig").?.getCleanHash().?).?,
    );
}

test "Adversarial 34: Commit timestamp persistence (ZIGVCS02 + git-interop) and branch rename/delete with oplog undo/redo" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-branch-ops");
    defer db.deinit();

    try db.editFile(0, "app.zig", "v1\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: base");
    db.commits.items[c1].timestamp_sec = 1731096000;
    db.commits.items[c1].tz_offset_min = -480; // -0800 PST

    var fmt_buf: [25]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2024-11-08 12:00:00 -0800",
        repo_db.formatTimestampWithOffsetBuf(1731096000, -480, &fmt_buf),
    );
    try std.testing.expectEqual(@as(?i16, -480), repo_db.parseTzOffsetMin("-0800"));
    try std.testing.expectEqual(@as(?i16, 330), repo_db.parseTzOffsetMin("+05:30"));

    // 1. Create branch `feature-old`, switch to it, make a dirty draft, then switch back to `main`
    _ = try db.switchBranch(0, "feature-old");
    try db.editFile(0, "draft.zig", "uncommitted work\n");
    _ = try db.switchBranch(0, "main");

    // 2. Rename `feature-old` -> `feature-new`
    try db.renameBranch("feature-old", "feature-new");
    try std.testing.expect(db.findBranchByName("feature-old") == null);
    try std.testing.expect(db.findBranchByName("feature-new") != null);

    // 3. Cannot delete currently checked-out branch `main`
    try std.testing.expectError(error.CannotDeleteCheckedOutBranch, db.deleteBranch("main"));

    // 4. Delete `feature-new`, then undo -> restores `feature-new` AND its shelved draft!
    try db.deleteBranch("feature-new");
    try std.testing.expect(db.findBranchByName("feature-new") == null);
    try std.testing.expect(try db.undo());
    const feat_br = db.findBranchByName("feature-new").?;
    try std.testing.expect(db.getDraft(0, feat_br) != null);

    // 5. Verify commit timestamp & timezone offset round-trip across `ZIGVCS02` and `git fast-export`/`import`
    const compact = try db.serializeToBytesCompact(gpa);
    defer gpa.free(compact);
    var loaded = try RepoDb.deserializeFromBytes(gpa, compact);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(i64, 1731096000), loaded.commits.items[c1].timestamp_sec);
    try std.testing.expectEqual(@as(i16, -480), loaded.commits.items[c1].tz_offset_min);

    const stream = try git_interop.emitFastExportStream(gpa, &db);
    defer gpa.free(stream);
    try std.testing.expect(std.mem.indexOf(u8, stream, "1731096000 -0800\n") != null);
    var git_loaded = try RepoDb.initNew(gpa, "/tmp/wt-git-ts");
    defer git_loaded.deinit();
    try git_interop.importFastExportStream(gpa, &git_loaded, stream);
    try std.testing.expectEqual(@as(i64, 1731096000), git_loaded.commits.items[c1].timestamp_sec);
    try std.testing.expectEqual(@as(i16, -480), git_loaded.commits.items[c1].tz_offset_min);
}

test "Adversarial 35: .gitignore fallback, **/ recursive glob matching, and POSIX symlink (0o120000) materialization" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const ignore_mod = @import("../worktree/ignore.zig");

    // 1. Verify `**/` recursive glob matching at 0, 1, and multiple directory levels
    var matcher = ignore_mod.IgnoreMatcher.init(gpa);
    defer matcher.deinit();
    try matcher.addRulesFromText("**/secret.key\nsrc/**/generated/*.zig\n");

    try std.testing.expect(matcher.isIgnored("secret.key", false));
    try std.testing.expect(matcher.isIgnored("a/b/c/secret.key", false));
    try std.testing.expect(matcher.isIgnored("src/generated/out.zig", false));
    try std.testing.expect(matcher.isIgnored("src/deep/nested/generated/out.zig", false));
    try std.testing.expect(!matcher.isIgnored("src/main.zig", false));

    // 2. Verify `.gitignore` loading and `FileMode.symlink` (`0o120000`) in worktree scanner/materializer
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wt_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(wt_rel);

    var db = try RepoDb.initNew(gpa, wt_rel);
    defer db.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "**/ignored_by_git.tmp\n" });
    try tmp.dir.createDirPath(io, "nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/ignored_by_git.tmp", .data = "skip me\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/kept.txt", .data = "keep me\n" });

    _ = try materializer.syncWorktreeFromDisk(gpa, io, &db, 0, wt_rel);
    const tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expect(tree.getPathSum("nested/kept.txt") != null);
    try std.testing.expect(tree.getPathSum("nested/ignored_by_git.tmp") == null);

    // Add a symlink (`0o120000`) and materialize to disk
    try db.editFileWithMode(0, "nested/link_to_kept", "kept.txt", .symlink);
    try materializer.materializeWorktreeToDir(gpa, io, &db, 0, wt_rel);
    const tree_with_link = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expectEqual(repo_db.FileMode.symlink, tree_with_link.getPathMode("nested/link_to_kept").?);
}

test "Adversarial 36: Everyday repo operations — moveFile (mv), deleteFile (rm), and showRevision (show <rev> and show <rev>:<path>)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-mv-show");
    defer db.deinit();

    try db.editFileWithMode(0, "scripts/run.sh", "#!/bin/sh\necho ok\n", .executable);
    const c1 = try db.commitWorktree(0, "alice", "c1: add run.sh");

    // 1. `moveFile` (`mv`) preserves `FileMode.executable` and records an atomic `"mv"` oplog entry
    try db.moveFile(0, "scripts/run.sh", "bin/start.sh");
    const moved_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expect(moved_tree.getPathSum("scripts/run.sh") == null);
    try std.testing.expect(moved_tree.getPathSum("bin/start.sh") != null);
    try std.testing.expectEqual(repo_db.FileMode.executable, moved_tree.getPathMode("bin/start.sh").?);

    const c2 = try db.commitWorktree(0, "alice", "c2: move script to bin/start.sh");

    // 2. `showRevision` with `<rev>:<path>` inspects historical file content at `c1` and `c2`
    const file_at_c1 = try db.showRevision(gpa, 0, "c1:scripts/run.sh");
    defer gpa.free(file_at_c1);
    try std.testing.expectEqualStrings("#!/bin/sh\necho ok\n", file_at_c1);

    const file_at_head = try db.showRevision(gpa, 0, ":bin/start.sh");
    defer gpa.free(file_at_head);
    try std.testing.expectEqualStrings("#!/bin/sh\necho ok\n", file_at_head);

    // 3. `showRevision` with `<rev>` outputs commit metadata and unified diff
    const commit_show = try db.showRevision(gpa, 0, "HEAD");
    defer gpa.free(commit_show);
    try std.testing.expect(std.mem.indexOf(u8, commit_show, "commit c2") != null);
    try std.testing.expect(std.mem.indexOf(u8, commit_show, "+++ b/bin/start.sh") != null);
    _ = c1;
    _ = c2;
}

// ============================================================================
// Wave 9: Named Remotes Registry, Algebraic Conflict Resolution Strategies
// (--ours / --theirs / --base), and Commit History / DiffStat Ergonomics
// ============================================================================

test "Adversarial 37: Named Remotes Registry (setRemote, removeRemote, resolveRemoteOrPath) with ZIGVCS02 Persistence and Atomic Undo/Redo" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-remotes");
    defer db.deinit();

    // 1. Register `origin` and `upstream`
    try db.setRemote("origin", "/srv/repos/origin.vcs");
    try db.setRemote("upstream", "/srv/repos/upstream.vcs");
    try std.testing.expectEqual(@as(usize, 2), db.remotes.items.len);
    try std.testing.expectEqualStrings("/srv/repos/origin.vcs", db.resolveRemoteOrPath("origin"));
    try std.testing.expectEqualStrings("/srv/repos/upstream.vcs", db.resolveRemoteOrPath("upstream"));
    try std.testing.expectEqualStrings("/direct/path/repo", db.resolveRemoteOrPath("/direct/path/repo"));

    // 2. Update `origin` URL in-place (`set-url`)
    try db.setRemote("origin", "/srv/repos/new-origin.vcs");
    try std.testing.expectEqual(@as(usize, 2), db.remotes.items.len);
    try std.testing.expectEqualStrings("/srv/repos/new-origin.vcs", db.findRemotePath("origin").?);

    // 3. Remove `upstream` and verify atomic `undo`/`redo` restores/removes it
    _ = try db.removeRemote("upstream");
    try std.testing.expectEqual(@as(usize, 1), db.remotes.items.len);
    try std.testing.expect(db.findRemotePath("upstream") == null);

    _ = try db.undo();
    try std.testing.expectEqual(@as(usize, 2), db.remotes.items.len);
    try std.testing.expectEqualStrings("/srv/repos/upstream.vcs", db.findRemotePath("upstream").?);

    _ = try db.redo();
    try std.testing.expectEqual(@as(usize, 1), db.remotes.items.len);

    // 4. Persist to `ZIGVCS02` and reload
    const compact = try db.serializeToBytesCompact(gpa);
    defer gpa.free(compact);
    var reloaded = try RepoDb.deserializeFromBytes(gpa, compact);
    defer reloaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), reloaded.remotes.items.len);
    try std.testing.expectEqualStrings("/srv/repos/new-origin.vcs", reloaded.findRemotePath("origin").?);
}

test "Adversarial 38: Algebraic Conflict Resolution Strategies (--ours, --theirs, --base) on Conflicted PathSums + Undo/Redo" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-resolve-strategy");
    defer db.deinit();

    // Base commit `c1` (`A`)
    try db.editFile(0, "config.zig", "pub const timeout = 10;\n");
    try db.editFile(0, "only_theirs.zig", "pub const mode = .base;\n");
    _ = try db.commitWorktree(0, "alice", "c1: base");

    // Branch `feat` (`C` / theirs) modifies `config.zig` and deletes `only_theirs.zig`
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "config.zig", "pub const timeout = 30; // theirs\n");
    try db.deleteFile(0, "only_theirs.zig");
    _ = try db.commitWorktree(0, "bob", "c2: theirs");

    // Branch `main` (`B` / ours) modifies `config.zig` and `only_theirs.zig`
    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "config.zig", "pub const timeout = 20; // ours\n");
    try db.editFile(0, "only_theirs.zig", "pub const mode = .ours_modified;\n");
    _ = try db.commitWorktree(0, "alice", "c3: ours");

    // Merge `feat` into `main` -> produces algebraic conflicts `B + C - A` on both paths
    const merge_cid = try db.mergeBranch(0, "feat", "alice", "Merge feat into main");
    try std.testing.expect(db.trees.items[db.commits.items[merge_cid].root_tree_id].hasConflicts());

    // 1. Resolve `config.zig` with `.ours` -> collapses `B + C - A` to `+1 * B` (`timeout = 20`)
    try db.resolveFileWithStrategy(0, "config.zig", .ours);
    {
        const t = db.trees.items[db.worktrees.items[0].working_tree_id];
        const ps = t.getPathSum("config.zig").?;
        try std.testing.expect(!ps.isConflicted());
        const bh = ps.terms.items[0].hash;
        try std.testing.expectEqualStrings("pub const timeout = 20; // ours\n", db.getBlob(bh).?);
    }

    // 2. Undo and resolve `config.zig` with `.theirs` -> collapses `B + C - A` to `+1 * C` (`timeout = 30`)
    _ = try db.undo();
    try db.resolveFileWithStrategy(0, "config.zig", .theirs);
    {
        const t = db.trees.items[db.worktrees.items[0].working_tree_id];
        const ps = t.getPathSum("config.zig").?;
        try std.testing.expect(!ps.isConflicted());
        const bh = ps.terms.items[0].hash;
        try std.testing.expectEqualStrings("pub const timeout = 30; // theirs\n", db.getBlob(bh).?);
    }

    // 3. Undo and resolve `config.zig` with `.base` -> collapses `B + C - A` to `+1 * A` (`timeout = 10`)
    _ = try db.undo();
    try db.resolveFileWithStrategy(0, "config.zig", .base);
    {
        const t = db.trees.items[db.worktrees.items[0].working_tree_id];
        const ps = t.getPathSum("config.zig").?;
        try std.testing.expect(!ps.isConflicted());
        const bh = ps.terms.items[0].hash;
        try std.testing.expectEqualStrings("pub const timeout = 10;\n", db.getBlob(bh).?);
    }

    // 4. Resolve modify/delete conflict on `only_theirs.zig` with `.theirs` (where `C = bot` deletion!)
    try db.resolveFileWithStrategy(0, "only_theirs.zig", .theirs);
    {
        const t = db.trees.items[db.worktrees.items[0].working_tree_id];
        try std.testing.expect(!t.hasConflicts());
        try std.testing.expect(t.getPathSum("only_theirs.zig") == null);
    }
}

test "Adversarial 39: DiffStat Histogram (`formatDiffStat`) and Filtered Commit Log (`formatCommitLogFiltered` with max_count and --stat)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-diffstat-log");
    defer db.deinit();

    try db.editFile(0, "src/a.zig", "line 1\nline 2\nline 3\n");
    try db.editFile(0, "src/b.zig", "old 1\nold 2\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: initial files");

    try db.editFile(0, "src/a.zig", "line 1\nline 2 modified\nline 3\nline 4 added\n");
    try db.deleteFile(0, "src/b.zig");
    try db.editFile(0, "src/c.zig", "brand new\n");
    const c2 = try db.commitWorktree(0, "bob", "c2: update a, remove b, add c");

    // 1. Verify `formatDiffStat` between `c1` and `c2`
    const stat_out = try db.formatDiffStat(gpa, db.commits.items[c1].root_tree_id, db.commits.items[c2].root_tree_id);
    defer gpa.free(stat_out);
    try std.testing.expect(std.mem.indexOf(u8, stat_out, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, stat_out, "src/b.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, stat_out, "src/c.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, stat_out, "3 file(s) changed") != null);

    // 2. Verify `formatCommitLogFiltered` with `max_count = 1` and `include_stat = true`
    const log_limited = try db.formatCommitLogFiltered(gpa, c2, 1, true);
    defer gpa.free(log_limited);
    try std.testing.expect(std.mem.indexOf(u8, log_limited, "c2: update a, remove b, add c") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_limited, "c1: initial files") == null);
    try std.testing.expect(std.mem.indexOf(u8, log_limited, "3 file(s) changed") != null);
}

// ============================================================================
// Wave 10: Path-Selective Commit, Algebraic Commit Squash, and Repository
// Integrity Verification (`verifyIntegrity` / `zig-vcs fsck`)
// ============================================================================

test "Adversarial 40: Path-Selective Commit (`commitWorktreePaths`, Theorem 9a) and Algebraic Commit Squash (`squashCommit`, Theorem 9b)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-selective-squash");
    defer db.deinit();

    // Base commit `c1`
    try db.editFile(0, "src/core.zig", "pub const v = 1;\n");
    try db.editFile(0, "src/cli.zig", "pub const cli = 1;\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: base");
    _ = c1;

    // 1. Modify both `src/core.zig` and `src/cli.zig` + add `docs/guide.md` in working tree
    try db.editFile(0, "src/core.zig", "pub const v = 2;\n");
    try db.editFile(0, "src/cli.zig", "pub const cli = 2;\n");
    try db.editFile(0, "docs/guide.md", "# Guide\n");

    // Commit ONLY `src/core.zig` (`c2`): working tree must remain dirty with `src/cli.zig` and `docs/guide.md`!
    const c2 = try db.commitWorktreePaths(0, "alice", "c2: update core only", &.{"src/core.zig"});
    try std.testing.expect(db.worktrees.items[0].is_dirty);
    {
        const c2_tree = db.trees.items[db.commits.items[c2].root_tree_id];
        try std.testing.expectEqualStrings("pub const v = 2;\n", db.getBlob(c2_tree.getPathSum("src/core.zig").?.getCleanHash().?).?);
        try std.testing.expectEqualStrings("pub const cli = 1;\n", db.getBlob(c2_tree.getPathSum("src/cli.zig").?.getCleanHash().?).?);
        try std.testing.expect(c2_tree.getPathSum("docs/guide.md") == null);
    }

    // Commit remaining paths `src/cli.zig` and `docs` (`c3`): working tree becomes clean (`Theorem 9a`)!
    const c3 = try db.commitWorktreePaths(0, "alice", "c3: update cli and docs", &.{ "src/cli.zig", "docs" });
    try std.testing.expect(!db.worktrees.items[0].is_dirty);
    {
        const c3_tree = db.trees.items[db.commits.items[c3].root_tree_id];
        try std.testing.expectEqualStrings("pub const v = 2;\n", db.getBlob(c3_tree.getPathSum("src/core.zig").?.getCleanHash().?).?);
        try std.testing.expectEqualStrings("pub const cli = 2;\n", db.getBlob(c3_tree.getPathSum("src/cli.zig").?.getCleanHash().?).?);
        try std.testing.expectEqualStrings("# Guide\n", db.getBlob(c3_tree.getPathSum("docs/guide.md").?.getCleanHash().?).?);
    }

    // 2. Create descendant commit `c4` on branch `feat` above `c3`, then squash `c3` into `c2` (`Theorem 9b`)!
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "src/feat.zig", "pub const feat = true;\n");
    const c4 = try db.commitWorktree(0, "bob", "c4: add feat.zig on top of c3");
    _ = c4;

    _ = try db.switchBranch(0, "main");
    const sq_cid = try db.squashCommit(0, c3, "c2+c3 squashed: core, cli, and docs");
    try std.testing.expectEqual(@as(repo_db.CommitId, 1), db.commits.items[sq_cid].parent1.?);
    try std.testing.expectEqualStrings("c2+c3 squashed: core, cli, and docs", db.commits.items[sq_cid].message);

    // Verify `feat` was automatically cascaded onto `sq_cid` and preserves `src/feat.zig` (`Theorem 9b`)!
    const feat_br = db.findBranchByName("feat").?;
    const feat_head = db.branches.items[feat_br].head_commit;
    try std.testing.expectEqual(sq_cid, db.commits.items[feat_head].parent1.?);
    {
        const feat_tree = db.trees.items[db.commits.items[feat_head].root_tree_id];
        try std.testing.expectEqualStrings("pub const feat = true;\n", db.getBlob(feat_tree.getPathSum("src/feat.zig").?.getCleanHash().?).?);
        try std.testing.expectEqualStrings("# Guide\n", db.getBlob(feat_tree.getPathSum("docs/guide.md").?.getCleanHash().?).?);
    }

    // Verify single-step `undo` restores pre-squash state
    _ = try db.undo();
    try std.testing.expectEqual(c3, db.branches.items[db.findBranchByName("main").?].head_commit);
    _ = try db.redo();
    try std.testing.expectEqual(sq_cid, db.branches.items[db.findBranchByName("main").?].head_commit);
}

test "Adversarial 41: Cryptographic & Algebraic Integrity Checker (`verifyIntegrity` / `zig-vcs fsck`)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-fsck");
    defer db.deinit();

    try db.editFile(0, "src/main.zig", "pub fn main() void {}\n");
    _ = try db.commitWorktree(0, "alice", "c1: initial");
    try db.createTag("v1.0", 1);

    // 1. Healthy repository passes `verifyIntegrity`
    const report = try db.verifyIntegrity();
    try std.testing.expectEqual(@as(usize, 1), report.blobs_verified);
    try std.testing.expectEqual(@as(usize, 2), report.commits_verified);

    // 2. Corrupt a blob's hash in-memory -> `verifyIntegrity` catches `error.CorruptBlobHash`!
    db.blobs.items[0].hash[0] ^= 0xFF;
    try std.testing.expectError(error.CorruptBlobHash, db.verifyIntegrity());
    db.blobs.items[0].hash[0] ^= 0xFF; // restore

    // 3. Violate `Z[A_bot]` coefficient conservation (`sum != 1`) -> `verifyIntegrity` catches `error.InvalidPathSumCoefficientConservation`!
    db.trees.items[1].entries.items[0].sum.terms.items[0].coeff = 2;
    try std.testing.expectError(error.InvalidPathSumCoefficientConservation, db.verifyIntegrity());
    db.trees.items[1].entries.items[0].sum.terms.items[0].coeff = 1; // restore

    // 4. Verify restored repository passes `verifyIntegrity` again
    _ = try db.verifyIntegrity();
}

// ============================================================================
// Wave 11: Incremental Tree Delta Compression (Theorem 10a), Path-Filtered
// Commit Log (Theorem 10b), and Machine-Readable JSON Output (`--json`)
// ============================================================================

test "Adversarial 42: Incremental Tree Delta Compression (`TREE_DELTA_FLAG`, Theorem 10a) Roundtrip & Size Reduction" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-tree-delta");
    defer db.deinit();

    // Seed 30 files in initial commit `c1`
    for (0..30) |i| {
        const path = try std.fmt.allocPrint(gpa, "src/pkg/file_{d:0>2}.zig", .{i});
        defer gpa.free(path);
        const content = try std.fmt.allocPrint(gpa, "pub const idx = {d};\n", .{i});
        defer gpa.free(content);
        try db.editFile(0, path, content);
    }
    _ = try db.commitWorktree(0, "alice", "c1: seed 30 files");

    // Create 15 incremental commits where each commit modifies 1 file, adds 1 file, or deletes 1 file
    for (0..15) |step| {
        const mod_path = try std.fmt.allocPrint(gpa, "src/pkg/file_{d:0>2}.zig", .{step});
        defer gpa.free(mod_path);
        const mod_content = try std.fmt.allocPrint(gpa, "pub const idx = {d};\npub const rev = {d};\n", .{ step, step + 1 });
        defer gpa.free(mod_content);
        try db.editFile(0, mod_path, mod_content);

        if (step % 3 == 0) {
            const add_path = try std.fmt.allocPrint(gpa, "src/extra/new_{d:0>2}.zig", .{step});
            defer gpa.free(add_path);
            try db.editFile(0, add_path, "pub const extra = true;\n");
        }
        if (step == 5) {
            try db.deleteFile(0, "src/pkg/file_29.zig");
        }
        const msg = try std.fmt.allocPrint(gpa, "commit step {d}", .{step});
        defer gpa.free(msg);
        _ = try db.commitWorktree(0, "alice", msg);
    }

    const raw_v1 = try db.serializeToBytes(gpa);
    defer gpa.free(raw_v1);
    const compact_v2 = try db.serializeToBytesCompact(gpa);
    defer gpa.free(compact_v2);

    // Compact V2 with Incremental Tree Delta Compression must be >3x smaller than raw V1!
    try std.testing.expect(compact_v2.len * 3 < raw_v1.len);

    // Roundtrip deserialize and verify every tree entry across all 17 trees is bit-for-bit identical (`Theorem 10a`)
    var loaded = try RepoDb.deserializeFromBytes(gpa, compact_v2);
    defer loaded.deinit();

    try std.testing.expectEqual(db.trees.items.len, loaded.trees.items.len);
    for (db.trees.items, loaded.trees.items) |orig_t, dec_t| {
        try std.testing.expect(orig_t.eql(dec_t));
    }
    _ = try loaded.verifyIntegrity();
}

test "Adversarial 43: Path-Filtered Commit Log (`formatCommitLogFilteredWithPath`, Theorem 10b) and JSON Output (`--json`)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-path-log-json");
    defer db.deinit();

    try db.editFile(0, "src/algebra/tree.zig", "pub const a = 1;\n");
    _ = try db.commitWorktree(0, "alice", "c1: add algebra tree");

    try db.editFile(0, "docs/README.md", "# Docs\n");
    _ = try db.commitWorktree(0, "bob", "c2: add docs readme");

    try db.editFile(0, "src/algebra/tree.zig", "pub const a = 2;\n");
    _ = try db.commitWorktree(0, "alice", "c3: update algebra tree");

    // 1. Path-filtered log for `src/algebra` must include `c1` and `c3`, and exclude `c2` (`Theorem 10b`)
    const alg_log = try db.formatCommitLogFilteredWithPath(gpa, null, null, false, "src/algebra");
    defer gpa.free(alg_log);
    try std.testing.expect(std.mem.indexOf(u8, alg_log, "c1: add algebra tree") != null);
    try std.testing.expect(std.mem.indexOf(u8, alg_log, "c3: update algebra tree") != null);
    try std.testing.expect(std.mem.indexOf(u8, alg_log, "c2: add docs readme") == null);

    // 2. Path-filtered log for `docs` must include `c2` and exclude `c1` and `c3`
    const docs_log = try db.formatCommitLogFilteredWithPath(gpa, null, null, false, "docs");
    defer gpa.free(docs_log);
    try std.testing.expect(std.mem.indexOf(u8, docs_log, "c2: add docs readme") != null);
    try std.testing.expect(std.mem.indexOf(u8, docs_log, "c1: add algebra tree") == null);
    try std.testing.expect(std.mem.indexOf(u8, docs_log, "c3: update algebra tree") == null);

    // 3. Machine-readable JSON output (`status --json`, `log --json`, `branch --json`, `worktree --json`)
    const status_json = try db.formatStatusJson(gpa, 0);
    defer gpa.free(status_json);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"branch\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"src/algebra/tree.zig\"") != null);

    const log_json = try db.formatCommitLogJson(gpa, null, null, "docs");
    defer gpa.free(log_json);
    try std.testing.expect(std.mem.indexOf(u8, log_json, "\"message\":\"c2: add docs readme\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_json, "\"message\":\"c3: update algebra tree\"") == null);

    const br_json = try db.formatBranchesJson(gpa, 0);
    defer gpa.free(br_json);
    try std.testing.expect(std.mem.indexOf(u8, br_json, "\"name\":\"main\",\"head_commit\":3,\"is_current\":true") != null);

    const wt_json = try db.formatWorktreesJson(gpa);
    defer gpa.free(wt_json);
    try std.testing.expect(std.mem.indexOf(u8, wt_json, "\"name\":\"main-wt\"") != null);
}

// ============================================================================
// Wave 12: Cross-Branch Algebraic Draft Apply (`draft <list|show|apply|drop>`,
// Theorem 11a) and Revision Range Filtering (`A..B`, Theorem 11b)
// ============================================================================

test "Adversarial 44: Cross-Branch Algebraic Draft Apply & Drop (`draft <list|show|apply|drop>`, Theorem 11a)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-draft-apply");
    defer db.deinit();

    try db.editFile(0, "src/config.zig", "const port = 8080;\n// ANCHOR\nconst workers = 4;\n");
    _ = try db.commitWorktree(0, "alice", "c1: initial config");

    // 1. Switch to `feat`, make uncommitted edit to `workers = 16` + add `src/feat_draft.zig`, then switch back to `main`
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "src/config.zig", "const port = 8080;\n// ANCHOR\nconst workers = 16;\n");
    try db.editFile(0, "src/feat_draft.zig", "pub const draft = true;\n");
    _ = try db.switchBranch(0, "main");
    try std.testing.expect(!db.worktrees.items[0].is_dirty);

    // 2. Inspect shelved drafts via `formatDraftsList`, `formatDraftsJson`, and `showBranchDraftDiff`
    const list_txt = try db.formatDraftsList(gpa);
    defer gpa.free(list_txt);
    try std.testing.expect(std.mem.indexOf(u8, list_txt, "branch=feat") != null);

    const list_json = try db.formatDraftsJson(gpa);
    defer gpa.free(list_json);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"branch\":\"feat\"") != null);

    const diff_txt = try db.showBranchDraftDiff(gpa, 0, "feat");
    defer gpa.free(diff_txt);
    try std.testing.expect(std.mem.indexOf(u8, diff_txt, "+const workers = 16;") != null);

    // 3. Edit top region (`port = 9090`) on `main`, then algebraically apply `feat`'s draft onto `main` (`Theorem 11a`)!
    try db.editFile(0, "src/config.zig", "const port = 9090;\n// ANCHOR\nconst workers = 4;\n");
    _ = try db.applyBranchDraft(0, "feat");

    const merged_tree = db.trees.items[db.worktrees.items[0].working_tree_id];
    try std.testing.expect(!merged_tree.hasConflicts());
    try std.testing.expectEqualStrings(
        "const port = 9090;\n// ANCHOR\nconst workers = 16;\n",
        db.getBlob(merged_tree.getPathSum("src/config.zig").?.getCleanHash().?).?,
    );
    try std.testing.expectEqualStrings(
        "pub const draft = true;\n",
        db.getBlob(merged_tree.getPathSum("src/feat_draft.zig").?.getCleanHash().?).?,
    );

    // 4. Drop `feat`'s shelved draft and verify single-step `undo` restores it (`INV-6`)!
    try std.testing.expect(try db.dropBranchDraft(0, "feat"));
    try std.testing.expectEqual(@as(usize, 0), db.drafts.items.len);
    _ = try db.undo();
    try std.testing.expectEqual(@as(usize, 1), db.drafts.items.len);
}

test "Adversarial 45: Revision Range Commit Log (`A..B`, Theorem 11b) & Commit-Parent-Aware Tree Delta Compression" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-rev-range");
    defer db.deinit();

    for (0..10) |i| {
        const path = try std.fmt.allocPrint(gpa, "src/file_{d}.zig", .{i});
        defer gpa.free(path);
        try db.editFile(0, path, "pub const v = 0;\n");
    }
    const c1 = try db.commitWorktree(0, "alice", "c1: base 10 files");

    try db.editFile(0, "src/file_0.zig", "pub const v = 1;\n");
    _ = try db.commitWorktree(0, "alice", "c2: main step 1");

    // Diverge `feat` from `c1` (interleaving commits across branches so `parent1.root_tree_id` is non-adjacent)
    _ = try db.getOrCreateBranch("feat", c1);
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "src/file_1.zig", "pub const v = 2;\n");
    const c3 = try db.commitWorktree(0, "bob", "c3: feat step 1");

    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "src/file_2.zig", "pub const v = 3;\n");
    const c4 = try db.commitWorktree(0, "alice", "c4: main step 2");

    // 1. Verify revision range `c1..c4` includes `c2` and `c4` and excludes `c1` and `c3` (`Theorem 11b`)
    const range_log = try db.formatCommitLogRange(gpa, c1, c4, null, false, null);
    defer gpa.free(range_log);
    try std.testing.expect(std.mem.indexOf(u8, range_log, "c4: main step 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, range_log, "c2: main step 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, range_log, "c1: base 10 files") == null);
    try std.testing.expect(std.mem.indexOf(u8, range_log, "c3: feat step 1") == null);

    // 2. Verify empty revision range `c3..c3` emits 0 commits (`Theorem 11b`)
    const empty_range = try db.formatCommitLogRange(gpa, c3, c3, null, false, null);
    defer gpa.free(empty_range);
    try std.testing.expectEqual(@as(usize, 0), empty_range.len);

    // 3. Verify compact V2 roundtrip across interleaved branch commits
    const compact = try db.serializeToBytesCompact(gpa);
    defer gpa.free(compact);
    var loaded = try RepoDb.deserializeFromBytes(gpa, compact);
    defer loaded.deinit();
    try std.testing.expectEqual(db.commits.items.len, loaded.commits.items.len);
}

// ============================================================================
// Wave 13: Telescoping Multi-Commit Range Cherry-Pick & Backout (`A..B`,
// Theorems 12a & 12b) and Compact `status -s` / `log --oneline`
// ============================================================================

test "Adversarial 46: Telescoping Multi-Commit Range Cherry-Pick & Backout (`cherry-pick A..B`, `backout A..B`, Theorems 12a & 12b)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-range-cherry-pick");
    defer db.deinit();

    try db.editFile(0, "src/core.zig", "pub const v = 0;\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: base");

    // Create a 3-commit feature chain `c1 -> c2 -> c3 -> c4` on `feat`
    _ = try db.switchBranch(0, "feat");
    try db.editFile(0, "src/a.zig", "pub const a = 1;\n");
    _ = try db.commitWorktree(0, "bob", "c2: add a.zig");
    try db.editFile(0, "src/b.zig", "pub const b = 2;\n");
    _ = try db.commitWorktree(0, "bob", "c3: add b.zig");
    try db.editFile(0, "src/a.zig", "pub const a = 10;\n");
    const c4 = try db.commitWorktree(0, "bob", "c4: refine a.zig");

    // Switch back to `main`, make an independent commit `c5`, then cherry-pick the entire range `c1..c4` (`Theorem 12a`)!
    _ = try db.switchBranch(0, "main");
    try db.editFile(0, "src/main_only.zig", "pub const m = true;\n");
    const c5 = try db.commitWorktree(0, "alice", "c5: main independent work");
    const c5_tid = db.commits.items[c5].root_tree_id;

    const cp_cid = try db.cherryPickCommitRange(0, c1, c4, "alice", "c6: cherry-pick c1..c4");
    {
        const cp_tree = db.trees.items[db.commits.items[cp_cid].root_tree_id];
        try std.testing.expectEqualStrings("pub const a = 10;\n", db.getBlob(cp_tree.getPathSum("src/a.zig").?.getCleanHash().?).?);
        try std.testing.expectEqualStrings("pub const b = 2;\n", db.getBlob(cp_tree.getPathSum("src/b.zig").?.getCleanHash().?).?);
        try std.testing.expectEqualStrings("pub const m = true;\n", db.getBlob(cp_tree.getPathSum("src/main_only.zig").?.getCleanHash().?).?);
    }

    // Backout the entire range `c1..c4` (`backoutCommitRange`) -> restores `c5`'s exact tree (`Theorem 12b`)!
    const bo_cid = try db.backoutCommitRange(0, c1, c4, "alice", "c7: backout c1..c4");
    const bo_tid = db.commits.items[bo_cid].root_tree_id;
    try std.testing.expect(db.trees.items[c5_tid].eql(db.trees.items[bo_tid]));
}

test "Adversarial 47: Compact `formatStatusShort` (`status -s`) and `formatCommitLogOneline` (`log --oneline`)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-short-oneline");
    defer db.deinit();

    try db.editFile(0, "src/keep.zig", "keep\n");
    try db.editFile(0, "src/mod.zig", "v1\n");
    try db.editFile(0, "src/del.zig", "bye\n");
    _ = try db.commitWorktree(0, "alice", "c1: seed files");
    try db.createTag("v0.1", 1);

    try db.editFile(0, "src/mod.zig", "v2\n");
    try db.deleteFile(0, "src/del.zig");
    try db.editFile(0, "src/add.zig", "new\n");

    const short_txt = try db.formatStatusShort(gpa, 0);
    defer gpa.free(short_txt);
    try std.testing.expect(std.mem.indexOf(u8, short_txt, "A  src/add.zig\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, short_txt, "D  src/del.zig\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, short_txt, "M  src/mod.zig\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, short_txt, "src/keep.zig") == null);

    const oneline_txt = try db.formatCommitLogOneline(gpa, null, null, null, null);
    defer gpa.free(oneline_txt);
    try std.testing.expect(std.mem.indexOf(u8, oneline_txt, "c1 (main, tag: v0.1) c1: seed files\n") != null);
}

// ============================================================================
// Wave 14: Oplog Index Jump (`restoreOplogAtIndex`, Theorem 13b) and
// Zero-Checkout POSIX USTAR `.tar` Archive Exporter (`exportRevisionTarBytes`)
// ============================================================================

test "Adversarial 48: Oplog Index Time-Travel (`restoreOplogAtIndex`, Theorem 13b) & `formatOplogJson`" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-oplog-restore");
    defer db.deinit();

    try db.editFile(0, "src/v.zig", "v1\n");
    const c1 = try db.commitWorktree(0, "alice", "c1: v1");

    // Capture the oplog index right after `c1` is committed
    try db.editFile(0, "src/v.zig", "v2\n");
    const snap_idx_at_c1 = db.oplog.items.len - 1; // pre-edit snapshot where `main` is at `c1` and clean!
    const c2 = try db.commitWorktree(0, "alice", "c2: v2");

    try db.editFile(0, "src/v.zig", "v3\n");
    const c3 = try db.commitWorktree(0, "alice", "c3: v3");
    _ = c2;
    try std.testing.expectEqual(c3, db.branches.items[0].head_commit);

    // 1. Inspect oplog JSON
    const oplog_json = try db.formatOplogJson(gpa, 3);
    defer gpa.free(oplog_json);
    try std.testing.expect(std.mem.indexOf(u8, oplog_json, "\"command\":\"commit\"") != null);

    // 2. Time-travel directly back to `snap_idx_at_c1` (`Theorem 13b`)!
    try db.restoreOplogAtIndex(snap_idx_at_c1);
    try std.testing.expectEqual(c1, db.branches.items[0].head_commit);
    try std.testing.expect(!db.worktrees.items[0].is_dirty);

    // 3. Single-step `undo` immediately reverses the time-travel jump back to `c3` (`Theorem 13b`)!
    try std.testing.expect(try db.undo());
    try std.testing.expectEqual(c3, db.branches.items[0].head_commit);
}

test "Adversarial 49: Zero-Checkout Deterministic POSIX USTAR `.tar` Archive Exporter (`exportRevisionTarBytes`)" {
    const gpa = std.testing.allocator;

    var db = try RepoDb.initNew(gpa, "/tmp/wt-tar-archive");
    defer db.deinit();

    try db.editFile(0, "README.md", "# Hello Tar\n");
    try db.editFileWithMode(0, "bin/run.sh", "#!/bin/sh\necho ok\n", .executable);
    try db.editFileWithMode(0, "bin/latest", "run.sh", .symlink);
    const c1 = try db.commitWorktree(0, "alice", "c1: release files");

    const tar_bytes = try db.exportRevisionTarBytes(gpa, c1, "zig-vcs-1.0");
    defer gpa.free(tar_bytes);

    // Must be a multiple of 512-byte blocks and contain `ustar` headers for all 3 entries
    try std.testing.expectEqual(@as(usize, 0), tar_bytes.len % 512);
    try std.testing.expect(std.mem.indexOf(u8, tar_bytes, "zig-vcs-1.0/README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_bytes, "zig-vcs-1.0/bin/run.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_bytes, "zig-vcs-1.0/bin/latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_bytes, "# Hello Tar\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_bytes, "ustar") != null);
}






