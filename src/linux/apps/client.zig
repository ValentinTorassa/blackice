//! Unprivileged CLI transport. The service derives identity from socket credentials, not this payload.
const std = @import("std");
const ipc = @import("ipc.zig");
const sys = @import("../sys.zig");
pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, out: *std.Io.Writer, errw: *std.Io.Writer) !u8 {
    request(gpa, io, args, out) catch |err| {
        try errw.print("blackice app: {s}\n", .{@errorName(err)});
        return 125;
    };
    return 0;
}
fn request(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, out: *std.Io.Writer) !void {
    const op: ipc.Op = if (args.len == 1 and std.mem.eql(u8, args[0], "off")) .off else if (args.len == 1 and std.mem.eql(u8, args[0], "status")) .status else if (args.len == 3 and std.mem.eql(u8, args[0], "on") and std.mem.eql(u8, args[1], "--policy")) .on else return error.ExpectedAppOnPolicyOffOrStatus;
    const bytes = if (op == .on) try std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(ipc.max_policy)) else try gpa.alloc(u8, 0);
    defer gpa.free(bytes);
    if (op == .on) {
        var cfg = try @import("config.zig").Config.parse(gpa, bytes);
        cfg.deinit();
    }
    const fd = try ipc.unixConnect(ipc.socket_path);
    defer sys.close(fd);
    const h = ipc.encodeHeader(op, @intCast(bytes.len));
    try sys.writeAll(fd, &h);
    try sys.writeAll(fd, bytes);
    var reply: [512]u8 = undefined;
    for (0..reply.len) |i| {
        try ipc.readExact(fd, reply[i..][0..1], 120000);
        if (reply[i] == '\n') {
            try out.writeAll(reply[0 .. i + 1]);
            if (!std.mem.startsWith(u8, reply[0 .. i + 1], "OK ")) return error.AppFilterRefused;
            return;
        }
    }
    return error.InvalidServiceReply;
}
