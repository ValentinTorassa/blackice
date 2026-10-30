//! A task scope: its id and its state directory.
//!
//! State lives in $XDG_STATE_HOME/blackice/scopes/<id>/ (default ~/.local/state/blackice/scopes/<id>/). The
//! directories are owner-only (0700) and a scope never reuses an existing directory:
//!   receipts.jsonl   one line per decision (0600)
//!   policy.json      the exact policy bytes the scope started with (0600)
//!   control.sock     the owner's control socket (grants)
//! The whole state root is read-only (or hidden) inside every scope; see backend.LaunchSpec.state_dir.

const std = @import("std");
const Io = std.Io;

pub const id_len = 10; // "s-" + 8 hex digits

/// Owner-only, where the OS has POSIX modes.
pub const private_dir: Io.File.Permissions = if (@hasDecl(Io.File.Permissions, "fromMode"))
    .fromMode(0o700)
else
    .default_dir;

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

/// The state root with symlinks resolved, for backends that match resolved paths (Seatbelt does). The root
/// must exist; `create` makes it. Caller owns the returned path.
pub fn realStateRoot(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) ![:0]u8 {
    const root = try stateRoot(gpa, env);
    defer gpa.free(root);
    return Io.Dir.realPathFileAbsoluteAlloc(io, root, gpa);
}

pub const Created = struct {
    id_buf: [id_len]u8,
    /// Absolute path of the new scope directory. Owned by the caller (free with the same allocator).
    path: []u8,

    pub fn id(c: *const Created) []const u8 {
        return &c.id_buf;
    }
};

/// Creates a new scope directory under a fresh id. An existing directory is never reused: on a clash it
/// draws another id.
pub fn create(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) !Created {
    const root = try stateRoot(gpa, env);
    defer gpa.free(root);
    const scopes = try std.fs.path.join(gpa, &.{ root, "scopes" });
    defer gpa.free(scopes);
    _ = try Io.Dir.cwd().createDirPathStatus(io, scopes, private_dir);

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var c: Created = .{ .id_buf = undefined, .path = &.{} };
        _ = newId(io, &c.id_buf);
        const path = try std.fs.path.join(gpa, &.{ scopes, &c.id_buf });
        Io.Dir.cwd().createDir(io, path, private_dir) catch |err| {
            gpa.free(path);
            if (err == error.PathAlreadyExists and attempt < 4) continue;
            return err;
        };
        c.path = path;
        return c;
    }
}

test newId {
    var buf: [id_len]u8 = undefined;
    const a = newId(std.testing.io, &buf);
    try std.testing.expect(std.mem.startsWith(u8, a, "s-"));
    try std.testing.expectEqual(@as(usize, id_len), a.len);
}

test create {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", base);

    const a = try create(gpa, io, &env);
    defer gpa.free(a.path);
    const b = try create(gpa, io, &env);
    defer gpa.free(b.path);
    try std.testing.expect(!std.mem.eql(u8, a.id(), b.id()));
    try std.testing.expect(std.mem.endsWith(u8, a.path, a.id()));

    const real = try realStateRoot(gpa, io, &env);
    defer gpa.free(real);
    try std.testing.expect(std.mem.endsWith(u8, real, "/blackice"));

    if (@hasDecl(Io.File.Permissions, "fromMode")) {
        const st = try Io.Dir.cwd().statFile(io, a.path, .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), st.permissions.toMode() & 0o777);
    }
}
