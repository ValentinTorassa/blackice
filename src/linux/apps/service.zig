//! Single dedicated-user instance. No client-controlled code, target cgroup or kernel offsets.
const std = @import("std");
const Io = std.Io;
const sys = @import("../sys.zig");
const l = sys.l;
const abi = @import("types.zig");
const config = @import("config.zig");
const kernel = @import("kernel.zig");
const host = @import("host.zig");
const ipc = @import("ipc.zig");
const polkit = @import("polkit.zig");
const proxy = @import("../../proxy/proxy.zig");
const receipt = @import("../../core/receipt.zig");
const Ring = @import("ring.zig").Ring;
const pinning = @import("pinning.zig");
const pin = @import("kernel_pin.zig");
const port_count = abi.last_port - abi.first_port + 1;

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        sys.writeAll(2, "blackice app filter: ") catch {};
        sys.writeAll(2, @errorName(err)) catch {};
        sys.writeAll(2, "; no new enforcement claim; existing pins retained unless authorized off completed\n") catch {};
        return 125;
    };
    return 0;
}
fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedServiceOrTeardown;
    const teardown = std.mem.eql(u8, args[1], "--teardown");
    if (!teardown and !std.mem.eql(u8, args[1], "--service")) return error.ExpectedServiceOrTeardown;
    const install = try host.installation(init.gpa);
    if (teardown) {
        if (l.geteuid() != 0) return error.OwnerRootTeardownRequired;
    } else {
        if (l.geteuid() != install.service_uid or l.getuid() != install.service_uid) return error.DedicatedSystemServiceRequired;
        const caps = try sys.capabilities();
        if (caps[0].effective != ((1 << 10) | (1 << 12)) or caps[1].effective != ((1 << 6) | (1 << 7))) return error.ServiceCapabilitiesRequired;
        try sys.noNewPrivileges();
        try sys.nonDumpable();
        try activatedSocket(init);
    }
    if (!teardown) try host.directories(install);
    const cg = try host.cgroup();
    defer sys.close(cg);
    const lock = try sys.fd(l.open(host.state_root ++ "/instance.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600));
    defer sys.close(lock);
    _ = try sys.check(l.flock(lock, 2 | 4));
    if (teardown) {
        if (try kernel.Loaded.openExisting(true)) |got| {
            var f = got;
            defer f.close();
            try f.detach(cg);
            try kernel.unpinAll();
        }
        // Without pins do not guess an ID or detach someone else's program.
        try kernel.requireVacant(cg);
        return;
    }
    // procfs files report size 0, so readFileAlloc on /proc/sys/kernel/osrelease returns no bytes and the
    // release check could never pass. uname(2) returns the same release string.
    const uts = std.posix.uname();
    const release = std.mem.sliceTo(&uts.release, 0);
    const btf = try Io.Dir.cwd().readFileAlloc(init.io, "/sys/kernel/btf/vmlinux", init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(btf);
    try pinning.verify(release, btf);
    var runtime: Runtime = .{ .gpa = init.gpa, .io = init.io, .install = install, .cg = cg };
    defer runtime.deinit();
    runtime.service_log = try newLog(init.gpa, init.io, "service", "appfilter");
    if (try kernel.Loaded.openExisting(true)) |got| {
        runtime.loaded = got;
        const state = try runtime.loaded.?.getState();
        if (state.owner_uid != install.owner_uid) return error.PinnedOwnerMismatch;
        if (state.phase != .armed) {
            try runtime.rollback();
            runtime.service_log.?.write(.{ .event = "app_filter_on_failed", .point = .app_filter, .reason = "interrupted_arming" });
        } else {
            runtime.loaded.?.close();
            runtime.loaded = (try kernel.Loaded.openExisting(false)) orelse return error.IncompletePins;
            try runtime.loaded.?.verifyAttachments(cg);
            const hex = std.fmt.bytesToHex(state.policy_sha256, .lower);
            const path = try std.fmt.allocPrint(init.gpa, host.state_root ++ "/policy-{s}.json", .{hex});
            defer init.gpa.free(path);
            const bytes = try Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(config.max_bytes));
            defer init.gpa.free(bytes);
            runtime.cfg = try config.Config.parse(init.gpa, bytes);
            if (!std.mem.eql(u8, &runtime.cfg.?.digest, &hex) or runtime.cfg.?.apps.len != state.app_count) return error.PinnedPolicyMismatch;
            try runtime.refreshFiles();
            try runtime.openLogs();
            try runtime.bindListeners();
            runtime.ring = try Ring.open(runtime.loaded.?.maps.ring);
            runtime.watch_fd = try host.watch(init.gpa, runtime.cfg.?.apps);
            try kernel.dropLoadCapabilities();
            try runtime.serveListeners();
            runtime.armed = true;
            runtime.service_log.?.policy_id = &runtime.cfg.?.digest;
            try runtime.drain();
            runtime.service_log.?.write(.{ .event = "app_filter_restart", .point = .app_filter, .detail = "reopened verified pins; receipts drained; file identities refreshed; downtime=unknown" });
        }
    } else try kernel.requireVacant(cg);
    while (true) {
        try runtime.drain();
        var fds = [_]l.pollfd{
            .{ .fd = 3, .events = l.POLL.IN, .revents = 0 },
            .{ .fd = runtime.watch_fd, .events = l.POLL.IN, .revents = 0 },
        };
        _ = try sys.poll(&fds, 100);
        if (fds[1].revents != 0) {
            var events: [8192]u8 = undefined;
            const n = l.read(runtime.watch_fd, &events, events.len);
            if (l.errno(n) != .AGAIN) _ = try sys.check(n);
            // Any event, including an overflow, causes a complete identity refresh and new watches.
            try runtime.refreshFiles();
            sys.close(runtime.watch_fd);
            runtime.watch_fd = -1;
            runtime.watch_fd = try host.watch(init.gpa, runtime.cfg.?.apps);
        }
        if (fds[0].revents == 0) continue;
        const client = try sys.fd(l.accept4(3, null, null, l.SOCK.CLOEXEC));
        defer sys.close(client);
        const keep_running = runtime.request(client) catch |err| {
            runtime.service_log.?.write(.{ .event = "app_filter_control", .point = .app_filter, .verdict = .deny, .reason = @errorName(err) });
            sys.writeAll(client, "ERROR ") catch {};
            sys.writeAll(client, @errorName(err)) catch {};
            sys.writeAll(client, "\n") catch {};
            if (runtime.failed_start) return error.ArmingFailed;
            continue;
        };
        if (!keep_running) return;
    }
}
fn activatedSocket(init: std.process.Init) !void {
    const count = init.environ_map.get("LISTEN_FDS") orelse return error.SocketActivationRequired;
    const pid = init.environ_map.get("LISTEN_PID") orelse return error.SocketActivationRequired;
    if (!std.mem.eql(u8, count, "1") or (std.fmt.parseInt(u32, pid, 10) catch 0) != l.getpid()) return error.SocketActivationRequired;
    var accepting: u32 = 0;
    var n: l.socklen_t = 4;
    _ = try sys.check(l.getsockopt(3, l.SOL.SOCKET, l.SO.ACCEPTCONN, std.mem.asBytes(&accepting), &n));
    if (accepting != 1) return error.SocketActivationRequired;
    var address: l.sockaddr.un = undefined;
    n = @sizeOf(l.sockaddr.un);
    _ = try sys.check(l.getsockname(3, @ptrCast(&address), &n));
    if (address.family != l.AF.UNIX or n != @offsetOf(l.sockaddr.un, "path") + ipc.socket_path.len + 1 or !std.mem.eql(u8, address.path[0..ipc.socket_path.len], ipc.socket_path)) return error.WrongControlSocket;
    _ = try sys.check(l.fcntl(3, l.F.SETFD, @as(u32, l.FD_CLOEXEC)));
}
fn newLog(gpa: std.mem.Allocator, io: Io, scope: []const u8, policy: []const u8) !receipt.Log {
    const name = try std.fmt.allocPrint(gpa, "receipt-{d}-{d}-{s}.jsonl", .{ Io.Clock.real.now(io).nanoseconds, l.getpid(), scope });
    defer gpa.free(name);
    var dir = try Io.Dir.openDirAbsolute(io, host.state_root, .{});
    defer dir.close(io);
    var log = try receipt.Log.open(io, dir, name, scope, policy);
    errdefer log.close();
    _ = try sys.check(l.fchmod(log.file.handle, 0o640));
    return log;
}
const Runtime = struct {
    gpa: std.mem.Allocator,
    io: Io,
    install: host.Install,
    cg: l.fd_t,
    cfg: ?config.Config = null,
    loaded: ?kernel.Loaded = null,
    ring: ?Ring = null,
    service_log: ?receipt.Log = null,
    logs: [abi.max_apps]?receipt.Log = @splat(null),
    scopes: [abi.max_apps]?[]const u8 = @splat(null),
    servers: [port_count * 2]?Io.net.Server = @splat(null),
    proxies: [abi.max_apps * 4]?*proxy.Proxy = @splat(null),
    watch_fd: l.fd_t = -1,
    armed: bool = false,
    failed_start: bool = false,
    reported_loss: u64 = 0,
    verifier: [65536]u8 = @splat(0),

    fn closeListeners(r: *Runtime) void {
        for (&r.proxies) |*p| if (p.*) |value| {
            value.stop();
            p.* = null;
        };
        for (&r.servers) |*s| if (s.*) |*value| {
            value.deinit(r.io);
            s.* = null;
        };
    }
    fn deinit(r: *Runtime) void {
        r.closeListeners();
        if (r.watch_fd >= 0) sys.close(r.watch_fd);
        if (r.ring) |*ring| ring.close();
        if (r.loaded) |*loaded| loaded.close(); // pins survive all unplanned termination
        for (&r.logs) |*log| if (log.*) |*value| value.close();
        for (r.scopes) |scope| if (scope) |value| r.gpa.free(value);
        if (r.service_log) |*log| log.close();
        if (r.cfg) |*cfg| cfg.deinit();
    }
    fn openLogs(r: *Runtime) !void {
        for (r.cfg.?.apps, 0..) |*app, i| {
            r.scopes[i] = try std.fmt.allocPrint(r.gpa, "app-{d}", .{i + 1});
            r.logs[i] = try newLog(r.gpa, r.io, r.scopes[i].?, &app.network.digest_hex);
            r.logs[i].?.app_id = @intCast(i + 1);
            r.logs[i].?.executable = app.executable;
        }
    }
    fn refreshFiles(r: *Runtime) !void {
        for (r.cfg.?.apps, 0..) |app, i| try r.loaded.?.addFile(try host.identity(r.gpa, app.executable), @intCast(i + 1));
    }
    fn bindListeners(r: *Runtime) !void {
        try host.portFloor();
        errdefer r.closeListeners();
        // Reserve the ENTIRE range before any proxy starts, so a collision cannot produce partial arming.
        for (abi.first_port..abi.last_port + 1) |port| for (0..2) |family| {
            const address: Io.net.IpAddress = if (family == 0) .{ .ip4 = .loopback(@intCast(port)) } else .{ .ip6 = .loopback(@intCast(port)) };
            r.servers[(port - abi.first_port) * 2 + family] = address.listen(r.io, .{}) catch |err| {
                var b: [128]u8 = undefined;
                const detail = try std.fmt.bufPrint(&b, "loopback port={d} family={d}: {s}", .{ port, family + 4, @errorName(err) });
                r.service_log.?.write(.{ .event = "app_filter_on_failed", .point = .app_filter, .reason = "listener_unavailable", .detail = detail });
                return error.ListenerPortOccupied;
            };
        };
    }
    fn serveListeners(r: *Runtime) !void {
        // Linux capabilities are per-thread. No workers may exist until the loader drops them.
        errdefer r.closeListeners();
        for (r.cfg.?.apps, 0..) |*app, i| for (0..4) |j| {
            const slot = i * 4 + j;
            const cfg: proxy.Config = .{ .mode = if (j < 2) .transparent_tls else .transparent_http, .receipt_point = .app_filter };
            r.proxies[slot] = try proxy.Proxy.startListening(r.gpa, r.io, &app.network, &r.logs[i].?, cfg, r.servers[slot].?);
            r.servers[slot] = null;
        };
    }
    fn rollback(r: *Runtime) !void {
        if (r.loaded == null) r.loaded = try kernel.Loaded.openExisting(true);
        if (r.loaded) |*f| {
            try f.detach(r.cg);
            try kernel.unpinAll();
            f.close();
            r.loaded = null;
        }
        r.closeListeners();
    }
    fn start(r: *Runtime, bytes: []const u8, peer: ipc.Peer) !void {
        r.cfg = try config.Config.parse(r.gpa, bytes);
        errdefer if (!r.failed_start) {
            r.cfg.?.deinit();
            r.cfg = null;
        };
        // Validate every executable and its ancestors before creating kernel objects.
        for (r.cfg.?.apps) |app| _ = try host.identity(r.gpa, app.executable);
        try host.writePolicy(r.gpa, r.io, &r.cfg.?.digest, bytes);
        var hash: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash, &r.cfg.?.digest);
        var state: abi.State = .{ .phase = .maps, .owner_uid = peer.credentials.uid, .app_count = @intCast(r.cfg.?.apps.len), .policy_sha256 = hash };
        r.failed_start = true;
        errdefer {
            r.rollback() catch {};
            const log = std.mem.sliceTo(&r.verifier, 0);
            if (log.len > 0) {
                sys.writeAll(2, log) catch {};
                sys.writeAll(2, "\n") catch {};
            }
        }
        r.loaded = try kernel.Loaded.create(state);
        try r.refreshFiles();
        for (r.cfg.?.apps, 0..) |_, i| try r.loaded.?.setPorts(@intCast(i + 1));
        try r.loaded.?.attach(r.cg, &r.verifier);
        state.phase = .cgroup;
        try r.loaded.?.setState(state);
        try r.openLogs();
        try r.bindListeners();
        state.phase = .listeners;
        try r.loaded.?.setState(state);
        try r.loaded.?.track(&r.verifier);
        state.phase = .tracking;
        try r.loaded.?.setState(state);
        try r.loaded.?.classifyExisting(&r.verifier);
        r.ring = try Ring.open(r.loaded.?.maps.ring);
        r.watch_fd = try host.watch(r.gpa, r.cfg.?.apps);
        try peer.live();
        if (try r.loaded.?.tag(@intCast(peer.credentials.pid)) != 0) return error.TaggedCaller;
        state.phase = .armed;
        try r.loaded.?.setState(state);
        try kernel.dropLoadCapabilities();
        try r.serveListeners();
        r.armed = true;
        r.failed_start = false;
        r.service_log.?.policy_id = &r.cfg.?.digest;
        var detail: [160]u8 = undefined;
        r.service_log.?.write(.{ .event = "app_filter_on", .point = .app_filter, .detail = try std.fmt.bufPrint(&detail, "caller_uid={d} caller_tgid={d}; pinned tracing; legacy user.slice attachments verified", .{ peer.credentials.uid, peer.credentials.pid }) });
    }
    fn request(r: *Runtime, client: l.fd_t) !bool {
        const peer = try ipc.Peer.open(client, r.install.owner_uid);
        defer peer.close();
        if (r.loaded) |*f| if (try f.tag(@intCast(peer.credentials.pid)) != 0) return error.TaggedCaller;
        var raw: [8]u8 = undefined;
        try ipc.readExact(client, &raw, 5000);
        const header = try ipc.decodeHeader(&raw);
        switch (header.op) {
            .status => {
                try sys.writeAll(client, if (r.armed) "OK armed\n" else "OK off\n");
                return r.armed;
            },
            .off => {
                if (r.armed) {
                    try polkit.authorize(peer);
                    if (try r.loaded.?.tag(@intCast(peer.credentials.pid)) != 0) return error.TaggedCaller;
                    var state = try r.loaded.?.getState();
                    state.phase = .stopping;
                    try r.loaded.?.setState(state);
                    try r.loaded.?.detach(r.cg);
                    try kernel.unpinAll();
                    r.armed = false;
                    var detail: [80]u8 = undefined;
                    r.service_log.?.write(.{ .event = "app_filter_off", .point = .app_filter, .reason = "owner_authorized", .detail = try std.fmt.bufPrint(&detail, "caller_uid={d} caller_tgid={d}", .{ peer.credentials.uid, peer.credentials.pid }) });
                }
                try sys.writeAll(client, "OK off\n");
                return false;
            },
            .on => {
                const bytes = try r.gpa.alloc(u8, header.length);
                defer r.gpa.free(bytes);
                try ipc.readExact(client, bytes, 5000);
                try peer.live();
                if (r.armed) {
                    var replacement = try config.Config.parse(r.gpa, bytes);
                    defer replacement.deinit();
                    if (!std.mem.eql(u8, &replacement.digest, &r.cfg.?.digest)) {
                        // A new app set changes identity IDs. v0 requires an explicitly authorized off/on.
                        // No partial update can reassign the policy of an existing tagged descendant.
                        return error.PolicyChangeRequiresAuthorizedOff;
                    }
                } else try r.start(bytes, peer);
                try sys.writeAll(client, "OK armed\n");
                return true;
            },
        }
    }
    fn drain(r: *Runtime) !void {
        if (r.ring) |*ring| {
            // Bound each batch so a flood cannot starve owner control.
            for (0..1024) |_| {
                const event = try ring.next() orelse break;
                const log = if (event.app_id > 0 and event.app_id <= r.cfg.?.apps.len) &r.logs[event.app_id - 1].? else &r.service_log.?;
                var ipbuf: [64]u8 = undefined;
                const ip = if (event.family == 2) proxy.formatIp(&ipbuf, .{ .ip4 = .{ .bytes = event.ip[0..4].*, .port = 0 } }) else proxy.formatIp(&ipbuf, .{ .ip6 = .{ .bytes = event.ip, .port = 0, .interface = .none } });
                var detail: [160]u8 = undefined;
                log.write(.{ .event = "kernel_drop", .point = .app_filter, .verdict = .deny, .reason = @tagName(event.reason), .app_id = event.app_id, .ip = if (event.port != 0) ip else null, .port = if (event.port != 0) std.mem.bigToNative(u16, @truncate(event.port)) else null, .detail = try std.fmt.bufPrint(&detail, "tgid={d} family={d} protocol={d} hook={d} kernel_monotonic_ns={d}", .{ event.tgid, event.family, event.protocol, event.hook, event.timestamp_ns }) });
            }
            const loss = try r.loaded.?.loss();
            if (loss != r.reported_loss) {
                var b: [64]u8 = undefined;
                r.service_log.?.write(.{ .event = "receipt_loss", .point = .app_filter, .reason = "ring_full", .detail = try std.fmt.bufPrint(&b, "total={d}", .{loss}) });
                r.reported_loss = loss;
            }
        }
    }
};
