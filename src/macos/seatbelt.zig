//! macOS task scope (experimental): the command runs under a Seatbelt profile that refuses every outbound
//! connection except to the scope's own loopback ports (proxy, relay).
//!
//! The profile also
//! - refuses every bind and inbound connection, loopback included: task scopes are clients only, as on Linux.
//!   Seatbelt cannot limit a listener to loopback (a `local ip "localhost:*"` allow also admits 0.0.0.0 and
//!   connections from the LAN, tested on macOS 27.0.1), so a narrower rule would leave a LAN listener open;
//! - refuses writes anywhere under the blackice state root (passed as the STATE_ROOT parameter), so the
//!   command cannot edit its own receipts, policy copy or control socket;
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

/// Caller owns the returned profile. It expects the STATE_ROOT parameter (sandbox-exec -D STATE_ROOT=...).
pub fn profile(gpa: std.mem.Allocator, ports: []const u16) error{OutOfMemory}![]u8 {
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
    return p.toOwnedSlice(gpa);
}

pub fn launch(gpa: std.mem.Allocator, io: Io, spec: backend.LaunchSpec) backend.Error!backend.Exit {
    if (spec.state_dir.len == 0 or spec.state_dir[0] != '/') {
        spec.receipts.write(.{ .event = "warning", .point = .control, .reason = "invalid_state_dir", .detail = spec.state_dir });
        return error.SpawnFailed;
    }
    const prof = try profile(gpa, spec.allowed_loopback_ports);
    defer gpa.free(prof);
    const state_param = try std.mem.concat(gpa, u8, &.{ "STATE_ROOT=", spec.state_dir });
    defer gpa.free(state_param);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ sandbox_exec, "-D", state_param, "-p", prof });
    try argv.appendSlice(gpa, spec.argv);

    var child = std.process.spawn(io, .{ .argv = argv.items, .environ_map = spec.environ }) catch |err| {
        spec.receipts.write(.{ .event = "warning", .point = .control, .reason = "spawn_failed", .detail = @errorName(err) });
        return error.SpawnFailed;
    };
    const term = child.wait(io) catch |err| {
        spec.receipts.write(.{ .event = "warning", .point = .control, .reason = "wait_failed", .detail = @errorName(err) });
        return .other;
    };
    return backend.exitFromTerm(term);
}

test profile {
    const p = try profile(std.testing.allocator, &.{ 18780, 18781 });
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
        \\
    , p);
}
