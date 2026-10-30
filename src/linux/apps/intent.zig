//! Durable intent is separate from volatile pins. A reboot must not look like an authorized off.
const std = @import("std");
const sys = @import("../sys.zig");
const host = @import("host.zig");
const max_generations = @import("config.zig").max_generations;
const History = @import("reload_history.zig").History;
const abi = @import("types.zig");
const Identity = struct { device: u32, inode: u64 };
pub const Intent = struct { armed: bool, boot: [36]u8, policy: [64]u8, generation: u32 = 1, retired_slots: u8 = 0, history: [max_generations][64]u8 = @splat(@splat(0)), identities: [abi.max_apps]?Identity = @splat(null) };
const Wire = struct { version: u32, armed: bool, boot_id: []const u8, policy_sha256: []const u8, generation: u32 = 1, retired_slots: u8 = 0, generations: ?[]const []const u8 = null, identities: ?[]const ?Identity = null };
const max_intent_bytes = 20 * 1024;

pub fn bootId() ![36]u8 {
    const fd = try sys.fd(sys.l.open("/proc/sys/kernel/random/boot_id", .{ .CLOEXEC = true, .NOFOLLOW = true }, 0));
    defer sys.close(fd);
    var buf: [64]u8 = undefined;
    const n = try sys.read(fd, &buf);
    const value = std.mem.trim(u8, buf[0..n], "\n");
    if (!validBoot(value)) return error.InvalidBootId;
    return value[0..36].*;
}
fn validBoot(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (ch != '-') return false;
        } else if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}
fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Intent {
    if (bytes.len > max_intent_bytes) return error.InvalidIntent;
    const decoded = std.json.parseFromSlice(Wire, gpa, bytes, .{ .duplicate_field_behavior = .@"error" }) catch return error.InvalidIntent;
    defer decoded.deinit();
    const w = decoded.value;
    if ((w.version != 1 and w.version != 2) or !validBoot(w.boot_id) or w.policy_sha256.len != 64) return error.InvalidIntent;
    for (w.policy_sha256) |ch| if (!std.ascii.isHex(ch)) return error.InvalidIntent;
    var result: Intent = .{ .armed = w.armed, .boot = w.boot_id[0..36].*, .policy = w.policy_sha256[0..64].* };
    if (w.version == 1) {
        if (w.generation != 1 or w.generations != null or w.retired_slots != 0 or w.identities != null) return error.InvalidIntent;
        result.history[0] = result.policy;
    } else {
        const hashes = w.generations orelse return error.InvalidIntent;
        if (w.generation == 0 or w.generation > max_generations or hashes.len != w.generation or w.retired_slots > 127) return error.InvalidIntent;
        for (hashes, 0..) |hash, i| {
            if (hash.len != 64) return error.InvalidIntent;
            for (hash) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return error.InvalidIntent;
            result.history[i] = hash[0..64].*;
        }
        if (!std.mem.eql(u8, hashes[hashes.len - 1], w.policy_sha256)) return error.InvalidIntent;
        result.generation = w.generation;
        result.retired_slots = w.retired_slots;
        if (w.identities) |ids| {
            if (ids.len != abi.max_apps) return error.InvalidIntent;
            for (ids, 0..) |id, i| {
                if (id) |key| if (key.inode == 0) return error.InvalidIntent;
                result.identities[i] = id;
            }
        }
        for (result.identities, 0..) |id, i| if (w.retired_slots & (@as(u8, 1) << @as(u3, @intCast(i))) != 0 and id == null) return error.InvalidIntent;
    }
    return result;
}
pub fn read(gpa: std.mem.Allocator, io: std.Io) !?Intent {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, host.state_root ++ "/intent.json", gpa, .limited(max_intent_bytes)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer gpa.free(bytes);
    return try parse(gpa, bytes);
}
pub fn writeHistory(gpa: std.mem.Allocator, io: std.Io, h: *const History, candidate: ?*@import("reload_history.zig").Generation) !void {
    var hashes: [max_generations][]const u8 = undefined;
    for (h.generations[0..h.count], 0..) |g, i| hashes[i] = &g.?.cfg.digest;
    const head = candidate orelse h.head.load(.acquire).?;
    const count = h.count + @as(u32, if (candidate != null) 1 else 0);
    if (count == 0 or count > max_generations or head.cfg.generation != count) return error.InvalidIntent;
    if (candidate != null) hashes[count - 1] = &head.cfg.digest;
    var retired: u8 = 0;
    var identities: [abi.max_apps]?Identity = @splat(null);
    for (head.snapshot.slots, 0..) |slot, i| if (slot) |b| {
        identities[i] = .{ .device = b.identity.device, .inode = b.identity.inode };
        if (!b.active) {
            retired |= @as(u8, 1) << @as(u3, @intCast(i));
        }
    };
    const boot = try bootId();
    const bytes = try std.json.Stringify.valueAlloc(gpa, Wire{ .version = 2, .armed = true, .boot_id = &boot, .policy_sha256 = &head.cfg.digest, .generation = count, .retired_slots = retired, .generations = hashes[0..count], .identities = &identities }, .{});
    defer gpa.free(bytes);
    var dir = try std.Io.Dir.openDirAbsolute(io, host.state_root, .{});
    defer dir.close(io);
    try host.atomicWrite(dir, io, "intent.json", bytes, true);
}

pub const Pending = struct { generation: u32, old_policy: [64]u8, new_policy: [64]u8 };
pub fn pendingWrite(gpa: std.mem.Allocator, io: std.Io, value: Pending) !void {
    const bytes = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(bytes);
    var dir = try std.Io.Dir.openDirAbsolute(io, host.state_root, .{});
    defer dir.close(io);
    try host.atomicWrite(dir, io, "reload-pending.json", bytes, true);
}
pub fn pendingRead(gpa: std.mem.Allocator, io: std.Io) !?Pending {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, host.state_root ++ "/reload-pending.json", gpa, .limited(2048)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(Pending, gpa, bytes, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    if (parsed.value.generation < 2 or parsed.value.generation > max_generations) return error.InvalidIntent;
    for (parsed.value.old_policy ++ parsed.value.new_policy) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return error.InvalidIntent;
    return parsed.value;
}
pub fn pendingClear(io: std.Io) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, host.state_root, .{});
    defer dir.close(io);
    dir.deleteFile(io, "reload-pending.json") catch |err| if (err != error.FileNotFound) return err;
    const fd = try sys.fd(sys.l.openat(dir.handle, ".", .{ .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0));
    defer sys.close(fd);
    _ = try sys.check(sys.l.fsync(fd));
}
pub fn write(gpa: std.mem.Allocator, io: std.Io, armed: bool, digest: *const [64]u8) !void {
    const boot = try bootId();
    const bytes = try std.json.Stringify.valueAlloc(gpa, Wire{ .version = 1, .armed = armed, .boot_id = &boot, .policy_sha256 = digest }, .{});
    defer gpa.free(bytes);
    var dir = try std.Io.Dir.openDirAbsolute(io, host.state_root, .{});
    defer dir.close(io);
    try host.atomicWrite(dir, io, "intent.json", bytes, true);
}
pub fn absentPinsStatus(saved: ?Intent, boot: *const [36]u8) []const u8 {
    const s = saved orelse return "off";
    if (!s.armed) return "off";
    return if (std.mem.eql(u8, &s.boot, boot)) "disarmed_pins_missing" else "disarmed_by_reboot";
}
test "appfilter persisted intent distinguishes reboot, missing pins and authorized off" {
    const boot = "00000000-0000-0000-0000-000000000001".*;
    var saved: Intent = .{ .armed = true, .boot = boot, .policy = @splat('0') };
    try std.testing.expectEqualStrings("disarmed_pins_missing", absentPinsStatus(saved, &boot));
    saved.boot[35] = '2';
    try std.testing.expectEqualStrings("disarmed_by_reboot", absentPinsStatus(saved, &boot));
    saved.armed = false;
    try std.testing.expectEqualStrings("off", absentPinsStatus(saved, &boot));
    try std.testing.expectEqualStrings("off", absentPinsStatus(null, &boot));
    try std.testing.expectError(error.InvalidIntent, parse(std.testing.allocator, "{\"armed\":false}"));
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, Wire{ .version = 1, .armed = true, .boot_id = &boot, .policy_sha256 = &saved.policy }, .{});
    defer std.testing.allocator.free(bytes);
    const got = try parse(std.testing.allocator, bytes);
    try std.testing.expect(got.armed);
    try std.testing.expectEqualSlices(u8, &boot, &got.boot);
}

test "appfilter v2 intent binds the ordered bounded history to the committed digest" {
    const boot = "00000000-0000-0000-0000-000000000001";
    const first: [64]u8 = @splat('1');
    const second: [64]u8 = @splat('2');
    const hashes = [_][]const u8{ &first, &second };
    var identities: [abi.max_apps]?Identity = @splat(null);
    identities[0] = .{ .device = 8, .inode = 12 };
    const w: Wire = .{ .version = 2, .armed = true, .boot_id = boot, .policy_sha256 = &second, .generation = 2, .retired_slots = 1, .generations = &hashes, .identities = &identities };
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, w, .{});
    defer std.testing.allocator.free(bytes);
    const saved = try parse(std.testing.allocator, bytes);
    try std.testing.expectEqual(@as(u32, 2), saved.generation);
    try std.testing.expectEqual(@as(u8, 1), saved.retired_slots);
    try std.testing.expectEqualStrings(&first, &saved.history[0]);
    try std.testing.expectEqualStrings(&second, &saved.history[1]);
    for (0..5) |scenario| {
        var bad = w;
        switch (scenario) {
            0 => bad.generation = 1,
            1 => bad.policy_sha256 = &first,
            2 => bad.generations = null,
            3 => bad.retired_slots = 128,
            4 => bad.identities = null,
            else => unreachable,
        }
        const malformed = try std.json.Stringify.valueAlloc(std.testing.allocator, bad, .{});
        defer std.testing.allocator.free(malformed);
        try std.testing.expectError(error.InvalidIntent, parse(std.testing.allocator, malformed));
    }
}
