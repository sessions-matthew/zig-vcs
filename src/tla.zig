//! A Zig-native TLA+/TLC-inspired Explicit-State Model Checker.
//!
//! Given a specification `Spec` defining:
//! - `State`: Value type representing the complete system + ghost state
//! - `Action`: Enum/tagged-union of non-deterministic next-state actions
//! - `init() State`: Initial state predicate (`Init`)
//! - `allActions() []const Action`: Universe of actions (`Next`)
//! - `enabled(State, Action) bool`: Precondition guard for an action
//! - `next(State, Action) State`: Deterministic transition function for an enabled action
//! - `invariants`: Slice of named safety predicates (`[]Invariant`)
//!
//! `ModelChecker(Spec)` explores the reachable state graph via Breadth-First Search (BFS),
//! checks all invariants at every state, detects deadlocks, records the full state-transition
//! graph for visualization, and reconstructs minimal counterexample traces on failure.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Invariant(comptime State: type) type {
    return struct {
        name: []const u8,
        description: []const u8,
        check: *const fn (State) bool,
    };
}

pub const CheckOptions = struct {
    max_states: usize = 5000,
    max_depth: u32 = 12,
    check_deadlocks: bool = true,
};

pub fn ModelChecker(comptime Spec: type) type {
    return struct {
        const Self = @This();
        pub const State = Spec.State;
        pub const Action = Spec.Action;

        pub const StateNode = struct {
            id: u32,
            state: State,
            depth: u32,
            parent_id: ?u32,
            via_action: ?Action,
        };

        pub const TransitionEdge = struct {
            from_id: u32,
            to_id: u32,
            action: Action,
        };

        pub const Violation = struct {
            invariant_name: []const u8,
            invariant_description: []const u8,
            violating_state_id: u32,
            is_deadlock: bool = false,
            /// Minimal path of state IDs from Init (index 0) to `violating_state_id`.
            trace_state_ids: []u32,
        };

        pub const CheckResult = struct {
            allocator: Allocator,
            nodes: std.ArrayList(StateNode),
            edges: std.ArrayList(TransitionEdge),
            max_depth_reached: u32,
            transitions_explored: usize,
            violation: ?Violation,

            pub fn deinit(self: *CheckResult) void {
                if (self.violation) |v| {
                    self.allocator.free(v.trace_state_ids);
                }
                self.nodes.deinit(self.allocator);
                self.edges.deinit(self.allocator);
            }
        };

        pub fn check(allocator: Allocator, options: CheckOptions) !CheckResult {
            var nodes: std.ArrayList(StateNode) = .empty;
            errdefer nodes.deinit(allocator);

            var edges: std.ArrayList(TransitionEdge) = .empty;
            errdefer edges.deinit(allocator);

            var seen: std.AutoHashMapUnmanaged(State, u32) = .empty;
            defer seen.deinit(allocator);

            const initial_state = Spec.init();
            try nodes.append(allocator, .{
                .id = 0,
                .state = initial_state,
                .depth = 0,
                .parent_id = null,
                .via_action = null,
            });
            try seen.put(allocator, initial_state, 0);

            // Check invariants on initial state
            for (Spec.invariants) |inv| {
                if (!inv.check(initial_state)) {
                    const trace = try reconstructTrace(allocator, nodes.items, 0);
                    return .{
                        .allocator = allocator,
                        .nodes = nodes,
                        .edges = edges,
                        .max_depth_reached = 0,
                        .transitions_explored = 0,
                        .violation = .{
                            .invariant_name = inv.name,
                            .invariant_description = inv.description,
                            .violating_state_id = 0,
                            .trace_state_ids = trace,
                        },
                    };
                }
            }

            var queue_idx: usize = 0;
            var max_depth_reached: u32 = 0;
            var transitions_explored: usize = 0;
            const actions = Spec.allActions();

            while (queue_idx < nodes.items.len) : (queue_idx += 1) {
                const current = nodes.items[queue_idx];
                if (current.depth > max_depth_reached) {
                    max_depth_reached = current.depth;
                }
                if (current.depth >= options.max_depth) {
                    continue;
                }

                var enabled_count: usize = 0;
                for (actions) |action| {
                    if (!Spec.enabled(current.state, action)) continue;
                    enabled_count += 1;
                    transitions_explored += 1;

                    const next_state = Spec.next(current.state, action);
                    const gop = try seen.getOrPut(allocator, next_state);
                    const target_id: u32 = if (gop.found_existing)
                        gop.value_ptr.*
                    else blk: {
                        const new_id: u32 = @intCast(nodes.items.len);
                        gop.value_ptr.* = new_id;
                        try nodes.append(allocator, .{
                            .id = new_id,
                            .state = next_state,
                            .depth = current.depth + 1,
                            .parent_id = current.id,
                            .via_action = action,
                        });
                        break :blk new_id;
                    };

                    try edges.append(allocator, .{
                        .from_id = current.id,
                        .to_id = target_id,
                        .action = action,
                    });

                    // If newly discovered state, verify all TLA+ invariants
                    if (!gop.found_existing) {
                        for (Spec.invariants) |inv| {
                            if (!inv.check(next_state)) {
                                const trace = try reconstructTrace(allocator, nodes.items, target_id);
                                return .{
                                    .allocator = allocator,
                                    .nodes = nodes,
                                    .edges = edges,
                                    .max_depth_reached = @max(max_depth_reached, current.depth + 1),
                                    .transitions_explored = transitions_explored,
                                    .violation = .{
                                        .invariant_name = inv.name,
                                        .invariant_description = inv.description,
                                        .violating_state_id = target_id,
                                        .trace_state_ids = trace,
                                    },
                                };
                            }
                        }

                        if (nodes.items.len >= options.max_states) {
                            return .{
                                .allocator = allocator,
                                .nodes = nodes,
                                .edges = edges,
                                .max_depth_reached = @max(max_depth_reached, current.depth + 1),
                                .transitions_explored = transitions_explored,
                                .violation = null,
                            };
                        }
                    }
                }

                if (options.check_deadlocks and enabled_count == 0) {
                    const trace = try reconstructTrace(allocator, nodes.items, current.id);
                    return .{
                        .allocator = allocator,
                        .nodes = nodes,
                        .edges = edges,
                        .max_depth_reached = max_depth_reached,
                        .transitions_explored = transitions_explored,
                        .violation = .{
                            .invariant_name = "DeadlockFreedom",
                            .invariant_description = "At least one VCS action must be enabled in every reachable state",
                            .violating_state_id = current.id,
                            .is_deadlock = true,
                            .trace_state_ids = trace,
                        },
                    };
                }
            }

            return .{
                .allocator = allocator,
                .nodes = nodes,
                .edges = edges,
                .max_depth_reached = max_depth_reached,
                .transitions_explored = transitions_explored,
                .violation = null,
            };
        }

        fn reconstructTrace(allocator: Allocator, nodes: []const StateNode, target_id: u32) ![]u32 {
            var rev: std.ArrayList(u32) = .empty;
            defer rev.deinit(allocator);

            var curr_opt: ?u32 = target_id;
            while (curr_opt) |cid| {
                try rev.append(allocator, cid);
                curr_opt = nodes[cid].parent_id;
            }

            const trace = try allocator.alloc(u32, rev.items.len);
            for (rev.items, 0..) |id, i| {
                trace[rev.items.len - 1 - i] = id;
            }
            return trace;
        }
    };
}
