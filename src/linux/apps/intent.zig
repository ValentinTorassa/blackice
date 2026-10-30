//! Durable intent is separate from volatile pins. A reboot must not look like an authorized off.
const std = @import("std");
const sys = @import("../sys.zig");
const host = @import("host.zig");
pub const Intent = struct { armed: bool, boot: [36]u8, policy: [64]u8 };
const Wire = struct { version: u32, armed: bool, boot_id: []const u8, policy_sha256: []const u8 };

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
    if (bytes.len > 512) return error.InvalidIntent;
    const decoded = std.json.parseFromSlice(Wire, gpa, bytes, .{ .duplicate_field_behavior = .@"error" }) catch return error.InvalidIntent;
    defer decoded.deinit();
    const w = decoded.value;
    if (w.version != 1 or !validBoot(w.boot_id) or w.policy_sha256.len != 64) return error.InvalidIntent;
    for (w.policy_sha256) |ch| if (!std.ascii.isHex(ch)) return error.InvalidIntent;
    return .{ .armed = w.armed, .boot = w.boot_id[0..36].*, .policy = w.policy_sha256[0..64].* };
}
pub fn read(gpa: std.mem.Allocator, io: std.Io) !?Intent {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, host.state_root ++ "/intent.json", gpa, .limited(512)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer gpa.free(bytes);
    return try parse(gpa, bytes);
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
