//! Reload records use the existing flat receipt writer and captured contexts.
const std = @import("std");
const receipt = @import("../../core/receipt.zig");
const snapshot = @import("reload_snapshot.zig");

/// The writer still cleans/caps detail at 512 bytes. Per-slot proxy records also
/// carry each executable, so long membership summaries are not the only record.
pub fn activationDetail(buffer: []u8, old: *const snapshot.Snapshot, new: *const snapshot.Snapshot) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    inline for (.{ "added", "removed", "retired", "changed" }) |kind| {
        try writer.print("{s}=[", .{kind});
        var comma = false;
        for (new.slots, 0..) |slot, i| if (slot) |b| {
            const before = old.slots[i];
            const include = if (comptime std.mem.eql(u8, kind, "added")) before == null else if (comptime std.mem.eql(u8, kind, "removed")) before != null and before.?.active and !b.active else if (comptime std.mem.eql(u8, kind, "retired")) !b.active else before != null and before.?.active and b.active and !std.mem.eql(u8, &before.?.network.digest_hex, &b.network.digest_hex);
            if (!include) continue;
            if (comma) try writer.writeByte(',');
            try writer.print("{f}", .{std.json.fmt(b.executable, .{})});
            comma = true;
        };
        try writer.writeAll("]; ");
    }
    try writer.writeAll("tags_retained; narrowing_watchdog_ms=200");
    return writer.buffered();
}

pub fn activated(log: *receipt.Log, old: receipt.Decision, new: receipt.Decision, detail: []const u8) !void {
    if (old.generation == 0 or old.generation >= @import("config.zig").max_generations or new.generation != old.generation + 1) return error.ExpectedNextGeneration;
    try digest(old.policy);
    try digest(new.policy);
    log.write(.{ .event = "policy_activated", .point = .app_filter, .decision = new, .old_policy = old.policy, .new_policy = new.policy, .detail = detail });
}
pub fn refused(log: *receipt.Log, current: ?receipt.Decision, reason: []const u8) void {
    log.write(.{ .event = "policy_change_refused", .point = .app_filter, .verdict = .deny, .decision = current, .old_policy = if (current) |c| c.policy else null, .reason = reason });
}
fn digest(value: []const u8) !void {
    if (value.len != 64) return error.InvalidPolicyDigest;
    for (value) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return error.InvalidPolicyDigest;
}

test "appfilter reload activation records both exact hashes and does not invent skipped generations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const old_hash: [64]u8 = @splat('1');
    const new_hash: [64]u8 = @splat('2');
    const old: receipt.Decision = .{ .generation = 1, .policy = &old_hash };
    const new: receipt.Decision = .{ .generation = 2, .policy = &new_hash };
    var log = try receipt.Log.open(io, tmp.dir, "r.jsonl", "service", old.policy);
    try std.testing.expectError(error.ExpectedNextGeneration, activated(&log, old, .{ .generation = 3, .policy = new.policy }, ""));
    try std.testing.expectError(error.InvalidPolicyDigest, activated(&log, old, .{ .generation = 2, .policy = "wrong" }, ""));
    try std.testing.expectEqual(@as(u64, 0), log.written);
    try activated(&log, old, new, "changed=/usr/bin/curl");
    log.close();
    const data = try tmp.dir.readFileAlloc(io, "r.jsonl", std.testing.allocator, .limited(16384));
    defer std.testing.allocator.free(data);
    const row = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{});
    defer row.deinit();
    try std.testing.expectEqual(@as(i64, 2), row.value.object.get("gen").?.integer);
    try std.testing.expectEqualStrings(old.policy, row.value.object.get("old_policy").?.string);
    try std.testing.expectEqualStrings(new.policy, row.value.object.get("new_policy").?.string);
    try std.testing.expectEqualStrings(new.policy, row.value.object.get("policy").?.string);
}

test "appfilter activation detail distinguishes changed removed retired added and unchanged apps" {
    var allow = try @import("../../core/policy.zig").Policy.parse(std.testing.allocator, "{\"version\":\"blackice.policy/v0\",\"network\":{\"mode\":\"allowlist\",\"allow\":[\"example.com\"]}}", null);
    defer allow.deinit();
    var deny = try @import("../../core/policy.zig").Policy.parse(std.testing.allocator, "{\"version\":\"blackice.policy/v0\",\"network\":{\"mode\":\"deny-all\"}}", null);
    defer deny.deinit();
    var old: snapshot.Snapshot = .{ .stamp = .{ .generation = 1, .digest = @splat(1) } };
    for ([_][]const u8{ "/usr/bin/changed", "/usr/bin/removed", "/usr/bin/retired", "/usr/bin/unchanged" }, 0..) |path, i| {
        old.slots[i] = .{ .executable = path, .network = &allow, .identity = .{ .device = 1, .inode = i + 1 }, .stamp = old.stamp, .active = i != 2 };
    }
    var new = old;
    new.slots[0].?.network = &deny;
    new.slots[1].?.active = false;
    new.slots[4] = .{ .executable = "/usr/bin/added", .network = &allow, .identity = .{ .device = 1, .inode = 5 }, .stamp = old.stamp, .active = true };
    var bytes: [16384]u8 = undefined;
    const detail = try activationDetail(&bytes, &old, &new);
    try std.testing.expectEqualStrings("added=[\"/usr/bin/added\"]; removed=[\"/usr/bin/removed\"]; retired=[\"/usr/bin/removed\",\"/usr/bin/retired\"]; changed=[\"/usr/bin/changed\"]; tags_retained; narrowing_watchdog_ms=200", detail);
}
