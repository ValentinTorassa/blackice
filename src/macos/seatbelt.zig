//! macOS task scope (experimental): the command runs under a Seatbelt profile that refuses every outbound
//! connection except to the scope's own loopback ports (proxy, relay).
//!
//! The profile also
//! - refuses every bind and inbound connection, loopback included: task scopes are clients only, as on Linux.
//!   Seatbelt cannot limit a listener to loopback (a `local ip "localhost:*"` allow also admits 0.0.0.0 and
//!   connections from the LAN, tested on macOS 27.0.1), so a narrower rule would leave a LAN listener open;
//! - refuses writes anywhere under the blackice state root (passed as the STATE_ROOT parameter), so the
//!   command cannot edit its own receipts, policy copy or control socket;
//! - refuses writes to the protected files (blackice's own executable, the policy file, and what the caller
//!   named with --protect), so a scoped command cannot swap in what the next scope runs;
//! - protects every ancestor directory of the state root and of the protected files against rename and
//!   removal: Seatbelt matches paths, so moving a parent away would otherwise leave the files writable at the
//!   new path, or let a new directory take the old one's place. Files can still be created inside those
//!   ancestors. Protected files and ancestors are LITERAL_<n> parameters;
//! - refuses launchd job creation, LaunchServices opens and Apple Events: a process started by launchd, by
//!   LaunchServices (`open`) or by another app (osascript) would run outside this profile.
//!
//! Every deny rule carries `(with message "blackice <scope id>")`, so the kernel's refusals come back as
//! receipts (kernel_log.zig).
//!
//! Verified primitives (macOS 27.0.1, SIP on and off): a deny rule blocks DNS through mDNSResponder, raw IP
//! connections, other loopback ports and Unix-socket connects; children and orphaned children inherit the
//! profile. Verified for this exact profile (macOS 27.0.1, SIP on): binds and listeners refused, writes,
//! truncation, deletion, renames, hard links and symlinked writes into the state root refused, hard links
//! made outside to a protected file or a receipts file refused (Seatbelt's own forbidden-link-priv rule: a
//! link to a file the profile forbids writing counts as a write), `launchctl submit` refused, the control
//! socket unreachable from inside, and git, swift and fx still run.
//! The lsopen and appleevent-send rules are not exercised yet (those tests open windows).
//!
//! Seatbelt cannot name remote hosts or IPs ("host must be * or localhost"), so names are decided by the
//! proxy. sandbox-exec is deprecated by Apple; it is still the documented way to apply a profile to a command.

const std = @import("std");
const Io = std.Io;
const backend = @import("../core/backend.zig");
const kernel_log = @import("kernel_log.zig");

pub const sandbox_exec = "/usr/bin/sandbox-exec";

/// At most this many protected literals (files plus distinct ancestors).
pub const max_literals = 64;

/// Caller owns the returned profile. It expects the STATE_ROOT parameter and LITERAL_0 ..
/// LITERAL_<literal_count - 1> (sandbox-exec -D NAME=VALUE). With a tag, every deny rule carries it as its
/// message; the tag must not need quoting (kernel_log.tag makes sure).
pub fn profile(gpa: std.mem.Allocator, ports: []const u16, literal_count: usize, tag: ?[]const u8) error{OutOfMemory}![]u8 {
    var msg_buf: [64]u8 = undefined;
    const m: []const u8 = if (tag) |t|
        std.fmt.bufPrint(&msg_buf, " (with message \"{s}\")", .{t}) catch return error.OutOfMemory
    else
        "";
    var p: std.ArrayList(u8) = .empty;
    errdefer p.deinit(gpa);
    try p.print(gpa, "(version 1)\n(allow default)\n(deny network-outbound{s})\n", .{m});
    for (ports) |port| {
        try p.print(gpa, "(allow network-outbound (remote ip \"localhost:{d}\"))\n", .{port});
    }
    try p.print(gpa,
        \\(deny network-bind{s})
        \\(deny network-inbound{s})
        \\(deny file-write* (subpath (param "STATE_ROOT")){s})
        \\(deny job-creation{s})
        \\(deny lsopen{s})
        \\(deny appleevent-send{s})
        \\
    , .{ m, m, m, m, m, m });
    for (0..literal_count) |i| {
        try p.print(gpa, "(deny file-write* (literal (param \"LITERAL_{d}\")){s})\n", .{ i, m });
    }
    return p.toOwnedSlice(gpa);
}

/// The ancestors of an absolute path, outermost first, without "/": "/a/b/c" gives "/a", "/a/b". Null when
/// there are more than `out` can hold, so a deep path is refused rather than partly protected.
pub fn ancestors(path: []const u8, out: [][]const u8) ?[][]const u8 {
    var n: usize = 0;
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            if (n == out.len) return null;
            out[n] = path[0..i];
            n += 1;
        }
    }
    return out[0..n];
}

/// The protected literals: the ancestors of the state root, and each protected file with its ancestors,
/// without duplicates. Null when they do not fit in `out`, or a path is not absolute.
pub fn literals(state_root: []const u8, protected: []const []const u8, out: [][]const u8) ?[][]const u8 {
    var n: usize = 0;
    var tmp: [max_literals][]const u8 = undefined;
    const roots = ancestors(state_root, &tmp) orelse return null;
    for (roots) |a| n = add(out, n, a) orelse return null;
    for (protected) |path| {
        const p = std.mem.trimEnd(u8, path, "/");
        if (p.len == 0 or p[0] != '/') return null;
        const anc = ancestors(p, &tmp) orelse return null;
        for (anc) |a| n = add(out, n, a) orelse return null;
        n = add(out, n, p) orelse return null;
    }
    return out[0..n];
}

fn add(out: [][]const u8, n: usize, item: []const u8) ?usize {
    for (out[0..n]) |have| if (std.mem.eql(u8, have, item)) return n;
    if (n == out.len) return null;
    out[n] = item;
    return n + 1;
}

pub fn launch(gpa: std.mem.Allocator, io: Io, spec: backend.LaunchSpec) backend.Error!backend.Exit {
    const root = std.mem.trimEnd(u8, spec.state_dir, "/");
    if (root.len == 0 or root[0] != '/') {
        spec.receipts.write(.{ .event = "warning", .point = .control, .reason = "invalid_state_dir", .detail = spec.state_dir });
        return error.SpawnFailed;
    }
    var lit_buf: [max_literals][]const u8 = undefined;
    const lits = literals(root, spec.protected_paths, &lit_buf) orelse {
        spec.receipts.write(.{ .event = "warning", .point = .control, .reason = "invalid_protected_path", .detail = "a protected path is not absolute, or the paths are nested too deep" });
        return error.SpawnFailed;
    };
    var tag_buf: [32]u8 = undefined;
    const tag = kernel_log.tag(&tag_buf, spec.scope_id);
    const prof = try profile(gpa, spec.allowed_loopback_ports, lits.len, tag);
    defer gpa.free(prof);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ sandbox_exec, "-D", try std.mem.concat(arena, u8, &.{ "STATE_ROOT=", root }) });
    for (lits, 0..) |a, i| {
        try argv.appendSlice(arena, &.{ "-D", try std.fmt.allocPrint(arena, "LITERAL_{d}={s}", .{ i, a }) });
    }
    try argv.appendSlice(arena, &.{ "-p", prof });
    try argv.appendSlice(arena, spec.argv);

    // Refusal receipts: the stream is live before the command starts, or a warning says it is not.
    const watch = kernel_log.Watch.start(gpa, io, spec.scope_id, spec.receipts);
    defer if (watch) |w| w.finish();

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
    const a = ancestors("/Users/u/.local/state/blackice", &buf).?;
    try std.testing.expectEqual(@as(usize, 4), a.len);
    try std.testing.expectEqualStrings("/Users", a[0]);
    try std.testing.expectEqualStrings("/Users/u/.local/state", a[3]);
    try std.testing.expectEqual(@as(usize, 0), ancestors("/blackice", &buf).?.len);
    var small: [2][]const u8 = undefined;
    try std.testing.expect(ancestors("/a/b/c/d", &small) == null);
}

test literals {
    var buf: [max_literals][]const u8 = undefined;
    const l = literals("/Users/u/.local/state/blackice", &.{ "/Users/u/.local/bin/blackice", "/Users/u/demo/agent.json" }, &buf).?;
    const want = [_][]const u8{
        "/Users",              "/Users/u",                     "/Users/u/.local", "/Users/u/.local/state",
        "/Users/u/.local/bin", "/Users/u/.local/bin/blackice", "/Users/u/demo",   "/Users/u/demo/agent.json",
    };
    try std.testing.expectEqual(want.len, l.len);
    for (want, l) |w, got| try std.testing.expectEqualStrings(w, got);
    try std.testing.expect(literals("/s", &.{"relative/path"}, &buf) == null);
    var small: [3][]const u8 = undefined;
    try std.testing.expect(literals("/a/b/c", &.{"/x/y"}, &small) == null);
}

test profile {
    const p = try profile(std.testing.allocator, &.{ 18780, 18781 }, 2, "blackice s-0a1b2c3d");
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings(
        \\(version 1)
        \\(allow default)
        \\(deny network-outbound (with message "blackice s-0a1b2c3d"))
        \\(allow network-outbound (remote ip "localhost:18780"))
        \\(allow network-outbound (remote ip "localhost:18781"))
        \\(deny network-bind (with message "blackice s-0a1b2c3d"))
        \\(deny network-inbound (with message "blackice s-0a1b2c3d"))
        \\(deny file-write* (subpath (param "STATE_ROOT")) (with message "blackice s-0a1b2c3d"))
        \\(deny job-creation (with message "blackice s-0a1b2c3d"))
        \\(deny lsopen (with message "blackice s-0a1b2c3d"))
        \\(deny appleevent-send (with message "blackice s-0a1b2c3d"))
        \\(deny file-write* (literal (param "LITERAL_0")) (with message "blackice s-0a1b2c3d"))
        \\(deny file-write* (literal (param "LITERAL_1")) (with message "blackice s-0a1b2c3d"))
        \\
    , p);
    const plain = try profile(std.testing.allocator, &.{18780}, 0, null);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.find(u8, plain, "with message") == null);
    try std.testing.expect(std.mem.find(u8, plain, "(deny network-outbound)\n") != null);
}
