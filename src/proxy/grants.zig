//! Grants: temporary allowances for one scope, added by its owner from outside the scope
//! (`blackice grant <scope> <host> --for 10m`, served over the control socket).
//!
//! The proxy consults them only when the policy refuses a name, and only by name: a grant never allows an
//! IP literal and never lifts the resolved-address checks (local and private addresses stay refused unless
//! a policy subnet allows them). A tunnel opened under a grant is closed when the grant expires.
//!
//! Patterns use the policy syntax: "example.com" or "*.example.com".

const std = @import("std");
const Io = std.Io;
const policy = @import("../core/policy.zig");

pub const Grants = struct {
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    items: std.ArrayList(Item) = .empty,

    const Item = struct {
        /// Normalized name, or for a wildcard the suffix with its leading dot.
        text: []u8,
        wildcard: bool,
        /// As given, for receipts.
        source: []u8,
        expires: Io.Timestamp,
    };

    pub const Match = struct {
        /// "grant:<pattern>", copied into the caller's buffer.
        rule: []const u8,
        expires: Io.Timestamp,
    };

    pub const AddError = error{ InvalidPattern, OutOfMemory };

    pub fn init(gpa: std.mem.Allocator) Grants {
        return .{ .gpa = gpa };
    }

    pub fn deinit(g: *Grants) void {
        for (g.items.items) |it| g.freeItem(it);
        g.items.deinit(g.gpa);
        g.* = undefined;
    }

    fn freeItem(g: *Grants, it: Item) void {
        g.gpa.free(it.text);
        g.gpa.free(it.source);
    }

    /// Adds (or extends) a grant for `pattern` lasting `duration` from now. Returns its expiry.
    pub fn add(g: *Grants, io: Io, pattern: []const u8, duration: Io.Duration) AddError!Io.Timestamp {
        if (duration.nanoseconds <= 0) return error.InvalidPattern;
        var buf: [policy.max_host_len]u8 = undefined;
        if (policy.parseIpLiteral(pattern) != null) return error.InvalidPattern;
        const wildcard = std.mem.startsWith(u8, pattern, "*.");
        const base = if (wildcard) pattern[2..] else pattern;
        if (std.mem.findScalar(u8, base, '*') != null) return error.InvalidPattern;
        const host = policy.normalizeHost(&buf, base) catch return error.InvalidPattern;

        const text = if (wildcard) try std.mem.concat(g.gpa, u8, &.{ ".", host }) else try g.gpa.dupe(u8, host);
        errdefer g.gpa.free(text);
        const source = try g.gpa.dupe(u8, pattern);
        errdefer g.gpa.free(source);
        const expires = Io.Clock.real.now(io).addDuration(duration);

        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        g.pruneLocked(io);
        for (g.items.items) |*it| {
            if (it.wildcard == wildcard and std.mem.eql(u8, it.text, text)) {
                g.gpa.free(text);
                g.gpa.free(source);
                if (expires.nanoseconds > it.expires.nanoseconds) it.expires = expires;
                return it.expires;
            }
        }
        try g.items.append(g.gpa, .{ .text = text, .wildcard = wildcard, .source = source, .expires = expires });
        return expires;
    }

    /// Removes the grant written exactly as `pattern`. Returns whether one was removed.
    /// Tunnels already open under it close at their original expiry.
    pub fn revoke(g: *Grants, io: Io, pattern: []const u8) bool {
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        for (g.items.items, 0..) |it, i| {
            if (std.mem.eql(u8, it.source, pattern)) {
                g.freeItem(g.items.swapRemove(i));
                return true;
            }
        }
        return false;
    }

    /// `host` must be normalized. On a match, the rule text is written into `rule_buf`.
    pub fn check(g: *Grants, io: Io, host: []const u8, rule_buf: []u8) ?Match {
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        g.pruneLocked(io);
        for (g.items.items) |it| {
            const hit = if (it.wildcard)
                host.len > it.text.len and std.mem.endsWith(u8, host, it.text)
            else
                std.mem.eql(u8, host, it.text);
            if (!hit) continue;
            const rule = std.fmt.bufPrint(rule_buf, "grant:{s}", .{it.source}) catch rule_buf[0..0];
            return .{ .rule = rule, .expires = it.expires };
        }
        return null;
    }

    fn pruneLocked(g: *Grants, io: Io) void {
        const now = Io.Clock.real.now(io);
        var i: usize = 0;
        while (i < g.items.items.len) {
            if (g.items.items[i].expires.nanoseconds <= now.nanoseconds) {
                g.freeItem(g.items.swapRemove(i));
            } else i += 1;
        }
    }
};

test Grants {
    const io = std.testing.io;
    var g: Grants = .init(std.testing.allocator);
    defer g.deinit();
    var rule_buf: [300]u8 = undefined;
    try std.testing.expect(g.check(io, "example.com", &rule_buf) == null);
    _ = try g.add(io, "Example.com", .fromSeconds(60));
    _ = try g.add(io, "*.npmjs.org", .fromSeconds(60));
    const m = g.check(io, "example.com", &rule_buf).?;
    try std.testing.expectEqualStrings("grant:Example.com", m.rule);
    try std.testing.expect(g.check(io, "registry.npmjs.org", &rule_buf) != null);
    try std.testing.expect(g.check(io, "npmjs.org", &rule_buf) == null);
    try std.testing.expect(g.check(io, "www.example.com", &rule_buf) == null);
    try std.testing.expect(g.revoke(io, "Example.com"));
    try std.testing.expect(g.check(io, "example.com", &rule_buf) == null);
    try std.testing.expectError(error.InvalidPattern, g.add(io, "10.0.0.1", .fromSeconds(60)));
    try std.testing.expectError(error.InvalidPattern, g.add(io, "*", .fromSeconds(60)));
    try std.testing.expectError(error.InvalidPattern, g.add(io, "a.*.com", .fromSeconds(60)));
    try std.testing.expectError(error.InvalidPattern, g.add(io, "x.com", .fromSeconds(0)));
}
