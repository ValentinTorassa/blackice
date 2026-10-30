//! Control socket: how a scope's owner changes the running scope from outside it.
//!
//! Each scope listens on <scope_dir>/control.sock (Unix stream socket, mode 0600 inside the scope's state
//! directory). Only a peer running as the same user is served (SO_PEERCRED on Linux, getpeereid on macOS);
//! any other peer is refused with a receipt. The command inside the scope cannot reach the socket: the OS
//! backend refuses its Unix-socket connects (Seatbelt's network-outbound deny on macOS, the Linux backend's
//! socket filter), so in v0 "owner" means a same-user process outside every scope.
//!
//! Protocol: one JSON line in, one JSON line out, then the connection closes.
//!   {"op":"grant","host":"api.example.com","for_s":600}  ->  {"ok":true,"expires":"2026-10-30T05:12:33.123Z"}
//!   {"op":"revoke","host":"api.example.com"}             ->  {"ok":true,"removed":true}
//!   anything refused                                      ->  {"ok":false,"error":"<reason>"}
//! Parsing is strict: unknown fields are refused. `host` is a name or "*.name" (policy syntax); IP literals
//! are refused. `for_s` is 1..3600. Granting a host that already has a grant extends it, never shortens it.
//!
//! Receipts (point "control"), event "grant" | "revoke" (or "control" before the op is known):
//!   owner_grant      grant added or extended (rule = the pattern; detail = "for <n>s until <ts>")
//!   owner_revoke     revoke handled (detail = "removed" | "not_found")
//!   peer_not_owner   the peer is another user, or its uid could not be read (detail = "uid=<n>")
//!   bad_request      not one JSON line with the fields above
//!   invalid_duration for_s outside 1..3600
//!   invalid_host     the host is not a name or *.name

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const receipt = @import("../core/receipt.zig");
const Grants = @import("../proxy/grants.zig").Grants;

pub const socket_name = "control.sock";
pub const max_grant_seconds = 3600;
/// sun_path is 104 bytes on macOS (108 on Linux); use the smaller everywhere.
pub const max_socket_path = 103;
const max_line = 1024;

pub const Reply = struct {
    ok: bool,
    expires: ?[]const u8 = null,
    removed: ?bool = null,
    @"error": ?[]const u8 = null,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    grants: *Grants,
    receipts: *receipt.Log,
    server: net.Server,
    /// Absolute or cwd-relative path of the socket. Owned.
    path: []u8,
    uid: u32,
    group: Io.Group = .init,
    active: std.atomic.Value(u32) = .init(0),

    const max_connections = 8;

    pub const StartError = net.UnixAddress.ListenError || Io.ConcurrentError || Io.Dir.SetFilePermissionsError ||
        error{ OutOfMemory, PathTooLong, StaleSocket };

    /// Listens on <scope_dir>/control.sock. `grants` and `receipts` must outlive the server.
    pub fn start(gpa: std.mem.Allocator, io: Io, scope_dir: []const u8, grants: *Grants, receipts: *receipt.Log) StartError!*Server {
        const path = try std.fs.path.join(gpa, &.{ scope_dir, socket_name });
        errdefer gpa.free(path);
        if (path.len > max_socket_path) return error.PathTooLong;

        // A socket file left by a crashed run would make bind fail.
        Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.StaleSocket,
        };
        const addr = net.UnixAddress.init(path) catch return error.PathTooLong;
        var server = try addr.listen(io, .{});
        errdefer server.deinit(io);
        // The scope directory is 0700 already; the socket itself is 0600 as well.
        try Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o600), .{});

        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .grants = grants,
            .receipts = receipts,
            .server = server,
            .path = path,
            .uid = currentUid(),
        };
        try s.group.concurrent(io, acceptLoop, .{s});
        return s;
    }

    /// Stops serving, removes the socket file and frees the server.
    pub fn stop(s: *Server) void {
        const io = s.io;
        s.group.cancel(io);
        s.server.deinit(io);
        Io.Dir.cwd().deleteFile(io, s.path) catch {};
        s.gpa.free(s.path);
        s.gpa.destroy(s);
    }

    fn acceptLoop(s: *Server) Io.Cancelable!void {
        const io = s.io;
        while (true) {
            const stream = s.server.accept(io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.ConnectionAborted, error.WouldBlock => continue,
                error.SocketNotListening => return,
                else => {
                    s.receipts.write(.{ .event = "warning", .point = .control, .reason = "accept_failed", .detail = @errorName(err) });
                    try io.sleep(.fromMilliseconds(100), .awake);
                    continue;
                },
            };
            // Each connection gets its own task, so work inside it can never consume the loop's
            // cancelation and leave accept() blocked after stop().
            if (s.active.fetchAdd(1, .monotonic) >= max_connections) {
                _ = s.active.fetchSub(1, .monotonic);
                stream.close(io);
                continue;
            }
            s.group.concurrent(io, serveTask, .{ s, stream }) catch {
                _ = s.active.fetchSub(1, .monotonic);
                stream.close(io);
            };
        }
    }

    fn serveTask(s: *Server, stream: net.Stream) Io.Cancelable!void {
        defer {
            stream.close(s.io);
            _ = s.active.fetchSub(1, .monotonic);
        }
        s.serve(stream);
    }

    fn serve(s: *Server, stream: net.Stream) void {
        var in_buf: [max_line]u8 = undefined;
        var out_buf: [256]u8 = undefined;
        var r = stream.reader(s.io, &in_buf);
        var w = stream.writer(s.io, &out_buf);
        const out = &w.interface;

        const peer = peerUid(stream.socket.handle);
        if (peer == null or peer.? != s.uid) {
            var detail_buf: [32]u8 = undefined;
            const detail = if (peer) |u| std.fmt.bufPrint(&detail_buf, "uid={d}", .{u}) catch "uid=?" else "uid=unknown";
            s.refuse(out, "control", "peer_not_owner", null, detail);
            return;
        }

        const line = r.interface.takeDelimiterExclusive('\n') catch {
            s.refuse(out, "control", "bad_request", null, "one JSON line expected");
            return;
        };
        s.handleLine(out, std.mem.trimEnd(u8, line, "\r"));
    }

    const Request = struct {
        op: []const u8,
        host: []const u8,
        for_s: ?i64 = null,
    };

    fn handleLine(s: *Server, out: *Io.Writer, line: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const req = std.json.parseFromSliceLeaky(Request, arena.allocator(), line, .{}) catch {
            s.refuse(out, "control", "bad_request", null, "strict JSON: op, host and for_s only");
            return;
        };
        var host_buf: [300]u8 = undefined;
        const host = printable(&host_buf, req.host);

        if (std.mem.eql(u8, req.op, "grant")) {
            const secs = req.for_s orelse {
                s.refuse(out, "grant", "invalid_duration", host, "for_s is required");
                return;
            };
            if (secs < 1 or secs > max_grant_seconds) {
                s.refuse(out, "grant", "invalid_duration", host, "for_s must be 1..3600");
                return;
            }
            const expires = s.grants.add(s.io, req.host, .fromSeconds(secs)) catch |err| switch (err) {
                error.InvalidPattern => {
                    s.refuse(out, "grant", "invalid_host", host, "use a name or *.name");
                    return;
                },
                error.OutOfMemory => {
                    s.refuse(out, "grant", "bad_request", host, "out of memory");
                    return;
                },
            };
            var ts_buf: [32]u8 = undefined;
            const ts = receipt.formatTimestamp(&ts_buf, expires);
            var detail_buf: [64]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "for {d}s until {s}", .{ secs, ts }) catch "";
            s.receipts.write(.{
                .event = "grant",
                .point = .control,
                .verdict = .allow,
                .reason = "owner_grant",
                .rule = host,
                .host = host,
                .detail = detail,
            });
            reply(out, .{ .ok = true, .expires = ts });
            return;
        }

        if (std.mem.eql(u8, req.op, "revoke")) {
            if (req.for_s != null) {
                s.refuse(out, "revoke", "bad_request", host, "revoke takes no for_s");
                return;
            }
            const removed = s.grants.revoke(s.io, req.host);
            s.receipts.write(.{
                .event = "revoke",
                .point = .control,
                .verdict = .allow,
                .reason = "owner_revoke",
                .rule = host,
                .host = host,
                .detail = if (removed) "removed" else "not_found",
            });
            reply(out, .{ .ok = true, .removed = removed });
            return;
        }

        s.refuse(out, "control", "bad_request", host, "op must be grant or revoke");
    }

    fn refuse(s: *Server, out: *Io.Writer, event: []const u8, reason: []const u8, host: ?[]const u8, detail: []const u8) void {
        s.receipts.write(.{
            .event = event,
            .point = .control,
            .verdict = .deny,
            .reason = reason,
            .host = host,
            .detail = detail,
        });
        reply(out, .{ .ok = false, .@"error" = reason });
    }
};

fn reply(out: *Io.Writer, r: Reply) void {
    out.print("{f}\n", .{std.json.fmt(r, .{ .emit_null_optional_fields = false })}) catch return;
    out.flush() catch {};
}

fn printable(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], buf[0..n]) |ch, *o| o.* = if (ch >= 0x20 and ch < 0x7f) ch else '?';
    return buf[0..n];
}

fn currentUid() u32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getuid(),
        else => @intCast(std.c.getuid()),
    };
}

extern "c" fn getpeereid(fd: c_int, euid: *std.c.uid_t, egid: *std.c.gid_t) c_int;

/// The uid of the process at the other end of a Unix socket, or null when the OS cannot say.
pub fn peerUid(handle: net.Socket.Handle) ?u32 {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
            var cred: Ucred = undefined;
            var len: linux.socklen_t = @sizeOf(Ucred);
            const rc = linux.getsockopt(handle, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len);
            if (linux.errno(rc) != .SUCCESS or len != @sizeOf(Ucred)) return null;
            return cred.uid;
        },
        .macos, .ios => {
            var uid: std.c.uid_t = undefined;
            var gid: std.c.gid_t = undefined;
            if (getpeereid(handle, &uid, &gid) != 0) return null;
            return @intCast(uid);
        },
        else => return null,
    }
}

// ---------------------------------------------------------------- client

pub const ClientError = net.UnixAddress.ConnectError || error{
    OutOfMemory,
    PathTooLong,
    WriteFailed,
    ReadFailed,
    /// The server closed without a reply line, or the reply was not valid.
    BadReply,
};

/// Sends one request line to the scope's control socket and returns the parsed reply. Caller deinits.
pub fn send(gpa: std.mem.Allocator, io: Io, scope_dir: []const u8, line: []const u8) ClientError!std.json.Parsed(Reply) {
    var path_buf: [max_socket_path + 1]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{c}{s}", .{ scope_dir, std.fs.path.sep, socket_name }) catch return error.PathTooLong;
    if (path.len > max_socket_path) return error.PathTooLong;
    const addr = net.UnixAddress.init(path) catch return error.PathTooLong;
    const stream = try addr.connect(io);
    defer stream.close(io);

    var out_buf: [max_line]u8 = undefined;
    var w = stream.writer(io, &out_buf);
    w.interface.writeAll(line) catch return error.WriteFailed;
    w.interface.writeByte('\n') catch return error.WriteFailed;
    w.interface.flush() catch return error.WriteFailed;

    var in_buf: [max_line]u8 = undefined;
    var r = stream.reader(io, &in_buf);
    const reply_line = r.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        else => return error.BadReply,
    };
    return std.json.parseFromSlice(Reply, gpa, reply_line, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadReply,
    };
}

/// `blackice grant <scope> <host> --for <duration>`: asks the running scope to allow `host` for `seconds`.
pub fn grant(gpa: std.mem.Allocator, io: Io, scope_dir: []const u8, host: []const u8, seconds: u32) ClientError!std.json.Parsed(Reply) {
    var buf: [max_line]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(.{ .op = "grant", .host = host, .for_s = seconds }, .{})}) catch
        return error.WriteFailed;
    return send(gpa, io, scope_dir, line);
}

/// Removes a grant before it expires.
pub fn revoke(gpa: std.mem.Allocator, io: Io, scope_dir: []const u8, host: []const u8) ClientError!std.json.Parsed(Reply) {
    var buf: [max_line]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(.{ .op = "revoke", .host = host }, .{})}) catch
        return error.WriteFailed;
    return send(gpa, io, scope_dir, line);
}

/// Parses a duration like "90s", "10m" or "1h" (or bare seconds) into seconds. Null when invalid.
pub fn parseDuration(text: []const u8) ?u32 {
    if (text.len == 0) return null;
    const unit: u32 = switch (text[text.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        '0'...'9' => 1,
        else => return null,
    };
    const digits = if (text[text.len - 1] >= '0' and text[text.len - 1] <= '9') text else text[0 .. text.len - 1];
    const n = std.fmt.parseInt(u32, digits, 10) catch return null;
    return std.math.mul(u32, n, unit) catch null;
}

test {
    _ = @import("test.zig");
}
