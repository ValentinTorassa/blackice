//! Grants: temporary allowances for one scope, added by its owner from outside the scope
//! (`blackice grant <scope> <host> --for 10m`, served over the control socket).
//!
//! The proxy consults them only when the policy refuses a name, and only by name: a grant never allows an
//! IP literal, never lifts a port refusal and never lifts the resolved-address checks (local and private
//! addresses stay refused unless a policy subnet allows them). A connection opened under a grant is closed
//! when the grant expires or is revoked.
//!
//! Lifetimes are enforced on the boot clock (monotonic, counts suspended time), so changing the wall clock
//! cannot extend a grant and a grant still runs out while the machine sleeps. The wall-clock expiry is kept
//! only for display and receipts.
//!
//! Patterns use the policy syntax: "example.com" or "*.example.com".

const std = @import("std");
const Io = std.Io;
const policy = @import("../core/policy.zig");

/// The clock that decides expiry.
pub const clock: Io.Clock = .boot;

pub const Grants = struct {
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    items: std.ArrayList(Item) = .empty,
    next_id: u64 = 1,

    const Item = struct {
        id: u64,
        /// Normalized name, or for a wildcard the suffix with its leading dot.
        text: []u8,
        wildcard: bool,
        /// As given, for receipts.
        source: []u8,
        /// On `clock`; decides expiry.
        deadline: Io.Timestamp,
        /// Wall clock; display only.
        expires: Io.Timestamp,
    };

    pub const Match = struct {
        id: u64,
        /// "grant:<pattern>", copied into the caller's buffer.
        rule: []const u8,
        /// On `clock`.
        deadline: Io.Timestamp,
        /// Wall clock, for receipts.
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

    /// Adds a grant for `pattern` lasting `duration` from now, or extends an existing one (never shortens
    /// it). Returns the wall-clock expiry.
    pub fn add(g: *Grants, io: Io, pattern: []const u8, duration: Io.Duration) AddError!Io.Timestamp {
        if (duration.nanoseconds <= 0) return error.InvalidPattern;
        var buf: [policy.max_host_len + 1]u8 = undefined;
        const key = try normalizePattern(&buf, pattern);
        const deadline = clock.now(io).addDuration(duration);
        const expires = Io.Clock.real.now(io).addDuration(duration);

        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        g.pruneLocked(io);
        for (g.items.items) |*it| {
            if (it.wildcard == key.wildcard and std.mem.eql(u8, it.text, key.text)) {
                if (deadline.nanoseconds > it.deadline.nanoseconds) {
                    it.deadline = deadline;
                    it.expires = expires;
                }
                return it.expires;
            }
        }
        const text = try g.gpa.dupe(u8, key.text);
        errdefer g.gpa.free(text);
        const source = try g.gpa.dupe(u8, pattern);
        errdefer g.gpa.free(source);
        try g.items.append(g.gpa, .{
            .id = g.next_id,
            .text = text,
            .wildcard = key.wildcard,
            .source = source,
            .deadline = deadline,
            .expires = expires,
        });
        g.next_id += 1;
        return expires;
    }

    /// Removes the grant for `pattern` (compared after normalization, so "Example.com." matches a grant
    /// written "example.com"). Returns whether one was removed. Connections opened under it are closed by
    /// their watchdog (see `deadlineOf`).
    pub fn revoke(g: *Grants, io: Io, pattern: []const u8) bool {
        var buf: [policy.max_host_len + 1]u8 = undefined;
        const key = normalizePattern(&buf, pattern) catch return false;
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        for (g.items.items, 0..) |it, i| {
            if (it.wildcard == key.wildcard and std.mem.eql(u8, it.text, key.text)) {
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
            return .{ .id = it.id, .rule = rule, .deadline = it.deadline, .expires = it.expires };
        }
        return null;
    }

    /// The current deadline (on `clock`) of grant `id`, which an extension may have moved, or null once the
    /// grant is gone (revoked, or expired and pruned).
    pub fn deadlineOf(g: *Grants, io: Io, id: u64) ?Io.Timestamp {
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        for (g.items.items) |it| if (it.id == id) return it.deadline;
        return null;
    }

    const Key = struct { text: []const u8, wildcard: bool };

    /// "example.com" -> "example.com"; "*.Example.com." -> ".example.com" (wildcard).
    fn normalizePattern(buf: *[policy.max_host_len + 1]u8, pattern: []const u8) error{InvalidPattern}!Key {
        if (policy.parseIpLiteral(pattern) != null) return error.InvalidPattern;
        const wildcard = std.mem.startsWith(u8, pattern, "*.");
        const base = if (wildcard) pattern[2..] else pattern;
        if (std.mem.findScalar(u8, base, '*') != null) return error.InvalidPattern;
        const host = policy.normalizeHost(buf[1..], base) catch return error.InvalidPattern;
        if (!wildcard) return .{ .text = host, .wildcard = false };
        buf[0] = '.';
        return .{ .text = buf[0 .. host.len + 1], .wildcard = true };
    }

    fn pruneLocked(g: *Grants, io: Io) void {
        const now = clock.now(io);
        var i: usize = 0;
        while (i < g.items.items.len) {
            if (g.items.items[i].deadline.nanoseconds <= now.nanoseconds) {
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
    try std.testing.expect(g.deadlineOf(io, m.id) != null);
    try std.testing.expect(g.check(io, "registry.npmjs.org", &rule_buf) != null);
    try std.testing.expect(g.check(io, "npmjs.org", &rule_buf) == null);
    try std.testing.expect(g.check(io, "www.example.com", &rule_buf) == null);

    // Extending keeps the id and moves the deadline later, never earlier.
    _ = try g.add(io, "example.com", .fromSeconds(600));
    const extended = g.deadlineOf(io, m.id).?;
    try std.testing.expect(extended.nanoseconds > m.deadline.nanoseconds);
    _ = try g.add(io, "example.com", .fromSeconds(1));
    try std.testing.expectEqual(extended.nanoseconds, g.deadlineOf(io, m.id).?.nanoseconds);

    try std.testing.expect(g.revoke(io, "example.com."));
    try std.testing.expect(!g.revoke(io, "example.com"));
    try std.testing.expect(g.check(io, "example.com", &rule_buf) == null);
    try std.testing.expect(g.deadlineOf(io, m.id) == null);
    try std.testing.expectError(error.InvalidPattern, g.add(io, "10.0.0.1", .fromSeconds(60)));
    try std.testing.expectError(error.InvalidPattern, g.add(io, "*", .fromSeconds(60)));
    try std.testing.expectError(error.InvalidPattern, g.add(io, "a.*.com", .fromSeconds(60)));
    try std.testing.expectError(error.InvalidPattern, g.add(io, "x.com", .fromSeconds(0)));
}
