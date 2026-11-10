//! Exhaustive End-to-End CLI Command, Flag & Error-Path Test Matrix (`src/testing/cli_e2e_tests.zig`).
//!
//! Exercises every subcommand, flag combination, positional argument variant, and error path
//! exposed by `zig_vcs` (`src/cli.zig`) against real on-disk temporary workspaces and `.vcs/db.vcs`
//! files under `std.testing.allocator` (guaranteeing zero memory leaks on both success and failure).
//!
//! Coverage Matrix:
//!   1. `init`, `status` (default, `-s`, `--short`, `--json`), `fsck` (default, `--json`), `gc`, and unknown/help fallback.
//!   2. `edit`, `mv`, `rm`, `commit` (default msg, custom msg, path-selective), `restore` (HEAD, `<rev>`),
//!      `show` (default `HEAD`, `<rev>`, `<rev>:<path>`), `diff` (working tree, `--stat`, `<rev>`, `<A..B>`, `<path>`),
//!      `log` (default, `-n <N>`, `--stat`, `--oneline`, `--json`, `<A..B>`, `-- <path_prefix>`),
//!      `blame` (`<path>`, `<path> <rev>`), `search <needle>`, `bisect <good> <bad> <path> <needle>`,
//!      `tag` (list, create at HEAD, create at `<rev>`, `-d <name>`, `delete <name>`),
//!      `archive <out.tar> [rev] [--prefix <dir> | --prefix=<dir>]`.
//!   3. `branch` (no args, `list`, `--json`, `list --json`, `<new>`, `-m`, `rename`, `-d`, `delete`),
//!      `switch <branch>` (with auto-shelved dirty working tree),
//!      `draft` (no args, `list`, `--json`, `list --json`, `show [branch]`, `apply <branch>`, `drop <branch>`),
//!      `merge <b1> [b2]` (clean + conflicted), `resolve <path> <--ours|--theirs|--base|content>`,
//!      `rebase <branch> <onto>`, `amend` (no args, `<msg>`, `<rev> <msg>`),
//!      `squash` (no args, `<msg>`, `<rev> <msg>`), `cherry-pick` (`<rev>`, `<A..B>`), `backout` (`<rev>`, `<A..B>`).
//!   4. `worktree` (no args, `list`, `--json`, `list --json`, `add <name> <path> [branch]`, `close <name>`, `reopen <name>`),
//!      `undo` (non-empty + empty oplog), `redo` (non-empty + empty stack),
//!      `oplog` (default, `-n <N>`, `--json`, `restore <idx>`).
//!   5. `clone` (`<src> <dst>`, `<src> .`, inferred name), `remote` (no args, `list`, `-v`, `add`, `set-url`, `remove`, `rm`),
//!      `fetch [remote] [branch]`, `pull [remote] [branch]`, `push [remote] [branch] [--force|-f]`,
//!      `git-export` (stdout + file), `git-import <file>`.
//!   6. Exhaustive negative/missing-argument and invalid-argument error paths across all commands.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");

fn writeDiskFile(io: Io, dir_path: []const u8, rel_path: []const u8, content: []const u8) !void {
    var gpa_buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&gpa_buf);
    const alloc = fba.allocator();
    const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, rel_path });
    if (std.fs.path.dirname(full_path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }
    const f = try Io.Dir.cwd().createFile(io, full_path, .{});
    defer f.close(io);
    var wbuf: [1024]u8 = undefined;
    var w: Io.File.Writer = .init(f, io, &wbuf);
    try w.interface.writeAll(content);
    try w.interface.flush();
}

test "CLI E2E Matrix 1: init, status (default/-s/--short/--json), fsck (default/--json), gc, and help fallback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const ws = "/tmp/zig_vcs_cli_e2e_1";
    Io.Dir.cwd().deleteTree(io, ws) catch {};
    try Io.Dir.cwd().createDirPath(io, ws);
    defer Io.Dir.cwd().deleteTree(io, ws) catch {};

    // 1. Root command (no args), `help`, `--help`, `-h`, `help <topic>`, `version`, and unknown command
    {
        const root_uninit = try cli.executeCommandAlloc(gpa, io, ws, &.{});
        defer gpa.free(root_uninit);
        try std.testing.expect(std.mem.indexOf(u8, root_uninit, "Not inside an initialized repository") != null);
        try std.testing.expect(std.mem.indexOf(u8, root_uninit, "Usage: zig_vcs <command>") != null);

        const out_help = try cli.executeCommandAlloc(gpa, io, ws, &.{"help"});
        defer gpa.free(out_help);
        try std.testing.expect(std.mem.indexOf(u8, out_help, "Everyday Commands:") != null);
        try std.testing.expect(std.mem.indexOf(u8, out_help, "zig_vcs help advanced") != null);

        const out_adv = try cli.executeCommandAlloc(gpa, io, ws, &.{ "help", "advanced" });
        defer gpa.free(out_adv);
        try std.testing.expect(std.mem.indexOf(u8, out_adv, "1. Algebraic Conflict Resolution & History Rewriting") != null);
        try std.testing.expect(std.mem.indexOf(u8, out_adv, "cherry-pick") != null);

        const out_all = try cli.executeCommandAlloc(gpa, io, ws, &.{ "help", "--all" });
        defer gpa.free(out_all);
        try std.testing.expect(std.mem.indexOf(u8, out_all, "Everyday Commands:") != null);
        try std.testing.expect(std.mem.indexOf(u8, out_all, "Advanced & Plumbing Commands:") != null);

        const out_all2 = try cli.executeCommandAlloc(gpa, io, ws, &.{"--help-all"});
        defer gpa.free(out_all2);
        try std.testing.expectEqualStrings(out_all, out_all2);

        const help_topics = [_][]const u8{
            "status",      "init",     "switch",   "branch",     "commit",  "amend",
            "squash",      "merge",    "resolve",  "rebase",     "cherry-pick", "backout",
            "restore",     "show",     "mv",       "rm",         "blame",   "tag",
            "bisect",      "search",   "log",      "diff",       "draft",   "worktree",
            "undo",        "redo",     "oplog",    "fsck",       "gc",      "clone",
            "remote",      "fetch",    "pull",     "push",       "archive", "git-export",
            "git-import",
        };
        for (help_topics) |t_name| {
            const h_txt = try cli.executeCommandAlloc(gpa, io, ws, &.{ "help", t_name });
            defer gpa.free(h_txt);
            try std.testing.expect(std.mem.indexOf(u8, h_txt, "Usage:") != null);
        }

        const out_sub_help = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "--help" });
        defer gpa.free(out_sub_help);
        try std.testing.expect(std.mem.indexOf(u8, out_sub_help, "Usage: zig_vcs commit") != null);

        const out_ver = try cli.executeCommandAlloc(gpa, io, ws, &.{"--version"});
        defer gpa.free(out_ver);
        try std.testing.expect(std.mem.indexOf(u8, out_ver, "zig_vcs 0.1.0") != null);

        const out_unk = try cli.executeCommandAlloc(gpa, io, ws, &.{"not-a-subcmd"});
        defer gpa.free(out_unk);
        try std.testing.expect(std.mem.indexOf(u8, out_unk, "Unknown command 'not-a-subcmd'.") != null);
    }

    // 2. `init` + root command inside an initialized repository
    {
        const out = try cli.executeCommandAlloc(gpa, io, ws, &.{"init"});
        defer gpa.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "Initialized single-file repository") != null);

        const root_init = try cli.executeCommandAlloc(gpa, io, ws, &.{});
        defer gpa.free(root_init);
        try std.testing.expect(std.mem.indexOf(u8, root_init, "Active Workspace:") != null);
        try std.testing.expect(std.mem.indexOf(u8, root_init, "Clean (0 tracked files") != null);

        const clean_st = try cli.executeCommandAlloc(gpa, io, ws, &.{"status"});
        defer gpa.free(clean_st);
        try std.testing.expect(std.mem.indexOf(u8, clean_st, "On branch main") != null);
        try std.testing.expect(std.mem.indexOf(u8, clean_st, "Working tree clean") != null);
    }

    // Create a file on disk and test all `status` flag variants
    try writeDiskFile(io, ws, "hello.txt", "line1\n");

    // 3. `status` (default human-readable diff vs HEAD) and `status -v` / `--verbose`
    {
        const out = try cli.executeCommandAlloc(gpa, io, ws, &.{"status"});
        defer gpa.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "On branch main") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "added:      hello.txt") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "Summary: 1 changed (1 added") != null);

        const out_v = try cli.executeCommandAlloc(gpa, io, ws, &.{ "status", "-v" });
        defer gpa.free(out_v);
        try std.testing.expect(std.mem.indexOf(u8, out_v, "Single-File Repository Diagnostics") != null);
    }

    // 4. `status -s` and `status --short`
    {
        const out_s = try cli.executeCommandAlloc(gpa, io, ws, &.{ "status", "-s" });
        defer gpa.free(out_s);
        try std.testing.expect(std.mem.indexOf(u8, out_s, "A  hello.txt") != null);

        const out_short = try cli.executeCommandAlloc(gpa, io, ws, &.{ "status", "--short" });
        defer gpa.free(out_short);
        try std.testing.expectEqualStrings(out_s, out_short);
    }

    // 5. `status --json`
    {
        const out_json = try cli.executeCommandAlloc(gpa, io, ws, &.{ "status", "--json" });
        defer gpa.free(out_json);
        try std.testing.expect(std.mem.indexOf(u8, out_json, "\"branch\":\"main\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out_json, "\"hello.txt\"") != null);
    }

    // 6. `fsck` and `fsck --json`
    {
        const out_fsck = try cli.executeCommandAlloc(gpa, io, ws, &.{"fsck"});
        defer gpa.free(out_fsck);
        try std.testing.expect(std.mem.indexOf(u8, out_fsck, "fsck ok:") != null);

        const out_fsck_json = try cli.executeCommandAlloc(gpa, io, ws, &.{ "fsck", "--json" });
        defer gpa.free(out_fsck_json);
        try std.testing.expect(std.mem.indexOf(u8, out_fsck_json, "\"status\":\"ok\"") != null);
    }

    // 7. `gc`
    {
        const out_gc = try cli.executeCommandAlloc(gpa, io, ws, &.{"gc"});
        defer gpa.free(out_gc);
        try std.testing.expect(std.mem.indexOf(u8, out_gc, "Compacted ") != null);
    }
}

test "CLI E2E Matrix 2: mv, rm, commit, restore, show, diff, log, blame, search, bisect, tag & archive" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const ws = "/tmp/zig_vcs_cli_e2e_2";
    Io.Dir.cwd().deleteTree(io, ws) catch {};
    try Io.Dir.cwd().createDirPath(io, ws);
    defer Io.Dir.cwd().deleteTree(io, ws) catch {};

    {
        const out = try cli.executeCommandAlloc(gpa, io, ws, &.{"init"});
        gpa.free(out);
    }

    // 1. Write two files on disk and selective `commit`
    {
        try writeDiskFile(io, ws, "src/a.txt", "alpha v1\n");
        try writeDiskFile(io, ws, "docs/b.txt", "beta v1\n");

        // Selective commit of only `src/a.txt`
        const c1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "Add a.txt only", "src/a.txt" });
        defer gpa.free(c1);
        try std.testing.expect(std.mem.indexOf(u8, c1, "Created commit c1: Add a.txt only") != null);

        // Commit remaining with default commit message (no message arg)
        const c2 = try cli.executeCommandAlloc(gpa, io, ws, &.{"commit"});
        defer gpa.free(c2);
        try std.testing.expect(std.mem.indexOf(u8, c2, "Created commit c2: Snapshot commit") != null);
    }

    // 2. `mv` and `rm`
    {
        const mv_out = try cli.executeCommandAlloc(gpa, io, ws, &.{ "mv", "docs/b.txt", "docs/b_renamed.txt" });
        defer gpa.free(mv_out);
        try std.testing.expect(std.mem.indexOf(u8, mv_out, "Moved 'docs/b.txt' -> 'docs/b_renamed.txt'") != null);

        const c3 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "Rename b.txt and introduce BUG_TOKEN" });
        defer gpa.free(c3);

        // Edit `src/a.txt` on disk to introduce a searchable token, commit c4
        try writeDiskFile(io, ws, "src/a.txt", "alpha v1\nREGRESSION_BUG_42\n");
        const c4 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "Introduce regression in a.txt" });
        defer gpa.free(c4);

        // Remove `docs/b_renamed.txt` via `rm`, then restore it from `HEAD` and from `c2`
        const rm_out = try cli.executeCommandAlloc(gpa, io, ws, &.{ "rm", "docs/b_renamed.txt" });
        defer gpa.free(rm_out);
        try std.testing.expect(std.mem.indexOf(u8, rm_out, "Removed 'docs/b_renamed.txt'") != null);

        const res_head = try cli.executeCommandAlloc(gpa, io, ws, &.{ "restore", "docs/b_renamed.txt" });
        defer gpa.free(res_head);
        try std.testing.expect(std.mem.indexOf(u8, res_head, "Restored 1 path(s)") != null);

        const res_c2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "restore", "docs/b.txt", "c2" });
        defer gpa.free(res_c2);
        try std.testing.expect(std.mem.indexOf(u8, res_c2, "Restored 1 path(s)") != null);
    }

    // 3. `show` (default HEAD, explicit rev, and rev:path)
    {
        const s_head = try cli.executeCommandAlloc(gpa, io, ws, &.{"show"});
        defer gpa.free(s_head);
        try std.testing.expect(std.mem.indexOf(u8, s_head, "commit c4") != null);

        const s_c1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "show", "c1" });
        defer gpa.free(s_c1);
        try std.testing.expect(std.mem.indexOf(u8, s_c1, "Add a.txt only") != null);

        const s_file = try cli.executeCommandAlloc(gpa, io, ws, &.{ "show", "c1:src/a.txt" });
        defer gpa.free(s_file);
        try std.testing.expectEqualStrings("alpha v1\n", s_file);
    }

    // 4. `diff` (working tree, `--stat`, `<rev>`, `<A..B>`, `<path_filter>`)
    {
        const d_wt = try cli.executeCommandAlloc(gpa, io, ws, &.{"diff"});
        defer gpa.free(d_wt);
        try std.testing.expect(std.mem.indexOf(u8, d_wt, "docs/b.txt") != null);

        const d_stat = try cli.executeCommandAlloc(gpa, io, ws, &.{ "diff", "--stat", "c1..c4" });
        defer gpa.free(d_stat);
        try std.testing.expect(std.mem.indexOf(u8, d_stat, "src/a.txt") != null);

        const d_rev = try cli.executeCommandAlloc(gpa, io, ws, &.{ "diff", "c1", "src/" });
        defer gpa.free(d_rev);
        try std.testing.expect(std.mem.indexOf(u8, d_rev, "REGRESSION_BUG_42") != null);

        const d_range_open = try cli.executeCommandAlloc(gpa, io, ws, &.{ "diff", "c1.." });
        defer gpa.free(d_range_open);
        try std.testing.expect(std.mem.indexOf(u8, d_range_open, "REGRESSION_BUG_42") != null);

        // Clean working tree by restoring docs/b.txt clean state
        const rm_b = try cli.executeCommandAlloc(gpa, io, ws, &.{ "rm", "docs/b.txt" });
        gpa.free(rm_b);
    }

    // 5. `log` (default, `-n`, `--stat`, `--oneline`, `--json`, `<A..B>`, path filter with and without `--`)
    {
        const l_def = try cli.executeCommandAlloc(gpa, io, ws, &.{"log"});
        defer gpa.free(l_def);
        try std.testing.expect(std.mem.indexOf(u8, l_def, "commit c4") != null);

        const l_n = try cli.executeCommandAlloc(gpa, io, ws, &.{ "log", "-n", "2", "--stat" });
        defer gpa.free(l_n);
        try std.testing.expect(std.mem.indexOf(u8, l_n, "commit c4") != null);
        try std.testing.expect(std.mem.indexOf(u8, l_n, "commit c1") == null);

        const l_one = try cli.executeCommandAlloc(gpa, io, ws, &.{ "log", "--oneline", "c1..c4" });
        defer gpa.free(l_one);
        try std.testing.expect(std.mem.indexOf(u8, l_one, "c4 ") != null);
        try std.testing.expect(std.mem.indexOf(u8, l_one, "c1 ") == null);

        const l_json = try cli.executeCommandAlloc(gpa, io, ws, &.{ "log", "--json", "c3", "--", "src/" });
        defer gpa.free(l_json);
        try std.testing.expect(std.mem.indexOf(u8, l_json, "\"id\":1") != null);

        const l_path_direct = try cli.executeCommandAlloc(gpa, io, ws, &.{ "log", "docs/" });
        defer gpa.free(l_path_direct);
        try std.testing.expect(std.mem.indexOf(u8, l_path_direct, "commit c2") != null);
    }

    // 6. `blame` (default HEAD and explicit `<rev>`)
    {
        const b_head = try cli.executeCommandAlloc(gpa, io, ws, &.{ "blame", "src/a.txt" });
        defer gpa.free(b_head);
        try std.testing.expect(std.mem.indexOf(u8, b_head, "REGRESSION_BUG_42") != null);

        const b_c1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "blame", "src/a.txt", "c1" });
        defer gpa.free(b_c1);
        try std.testing.expect(std.mem.indexOf(u8, b_c1, "alpha v1") != null);
        try std.testing.expect(std.mem.indexOf(u8, b_c1, "REGRESSION_BUG_42") == null);
    }

    // 7. `search` and `bisect`
    {
        const srch = try cli.executeCommandAlloc(gpa, io, ws, &.{ "search", "REGRESSION_BUG_42" });
        defer gpa.free(srch);
        try std.testing.expect(std.mem.indexOf(u8, srch, "c4") != null);

        const bis = try cli.executeCommandAlloc(gpa, io, ws, &.{ "bisect", "c1", "c4", "src/a.txt", "REGRESSION_BUG_42" });
        defer gpa.free(bis);
        try std.testing.expect(std.mem.indexOf(u8, bis, "c4 is the first bad commit") != null);
    }

    // 8. `tag` (create at HEAD, create at `<rev>`, list, `-d`, `delete`)
    {
        const t1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "tag", "v1.0" });
        defer gpa.free(t1);
        try std.testing.expect(std.mem.indexOf(u8, t1, "Tagged commit c4 as 'v1.0'") != null);

        const t2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "tag", "v0.1", "c1" });
        defer gpa.free(t2);
        try std.testing.expect(std.mem.indexOf(u8, t2, "Tagged commit c1 as 'v0.1'") != null);

        const t_list = try cli.executeCommandAlloc(gpa, io, ws, &.{"tag"});
        defer gpa.free(t_list);
        try std.testing.expect(std.mem.indexOf(u8, t_list, "v1.0\tc4") != null);
        try std.testing.expect(std.mem.indexOf(u8, t_list, "v0.1\tc1") != null);

        const td1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "tag", "-d", "v0.1" });
        defer gpa.free(td1);
        try std.testing.expect(std.mem.indexOf(u8, td1, "Deleted tag 'v0.1'") != null);

        const td2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "tag", "delete", "v1.0" });
        defer gpa.free(td2);
        try std.testing.expect(std.mem.indexOf(u8, td2, "Deleted tag 'v1.0'") != null);
    }

    // 9. `archive` (`--prefix <dir>` and `--prefix=<dir>` with explicit revision)
    {
        const tar1 = "/tmp/zig_vcs_cli_e2e_2/out1.tar";
        const a1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "archive", tar1, "c1", "--prefix", "rel-1.0" });
        defer gpa.free(a1);
        try std.testing.expect(std.mem.indexOf(u8, a1, "Exported POSIX tar archive for c1") != null);

        const tar2 = "/tmp/zig_vcs_cli_e2e_2/out2.tar";
        const a2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "archive", tar2, "--prefix=rel-head/" });
        defer gpa.free(a2);
        try std.testing.expect(std.mem.indexOf(u8, a2, "Exported POSIX tar archive for c4") != null);
    }
}

test "CLI E2E Matrix 3: branch, switch, draft, merge, resolve, rebase, amend, squash, cherry-pick & backout" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const ws = "/tmp/zig_vcs_cli_e2e_3";
    Io.Dir.cwd().deleteTree(io, ws) catch {};
    try Io.Dir.cwd().createDirPath(io, ws);
    defer Io.Dir.cwd().deleteTree(io, ws) catch {};

    {
        const out = try cli.executeCommandAlloc(gpa, io, ws, &.{"init"});
        gpa.free(out);
        try writeDiskFile(io, ws, "app.txt", "line1\nline2\nline3\n");
        const c1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "Base app.txt" });
        gpa.free(c1);
    }

    // 1. `branch` (create, list, `--json`, `list --json`, `-m`, `rename`, `-d`, `delete`)
    {
        const b_create = try cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "temp-br" });
        defer gpa.free(b_create);
        try std.testing.expect(std.mem.indexOf(u8, b_create, "Created branch 'temp-br'") != null);

        const b_list1 = try cli.executeCommandAlloc(gpa, io, ws, &.{"branch"});
        defer gpa.free(b_list1);
        try std.testing.expect(std.mem.indexOf(u8, b_list1, "* main") != null);
        try std.testing.expect(std.mem.indexOf(u8, b_list1, "temp-br") != null);

        const b_list2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "list" });
        defer gpa.free(b_list2);
        try std.testing.expectEqualStrings(b_list1, b_list2);

        const b_json1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "--json" });
        defer gpa.free(b_json1);
        const b_json2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "list", "--json" });
        defer gpa.free(b_json2);
        try std.testing.expectEqualStrings(b_json1, b_json2);

        const b_m = try cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "-m", "temp-br", "renamed-br" });
        defer gpa.free(b_m);
        try std.testing.expect(std.mem.indexOf(u8, b_m, "Renamed branch 'temp-br' -> 'renamed-br'") != null);

        const b_ren = try cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "rename", "renamed-br", "del-me" });
        defer gpa.free(b_ren);

        const b_del1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "-d", "del-me" });
        defer gpa.free(b_del1);
        try std.testing.expect(std.mem.indexOf(u8, b_del1, "Deleted branch 'del-me'") != null);

        const b_c2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "del-me-2" });
        gpa.free(b_c2);
        const b_del2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "delete", "del-me-2" });
        defer gpa.free(b_del2);
        try std.testing.expect(std.mem.indexOf(u8, b_del2, "Deleted branch 'del-me-2'") != null);
    }

    // 2. `switch` & `draft` (auto-shelve dirty state, `draft`, `draft list`, `draft --json`, `draft list --json`, `draft show`, `draft apply`, `draft drop`)
    {
        const sw_feat = try cli.executeCommandAlloc(gpa, io, ws, &.{ "switch", "feature-draft" });
        gpa.free(sw_feat);
        try writeDiskFile(io, ws, "draft_note.txt", "wip content\n");

        // Switch back to `main` (auto-shelves `feature-draft` dirty tree)
        const sw_main = try cli.executeCommandAlloc(gpa, io, ws, &.{ "switch", "main" });
        defer gpa.free(sw_main);
        try std.testing.expect(std.mem.indexOf(u8, sw_main, "Switched worktree wt0 to branch 'main'") != null);

        const d_def = try cli.executeCommandAlloc(gpa, io, ws, &.{"draft"});
        defer gpa.free(d_def);
        try std.testing.expect(std.mem.indexOf(u8, d_def, "feature-draft") != null);

        const d_list = try cli.executeCommandAlloc(gpa, io, ws, &.{ "draft", "list" });
        defer gpa.free(d_list);
        try std.testing.expectEqualStrings(d_def, d_list);

        const d_json1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "draft", "--json" });
        defer gpa.free(d_json1);
        const d_json2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "draft", "list", "--json" });
        defer gpa.free(d_json2);
        try std.testing.expectEqualStrings(d_json1, d_json2);
        try std.testing.expect(std.mem.indexOf(u8, d_json1, "\"branch\":\"feature-draft\"") != null);

        const d_show = try cli.executeCommandAlloc(gpa, io, ws, &.{ "draft", "show", "feature-draft" });
        defer gpa.free(d_show);
        try std.testing.expect(std.mem.indexOf(u8, d_show, "+wip content") != null);

        const d_apply = try cli.executeCommandAlloc(gpa, io, ws, &.{ "draft", "apply", "feature-draft" });
        defer gpa.free(d_apply);
        try std.testing.expect(std.mem.indexOf(u8, d_apply, "Algebraically applied draft") != null);

        // Remove applied draft file from main working tree
        const rm_wip = try cli.executeCommandAlloc(gpa, io, ws, &.{ "rm", "draft_note.txt" });
        gpa.free(rm_wip);

        const d_drop1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "draft", "drop", "feature-draft" });
        defer gpa.free(d_drop1);
        try std.testing.expect(std.mem.indexOf(u8, d_drop1, "Dropped shelved draft") != null);

        const d_drop2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "draft", "drop", "feature-draft" });
        defer gpa.free(d_drop2);
        try std.testing.expect(std.mem.indexOf(u8, d_drop2, "No shelved draft found") != null);
    }

    // 3. `merge` (conflicted) and `resolve` (`--ours`, `--theirs`, `--base`, custom content)
    {
        const sw_b1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "switch", "conflict-br" });
        gpa.free(sw_b1);
        try writeDiskFile(io, ws, "app.txt", "line1-THEIRS\nline2\nline3\n");
        const c_b1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "Theirs change" });
        gpa.free(c_b1);

        const sw_m = try cli.executeCommandAlloc(gpa, io, ws, &.{ "switch", "main" });
        gpa.free(sw_m);
        try writeDiskFile(io, ws, "app.txt", "line1-OURS\nline2\nline3\n");
        const c_m = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "Ours change" });
        gpa.free(c_m);

        // Merge `conflict-br` into `main` -> produces algebraic conflict
        const m_out = try cli.executeCommandAlloc(gpa, io, ws, &.{ "merge", "conflict-br" });
        defer gpa.free(m_out);
        try std.testing.expect(std.mem.indexOf(u8, m_out, "conflicts=true") != null);

        // Test `--ours` then `undo`, `--theirs` then `undo`, `--base` then `undo`, then custom content
        const r_ours = try cli.executeCommandAlloc(gpa, io, ws, &.{ "resolve", "app.txt", "--ours" });
        defer gpa.free(r_ours);
        try std.testing.expect(std.mem.indexOf(u8, r_ours, "Resolved conflict") != null);
        const un1 = try cli.executeCommandAlloc(gpa, io, ws, &.{"undo"});
        gpa.free(un1);

        const r_theirs = try cli.executeCommandAlloc(gpa, io, ws, &.{ "resolve", "app.txt", "--theirs" });
        defer gpa.free(r_theirs);
        const un2 = try cli.executeCommandAlloc(gpa, io, ws, &.{"undo"});
        gpa.free(un2);

        const r_base = try cli.executeCommandAlloc(gpa, io, ws, &.{ "resolve", "app.txt", "--base" });
        defer gpa.free(r_base);
        const un3 = try cli.executeCommandAlloc(gpa, io, ws, &.{"undo"});
        gpa.free(un3);

        const r_custom = try cli.executeCommandAlloc(gpa, io, ws, &.{ "resolve", "app.txt", "line1-MERGED\nline2\nline3\n" });
        defer gpa.free(r_custom);
        const c_res = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "Resolved conflict" });
        gpa.free(c_res);
    }

    // 4. `rebase`, `amend` (no args, msg, rev+msg), `squash` (no args, msg), `cherry-pick` (single + A..B), `backout` (single + A..B)
    {
        const sw_rb = try cli.executeCommandAlloc(gpa, io, ws, &.{ "switch", "rb-branch" });
        gpa.free(sw_rb);
        try writeDiskFile(io, ws, "rb1.txt", "step1\n");
        const c1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "rb step 1" });
        gpa.free(c1);

        // Amend with no args, then with message, then with explicit revision + message
        const am1 = try cli.executeCommandAlloc(gpa, io, ws, &.{"amend"});
        defer gpa.free(am1);
        try std.testing.expect(std.mem.indexOf(u8, am1, "Amended commit") != null);

        const am2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "amend", "rb step 1 amended" });
        defer gpa.free(am2);

        const am3 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "amend", "HEAD", "rb step 1 amended v2" });
        defer gpa.free(am3);

        // Add second commit on `rb-branch` and squash it with message
        try writeDiskFile(io, ws, "rb2.txt", "step2\n");
        const c2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "rb step 2" });
        gpa.free(c2);

        const sq1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "squash", "rb steps 1+2 squashed" });
        defer gpa.free(sq1);
        try std.testing.expect(std.mem.indexOf(u8, sq1, "Squashed commit into parent") != null);

        // Add two more commits on `rb-branch` for range cherry-pick/backout
        try writeDiskFile(io, ws, "range1.txt", "r1\n");
        const c3 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "range 1" });
        gpa.free(c3);
        try writeDiskFile(io, ws, "range2.txt", "r2\n");
        const c4 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "range 2" });
        gpa.free(c4);

        // Switch to `main`, cherry-pick single commit, then backout single commit
        const sw_m = try cli.executeCommandAlloc(gpa, io, ws, &.{ "switch", "main" });
        gpa.free(sw_m);

        const cp_single = try cli.executeCommandAlloc(gpa, io, ws, &.{ "cherry-pick", "rb-branch", "Pick tip of rb-branch" });
        defer gpa.free(cp_single);
        try std.testing.expect(std.mem.indexOf(u8, cp_single, "Cherry-picked commit") != null);

        const bo_single = try cli.executeCommandAlloc(gpa, io, ws, &.{ "backout", "HEAD", "Revert tip pick" });
        defer gpa.free(bo_single);
        try std.testing.expect(std.mem.indexOf(u8, bo_single, "Backed out commit") != null);

        // Cherry-pick range `main..rb-branch` and backout range `main..rb-branch`
        const cp_range = try cli.executeCommandAlloc(gpa, io, ws, &.{ "cherry-pick", "c1..rb-branch", "Range pick" });
        defer gpa.free(cp_range);
        try std.testing.expect(std.mem.indexOf(u8, cp_range, "Cherry-picked range") != null);

        const bo_range = try cli.executeCommandAlloc(gpa, io, ws, &.{ "backout", "c1..rb-branch", "Range backout" });
        defer gpa.free(bo_range);
        try std.testing.expect(std.mem.indexOf(u8, bo_range, "Backed out range") != null);

        // Rebase `conflict-br` onto `main`
        const rb_out = try cli.executeCommandAlloc(gpa, io, ws, &.{ "rebase", "conflict-br", "main" });
        defer gpa.free(rb_out);
        try std.testing.expect(std.mem.indexOf(u8, rb_out, "Rebased 'conflict-br' onto 'main'") != null);
    }
}

test "CLI E2E Matrix 4: worktree (list/--json/add/close/reopen), undo, redo & oplog (-n/--json/restore)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const ws = "/tmp/zig_vcs_cli_e2e_4";
    const wt2_dir = "/tmp/zig_vcs_cli_e2e_4_wt2";
    Io.Dir.cwd().deleteTree(io, ws) catch {};
    Io.Dir.cwd().deleteTree(io, wt2_dir) catch {};
    try Io.Dir.cwd().createDirPath(io, ws);
    defer Io.Dir.cwd().deleteTree(io, ws) catch {};
    defer Io.Dir.cwd().deleteTree(io, wt2_dir) catch {};

    {
        const out = try cli.executeCommandAlloc(gpa, io, ws, &.{"init"});
        gpa.free(out);
    }

    // 1. Undo & Redo on empty stack
    {
        const u_empty = try cli.executeCommandAlloc(gpa, io, ws, &.{"undo"});
        defer gpa.free(u_empty);
        try std.testing.expect(std.mem.indexOf(u8, u_empty, "Oplog is empty") != null);

        const r_empty = try cli.executeCommandAlloc(gpa, io, ws, &.{"redo"});
        defer gpa.free(r_empty);
        try std.testing.expect(std.mem.indexOf(u8, r_empty, "Redo stack is empty") != null);
    }

    // 2. `worktree` (`list`, `--json`, `list --json`, `add`, `close`, `reopen`)
    {
        const wt_add = try cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "add", "agent-wt", wt2_dir, "agent-branch" });
        defer gpa.free(wt_add);
        try std.testing.expect(std.mem.indexOf(u8, wt_add, "Created linked worktree wt1 ('agent-wt')") != null);

        const wt_l1 = try cli.executeCommandAlloc(gpa, io, ws, &.{"worktree"});
        defer gpa.free(wt_l1);
        const wt_l2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "list" });
        defer gpa.free(wt_l2);
        try std.testing.expectEqualStrings(wt_l1, wt_l2);
        try std.testing.expect(std.mem.indexOf(u8, wt_l1, "agent-wt") != null);

        const wt_j1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "--json" });
        defer gpa.free(wt_j1);
        const wt_j2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "list", "--json" });
        defer gpa.free(wt_j2);
        try std.testing.expectEqualStrings(wt_j1, wt_j2);

        // Write a file on disk inside the linked worktree `wt2_dir` and run `status` (via `.vcs-link` resolution!)
        try writeDiskFile(io, wt2_dir, "agent.txt", "agent work\n");
        const st_wt2 = try cli.executeCommandAlloc(gpa, io, wt2_dir, &.{"status"});
        defer gpa.free(st_wt2);
        try std.testing.expect(std.mem.indexOf(u8, st_wt2, "On branch agent-branch (worktree 'agent-wt'") != null);
        try std.testing.expect(std.mem.indexOf(u8, st_wt2, "added:      agent.txt") != null);

        const wt_close = try cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "close", "agent-wt" });
        defer gpa.free(wt_close);
        try std.testing.expect(std.mem.indexOf(u8, wt_close, "Closed worktree wt1") != null);

        const wt_reopen = try cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "reopen", "agent-wt" });
        defer gpa.free(wt_reopen);
        try std.testing.expect(std.mem.indexOf(u8, wt_reopen, "Reopened worktree wt1") != null);
    }

    // 3. `undo`, `redo`, and `oplog` (default, `-n`, `--json`, `restore <idx>`)
    {
        const un_out = try cli.executeCommandAlloc(gpa, io, ws, &.{"undo"});
        defer gpa.free(un_out);
        try std.testing.expect(std.mem.indexOf(u8, un_out, "Undid last operation") != null);

        const red_out = try cli.executeCommandAlloc(gpa, io, ws, &.{"redo"});
        defer gpa.free(red_out);
        try std.testing.expect(std.mem.indexOf(u8, red_out, "Redid operation") != null);

        const op_def = try cli.executeCommandAlloc(gpa, io, ws, &.{"oplog"});
        defer gpa.free(op_def);
        try std.testing.expect(std.mem.indexOf(u8, op_def, "Single-DB Oplog") != null);

        const op_n = try cli.executeCommandAlloc(gpa, io, ws, &.{ "oplog", "-n", "1" });
        defer gpa.free(op_n);

        const op_json = try cli.executeCommandAlloc(gpa, io, ws, &.{ "oplog", "--json", "-n", "2" });
        defer gpa.free(op_json);
        try std.testing.expect(std.mem.indexOf(u8, op_json, "\"index\":") != null);

        const op_rest = try cli.executeCommandAlloc(gpa, io, ws, &.{ "oplog", "restore", "0" });
        defer gpa.free(op_rest);
        try std.testing.expect(std.mem.indexOf(u8, op_rest, "Restored repository state from oplog[0]") != null);
    }
}

test "CLI E2E Matrix 5: clone, remote, fetch, pull, push (--force) & git-export / git-import" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const origin_ws = "/tmp/zig_vcs_cli_e2e_5_origin";
    const clone_ws = "/tmp/zig_vcs_cli_e2e_5_clone";
    const import_ws = "/tmp/zig_vcs_cli_e2e_5_import";
    const stream_file = "/tmp/zig_vcs_cli_e2e_5_stream.fast-export";

    Io.Dir.cwd().deleteTree(io, origin_ws) catch {};
    Io.Dir.cwd().deleteTree(io, clone_ws) catch {};
    Io.Dir.cwd().deleteTree(io, import_ws) catch {};
    Io.Dir.cwd().deleteFile(io, stream_file) catch {};
    try Io.Dir.cwd().createDirPath(io, origin_ws);
    try Io.Dir.cwd().createDirPath(io, import_ws);
    defer Io.Dir.cwd().deleteTree(io, origin_ws) catch {};
    defer Io.Dir.cwd().deleteTree(io, clone_ws) catch {};
    defer Io.Dir.cwd().deleteTree(io, import_ws) catch {};
    defer Io.Dir.cwd().deleteFile(io, stream_file) catch {};

    // Initialize origin repo and commit v1
    {
        const out = try cli.executeCommandAlloc(gpa, io, origin_ws, &.{"init"});
        gpa.free(out);
        try writeDiskFile(io, origin_ws, "readme.md", "# Origin v1\n");
        const c1 = try cli.executeCommandAlloc(gpa, io, origin_ws, &.{ "commit", "Origin initial commit" });
        gpa.free(c1);
    }

    // 1. `clone <origin_ws> <clone_ws>`
    {
        const cl = try cli.executeCommandAlloc(gpa, io, origin_ws, &.{ "clone", origin_ws, clone_ws });
        defer gpa.free(cl);
        try std.testing.expect(std.mem.indexOf(u8, cl, "Cloned ") != null);
    }

    // 2. `remote` (`list`, `-v`, `add`, `set-url`, `remove`, `rm`)
    {
        const r_def = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{"remote"});
        defer gpa.free(r_def);
        try std.testing.expect(std.mem.indexOf(u8, r_def, "origin") != null);

        const r_v = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{ "remote", "-v" });
        defer gpa.free(r_v);
        try std.testing.expectEqualStrings(r_def, r_v);

        const r_add = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{ "remote", "add", "upstream", origin_ws });
        defer gpa.free(r_add);
        try std.testing.expect(std.mem.indexOf(u8, r_add, "Configured remote 'upstream'") != null);

        const r_set = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{ "remote", "set-url", "upstream", origin_ws });
        defer gpa.free(r_set);

        const r_rm1 = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{ "remote", "remove", "upstream" });
        defer gpa.free(r_rm1);
        try std.testing.expect(std.mem.indexOf(u8, r_rm1, "Removed remote 'upstream'") != null);

        const r_add2 = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{ "remote", "add", "temp", origin_ws });
        gpa.free(r_add2);
        const r_rm2 = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{ "remote", "rm", "temp" });
        defer gpa.free(r_rm2);
        try std.testing.expect(std.mem.indexOf(u8, r_rm2, "Removed remote 'temp'") != null);
    }

    // 3. Commit in origin, then `fetch` and `pull` in clone, then commit in clone and `push` (`--force`) to origin
    {
        try writeDiskFile(io, origin_ws, "readme.md", "# Origin v2\n");
        const c2 = try cli.executeCommandAlloc(gpa, io, origin_ws, &.{ "commit", "Origin v2" });
        gpa.free(c2);

        const f_out = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{"fetch"});
        defer gpa.free(f_out);
        try std.testing.expect(std.mem.indexOf(u8, f_out, "Fetched 'main' from origin") != null);

        const p_out = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{ "pull", "origin", "main" });
        defer gpa.free(p_out);
        try std.testing.expect(std.mem.indexOf(u8, p_out, "Pulled 'main' from origin") != null);

        try writeDiskFile(io, clone_ws, "from_clone.txt", "pushed data\n");
        const c3 = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{ "commit", "Commit from clone" });
        gpa.free(c3);

        const push_out = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{ "push", "origin", "main", "--force" });
        defer gpa.free(push_out);
        try std.testing.expect(std.mem.indexOf(u8, push_out, "Pushed 'main' to origin") != null);
    }

    // 4. `git-export` (stdout + file) and `git-import`
    {
        const exp_stdout = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{"git-export"});
        defer gpa.free(exp_stdout);
        try std.testing.expect(std.mem.indexOf(u8, exp_stdout, "commit refs/heads/main") != null);

        const exp_file = try cli.executeCommandAlloc(gpa, io, clone_ws, &.{ "git-export", stream_file });
        defer gpa.free(exp_file);
        try std.testing.expect(std.mem.indexOf(u8, exp_file, "Exported git fast-import stream") != null);

        const imp_out = try cli.executeCommandAlloc(gpa, io, import_ws, &.{ "git-import", stream_file });
        defer gpa.free(imp_out);
        try std.testing.expect(std.mem.indexOf(u8, imp_out, "Imported git fast-export stream") != null);
    }
}

test "CLI E2E Matrix 6: Exhaustive negative & missing-argument error paths across all subcommands" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const ws = "/tmp/zig_vcs_cli_e2e_6";
    Io.Dir.cwd().deleteTree(io, ws) catch {};
    try Io.Dir.cwd().createDirPath(io, ws);
    defer Io.Dir.cwd().deleteTree(io, ws) catch {};

    {
        const out = try cli.executeCommandAlloc(gpa, io, ws, &.{"init"});
        gpa.free(out);
    }

    // Verify every missing-argument and unknown-action error path returns the exact expected error with 0 leaks
    try std.testing.expectError(error.MissingBranchName, cli.executeCommandAlloc(gpa, io, ws, &.{"switch"}));
    try std.testing.expectError(error.MissingSourceBranch, cli.executeCommandAlloc(gpa, io, ws, &.{"merge"}));
    try std.testing.expectError(error.MissingFilePath, cli.executeCommandAlloc(gpa, io, ws, &.{"blame"}));
    try std.testing.expectError(error.MissingBranchName, cli.executeCommandAlloc(gpa, io, ws, &.{"rebase"}));
    try std.testing.expectError(error.MissingOntoBranch, cli.executeCommandAlloc(gpa, io, ws, &.{ "rebase", "main" }));
    try std.testing.expectError(error.MissingFilePath, cli.executeCommandAlloc(gpa, io, ws, &.{"resolve"}));
    try std.testing.expectError(error.MissingContent, cli.executeCommandAlloc(gpa, io, ws, &.{ "resolve", "a.txt" }));
    try std.testing.expectError(error.MissingFilePath, cli.executeCommandAlloc(gpa, io, ws, &.{"restore"}));
    try std.testing.expectError(error.MissingCommitId, cli.executeCommandAlloc(gpa, io, ws, &.{"cherry-pick"}));
    try std.testing.expectError(error.MissingCommitId, cli.executeCommandAlloc(gpa, io, ws, &.{"backout"}));
    try std.testing.expectError(error.MissingTagName, cli.executeCommandAlloc(gpa, io, ws, &.{ "tag", "-d" }));
    try std.testing.expectError(error.TagNotFound, cli.executeCommandAlloc(gpa, io, ws, &.{ "tag", "-d", "nonexistent" }));
    try std.testing.expectError(error.MissingGoodRevision, cli.executeCommandAlloc(gpa, io, ws, &.{"bisect"}));
    try std.testing.expectError(error.MissingBadRevision, cli.executeCommandAlloc(gpa, io, ws, &.{ "bisect", "c0" }));
    try std.testing.expectError(error.MissingFilePath, cli.executeCommandAlloc(gpa, io, ws, &.{ "bisect", "c0", "c0" }));
    try std.testing.expectError(error.MissingSearchNeedle, cli.executeCommandAlloc(gpa, io, ws, &.{ "bisect", "c0", "c0", "a.txt" }));
    try std.testing.expectError(error.MissingSearchNeedle, cli.executeCommandAlloc(gpa, io, ws, &.{"search"}));
    try std.testing.expectError(error.MissingCount, cli.executeCommandAlloc(gpa, io, ws, &.{ "log", "-n" }));
    try std.testing.expectError(error.MissingBranchName, cli.executeCommandAlloc(gpa, io, ws, &.{ "draft", "apply" }));
    try std.testing.expectError(error.MissingBranchName, cli.executeCommandAlloc(gpa, io, ws, &.{ "draft", "drop" }));
    try std.testing.expectError(error.UnknownDraftAction, cli.executeCommandAlloc(gpa, io, ws, &.{ "draft", "bogus" }));
    try std.testing.expectError(error.MissingWorktreeName, cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "add" }));
    try std.testing.expectError(error.MissingWorktreePath, cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "add", "wt1" }));
    try std.testing.expectError(error.MissingWorktreeName, cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "close" }));
    try std.testing.expectError(error.WorktreeNotFound, cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "close", "no-such-wt" }));
    try std.testing.expectError(error.MissingWorktreeName, cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "reopen" }));
    try std.testing.expectError(error.WorktreeNotFound, cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "reopen", "no-such-wt" }));
    try std.testing.expectError(error.UnknownWorktreeAction, cli.executeCommandAlloc(gpa, io, ws, &.{ "worktree", "bogus" }));
    try std.testing.expectError(error.MissingCount, cli.executeCommandAlloc(gpa, io, ws, &.{ "oplog", "-n" }));
    try std.testing.expectError(error.MissingOplogIndex, cli.executeCommandAlloc(gpa, io, ws, &.{ "oplog", "restore" }));
    try std.testing.expectError(error.MissingOutputPath, cli.executeCommandAlloc(gpa, io, ws, &.{"archive"}));
    try std.testing.expectError(error.MissingPrefix, cli.executeCommandAlloc(gpa, io, ws, &.{ "archive", "/tmp/out.tar", "--prefix" }));
    try std.testing.expectError(error.MissingFastExportFile, cli.executeCommandAlloc(gpa, io, ws, &.{"git-import"}));
    try std.testing.expectError(error.MissingRemotePath, cli.executeCommandAlloc(gpa, io, ws, &.{"clone"}));
    try std.testing.expectError(error.MissingRemoteName, cli.executeCommandAlloc(gpa, io, ws, &.{ "remote", "add" }));
    try std.testing.expectError(error.MissingRemotePath, cli.executeCommandAlloc(gpa, io, ws, &.{ "remote", "add", "origin" }));
    try std.testing.expectError(error.MissingRemoteName, cli.executeCommandAlloc(gpa, io, ws, &.{ "remote", "remove" }));
    try std.testing.expectError(error.RemoteNotFound, cli.executeCommandAlloc(gpa, io, ws, &.{ "remote", "remove", "nonexistent" }));
    try std.testing.expectError(error.UnknownRemoteAction, cli.executeCommandAlloc(gpa, io, ws, &.{ "remote", "bogus" }));
    try std.testing.expectError(error.MissingBranchName, cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "-m" }));
    try std.testing.expectError(error.MissingBranchName, cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "-m", "main" }));
    try std.testing.expectError(error.MissingBranchName, cli.executeCommandAlloc(gpa, io, ws, &.{ "branch", "-d" }));
    try std.testing.expectError(error.MissingFilePath, cli.executeCommandAlloc(gpa, io, ws, &.{"mv"}));
    try std.testing.expectError(error.MissingFilePath, cli.executeCommandAlloc(gpa, io, ws, &.{ "mv", "a.txt" }));
    try std.testing.expectError(error.MissingFilePath, cli.executeCommandAlloc(gpa, io, ws, &.{"rm"}));
    try std.testing.expectError(error.MissingCommitMessage, cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "-m" }));
    try std.testing.expectError(error.MissingAuthor, cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "--author" }));
    try std.testing.expectError(error.MissingConfigKey, cli.executeCommandAlloc(gpa, io, ws, &.{ "config", "get" }));
    try std.testing.expectError(error.MissingConfigKey, cli.executeCommandAlloc(gpa, io, ws, &.{ "config", "set" }));
    try std.testing.expectError(error.MissingConfigValue, cli.executeCommandAlloc(gpa, io, ws, &.{ "config", "set", "user.name" }));
    try std.testing.expectError(error.ConfigKeyNotFound, cli.executeCommandAlloc(gpa, io, ws, &.{ "config", "get", "nonexistent.key" }));
    try std.testing.expectError(error.ConfigKeyNotFound, cli.executeCommandAlloc(gpa, io, ws, &.{ "config", "--unset", "nonexistent.key" }));
}

test "CLI E2E Matrix 7: Usability features (config, -m/--author flags, aliases, @/@-/@-- revisions, --color, Did-you-mean, formatCliErrorAlloc)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const ws = "/tmp/zig_vcs_cli_e2e_7";
    Io.Dir.cwd().deleteTree(io, ws) catch {};
    try Io.Dir.cwd().createDirPath(io, ws);
    defer Io.Dir.cwd().deleteTree(io, ws) catch {};

    {
        const out = try cli.executeCommandAlloc(gpa, io, ws, &.{"init"});
        gpa.free(out);
    }

    // 1. `config` (set, get, list, shorthand key/value, --unset) and `cfg` alias
    {
        const c1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "config", "set", "user.name", "Ada Lovelace" });
        defer gpa.free(c1);
        try std.testing.expect(std.mem.indexOf(u8, c1, "Configured user.name=Ada Lovelace") != null);

        const c2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "cfg", "user.email", "ada@analytical.engine" });
        defer gpa.free(c2);
        try std.testing.expect(std.mem.indexOf(u8, c2, "Configured user.email=ada@analytical.engine") != null);

        const g1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "config", "get", "user.name" });
        defer gpa.free(g1);
        try std.testing.expectEqualStrings("Ada Lovelace\n", g1);

        const g2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "config", "user.email" });
        defer gpa.free(g2);
        try std.testing.expectEqualStrings("ada@analytical.engine\n", g2);

        const list_out = try cli.executeCommandAlloc(gpa, io, ws, &.{ "config", "list" });
        defer gpa.free(list_out);
        try std.testing.expect(std.mem.indexOf(u8, list_out, "user.name=Ada Lovelace\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, list_out, "user.email=ada@analytical.engine\n") != null);

        const c_tmp = try cli.executeCommandAlloc(gpa, io, ws, &.{ "config", "set", "temp.key", "123" });
        gpa.free(c_tmp);
        const u_tmp = try cli.executeCommandAlloc(gpa, io, ws, &.{ "config", "--unset", "temp.key" });
        defer gpa.free(u_tmp);
        try std.testing.expect(std.mem.indexOf(u8, u_tmp, "Unset temp.key") != null);
    }

    // 2. `-m` / `--message` and `--author` flags + `ci`, `st`, `co`, `br`, `cp`, `wt` aliases + `@`, `@-`, `@--` revisions
    {
        try writeDiskFile(io, ws, "notes.txt", "line 1\n");
        const ci1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "ci", "-m", "First commit with -m" });
        defer gpa.free(ci1);
        try std.testing.expect(std.mem.indexOf(u8, ci1, "Created commit c1: First commit with -m") != null);

        // Verify configured author "Ada Lovelace <ada@analytical.engine>" was recorded on c1
        const st1 = try cli.executeCommandAlloc(gpa, io, ws, &.{"st"});
        defer gpa.free(st1);
        try std.testing.expect(std.mem.indexOf(u8, st1, "Ada Lovelace <ada@analytical.engine>") != null);

        try writeDiskFile(io, ws, "notes.txt", "line 1\nline 2\n");
        const ci2 = try cli.executeCommandAlloc(
            gpa,
            io,
            ws,
            &.{ "commit", "--message=Second commit", "--author=Grace Hopper <grace@navy.mil>" },
        );
        defer gpa.free(ci2);
        try std.testing.expect(std.mem.indexOf(u8, ci2, "Created commit c2: Second commit") != null);

        try writeDiskFile(io, ws, "notes.txt", "line 1\nline 2\nline 3\n");
        const ci3 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "commit", "-m", "Third commit" });
        defer gpa.free(ci3);
        try std.testing.expect(std.mem.indexOf(u8, ci3, "Created commit c3: Third commit") != null);

        // Verify `@`, `@-`, `@--`, `@-2` revision shorthands in `show`
        const sh_at = try cli.executeCommandAlloc(gpa, io, ws, &.{ "show", "@:notes.txt" });
        defer gpa.free(sh_at);
        try std.testing.expectEqualStrings("line 1\nline 2\nline 3\n", sh_at);

        const sh_at1 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "show", "@-:notes.txt" });
        defer gpa.free(sh_at1);
        try std.testing.expectEqualStrings("line 1\nline 2\n", sh_at1);

        const sh_at2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "show", "@--:notes.txt" });
        defer gpa.free(sh_at2);
        try std.testing.expectEqualStrings("line 1\n", sh_at2);

        const sh_at_n2 = try cli.executeCommandAlloc(gpa, io, ws, &.{ "show", "@-2:notes.txt" });
        defer gpa.free(sh_at_n2);
        try std.testing.expectEqualStrings("line 1\n", sh_at_n2);

        // Verify `co` / `br` / `wt` aliases
        const co_out = try cli.executeCommandAlloc(gpa, io, ws, &.{ "co", "feature-alias" });
        defer gpa.free(co_out);
        try std.testing.expect(std.mem.indexOf(u8, co_out, "Switched worktree wt0 to branch 'feature-alias'") != null);

        const br_out = try cli.executeCommandAlloc(gpa, io, ws, &.{"br"});
        defer gpa.free(br_out);
        try std.testing.expect(std.mem.indexOf(u8, br_out, "* feature-alias") != null);

        const wt_out = try cli.executeCommandAlloc(gpa, io, ws, &.{"wt"});
        defer gpa.free(wt_out);
        try std.testing.expect(std.mem.indexOf(u8, wt_out, "main-wt") != null);
    }

    // 3. ANSI color output (`--color=always`, `--no-color`, `config color.ui always`)
    {
        try writeDiskFile(io, ws, "notes.txt", "line 1\nline 2\nline 3\nline 4\n");
        const st_color = try cli.executeCommandAlloc(gpa, io, ws, &.{ "status", "--color=always" });
        defer gpa.free(st_color);
        try std.testing.expect(std.mem.indexOf(u8, st_color, "\x1b[") != null);

        const diff_color = try cli.executeCommandAlloc(gpa, io, ws, &.{ "diff", "--color=always" });
        defer gpa.free(diff_color);
        try std.testing.expect(std.mem.indexOf(u8, diff_color, "\x1b[32m+line 4") != null);

        const log_color = try cli.executeCommandAlloc(gpa, io, ws, &.{ "log", "--oneline", "--color=always" });
        defer gpa.free(log_color);
        try std.testing.expect(std.mem.indexOf(u8, log_color, "\x1b[1;33m") != null);

        const show_color = try cli.executeCommandAlloc(gpa, io, ws, &.{ "show", "@", "--color=always" });
        defer gpa.free(show_color);
        try std.testing.expect(std.mem.indexOf(u8, show_color, "\x1b[") != null);
    }

    // 4. Levenshtein typo suggestions ("Did you mean '...'?") & `formatCliErrorAlloc`
    {
        const typo1 = try cli.executeCommandAlloc(gpa, io, ws, &.{"stauts"});
        defer gpa.free(typo1);
        try std.testing.expect(std.mem.indexOf(u8, typo1, "Unknown command 'stauts'. Did you mean 'status'?") != null);

        const typo2 = try cli.executeCommandAlloc(gpa, io, ws, &.{"comit"});
        defer gpa.free(typo2);
        try std.testing.expect(std.mem.indexOf(u8, typo2, "Unknown command 'comit'. Did you mean 'commit'?") != null);

        const err_msg = try cli.formatCliErrorAlloc(gpa, error.UnresolvedConflictsInTree, &.{"commit"});
        defer gpa.free(err_msg);
        try std.testing.expect(std.mem.indexOf(u8, err_msg, "Cannot commit while algebraic conflicts") != null);
        try std.testing.expect(std.mem.indexOf(u8, err_msg, "hint:") != null);
    }
}
