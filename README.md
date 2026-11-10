# `zig-vcs` — Formally Verified, Single-File, Multi-Worktree Version Control System

`zig-vcs` is a high-performance, single-file version control system written in **Zig 0.17** and backed by **38 machine-checked theorems in Lean 4** (`0 sorry`), an **explicit-state TLA+ model checker in Zig**, and a **differential conformance & crash-recovery fuzzer**.

It combines the single-file operational simplicity of **Fossil** with the concept-aligned ergonomics of **Gitless / Jujutsu** and a first-class **free abelian merge algebra ($\mathbb{Z}[\mathcal{A}_{\bot}]$)**—while remaining 100% interoperable with **Git** and **GitHub**.

---

## Why `zig-vcs`? (The Three Architectural Pillars)

### 1. Per-Branch Working State & Multi-Worktree Isolation *(De Rosso & Jackson 2013/2016 Gitless; Jujutsu)*
- **No staging area (`git add`)**, **no `git stash`**, and **no detached `HEAD`**.
- Working directories are scanned automatically using an `mtime`/`size` `stat_cache` and `.vcsignore` / `.gitignore` rules.
- Uncommitted changes belong to `(worktree_id, branch_id)` inside the single-file `.vcs/db.vcs` database.
- **Total Branch Switching (`INV-4`)**: `zig_vcs switch <branch>` and `zig_vcs worktree close` **never** fail on a dirty working tree and **never** overwrite uncommitted work—dirty state is automatically shelved into the single-DB `drafts` table and restored when switching back.

### 2. First-Class Algebraic Conflicts ($B + C - A$) *(Jujutsu Merge Algebra; Kaki et al. OOPSLA 2019 MRDTs; Mimram 2013 Pushouts; Khanna, Kunal, & Pierce 2007 `diff3`)*
- **Never halts mid-merge or mid-rebase**: There is no `MERGE_HEAD` or broken "in-between" repository state.
- **Pure Artifact Store (`INV-5`)**: Conflict markers (`<<<<<<<`) are **never** stored inside `db.blobs`. Every file path in a tree is represented as a formal linear combination (`PathSum`) in the free abelian group $\mathbb{Z}[\mathcal{A}_{\bot}]$ ($\sum c_i \cdot \mathbf{e}_{h_i}$ with $\sum c_i = 1$).
- **3-Way & Octopus Merge**: Merging `ours` ($B$) and `theirs` ($C$) over common ancestor `base` ($A$) computes $B + C - A$, combined with Pierce's unique-anchor sub-file `diff3` hunk merger.
- **Algebraic Cancellation**: Rebasing a conflicted branch onto the side that caused the conflict—or backing out a conflicted merge commit—automatically cancels opposite terms ($(B + C - A) + A - C = B$) back to a clean file without manual intervention.

### 3. Single-File Transactional Oplog & CoW Storage *(D. Richard Hipp Fossil; Ohad Rodeh 2008 CoW B-Trees; Sears & Brewer OSDI 2006 Stasis)*
- **Single-File Repository (`.vcs/db.vcs`)**: All blobs (BLAKE3-addressed + `ZDL1` rolling-hash delta compressed), trees, commits, branches, worktrees, shelved drafts, tags, remotes, config, and the operation log live in one file.
- **4KB Shadow-Paged Crash Immunity**: Uses a Dual-Superblock (`Slot A` / `Slot B`) copy-on-write paging engine (`ZVCSPG01`) verified against torn writes and power-loss faults.
- **Instant $O(1)$ Undo & Redo (`INV-6`)**: Every mutating command records an atomic pre-state snapshot in the single-DB `oplog`, making `zig_vcs undo`, `zig_vcs redo`, and `zig_vcs oplog restore <N>` instant pointer restorations.

---

## Quick Start

### Build from Source

Requires **Zig 0.17.0** (and optionally **Lean 4 `v4.33.1`** to re-check the mechanized proof suite in `proofs/`):

```bash
# Build the production CLI binary (./zig-out/bin/zig_vcs)
zig build

# Run all unit and end-to-end CLI tests
zig build test

# Run Lean 4 proofs + Zig TLA+ model checker + Differential Fuzzer + HTML State Explorer
zig build prove
```

### Everyday Workflow

```bash
# 1. Initialize a single-file repository (.vcs/db.vcs) and configure author identity
zig_vcs init
zig_vcs config set user.name "Ada Lovelace"
zig_vcs config set user.email "ada@analytical.engine"

# 2. Check workspace status & diff (auto-tracked — no 'git add' staging step needed)
zig_vcs status                 # alias: zig_vcs st
zig_vcs diff                   # unified diff vs HEAD (@)

# 3. Commit all (or specific) changed paths
zig_vcs commit -m "Initial implementation"           # alias: zig_vcs ci
zig_vcs commit -m "Update parser only" src/parser.zig

# 4. Switch branches freely (uncommitted edits are auto-shelved and restored)
zig_vcs switch feature-x       # aliases: zig_vcs co, zig_vcs checkout
# ... edit files ...
zig_vcs switch main            # feature-x edits are safely shelved in .vcs/db.vcs

# 5. Merge branches algebraically (B + C - A)
zig_vcs merge feature-x

# 6. Inspect history or undo/redo any operation in O(1)
zig_vcs log --oneline
zig_vcs show @-                # inspect parent of HEAD (@, @-, @--, @-N, HEAD~N, c<N>)
zig_vcs undo
zig_vcs redo
```

### Cloning & Syncing with GitHub / Git Repositories

`zig_vcs` natively clones, fetches, pulls, and pushes to/from both `.vcs` repositories and Git remotes (`https://github.com/...`, `git@github.com:...`, or local `.git` directories):

```bash
# Clone directly from GitHub into a single-file .vcs workspace
zig_vcs clone https://github.com/<owner>/<repo>.git

# Or attach a GitHub remote to an existing zig_vcs repository and push/pull
zig_vcs remote add origin git@github.com:<owner>/<repo>.git
zig_vcs push origin main
zig_vcs pull origin main       # alias: zig_vcs up
```

---

## CLI Command Reference

Run `zig_vcs` (inside any workspace for a live status overview), `zig_vcs help advanced`, `zig_vcs help --all`, or `zig_vcs <command> --help`.

| Category | Command | Description |
| :--- | :--- | :--- |
| **Start & Config** | `zig_vcs init` | Initialize single-file repository at `.vcs/db.vcs` |
| | `zig_vcs clone <src> [dst]` | Clone `.vcs` or `.git` (local/GitHub) repository |
| | `zig_vcs config [list\|get\|set\|--unset] [k] [v]` | Manage repository config (`user.name`, `user.email`, `color.ui`) |
| **Working Tree** | `zig_vcs status [-s] [--json] [-v] [--color]` | Auto-scan worktree & show changes, conflicts, and drafts (`st`) |
| | `zig_vcs diff [--stat] [--color] [rev\|A..B] [path]` | Unified diff (`@@ -l,c +l,c @@`) or diffstat |
| | `zig_vcs commit [-m "<msg>"] [--author "..."] [paths...]` | Commit working tree changes (`ci`) |
| | `zig_vcs restore <path> [rev]` | Restore file or directory prefix from `HEAD` or `<rev>` |
| | `zig_vcs mv <src> <dst>` / `zig_vcs rm <path>` | Move/rename or remove tracked file |
| **Branches & Merge** | `zig_vcs switch <branch>` | Switch branch with automatic draft shelving/restoration (`co`) |
| | `zig_vcs branch [list\|-m\|-d\|<name>] [--json]` | List, create, rename, or delete branches (`br`) |
| | `zig_vcs merge <b1> [b2 ...] [-m "<msg>"]` | 3-way or octopus algebraic merge ($B + C - A$ + Pierce `diff3`) |
| | `zig_vcs resolve <path> <--ours\|--theirs\|--base\|text>` | Collapse conflicted `PathSum` to a clean basis term |
| **History Rewriting** | `zig_vcs rebase <branch> <onto>` | Rebase multi-commit chain via $B + C - A$ |
| | `zig_vcs amend [rev] [-m "<msg>"]` | Amend commit & automatically cascade-rebase all descendants |
| | `zig_vcs squash [rev] [-m "<msg>"]` | Squash commit into parent & cascade-rebase all descendants |
| | `zig_vcs cherry-pick <rev\|A..B> [-m "<msg>"]` | Forward-port commit or range ($T_{\text{ours}} + T_B - T_A$, `cp`) |
| | `zig_vcs backout <rev\|A..B> [-m "<msg>"]` | Revert commit or range ($T_{\text{ours}} + T_A - T_B$) |
| **Inspection & Search** | `zig_vcs log [-n N] [--stat] [--oneline] [--json] [A..B]` | Inspect commit DAG history |
| | `zig_vcs show [rev[:path]] [--color]` | Show commit diff or exact file content at `<rev>:<path>` |
| | `zig_vcs blame <path> [rev]` | Line-by-line commit provenance & conflict-aware blame |
| | `zig_vcs search <needle>` | Pickaxe search across all historical commits & blobs |
| | `zig_vcs bisect <good> <bad> <path> <needle>` | Zero-checkout $O(\log N)$ binary search across commit DAG |
| | `zig_vcs tag [name [rev] \| -d <name>]` | List, create/update, or delete transactional tags |
| **Worktrees & Drafts** | `zig_vcs worktree [list\|add\|close\|reopen] ...` | Manage multiple isolated worktrees sharing `.vcs/db.vcs` (`wt`) |
| | `zig_vcs draft [list\|show\|apply\|drop] [branch]` | Inspect, algebraically apply, or drop shelved branch drafts |
| **Oplog & Remotes** | `zig_vcs undo` / `zig_vcs redo` | Instant $O(1)$ atomic undo/redo via single-DB oplog |
| | `zig_vcs oplog [-n N] [--json] \| restore <N>` | View operation log or jump directly to `oplog[N]` |
| | `zig_vcs remote [list\|-v\|add\|set-url\|rm]` | Manage named remote repositories |
| | `zig_vcs fetch` / `zig_vcs pull` / `zig_vcs push` | Synchronize with `.vcs` or native `.git` / GitHub remotes |
| **Maintenance** | `zig_vcs fsck [--json]` | Verify BLAKE3 hashes, DAG acyclicity & $\mathbb{Z}[\mathcal{A}_{\bot}]$ invariants |
| | `zig_vcs gc` | Compact 4KB shadow-paged DB image & reclaim inactive pages |
| | `zig_vcs archive <out.tar> [rev] [--prefix <dir>]` | Export revision to deterministic POSIX `ustar` `.tar` archive |
| | `zig_vcs git-export` / `zig_vcs git-import` | Bi-directional `git fast-export` / `git fast-import` stream bridge |

---

## Formal Verification & Testing Suite

`zig-vcs` enforces six non-negotiable formal invariants (`INV-1` through `INV-6`, documented in [`ARCHITECTURE.md`](ARCHITECTURE.md) and [`AGENTS.md`](AGENTS.md)):

1. **`INV-1` (Strict Artifact & Commit Monotonicity)**: `blobs`, `trees`, and `commits` are strictly append-only across all operations.
2. **`INV-2` (Referential Integrity & DAG Acyclicity)**: Every branch head and commit parent references a valid commit with $\text{parent} < \text{commit\_id}$.
3. **`INV-3` (Multi-Worktree Isolation)**: Operations in worktree $w_1$ never corrupt or overwrite a distinct worktree $w_2$ ($w_1 \neq w_2$).
4. **`INV-4` (Zero Uncommitted Data Loss)**: Dirty worktree state is preserved across `switch` and `worktree close` in `drafts[(wt_id, branch_id)]`.
5. **`INV-5` (Storage Purity & Free Abelian Group Conservation)**: `db.blobs` never contains conflict markers (`<<<<<<<`), and every `PathSum` satisfies $\sum c_i = 1$ in $\mathbb{Z}[\mathcal{A}_{\bot}]$.
6. **`INV-6` (Single-Step Atomic Undo / Redo Invertibility)**: Every mutating transition records an atomic oplog snapshot so `undo` $\circ$ `redo` is an exact identity on user state.

| Verification Command | Description |
| :--- | :--- |
| `zig build prove` | Runs all 38 Lean 4 theorems (`proofs/VcsProofs/Basic.lean`), the Zig explicit-state TLA+ BFS model checker (`SafeVcsSpec` vs `NaiveVcsSpec`), the 1,000-step Differential Conformance Fuzzer, and generates `zig-out/vcs-model-explorer.html` |
| `zig build test` | Runs all unit tests, the 49 adversarial edge-case/OOM/security tests (`src/testing/adversarial_tests.zig`), the live `git` subprocess differential parity oracle (`src/testing/git_parity_oracle.zig`), and the exhaustive CLI E2E test matrix (`src/testing/cli_e2e_tests.zig`) under `std.testing.allocator` |
| `zig build fuzz` | Runs the 1,500-step randomized differential conformance fuzzer and 150 torn-write power-loss crash recovery fault injections |
| `zig build bench` | Runs the complex repository benchmark suite (500 files, 118 commits) and real-world repository profile (`ref/fossil`, 988 files / ~37 MB) |

---

## Research Foundations & Academic Citations

Every subsystem and formal proof in `zig-vcs` is grounded in peer-reviewed version control, programming languages, and storage systems literature:

### 1. Concept Design & Per-Branch Working State (Pillar 1)
- **Santiago Perez De Rosso and Daniel Jackson (2013)**, *"What's Wrong with Git? A Conceptual Design Analysis"*, in **ACM Onward! 2013**, pp. 37–52.
  - Identifies the conceptual flaws of Git's staging area (`index`), `stash`, and non-total branch switching that cause silent uncommitted data loss—motivating `zig-vcs`'s staging-free auto-tracked worktrees and per-`(worktree_id, branch_id)` `drafts` table (`INV-4`).
- **Santiago Perez De Rosso and Daniel Jackson (2016)**, *"Purposes, Concepts, Misfits, and a Redesign of Git"*, in **ACM OOPSLA 2016**, pp. 292–310.
  - Formalizes **Gitless** and 1-to-1 concept-aligned version control commands where uncommitted changes are part of the branch state rather than global checkout state.

### 2. Algebraic Conflicts, Mergeable Types & Patch Theory (Pillar 2)
- **Sanjeev Khanna, Keshav Kunal, and Benjamin C. Pierce (2007)**, *"A Formal Investigation of `diff3`"*, in **FSTTCS 2007** (LNCS vol. 4855), pp. 485–496.
  - Proves when 3-way text merge (`diff3`) is well-behaved via **monotonic unique anchors** separating modified regions—implemented directly in [`src/algebra/diff3_anchors.zig`](src/algebra/diff3_anchors.zig).
- **Samuel Mimram and Cinzia Di Giusto (2013)**, *"A Categorical Theory of Patches"*, in **Electronic Notes in Theoretical Computer Science (MFPS XXIX)**, vol. 298, pp. 283–307 (and the **Pijul** patch theory specification).
  - Models merges as categorical pushouts so conflicts are first-class mathematical objects rather than ad-hoc text markers.
- **Carlo Angiuli, Edward Morehouse, Daniel R. Licata, and Robert Harper (2014)**, *"Homotopical Patch Theory"*, in **ACM ICFP 2014**, pp. 243–256.
  - Establishes algebraic laws (commutativity, associativity, and inverse cancellation) for patch/revision spaces.
- **Gowtham Kaki, Swarn Priya, KC Sivaramakrishnan, and Suresh Jagannathan (2019)**, *"Mergeable Replicated Data Types (MRDTs)"*, in **ACM OOPSLA 2019**, Article 154.
  - Formalizes relational 3-way merge via invertible algebraic representations over lowest common ancestors (LCAs).
- **Martin von Zweigbergk et al.**, *"Jujutsu (`jj`) — First-Class Conflicts & Tree Algebra"*.
  - Inspires `zig-vcs`'s representation of every path (`PathSum`) and tree (`TreeManifest`) in the free abelian group $\mathbb{Z}[\mathcal{A}_{\bot}]$ ($\sum c_i = 1$) where 3-way merge is $B + C - A$, rebase is $(B + C - A) + D - C = B + D - A$, and conflict markers are never stored in `db.blobs` (`INV-5`, [`src/algebra/tree_sum.zig`](src/algebra/tree_sum.zig)).

### 3. Mechanized Verification of Version Control Systems
- **Wouter Swierstra and Andres Löh (2014)**, *"The Semantics of Version Control"*, in **ACM Onward! 2014**, pp. 43–54.
- **Wouter Swierstra (2017)**, *"A Verified Implementation of a Version Control System"*, Utrecht University Technical Report.
  - Guides our mechanized **Lean 4** proof suite ([`proofs/VcsProofs/Basic.lean`](proofs/VcsProofs/Basic.lean), 38 theorems with `0 sorry`) and explicit-state **TLA+ model checker** ([`src/tla.zig`](src/tla.zig), [`src/vcs_model.zig`](src/vcs_model.zig)).

### 4. Single-File Transactional Storage, CoW B-Trees & Crash Recovery (Pillar 3)
- **D. Richard Hipp**, *"Fossil SCM: Thoughts On The Design Of The Fossil DVCS (`fossil_theory1.wiki`), Technical Overview (`fossil_tech_overview.wiki`), and File Format (`fossil_fileformat.wiki`)"*.
  - Inspires the separation of the enduring content-addressed artifact store from the mutable relational index inside a single `.vcs/db.vcs` database file, as well as the 8-byte rolling-hash byte-delta compressor (`ZDL1`, [`src/storage/delta.zig`](src/storage/delta.zig))—while fixing Fossil's transient `.fslckout` worktree limitation by storing `worktrees`, `drafts`, and `oplog` inside the primary repository file.
- **Ohad Rodeh (2008)**, *"B-trees, Shadowing, and Clones"*, in **ACM Transactions on Storage (TOS)**, vol. 3, no. 4, Article 2.
  - Provides the top-down copy-on-write (CoW) B-tree algorithm with $O(1)$ tree cloning and lazy reference counting implemented in [`src/storage/cow_btree.zig`](src/storage/cow_btree.zig).
- **Russell Sears and Eric Brewer (2006)**, *"Stasis: Flexible Transactional Storage"*, in **USENIX OSDI 2006**, pp. 29–44.
  - Informs our 4KB shadow-paged storage engine (`ZVCSPG01`) with Dual-Superblock (`Slot A` / `Slot B`) atomic commit and torn-write crash recovery ([`src/storage/paged_file.zig`](src/storage/paged_file.zig)).

---

## License

Released under the [MIT License](LICENSE).
