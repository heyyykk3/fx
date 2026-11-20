//! The agent whose saved notes an ACP session reads and writes, named by the
//! client as `_meta.fx.memoryAgent` on `session/new`, `session/load`, or
//! `session/resume`. A host running many bots names each one, so every bot
//! keeps its own notes. Unnamed, a session uses fx's `main`.

const std = @import("std");
const acp_types = @import("types.zig");
const memory_store = @import("../core/memory/store.zig");

pub const default_name = "main";

/// A validated name, held inline so the session owns no allocation for it.
pub const Name = struct {
    buf: [memory_store.max_agent_name_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Name) []const u8 {
        return if (self.len == 0) default_name else self.buf[0..self.len];
    }
};

pub const ParseError = std.mem.Allocator.Error || error{InvalidMemoryAgent};

pub const invalid_message = "_meta.fx.memoryAgent must be 1 to 64 letters, digits, '-' or '_'";

/// The name in `params_raw`, or the default when it names none. Params
/// that are not a JSON object name none; their own parsers report them.
pub fn parse(alloc: std.mem.Allocator, params_raw: ?[]const u8) ParseError!Name {
    const raw = params_raw orelse return .{};
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const value = acp_types.fxMetaField(parsed.value.object, "memoryAgent") orelse return .{};
    if (value == .null) return .{};
    if (value != .string or !memory_store.validAgentName(value.string)) return error.InvalidMemoryAgent;
    var name: Name = .{ .len = @intCast(value.string.len) };
    @memcpy(name.buf[0..value.string.len], value.string);
    return name;
}

test "a session names its memory agent under _meta.fx, or uses main" {
    const alloc = std.testing.allocator;
    const named = try parse(alloc, "{\"cwd\":\"/tmp\",\"_meta\":{\"fx\":{\"memoryAgent\":\"bot_42\"}}}");
    try std.testing.expectEqualStrings("bot_42", named.slice());
    try std.testing.expectEqualStrings("main", (try parse(alloc, "{\"cwd\":\"/tmp\"}")).slice());
    try std.testing.expectEqualStrings("main", (try parse(alloc, null)).slice());
    try std.testing.expectError(error.InvalidMemoryAgent, parse(alloc, "{\"_meta\":{\"fx\":{\"memoryAgent\":\"../user\"}}}"));
    try std.testing.expectError(error.InvalidMemoryAgent, parse(alloc, "{\"_meta\":{\"fx\":{\"memoryAgent\":7}}}"));
}
