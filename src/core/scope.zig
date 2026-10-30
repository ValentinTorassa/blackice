//! A task scope: its id and its state directory.
//!
//! State lives in $XDG_STATE_HOME/blackice/scopes/<id>/ (default ~/.local/state/blackice/scopes/<id>/):
//!   receipts.jsonl   one line per decision
//!   policy.json      the exact policy bytes the scope started with

const std = @import("std");
const Io = std.Io;

pub const id_len = 10; // "s-" + 8 hex digits

pub fn newId(io: Io, buf: *[id_len]u8) []const u8 {
    var r: [4]u8 = undefined;
    io.random(&r);
    buf[0..2].* = "s-".*;
    const hex = std.fmt.bytesToHex(r, .lower);
    @memcpy(buf[2..], &hex);
    return buf;
}

/// Caller owns the returned path.
pub fn stateRoot(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_STATE_HOME")) |x| {
        if (x.len > 0 and x[0] == '/') return std.fs.path.join(gpa, &.{ x, "blackice" });
    }
    const home = env.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".local", "state", "blackice" });
}

/// Creates the scope directory and returns its absolute path. Caller owns the path.
pub fn createDir(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, id: []const u8) ![]u8 {
    const root = try stateRoot(gpa, env);
    defer gpa.free(root);
    const dir = try std.fs.path.join(gpa, &.{ root, "scopes", id });
    errdefer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

test newId {
    var buf: [id_len]u8 = undefined;
    const a = newId(std.testing.io, &buf);
    try std.testing.expect(std.mem.startsWith(u8, a, "s-"));
    try std.testing.expectEqual(@as(usize, id_len), a.len);
}
