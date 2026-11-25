# zig-vcs

`zig-vcs` is a version control system written in Zig 0.17 that stores an entire repository (blobs, trees, commits, branches, worktrees, uncommitted drafts, tags, remotes, and the operation log) in a single `.vcs/db.vcs` file.

Core state transitions and merge laws are checked by 38 theorems in Lean 4 ([`proofs/VcsProofs/Basic.lean`](proofs/VcsProofs/Basic.lean)), a bounded explicit-state model checker ([`src/tla.zig`](src/tla.zig), [`src/vcs_model.zig`](src/vcs_model.zig)), and a differential conformance and crash-recovery fuzzer ([`src/testing/conformance_fuzzer.zig`](src/testing/conformance_fuzzer.zig)). It interoperates with Git and GitHub remotes via `git fast-export` / `git fast-import`.

## Design

### Working state belongs to branches
There is no staging area (`git add`), no `stash`, and no detached `HEAD`. Working directories are scanned automatically using an `mtime`/`size` stat cache and `.vcsignore` / `.gitignore` rules.

Uncommitted changes are tracked per `(worktree_id, branch_id)` in `.vcs/db.vcs`. Switching branches (`zig_vcs switch`) or closing a worktree (`zig_vcs worktree close`) on a dirty tree saves the working state to the `drafts` table and restores it when you switch back or reopen the worktree. Multiple worktrees can attach to the same `.vcs/db.vcs` file without interfering with each other.

### Algebraic conflicts
Merges and rebases never stop mid-operation (`MERGE_HEAD` does not exist), and `<<<<<<<` conflict markers are never written into stored blobs. Each path in a tree is stored as a formal integer linear combination of content hashes ($\sum c_i \cdot h_i$ with $\sum c_i = 1$).

A 3-way merge of `ours` ($B$) and `theirs` ($C$) over common ancestor `base` ($A$) computes $B + C - A$, combined with unique-anchor 3-way line merging ([`src/algebra/diff3_anchors.zig`](src/algebra/diff3_anchors.zig)). If all hunks between unique anchors resolve cleanly, the merged file collapses to a single blob hash; otherwise the structured conflict sum is stored in the tree and rendered as diff3 markers only when materialized to disk. Rebasing a conflicted commit onto the branch that caused the conflict, or backing out a conflicted merge, cancels opposite terms algebraically ($(B + C - A) + A - C = B$).

### Single-file storage and undo log
Repository state lives in `.vcs/db.vcs` on a 4 KiB shadow-paged, dual-superblock storage engine ([`src/storage/paged_file.zig`](src/storage/paged_file.zig)) with BLAKE3 content addressing and rolling-hash byte-delta compression ([`src/storage/delta.zig`](src/storage/delta.zig)). Artifacts and commits are append-only. Every mutating command snapshots `(branches, worktrees, drafts, tags, remotes)` into the operation log inside the same transaction, so `zig_vcs undo`, `zig_vcs redo`, and `zig_vcs oplog restore <N>` restore prior repository state in one step.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the storage layout and formal invariants (`INV-1` through `INV-6`).

## Build

Requires Zig `0.17.0`. Re-checking the Lean proofs in `proofs/` also requires Lean 4 (`leanprover/lean4:v4.33.1`).

```bash
zig build        # build ./zig-out/bin/zig_vcs
zig build test   # unit, adversarial, git parity, and CLI integration tests
zig build prove  # Lean 4 proofs + TLA+ model checker + conformance fuzzer
```

## Usage

```bash
zig_vcs init
zig_vcs config set user.name "Jane Doe"
zig_vcs config set user.email "jane@example.com"

zig_vcs status                 # auto-scans working tree (alias: st)
zig_vcs diff                   # unified diff against HEAD (@)
zig_vcs commit -m "Initial import"
zig_vcs commit -m "Parser fix" src/parser.zig

zig_vcs switch feature-x       # dirty edits on current branch are shelved automatically
zig_vcs switch main
zig_vcs merge feature-x

zig_vcs log --oneline
zig_vcs show @-                # supports @, @-, @-N, HEAD~N, c<N>, tags, and rev:path
zig_vcs undo
zig_vcs redo
```

### Git and GitHub remotes

`zig_vcs` can clone, fetch, pull, and push against `.vcs` repositories, local `.git` repositories, and GitHub URLs (`https://` or `git@`):

```bash
zig_vcs clone https://github.com/<owner>/<repo>.git

zig_vcs remote add origin git@github.com:<owner>/<repo>.git
zig_vcs push origin main
zig_vcs pull origin main
```

## Commands

Run `zig_vcs` with no arguments inside a workspace for a status summary, `zig_vcs help --all` for all commands, or `zig_vcs <command> --help` for command-specific flags.

| Command | Description |
| :--- | :--- |
| `init` | Initialize `.vcs/db.vcs` in the current directory |
| `clone <src> [dst]` | Clone a `.vcs` or `.git` (local or remote) repository |
| `config [list\|get\|set\|--unset] [k] [v]` | Read or update repository config (`user.name`, `user.email`, `color.ui`) |
| `status [-s] [--json] [-v] [--color]` | Scan worktree and show changes, conflicts, and drafts (`st`) |
| `diff [--stat] [--color] [rev\|A..B] [path]` | Unified diff or diffstat |
| `commit [-m "<msg>"] [--author "..."] [paths...]` | Commit all or selected paths (`ci`) |
| `restore <path> [rev]` | Restore a file or directory prefix from `HEAD` or `<rev>` |
| `mv <src> <dst>` / `rm <path>` | Move/rename or remove a tracked file |
| `switch <branch>` | Switch branches, shelving and restoring uncommitted drafts (`co`) |
| `branch [list\|-m\|-d\|<name>] [--json]` | List, create, rename, or delete branches (`br`) |
| `merge <b1> [b2 ...] [-m "<msg>"]` | 3-way or octopus merge ($B + C - A$ with anchor `diff3`) |
| `resolve <path> <--ours\|--theirs\|--base\|text>` | Resolve a conflicted path to a single clean version |
| `rebase <branch> <onto>` | Rebase a branch onto another branch |
| `amend [rev] [-m "<msg>"]` | Amend a commit and rebase its descendants |
| `squash [rev] [-m "<msg>"]` | Squash a commit into its parent and rebase its descendants |
| `cherry-pick <rev\|A..B> [-m "<msg>"]` | Apply a commit or range onto the current branch (`cp`) |
| `backout <rev\|A..B> [-m "<msg>"]` | Revert a commit or range |
| `log [-n N] [--stat] [--oneline] [--json] [A..B]` | Show commit history |
| `show [rev[:path]] [--color]` | Show a commit diff or file contents at `<rev>:<path>` |
| `blame <path> [rev]` | Show per-line commit provenance |
| `search <needle>` | Search commit messages and historical file contents |
| `bisect <good> <bad> <path> <needle>` | Binary search commit history without checking out trees |
| `tag [name [rev] \| -d <name>]` | List, create, move, or delete tags |
| `worktree [list\|add\|close\|reopen] ...` | Manage multiple worktrees sharing `.vcs/db.vcs` (`wt`) |
| `draft [list\|show\|apply\|drop] [branch]` | Inspect, apply, or drop shelved branch drafts |
| `undo` / `redo` | Undo or redo the last repository operation |
| `oplog [-n N] [--json] \| restore <N>` | Inspect the operation log or restore `oplog[N]` |
| `remote [list\|-v\|add\|set-url\|rm]` | Manage named remotes |
| `fetch` / `pull` / `push` | Sync with `.vcs` or Git remotes (`pull` alias: `up`) |
| `fsck [--json]` | Verify BLAKE3 hashes, DAG acyclicity, and tree invariants |
| `gc` | Compact `.vcs/db.vcs` and reclaim inactive shadow pages |
| `archive <out.tar> [rev] [--prefix <dir>]` | Export a commit tree as a POSIX `ustar` `.tar` archive |
| `git-export` / `git-import` | Export or import a `git fast-export` stream |

## Verification & Benchmarks

| Command | What it runs |
| :--- | :--- |
| `zig build test` | Unit tests, adversarial/OOM/security tests (`src/testing/adversarial_tests.zig`), live `git` parity tests (`src/testing/git_parity_oracle.zig`), and CLI end-to-end tests (`src/testing/cli_e2e_tests.zig`) under `std.testing.allocator` |
| `zig build prove` | Lean 4 theorems (`proofs/VcsProofs/Basic.lean`), explicit-state model checker (`SafeVcsSpec` vs `NaiveVcsSpec`), 1,000-step conformance fuzzer, and HTML state explorer (`zig-out/vcs-model-explorer.html`) |
| `zig build fuzz` | 1,500-step randomized differential conformance fuzzer and 150 torn-write crash recovery fault injections |
| `zig build bench` | Multi-branch / multi-worktree repository benchmark suite (`src/testing/perf_profiler.zig`) |

## References

- Santiago Perez De Rosso and Daniel Jackson, *"What's Wrong with Git? A Conceptual Design Analysis"* (Onward! 2013) and *"Purposes, Concepts, Misfits, and a Redesign of Git"* (OOPSLA 2016).
- Martin von Zweigbergk et al., *Jujutsu (`jj`)* conflict and tree algebra documentation.
- Sanjeev Khanna, Keshav Kunal, and Benjamin C. Pierce, *"A Formal Investigation of `diff3`"* (FSTTCS 2007).
- Samuel Mimram and Cinzia Di Giusto, *"A Categorical Theory of Patches"* (MFPS 2013).
- Carlo Angiuli, Edward Morehouse, Daniel R. Licata, and Robert Harper, *"Homotopical Patch Theory"* (ICFP 2014).
- Gowtham Kaki, Swarn Priya, KC Sivaramakrishnan, and Suresh Jagannathan, *"Mergeable Replicated Data Types"* (OOPSLA 2019).
- Wouter Swierstra and Andres Löh, *"The Semantics of Version Control"* (Onward! 2014); Wouter Swierstra, *"A Verified Implementation of a Version Control System"* (2017).
- D. Richard Hipp, *Fossil SCM Design & File Format Notes*.
- Ohad Rodeh, *"B-trees, Shadowing, and Clones"* (ACM TOS 2008).
- Russell Sears and Eric Brewer, *"Stasis: Flexible Transactional Storage"* (OSDI 2006).

## Acknowledgments

Built with Gemini in Google Antigravity.

## License

[MIT](LICENSE)
