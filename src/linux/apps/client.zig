//! Unprivileged CLI transport. The service derives identity from socket credentials, not this payload.
const std = @import("std");
const ipc = @import("ipc.zig");
const sys = @import("../sys.zig");
const config = @import("config.zig");
const reload = @import("reload_control.zig");
pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, out: *std.Io.Writer, errw: *std.Io.Writer) !u8 {
    if (args.len == 2 and std.mem.eql(u8, args[0], "reload") and std.mem.eql(u8, args[1], "--help")) {
        try out.writeAll(reload.help);
        return 0;
    }
    request(gpa, io, args, out) catch |err| {
        try errw.print("blackice app: {s}\n", .{@errorName(err)});
        return 125;
    };
    return 0;
}
pub const Request = struct { op: ipc.Op, policy_path: ?[]const u8 = null };
pub fn parseArgs(args: []const []const u8) !Request {
    if (args.len == 1) {
        if (std.mem.eql(u8, args[0], "off")) return .{ .op = .off };
        if (std.mem.eql(u8, args[0], "status")) return .{ .op = .status };
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "--policy") and args[2].len > 0) {
        if (std.mem.eql(u8, args[0], "on")) return .{ .op = .on, .policy_path = args[2] };
        if (std.mem.eql(u8, args[0], "reload")) return .{ .op = .reload, .policy_path = args[2] };
    }
    return error.ExpectedAppOnOrReloadPolicyOffOrStatus;
}
fn request(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, out: *std.Io.Writer) !void {
    const parsed = try parseArgs(args);
    const op = parsed.op;
    const bytes = if (parsed.policy_path) |path| try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(ipc.max_policy)) else try gpa.alloc(u8, 0);
    defer gpa.free(bytes);
    if (parsed.policy_path != null) {
        var cfg = if (op == .reload) try config.Config.parseReload(gpa, bytes) else try config.Config.parse(gpa, bytes);
        defer cfg.deinit();
        if (op == .on and cfg.generation != 1) return error.InitialGenerationMustBeOne;
    }
    if (op == .reload) try reload.requireAvailable(); // no socket, agent or prompt while gated
    // Start before connecting: registration cannot consume the daemon's control-header timeout.
    var agent = if (op == .off or op == .reload) try @import("tty_agent.zig").start(io) else null;
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

test "appfilter reload CLI accepts exactly one policy and never accepts client identity or generation overrides" {
    const parsed = try parseArgs(&.{ "reload", "--policy", "/tmp/apps.json" });
    try std.testing.expectEqual(ipc.Op.reload, parsed.op);
    try std.testing.expectEqualStrings("/tmp/apps.json", parsed.policy_path.?);
    const bad = [_][]const []const u8{ &.{"reload"}, &.{ "reload", "--policy" }, &.{ "reload", "--policy", "" }, &.{ "reload", "--policy", "x", "--uid", "1000" }, &.{ "reload", "--policy", "x", "--generation", "2" }, &.{ "reload", "--policy", "x", "--policy", "y" } };
    for (bad) |args| try std.testing.expectError(error.ExpectedAppOnOrReloadPolicyOffOrStatus, parseArgs(args));
}
