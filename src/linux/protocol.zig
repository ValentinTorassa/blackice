//! Private, versioned helper pipe. No workload-controlled strings become executable input.
const std = @import("std");
pub const helper_path = "/usr/local/libexec/blackice-linux-helper";
pub const cgroup_root = "/sys/fs/cgroup/blackice";
pub const max_ports = 8;
pub const max_protected = 48;
pub const launch_version = "--protocol-v2";

pub fn parseProtectedCount(s: []const u8) !usize {
    if (s.len == 0 or s.len > 2) return error.InvalidProtectedCount;
    for (s) |c| if (!std.ascii.isDigit(c)) return error.InvalidProtectedCount;
    const count = try std.fmt.parseInt(usize, s, 10);
    if (count > max_protected) return error.InvalidProtectedCount;
    return count;
}

pub fn validPath(path: []const u8) bool {
    if (path.len < 2 or path.len >= 4096 or path[0] != '/' or std.mem.findScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}
pub const magic: u32 = 0x42494345;
pub const Kind = enum(u16) { armed = 1, drop = 2, loss = 3, failure = 4, exited = 5, signaled = 6, cleanup = 7 };
pub const Event = extern struct {
    magic_number: u32 = magic,
    version: u16 = 1,
    kind: u16 = 0,
    value: u64 = 0,
    ip: [16]u8 = @splat(0),
    port: u16 = 0,
    family: u16 = 0,
    protocol: u32 = 0,
    pid: u32 = 0,
    reserved: u32 = 0,
    detail: [80]u8 = @splat(0),

    pub fn init(kind: Kind, detail: []const u8) Event {
        var e: Event = .{ .kind = @backingInt(kind) };
        const n = @min(e.detail.len - 1, detail.len);
        @memcpy(e.detail[0..n], detail[0..n]);
        return e;
    }
    pub fn text(e: *const Event) []const u8 {
        return std.mem.sliceTo(&e.detail, 0);
    }
    pub fn tag(e: Event) !Kind {
        if (e.magic_number != magic or e.version != 1 or e.reserved != 0) return error.InvalidProtocol;
        return std.enums.fromInt(Kind, e.kind) orelse error.InvalidProtocol;
    }
};
pub fn validScope(id: []const u8) bool {
    if (id.len != 10 or !std.mem.startsWith(u8, id, "s-")) return false;
    for (id[2..]) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}
pub fn parsePorts(s: []const u8, out: *[max_ports]u16) ![]const u16 {
    if (std.mem.eql(u8, s, "-")) return out[0..0];
    var it = std.mem.splitScalar(u8, s, ',');
    var n: usize = 0;
    while (it.next()) |part| {
        if (n == max_ports or part.len == 0 or part.len > 5) return error.InvalidPorts;
        for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidPorts;
        const port = std.fmt.parseInt(u16, part, 10) catch return error.InvalidPorts;
        if (port == 0) return error.InvalidPorts;
        for (out[0..n]) |other| if (other == port) return error.InvalidPorts;
        out[n] = port;
        n += 1;
    }
    return out[0..n];
}
test "protocol rejects path injection, zero ports and ambiguous port lists" {
    const t = std.testing;
    try t.expect(validScope("s-01abcdef"));
    for ([_][]const u8{ "s-../../xx", "s-1234567Z", "s-123456789", "x-01234567" }) |s| try t.expect(!validScope(s));
    var buf: [max_ports]u16 = undefined;
    try t.expectEqualSlices(u16, &.{ 1234, 65535 }, try parsePorts("1234,65535", &buf));
    try t.expectEqual(@as(usize, 0), (try parsePorts("-", &buf)).len);
    for ([_][]const u8{ "", "0", "+1", "1,", "1,1", "65536", "1\n2", "1;2" }) |s| try t.expectError(error.InvalidPorts, parsePorts(s, &buf));
    try t.expectEqual(@as(usize, 128), @sizeOf(Event));
    try t.expectEqual(@as(usize, 48), try parseProtectedCount("48"));
    for ([_][]const u8{ "", "-1", "+1", "49", "999", "1x" }) |s| try t.expectError(error.InvalidProtectedCount, parseProtectedCount(s));
    for ([_][]const u8{ "relative", "/", "/x/", "/x//y", "/x/../y", "/./x", "/x\x00y" }) |s| try t.expect(!validPath(s));
    try t.expect(validPath("/home/user/a file"));
}
