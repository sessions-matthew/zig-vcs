//! `.vcsignore` & Built-in Ignore Pattern Matcher.
//!
//! Supports standard gitignore-style rules for worktree scanning:
//! - Built-in ignores: `.vcs`, `.vcs-wt`, `.git`, `.jj`, `.hg`, `.svn`, `.DS_Store`.
//! - Blank lines and `#` comments are skipped.
//! - Trailing `/` matches directories only (e.g., `zig-out/`, `.zig-cache/`).
//! - Patterns without `/` match the basename at any directory depth (e.g., `*.o`, `*.tmp`).
//! - Patterns containing `/` match relative to the worktree root (e.g., `/build`, `ref/papers/*`).
//! - Leading `!` negates a previous ignore rule (e.g., `!important.o`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BuiltinIgnoreDirs = [_][]const u8{
    ".vcs",
    ".vcs-wt",
    ".git",
    ".jj",
    ".hg",
    ".svn",
    "zig-out",
    ".zig-cache",
};

pub const BuiltinIgnoreFiles = [_][]const u8{
    ".vcs-wt",
    ".vcs-link",
    ".DS_Store",
};

pub const Rule = struct {
    pattern: []u8,
    negated: bool,
    dir_only: bool,
    anchored: bool,
};

pub const IgnoreMatcher = struct {
    allocator: Allocator,
    rules: std.ArrayList(Rule) = .empty,

    pub fn init(allocator: Allocator) IgnoreMatcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *IgnoreMatcher) void {
        for (self.rules.items) |r| self.allocator.free(r.pattern);
        self.rules.deinit(self.allocator);
    }

    /// Parse multi-line `.vcsignore` content and append rules.
    pub fn addRulesFromText(self: *IgnoreMatcher, text: []const u8) !void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            var slice = line;
            var negated = false;
            if (slice[0] == '!') {
                negated = true;
                slice = slice[1..];
                if (slice.len == 0) continue;
            }

            var dir_only = false;
            if (slice[slice.len - 1] == '/') {
                dir_only = true;
                slice = slice[0 .. slice.len - 1];
                if (slice.len == 0) continue;
            }

            var anchored = false;
            if (slice[0] == '/') {
                anchored = true;
                slice = slice[1..];
                if (slice.len == 0) continue;
            } else if (std.mem.indexOfScalar(u8, slice, '/') != null) {
                anchored = true;
            }

            try self.rules.append(self.allocator, .{
                .pattern = try self.allocator.dupe(u8, slice),
                .negated = negated,
                .dir_only = dir_only,
                .anchored = anchored,
            });
        }
    }

    /// Check whether `rel_path` (normalized with `/` separators, no leading `/`) is ignored.
    pub fn isIgnored(self: *const IgnoreMatcher, rel_path: []const u8, is_dir: bool) bool {
        const basename = std.fs.path.basename(rel_path);

        // 1. Always ignore internal VCS directories and metadata files
        for (BuiltinIgnoreDirs) |bdir| {
            if (std.mem.eql(u8, basename, bdir) or std.mem.eql(u8, rel_path, bdir)) {
                return true;
            }
            if (std.mem.startsWith(u8, rel_path, bdir) and
                rel_path.len > bdir.len and
                rel_path[bdir.len] == '/')
            {
                return true;
            }
        }
        if (!is_dir) {
            for (BuiltinIgnoreFiles) |bfile| {
                if (std.mem.eql(u8, basename, bfile)) return true;
            }
        }

        // 2. Evaluate user `.vcsignore` rules in order (last matching rule wins)
        var ignored = false;
        for (self.rules.items) |rule| {
            if (rule.dir_only and !is_dir) continue;
            const target = if (rule.anchored) rel_path else basename;
            if (globMatch(rule.pattern, target) or
                (rule.dir_only and std.mem.startsWith(u8, rel_path, rule.pattern) and
                    rel_path.len > rule.pattern.len and rel_path[rule.pattern.len] == '/'))
            {
                ignored = !rule.negated;
            }
        }
        return ignored;
    }
};

/// Simple, fast glob matcher supporting `*`, `?`, and `**/` recursive directory wildcards.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "**/")) |ds_idx| {
        const prefix = pattern[0..ds_idx];
        const suffix = pattern[ds_idx + 3 ..];

        // Find every position `p_end` where `prefix` matches `text[0..p_end]`,
        // then allow `**/` to consume 0 directories (`text[p_end..]`) or 1+ directories
        // (up to any subsequent `/` in `text[p_end..]`) before matching `suffix`.
        var p_end: usize = 0;
        while (p_end <= text.len) : (p_end += 1) {
            if (prefix.len == 0 and p_end > 0) break;
            if (prefix.len == 0 or globMatch(prefix, text[0..p_end])) {
                // 0 directories consumed by `**/`
                if (globMatch(suffix, text[p_end..])) return true;
                // 1+ directories consumed by `**/`
                for (p_end..text.len) |s_idx| {
                    if (text[s_idx] == '/') {
                        if (globMatch(suffix, text[s_idx + 1 ..])) return true;
                    }
                }
            }
        }
        return false;
    }

    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or pattern[p_idx] == text[t_idx])) {
            p_idx += 1;
            t_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx) |s_idx| {
            p_idx = s_idx + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') : (p_idx += 1) {}
    return p_idx == pattern.len;
}

test "IgnoreMatcher: matches built-in VCS dirs, globs, anchored paths, and negation rules" {
    const gpa = std.testing.allocator;
    var matcher = IgnoreMatcher.init(gpa);
    defer matcher.deinit();

    try matcher.addRulesFromText(
        \\# Build artifacts and logs
        \\*.o
        \\*.log
        \\!keep.log
        \\build/
        \\/root_only.txt
    );

    try std.testing.expect(matcher.isIgnored(".vcs", true));
    try std.testing.expect(matcher.isIgnored(".vcs/db.vcs", false));
    try std.testing.expect(matcher.isIgnored(".DS_Store", false));
    try std.testing.expect(matcher.isIgnored("src/foo.o", false));
    try std.testing.expect(matcher.isIgnored("debug.log", false));
    try std.testing.expect(!matcher.isIgnored("keep.log", false));
    try std.testing.expect(matcher.isIgnored("build", true));
    try std.testing.expect(!matcher.isIgnored("build", false));
    try std.testing.expect(matcher.isIgnored("root_only.txt", false));
    try std.testing.expect(!matcher.isIgnored("sub/root_only.txt", false));
    try std.testing.expect(!matcher.isIgnored("src/main.zig", false));
}
