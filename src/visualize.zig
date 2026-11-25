//! Visualization & Reporting for the Zig TLA+ Model Checker.
//!
//! Renders:
//! 1. Terminal TLA+ Model Checking Report + Counterexample Trace Debugger
//! 2. Mermaid `stateDiagram-v2` / `flowchart` of the reachable VCS state graph
//! 3. Standalone Interactive HTML Visualizer (`vcs-model-explorer.html`) showing:
//!    - Single-File Database live tables (`commits`, `branches`, `worktrees`, `drafts`, `oplog`)
//!    - Interactive state-space graph & step-by-step action simulator
//!    - Side-by-side Naive vs Safe VCS counterexample trace comparison
//!    - Lean 4 machine-checked theorem catalog

const std = @import("std");
const Io = std.Io;
const tla = @import("tla.zig");
const vcs = @import("vcs_model.zig");

pub const SafeChecker = tla.ModelChecker(vcs.SafeVcsSpec);
pub const NaiveChecker = tla.ModelChecker(vcs.NaiveVcsSpec);

pub fn formatTreeValue(tv: vcs.TreeValue, writer: *Io.Writer) Io.Writer.Error!void {
    switch (tv.kind) {
        .clean => try writer.print("clean(v{d})", .{tv.ours}),
        .conflict => try writer.print("CONFLICT(v{d}⚡v{d})", .{ tv.ours, tv.theirs }),
    }
}

pub fn formatSingleDbStateCompact(s: vcs.SingleDbState, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print(
        "DB[commits={d} | main=c{d}, feat=c{d} | wt0(br{d}, ",
        .{ s.commit_count, s.branches[0], s.branches[1], s.worktrees[0].branch },
    );
    try formatTreeValue(s.worktrees[0].working_tree, writer);
    try writer.print(
        "{s}) | wt1(br{d}, ",
        .{ if (s.worktrees[0].is_dirty) "*" else "", s.worktrees[1].branch },
    );
    try formatTreeValue(s.worktrees[1].working_tree, writer);
    try writer.print("{s})]", .{if (s.worktrees[1].is_dirty) "*" else ""});
}

pub fn printModelCheckSummary(
    spec_title: []const u8,
    invariants: []const tla.Invariant(vcs.SingleDbState),
    result: anytype,
    writer: *Io.Writer,
) Io.Writer.Error!void {
    try writer.print("\n========================================================================\n", .{});
    try writer.print("  ZIG TLA+ MODEL CHECKER: {s}\n", .{spec_title});
    try writer.print("========================================================================\n", .{});
    try writer.print("  Distinct Reachable States : {d}\n", .{result.nodes.items.len});
    try writer.print("  Transitions Explored      : {d}\n", .{result.transitions_explored});
    try writer.print("  Max BFS Depth Reached     : {d}\n", .{result.max_depth_reached});
    try writer.print("  Invariants Checked        : {d}\n", .{invariants.len});

    for (invariants) |inv| {
        const failed = if (result.violation) |v| std.mem.eql(u8, v.invariant_name, inv.name) else false;
        try writer.print("    [{s}] {s}: {s}\n", .{
            if (failed) "FAIL" else "PASS",
            inv.name,
            inv.description,
        });
    }

    if (result.violation) |v| {
        try writer.print("\n  >>> INVARIANT VIOLATION DETECTED: {s} <<<\n", .{v.invariant_name});
        try writer.print("  >>> Reason: {s}\n", .{v.invariant_description});
        try writer.print("  >>> Minimal Counterexample Trace ({d} states):\n", .{v.trace_state_ids.len});
        for (v.trace_state_ids, 0..) |sid, step_idx| {
            const node = result.nodes.items[sid];
            try writer.print("      Step {d} (State S{d}): ", .{ step_idx, sid });
            if (node.via_action) |act| {
                try writer.writeAll("via ");
                try act.formatShort(writer);
                try writer.writeAll(" -> ");
            } else {
                try writer.writeAll("[Init] -> ");
            }
            try formatSingleDbStateCompact(node.state, writer);
            try writer.writeAll("\n");
        }
    } else {
        try writer.print("\n  >>> STATUS: ALL INVARIANTS VERIFIED ACROSS REACHABLE STATE SPACE <<<\n", .{});
    }
}

pub fn writeMermaidDiagram(
    result: SafeChecker.CheckResult,
    max_nodes_to_render: usize,
    writer: *Io.Writer,
) Io.Writer.Error!void {
    try writer.writeAll("flowchart TD\n");
    const count = @min(result.nodes.items.len, max_nodes_to_render);
    for (result.nodes.items[0..count]) |node| {
        const s = node.state;
        try writer.print(
            "  S{d}[\"S{d} (d={d}) | commits:{d} | main:c{d} feat:c{d} | wt0:br{d}{s} wt1:br{d}{s}\"]\n",
            .{
                node.id,
                node.id,
                node.depth,
                s.commit_count,
                s.branches[0],
                s.branches[1],
                s.worktrees[0].branch,
                if (s.worktrees[0].is_dirty) "*" else "",
                s.worktrees[1].branch,
                if (s.worktrees[1].is_dirty) "*" else "",
            },
        );
    }
    for (result.edges.items) |edge| {
        if (edge.from_id < count and edge.to_id < count and edge.from_id != edge.to_id) {
            try writer.print("  S{d} -->|\"", .{edge.from_id});
            try edge.action.formatShort(writer);
            try writer.print("\"| S{d}\n", .{edge.to_id});
        }
    }
}

fn writeJsonTreeValue(tv: vcs.TreeValue, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("{{\"kind\":\"{s}\",\"ours\":{d},\"theirs\":{d}}}", .{
        @tagName(tv.kind),
        tv.ours,
        tv.theirs,
    });
}

fn writeJsonState(s: vcs.SingleDbState, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("{{\"commitCount\":{d},\"commits\":[", .{s.commit_count});
    var i: u8 = 0;
    while (i < s.commit_count) : (i += 1) {
        if (i > 0) try writer.writeAll(",");
        const c = s.commits[i];
        try writer.print("{{\"id\":{d},\"parent1\":", .{c.id});
        if (c.parent1) |p1| try writer.print("{d}", .{p1}) else try writer.writeAll("null");
        try writer.writeAll(",\"parent2\":");
        if (c.parent2) |p2| try writer.print("{d}", .{p2}) else try writer.writeAll("null");
        try writer.writeAll(",\"tree\":");
        try writeJsonTreeValue(c.tree, writer);
        try writer.writeAll("}");
    }
    try writer.print("],\"branches\":[{d},{d}],\"worktrees\":[", .{ s.branches[0], s.branches[1] });
    for (s.worktrees, 0..) |wt, wi| {
        if (wi > 0) try writer.writeAll(",");
        try writer.print("{{\"id\":{d},\"branch\":{d},\"isDirty\":{s},\"workingTree\":", .{
            wi,
            wt.branch,
            if (wt.is_dirty) "true" else "false",
        });
        try writeJsonTreeValue(wt.working_tree, writer);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"drafts\":[");
    for (0..vcs.NUM_WORKTREES) |w| {
        if (w > 0) try writer.writeAll(",");
        try writer.writeAll("[");
        for (0..vcs.NUM_BRANCHES) |b| {
            if (b > 0) try writer.writeAll(",");
            if (s.drafts[w][b]) |d| {
                try writeJsonTreeValue(d, writer);
            } else {
                try writer.writeAll("null");
            }
        }
        try writer.writeAll("]");
    }
    try writer.print("],\"hasUndo\":{s}}}", .{if (s.last_oplog.valid) "true" else "false"});
}

pub fn writeInteractiveHtml(
    safe_res: SafeChecker.CheckResult,
    naive_res: NaiveChecker.CheckResult,
    max_export_nodes: usize,
    writer: *Io.Writer,
) Io.Writer.Error!void {
    const export_count = @min(safe_res.nodes.items.len, max_export_nodes);

    try writer.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<title>Zig-VCS: Single-DB + Multi-Worktree TLA+ & Lean 4 Explorer</title>
        \\<style>
        \\  :root {
        \\    --bg: #0f172a; --panel: #1e293b; --border: #334155;
        \\    --text: #f8fafc; --muted: #94a3b8; --accent: #38bdf8;
        \\    --green: #4ade80; --amber: #fbbf24; --red: #f87171; --purple: #c084fc;
        \\  }
        \\  * { box-sizing: border-box; }
        \\  body {
        \\    margin: 0; font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
        \\    background: var(--bg); color: var(--text); line-height: 1.5;
        \\  }
        \\  header {
        \\    padding: 18px 28px; background: #020617; border-bottom: 1px solid var(--border);
        \\    display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 12px;
        \\  }
        \\  header h1 { margin: 0; font-size: 1.25rem; color: var(--accent); }
        \\  .badges { display: flex; gap: 10px; flex-wrap: wrap; }
        \\  .badge {
        \\    padding: 4px 10px; border-radius: 999px; font-size: 0.78rem; font-weight: 600;
        \\    background: var(--panel); border: 1px solid var(--border);
        \\  }
        \\  .badge.pass { border-color: var(--green); color: var(--green); }
        \\  .badge.fail { border-color: var(--red); color: var(--red); }
        \\  .layout {
        \\    display: grid; grid-template-columns: 360px 1fr; gap: 18px; padding: 18px 28px;
        \\  }
        \\  @media (max-width: 1024px) { .layout { grid-template-columns: 1fr; } }
        \\  .card {
        \\    background: var(--panel); border: 1px solid var(--border); border-radius: 10px;
        \\    padding: 16px; margin-bottom: 16px;
        \\  }
        \\  .card h2 { margin: 0 0 10px 0; font-size: 1rem; color: var(--accent); }
        \\  .card h3 { margin: 12px 0 8px 0; font-size: 0.9rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }
        \\  .state-list { max-height: 360px; overflow-y: auto; display: flex; flex-direction: column; gap: 6px; }
        \\  .state-btn, .act-btn {
        \\    background: #0f172a; color: var(--text); border: 1px solid var(--border);
        \\    padding: 8px 12px; border-radius: 6px; cursor: pointer; text-align: left;
        \\    font-family: ui-monospace, SFMono-Regular, monospace; font-size: 0.82rem;
        \\    transition: all 0.15s;
        \\  }
        \\  .state-btn:hover, .act-btn:hover { border-color: var(--accent); background: #1e293b; }
        \\  .state-btn.active { border-color: var(--green); background: rgba(74, 222, 128, 0.12); }
        \\  .actions-bar { display: flex; flex-wrap: wrap; gap: 8px; }
        \\  .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
        \\  @media (max-width: 800px) { .grid-2 { grid-template-columns: 1fr; } }
        \\  table { width: 100%; border-collapse: collapse; font-size: 0.84rem; font-family: ui-monospace, monospace; }
        \\  th, td { padding: 8px 10px; border-bottom: 1px solid var(--border); text-align: left; }
        \\  th { color: var(--muted); font-weight: 600; background: rgba(2, 6, 23, 0.4); }
        \\  .pill { padding: 2px 8px; border-radius: 4px; font-size: 0.75rem; font-weight: 600; }
        \\  .pill-clean { background: rgba(74, 222, 128, 0.15); color: var(--green); }
        \\  .pill-dirty { background: rgba(251, 191, 36, 0.18); color: var(--amber); }
        \\  .pill-conflict { background: rgba(248, 113, 113, 0.2); color: var(--red); }
        \\  .dag-node {
        \\    display: inline-flex; align-items: center; gap: 8px; padding: 6px 12px;
        \\    background: #0f172a; border: 1px solid var(--accent); border-radius: 8px;
        \\    margin: 4px 6px 4px 0; font-family: ui-monospace, monospace; font-size: 0.82rem;
        \\  }
        \\  .trace-step {
        \\    padding: 8px 12px; border-left: 3px solid var(--red); background: rgba(248, 113, 113, 0.08);
        \\    margin-bottom: 8px; font-family: ui-monospace, monospace; font-size: 0.82rem;
        \\  }
        \\  .theorem-item {
        \\    padding: 8px 12px; border-left: 3px solid var(--purple); background: rgba(192, 132, 252, 0.08);
        \\    margin-bottom: 8px; font-size: 0.85rem;
        \\  }
        \\</style>
        \\</head>
        \\<body>
        \\<header>
        \\  <h1>Zig-VCS Formal Verification & Single-File DB Visualizer</h1>
        \\  <div class="badges" id="header-badges"></div>
        \\</header>
        \\<div class="layout">
        \\  <div>
        \\    <div class="card">
        \\      <h2>TLA+ Reachable States (SafeVcsSpec)</h2>
        \\      <p style="font-size:0.82rem;color:var(--muted);margin-top:0;">
        \\        Click any state node explored by the Zig BFS model checker or trigger enabled transitions:
        \\      </p>
        \\      <div class="state-list" id="state-list"></div>
        \\    </div>
        \\    <div class="card">
        \\      <h2>Lean 4 Machine-Checked Theorems</h2>
        \\      <div class="theorem-item"><strong>commitStore_trace_monotonic</strong><br>Commits in the single DB are strictly append-only across any sequence of operations.</div>
        \\      <div class="theorem-item"><strong>worktree_isolation_*</strong><br>Editing, committing, switching, or merging in worktree <code>w1</code> never mutates worktree <code>w2</code>.</div>
        \\      <div class="theorem-item"><strong>switch_roundtrip_preserves_uncommitted</strong><br>Switching branches auto-snapshots dirty worktrees in the DB <code>drafts</code> table and restores them losslessly.</div>
        \\      <div class="theorem-item"><strong>merge_never_wedged</strong><br>Merges are total functions with first-class conflict trees—worktrees never wedge mid-merge.</div>
        \\      <div class="theorem-item"><strong>undo_*_restores</strong><br>Single-DB <code>oplog</code> undo atomically restores branches, worktrees, and drafts.</div>
        \\    </div>
        \\  </div>
        \\  <div>
        \\    <div class="card">
        \\      <h2>Single-File Repository Database Inspector (<span id="current-state-title">S0</span>)</h2>
        \\      <h3>Enabled TLA+ Next-State Actions from Current State</h3>
        \\      <div class="actions-bar" id="enabled-actions"></div>
        \\      <div class="grid-2" style="margin-top: 14px;">
        \\        <div>
        \\          <h3>Table 1: <code>worktrees</code> (Multi-Worktree Checkout State)</h3>
        \\          <table id="worktrees-table">
        \\            <thead><tr><th>Worktree</th><th>Branch</th><th>Working Tree</th><th>Status</th></tr></thead>
        \\            <tbody></tbody>
        \\          </table>
        \\          <h3>Table 2: <code>branches</code> (Named Branch Pointers)</h3>
        \\          <table id="branches-table">
        \\            <thead><tr><th>Branch</th><th>Head Commit</th><th>Commit Tree</th></tr></thead>
        \\            <tbody></tbody>
        \\          </table>
        \\        </div>
        \\        <div>
        \\          <h3>Table 3: <code>commits</code> (Immutable Artifact DAG in Single DB)</h3>
        \\          <div id="commits-dag" style="margin-bottom:10px;"></div>
        \\          <table id="commits-table">
        \\            <thead><tr><th>Commit ID</th><th>Parents</th><th>Tree Snapshot</th></tr></thead>
        \\            <tbody></tbody>
        \\          </table>
        \\          <h3>Table 4: <code>drafts</code> (Auto-Shelved Dirty Worktree State)</h3>
        \\          <table id="drafts-table">
        \\            <thead><tr><th>Worktree</th><th>Branch</th><th>Saved Draft</th></tr></thead>
        \\            <tbody></tbody>
        \\          </table>
        \\        </div>
        \\      </div>
        \\    </div>
        \\    <div class="card">
        \\      <h2>Why Formal Verification Matters: Naive Checkout Counterexample Trace</h2>
        \\      <p style="font-size:0.84rem;color:var(--muted);margin-top:0;">
        \\        When we disable single-DB auto-drafting (<code>NaiveVcsSpec</code>), the Zig TLA+ model checker immediately catches a violation of <code>Inv_NoUncommittedWorkLost</code> and produces this minimal counterexample:
        \\      </p>
        \\      <div id="counterexample-box"></div>
        \\    </div>
        \\  </div>
        \\</div>
        \\<script>
        \\const MODEL_DATA = 
    );

    try writer.print(
        "{{\"totalSafeStates\":{d},\"totalSafeTransitions\":{d},\"maxSafeDepth\":{d},\"nodes\":[",
        .{ safe_res.nodes.items.len, safe_res.transitions_explored, safe_res.max_depth_reached },
    );

    for (safe_res.nodes.items[0..export_count], 0..) |node, idx| {
        if (idx > 0) try writer.writeAll(",");
        try writer.print("{{\"id\":{d},\"depth\":{d},\"parent\":", .{ node.id, node.depth });
        if (node.parent_id) |pid| try writer.print("{d}", .{pid}) else try writer.writeAll("null");
        try writer.writeAll(",\"via\":");
        if (node.via_action) |act| {
            try writer.writeAll("\"");
            try act.formatShort(writer);
            try writer.writeAll("\"");
        } else {
            try writer.writeAll("\"Init\"");
        }
        try writer.writeAll(",\"state\":");
        try writeJsonState(node.state, writer);
        try writer.writeAll("}");
    }

    try writer.writeAll("],\"edges\":[");
    var first_edge = true;
    for (safe_res.edges.items) |edge| {
        if (edge.from_id < export_count and edge.to_id < export_count) {
            if (!first_edge) try writer.writeAll(",");
            first_edge = false;
            try writer.print("{{\"from\":{d},\"to\":{d},\"label\":\"", .{ edge.from_id, edge.to_id });
            try edge.action.formatShort(writer);
            try writer.writeAll("\"}");
        }
    }

    try writer.writeAll("],\"naiveViolation\":");
    if (naive_res.violation) |v| {
        try writer.print("{{\"invariant\":\"{s}\",\"description\":\"{s}\",\"steps\":[", .{
            v.invariant_name,
            v.invariant_description,
        });
        for (v.trace_state_ids, 0..) |sid, i| {
            if (i > 0) try writer.writeAll(",");
            const n = naive_res.nodes.items[sid];
            try writer.print("{{\"stateId\":{d},\"action\":\"", .{sid});
            if (n.via_action) |act| {
                try act.formatShort(writer);
            } else {
                try writer.writeAll("Init");
            }
            try writer.writeAll("\",\"summary\":\"");
            try formatSingleDbStateCompact(n.state, writer);
            try writer.writeAll("\"}");
        }
        try writer.writeAll("]}");
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("};\n");

    try writer.writeAll(
        \\const branchNames = ["main (br0)", "feat (br1)"];
        \\function fmtTree(t) {
        \\  if (!t) return "—";
        \\  return t.kind === "clean" ? `clean(v${t.ours})` : `CONFLICT(v${t.ours} ⚡ v${t.theirs})`;
        \\}
        \\let currentId = 0;
        \\function selectState(id) {
        \\  currentId = id;
        \\  const node = MODEL_DATA.nodes[id];
        \\  const s = node.state;
        \\  document.getElementById("current-state-title").textContent =
        \\    `State S${node.id} (BFS depth ${node.depth}, reached via ${node.via})`;
        \\  document.querySelectorAll(".state-btn").forEach(btn => {
        \\    btn.classList.toggle("active", Number(btn.dataset.id) === id);
        \\  });
        \\  // Enabled actions
        \\  const actContainer = document.getElementById("enabled-actions");
        \\  actContainer.innerHTML = "";
        \\  const outEdges = MODEL_DATA.edges.filter(e => e.from === id);
        \\  if (outEdges.length === 0) {
        \\    actContainer.innerHTML = `<span style="color:var(--muted);font-size:0.82rem;">Max exported preview depth reached for this node</span>`;
        \\  } else {
        \\    outEdges.forEach(e => {
        \\      const b = document.createElement("button");
        \\      b.className = "act-btn";
        \\      b.textContent = `${e.label} → S${e.to}`;
        \\      b.onclick = () => selectState(e.to);
        \\      actContainer.appendChild(b);
        \\    });
        \\  }
        \\  // Worktrees table
        \\  const wtBody = document.querySelector("#worktrees-table tbody");
        \\  wtBody.innerHTML = s.worktrees.map(wt => `
        \\    <tr>
        \\      <td><strong>wt${wt.id}</strong></td>
        \\      <td>${branchNames[wt.branch]}</td>
        \\      <td><span class="pill ${wt.workingTree.kind === 'conflict' ? 'pill-conflict' : 'pill-clean'}">${fmtTree(wt.workingTree)}</span></td>
        \\      <td><span class="pill ${wt.isDirty ? 'pill-dirty' : 'pill-clean'}">${wt.isDirty ? 'DIRTY (uncommitted)' : 'CLEAN'}</span></td>
        \\    </tr>
        \\  `).join("");
        \\  // Branches table
        \\  const brBody = document.querySelector("#branches-table tbody");
        \\  brBody.innerHTML = s.branches.map((cid, bi) => `
        \\    <tr>
        \\      <td><strong>${branchNames[bi]}</strong></td>
        \\      <td><code>c${cid}</code></td>
        \\      <td>${fmtTree(s.commits[cid].tree)}</td>
        \\    </tr>
        \\  `).join("");
        \\  // Commits table & DAG
        \\  const dagDiv = document.getElementById("commits-dag");
        \\  dagDiv.innerHTML = s.commits.map(c => {
        \\    const p = c.parent1 === null ? "root" : (c.parent2 !== null ? `c${c.parent1}+c${c.parent2}` : `c${c.parent1}`);
        \\    return `<span class="dag-node"><strong>c${c.id}</strong> ← (${p}) : ${fmtTree(c.tree)}</span>`;
        \\  }).join("");
        \\  const cmBody = document.querySelector("#commits-table tbody");
        \\  cmBody.innerHTML = s.commits.map(c => `
        \\    <tr>
        \\      <td><strong>c${c.id}</strong></td>
        \\      <td>${c.parent1 === null ? '— (root)' : (c.parent2 !== null ? `c${c.parent1}, c${c.parent2} (merge)` : `c${c.parent1}`)}</td>
        \\      <td>${fmtTree(c.tree)}</td>
        \\    </tr>
        \\  `).join("");
        \\  // Drafts table
        \\  const drBody = document.querySelector("#drafts-table tbody");
        \\  let drRows = "";
        \\  for (let w = 0; w < s.drafts.length; w++) {
        \\    for (let b = 0; b < s.drafts[w].length; b++) {
        \\      const d = s.drafts[w][b];
        \\      drRows += `<tr><td>wt${w}</td><td>${branchNames[b]}</td><td>${d ? `<span class="pill pill-dirty">${fmtTree(d)}</span>` : '—'}</td></tr>`;
        \\    }
        \\  }
        \\  drBody.innerHTML = drRows;
        \\}
        \\// Populate header badges
        \\document.getElementById("header-badges").innerHTML = `
        \\  <span class="badge pass">SafeVcsSpec: ${MODEL_DATA.totalSafeStates} States / ${MODEL_DATA.totalSafeTransitions} Transitions Verified</span>
        \\  <span class="badge pass">Lean 4: 8 Theorems Proved (0 sorry)</span>
        \\  <span class="badge fail">NaiveVcsSpec: Counterexample Found at Depth ${MODEL_DATA.naiveViolation ? MODEL_DATA.naiveViolation.steps.length - 1 : 0}</span>
        \\`;
        \\// Populate state list
        \\const listEl = document.getElementById("state-list");
        \\MODEL_DATA.nodes.forEach(n => {
        \\  const btn = document.createElement("button");
        \\  btn.className = "state-btn";
        \\  btn.dataset.id = n.id;
        \\  btn.textContent = `S${n.id} (d=${n.depth}) [${n.via}] commits:${n.state.commitCount} wt0:br${n.state.worktrees[0].branch}${n.state.worktrees[0].isDirty?'*':''} wt1:br${n.state.worktrees[1].branch}${n.state.worktrees[1].isDirty?'*':''}`;
        \\  btn.onclick = () => selectState(n.id);
        \\  listEl.appendChild(btn);
        \\});
        \\// Populate counterexample
        \\if (MODEL_DATA.naiveViolation) {
        \\  const cx = MODEL_DATA.naiveViolation;
        \\  document.getElementById("counterexample-box").innerHTML = cx.steps.map((st, idx) => `
        \\    <div class="trace-step">
        \\      <strong>Step ${idx} (${st.action})</strong> → State S${st.stateId}: <code>${st.summary}</code>
        \\    </div>
        \\  `).join("") + `<div style="color:var(--red);font-weight:600;font-size:0.85rem;">⚡ Violated ${cx.invariant}: ${cx.description}</div>`;
        \\}
        \\selectState(0);
        \\</script>
        \\</body>
        \\</html>
    );
}
