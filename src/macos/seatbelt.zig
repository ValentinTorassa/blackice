//! macOS task scope (experimental): the command runs under a Seatbelt profile that refuses every outbound
//! connection except to the scope's own loopback ports (proxy, relay).
//!
//! The profile also
//! - refuses every bind and inbound connection, loopback included: task scopes are clients only, as on Linux.
//!   Seatbelt cannot limit a listener to loopback (a `local ip "localhost:*"` allow also admits 0.0.0.0 and
//!   connections from the LAN, tested on macOS 27.0.1), so a narrower rule would leave a LAN listener open;
//! - refuses writes anywhere under the blackice state root (passed as the STATE_ROOT parameter), so the
//!   command cannot edit its own receipts, policy copy or control socket. Seatbelt matches paths, so every
//!   ancestor directory of the root is also protected against rename and removal (STATE_ANCESTOR_<n>):
//!   otherwise moving a parent away would leave the receipts writable at the new path. Files can still be
//!   created inside those ancestors;
//! - refuses launchd job creation, LaunchServices opens and Apple Events: a process started by launchd, by
//!   LaunchServices (`open`) or by another app (osascript) would run outside this profile.
//!
//! Verified primitives (macOS 27.0.1, SIP on and off): a deny rule blocks DNS through mDNSResponder, raw IP
//! connections, other loopback ports and Unix-socket connects; children and orphaned children inherit the
//! profile. Verified for this exact profile (macOS 27.0.1, SIP on): binds and listeners refused, writes,
//! truncation, deletion, renames, hard links and symlinked writes into the state root refused,
//! `launchctl submit` refused, the control socket unreachable from inside, and git, swift and fx still run.
//! The lsopen and appleevent-send rules are not exercised yet (those tests open windows).
//!
//! Seatbelt cannot name remote hosts or IPs ("host must be * or localhost"), so names are decided by the
//! proxy. sandbox-exec is deprecated by Apple; it is still the documented way to apply a profile to a command.

const std = @import("std");
const Io = std.Io;
const backend = @import("../core/backend.zig");

pub const sandbox_exec = "/usr/bin/sandbox-exec";

/// Caller owns the returned profile. It expects the STATE_ROOT parameter and STATE_ANCESTOR_0 ..
/// STATE_ANCESTOR_<ancestor_count - 1> (sandbox-exec -D NAME=VALUE).
pub fn profile(gpa: std.mem.Allocator, ports: []const u16, ancestor_count: usize) error{OutOfMemory}![]u8 {
    var p: std.ArrayList(u8) = .empty;
    errdefer p.deinit(gpa);
    try p.appendSlice(gpa,
        \\(version 1)
        \\(allow default)
        \\(deny network-outbound)
        \\
    );
    for (ports) |port| {
        try p.print(gpa, "(allow network-outbound (remote ip \"localhost:{d}\"))\n", .{port});
    }
    try p.appendSlice(gpa,
        \\(deny network-bind)
        \\(deny network-inbound)
        \\(deny file-write* (subpath (param "STATE_ROOT")))
        \\(deny job-creation)
        \\(deny lsopen)
        \\(deny appleevent-send)
        \\
    );
    for (0..ancestor_count) |i| {
        try p.print(gpa, "(deny file-write* (literal (param \"STATE_ANCESTOR_{d}\")))\n", .{i});
    }
    return p.toOwnedSlice(gpa);
}

/// The ancestors of an absolute path, outermost first, without "/": "/a/b/c" gives "/a", "/a/b".
pub fn ancestors(path: []const u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' and n < out.len) {
            out[n] = path[0..i];
            n += 1;
        }
    }
    return out[0..n];
}

pub fn launch(gpa: std.mem.Allocator, io: Io, spec: backend.LaunchSpec) backend.Error!backend.Exit {
    const root = std.mem.trimEnd(u8, spec.state_dir, "/");
    if (root.len == 0 or root[0] != '/') {
        spec.receipts.write(.{ .event = "warning", .point = .control, .reason = "invalid_state_dir", .detail = spec.state_dir });
        return error.SpawnFailed;
    }
    var anc_buf: [64][]const u8 = undefined;
    const anc = ancestors(root, &anc_buf);
    const prof = try profile(gpa, spec.allowed_loopback_ports, anc.len);
    defer gpa.free(prof);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ sandbox_exec, "-D", try std.mem.concat(arena, u8, &.{ "STATE_ROOT=", root }) });
    for (anc, 0..) |a, i| {
        try argv.appendSlice(arena, &.{ "-D", try std.fmt.allocPrint(arena, "STATE_ANCESTOR_{d}={s}", .{ i, a }) });
    }
    try argv.appendSlice(arena, &.{ "-p", prof });
    try argv.appendSlice(arena, spec.argv);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = spec.environ,
        .stdin = switch (spec.stdin) {
            .inherit => .inherit,
            .null_device => .ignore,
        },
    }) catch |err| {
        spec.receipts.write(.{ .event = "warning", .point = .control, .reason = "spawn_failed", .detail = @errorName(err) });
        return error.SpawnFailed;
    };
    const term = child.wait(io) catch |err| {
        spec.receipts.write(.{ .event = "warning", .point = .control, .reason = "wait_failed", .detail = @errorName(err) });
        return .other;
    };
    return backend.exitFromTerm(term);
}

test ancestors {
    var buf: [8][]const u8 = undefined;
    const a = ancestors("/Users/u/.local/state/blackice", &buf);
    try std.testing.expectEqual(@as(usize, 4), a.len);
    try std.testing.expectEqualStrings("/Users", a[0]);
    try std.testing.expectEqualStrings("/Users/u/.local/state", a[3]);
    try std.testing.expectEqual(@as(usize, 0), ancestors("/blackice", &buf).len);
}

test profile {
    const p = try profile(std.testing.allocator, &.{ 18780, 18781 }, 2);
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings(
        \\(version 1)
        \\(allow default)
        \\(deny network-outbound)
        \\(allow network-outbound (remote ip "localhost:18780"))
        \\(allow network-outbound (remote ip "localhost:18781"))
        \\(deny network-bind)
        \\(deny network-inbound)
        \\(deny file-write* (subpath (param "STATE_ROOT")))
        \\(deny job-creation)
        \\(deny lsopen)
        \\(deny appleevent-send)
        \\(deny file-write* (literal (param "STATE_ANCESTOR_0")))
        \\(deny file-write* (literal (param "STATE_ANCESTOR_1")))
        \\
    , p);
}
