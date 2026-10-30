//! Immutable per-connection views. Publishers retain every view until shutdown.
const std = @import("std");
const policy = @import("../core/policy.zig");
const receipt = @import("../core/receipt.zig");
pub const Binding = struct {
    policy: *const policy.Policy,
    decision: receipt.Decision,
    executable: []const u8,
    serve: bool = true,
};
pub const Source = struct {
    context: *const anyopaque,
    slot: usize,
    read: *const fn (*const anyopaque, usize) ?Binding,
    paused: *const std.atomic.Value(bool),

    pub fn capture(s: Source) ?Binding {
        if (s.paused.load(.acquire)) return null;
        const b = s.read(s.context, s.slot) orelse return null;
        return if (b.serve) b else null;
    }
    pub fn current(s: Source) ?Binding {
        return s.read(s.context, s.slot);
    }
};

pub fn permits(b: Binding, host: []const u8, port: u16, ip: ?std.Io.net.IpAddress) bool {
    if (!b.serve) return false;
    if (!b.policy.checkPort(port).allowed) return false;
    if (policy.parseIpLiteral(host)) |literal| return b.policy.checkLiteral(literal).allowed;
    if (!b.policy.checkHost(host).allowed) return false;
    if (ip) |resolved| if (!b.policy.checkResolved(resolved).allowed) return false;
    return true;
}

test "appfilter live view narrowing checks host port and the already selected address" {
    var p = try policy.Policy.parse(std.testing.allocator, "{\"version\":\"blackice.policy/v0\",\"network\":{\"mode\":\"allowlist\",\"allow\":[\"example.com\"]}}", null);
    defer p.deinit();
    const b: Binding = .{ .policy = &p, .decision = .{ .policy = &p.digest_hex, .generation = 2 }, .executable = "/usr/bin/curl" };
    try std.testing.expect(permits(b, "example.com", 443, null));
    try std.testing.expect(!permits(b, "other.example", 443, null));
    try std.testing.expect(!permits(b, "example.com", 22, null));
    try std.testing.expect(!permits(b, "example.com", 443, .{ .ip4 = .loopback(443) }));
}
