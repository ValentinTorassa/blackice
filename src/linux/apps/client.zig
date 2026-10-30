//! Unprivileged CLI transport. The service derives identity from socket credentials, not this payload.
const std = @import("std");
const ipc = @import("ipc.zig");
const sys = @import("../sys.zig");
const off_help =
    \\usage: blackice app off
    \\
    \\Authorize turning off the application filter through polkit.
    \\Answer the password prompt within 15 s. The whole authorization exchange shares that budget.
    \\On timeout, off is refused; run `blackice app off` again.
    \\Use a terminal (ssh -t) or a desktop session with a polkit agent.
    \\
;
pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, out: *std.Io.Writer, errw: *std.Io.Writer) !u8 {
    if (args.len == 2 and std.mem.eql(u8, args[0], "off") and
        (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")))
    {
        try out.writeAll(off_help);
        return 0;
    }
    request(gpa, io, args, out) catch |err| {
        const off = isOff(args);
        const tty = if (off) std.Io.File.stdin().isTty(io) catch false else false;
        try writeFailure(errw, err, off, tty);
        return 125;
    };
    return 0;
}
fn isOff(args: []const []const u8) bool {
    return args.len == 1 and std.mem.eql(u8, args[0], "off");
}
fn writeFailure(errw: *std.Io.Writer, err: anyerror, off: bool, tty: bool) !void {
    try errw.print("blackice app: {s}\n", .{@errorName(err)});
    if (off and !tty) try errw.writeAll("For interactive authorization, run `blackice app off` from a terminal (ssh -t) or a desktop session with a polkit agent.\n");
}
fn request(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, out: *std.Io.Writer) !void {
    const op: ipc.Op = if (isOff(args)) .off else if (args.len == 1 and std.mem.eql(u8, args[0], "status")) .status else if (args.len == 3 and std.mem.eql(u8, args[0], "on") and std.mem.eql(u8, args[1], "--policy")) .on else return error.ExpectedAppOnPolicyOffOrStatus;
    const bytes = if (op == .on) try std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(ipc.max_policy)) else try gpa.alloc(u8, 0);
    defer gpa.free(bytes);
    if (op == .on) {
        var cfg = try @import("config.zig").Config.parse(gpa, bytes);
        cfg.deinit();
    }
    // Start before connecting: registration cannot consume the daemon's control-header timeout.
    var agent = if (op == .off) try @import("tty_agent.zig").start(io) else null;
    defer if (agent) |*a| a.stop(io);
    const fd = try ipc.unixConnect(ipc.socket_path);
    defer sys.close(fd);
    const h = ipc.encodeHeader(op, @intCast(bytes.len));
    try sys.writeAll(fd, &h);
    try sys.writeAll(fd, bytes);
    var reply: [512]u8 = undefined;
    const deadline = try ipc.Deadline.after(120000);
    for (0..reply.len) |i| {
        try deadline.read(fd, reply[i..][0..1]);
        if (reply[i] == '\n') {
            try out.writeAll(reply[0 .. i + 1]);
            if (!std.mem.startsWith(u8, reply[0 .. i + 1], "OK ")) return error.AppFilterRefused;
            return;
        }
    }
    return error.InvalidServiceReply;
}

test "appfilter off failure explains terminal authorization only for non-tty off" {
    for ([_]bool{ false, true }) |tty| {
        for ([_][]const []const u8{ &.{"off"}, &.{"status"}, &.{ "on", "--policy", "apps.json" }, &.{ "off", "extra" } }) |args| {
            var buffer: [512]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try writeFailure(&writer, error.AppFilterRefused, isOff(args), tty);
            const message = writer.buffered();
            try std.testing.expect(std.mem.startsWith(u8, message, "blackice app: AppFilterRefused\n"));
            try std.testing.expectEqual(!tty and args.len == 1 and std.mem.eql(u8, args[0], "off"), std.mem.find(u8, message, "ssh -t") != null);
        }
    }
}

test "appfilter off help explains the authorization deadline without starting an agent" {
    for ([_][]const u8{ "--help", "-h" }) |flag| {
        var stdout: [1024]u8 = undefined;
        var stderr: [128]u8 = undefined;
        var out = std.Io.Writer.fixed(&stdout);
        var errw = std.Io.Writer.fixed(&stderr);
        try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, .failing, &.{ "off", flag }, &out, &errw));
        try std.testing.expect(std.mem.find(u8, out.buffered(), "Answer the password prompt within 15 s") != null);
        try std.testing.expectEqual(@as(usize, 0), errw.buffered().len);
    }
}
