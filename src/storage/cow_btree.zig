//! Rodeh (2008) Top-Down Copy-on-Write (CoW) B-Tree with Lazy Refcount Shadowing & O(1) Clones.
//!
//! Implements the core algorithms from Ohad Rodeh, "B-Trees, Shadowing, and Clones" (ACM TOS 2008):
//! 1. **No Leaf Sibling Pointers**: Leaf nodes do not point to horizontal neighbors, so modifying
//!    a leaf node only shadows the `O(log_b N)` path from root to leaf.
//! 2. **Lazy Hierarchical Refcount Pushdown**:
//!    - Cloning an entire B-Tree (`cloneRoot`) for a worktree snapshot, a branch draft, or an
//!      `oplog` entry takes **O(1) time**: it simply increments `ref_count[root_page]`.
//!    - When a subsequent write traverses into a page with `ref_count > 1`, `shadowPage` allocates
//!      a fresh page copy, decrements the old page's `ref_count`, and increments the `ref_count`
//!      of the page's immediate children by 1 (`O(b)` work).
//! 3. **Top-Down Single-Pass Proactive Split**:
//!    - Full nodes (`num_keys == MAX_KEYS`) are split on the way down during `put`, guaranteeing
//!      single-pass root-to-leaf CoW mutation without parent pointers or upward backtracking.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PageId = u32;
pub const INVALID_PAGE: PageId = std.math.maxInt(PageId);

/// Minimum degree `t = 4`:
/// - `MIN_KEYS = t - 1 = 3` (except root)
/// - `MAX_KEYS = 2*t - 1 = 7`
/// - `MAX_CHILDREN = 2*t = 8`
pub const T_DEGREE: usize = 4;
pub const MIN_KEYS: usize = T_DEGREE - 1;
pub const MAX_KEYS: usize = 2 * T_DEGREE - 1;
pub const MAX_CHILDREN: usize = 2 * T_DEGREE;

pub fn CowBTree(comptime K: type, comptime V: type, comptime compareFn: fn (K, K) std.math.Order) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            is_leaf: bool = true,
            num_keys: u16 = 0,
            keys: [MAX_KEYS]K = undefined,
            values: [MAX_KEYS]V = undefined,
            children: [MAX_CHILDREN]PageId = @splat(INVALID_PAGE),
        };

        allocator: Allocator,
        pages: std.ArrayList(Node) = .empty,
        ref_counts: std.ArrayList(u32) = .empty,
        free_list: std.ArrayList(PageId) = .empty,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.pages.deinit(self.allocator);
            self.ref_counts.deinit(self.allocator);
            self.free_list.deinit(self.allocator);
        }

        /// Allocate a new page with `ref_count = 1`.
        pub fn allocPage(self: *Self, node: Node) !PageId {
            if (self.free_list.items.len > 0) {
                const pid = self.free_list.pop().?;
                self.pages.items[pid] = node;
                self.ref_counts.items[pid] = 1;
                return pid;
            }
            try self.pages.ensureUnusedCapacity(self.allocator, 1);
            try self.ref_counts.ensureUnusedCapacity(self.allocator, 1);
            const pid: PageId = @intCast(self.pages.items.len);
            self.pages.appendAssumeCapacity(node);
            self.ref_counts.appendAssumeCapacity(1);
            return pid;
        }

        /// Create a fresh empty B-Tree root.
        pub fn createEmptyRoot(self: *Self) !PageId {
            return self.allocPage(.{ .is_leaf = true, .num_keys = 0 });
        }

        /// O(1) Writable Clone (Rodeh §4): increments only the root page's reference count!
        /// Both the original root and the returned root can be mutated independently via CoW.
        pub fn cloneRoot(self: *Self, root: PageId) PageId {
            self.ref_counts.items[root] += 1;
            return root;
        }

        /// Decrement reference count of a page; if it drops to 0, recursively release children.
        pub fn decRef(self: *Self, page_id: PageId) !void {
            std.debug.assert(self.ref_counts.items[page_id] > 0);
            self.ref_counts.items[page_id] -= 1;
            if (self.ref_counts.items[page_id] == 0) {
                const node = self.pages.items[page_id];
                if (!node.is_leaf) {
                    const num_c: usize = @as(usize, node.num_keys) + 1;
                    for (0..num_c) |i| {
                        try self.decRef(node.children[i]);
                    }
                }
                try self.free_list.append(self.allocator, page_id);
            }
        }

        /// Rodeh Lazy Refcount Shadowing:
        /// - If `ref_count[page_id] == 1`, the page is exclusively owned and can be mutated in-place!
        /// - If `ref_count[page_id] > 1`, allocate a shadow copy, decrement `ref_count[page_id]`,
        ///   and push +1 refcount down to the immediate children of the copied internal node.
        fn ensureWritablePage(self: *Self, page_id: PageId) !PageId {
            const rc = self.ref_counts.items[page_id];
            std.debug.assert(rc >= 1);
            if (rc == 1) return page_id;

            const original = self.pages.items[page_id];
            if (!original.is_leaf) {
                const num_c: usize = @as(usize, original.num_keys) + 1;
                for (0..num_c) |i| {
                    self.ref_counts.items[original.children[i]] += 1;
                }
            }
            self.ref_counts.items[page_id] -= 1;
            return self.allocPage(original);
        }

        /// Point lookup `get(root, key) -> ?V`. Does not mutate or allocate any pages.
        pub fn get(self: *const Self, root: PageId, key: K) ?V {
            var curr = root;
            while (true) {
                const node = self.pages.items[curr];
                var i: usize = 0;
                const n: usize = node.num_keys;
                while (i < n and compareFn(key, node.keys[i]) == .gt) : (i += 1) {}
                if (i < n and compareFn(key, node.keys[i]) == .eq) {
                    return node.values[i];
                }
                if (node.is_leaf) return null;
                curr = node.children[i];
            }
        }

        /// Split full child `child_idx` of writable parent `parent_id`.
        /// Precondition: `parent_id` has `ref_count == 1` and `num_keys < MAX_KEYS`,
        /// and `child` has `num_keys == MAX_KEYS`.
        fn splitChild(self: *Self, parent_id: PageId, child_idx: usize) !void {
            const raw_child_id = self.pages.items[parent_id].children[child_idx];
            const left_id = try self.ensureWritablePage(raw_child_id);
            self.pages.items[parent_id].children[child_idx] = left_id;

            const left_copy = self.pages.items[left_id];
            std.debug.assert(left_copy.num_keys == MAX_KEYS);

            var right_node: Node = .{
                .is_leaf = left_copy.is_leaf,
                .num_keys = MIN_KEYS,
            };

            // Copy upper MIN_KEYS keys/values to right_node
            for (0..MIN_KEYS) |j| {
                right_node.keys[j] = left_copy.keys[j + T_DEGREE];
                right_node.values[j] = left_copy.values[j + T_DEGREE];
            }
            if (!left_copy.is_leaf) {
                for (0..T_DEGREE) |j| {
                    right_node.children[j] = left_copy.children[j + T_DEGREE];
                }
            }

            const median_key = left_copy.keys[MIN_KEYS];
            const median_val = left_copy.values[MIN_KEYS];

            const right_id = try self.allocPage(right_node);

            // Truncate left node to MIN_KEYS after `allocPage` succeeds
            self.pages.items[left_id].num_keys = MIN_KEYS;

            // Insert median_key and right_id into parent_id
            var parent = &self.pages.items[parent_id];
            const pn: usize = parent.num_keys;
            var j: usize = pn;
            while (j > child_idx) : (j -= 1) {
                parent.children[j + 1] = parent.children[j];
                parent.keys[j] = parent.keys[j - 1];
                parent.values[j] = parent.values[j - 1];
            }
            parent.children[child_idx + 1] = right_id;
            parent.keys[child_idx] = median_key;
            parent.values[child_idx] = median_val;
            parent.num_keys = @intCast(pn + 1);
        }

        /// Top-down CoW insert/upsert `put(root, key, value) -> new_root`.
        /// Any cloned snapshots sharing pages with `root` remain completely untouched!
        pub fn put(self: *Self, root: PageId, key: K, value: V) !PageId {
            try self.pages.ensureUnusedCapacity(self.allocator, 16);
            try self.ref_counts.ensureUnusedCapacity(self.allocator, 16);
            var writable_root = try self.ensureWritablePage(root);
            if (self.pages.items[writable_root].num_keys == MAX_KEYS) {
                var new_root_node: Node = .{
                    .is_leaf = false,
                    .num_keys = 0,
                };
                new_root_node.children[0] = writable_root;
                const new_root_id = try self.allocPage(new_root_node);
                try self.splitChild(new_root_id, 0);
                writable_root = new_root_id;
            }
            try self.putNonFull(writable_root, key, value);
            return writable_root;
        }

        fn putNonFull(self: *Self, page_id: PageId, key: K, value: V) !void {
            var curr = page_id;
            while (true) {
                var node = &self.pages.items[curr];
                const n: usize = node.num_keys;

                // Check if key already exists in current node (in-place update on shadowed node)
                var i: usize = 0;
                while (i < n and compareFn(key, node.keys[i]) == .gt) : (i += 1) {}
                if (i < n and compareFn(key, node.keys[i]) == .eq) {
                    node.values[i] = value;
                    return;
                }

                if (node.is_leaf) {
                    var j: usize = n;
                    while (j > i) : (j -= 1) {
                        node.keys[j] = node.keys[j - 1];
                        node.values[j] = node.values[j - 1];
                    }
                    node.keys[i] = key;
                    node.values[i] = value;
                    node.num_keys = @intCast(n + 1);
                    return;
                }

                // Internal node: check if target child is full before descending
                const child_raw = node.children[i];
                if (self.pages.items[child_raw].num_keys == MAX_KEYS) {
                    try self.splitChild(curr, i);
                    // After split, check whether key matches the promoted median or belongs right
                    const cmp_median = compareFn(key, self.pages.items[curr].keys[i]);
                    if (cmp_median == .eq) {
                        self.pages.items[curr].values[i] = value;
                        return;
                    } else if (cmp_median == .gt) {
                        i += 1;
                    }
                }

                const next_child = try self.ensureWritablePage(self.pages.items[curr].children[i]);
                self.pages.items[curr].children[i] = next_child;
                curr = next_child;
            }
        }

        /// Count total keys in the subtree rooted at `root`.
        pub fn countKeys(self: *const Self, root: PageId) usize {
            const node = self.pages.items[root];
            var total: usize = node.num_keys;
            if (!node.is_leaf) {
                const num_c: usize = @as(usize, node.num_keys) + 1;
                for (0..num_c) |i| {
                    total += self.countKeys(node.children[i]);
                }
            }
            return total;
        }

        /// Compute the height of the B-tree rooted at `root` (`0` for a leaf root).
        /// Because B-trees are height-balanced, walking `children[0]` takes $O(\log_b N)$ steps.
        pub fn getTreeHeight(self: *const Self, root: PageId) usize {
            var h: usize = 0;
            var curr = root;
            while (!self.pages.items[curr].is_leaf) {
                curr = self.pages.items[curr].children[0];
                h += 1;
            }
            return h;
        }

        pub const DiffEntry = struct {
            key: K,
            old_value: ?V,
            new_value: ?V,
        };

        pub const DiffResult = struct {
            entries: std.ArrayList(DiffEntry) = .empty,
            pages_visited: usize = 0,
            shared_subtrees_skipped: usize = 0,

            pub fn deinit(self: *DiffResult, allocator: Allocator) void {
                self.entries.deinit(allocator);
            }
        };

        const KV = struct {
            key: K,
            val: V,
        };

        /// Sublinear $O(k \log_b N)$ Snapshot Diffing (`diffRoots`, Rodeh 2008):
        /// Exploits B-tree equi-depth invariants and CoW page sharing to prune any `PageId`
        /// that appears in both `root_a` and `root_b` at the same height above the leaves in $O(1)$
        /// without visiting that page or any of its descendants!
        pub fn diffRoots(
            self: *const Self,
            allocator: Allocator,
            root_a: PageId,
            root_b: PageId,
        ) !DiffResult {
            var res: DiffResult = .{};
            errdefer res.deinit(allocator);

            if (root_a == root_b) {
                res.shared_subtrees_skipped = 1;
                return res;
            }

            var kvs_a: std.ArrayList(KV) = .empty;
            defer kvs_a.deinit(allocator);
            var kvs_b: std.ArrayList(KV) = .empty;
            defer kvs_b.deinit(allocator);

            var level_a: std.ArrayList(PageId) = .empty;
            defer level_a.deinit(allocator);
            var level_b: std.ArrayList(PageId) = .empty;
            defer level_b.deinit(allocator);

            try level_a.append(allocator, root_a);
            try level_b.append(allocator, root_b);

            var h_a = self.getTreeHeight(root_a);
            var h_b = self.getTreeHeight(root_b);

            while (h_a > h_b) : (h_a -= 1) {
                var next_a: std.ArrayList(PageId) = .empty;
                errdefer next_a.deinit(allocator);
                for (level_a.items) |pid| {
                    res.pages_visited += 1;
                    const node = self.pages.items[pid];
                    const n: usize = node.num_keys;
                    for (0..n) |i| try kvs_a.append(allocator, .{ .key = node.keys[i], .val = node.values[i] });
                    for (0..(n + 1)) |i| try next_a.append(allocator, node.children[i]);
                }
                level_a.deinit(allocator);
                level_a = next_a;
            }

            while (h_b > h_a) : (h_b -= 1) {
                var next_b: std.ArrayList(PageId) = .empty;
                errdefer next_b.deinit(allocator);
                for (level_b.items) |pid| {
                    res.pages_visited += 1;
                    const node = self.pages.items[pid];
                    const n: usize = node.num_keys;
                    for (0..n) |i| try kvs_b.append(allocator, .{ .key = node.keys[i], .val = node.values[i] });
                    for (0..(n + 1)) |i| try next_b.append(allocator, node.children[i]);
                }
                level_b.deinit(allocator);
                level_b = next_b;
            }

            // Now `h_a == h_b`: prune shared `PageId`s at each level before descending!
            while (true) {
                var next_a: std.ArrayList(PageId) = .empty;
                errdefer next_a.deinit(allocator);
                var next_b: std.ArrayList(PageId) = .empty;
                errdefer next_b.deinit(allocator);

                for (level_a.items) |pid_a| {
                    var shared = false;
                    for (level_b.items) |pid_b| {
                        if (pid_a == pid_b) {
                            shared = true;
                            break;
                        }
                    }
                    if (shared) {
                        res.shared_subtrees_skipped += 1;
                        continue;
                    }
                    res.pages_visited += 1;
                    const node = self.pages.items[pid_a];
                    const n: usize = node.num_keys;
                    for (0..n) |i| try kvs_a.append(allocator, .{ .key = node.keys[i], .val = node.values[i] });
                    if (!node.is_leaf) {
                        for (0..(n + 1)) |i| try next_a.append(allocator, node.children[i]);
                    }
                }

                for (level_b.items) |pid_b| {
                    var shared = false;
                    for (level_a.items) |pid_a| {
                        if (pid_b == pid_a) {
                            shared = true;
                            break;
                        }
                    }
                    if (shared) continue;
                    res.pages_visited += 1;
                    const node = self.pages.items[pid_b];
                    const n: usize = node.num_keys;
                    for (0..n) |i| try kvs_b.append(allocator, .{ .key = node.keys[i], .val = node.values[i] });
                    if (!node.is_leaf) {
                        for (0..(n + 1)) |i| try next_b.append(allocator, node.children[i]);
                    }
                }

                level_a.deinit(allocator);
                level_a = next_a;
                level_b.deinit(allocator);
                level_b = next_b;

                if (h_a == 0) break;
                h_a -= 1;
            }

            const SortKV = struct {
                pub fn lessThan(_: void, lhs: KV, rhs: KV) bool {
                    return compareFn(lhs.key, rhs.key) == .lt;
                }
            };
            std.mem.sort(KV, kvs_a.items, {}, SortKV.lessThan);
            std.mem.sort(KV, kvs_b.items, {}, SortKV.lessThan);

            var ia: usize = 0;
            var ib: usize = 0;
            while (ia < kvs_a.items.len or ib < kvs_b.items.len) {
                if (ia < kvs_a.items.len and ib < kvs_b.items.len) {
                    const ord = compareFn(kvs_a.items[ia].key, kvs_b.items[ib].key);
                    switch (ord) {
                        .eq => {
                            if (!std.meta.eql(kvs_a.items[ia].val, kvs_b.items[ib].val)) {
                                try res.entries.append(allocator, .{
                                    .key = kvs_a.items[ia].key,
                                    .old_value = kvs_a.items[ia].val,
                                    .new_value = kvs_b.items[ib].val,
                                });
                            }
                            ia += 1;
                            ib += 1;
                        },
                        .lt => {
                            // Key was in a non-shared page of A; check if it moved to a shared page in B
                            const b_lookup = self.get(root_b, kvs_a.items[ia].key);
                            if (b_lookup == null or !std.meta.eql(kvs_a.items[ia].val, b_lookup.?)) {
                                try res.entries.append(allocator, .{
                                    .key = kvs_a.items[ia].key,
                                    .old_value = kvs_a.items[ia].val,
                                    .new_value = b_lookup,
                                });
                            }
                            ia += 1;
                        },
                        .gt => {
                            const a_lookup = self.get(root_a, kvs_b.items[ib].key);
                            if (a_lookup == null or !std.meta.eql(a_lookup.?, kvs_b.items[ib].val)) {
                                try res.entries.append(allocator, .{
                                    .key = kvs_b.items[ib].key,
                                    .old_value = a_lookup,
                                    .new_value = kvs_b.items[ib].val,
                                });
                            }
                            ib += 1;
                        },
                    }
                } else if (ia < kvs_a.items.len) {
                    const b_lookup = self.get(root_b, kvs_a.items[ia].key);
                    if (b_lookup == null or !std.meta.eql(kvs_a.items[ia].val, b_lookup.?)) {
                        try res.entries.append(allocator, .{
                            .key = kvs_a.items[ia].key,
                            .old_value = kvs_a.items[ia].val,
                            .new_value = b_lookup,
                        });
                    }
                    ia += 1;
                } else {
                    const a_lookup = self.get(root_a, kvs_b.items[ib].key);
                    if (a_lookup == null or !std.meta.eql(a_lookup.?, kvs_b.items[ib].val)) {
                        try res.entries.append(allocator, .{
                            .key = kvs_b.items[ib].key,
                            .old_value = a_lookup,
                            .new_value = kvs_b.items[ib].val,
                        });
                    }
                    ib += 1;
                }
            }

            return res;
        }
    };
}

fn compareU64(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

test "Rodeh CoW B-Tree: O(1) writable clones and lazy refcount shadowing preserve snapshot isolation" {
    const gpa = std.testing.allocator;
    const Tree = CowBTree(u64, u64, compareU64);
    var btree = Tree.init(gpa);
    defer btree.deinit();

    var root_v1 = try btree.createEmptyRoot();
    // Insert 50 keys to force multiple levels of top-down splits
    for (0..50) |k| {
        root_v1 = try btree.put(root_v1, k, k * 10);
    }
    try std.testing.expectEqual(@as(usize, 50), btree.countKeys(root_v1));

    // O(1) clone for snapshot / worktree draft!
    const pages_before_clone = btree.pages.items.len;
    const root_clone = btree.cloneRoot(root_v1);
    try std.testing.expectEqual(pages_before_clone, btree.pages.items.len);
    try std.testing.expectEqual(@as(u32, 2), btree.ref_counts.items[root_v1]);

    // Mutate `root_clone` heavily (overwrite existing keys and insert new keys)
    var root_v2 = root_clone;
    for (0..50) |k| {
        root_v2 = try btree.put(root_v2, k, k * 100 + 7);
    }
    for (50..80) |k| {
        root_v2 = try btree.put(root_v2, k, k * 100);
    }

    // Verify `root_v1` is 100% isolated and unchanged!
    try std.testing.expectEqual(@as(usize, 50), btree.countKeys(root_v1));
    try std.testing.expectEqual(@as(usize, 80), btree.countKeys(root_v2));

    for (0..50) |k| {
        try std.testing.expectEqual(@as(?u64, k * 10), btree.get(root_v1, k));
        try std.testing.expectEqual(@as(?u64, k * 100 + 7), btree.get(root_v2, k));
    }
    try std.testing.expectEqual(@as(?u64, null), btree.get(root_v1, 60));
    try std.testing.expectEqual(@as(?u64, 6000), btree.get(root_v2, 60));
}
