//! Reload records use the existing flat receipt writer and captured contexts.
const std = @import("std");
const receipt = @import("../../core/receipt.zig");

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
