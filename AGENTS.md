# AGENTS.md — Agent & Contributor Guide for `zig-vcs`

## 0. Self-Hosting Version Control Rules (Use `zig_vcs`, NOT `git`)

This repository is **self-hosted (dogfooded)** using `zig_vcs` itself. All repository history, branches, drafts, and oplog snapshots live in the single-file database at [`.vcs/db.vcs`](file:///Users/matthewsessions/Projects/zig-vcs/.vcs/db.vcs) (with ignore rules in [`.vcsignore`](file:///Users/matthewsessions/Projects/zig-vcs/.vcsignore)). There is **no `.git` directory** in the workspace root.

### Mandatory Agent Workflow for Tracking Changes
1. **Always use `./zig-out/bin/zig_vcs` (or `zig build run -- <cmd>`)** instead of `git` to inspect and commit changes in this workspace:
   ```bash
   # Check workspace status (auto-scans working tree; no 'git add' staging step exists)
   ./zig-out/bin/zig_vcs status          # or: ./zig-out/bin/zig_vcs st

   # Inspect uncommitted diffs or commit history
   ./zig-out/bin/zig_vcs diff            # unified diff vs HEAD (@)
   ./zig-out/bin/zig_vcs diff --stat     # diffstat summary
   ./zig-out/bin/zig_vcs log --oneline   # compact commit history

   # Commit changes (only after `zig build test` and `zig build prove` pass!)
   ./zig-out/bin/zig_vcs commit -m "<concise summary of verified change>"

   # Verify cryptographic (BLAKE3) & algebraic (Z[A_bot] sum=1, DAG acyclicity) integrity
   ./zig-out/bin/zig_vcs fsck
   ```
2. **Never run `git init` in the workspace root**, and never delete [`.vcs/db.vcs`](file:///Users/matthewsessions/Projects/zig-vcs/.vcs/db.vcs).
3. **Instant Atomic Recovery**: Every mutating operation in `zig_vcs` records an atomic pre-state snapshot in the single-DB oplog (`INV-6`). If an operation needs to be reverted or inspected:
   ```bash
   ./zig-out/bin/zig_vcs oplog -n 10
   ./zig-out/bin/zig_vcs undo
   ./zig-out/bin/zig_vcs redo
   ```

---

## 1. Mission & Core Philosophy

`zig-vcs` is a **formally verified, single-file, multi-worktree version control system** written in **Zig 0.17** and backed by machine-checked proofs in **Lean 4** and an explicit-state **TLA+ model checker in Zig**.

Every architectural decision is anchored in three research pillars (documented in [`ARCHITECTURE.md`](file:///Users/matthewsessions/Projects/zig-vcs/ARCHITECTURE.md) and [`ref/papers/`](file:///Users/matthewsessions/Projects/zig-vcs/ref/papers)):

1. **Pillar 1 — Per-Branch Working State & Multi-Worktree Isolation** *(De Rosso & Jackson 2013/2016 Gitless; Jujutsu)*:
   - **No staging area (`index`)**, **no `stash`**, and **no detached `HEAD`**.
   - Uncommitted changes are tracked per `(worktree_id, branch_id)` in the `drafts` table inside the single-file repository database.
   - Branch switches (`switchBranch`) and worktree closures (`closeWorktree`) are **total and non-destructive**: dirty state is automatically shelved into `drafts` and restored when returning to that branch or reopening the worktree.
2. **Pillar 2 — First-Class Algebraic Conflicts ($B + C - A$)** *(Jujutsu Merge Algebra; Kaki et al. OOPSLA 2019 MRDTs; Mimram 2013 Pushouts; Khanna, Kunal, & Pierce 2007 `diff3`)*:
   - **Never halt an operation mid-merge/mid-rebase** (`MERGE_HEAD` does not exist) and **never write `<<<<<<<` conflict markers into the artifact store** (`RepoDb.blobs`).
   - Every file path in a tree is stored as a `PathSum` in the free abelian group $\mathbb{Z}[\mathcal{A}_{\bot}]$ ($\sum c_i \cdot \mathbf{e}_{h_i}$ with $\sum c_i = 1$).
   - 3-way merge of `ours` ($B$) and `theirs` ($C$) over ancestor `base` ($A$) is $B + C - A$, combined with Pierce's anchor-separated sub-file hunk lifting ([`src/algebra/diff3_anchors.zig`](file:///Users/matthewsessions/Projects/zig-vcs/src/algebra/diff3_anchors.zig)).
   - Conflict markers are rendered lazily **only** when materializing a conflicted `PathSum` to a checkout directory on disk ([`src/worktree/materializer.zig`](file:///Users/matthewsessions/Projects/zig-vcs/src/worktree/materializer.zig)).
3. **Pillar 3 — Single-File Transactional Oplog & CoW Storage** *(D. Richard Hipp Fossil; Ohad Rodeh 2008 CoW B-Trees; Sears & Brewer OSDI 2006 Stasis)*:
   - All repository state lives in a single database file ([`.vcs/db.vcs`](file:///Users/matthewsessions/Projects/zig-vcs/.vcs/db.vcs)), split into an **enduring append-only artifact/commit store** (`blobs`, `trees`, `commits`) and a **transactional MVCC view** (`branches`, `worktrees`, `drafts`, `configs`, `stat_cache`, `oplog`, `redo_stack`).
   - Every mutating transition prepends a snapshot to `oplog` inside the same transaction, making `undo` and `redo` instant $O(1)$ pointer restorations.

---

## 2. Essential Commands & Verification Workflow

Always run the formal verification suite and unit/E2E test suite before and after making changes:

```bash
# 1. Build the production CLI binary (`./zig-out/bin/zig_vcs`)
zig build

# 2. Run Lean 4 mechanized proofs + Zig TLA+ model checker + Differential Fuzzer + HTML Visualizer
zig build prove

# 3. Run all Zig unit and E2E integration tests across all modules (under std.testing.allocator)
zig build test

# 4. Run the 1,500-step Differential Conformance Fuzzer & Torn-Write Crash Recovery harness
zig build fuzz

# 4b. Run Complex Repository CPU Profiler & macOS `/usr/bin/sample` Call-Stack Profiler
zig build bench
zig build profile

# 5. Production CLI Commands (`./zig-out/bin/zig_vcs <cmd>` or `zig build run -- <cmd>`)
./zig-out/bin/zig_vcs                                          # Live workspace overview + everyday help
./zig-out/bin/zig_vcs help [advanced | --all | <command>]      # 3-tier help system
./zig-out/bin/zig_vcs init
./zig-out/bin/zig_vcs config [list|get|set|--unset] [key] [val] # e.g. user.name, user.email, color.ui
./zig-out/bin/zig_vcs clone <src_repo> [dst_dir]
./zig-out/bin/zig_vcs remote [list|-v|add|remove|set-url] [args...]
./zig-out/bin/zig_vcs fetch [remote] [branch]
./zig-out/bin/zig_vcs pull [remote] [branch]                   # alias: up
./zig-out/bin/zig_vcs push [remote] [branch] [--force|-f]
./zig-out/bin/zig_vcs status [-s|--short] [--json] [-v] [--color] # alias: st
./zig-out/bin/zig_vcs switch <branch>                          # aliases: co, checkout
./zig-out/bin/zig_vcs branch [list|-m|-d|<name>] [--json]      # alias: br
./zig-out/bin/zig_vcs commit [-m "<message>"] [--author "<author>"] [paths...] # alias: ci
./zig-out/bin/zig_vcs amend [rev] [-m "<message>"]
./zig-out/bin/zig_vcs squash [rev] [-m "<message>"]
./zig-out/bin/zig_vcs merge <branch1> [branch2 ...] [-m "<message>"] [--author "<author>"]
./zig-out/bin/zig_vcs resolve <path> <--ours|--theirs|--base|content>
./zig-out/bin/zig_vcs rebase <branch> <onto_branch>
./zig-out/bin/zig_vcs cherry-pick <rev|A..B> [-m "<message>"]  # alias: cp
./zig-out/bin/zig_vcs backout <rev|A..B> [-m "<message>"]
./zig-out/bin/zig_vcs restore <path> [rev]
./zig-out/bin/zig_vcs show [rev[:path]] [--color]              # supports @, @-, @--, @-N, HEAD~N, c<N>
./zig-out/bin/zig_vcs mv <src> <dst>
./zig-out/bin/zig_vcs rm <path>
./zig-out/bin/zig_vcs blame <path> [rev]
./zig-out/bin/zig_vcs tag [name [rev] | -d <name>]
./zig-out/bin/zig_vcs bisect <good_rev> <bad_rev> <path> <needle>
./zig-out/bin/zig_vcs search <needle>
./zig-out/bin/zig_vcs log [-n <limit>] [--stat] [--oneline] [--json] [--color] [rev|A..B] [-- <path_prefix>]
./zig-out/bin/zig_vcs diff [--stat] [--color] [rev|A..B] [path_prefix]
./zig-out/bin/zig_vcs draft [list|show|apply|drop] [--json] [branch]
./zig-out/bin/zig_vcs fsck [--json]
./zig-out/bin/zig_vcs gc
./zig-out/bin/zig_vcs worktree [list|add|close|reopen] [--json] [args...] # alias: wt
./zig-out/bin/zig_vcs undo
./zig-out/bin/zig_vcs redo
./zig-out/bin/zig_vcs oplog [-n <limit>] [--json] | restore <index>
./zig-out/bin/zig_vcs archive <output.tar> [rev] [--prefix <dir>]
./zig-out/bin/zig_vcs git-import <fast_export_stream>
./zig-out/bin/zig_vcs git-export [output_stream_file]
```

---

## 3. Repository Layout

```text
zig-vcs/
├── .vcs/db.vcs                         # Self-hosted single-file zig_vcs database
├── .vcsignore                          # Self-hosted ignore rules (excludes .lake/, /ref/, zig-out/)
├── AGENTS.md                           # This guide
├── ARCHITECTURE.md                     # Complete 4-layer architecture & schema specification
├── build.zig                           # Zig 0.17 build graph (`prove`, `test`, `bench`, `profile`, `run` steps)
├── proofs/                             # Lean 4 Mechanized Proof Suite (`leanprover/lean4:v4.33.1`)
│   ├── lakefile.toml
│   ├── lean-toolchain
│   ├── VcsProofs.lean
│   └── VcsProofs/
│       └── Basic.lean                  # 38 machine-checked theorems (`0 sorry`)
├── src/
│   ├── main.zig                        # Production CLI entry point delegating to `src/cli.zig`
│   ├── cli.zig                         # Production CLI command dispatcher (`executeCommandInDir`)
│   ├── verify_runner.zig               # Non-installed verification/fuzz/bench runner (`zig build prove|fuzz|bench`)
│   ├── root.zig                        # Module exports & root property tests
│   ├── tla.zig                         # Generic explicit-state TLA+ BFS model checker in Zig
│   ├── vcs_model.zig                   # Formal state machines (`SafeVcsSpec`, `NaiveVcsSpec`, `FormalTreeSum`)
│   ├── visualize.zig                   # Terminal summary, Mermaid generator & HTML state explorer
│   ├── algebra/
│   │   ├── tree_sum.zig                # Multi-path `PathSum` & `TreeManifest` (`B + C - A`) in Z[A_bot]
│   │   └── diff3_anchors.zig           # Pierce (2007) unique-anchor 3-way text merger & marker renderer
│   ├── storage/
│   │   ├── repo_db.zig                 # Single-file transactional `RepoDb` (blobs, trees, commits, drafts, remotes, oplog)
│   │   ├── cow_btree.zig               # Rodeh (2008) top-down CoW B-tree with O(1) clones & lazy refcounts
│   │   ├── delta.zig                   # Fossil-style 8-byte rolling-hash byte delta compressor (`ZDL1`)
│   │   └── paged_file.zig              # 4KB shadow-paged engine with Dual-Superblock crash recovery (`ZVCSPG01`)
│   ├── worktree/
│   │   ├── materializer.zig            # Auto disk scanner (`syncWorktreeFromDisk`), `.vcs-link`, `stat_cache`
│   │   └── ignore.zig                  # `.vcsignore` / `.gitignore` & recursive `**/` glob matcher
│   ├── testing/
│   │   ├── conformance_fuzzer.zig      # Differential fuzzer & torn-write crash-fault injection harness
│   │   ├── adversarial_tests.zig       # 49 adversarial edge-case, OOM, D/F, crisscross, sync & security tests
│   │   ├── cli_e2e_tests.zig           # Exhaustive E2E test matrix covering all CLI subcommands, flags & error paths
│   │   ├── perf_profiler.zig           # Complex repo benchmark suite & macOS `/usr/bin/sample` profiler
│   │   └── git_parity_oracle.zig       # Live `git` subprocess differential parity & usability-delta oracle
│   └── interop/
│       └── git_interop.zig             # Bi-directional `git fast-export` / `git fast-import` & native `.git` remote bridge
└── ref/                                # Reference source repositories & research corpus (read-only, ignored by .vcsignore)
    ├── git/                            # Upstream Git source reference
    ├── fossil/                         # Upstream Fossil SCM source reference
    └── papers/                         # 16 primary research PDFs, HTML specs, and Fossil design wikis
```

---

## 4. Non-Negotiable Formal Invariants (`INV-1` .. `INV-6`)

Any change to `src/storage/`, `src/algebra/`, or `src/worktree/` **must** preserve all six formal invariants enforced by [`checkAllFormalInvariants`](file:///Users/matthewsessions/Projects/zig-vcs/src/testing/conformance_fuzzer.zig#L45-L92):

1. **`INV-1` (Strict Artifact & Commit Monotonicity)**:
   - `db.blobs`, `db.trees`, and `db.commits` are strictly append-only. No operation—including `undo`, `redo`, `rebase`, or `switch`—may ever delete or mutate an existing row.
2. **`INV-2` (Referential Integrity & DAG Acyclicity)**:
   - Every `branch.head_commit` and commit parent (`parent1`, `parent2`) must reference a valid `CommitId` with `parent < commit_id`.
3. **`INV-3` (Multi-Worktree Isolation)**:
   - Editing, committing, switching branches, or merging in worktree `w1` must never corrupt or overwrite the working state or branch binding of a distinct worktree `w2` (`w1 != w2`).
4. **`INV-4` (Zero Uncommitted Data Loss Across Branch Switches & Worktree Close)**:
   - Switching branches (`switchBranch`) or closing a worktree (`closeWorktree`) when `is_dirty == true` must save `working_tree_id` into `drafts[(wt_id, branch_id)]`. Switching back (or reopening) must restore that exact `TreeId`.
5. **`INV-5` (Storage Purity & Free Abelian Group Conservation)**:
   - No blob in `db.blobs` may ever contain `<<<<<<<` conflict markers (`!diff3.hasConflictMarkers(blob.bytes)`).
   - Every `PathSum` in every `TreeManifest` must have non-zero integer coefficients summing to `1` ($\sum c_i = 1$).
6. **`INV-6` (Single-Step Atomic Undo / Redo Invertibility)**:
   - Every mutating transition on `(branches, worktrees, drafts)` must call `recordOplog` prior to mutation so `undo()` followed by `redo()` is an exact identity on user state.

---

## 5. Toolchain & Coding Conventions

### Zig 0.17 Conventions
- **Entry Point & I/O**: Use `pub fn main(init: std.process.Init) !void` with `const gpa = init.gpa;` and `const io = init.io;`.
- **Filesystem Operations**: Pass `io: std.Io` to `Io.Dir.cwd().openDir(io, ...)`, `createFile(io, ...)`, `readFileAlloc(io, ...)`, and `statFile(io, ...)`.
- **Unmanaged Containers**: `std.ArrayList(T)` defaults to unmanaged in Zig 0.17 (`var list: std.ArrayList(T) = .empty; defer list.deinit(allocator);`).
- **Memory Discipline**: Always test with `std.testing.allocator` so any leak or double-free fails `zig build test` immediately.

### Lean 4 Proof Conventions (`proofs/`)
- Toolchain is pinned to `leanprover/lean4:v4.33.1` in [`proofs/lean-toolchain`](file:///Users/matthewsessions/Projects/zig-vcs/proofs/lean-toolchain).
- Never leave `sorry` or `admit` in [`proofs/VcsProofs/Basic.lean`](file:///Users/matthewsessions/Projects/zig-vcs/proofs/VcsProofs/Basic.lean).
- When adding a new VCS state transition:
  1. Model the pure transition in [`proofs/VcsProofs/Basic.lean`](file:///Users/matthewsessions/Projects/zig-vcs/proofs/VcsProofs/Basic.lean) and prove monotonicity/isolation/undo preservation.
  2. Add the action to [`src/vcs_model.zig`](file:///Users/matthewsessions/Projects/zig-vcs/src/vcs_model.zig) and [`src/testing/conformance_fuzzer.zig`](file:///Users/matthewsessions/Projects/zig-vcs/src/testing/conformance_fuzzer.zig).
  3. Verify with `zig build prove && zig build test`.

### Python & Scripting Environment
- Follow global workspace rules: never use raw `python` or `pip install`; always use `uv run python` or `uvx` if running auxiliary scripts.
