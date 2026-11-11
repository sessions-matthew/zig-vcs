//! Native `.dylib` Editor Plugin (`libzig_vcs.dylib`) for the Lightning Editor (`../editor`).
//!
//! Exports `editor_plugin_entry_v1` conforming to `EDITOR_PLUGIN_ABI_VERSION = 1`
//! (`../editor/src/platform/plugin_abi.zig`) and integrates directly with `zig-vcs`'s
//! in-process `RepoDb`, `materializer`, `git_interop`, and `editor_plugin` safety guardrails.
//!
//! Features all 6 UX refinements alongside existing Git source control:
//!   1. Unchecked conflict (`⚡ U`) defaults + morphing amber warning commit button
//!   2. Expandable sub-file line/hunk selection (`commitWithSubfileLineSelections`) without a staging index
//!   3. Auto-shelve branch-switch toast (`"Shelved N files on <branch> • [Bring Changes Here]"`)
//!   4. Human-first provenance labels (`Keep <branch> (cN)` / `Take <other> (cM)`) + 2-pane delta view
//!   5. Collapsed single-line Oplog footer bar (`↶ Undo: <op> • #<N> [Scrub ▴]`) + read-only jump preview
//!   6. Immutable/pushed commit lock glyphs (`🔒`) + in-memory Amend Cascade dry-run (`✓ Clean` vs `⚡ Conflict`)
//!   7. State-aware Git Sync Bridge health pill (`Git: In Sync ✓`, `Git: Ahead`, `Git Export Blocked`)

const std = @import("std");
const root = @import("zig_vcs");
const repo_db = root.repo_db;
const tree_sum = root.tree_sum;
const diff3 = root.diff3_anchors;
const materializer = root.materializer;
const ep = root.editor_plugin;

// ============================================================================
// 1. Lightning Editor C-ABI v1 Definitions (`../editor/src/platform/plugin_abi.zig`)
// ============================================================================

pub const EDITOR_PLUGIN_ABI_VERSION: u32 = 1;
pub const PLUGIN_ENTRY_SYMBOL = "editor_plugin_entry_v1";

pub const AbiSlice = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub fn fromZig(s: []const u8) AbiSlice {
        return .{
            .ptr = if (s.len > 0) s.ptr else null,
            .len = s.len,
        };
    }

    pub fn toZig(self: AbiSlice) []const u8 {
        const p = self.ptr orelse return &.{};
        return p[0..self.len];
    }
};

pub const PluginCapabilities = packed struct(u32) {
    commands: bool = false,
    buffer_hooks: bool = false,
    sidebar_panel: bool = false,
    bottom_panel: bool = false,
    status_bar: bool = false,
    editor_overlay: bool = false,
    background_poller: bool = false,
    _reserved: u25 = 0,
};

pub const PluginSidebarIcon = enum(u8) {
    none = 0,
    debug = 1,
    cpu = 2,
    waveform = 3,
    git = 4,
    plugins = 5,
    board = 6,
    pdf = 7,
};

pub const PluginToolbarIcon = enum(u8) {
    play = 0,
    pause = 1,
    step_over = 2,
    step_into = 3,
    step_out = 4,
    restart = 5,
    stop = 6,
    gear = 7,
    debug_console = 8,
    breakpoint = 9,
};

pub const PluginManifestV1 = extern struct {
    abi_version: u32 = EDITOR_PLUGIN_ABI_VERSION,
    id: AbiSlice,
    display_name: AbiSlice,
    version: AbiSlice,
    capabilities: PluginCapabilities = .{},
    sidebar_icon: PluginSidebarIcon = .none,
    sidebar_title: AbiSlice = .{},
    bottom_tab_title: AbiSlice = .{},
    debug_extensions: AbiSlice = .{},
};

pub const BufferInfoV1 = extern struct {
    buffer_id: u32 = 0,
    file_path: AbiSlice = .{},
    text: AbiSlice = .{},
    line_count: u32 = 1,
    cursor_offset: usize = 0,
    selection_anchor: usize = 0,
    cursor_line: u32 = 0,
    cursor_col: u32 = 0,
    edit_version: u32 = 0,
    is_dirty: bool = false,
};

pub const LineRangeV1 = extern struct {
    start: usize = 0,
    end: usize = 0,
};

pub const BufferEditEventV1 = extern struct {
    buffer_id: u32 = 0,
    start_offset: usize = 0,
    old_end_offset: usize = 0,
    new_end_offset: usize = 0,
    edit_version: u32 = 0,
};

pub const CompletionItemV1 = extern struct {
    label: AbiSlice = .{},
    detail: AbiSlice = .{},
    insert_text: AbiSlice = .{},
    kind: u8 = 0,
    replace_prefix_len: u16 = 0,
};

pub const BreakpointV1 = extern struct {
    file_path: AbiSlice = .{},
    line: u32 = 1,
    enabled: bool = true,
    hit_count: u32 = 0,
};

pub const GitActionV1 = enum(u32) {
    stage_path = 0,
    unstage_path = 1,
    stage_all = 2,
    unstage_all = 3,
    discard_path = 4,
    commit = 5,
    refresh = 6,
};

pub const GitFileStatusV1 = extern struct {
    path: AbiSlice = .{},
    status: u8 = 'M',
    staged: bool = false,
    unstaged: bool = false,
    untracked: bool = false,
};

pub const GitCommitV1 = extern struct {
    hash: AbiSlice = .{},
    subject: AbiSlice = .{},
    rel_time: AbiSlice = .{},
    files_changed: u16 = 0,
    files_ptr: ?[*]const GitFileStatusV1 = null,
    file_count: usize = 0,
};

pub const GitStatusSnapshotV1 = extern struct {
    branch: AbiSlice = .{},
    is_busy: bool = false,
    files_ptr: ?[*]const GitFileStatusV1 = null,
    file_count: usize = 0,
    commits_ptr: ?[*]const GitCommitV1 = null,
    commit_count: usize = 0,
};

pub const TextFieldResultFlags = packed struct(u8) {
    changed: bool = false,
    submitted: bool = false,
    escaped: bool = false,
    focused: bool = false,
    _reserved: u4 = 0,
};

pub const SectionHeaderResultFlags = packed struct(u8) {
    expanded: bool = false,
    action_clicked: bool = false,
    right_clicked: bool = false,
    _reserved: u5 = 0,
};

pub const ListItemResultFlags = packed struct(u8) {
    clicked: bool = false,
    action_clicked: bool = false,
    secondary_action_clicked: bool = false,
    right_clicked: bool = false,
    _reserved: u4 = 0,
};

pub const PluginUiApiV1 = extern struct {
    get_pass: *const fn (host: *anyopaque) callconv(.c) u8,

    // Layout Containers
    begin_column: *const fn (host: *anyopaque, w: f32, h: f32, pad: f32, gap: f32) callconv(.c) void,
    begin_row: *const fn (host: *anyopaque, w: f32, h: f32, pad: f32, gap: f32) callconv(.c) void,
    end_box: *const fn (host: *anyopaque) callconv(.c) void,
    begin_scroll_panel: *const fn (host: *anyopaque, id: AbiSlice, w: f32, h: f32, pad: f32, gap: f32) callconv(.c) void,
    end_scroll_panel: *const fn (host: *anyopaque) callconv(.c) void,
    spacer: *const fn (host: *anyopaque, w: f32, h: f32) callconv(.c) void,
    divider: *const fn (host: *anyopaque) callconv(.c) void,
    push_id: *const fn (host: *anyopaque, id: AbiSlice) callconv(.c) void,
    pop_id: *const fn (host: *anyopaque) callconv(.c) void,

    // Cached Text & Interactive Widgets
    label: *const fn (host: *anyopaque, text: AbiSlice, style: u8) callconv(.c) void,
    button: *const fn (host: *anyopaque, label: AbiSlice, w: f32, h: f32) callconv(.c) bool,
    toolbar_icon_btn: *const fn (host: *anyopaque, label: AbiSlice, icon: PluginToolbarIcon, w: f32, h: f32, enabled: bool) callconv(.c) bool,
    dropdown_select: *const fn (host: *anyopaque, label: AbiSlice, display_text: AbiSlice, w: f32, h: f32, active_border: bool) callconv(.c) bool,
    reserve_dropdown_overlay: *const fn (host: *anyopaque, height: f32) callconv(.c) bool,
    begin_dropdown_overlay: *const fn (host: *anyopaque) callconv(.c) void,
    end_dropdown_overlay: *const fn (host: *anyopaque) callconv(.c) void,
    collapsible_section: *const fn (host: *anyopaque, label: AbiSlice, expanded: *bool, badge_text: AbiSlice) callconv(.c) bool,
    collapsible_section_with_action: *const fn (host: *anyopaque, label: AbiSlice, expanded: *bool, badge_text: AbiSlice, action_label: AbiSlice) callconv(.c) u8,
    tree_folder_node: *const fn (host: *anyopaque, label: AbiSlice, indent_level: u8, expanded: *bool, meta: AbiSlice) callconv(.c) bool,
    chip: *const fn (host: *anyopaque, label: AbiSlice, active: bool) callconv(.c) bool,
    list_item: *const fn (host: *anyopaque, label: AbiSlice, meta: AbiSlice, selected: bool) callconv(.c) bool,
    list_item_ex: *const fn (
        host: *anyopaque,
        label: AbiSlice,
        meta: AbiSlice,
        icon_text: AbiSlice,
        action_label: AbiSlice,
        secondary_action_label: AbiSlice,
        indent_level: u8,
        selected: bool,
        accent_kind: u8,
    ) callconv(.c) u8,
    text_field: *const fn (host: *anyopaque, id: AbiSlice, buf_ptr: [*]u8, len_ptr: *usize, cap: usize, placeholder: AbiSlice) callconv(.c) u8,
    text_area: *const fn (host: *anyopaque, id: AbiSlice, buf_ptr: [*]u8, len_ptr: *usize, cap: usize, placeholder: AbiSlice, height: f32) callconv(.c) u8,
    markdown: *const fn (host: *anyopaque, source: AbiSlice) callconv(.c) void,
    waveform_view: *const fn (host: *anyopaque, id: AbiSlice, vcd_source: AbiSlice, height: f32) callconv(.c) void,
    pdf_view: *const fn (host: *anyopaque, id: AbiSlice, file_path: AbiSlice, raw_bytes: AbiSlice, height: f32) callconv(.c) void,
};

pub const EditorHostApiV1 = extern struct {
    abi_version: u32 = EDITOR_PLUGIN_ABI_VERSION,

    // 1. Per-Frame Arena & Persistent Scoped State (`dlclose`-safe)
    frame_alloc: *const fn (host: *anyopaque, size: usize, alignment_log2: u8) callconv(.c) ?[*]u8,
    use_state_raw: *const fn (
        host: *anyopaque,
        key: AbiSlice,
        size: usize,
        alignment_log2: u8,
        type_hash: u64,
        initialized_out: *bool,
    ) callconv(.c) [*]u8,

    // 2. Zero-Copy Buffer Inspection & Atomic Mutation
    get_active_buffer: *const fn (host: *anyopaque, out: *BufferInfoV1) callconv(.c) bool,
    get_line_range: *const fn (host: *anyopaque, buffer_id: u32, line_idx: u32) callconv(.c) LineRangeV1,
    offset_to_line_col: *const fn (host: *anyopaque, buffer_id: u32, offset: usize, line_out: *u32, col_out: *u32) callconv(.c) void,
    replace_buffer_range: *const fn (host: *anyopaque, buffer_id: u32, start: usize, end: usize, new_text: AbiSlice) callconv(.c) bool,
    set_cursor_and_scroll: *const fn (host: *anyopaque, buffer_id: u32, cursor: usize, anchor: usize) callconv(.c) void,

    // 3. Command Palette, Autocomplete Popup, Preview Buffers, Status Notice & Async Wakeup
    register_command: *const fn (host: *anyopaque, cmd_id: AbiSlice, title: AbiSlice, category: AbiSlice, shortcut_hint: AbiSlice) callconv(.c) bool,
    set_completions: *const fn (host: *anyopaque, buffer_id: u32, cursor_offset: usize, items_ptr: ?[*]const CompletionItemV1, item_count: usize) callconv(.c) void,
    open_waveform_preview: *const fn (host: *anyopaque, vcd_source: AbiSlice, split_to_side: bool) callconv(.c) void,
    open_pdf_preview: *const fn (host: *anyopaque, file_path: AbiSlice, raw_bytes: AbiSlice, split_to_side: bool) callconv(.c) void,
    open_git_diff: *const fn (host: *anyopaque, file_path: AbiSlice, commit_sha: AbiSlice, staged: bool, split_to_side: bool) callconv(.c) void,
    open_file_path: *const fn (host: *anyopaque, path: AbiSlice) callconv(.c) bool,
    sync_workspace_git: *const fn (host: *anyopaque, save_dirty: bool, reload_from_disk: bool) callconv(.c) void,
    get_git_status: *const fn (host: *anyopaque, out: *GitStatusSnapshotV1) callconv(.c) bool,
    git_action: *const fn (host: *anyopaque, action: GitActionV1, path_or_msg: AbiSlice) callconv(.c) bool,
    run_terminal_command: *const fn (host: *anyopaque, cmd: AbiSlice) callconv(.c) void,
    toggle_bottom_panel: *const fn (host: *anyopaque) callconv(.c) void,
    set_status_notice: *const fn (host: *anyopaque, msg: AbiSlice) callconv(.c) void,
    request_continuous_redraw: *const fn (host: *anyopaque) callconv(.c) void,

    // 4. Shared Breakpoints & Active Debugger Execution Line
    toggle_breakpoint: *const fn (host: *anyopaque, file_path: AbiSlice, line_1based: u32) callconv(.c) bool,
    clear_breakpoints: *const fn (host: *anyopaque) callconv(.c) void,
    get_breakpoints: *const fn (host: *anyopaque, out_ptr: ?[*]BreakpointV1, max_count: usize) callconv(.c) usize,
    set_debug_location: *const fn (host: *anyopaque, active: bool, paused: bool, file_path: AbiSlice, line_1based: u32, jump_to_line: bool) callconv(.c) void,

    // 5. Two-Phase Declarative UI Toolkit Bridge
    ui: *const PluginUiApiV1,
};

pub const PluginHookFn = *const fn (host: *anyopaque, api: *const EditorHostApiV1) callconv(.c) void;
pub const PluginCommandFn = *const fn (host: *anyopaque, api: *const EditorHostApiV1, cmd_id: AbiSlice) callconv(.c) void;
pub const PluginBufferInfoFn = *const fn (host: *anyopaque, api: *const EditorHostApiV1, info: *const BufferInfoV1) callconv(.c) void;
pub const PluginBufferEditFn = *const fn (host: *anyopaque, api: *const EditorHostApiV1, ev: *const BufferEditEventV1) callconv(.c) void;

pub const EditorPluginV1 = extern struct {
    manifest: PluginManifestV1,
    init: ?PluginHookFn = null,
    before_reload: ?PluginHookFn = null,
    on_reload: ?PluginHookFn = null,
    deinit: ?PluginHookFn = null,
    on_poll_io: ?PluginHookFn = null,
    on_command: ?PluginCommandFn = null,
    on_buffer_open: ?PluginBufferInfoFn = null,
    on_buffer_edit: ?PluginBufferEditFn = null,
    on_buffer_save: ?PluginBufferInfoFn = null,
    render_sidebar: ?PluginHookFn = null,
    render_bottom_panel: ?PluginHookFn = null,
    render_status_bar: ?PluginHookFn = null,
};

pub fn InlineString(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Capacity = capacity;
        buf: [capacity]u8 = @splat(0),
        len: usize = 0,

        pub fn set(self: *Self, str: []const u8) void {
            const n = @min(str.len, capacity);
            @memcpy(self.buf[0..n], str[0..n]);
            self.len = n;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..@min(self.len, capacity)];
        }
    };
}

// ============================================================================
// 2. Persistent Plugin UI State (Stored in Host StateStore, <= 24 KB)
// ============================================================================

const MaxTrackedFiles = 20;
const MaxTrackedLinesPerFile = 8;
const MaxTrackedBranches = 8;
const MaxTrackedCommits = 12;
const MaxTrackedOplog = 10;

pub const CachedFileItem = struct {
    path: InlineString(80) = .{},
    status: ep.FileChangeStatus = .modified,
    checked: bool = true,
    has_conflict: bool = false,
    expanded_hunks: bool = false,
    line_count: u8 = 0,
    line_numbers: [MaxTrackedLinesPerFile]u16 = @splat(1),
    line_previews: [MaxTrackedLinesPerFile]InlineString(40) = @splat(.{}),
    line_checked: [MaxTrackedLinesPerFile]bool = @splat(true),
    keep_left_label: InlineString(40) = .{},
    take_right_label: InlineString(40) = .{},
    math_badge: InlineString(56) = .{},
    ours_summary: InlineString(48) = .{},
    theirs_summary: InlineString(48) = .{},
};

pub const CachedBranchItem = struct {
    name: InlineString(32) = .{},
    head_commit: u64 = 0,
    has_draft: bool = false,
    is_current: bool = false,
};

pub const CachedCommitItem = struct {
    id: u64 = 0,
    parent1: u64 = 0,
    parent2: u64 = 0,
    timestamp: i64 = 0,
    tz_offset_min: i16 = 0,
    author: InlineString(32) = .{},
    subject: InlineString(64) = .{},
    has_conflicts: bool = false,
    is_locked_git: bool = false,
};

pub const CachedOplogItem = struct {
    index: usize = 0,
    op_name: InlineString(36) = .{},
    head_commit: u64 = 0,
};

pub const PendingActionKind = enum(u8) {
    none = 0,
    sync_refresh = 1,
    toggle_branches_dropdown = 2,
    toggle_git_mode = 3,
    toggle_math_mode = 4,
    dismiss_toast = 5,
    bring_shelved_draft = 6,
    switch_branch = 7,
    commit_checked = 8,
    toggle_file_checked = 9,
    toggle_file_hunks = 10,
    toggle_line_checked = 11,
    resolve_conflict_ours = 12,
    resolve_conflict_theirs = 13,
    select_commit = 14,
    unlock_immutable = 15,
    amend_commit = 16,
    backout_commit = 17,
    undo_op = 18,
    redo_op = 19,
    toggle_oplog_expanded = 20,
    preview_oplog_jump = 21,
    restore_oplog = 22,
    cancel_oplog_preview = 23,
};

pub const ZigVcsPluginState = struct {
    initialized: bool = false,
    has_zvcs_db: bool = false,
    has_git_dir: bool = false,
    show_git_fallback_mode: bool = false,
    math_mode: bool = false,
    last_db_mtime_ns: i96 = -1,

    // Deferred action queue (guarantees Pass.input == Pass.paint layout determinism)
    pending_kind: PendingActionKind = .none,
    pending_index: usize = 0,
    pending_sub_index: usize = 0,
    pending_u64: u64 = 0,

    // Active workspace summary
    current_branch: InlineString(32) = .{},
    current_worktree: InlineString(32) = .{},
    head_commit: u64 = 0,
    git_synced_max_commit: u64 = 0,
    bridge_pill: InlineString(80) = .{},
    bridge_can_export: bool = true,

    // Commit composer & filter
    commit_msg: InlineString(128) = .{},
    show_branches_dropdown: bool = false,

    // Working changes
    files: [MaxTrackedFiles]CachedFileItem = @splat(.{}),
    file_count: usize = 0,

    // Branch switcher + Refinement 1c (Shelved draft toast)
    branches: [MaxTrackedBranches]CachedBranchItem = @splat(.{}),
    branch_count: usize = 0,
    toast_visible: bool = false,
    toast_from_branch: InlineString(32) = .{},
    toast_banner: InlineString(96) = .{},

    // Commit history + Refinement 3b (Immutable lock + Cascade dry-run)
    commits: [MaxTrackedCommits]CachedCommitItem = @splat(.{}),
    commit_count: usize = 0,
    selected_commit_id: u64 = 0,
    unlock_immutable_rewrite: bool = false,
    cascade_preview_active: bool = false,
    cascade_preview_commit: u64 = 0,
    cascade_impacts_count: usize = 0,
    cascade_new_conflicts: usize = 0,

    // Oplog footer + Refinement 3a (Collapsed bar + Read-only jump preview)
    oplog_expanded: bool = false,
    oplog_total: usize = 0,
    redo_total: usize = 0,
    collapsed_oplog_bar: InlineString(80) = .{},
    oplog_items: [MaxTrackedOplog]CachedOplogItem = @splat(.{}),
    oplog_item_count: usize = 0,
    oplog_preview_active: bool = false,
    oplog_preview_index: usize = 0,
    oplog_preview_op: InlineString(36) = .{},
    oplog_preview_diff: InlineString(120) = .{},

    // Status feedback banner
    last_action_status: InlineString(96) = .{},

    pub fn schedule(self: *ZigVcsPluginState, ctx: *Ctx, kind: PendingActionKind, idx: usize, sub_idx: usize, val_u64: u64) void {
        self.pending_kind = kind;
        self.pending_index = idx;
        self.pending_sub_index = sub_idx;
        self.pending_u64 = val_u64;
        ctx.api.request_continuous_redraw(ctx.host);
    }
};

comptime {
    if (@sizeOf(ZigVcsPluginState) > 24576) {
        @compileError("ZigVcsPluginState must remain <= 24 KB to fit inside host fallback_state_buf (32 KB)");
    }
}

// ============================================================================
// 3. Lightweight Host UI & Context Wrapper
// ============================================================================

const Ctx = struct {
    host: *anyopaque,
    api: *const EditorHostApiV1,

    fn isInputPass(self: *Ctx) bool {
        return self.api.ui.get_pass(self.host) == 0;
    }

    fn alloc(self: *Ctx) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = frameAlloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = std.mem.Allocator.noFree,
            },
        };
    }

    fn frameAlloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Ctx = @ptrCast(@alignCast(ptr));
        return self.api.frame_alloc(self.host, len, @intFromEnum(alignment));
    }

    fn fmt(self: *Ctx, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.alloc(), format, args) catch "";
    }

    fn state(self: *Ctx) *ZigVcsPluginState {
        var initialized = false;
        const raw = self.api.use_state_raw(
            self.host,
            AbiSlice.fromZig("zvcs_state_v3"),
            @sizeOf(ZigVcsPluginState),
            @ctz(@as(usize, @alignOf(ZigVcsPluginState))),
            0x5A564353_55495F34,
            &initialized,
        );
        const ptr: *ZigVcsPluginState = @ptrCast(@alignCast(raw));
        if (!initialized) {
            ptr.* = .{};
        }
        return ptr;
    }

    fn label(self: *Ctx, text: []const u8) void {
        self.api.ui.label(self.host, AbiSlice.fromZig(text), 0);
    }

    fn mutedLabel(self: *Ctx, text: []const u8) void {
        self.api.ui.label(self.host, AbiSlice.fromZig(text), 1);
    }

    fn monoLabel(self: *Ctx, text: []const u8) void {
        self.api.ui.label(self.host, AbiSlice.fromZig(text), 2);
    }

    fn sectionLabel(self: *Ctx, text: []const u8) void {
        self.api.ui.label(self.host, AbiSlice.fromZig(text), 3);
    }

    fn divider(self: *Ctx) void {
        self.api.ui.divider(self.host);
    }

    fn beginRow(self: *Ctx, h: f32, gap: f32) void {
        self.api.ui.begin_row(self.host, 0, h, 0, gap);
    }

    fn endBox(self: *Ctx) void {
        self.api.ui.end_box(self.host);
    }

    fn pushId(self: *Ctx, id: []const u8) void {
        self.api.ui.push_id(self.host, AbiSlice.fromZig(id));
    }

    fn popId(self: *Ctx) void {
        self.api.ui.pop_id(self.host);
    }

    fn button(self: *Ctx, lbl: []const u8, w: f32, h: f32) bool {
        return self.api.ui.button(self.host, AbiSlice.fromZig(lbl), w, h);
    }

    fn chip(self: *Ctx, lbl: []const u8, active: bool) bool {
        return self.api.ui.chip(self.host, AbiSlice.fromZig(lbl), active);
    }

    fn listItem(self: *Ctx, lbl: []const u8, meta: []const u8, selected: bool) bool {
        return self.api.ui.list_item(self.host, AbiSlice.fromZig(lbl), AbiSlice.fromZig(meta), selected);
    }

    fn listItemAction(
        self: *Ctx,
        lbl: []const u8,
        meta: []const u8,
        icon_text: []const u8,
        accent_kind: u8,
        selected: bool,
        action_label: []const u8,
    ) ListItemResultFlags {
        const bits = self.api.ui.list_item_ex(
            self.host,
            AbiSlice.fromZig(lbl),
            AbiSlice.fromZig(meta),
            AbiSlice.fromZig(icon_text),
            AbiSlice.fromZig(action_label),
            AbiSlice.fromZig(""),
            0,
            selected,
            accent_kind,
        );
        return @bitCast(bits);
    }

    fn textField(self: *Ctx, id: []const u8, str: anytype, placeholder: []const u8) TextFieldResultFlags {
        const bits = self.api.ui.text_field(
            self.host,
            AbiSlice.fromZig(id),
            &str.buf,
            &str.len,
            @TypeOf(str.*).Capacity,
            AbiSlice.fromZig(placeholder),
        );
        return @bitCast(bits);
    }

    fn setNotice(self: *Ctx, msg: []const u8) void {
        self.api.set_status_notice(self.host, AbiSlice.fromZig(msg));
    }
};

// ============================================================================
// 4. In-Process `RepoDb` Synchronization & Action Execution
// ============================================================================

fn getIo() std.Io {
    const S = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}

fn statusBadgeText(status: ep.FileChangeStatus) []const u8 {
    return switch (status) {
        .added => "A",
        .modified => "M",
        .deleted => "D",
        .conflicted => "⚡ U",
    };
}

fn refreshFromRepoDb(st: *ZigVcsPluginState, force_sync_disk: bool) void {
    const io = getIo();
    const gpa = std.heap.c_allocator;

    const backend = ep.detectWorkspaceVcs(io, ".");
    st.has_git_dir = (backend == .git_only or backend == .hybrid_zig_vcs_and_git);
    st.has_zvcs_db = (backend == .zig_vcs_only or backend == .hybrid_zig_vcs_and_git);
    if (!st.has_zvcs_db) {
        st.initialized = true;
        return;
    }

    var ws_ctx = materializer.resolveWorkspaceContext(gpa, io, ".") catch {
        st.has_zvcs_db = false;
        st.initialized = true;
        return;
    };
    defer ws_ctx.deinit(gpa);

    const db_stat = std.Io.Dir.cwd().statFile(io, ws_ctx.db_path, .{}) catch {
        st.has_zvcs_db = false;
        st.initialized = true;
        return;
    };

    if (!force_sync_disk and st.initialized and db_stat.mtime.nanoseconds == st.last_db_mtime_ns) {
        return;
    }

    var db = repo_db.RepoDb.loadFromFile(gpa, io, ws_ctx.db_path) catch {
        st.has_zvcs_db = false;
        return;
    };
    defer db.deinit();

    const wt_id = ws_ctx.wt_id;
    if (force_sync_disk) {
        _ = materializer.syncWorktreeFromDisk(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};
        db.saveToFile(io, ws_ctx.db_path) catch {};
    }

    if (std.Io.Dir.cwd().statFile(io, ws_ctx.db_path, .{})) |after_stat| {
        st.last_db_mtime_ns = after_stat.mtime.nanoseconds;
    } else |_| {}

    const wt = db.worktrees.items[wt_id];
    const br = db.branches.items[wt.branch_id];
    st.current_branch.set(br.name);
    st.current_worktree.set(wt.name);
    st.head_commit = br.head_commit;

    // Populate branches
    st.branch_count = 0;
    for (db.branches.items, 0..) |b, b_id_usize| {
        if (st.branch_count >= MaxTrackedBranches) break;
        const b_id: repo_db.BranchId = @intCast(b_id_usize);
        var has_draft = false;
        for (db.drafts.items) |d| {
            if (d.worktree_id == wt_id and d.branch_id == b_id) {
                has_draft = true;
                break;
            }
        }
        var item = &st.branches[st.branch_count];
        item.* = .{
            .head_commit = b.head_commit,
            .has_draft = has_draft,
            .is_current = (b_id == wt.branch_id),
        };
        item.name.set(b.name);
        st.branch_count += 1;
    }

    // Preserve previous checkbox states by path where possible
    var prev_paths: [MaxTrackedFiles]InlineString(80) = @splat(.{});
    var prev_checked: [MaxTrackedFiles]bool = @splat(true);
    var prev_expanded: [MaxTrackedFiles]bool = @splat(false);
    const prev_count = st.file_count;
    for (0..prev_count) |i| {
        prev_paths[i] = st.files[i].path;
        prev_checked[i] = st.files[i].checked;
        prev_expanded[i] = st.files[i].expanded_hunks;
    }

    // Build working file checkboxes via `editor_plugin.buildWorkingChangesList`
    const wf_slice = ep.buildWorkingChangesList(gpa, &db, wt_id) catch {
        st.initialized = true;
        return;
    };
    defer ep.freeWorkingChangesList(gpa, wf_slice);

    const base_tid = db.commits.items[br.head_commit].root_tree_id;
    const base_tree = db.trees.items[base_tid];
    const work_tree = db.trees.items[wt.working_tree_id];

    st.file_count = 0;
    for (wf_slice) |wf| {
        if (st.file_count >= MaxTrackedFiles) break;
        var item = &st.files[st.file_count];
        const is_conf = (wf.status == .conflicted);
        item.* = .{
            .status = wf.status,
            .checked = wf.checked, // Conflicted files default to false!
            .has_conflict = is_conf,
        };
        item.path.set(wf.path);

        // Restore user's explicit toggle if path already existed in list
        for (0..prev_count) |p_i| {
            if (std.mem.eql(u8, prev_paths[p_i].slice(), wf.path)) {
                item.checked = prev_checked[p_i];
                item.expanded_hunks = prev_expanded[p_i];
                break;
            }
        }

        if (is_conf) {
            if (ep.buildTwoPaneConflictViewModel(gpa, &db, wt_id, wf.path)) |vm_val| {
                var vm = vm_val;
                defer vm.deinit(gpa);
                item.keep_left_label.set(vm.keep_left_label);
                item.take_right_label.set(vm.take_right_label);
                item.math_badge.set(vm.math_formula_badge);

                var l_add: usize = 0;
                var l_del: usize = 0;
                for (vm.left_delta_lines) |l| {
                    if (l.kind == .added_vs_base) l_add += 1 else if (l.kind == .deleted_from_base) l_del += 1;
                }
                var r_add: usize = 0;
                var r_del: usize = 0;
                for (vm.right_delta_lines) |r| {
                    if (r.kind == .added_vs_base) r_add += 1 else if (r.kind == .deleted_from_base) r_del += 1;
                }
                var s1_buf: [48]u8 = undefined;
                var s2_buf: [48]u8 = undefined;
                item.ours_summary.set(std.fmt.bufPrint(&s1_buf, "+{d} -{d} vs Base", .{ l_add, l_del }) catch "");
                item.theirs_summary.set(std.fmt.bufPrint(&s2_buf, "+{d} -{d} vs Base", .{ r_add, r_del }) catch "");
            } else |_| {}
        } else if (wf.status == .modified or wf.status == .added) {
            const base_bytes: []const u8 = if (base_tree.getPathSum(wf.path)) |bs|
                (if (bs.getCleanHash()) |bh| (db.getBlob(bh) orelse "") else "")
            else
                "";
            const work_bytes: []const u8 = if (work_tree.getPathSum(wf.path)) |ws|
                (if (ws.getCleanHash()) |wh| (db.getBlob(wh) orelse "") else "")
            else
                "";

            if (diff3.splitLines(gpa, work_bytes)) |w_lines| {
                defer gpa.free(w_lines);
                const b_lines = diff3.splitLines(gpa, base_bytes) catch &.{};
                defer if (b_lines.len > 0) gpa.free(b_lines);

                item.line_count = 0;
                for (w_lines, 0..) |w_l, idx| {
                    var in_base = false;
                    for (b_lines) |b_l| {
                        if (std.mem.eql(u8, w_l, b_l)) {
                            in_base = true;
                            break;
                        }
                    }
                    if (!in_base and item.line_count < MaxTrackedLinesPerFile) {
                        const slot = item.line_count;
                        item.line_numbers[slot] = @intCast(idx + 1);
                        item.line_previews[slot].set(std.mem.trimEnd(u8, w_l, "\r\n"));
                        item.line_checked[slot] = true;
                        item.line_count += 1;
                    }
                }
            } else |_| {}
        }
        st.file_count += 1;
    }

    // Check if origin remote is configured to mark pushed commits as locked
    const has_remote = (db.remotes.items.len > 0);
    st.git_synced_max_commit = if (has_remote and db.commits.items.len > 1) br.head_commit else 0;

    // Inspect Git Bridge Health (Refinement 4)
    if (ep.inspectGitBridgeHealth(gpa, &db, if (st.git_synced_max_commit > 0) @intCast(st.git_synced_max_commit) else null)) |rep_val| {
        var rep = rep_val;
        defer rep.deinit(gpa);
        st.bridge_pill.set(rep.pill_label);
        st.bridge_can_export = (rep.status != .export_blocked_conflicts);
    } else |_| {
        st.bridge_pill.set("Git: In Sync ✓");
        st.bridge_can_export = true;
    }

    st.commit_count = 0;
    var c_idx = db.commits.items.len;
    while (c_idx > 0 and st.commit_count < MaxTrackedCommits) {
        c_idx -= 1;
        const c = db.commits.items[c_idx];
        var ci = &st.commits[st.commit_count];
        ci.* = .{
            .id = c_idx,
            .parent1 = c.parent1 orelse 0,
            .parent2 = c.parent2 orelse 0,
            .timestamp = c.timestamp_sec,
            .tz_offset_min = c.tz_offset_min,
            .has_conflicts = db.trees.items[c.root_tree_id].hasConflicts(),
            .is_locked_git = (st.git_synced_max_commit > 0 and c_idx <= st.git_synced_max_commit and c_idx > 0),
        };
        ci.author.set(c.author);
        const first_line = if (std.mem.indexOfScalar(u8, c.message, '\n')) |nl| c.message[0..nl] else c.message;
        ci.subject.set(first_line);
        st.commit_count += 1;
    }

    // Populate Oplog footer & recent entries (Refinement 3a)
    st.oplog_total = db.oplog.items.len;
    st.redo_total = db.redo_stack.items.len;
    if (ep.buildOplogFooterBarModel(gpa, &db, st.oplog_expanded)) |fb_val| {
        var fb = fb_val;
        defer fb.deinit(gpa);
        st.collapsed_oplog_bar.set(fb.collapsed_summary);
    } else |_| {}

    st.oplog_item_count = 0;
    var op_idx = db.oplog.items.len;
    while (op_idx > 0 and st.oplog_item_count < MaxTrackedOplog) {
        op_idx -= 1;
        const entry = db.oplog.items[op_idx];
        var oi = &st.oplog_items[st.oplog_item_count];
        oi.* = .{
            .index = op_idx,
            .head_commit = if (entry.branches.items.len > wt.branch_id) entry.branches.items[wt.branch_id].head_commit else 0,
        };
        oi.op_name.set(entry.command_desc);
        st.oplog_item_count += 1;
    }

    st.initialized = true;
}

fn performCommitChecked(ctx: *Ctx, st: *ZigVcsPluginState) void {
    const msg = std.mem.trim(u8, st.commit_msg.slice(), " \t\r\n");
    if (msg.len == 0) {
        st.last_action_status.set("Enter a commit message first.");
        ctx.setNotice("zig-vcs: Enter a commit message before committing.");
        return;
    }

    ctx.api.sync_workspace_git(ctx.host, true, false);

    const io = getIo();
    const gpa = std.heap.c_allocator;
    var ws_ctx = materializer.resolveWorkspaceContext(gpa, io, ".") catch return;
    defer ws_ctx.deinit(gpa);
    var db = repo_db.RepoDb.loadFromFile(gpa, io, ws_ctx.db_path) catch return;
    defer db.deinit();

    const wt_id = ws_ctx.wt_id;
    _ = materializer.syncWorktreeFromDisk(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};

    const author = db.getConfig("user.name") orelse "developer";

    // Check if a single file has sub-file lines partially unchecked (Refinement 1b)
    if (st.file_count == 1 and st.files[0].checked and st.files[0].line_count > 1) {
        const f = &st.files[0];
        var any_unchecked = false;
        var ranges: [MaxTrackedLinesPerFile]ep.LineRangeSelection = undefined;
        var range_count: usize = 0;
        for (0..f.line_count) |l_i| {
            if (f.line_checked[l_i]) {
                ranges[range_count] = .{
                    .start_line = f.line_numbers[l_i],
                    .end_line = f.line_numbers[l_i],
                };
                range_count += 1;
            } else {
                any_unchecked = true;
            }
        }
        if (any_unchecked and range_count > 0) {
            const new_cid = ep.commitWithSubfileLineSelections(
                gpa,
                &db,
                wt_id,
                f.path.slice(),
                ranges[0..range_count],
                author,
                msg,
            ) catch return;
            db.saveToFile(io, ws_ctx.db_path) catch {};
            st.commit_msg.clear();
            const notice = ctx.fmt("zig-vcs: Committed c{d} ({d} selected line(s) of {s})", .{ new_cid, range_count, f.path.slice() });
            st.last_action_status.set(notice);
            ctx.setNotice(notice);
            refreshFromRepoDb(st, true);
            return;
        }
    }

    var items: [MaxTrackedFiles]ep.WorkingFileCheckboxItem = undefined;
    var any_conflict_checked = false;
    for (st.files[0..st.file_count], 0..) |*f, i| {
        items[i] = .{
            .path = @constCast(f.path.slice()),
            .status = f.status,
            .checked = f.checked,
            .term_count = if (f.has_conflict) 3 else 1,
        };
        if (f.checked and f.has_conflict) any_conflict_checked = true;
    }

    const new_cid = ep.commitCheckedItems(
        gpa,
        &db,
        wt_id,
        items[0..st.file_count],
        author,
        msg,
        any_conflict_checked,
    ) catch |err| {
        st.last_action_status.set(ctx.fmt("Commit failed: {s}", .{@errorName(err)}));
        return;
    };

    db.saveToFile(io, ws_ctx.db_path) catch {};
    st.commit_msg.clear();
    const notice = ctx.fmt("zig-vcs: Committed c{d} on @{s}", .{ new_cid, st.current_branch.slice() });
    st.last_action_status.set(notice);
    ctx.setNotice(notice);
    refreshFromRepoDb(st, true);
}

fn performSwitchBranch(ctx: *Ctx, st: *ZigVcsPluginState, target_branch_name: []const u8) void {
    ctx.api.sync_workspace_git(ctx.host, true, false);

    const io = getIo();
    const gpa = std.heap.c_allocator;
    var ws_ctx = materializer.resolveWorkspaceContext(gpa, io, ".") catch return;
    defer ws_ctx.deinit(gpa);
    var db = repo_db.RepoDb.loadFromFile(gpa, io, ws_ctx.db_path) catch return;
    defer db.deinit();

    const wt_id = ws_ctx.wt_id;
    _ = materializer.syncWorktreeFromDisk(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};

    var toast = ep.switchBranchWithToast(gpa, &db, wt_id, target_branch_name) catch return;
    defer toast.deinit(gpa);

    materializer.materializeWorktreeToDir(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};
    db.saveToFile(io, ws_ctx.db_path) catch {};
    ctx.api.sync_workspace_git(ctx.host, false, true);

    if (toast.toast_message) |msg| {
        st.toast_visible = true;
        st.toast_from_branch.set(toast.old_branch);
        st.toast_banner.set(msg);
    } else {
        st.toast_visible = false;
    }

    const notice = ctx.fmt("Switched to @{s}", .{target_branch_name});
    st.last_action_status.set(notice);
    ctx.setNotice(notice);
    refreshFromRepoDb(st, true);
}

fn performBringShelvedDraftHere(ctx: *Ctx, st: *ZigVcsPluginState) void {
    ctx.api.sync_workspace_git(ctx.host, true, false);

    const io = getIo();
    const gpa = std.heap.c_allocator;
    var ws_ctx = materializer.resolveWorkspaceContext(gpa, io, ".") catch return;
    defer ws_ctx.deinit(gpa);
    var db = repo_db.RepoDb.loadFromFile(gpa, io, ws_ctx.db_path) catch return;
    defer db.deinit();

    const wt_id = ws_ctx.wt_id;
    _ = ep.bringShelvedChangesHere(&db, wt_id, st.toast_from_branch.slice()) catch return;
    materializer.materializeWorktreeToDir(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};
    db.saveToFile(io, ws_ctx.db_path) catch {};
    ctx.api.sync_workspace_git(ctx.host, false, true);

    st.toast_visible = false;
    const notice = ctx.fmt("Brought shelved changes from {s} onto @{s} (B+C-A)", .{ st.toast_from_branch.slice(), st.current_branch.slice() });
    st.last_action_status.set(notice);
    ctx.setNotice(notice);
    refreshFromRepoDb(st, true);
}

fn performResolveConflictSide(ctx: *Ctx, st: *ZigVcsPluginState, path: []const u8, pick_ours: bool) void {
    const io = getIo();
    const gpa = std.heap.c_allocator;
    var ws_ctx = materializer.resolveWorkspaceContext(gpa, io, ".") catch return;
    defer ws_ctx.deinit(gpa);
    var db = repo_db.RepoDb.loadFromFile(gpa, io, ws_ctx.db_path) catch return;
    defer db.deinit();

    const wt_id = ws_ctx.wt_id;
    const wt = db.worktrees.items[wt_id];
    const sum = db.trees.items[wt.working_tree_id].getPathSum(path) orelse return;

    var pos_idx: usize = 0;
    var chosen_bytes: ?[]const u8 = null;
    for (sum.terms.items) |t| {
        if (t.coeff > 0) {
            if ((pick_ours and pos_idx == 0) or (!pick_ours and pos_idx > 0)) {
                chosen_bytes = db.getBlob(t.hash) orelse "";
                break;
            }
            pos_idx += 1;
        }
    }

    if (chosen_bytes) |bytes| {
        _ = db.resolveFile(wt_id, path, bytes) catch return;
        materializer.materializeWorktreeToDir(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};
        db.saveToFile(io, ws_ctx.db_path) catch {};
        ctx.api.sync_workspace_git(ctx.host, false, true);
        const side_name = if (pick_ours) st.current_branch.slice() else "incoming";
        const notice = ctx.fmt("Resolved {s} using {s}", .{ path, side_name });
        st.last_action_status.set(notice);
        ctx.setNotice(notice);
        refreshFromRepoDb(st, true);
    }
}

fn performPreviewOplogJump(st: *ZigVcsPluginState, oplog_idx: usize) void {
    const io = getIo();
    const gpa = std.heap.c_allocator;
    var ws_ctx = materializer.resolveWorkspaceContext(gpa, io, ".") catch return;
    defer ws_ctx.deinit(gpa);
    var db = repo_db.RepoDb.loadFromFile(gpa, io, ws_ctx.db_path) catch return;
    defer db.deinit();

    const diff_txt = ep.previewOplogJumpDiff(gpa, &db, ws_ctx.wt_id, oplog_idx) catch return;
    defer gpa.free(diff_txt);

    st.oplog_preview_active = true;
    st.oplog_preview_index = oplog_idx;
    if (oplog_idx < db.oplog.items.len) {
        st.oplog_preview_op.set(db.oplog.items[oplog_idx].command_desc);
    }
    const first_line = if (std.mem.indexOfScalar(u8, diff_txt, '\n')) |nl| diff_txt[0..nl] else diff_txt;
    st.oplog_preview_diff.set(if (first_line.len > 0) first_line else "(No tree changes vs current)");
}

fn performRestoreOplog(ctx: *Ctx, st: *ZigVcsPluginState, oplog_idx: usize) void {
    // Refinement 3a: Auto-save open editor buffers before restoring an oplog state!
    ctx.api.sync_workspace_git(ctx.host, true, false);

    const io = getIo();
    const gpa = std.heap.c_allocator;
    var ws_ctx = materializer.resolveWorkspaceContext(gpa, io, ".") catch return;
    defer ws_ctx.deinit(gpa);
    var db = repo_db.RepoDb.loadFromFile(gpa, io, ws_ctx.db_path) catch return;
    defer db.deinit();

    const wt_id = ws_ctx.wt_id;
    _ = materializer.syncWorktreeFromDisk(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};

    ep.executeOplogJumpGuarded(&db, oplog_idx, false) catch return;
    materializer.materializeWorktreeToDir(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};
    db.saveToFile(io, ws_ctx.db_path) catch {};
    ctx.api.sync_workspace_git(ctx.host, false, true);

    st.oplog_preview_active = false;
    const notice = ctx.fmt("Restored oplog #{d} ({s})", .{ oplog_idx, st.oplog_preview_op.slice() });
    st.last_action_status.set(notice);
    ctx.setNotice(notice);
    refreshFromRepoDb(st, true);
}

fn performUndoRedo(ctx: *Ctx, st: *ZigVcsPluginState, is_undo: bool) void {
    ctx.api.sync_workspace_git(ctx.host, true, false);

    const io = getIo();
    const gpa = std.heap.c_allocator;
    var ws_ctx = materializer.resolveWorkspaceContext(gpa, io, ".") catch return;
    defer ws_ctx.deinit(gpa);
    var db = repo_db.RepoDb.loadFromFile(gpa, io, ws_ctx.db_path) catch return;
    defer db.deinit();

    const wt_id = ws_ctx.wt_id;
    const ok = if (is_undo) (db.undo() catch false) else (db.redo() catch false);
    if (ok) {
        materializer.materializeWorktreeToDir(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};
        db.saveToFile(io, ws_ctx.db_path) catch {};
        ctx.api.sync_workspace_git(ctx.host, false, true);
        const notice = if (is_undo) "zig-vcs: Undid last operation (O(1) snapshot)" else "zig-vcs: Redid operation";
        st.last_action_status.set(notice);
        ctx.setNotice(notice);
        refreshFromRepoDb(st, true);
    }
}

fn performPreviewAmendCascade(st: *ZigVcsPluginState, target_cid: u64) void {
    const io = getIo();
    const gpa = std.heap.c_allocator;
    var ws_ctx = materializer.resolveWorkspaceContext(gpa, io, ".") catch return;
    defer ws_ctx.deinit(gpa);
    var db = repo_db.RepoDb.loadFromFile(gpa, io, ws_ctx.db_path) catch return;
    defer db.deinit();

    const wt_id = ws_ctx.wt_id;
    _ = materializer.syncWorktreeFromDisk(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};

    const max_pushed: ?repo_db.CommitId = if (st.git_synced_max_commit > 0) @intCast(st.git_synced_max_commit) else null;
    var dry_run = ep.previewAmendCascadeDryRun(gpa, &db, wt_id, @intCast(target_cid), max_pushed) catch return;
    defer dry_run.deinit(gpa);

    st.cascade_preview_active = true;
    st.cascade_preview_commit = target_cid;
    st.cascade_impacts_count = dry_run.impacts.len;
    st.cascade_new_conflicts = dry_run.total_new_conflicts;
}

fn performAmendCommit(ctx: *Ctx, st: *ZigVcsPluginState, target_cid: u64) void {
    ctx.api.sync_workspace_git(ctx.host, true, false);

    const io = getIo();
    const gpa = std.heap.c_allocator;
    var ws_ctx = materializer.resolveWorkspaceContext(gpa, io, ".") catch return;
    defer ws_ctx.deinit(gpa);
    var db = repo_db.RepoDb.loadFromFile(gpa, io, ws_ctx.db_path) catch return;
    defer db.deinit();

    const wt_id = ws_ctx.wt_id;
    _ = materializer.syncWorktreeFromDisk(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};

    const new_msg: ?[]const u8 = if (st.commit_msg.slice().len > 0) st.commit_msg.slice() else null;
    const max_pushed: ?repo_db.CommitId = if (st.git_synced_max_commit > 0) @intCast(st.git_synced_max_commit) else null;
    const new_cid = ep.amendCommitGuarded(
        &db,
        wt_id,
        @intCast(target_cid),
        new_msg,
        max_pushed,
        st.unlock_immutable_rewrite,
    ) catch |err| {
        st.last_action_status.set(ctx.fmt("Amend blocked: {s}", .{@errorName(err)}));
        return;
    };

    materializer.materializeWorktreeToDir(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};
    db.saveToFile(io, ws_ctx.db_path) catch {};
    ctx.api.sync_workspace_git(ctx.host, false, true);

    st.cascade_preview_active = false;
    st.unlock_immutable_rewrite = false;
    const notice = ctx.fmt("Amended c{d} -> c{d} (cascaded descendants)", .{ target_cid, new_cid });
    st.last_action_status.set(notice);
    ctx.setNotice(notice);
    refreshFromRepoDb(st, true);
}

fn performBackoutCommit(ctx: *Ctx, st: *ZigVcsPluginState, target_cid: u64) void {
    ctx.api.sync_workspace_git(ctx.host, true, false);

    const io = getIo();
    const gpa = std.heap.c_allocator;
    var ws_ctx = materializer.resolveWorkspaceContext(gpa, io, ".") catch return;
    defer ws_ctx.deinit(gpa);
    var db = repo_db.RepoDb.loadFromFile(gpa, io, ws_ctx.db_path) catch return;
    defer db.deinit();

    const wt_id = ws_ctx.wt_id;
    _ = materializer.syncWorktreeFromDisk(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};

    const author = db.getConfig("user.name") orelse "developer";
    const backout_msg = ctx.fmt("Backout commit c{d}", .{target_cid});
    const new_cid = db.backoutCommit(wt_id, @intCast(target_cid), author, backout_msg) catch return;
    materializer.materializeWorktreeToDir(gpa, io, &db, wt_id, ws_ctx.worktree_dir) catch {};
    db.saveToFile(io, ws_ctx.db_path) catch {};
    ctx.api.sync_workspace_git(ctx.host, false, true);

    const notice = ctx.fmt("Backed out c{d} as commit c{d} (T_head + T_parent - T_c)", .{ target_cid, new_cid });
    st.last_action_status.set(notice);
    ctx.setNotice(notice);
    refreshFromRepoDb(st, true);
}

// ============================================================================
// 5. Sidebar, Status Bar & Lifecycle Hook Implementations
// ============================================================================

const AccentNone: u8 = 0;
const AccentEmerald: u8 = 1;
const AccentAmber: u8 = 2;
const AccentCrimson: u8 = 3;

fn applyPendingMutations(ctx: *Ctx, st: *ZigVcsPluginState) void {
    const kind = st.pending_kind;
    if (kind == .none) return;
    st.pending_kind = .none;

    switch (kind) {
        .none => {},
        .sync_refresh => {
            ctx.api.sync_workspace_git(ctx.host, true, false);
            refreshFromRepoDb(st, true);
        },
        .toggle_branches_dropdown => {
            st.show_branches_dropdown = !st.show_branches_dropdown;
        },
        .toggle_git_mode => {
            st.show_git_fallback_mode = !st.show_git_fallback_mode;
        },
        .toggle_math_mode => {
            st.math_mode = !st.math_mode;
        },
        .dismiss_toast => {
            st.toast_visible = false;
        },
        .bring_shelved_draft => {
            performBringShelvedDraftHere(ctx, st);
        },
        .switch_branch => {
            if (st.pending_index < st.branch_count) {
                var br_name: [32]u8 = undefined;
                const src = st.branches[st.pending_index].name.slice();
                @memcpy(br_name[0..src.len], src);
                performSwitchBranch(ctx, st, br_name[0..src.len]);
            }
        },
        .commit_checked => {
            performCommitChecked(ctx, st);
        },
        .toggle_file_checked => {
            if (st.pending_index < st.file_count) {
                st.files[st.pending_index].checked = !st.files[st.pending_index].checked;
            }
        },
        .toggle_file_hunks => {
            if (st.pending_index < st.file_count) {
                st.files[st.pending_index].expanded_hunks = !st.files[st.pending_index].expanded_hunks;
            }
        },
        .toggle_line_checked => {
            if (st.pending_index < st.file_count) {
                const f = &st.files[st.pending_index];
                if (st.pending_sub_index < f.line_count) {
                    f.line_checked[st.pending_sub_index] = !f.line_checked[st.pending_sub_index];
                }
            }
        },
        .resolve_conflict_ours => {
            if (st.pending_index < st.file_count) {
                var p_buf: [80]u8 = undefined;
                const src = st.files[st.pending_index].path.slice();
                @memcpy(p_buf[0..src.len], src);
                performResolveConflictSide(ctx, st, p_buf[0..src.len], true);
            }
        },
        .resolve_conflict_theirs => {
            if (st.pending_index < st.file_count) {
                var p_buf: [80]u8 = undefined;
                const src = st.files[st.pending_index].path.slice();
                @memcpy(p_buf[0..src.len], src);
                performResolveConflictSide(ctx, st, p_buf[0..src.len], false);
            }
        },
        .select_commit => {
            const cid = st.pending_u64;
            if (st.selected_commit_id == cid) {
                st.selected_commit_id = 0;
                st.cascade_preview_active = false;
            } else {
                st.selected_commit_id = cid;
                performPreviewAmendCascade(st, cid);
            }
        },
        .unlock_immutable => {
            st.unlock_immutable_rewrite = true;
        },
        .amend_commit => {
            performAmendCommit(ctx, st, st.pending_u64);
        },
        .backout_commit => {
            performBackoutCommit(ctx, st, st.pending_u64);
        },
        .undo_op => {
            performUndoRedo(ctx, st, true);
        },
        .redo_op => {
            performUndoRedo(ctx, st, false);
        },
        .toggle_oplog_expanded => {
            st.oplog_expanded = !st.oplog_expanded;
            refreshFromRepoDb(st, false);
        },
        .preview_oplog_jump => {
            performPreviewOplogJump(st, st.pending_index);
        },
        .restore_oplog => {
            performRestoreOplog(ctx, st, st.pending_index);
        },
        .cancel_oplog_preview => {
            st.oplog_preview_active = false;
        },
    }
}

fn registerCommands(ctx: *Ctx) void {
    _ = ctx.api.register_command(ctx.host, AbiSlice.fromZig("zig_vcs.refresh"), AbiSlice.fromZig("zig-vcs: Sync & Refresh Repository State"), AbiSlice.fromZig("zig-vcs"), AbiSlice.fromZig("ZVCS"));
    _ = ctx.api.register_command(ctx.host, AbiSlice.fromZig("zig_vcs.commit"), AbiSlice.fromZig("zig-vcs: Commit Checked Files"), AbiSlice.fromZig("zig-vcs"), AbiSlice.fromZig("Cmd+Enter"));
    _ = ctx.api.register_command(ctx.host, AbiSlice.fromZig("zig_vcs.undo"), AbiSlice.fromZig("zig-vcs: Atomic O(1) Undo Last Operation"), AbiSlice.fromZig("zig-vcs"), AbiSlice.fromZig("Undo"));
    _ = ctx.api.register_command(ctx.host, AbiSlice.fromZig("zig_vcs.redo"), AbiSlice.fromZig("zig-vcs: Atomic O(1) Redo Operation"), AbiSlice.fromZig("zig-vcs"), AbiSlice.fromZig("Redo"));
    _ = ctx.api.register_command(ctx.host, AbiSlice.fromZig("zig_vcs.toggle_math"), AbiSlice.fromZig("zig-vcs: Toggle Algebraic Math Mode (Z[A_bot])"), AbiSlice.fromZig("zig-vcs"), AbiSlice.fromZig("Math"));
    _ = ctx.api.register_command(ctx.host, AbiSlice.fromZig("zig_vcs.fsck"), AbiSlice.fromZig("zig-vcs: Run Formal Invariant & BLAKE3 Integrity Check (fsck)"), AbiSlice.fromZig("zig-vcs"), AbiSlice.fromZig("INV-1..6"));
}

fn onInit(host: *anyopaque, api: *const EditorHostApiV1) callconv(.c) void {
    var ctx = Ctx{ .host = host, .api = api };
    registerCommands(&ctx);
    const st = ctx.state();
    refreshFromRepoDb(st, true);
}

fn onReload(host: *anyopaque, api: *const EditorHostApiV1) callconv(.c) void {
    var ctx = Ctx{ .host = host, .api = api };
    registerCommands(&ctx);
    const st = ctx.state();
    refreshFromRepoDb(st, false);
}

fn onBufferSave(host: *anyopaque, api: *const EditorHostApiV1, _: *const BufferInfoV1) callconv(.c) void {
    var ctx = Ctx{ .host = host, .api = api };
    const st = ctx.state();
    refreshFromRepoDb(st, true);
}

fn onCommand(host: *anyopaque, api: *const EditorHostApiV1, cmd_id_abi: AbiSlice) callconv(.c) void {
    var ctx = Ctx{ .host = host, .api = api };
    const st = ctx.state();
    const cmd = cmd_id_abi.toZig();

    if (std.mem.eql(u8, cmd, "zig_vcs.refresh")) {
        ctx.api.sync_workspace_git(ctx.host, true, false);
        refreshFromRepoDb(st, true);
        ctx.setNotice("zig-vcs: Synchronized worktree with .vcs/db.vcs");
    } else if (std.mem.eql(u8, cmd, "zig_vcs.commit")) {
        performCommitChecked(&ctx, st);
    } else if (std.mem.eql(u8, cmd, "zig_vcs.undo")) {
        performUndoRedo(&ctx, st, true);
    } else if (std.mem.eql(u8, cmd, "zig_vcs.redo")) {
        performUndoRedo(&ctx, st, false);
    } else if (std.mem.eql(u8, cmd, "zig_vcs.toggle_math")) {
        st.math_mode = !st.math_mode;
        ctx.setNotice(if (st.math_mode) "zig-vcs: Enabled Z[A_bot] Math Mode" else "zig-vcs: Switched to Human-First Provenance Labels");
    } else if (std.mem.eql(u8, cmd, "zig_vcs.fsck")) {
        ctx.api.run_terminal_command(ctx.host, AbiSlice.fromZig("./zig-out/bin/zig_vcs fsck"));
    }
}

fn renderStatusBar(host: *anyopaque, api: *const EditorHostApiV1) callconv(.c) void {
    var ctx = Ctx{ .host = host, .api = api };
    const st = ctx.state();
    if (ctx.isInputPass() and !st.initialized) {
        refreshFromRepoDb(st, false);
    }
    if (!st.has_zvcs_db) return;

    var conflict_count: usize = 0;
    for (st.files[0..st.file_count]) |f| {
        if (f.has_conflict) conflict_count += 1;
    }

    const chip_lbl = if (conflict_count > 0)
        ctx.fmt("zvcs: @{s} (c{d} · ⚡{d} conflict)##zvcs_sb", .{ st.current_branch.slice(), st.head_commit, conflict_count })
    else if (st.file_count > 0)
        ctx.fmt("zvcs: @{s} (c{d} · +{d} dirty)##zvcs_sb", .{ st.current_branch.slice(), st.head_commit, st.file_count })
    else
        ctx.fmt("zvcs: @{s} (c{d} · ✓)##zvcs_sb", .{ st.current_branch.slice(), st.head_commit });

    if (ctx.chip(chip_lbl, conflict_count == 0)) {
        st.schedule(&ctx, .sync_refresh, 0, 0, 0);
    }
}

fn renderSidebar(host: *anyopaque, api: *const EditorHostApiV1) callconv(.c) void {
    var ctx = Ctx{ .host = host, .api = api };
    const st = ctx.state();
    if (ctx.isInputPass()) {
        applyPendingMutations(&ctx, st);
        refreshFromRepoDb(st, false);
    }

    // Top Header Bar + Provider Mode / Math Mode Toggles
    ctx.beginRow(28, 6);
    if (st.has_zvcs_db) {
        if (ctx.chip(ctx.fmt("@{s} (c{d})##zvcs_br_chip", .{ st.current_branch.slice(), st.head_commit }), !st.show_git_fallback_mode)) {
            st.schedule(&ctx, .toggle_branches_dropdown, 0, 0, 0);
        }
    }
    if (st.has_git_dir) {
        if (ctx.chip(if (st.show_git_fallback_mode) "Mode: Git ⇄##zvcs_git_mode" else "ZVCS ⇄ Git##zvcs_git_mode", st.show_git_fallback_mode)) {
            st.schedule(&ctx, .toggle_git_mode, 0, 0, 0);
        }
    }
    if (ctx.chip(if (st.math_mode) "Z[A_bot]##zvcs_math" else "Human Labels##zvcs_math", st.math_mode)) {
        st.schedule(&ctx, .toggle_math_mode, 0, 0, 0);
    }
    if (ctx.button("Sync##zvcs_sync", 52, 24)) {
        st.schedule(&ctx, .sync_refresh, 0, 0, 0);
    }
    ctx.endBox();

    if (!st.has_zvcs_db or st.show_git_fallback_mode) {
        renderGitCompatibilityView(&ctx, st);
        return;
    }

    // Refinement 4: Live Git Sync Bridge Health Pill
    ctx.beginRow(24, 6);
    _ = ctx.chip(ctx.fmt("{s}##zvcs_bridge_pill", .{st.bridge_pill.slice()}), st.bridge_can_export);
    if (ctx.button("Push##zvcs_push_btn", 48, 22)) {
        if (st.bridge_can_export) {
            ctx.api.run_terminal_command(ctx.host, AbiSlice.fromZig("./zig-out/bin/zig_vcs push origin main"));
        } else {
            ctx.setNotice("Git Export Blocked: Resolve committed PathSum conflicts before pushing to Git.");
        }
    }
    if (ctx.button("Pull##zvcs_pull_btn", 48, 22)) {
        ctx.api.run_terminal_command(ctx.host, AbiSlice.fromZig("./zig-out/bin/zig_vcs pull origin main"));
    }
    ctx.endBox();

    if (st.last_action_status.slice().len > 0) {
        ctx.monoLabel(st.last_action_status.slice());
    }

    // Refinement 1c: Auto-Shelved Draft Toast on 1-Click Branch Switch
    if (st.toast_visible) {
        ctx.divider();
        ctx.label(st.toast_banner.slice());
        ctx.beginRow(26, 6);
        if (ctx.button("Bring Changes Here (B+C-A)##zvcs_bring_draft", 190, 24)) {
            st.schedule(&ctx, .bring_shelved_draft, 0, 0, 0);
        }
        if (ctx.button("Keep Shelved##zvcs_dismiss_toast", 96, 24)) {
            st.schedule(&ctx, .dismiss_toast, 0, 0, 0);
        }
        ctx.endBox();
    }

    // Expandable Branch Switcher (with per-branch draft badges)
    if (st.show_branches_dropdown) {
        ctx.divider();
        ctx.sectionLabel("BRANCHES & DRAFTS (NO STASH NEEDED)");
        for (st.branches[0..st.branch_count], 0..) |b, b_i| {
            ctx.pushId(ctx.fmt("br_{d}", .{b_i}));
            const meta = if (b.has_draft)
                ctx.fmt("c{d} · ● draft", .{b.head_commit})
            else
                ctx.fmt("c{d}", .{b.head_commit});
            const row = ctx.listItemAction(
                b.name.slice(),
                meta,
                if (b.is_current) "@" else " ",
                if (b.is_current) AccentEmerald else AccentNone,
                b.is_current,
                if (b.is_current) "Active" else "Switch",
            );
            if ((row.clicked or row.action_clicked) and !b.is_current) {
                st.schedule(&ctx, .switch_branch, b_i, 0, 0);
            }
            ctx.popId();
        }
    }

    ctx.divider();

    // ========================================================================
    // Working Changes + Safe Checkboxes + Sub-File Lines + 2-Pane Conflict Delta
    // ========================================================================
    ctx.sectionLabel(ctx.fmt("WORKING CHANGES ({d}) — @{s}", .{ st.file_count, st.current_worktree.slice() }));

    const tf_res = ctx.textField("##zvcs_commit_msg", &st.commit_msg, "Commit message (no staging index needed)...");
    if (tf_res.submitted) {
        st.schedule(&ctx, .commit_checked, 0, 0, 0);
    }

    // Compute Commit Button Guardrail State (Refinement 1a)
    var checked_total: usize = 0;
    var checked_conflicts: usize = 0;
    for (st.files[0..st.file_count]) |f| {
        if (f.checked) {
            checked_total += 1;
            if (f.has_conflict) checked_conflicts += 1;
        }
    }
    const btn_label = if (checked_total == 0)
        "Commit Checked (0)"
    else if (checked_conflicts > 0)
        ctx.fmt("Commit Checked (Includes {d} Conflict{s} ⚡)", .{ checked_conflicts, if (checked_conflicts == 1) "" else "s" })
    else
        ctx.fmt("Commit Checked ({d})", .{checked_total});

    ctx.beginRow(28, 6);
    if (ctx.button(ctx.fmt("{s}##zvcs_commit_btn", .{btn_label}), 0, 26)) {
        if (checked_total > 0) {
            st.schedule(&ctx, .commit_checked, 0, 0, 0);
        }
    }
    ctx.endBox();

    if (st.file_count == 0) {
        ctx.mutedLabel("Working tree clean (matches HEAD).");
    } else {
        for (st.files[0..st.file_count], 0..) |*f, f_idx| {
            ctx.pushId(ctx.fmt("wf_{d}", .{f_idx}));
            const check_glyph = if (f.checked) "[✓]" else "[ ]";
            const badge = statusBadgeText(f.status);
            const accent: u8 = switch (f.status) {
                .conflicted => AccentAmber,
                .added => AccentEmerald,
                .deleted => AccentCrimson,
                .modified => AccentAmber,
            };
            const item_lbl = ctx.fmt("{s} {s}", .{ check_glyph, f.path.slice() });
            const action_lbl = if (f.has_conflict)
                "Resolve ▾"
            else if (f.line_count > 1)
                (if (f.expanded_hunks) "Lines ▴" else "Lines ▾")
            else
                "Diff";

            const row = ctx.listItemAction(
                item_lbl,
                badge,
                if (f.has_conflict) "⚡" else "●",
                accent,
                f.checked,
                action_lbl,
            );
            if (row.clicked) {
                st.schedule(&ctx, .toggle_file_checked, f_idx, 0, 0);
            } else if (row.action_clicked) {
                if (f.line_count > 1 or f.has_conflict) {
                    st.schedule(&ctx, .toggle_file_hunks, f_idx, 0, 0);
                } else {
                    ctx.api.open_git_diff(ctx.host, AbiSlice.fromZig(f.path.slice()), AbiSlice.fromZig(""), false, false);
                }
            } else if (row.secondary_action_clicked) {
                _ = ctx.api.open_file_path(ctx.host, AbiSlice.fromZig(f.path.slice()));
            }

            // Refinement 2a & 2b: 2-Pane Conflict Delta Inspector & Human-First Provenance Labels
            if (f.has_conflict) {
                if (st.math_mode and f.math_badge.slice().len > 0) {
                    ctx.monoLabel(ctx.fmt("  {s}", .{f.math_badge.slice()}));
                }
                ctx.monoLabel(ctx.fmt("  Ours: {s} | Theirs: {s}", .{
                    f.ours_summary.slice(),
                    f.theirs_summary.slice(),
                }));
                ctx.beginRow(24, 6);
                if (ctx.button(ctx.fmt("{s}##res_ours_{d}", .{ f.keep_left_label.slice(), f_idx }), 126, 22)) {
                    st.schedule(&ctx, .resolve_conflict_ours, f_idx, 0, 0);
                }
                if (ctx.button(ctx.fmt("{s}##res_theirs_{d}", .{ f.take_right_label.slice(), f_idx }), 126, 22)) {
                    st.schedule(&ctx, .resolve_conflict_theirs, f_idx, 0, 0);
                }
                ctx.endBox();
            }

            // Refinement 1b: Sub-File Line/Hunk Checkboxes
            if (f.expanded_hunks and f.line_count > 0) {
                for (0..f.line_count) |l_i| {
                    ctx.pushId(ctx.fmt("ln_{d}", .{l_i}));
                    const ln_glyph = if (f.line_checked[l_i]) "  [✓]" else "  [ ]";
                    if (ctx.listItem(
                        ctx.fmt("{s} L{d}: {s}", .{ ln_glyph, f.line_numbers[l_i], f.line_previews[l_i].slice() }),
                        "line",
                        f.line_checked[l_i],
                    )) {
                        st.schedule(&ctx, .toggle_line_checked, f_idx, l_i, 0);
                    }
                    ctx.popId();
                }
            }
            ctx.popId();
        }
    }

    ctx.divider();

    // ========================================================================
    // Commit Graph (`log`) + Immutable Lock Glyphs + Amend Cascade Dry-Run
    // ========================================================================
    ctx.sectionLabel("COMMIT DAG (LOCAL TIME ±HHMM & CASCADE)");

    for (st.commits[0..st.commit_count], 0..) |c, c_i| {
        ctx.pushId(ctx.fmt("cm_{d}", .{c_i}));
        var tz_buf: [5]u8 = undefined;
        const tz_str = repo_db.formatTzOffsetBuf(c.tz_offset_min, &tz_buf);
        const lock_prefix = if (c.is_locked_git) "🔒 " else "";
        const conflict_suffix = if (c.has_conflicts) " ⚡" else "";
        const lbl = ctx.fmt("{s}c{d}{s}  {s}", .{ lock_prefix, c.id, conflict_suffix, c.subject.slice() });
        const meta = ctx.fmt("{s}", .{tz_str});
        const is_sel = (st.selected_commit_id == c.id);

        const row = ctx.listItemAction(
            lbl,
            meta,
            if (c.id == st.head_commit) "@" else "●",
            if (c.has_conflicts) AccentAmber else if (c.id == st.head_commit) AccentEmerald else AccentNone,
            is_sel,
            "Inspect",
        );
        if (row.clicked or row.action_clicked) {
            st.schedule(&ctx, .select_commit, c_i, 0, c.id);
        }

        // Refinement 3b: Cascade Dry-Run Preview & Immutable Commit Lock Guard
        if (is_sel and c.id > 0) {
            if (st.cascade_preview_active and st.cascade_preview_commit == c.id) {
                const status_badge = if (st.cascade_new_conflicts == 0)
                    "✓ Clean Cascade"
                else
                    ctx.fmt("⚡ Creates {d} conflict(s)", .{st.cascade_new_conflicts});
                ctx.monoLabel(ctx.fmt("  Cascade (T_C' - T_C): {d} target(s) · {s}", .{
                    st.cascade_impacts_count,
                    status_badge,
                }));
            }
            if (c.is_locked_git and !st.unlock_immutable_rewrite) {
                ctx.beginRow(24, 6);
                ctx.mutedLabel("  🔒 Pushed to Git");
                if (ctx.button("Unlock Rewrite##zvcs_unlock", 104, 22)) {
                    st.schedule(&ctx, .unlock_immutable, 0, 0, 0);
                }
                if (ctx.button(ctx.fmt("Undo c{d} (B+C-A)##zvcs_backout", .{c.id}), 116, 22)) {
                    st.schedule(&ctx, .backout_commit, 0, 0, c.id);
                }
                ctx.endBox();
            } else {
                ctx.beginRow(24, 6);
                if (ctx.button(ctx.fmt("Amend c{d} & Cascade##zvcs_amend", .{c.id}), 134, 22)) {
                    st.schedule(&ctx, .amend_commit, 0, 0, c.id);
                }
                if (ctx.button(ctx.fmt("Backout c{d}##zvcs_backout2", .{c.id}), 96, 22)) {
                    st.schedule(&ctx, .backout_commit, 0, 0, c.id);
                }
                ctx.endBox();
            }
        }
        ctx.popId();
    }

    ctx.divider();

    // ========================================================================
    // Refinement 3a: Collapsed Single-Line Oplog Footer Bar & Read-Only Jump Preview
    // ========================================================================
    ctx.monoLabel(st.collapsed_oplog_bar.slice());

    ctx.beginRow(26, 6);
    if (ctx.button("↶ Undo##zvcs_undo_btn", 68, 24)) {
        st.schedule(&ctx, .undo_op, 0, 0, 0);
    }
    if (ctx.button("↷ Redo##zvcs_redo_btn", 68, 24)) {
        st.schedule(&ctx, .redo_op, 0, 0, 0);
    }
    if (ctx.button(if (st.oplog_expanded) "Collapse ▾##zvcs_scrub" else "Scrub ▴##zvcs_scrub", 86, 24)) {
        st.schedule(&ctx, .toggle_oplog_expanded, 0, 0, 0);
    }
    ctx.endBox();

    if (st.oplog_expanded) {
        if (st.oplog_preview_active) {
            ctx.monoLabel(ctx.fmt("Preview #{d} ({s}): {s}", .{
                st.oplog_preview_index,
                st.oplog_preview_op.slice(),
                st.oplog_preview_diff.slice(),
            }));
            ctx.beginRow(24, 6);
            if (ctx.button(ctx.fmt("Restore #{d} (Auto-Saves Buffers)##zvcs_oplog_restore", .{st.oplog_preview_index}), 200, 22)) {
                st.schedule(&ctx, .restore_oplog, st.oplog_preview_index, 0, 0);
            }
            if (ctx.button("Cancel##zvcs_oplog_cancel", 64, 22)) {
                st.schedule(&ctx, .cancel_oplog_preview, 0, 0, 0);
            }
            ctx.endBox();
        }

        for (st.oplog_items[0..st.oplog_item_count], 0..) |op, o_i| {
            ctx.pushId(ctx.fmt("op_{d}", .{o_i}));
            const op_lbl = ctx.fmt("#{d}  {s}", .{ op.index, op.op_name.slice() });
            const op_meta = ctx.fmt("c{d}", .{op.head_commit});
            const is_prev = st.oplog_preview_active and (st.oplog_preview_index == op.index);
            if (ctx.listItem(op_lbl, op_meta, is_prev)) {
                st.schedule(&ctx, .preview_oplog_jump, op.index, 0, 0);
            }
            ctx.popId();
        }
    }
}

fn renderGitCompatibilityView(ctx: *Ctx, st: *ZigVcsPluginState) void {
    ctx.divider();
    if (!st.has_zvcs_db) {
        ctx.sectionLabel("INITIALIZE ZIG-VCS IN WORKSPACE");
        ctx.mutedLabel("No .vcs/db.vcs found. Initialize zig-vcs to enable per-branch drafts, algebraic B+C-A merges, and O(1) oplog undo.");
        ctx.beginRow(28, 6);
        if (ctx.button("Init .vcs/db.vcs##zvcs_init_btn", 130, 26)) {
            ctx.api.run_terminal_command(ctx.host, AbiSlice.fromZig("./zig-out/bin/zig_vcs init"));
            st.schedule(ctx, .sync_refresh, 0, 0, 0);
        }
        ctx.endBox();
        ctx.divider();
    }

    var snap = GitStatusSnapshotV1{};
    if (!ctx.api.get_git_status(ctx.host, &snap)) {
        ctx.mutedLabel("Git status unavailable.");
        return;
    }

    ctx.sectionLabel(ctx.fmt("GIT COMPATIBILITY VIEW ({s})", .{snap.branch.toZig()}));
    if (snap.files_ptr) |files_ptr| {
        const files = files_ptr[0..snap.file_count];
        for (files, 0..) |f, idx| {
            ctx.pushId(ctx.fmt("git_f_{d}", .{idx}));
            var st_buf: [2]u8 = .{ f.status, 0 };
            if (ctx.listItem(f.path.toZig(), st_buf[0..1], f.staged)) {
                ctx.api.open_git_diff(ctx.host, f.path, AbiSlice.fromZig(""), f.staged, false);
            }
            ctx.popId();
        }
    }
}

// ============================================================================
// 6. Exported C-ABI Entry Point (`editor_plugin_entry_v1`)
// ============================================================================

pub const PLUGIN_DESCRIPTOR = EditorPluginV1{
    .manifest = .{
        .abi_version = EDITOR_PLUGIN_ABI_VERSION,
        .id = AbiSlice.fromZig("zig_vcs.source_control"),
        .display_name = AbiSlice.fromZig("zig-vcs Algebraic Source Control"),
        .version = AbiSlice.fromZig("0.2.0"),
        .capabilities = .{
            .commands = true,
            .buffer_hooks = true,
            .sidebar_panel = true,
            .status_bar = true,
        },
        .sidebar_icon = .git,
        .sidebar_title = AbiSlice.fromZig("ZIG-VCS SOURCE CONTROL"),
    },
    .init = &onInit,
    .on_reload = &onReload,
    .on_command = &onCommand,
    .on_buffer_save = &onBufferSave,
    .render_sidebar = &renderSidebar,
    .render_status_bar = &renderStatusBar,
};

pub fn editor_plugin_entry_v1() callconv(.c) *const EditorPluginV1 {
    return &PLUGIN_DESCRIPTOR;
}

comptime {
    @export(&editor_plugin_entry_v1, .{ .name = PLUGIN_ENTRY_SYMBOL, .linkage = .strong });
}

test "LightningVcsPlugin: C-ABI descriptor & state size conformance" {
    const desc = editor_plugin_entry_v1();
    try std.testing.expectEqual(EDITOR_PLUGIN_ABI_VERSION, desc.manifest.abi_version);
    try std.testing.expectEqualStrings("zig_vcs.source_control", desc.manifest.id.toZig());
    try std.testing.expectEqual(PluginSidebarIcon.git, desc.manifest.sidebar_icon);
    try std.testing.expect(desc.manifest.capabilities.sidebar_panel);
    try std.testing.expect(desc.manifest.capabilities.status_bar);
    try std.testing.expect(desc.manifest.capabilities.commands);
    try std.testing.expect(@sizeOf(ZigVcsPluginState) <= 24576);
}
