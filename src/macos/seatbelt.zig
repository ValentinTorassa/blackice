//! macOS task scope (experimental): the command runs under a Seatbelt profile that refuses every outbound
//! connection except to the scope's own loopback ports (proxy, relay).
//!
//! Verified primitives (macOS 27.0.1, SIP on and off): a deny rule blocks DNS through mDNSResponder, raw IP
//! connections and other loopback ports; children and orphaned children inherit the profile. Seatbelt cannot
//! name remote hosts or IPs ("host must be * or localhost"), so names are decided by the proxy.
//! sandbox-exec is deprecated by Apple; it is still the documented way to apply a profile to a command.

const std = @import("std");
const Io = std.Io;
const backend = @import("../core/backend.zig");

pub const sandbox_exec = "/usr/bin/sandbox-exec";

/// Caller owns the returned profile.
pub fn profile(gpa: std.mem.Allocator, ports: []const u16, harden: bool) error{OutOfMemory}![]u8 {
    var p: std.ArrayList(u8) = .empty;
    errdefer p.deinit(gpa);
    try p.appendSlice(gpa, "(version 1)\n(allow default)\n(deny network-outbound)\n");
    for (ports) |port| {
        try p.print(gpa, "(allow network-outbound (remote ip \"localhost:{d}\"))\n", .{port});
    }
    if (harden) {
        // Processes started by launchd, LaunchServices or another app run outside this profile.
        try p.appendSlice(gpa, "(deny job-creation)\n(deny lsopen)\n(deny appleevent-send)\n");
    }
    return p.toOwnedSlice(gpa);
}

pub fn launch(gpa: std.mem.Allocator, io: Io, spec: backend.LaunchSpec) backend.Error!backend.Exit {
    const prof = try profile(gpa, spec.allowed_loopback_ports, spec.harden);
    defer gpa.free(prof);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ sandbox_exec, "-p", prof });
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
    const p = try profile(std.testing.allocator, &.{ 18780, 18781 }, false);
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings(
        \\(version 1)
        \\(allow default)
        \\(deny network-outbound)
        \\(allow network-outbound (remote ip "localhost:18780"))
        \\(allow network-outbound (remote ip "localhost:18781"))
        \\
    , p);
}
