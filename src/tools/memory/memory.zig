const std = @import("std");
const memory_core = @import("../../core/memory/memory.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");

const Allocator = std.mem.Allocator;

pub const Action = enum {
    save,
    search,
    list,
    update,
    forget,
};

pub const Input = struct {
    action: Action,
    scope: ?memory_core.Scope = null,
    kind: ?memory_core.Kind = null,
    id: ?[]u8 = null,
    title: ?[]u8 = null,
    content: ?[]u8 = null,
    query: ?[]u8 = null,
    tags: ?[][]u8 = null,
    importance: ?u8 = null,
    limit: usize = 10,
    reason: ?[]u8 = null,
    include_inactive: bool = false,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        if (self.id) |v| alloc.free(v);
        if (self.title) |v| alloc.free(v);
        if (self.content) |v| alloc.free(v);
        if (self.query) |v| alloc.free(v);
        if (self.tags) |tags| {
            for (tags) |t| alloc.free(t);
            alloc.free(tags);
        }
        if (self.reason) |v| alloc.free(v);
        self.* = undefined;
    }
};

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn optionalString(alloc: Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .null => null,
        .string => |s| try alloc.dupe(u8, s),
        else => error.InvalidFieldType,
    };
}

fn optionalTags(alloc: Allocator, obj: std.json.ObjectMap) !?[][]u8 {
    const val = obj.get("tags") orelse return null;
    if (val == .null) return null;
    if (val != .array) return error.InvalidFieldType;
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |t| alloc.free(t);
        out.deinit(alloc);
    }
    for (val.array.items) |item| {
        if (item != .string) return error.InvalidFieldType;
        try out.append(alloc, try alloc.dupe(u8, item.string));
    }
    return try out.toOwnedSlice(alloc);
}

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var decoder: tool_args.ArgsDecoder = .{ .alloc = ctx.allocator, .tool = "memories" };
    var parsed = decoder.parse(args_json) catch |err| return .{ .failure = try decoder.takeFailure(err) };
    defer parsed.deinit();

    const args = (try tool_args.unwrapRequest(parsed.arena.allocator(), parsed.value.object)) orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "memories arguments must be a JSON object") };
    };

    const action_val = args.get("action") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "memories requires action: save, search, list, update, or forget") };
    };
    if (action_val != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "memories action must be a string: save, search, list, update, or forget") };
    }
    const action = std.meta.stringToEnum(Action, action_val.string) orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "memories action must be save, search, list, update, or forget") };
    };

    var scope: ?memory_core.Scope = null;
    if (args.get("scope")) |v| if (v != .null) {
        if (v != .string) return .{ .failure = try ctx.allocator.dupe(u8, "memories scope must be user, agent, workspace, or shared") };
        scope = memory_core.Scope.parse(v.string) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "memories scope must be user, agent, workspace, or shared") };
        };
    };

    var kind: ?memory_core.Kind = null;
    if (args.get("kind")) |v| if (v != .null) {
        if (v != .string) return .{ .failure = try ctx.allocator.dupe(u8, "memories kind must be fact, preference, decision, procedure, entity, or episodic") };
        kind = memory_core.Kind.parse(v.string) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "memories kind must be fact, preference, decision, procedure, entity, or episodic") };
        };
    };

    var importance: ?u8 = null;
    if (args.get("importance")) |v| if (v != .null) {
        if (v != .integer or v.integer < 1 or v.integer > 5) {
            return .{ .failure = try ctx.allocator.dupe(u8, "memories importance must be an integer from 1 to 5") };
        }
        importance = @intCast(v.integer);
    };

    var limit: usize = 10;
    if (args.get("limit")) |v| if (v != .null) {
        if (v != .integer or v.integer < 1 or v.integer > 50) {
            return .{ .failure = try ctx.allocator.dupe(u8, "memories limit must be an integer from 1 to 50") };
        }
        limit = @intCast(v.integer);
    };

    var include_inactive = false;
    if (args.get("include_inactive")) |v| if (v != .null) {
        if (v != .bool) return .{ .failure = try ctx.allocator.dupe(u8, "memories include_inactive must be a boolean") };
        include_inactive = v.bool;
    };

    const id = optionalString(ctx.allocator, args, "id") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "memories id must be a string") },
    };
    errdefer if (id) |v| ctx.allocator.free(v);

    const title = optionalString(ctx.allocator, args, "title") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "memories title must be a string") },
    };
    errdefer if (title) |v| ctx.allocator.free(v);

    const content = optionalString(ctx.allocator, args, "content") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "memories content must be a string") },
    };
    errdefer if (content) |v| ctx.allocator.free(v);

    const query = optionalString(ctx.allocator, args, "query") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "memories query must be a string") },
    };
    errdefer if (query) |v| ctx.allocator.free(v);

    const reason = optionalString(ctx.allocator, args, "reason") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "memories reason must be a string") },
    };
    errdefer if (reason) |v| ctx.allocator.free(v);

    const tags = optionalTags(ctx.allocator, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "memories tags must be an array of strings") },
    };
    errdefer if (tags) |t| {
        for (t) |item| ctx.allocator.free(item);
        ctx.allocator.free(t);
    };

    const input = try ctx.allocator.create(Input);
    input.* = .{
        .action = action,
        .scope = scope,
        .kind = kind,
        .id = id,
        .title = title,
        .content = content,
        .query = query,
        .tags = tags,
        .importance = importance,
        .limit = limit,
        .reason = reason,
        .include_inactive = include_inactive,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    return switch (input.action) {
        .save => if (input.content == null or std.mem.trim(u8, input.content.?, " \t\r\n").len == 0)
            try ctx.allocator.dupe(u8, "memories save requires non-empty content")
        else
            null,
        .search => if (input.query == null or std.mem.trim(u8, input.query.?, " \t\r\n").len == 0)
            try ctx.allocator.dupe(u8, "memories search requires a non-empty query")
        else
            null,
        .update => if (input.id == null or input.id.?.len == 0)
            try ctx.allocator.dupe(u8, "memories update requires id")
        else if (input.content == null or std.mem.trim(u8, input.content.?, " \t\r\n").len == 0)
            try ctx.allocator.dupe(u8, "memories update requires non-empty content")
        else
            null,
        .forget => if (input.id == null or input.id.?.len == 0)
            try ctx.allocator.dupe(u8, "memories forget requires id")
        else
            null,
        .list => null,
    };
}

fn formatEntry(writer: anytype, entry: memory_core.Entry, score: ?i64) !void {
    try writer.print("- id={s} scope={s} kind={s} importance={d}", .{
        entry.id,
        entry.scope.label(),
        entry.kind.label(),
        entry.importance,
    });
    if (score) |s| try writer.print(" score={d}", .{s});
    if (entry.title.len > 0) try writer.print(" title=\"{s}\"", .{entry.title});
    if (entry.tags.len > 0) {
        try writer.writeAll(" tags=[");
        for (entry.tags, 0..) |tag, idx| {
            if (idx > 0) try writer.writeByte(',');
            try writer.writeAll(tag);
        }
        try writer.writeByte(']');
    }
    if (entry.archived) try writer.writeAll(" [archived]");
    if (entry.superseded_by) |by| try writer.print(" [superseded_by={s}]", .{by});
    try writer.print("\n  {s}\n", .{entry.content});
}

fn memoryPaths(ctx: tool_dispatch.DispatchContext) memory_core.Paths {
    return .{
        .workspace_root = ctx.workspace_root,
        .agent_name = ctx.memory_agent_name,
    };
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return run(ctx, memoryPaths(ctx), erased.as(Input));
}

fn run(ctx: tool_dispatch.DispatchContext, paths: memory_core.Paths, input: *Input) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    switch (input.action) {
        .save => {
            // A bot's own notes are the default; workspace notes are for facts about one repository.
            const scope = input.scope orelse memory_core.Scope.agent;
            const tags_slice: []const []const u8 = if (input.tags) |t| t else &.{};
            var saved = memory_core.save(ctx.allocator, paths, .{
                .scope = scope,
                .kind = input.kind orelse .fact,
                .title = input.title orelse "",
                .content = input.content.?,
                .tags = tags_slice,
                .importance = input.importance orelse 3,
                .source = ctx.memory_agent_name,
            }) catch |err| return .{
                .failure = try ctx.allocator.print("memories save failed: {s}", .{@errorName(err)}),
            };
            defer saved.deinit(ctx.allocator);

            var out: std.Io.Writer.Allocating = .init(ctx.allocator);
            errdefer out.deinit();
            out.writer.writeAll("Saved memory:\n") catch return error.OutOfMemory;
            formatEntry(&out.writer, saved, null) catch return error.OutOfMemory;
            return .{ .success = try out.toOwnedSlice() };
        },
        .search => {
            const hits = memory_core.search(ctx.allocator, paths, .{
                .query = input.query.?,
                .scope = input.scope,
                .kind = input.kind,
                .limit = input.limit,
                .include_inactive = input.include_inactive,
            }) catch |err| return .{
                .failure = try ctx.allocator.print("memories search failed: {s}", .{@errorName(err)}),
            };
            defer {
                for (hits) |*h| h.entry.deinit(ctx.allocator);
                ctx.allocator.free(hits);
            }
            if (hits.len == 0) {
                return .{ .success = try ctx.allocator.dupe(u8, "No matching memories found.") };
            }
            var out: std.Io.Writer.Allocating = .init(ctx.allocator);
            errdefer out.deinit();
            out.writer.print("Found {d} memories:\n", .{hits.len}) catch return error.OutOfMemory;
            for (hits) |hit| {
                formatEntry(&out.writer, hit.entry, hit.score) catch return error.OutOfMemory;
            }
            return .{ .success = try out.toOwnedSlice() };
        },
        .list => {
            const entries = memory_core.list(ctx.allocator, paths, .{
                .scope = input.scope,
                .kind = input.kind,
                .limit = input.limit,
                .include_inactive = input.include_inactive,
            }) catch |err| return .{
                .failure = try ctx.allocator.print("memories list failed: {s}", .{@errorName(err)}),
            };
            defer {
                for (entries) |*e| e.deinit(ctx.allocator);
                ctx.allocator.free(entries);
            }
            if (entries.len == 0) {
                return .{ .success = try ctx.allocator.dupe(u8, "No memories stored for the requested scope.") };
            }
            var out: std.Io.Writer.Allocating = .init(ctx.allocator);
            errdefer out.deinit();
            out.writer.print("Listed {d} memories:\n", .{entries.len}) catch return error.OutOfMemory;
            for (entries) |entry| {
                formatEntry(&out.writer, entry, null) catch return error.OutOfMemory;
            }
            return .{ .success = try out.toOwnedSlice() };
        },
        .update => {
            const tags_opt: ?[]const []const u8 = if (input.tags) |t| t else null;
            var updated = memory_core.update(ctx.allocator, paths, .{
                .id = input.id.?,
                .scope = input.scope,
                .title = input.title,
                .content = input.content.?,
                .tags = tags_opt,
                .importance = input.importance,
                .source = ctx.memory_agent_name,
            }) catch |err| return .{
                .failure = try ctx.allocator.print("memories update failed: {s}", .{@errorName(err)}),
            };
            defer updated.deinit(ctx.allocator);

            var out: std.Io.Writer.Allocating = .init(ctx.allocator);
            errdefer out.deinit();
            out.writer.print("Updated memory (superseded {s}):\n", .{input.id.?}) catch return error.OutOfMemory;
            formatEntry(&out.writer, updated, null) catch return error.OutOfMemory;
            return .{ .success = try out.toOwnedSlice() };
        },
        .forget => {
            const scope = memory_core.forget(ctx.allocator, paths, input.id.?, input.scope, input.reason) catch |err| return .{
                .failure = try ctx.allocator.print("memories forget failed: {s}", .{@errorName(err)}),
            };
            return .{ .success = try ctx.allocator.print("Archived memory {s} in scope {s}.", .{ input.id.?, scope.label() }) };
        },
    }
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(Input);
    return input.action == .search or input.action == .list;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

/// Each action's row: what it does to the notes, and the text it names.
pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const raw = tool_args.optionalStringArg(args, "action") orelse return null;
    const action = std.meta.stringToEnum(Action, raw) orelse return null;
    return switch (action) {
        .save => .{ .activity_kind = .read, .action_label = "Saving note", .completed_action_label = "Saved note", .label_arg_kind = .content, .label_arg_default = "note" },
        .update => .{ .activity_kind = .read, .action_label = "Updating note", .completed_action_label = "Updated note", .label_arg_kind = .content, .label_arg_default = "note" },
        .search => .{ .activity_kind = .read, .action_label = "Searching notes", .completed_action_label = "Searched notes", .label_arg_kind = .query, .label_arg_default = "notes" },
        .list => .{ .activity_kind = .read, .action_label = "Listing notes", .completed_action_label = "Listed notes", .label_arg_kind = .none, .label_arg_default = "notes" },
        .forget => .{ .activity_kind = .read, .action_label = "Forgetting note", .completed_action_label = "Forgot note", .label_arg_kind = .none, .label_arg_default = "note" },
    };
}

test "memories tool saves to the bot's own notes by default and other bots can't see them" {
    const alloc = std.testing.allocator;
    const io_mod = @import("../../core/shared/io.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = alloc,
        .workspace_root = root,
        .memory_agent_name = "assistant",
    };
    const paths: memory_core.Paths = .{ .home_dir = root, .workspace_root = root, .agent_name = "assistant" };
    const other: memory_core.Paths = .{ .home_dir = root, .workspace_root = root, .agent_name = "bot_two" };

    const decoded_save = try decode(ctx, "{\"action\":\"save\",\"kind\":\"decision\",\"title\":\"Engine\",\"content\":\"Use fx with first-class memory\",\"tags\":[\"fx\",\"memory\"],\"importance\":5}");
    const save_input = decoded_save.input;
    defer save_input.deinit(alloc);
    try std.testing.expect((try validate(ctx, save_input)) == null);
    try std.testing.expect(!readsOnly(save_input));

    const save_res = try run(ctx, paths, save_input.as(Input));
    defer save_res.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, save_res.success, "scope=agent") != null);

    const decoded_search = try decode(ctx, "{\"action\":\"search\",\"query\":\"first-class memory\"}");
    const search_input = decoded_search.input;
    defer search_input.deinit(alloc);
    try std.testing.expect(readsOnly(search_input));

    const search_res = try run(ctx, paths, search_input.as(Input));
    defer search_res.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, search_res.success, "Use fx with first-class memory") != null);

    const other_res = try run(ctx, other, search_input.as(Input));
    defer other_res.deinit(alloc);
    try std.testing.expectEqualStrings("No matching memories found.", other_res.success);
}

test "memories tool refuses bad arguments with a clear message" {
    const alloc = std.testing.allocator;
    const ctx: tool_dispatch.DispatchContext = .{ .allocator = alloc };
    const bad = try decode(ctx, "{\"action\":\"save\",\"scope\":\"everyone\"}");
    defer alloc.free(bad.failure);
    try std.testing.expect(std.mem.startsWith(u8, bad.failure, "memories scope"));
}

test "a memories row names what it does and the note it writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"action\":\"save\",\"content\":\"Prefers tea\"}", .{});
    const shown = presentation(parsed.object).?;
    try std.testing.expectEqualStrings("Saving note", shown.action_label);
    try std.testing.expectEqualStrings("Prefers tea", tool_dispatch.presentationLabelValue(shown, parsed.object).?);
    const search = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"action\":\"search\",\"query\":\"tea\"}", .{});
    try std.testing.expectEqualStrings("Searching notes", presentation(search.object).?.action_label);
}
