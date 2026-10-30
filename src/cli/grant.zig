//! `blackice grant SCOPE HOST [--for DURATION]` and `blackice revoke SCOPE HOST`: the owner changes a running
//! scope from outside it, over the scope's control socket. A grant lets one more name through the proxy for a
//! while (default 10 minutes, at most 1 hour). It never lifts the port, address or local-network checks.

const std = @import("std");
const Io = std.Io;
const scope = @import("../core/scope.zig");
const control = @import("../control/control.zig");

pub const usage =
    \\usage: blackice grant SCOPE HOST [--for DURATION]   (DURATION like 90s, 10m, 1h; default 10m)
    \\       blackice revoke SCOPE HOST
    \\
;

pub const Op = enum { grant, revoke };

/// "s-" followed by 8 lowercase hex digits.
pub fn validScopeId(id: []const u8) bool {
    if (id.len != scope.id_len or !std.mem.startsWith(u8, id, "s-")) return false;
    for (id[2..]) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    op: Op,
    args: []const []const u8,
    out: *Io.Writer,
    errw: *Io.Writer,
) !u8 {
    var seconds: u32 = 600;
    const ok_shape = switch (op) {
        .grant => args.len == 2 or (args.len == 4 and std.mem.eql(u8, args[2], "--for")),
        .revoke => args.len == 2,
    };
    if (!ok_shape) {
        try errw.writeAll(usage);
        return 2;
    }
    if (op == .grant and args.len == 4) {
        seconds = control.parseDuration(args[3]) orelse {
            try errw.print("blackice grant: invalid duration {s}; use 90s, 10m or 1h (at most 1h)\n", .{args[3]});
            return 2;
        };
    }
    const sid = args[0];
    const host = args[1];
    if (!validScopeId(sid)) {
        try errw.print("blackice: {s} is not a scope id (s- and 8 hex digits)\n", .{sid});
        return 2;
    }
    const root = try scope.stateRoot(gpa, env);
    defer gpa.free(root);
    const dir = try std.fs.path.join(gpa, &.{ root, "scopes", sid });
    defer gpa.free(dir);

    const result = switch (op) {
        .grant => control.grant(gpa, io, dir, host, seconds),
        .revoke => control.revoke(gpa, io, dir, host),
    };
    var parsed = result catch |err| {
        try errw.print("blackice: cannot reach the control socket of scope {s} ({s}). Commands inside a scope cannot " ++
            "reach it; from outside, check that the scope is still running.\n", .{ sid, @errorName(err) });
        return 1;
    };
    defer parsed.deinit();
    const reply = parsed.value;
    if (!reply.ok) {
        try errw.print("blackice: scope {s} refused: {s}\n", .{ sid, reply.@"error" orelse "unknown" });
        return 1;
    }
    switch (op) {
        .grant => try out.print("granted {s} to scope {s} until {s}\n", .{ host, sid, reply.expires orelse "?" }),
        .revoke => try out.print("{s} {s} in scope {s}\n", .{ if (reply.removed orelse false) "revoked" else "no grant for", host, sid }),
    }
    return 0;
}

test validScopeId {
    try std.testing.expect(validScopeId("s-0a1b2c3d"));
    try std.testing.expect(!validScopeId("s-0A1B2C3D"));
    try std.testing.expect(!validScopeId("s-../../x"));
    try std.testing.expect(!validScopeId("s-0a1b2c3"));
    try std.testing.expect(!validScopeId("x-0a1b2c3d"));
}
