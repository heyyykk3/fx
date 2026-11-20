const std = @import("std");

const Allocator = std.mem.Allocator;

pub const redaction_marker = "[redacted]";

const secret_prefixes = [_][]const u8{
    "sk-proj-",
    "sk-ant-",
    "sk-live-",
    "sk-test-",
    "sk-",
    "ghp_",
    "gho_",
    "ghu_",
    "ghs_",
    "github_pat_",
    "xoxb-",
    "xoxp-",
    "xoxa-",
    "AKIA",
    "ASIA",
    "AIza",
    "dusk_sess_",
};

const key_markers = [_][]const u8{
    "api_key",
    "apikey",
    "api-key",
    "password",
    "passwd",
    "secret",
    "access_token",
    "refresh_token",
    "auth_token",
    "bearer ",
    "private_key",
};

fn isTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == '/' or byte == '+' or byte == '=';
}

fn matchPrefix(text: []const u8, index: usize) ?usize {
    for (secret_prefixes) |prefix| {
        if (index + prefix.len <= text.len and std.mem.eql(u8, text[index .. index + prefix.len], prefix)) {
            if (index > 0 and (std.ascii.isAlphanumeric(text[index - 1]) or text[index - 1] == '_')) continue;
            var end = index + prefix.len;
            while (end < text.len and isTokenByte(text[end])) : (end += 1) {}
            if (end - index >= prefix.len + 8) return end;
        }
    }
    return null;
}

fn matchAssignmentValue(text: []const u8, index: usize) ?struct { value_start: usize, value_end: usize } {
    for (key_markers) |marker| {
        if (index + marker.len > text.len) continue;
        if (!std.ascii.eqlIgnoreCase(text[index .. index + marker.len], marker)) continue;
        if (index > 0 and (std.ascii.isAlphanumeric(text[index - 1]) or text[index - 1] == '_')) continue;

        var cursor = index + marker.len;
        if (std.ascii.eqlIgnoreCase(marker, "bearer ")) {
            while (cursor < text.len and (text[cursor] == ' ' or text[cursor] == '\t')) : (cursor += 1) {}
        } else {
            while (cursor < text.len and (text[cursor] == ' ' or text[cursor] == '\t' or text[cursor] == '"' or text[cursor] == '\'')) : (cursor += 1) {}
            if (cursor >= text.len or (text[cursor] != ':' and text[cursor] != '=')) continue;
            cursor += 1;
            while (cursor < text.len and (text[cursor] == ' ' or text[cursor] == '\t' or text[cursor] == '"' or text[cursor] == '\'')) : (cursor += 1) {}
        }
        if (cursor >= text.len) continue;
        const start = cursor;
        while (cursor < text.len and isTokenByte(text[cursor])) : (cursor += 1) {}
        if (cursor - start >= 6) {
            return .{ .value_start = start, .value_end = cursor };
        }
    }
    return null;
}

/// The end of a whole token at `index` that looks like a credential with no
/// telling prefix: a JWT, a 32-digit hex key (Azure's older keys), or a long
/// random mix of cases and digits (Azure's newer ones). A 40-digit commit
/// hash is left alone; notes name commits.
fn matchBareCredential(text: []const u8, index: usize) ?usize {
    if (index > 0 and isTokenByte(text[index - 1])) return null;
    var end = index;
    while (end < text.len and isTokenByte(text[end])) : (end += 1) {}
    const token = std.mem.trimEnd(u8, text[index..end], ".");
    if (token.len == 0) return null;
    const token_end = index + token.len;

    if (std.mem.startsWith(u8, token, "eyJ") and token.len >= 24 and std.mem.count(u8, token, ".") == 2) return token_end;

    var all_hex = true;
    var upper = false;
    var lower = false;
    var digit = false;
    var key_chars = true;
    for (token) |b| {
        if (!std.ascii.isHex(b)) all_hex = false;
        if (std.ascii.isUpper(b)) upper = true else if (std.ascii.isLower(b)) lower = true else if (std.ascii.isDigit(b)) digit = true else if (b != '+' and b != '/' and b != '=') key_chars = false;
    }
    if (all_hex and token.len == 32) return token_end;
    if (key_chars and token.len >= 64 and upper and lower and digit) return token_end;
    return null;
}

/// Replaces credential-like tokens and key/password assignments with [redacted]
/// before persisting text into long-term memory. Caller owns the returned slice.
pub fn redactSecretsAlloc(alloc: Allocator, input: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, input.len);

    var i: usize = 0;
    while (i < input.len) {
        if (matchPrefix(input, i)) |end| {
            try out.appendSlice(alloc, redaction_marker);
            i = end;
            continue;
        }
        if (matchBareCredential(input, i)) |end| {
            try out.appendSlice(alloc, redaction_marker);
            i = end;
            continue;
        }
        if (matchAssignmentValue(input, i)) |span| {
            try out.appendSlice(alloc, input[i..span.value_start]);
            try out.appendSlice(alloc, redaction_marker);
            i = span.value_end;
            continue;
        }
        try out.append(alloc, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

test "redacts common token prefixes and secret assignments while preserving plain facts" {
    const alloc = std.testing.allocator;
    const raw = "Prefer concise replies. key=sk-proj-1234567890abcdef and password: supersecretvalue12 and Bearer eyJhbGciOiJIUzI1NiJ9.payload";
    const cleaned = try redactSecretsAlloc(alloc, raw);
    defer alloc.free(cleaned);

    try std.testing.expect(std.mem.find(u8, cleaned, "Prefer concise replies.") != null);
    try std.testing.expect(std.mem.find(u8, cleaned, "1234567890abcdef") == null);
    try std.testing.expect(std.mem.find(u8, cleaned, "supersecretvalue12") == null);
    try std.testing.expect(std.mem.find(u8, cleaned, "eyJhbGciOiJIUzI1NiJ9") == null);
    try std.testing.expect(std.mem.find(u8, cleaned, redaction_marker) != null);
}

test "redacts bare JWTs and Azure-style keys but keeps commit hashes" {
    const alloc = std.testing.allocator;
    const raw = "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlMTIz. azure 0123456789abcdef0123456789ABCDEF new " ++
        "Ab3dEf7hIjKlMn0pQrStUv1xYz2aBc4dEf5hIj6lMn8pQr9tUvWxYzAbCdEfGhIjKlMnOpQrStUvWx== commit 0123456789abcdef0123456789abcdef01234567";
    const cleaned = try redactSecretsAlloc(alloc, raw);
    defer alloc.free(cleaned);
    try std.testing.expect(std.mem.find(u8, cleaned, "eyJ") == null);
    try std.testing.expect(std.mem.find(u8, cleaned, "0123456789abcdef0123456789ABCDEF") == null);
    try std.testing.expect(std.mem.find(u8, cleaned, "Ab3dEf7h") == null);
    try std.testing.expect(std.mem.find(u8, cleaned, "commit 0123456789abcdef0123456789abcdef01234567") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, cleaned, redaction_marker));
}
