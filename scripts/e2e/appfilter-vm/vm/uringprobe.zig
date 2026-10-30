//! io_uring probes for the app-filter kernel tests (test 4). Runs inside the disposable test VM only.
//!
//!   uringprobe basic DST4 PORT
//!       IORING_OP_SOCKET then IORING_OP_CONNECT, inline and with IOSQE_ASYNC (io-wq worker).
//!   uringprobe exitrace DST4 PORT ITERATIONS
//!       Each iteration forks a child that queues 16 async direct-socket + connect pairs and exits at once,
//!       so io-wq work may run while the thread group is exiting. The netns sniffer is the oracle.
//!   uringprobe sqpoll-server MODE DST4 PORT LAUNCHER [ARG]...
//!       Creates an SQPOLL ring, then runs LAUNCHER ARG... SELF sqpoll-client MODE DST4 PORT PARAMS with the
//!       ring on fd 3. Run it untagged with a listed launcher: the client is tagged, the SQPOLL thread is not.
//!   uringprobe sqpoll-client MODE DST4 PORT PARAMS ADDR_PTR TS_PTR
//!       MODE ring-socket: socket and connect both run in the ring (the SQPOLL thread's identity).
//!       MODE own-socket:  the client's own socket(), registered as a fixed file, connected through the ring.
//!       The SQPOLL thread reads user pointers in the server's address space, so the server keeps the
//!       destination address and the timeout and passes their addresses (ADDR_PTR, TS_PTR) to the client.
//!
//! Every connect is linked to a 3 s timeout. Output is one JSON line per result on stdout.
const std = @import("std");
const linux = std.os.linux;
const IoUring = linux.IoUring;

var out_buf: [4096]u8 = undefined;

fn emit(comptime fmt: []const u8, args: anytype) void {
    const line = std.fmt.bufPrint(&out_buf, fmt ++ "\n", args) catch return;
    var done: usize = 0;
    while (done < line.len) {
        const rc = linux.write(1, line[done..].ptr, line.len - done);
        if (linux.errno(rc) != .SUCCESS) return;
        done += rc;
    }
}

fn fail(what: []const u8, err: anyerror) noreturn {
    emit("{{\"probe\":\"uring\",\"error\":\"{s}: {s}\"}}", .{ what, @errorName(err) });
    linux.exit_group(2);
}

fn parse4(text: []const u8, port: u16) !linux.sockaddr.in {
    var parts: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (n == 4) return error.BadAddress;
        parts[n] = try std.fmt.parseInt(u8, p, 10);
    }
    if (n != 4) return error.BadAddress;
    return .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(parts) };
}

/// Errno name for a negative CQE result, or "ok".
fn resName(res: i32) []const u8 {
    if (res >= 0) return "ok";
    const e: linux.E = @enumFromInt(@as(u16, @intCast(-res)));
    return @tagName(e);
}

const timeout: linux.kernel_timespec = .{ .sec = 3, .nsec = 0 };

/// Queues connect + a linked timeout, waits for both, returns the connect result.
fn ringConnect(ring: *IoUring, fd: i32, fixed: bool, addr: *const linux.sockaddr.in, ts: *const linux.kernel_timespec, async_flag: bool) !i32 {
    const c = try ring.connect(1, fd, @ptrCast(addr), @sizeOf(linux.sockaddr.in));
    c.flags |= linux.IOSQE_IO_LINK;
    if (fixed) c.flags |= linux.IOSQE_FIXED_FILE;
    if (async_flag) c.flags |= linux.IOSQE_ASYNC;
    _ = try ring.link_timeout(2, ts, 0);
    _ = try ring.submit();
    var result: i32 = -@as(i32, @intFromEnum(linux.E.TIME));
    for (0..2) |_| {
        const cqe = try ring.copy_cqe();
        if (cqe.user_data == 1) result = cqe.res;
    }
    return result;
}

fn ringSocket(ring: *IoUring, async_flag: bool) !i32 {
    const s = try ring.socket(3, linux.AF.INET, linux.SOCK.STREAM, 0, 0);
    if (async_flag) s.flags |= linux.IOSQE_ASYNC;
    _ = try ring.submit();
    const cqe = try ring.copy_cqe();
    return cqe.res;
}

fn basic(dst: []const u8, port: u16) !void {
    const addr = try parse4(dst, port);
    for ([_]bool{ false, true }) |async_flag| {
        var ring = try IoUring.init(8, 0);
        defer ring.deinit();
        const sock = try ringSocket(&ring, async_flag);
        const conn: i32 = if (sock >= 0) try ringConnect(&ring, sock, false, &addr, &timeout, async_flag) else 0;
        emit("{{\"probe\":\"uring-basic\",\"async\":{},\"dst\":\"{s}:{d}\",\"socket\":\"{s}\",\"connect\":\"{s}\"}}", .{ async_flag, dst, port, resName(sock), if (sock >= 0) resName(conn) else "skipped" });
        if (sock >= 0) _ = linux.close(sock);
    }
}

fn exitrace(dst: []const u8, port: u16, iterations: u32) !void {
    const addr = try parse4(dst, port);
    var children: u32 = 0;
    for (0..iterations) |_| {
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
        if (pid == 0) {
            var ring = IoUring.init(64, 0) catch linux.exit_group(3);
            ring.register_files_sparse(16) catch linux.exit_group(4);
            for (0..16) |j| {
                const s = ring.socket_direct(10 + j, linux.AF.INET, linux.SOCK.STREAM, 0, 0, @intCast(j)) catch break;
                s.flags |= linux.IOSQE_ASYNC | linux.IOSQE_IO_LINK;
                const c = ring.connect(100 + j, @intCast(j), @ptrCast(&addr), @sizeOf(linux.sockaddr.in)) catch break;
                c.flags |= linux.IOSQE_ASYNC | linux.IOSQE_FIXED_FILE;
            }
            _ = ring.submit() catch {};
            linux.exit_group(0); // no wait: the requests are still queued in io-wq
        }
        var status: i32 = 0;
        _ = linux.wait4(@intCast(pid), &status, 0, null);
        children += 1;
    }
    emit("{{\"probe\":\"uring-exitrace\",\"dst\":\"{s}:{d}\",\"iterations\":{d}}}", .{ dst, port, children });
}

fn hexEncode(bytes: []const u8, buf: []u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[i * 2] = digits[b >> 4];
        buf[i * 2 + 1] = digits[b & 15];
    }
    return buf[0 .. bytes.len * 2];
}

// Read by the SQPOLL thread, which runs in this (the server's) address space.
var shared_addr: linux.sockaddr.in = undefined;
var shared_ts: linux.kernel_timespec = .{ .sec = 3, .nsec = 0 };

fn sqpollServer(arena: std.mem.Allocator, self_path: []const u8, rest: []const []const u8) !void {
    if (rest.len < 4) return error.Usage;
    shared_addr = try parse4(rest[1], try std.fmt.parseInt(u16, rest[2], 10));
    var params = std.mem.zeroInit(linux.io_uring_params, .{ .flags = linux.IORING_SETUP_SQPOLL, .sq_thread_idle = 5000 });
    var ring = try IoUring.init_params(16, &params);
    defer ring.deinit();
    var hex_buf: [2 * @sizeOf(linux.io_uring_params)]u8 = undefined;
    const hex = hexEncode(std.mem.asBytes(&params), &hex_buf);

    // argv: LAUNCHER ARG... SELF sqpoll-client MODE DST PORT PARAMS ADDR_PTR TS_PTR
    const launcher = rest[3..];
    var argv = try arena.alloc(?[*:0]const u8, launcher.len + 9);
    const addr_ptr = try std.fmt.allocPrint(arena, "{d}", .{@intFromPtr(&shared_addr)});
    const ts_ptr = try std.fmt.allocPrint(arena, "{d}", .{@intFromPtr(&shared_ts)});
    for (launcher, 0..) |a, i| argv[i] = try arena.dupeSentinel(u8, a, 0);
    const tail = [_][]const u8{ self_path, "sqpoll-client", rest[0], rest[1], rest[2], hex, addr_ptr, ts_ptr };
    for (tail, 0..) |a, i| argv[launcher.len + i] = try arena.dupeSentinel(u8, a, 0);
    argv[launcher.len + tail.len] = null;
    const envp = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", null };

    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        if (ring.fd != 3) {
            if (linux.errno(linux.dup2(ring.fd, 3)) != .SUCCESS) linux.exit_group(5);
        } else {
            // dup2 to itself keeps O_CLOEXEC; clear it so the ring survives exec.
            _ = linux.fcntl(3, linux.F.SETFD, 0);
        }
        _ = linux.execve(argv[0].?, @ptrCast(argv.ptr), &envp);
        linux.exit_group(6);
    }
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    emit("{{\"probe\":\"uring-sqpoll-server\",\"mode\":\"{s}\",\"child_status\":{d}}}", .{ rest[0], status });
}

fn sqpollClient(mode: []const u8, dst: []const u8, port: u16, hex: []const u8, addr_ptr: usize, ts_ptr: usize) !void {
    // Server addresses: valid in the SQPOLL thread's address space, never dereferenced here.
    const addr: *const linux.sockaddr.in = @ptrFromInt(addr_ptr);
    const ts: *const linux.kernel_timespec = @ptrFromInt(ts_ptr);
    var params: linux.io_uring_params = undefined;
    if (hex.len != 2 * @sizeOf(linux.io_uring_params)) return error.BadParams;
    _ = try std.fmt.hexToBytes(std.mem.asBytes(&params), hex);
    var sq = try IoUring.SubmissionQueue.init(3, params);
    const cq = try IoUring.CompletionQueue.init(3, params, sq);
    var ring: IoUring = .{ .fd = 3, .sq = sq, .cq = cq, .flags = params.flags, .features = params.features };
    _ = &sq;
    if (std.mem.eql(u8, mode, "ring-socket")) {
        const sock = try ringSocket(&ring, false);
        const conn: i32 = if (sock >= 0) try ringConnect(&ring, sock, false, addr, ts, false) else 0;
        emit("{{\"probe\":\"uring-sqpoll-client\",\"mode\":\"ring-socket\",\"dst\":\"{s}:{d}\",\"socket\":\"{s}\",\"connect\":\"{s}\"}}", .{ dst, port, resName(sock), if (sock >= 0) resName(conn) else "skipped" });
    } else if (std.mem.eql(u8, mode, "own-socket")) {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (linux.errno(rc) != .SUCCESS) {
            emit("{{\"probe\":\"uring-sqpoll-client\",\"mode\":\"own-socket\",\"dst\":\"{s}:{d}\",\"socket\":\"{s}\",\"connect\":\"skipped\"}}", .{ dst, port, @tagName(linux.errno(rc)) });
            return;
        }
        const own: i32 = @intCast(rc);
        var dev: [16]u8 = @splat(0);
        var dev_len: linux.socklen_t = dev.len;
        _ = linux.getsockopt(own, linux.SOL.SOCKET, linux.SO.BINDTODEVICE, &dev, &dev_len);
        try ring.register_files(&.{own});
        const conn = try ringConnect(&ring, 0, true, addr, ts, false);
        emit("{{\"probe\":\"uring-sqpoll-client\",\"mode\":\"own-socket\",\"dst\":\"{s}:{d}\",\"bound_device\":\"{s}\",\"connect\":\"{s}\"}}", .{ dst, port, std.mem.sliceTo(&dev, 0), resName(conn) });
    } else return error.Usage;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) fail("usage", error.Usage);
    const cmd = args[1];
    const run = blk: {
        if (std.mem.eql(u8, cmd, "basic") and args.len == 4) {
            break :blk basic(args[2], try std.fmt.parseInt(u16, args[3], 10));
        } else if (std.mem.eql(u8, cmd, "exitrace") and args.len == 5) {
            break :blk exitrace(args[2], try std.fmt.parseInt(u16, args[3], 10), try std.fmt.parseInt(u32, args[4], 10));
        } else if (std.mem.eql(u8, cmd, "sqpoll-server") and args.len >= 6) {
            break :blk sqpollServer(arena, args[0], args[2..]);
        } else if (std.mem.eql(u8, cmd, "sqpoll-client") and args.len == 8) {
            break :blk sqpollClient(args[2], args[3], try std.fmt.parseInt(u16, args[4], 10), args[5], try std.fmt.parseInt(usize, args[6], 10), try std.fmt.parseInt(usize, args[7], 10));
        }
        break :blk error.Usage;
    };
    run catch |err| fail(cmd, err);
}
