//! Fixed loader and protected-pin lifecycle. Unit tests never call capability-using operations.
const std = @import("std");
const sys = @import("../sys.zig");
const l = sys.l;
const bpf = l.BPF;
const abi = @import("types.zig");
const programs = @import("programs.zig");
const pin = @import("kernel_pin.zig");
const a = @import("assembler.zig");
pub const pin_root = "/run/blackice-appfilter/bpf";
pub const cgroup_path = "/sys/fs/cgroup/user.slice";
const Map = struct { name: [:0]const u8, kind: bpf.MapType, key: u32, value: u32, count: u32 };
const maps = [_]Map{
    .{ .name = "state", .kind = .array, .key = 4, .value = @sizeOf(abi.State), .count = 1 },
    .{ .name = "files", .kind = .hash, .key = @sizeOf(abi.FileKey), .value = 4, .count = 4096 },
    .{ .name = "tags", .kind = .array, .key = 4, .value = 4, .count = abi.pid_slots },
    .{ .name = "ports", .kind = .array, .key = 4, .value = @sizeOf(abi.Ports), .count = abi.max_apps + 1 },
    .{ .name = "ring", .kind = .ringbuf, .key = 0, .value = 0, .count = abi.ring_bytes },
    .{ .name = "lost", .kind = .array, .key = 4, .value = 8, .count = 1 },
    .{ .name = "existing", .kind = .array, .key = 4, .value = 4, .count = 1 },
};
const trace_events = [_]programs.trace_events{ .exit, .fork, .exec };
const trace_ids = [_]u32{ pin.sched_process_exit_btf_id, pin.sched_process_fork_btf_id, pin.sched_process_exec_btf_id };
const trace_names = [_][:0]const u8{ "exit", "fork", "exec" };
const socket_names = [_][:0]const u8{ "conn4", "conn6", "send4", "send6", "create" };
const zero: u32 = 0;

pub const Loaded = struct {
    maps: programs.Fds = .{ .files = -1, .tags = -1, .ports = -1, .state = -1, .ring = -1, .lost = -1, .existing = -1 },
    traces: [3]l.fd_t = @splat(-1),
    trace_links: [3]l.fd_t = @splat(-1),
    sockets: [5]l.fd_t = @splat(-1),

    pub fn create(state: abi.State) !Loaded {
        var f: Loaded = .{};
        errdefer f.close();
        inline for (maps) |m| @field(f.maps, m.name) = try bpf.map_create(m.kind, m.key, m.value, m.count);
        try f.setState(state);
        // State is the first pin, before any persistent attachment can exist.
        inline for (maps) |m| try pinFd(@field(f.maps, m.name), m.name);
        return f;
    }
    pub fn openExisting(partial: bool) !?Loaded {
        var f: Loaded = .{};
        errdefer f.close();
        f.maps.state = (try getPin("state")) orelse return null;
        inline for (maps) |m| {
            if (!std.mem.eql(u8, m.name, "state")) @field(f.maps, m.name) = (try getPin(m.name)) orelse -1;
            const fd = @field(f.maps, m.name);
            if (fd < 0) {
                if (!partial) return error.IncompletePins;
            } else try verifyMap(fd, m);
        }
        inline for (trace_names, 0..) |name, i| {
            f.traces[i] = (try getPin("prog_" ++ name)) orelse -1;
            f.trace_links[i] = (try getPin("link_" ++ name)) orelse -1;
            if (f.traces[i] < 0 or f.trace_links[i] < 0) {
                if (!partial) return error.IncompletePins;
            } else {
                try verifyProgram(f.traces[i], &programs.tracing(trace_events[i], f.maps));
                var info: LinkInfo = undefined;
                try getInfo(f.trace_links[i], &info);
                const prog = try programInfo(f.traces[i]);
                // RAW_TRACEPOINT_OPEN uses BPF_LINK_TYPE_RAW_TRACEPOINT (1), also for tp_btf.
                if (info.kind != 1 or info.prog_id != prog.id) return error.WrongTracingLink;
            }
        }
        inline for (socket_names, 0..) |name, i| {
            f.sockets[i] = (try getPin("prog_" ++ name)) orelse -1;
            if (f.sockets[i] < 0) {
                if (!partial) return error.IncompletePins;
            } else try verifyProgram(f.sockets[i], &programs.admission(programs.hooks[i], f.maps));
        }
        return f;
    }
    pub fn getState(f: *const Loaded) !abi.State {
        var state: abi.State = undefined;
        try bpf.map_lookup_elem(f.maps.state, std.mem.asBytes(&zero), std.mem.asBytes(&state));
        // Decode the enum only after validating its raw discriminant.
        const phase = std.mem.readInt(u32, std.mem.asBytes(&state)[0..4], .little);
        if (phase < 1 or phase > @backingInt(abi.Phase.stopping) or state.version != 1 or state.app_count == 0 or state.app_count > abi.max_apps or state.owner_uid == 0) return error.InvalidPinnedState;
        return state;
    }
    pub fn setState(f: *Loaded, state: abi.State) !void {
        try bpf.map_update_elem(f.maps.state, std.mem.asBytes(&zero), std.mem.asBytes(&state), 0);
    }
    pub fn tag(f: *const Loaded, tgid: u32) !u32 {
        if (tgid == 0 or tgid >= abi.pid_slots) return error.InvalidProcess;
        var app: u32 = 0;
        try bpf.map_lookup_elem(f.maps.tags, std.mem.asBytes(&tgid), std.mem.asBytes(&app));
        return app;
    }
    pub fn addFile(f: *Loaded, key: abi.FileKey, app_id: u32) !void {
        var old: u32 = 0;
        if (bpf.map_lookup_elem(f.maps.files, std.mem.asBytes(&key), std.mem.asBytes(&old))) |_| {
            if (old != app_id) return error.DuplicateExecutableIdentity;
        } else |err| if (err != error.NotFound) return err;
        try bpf.map_update_elem(f.maps.files, std.mem.asBytes(&key), std.mem.asBytes(&app_id), 0);
    }
    pub fn setPorts(f: *Loaded, app_id: u32) !void {
        var ports = abi.ports(app_id);
        inline for (@typeInfo(abi.Ports).@"struct".field_names) |name| @field(ports, name) = std.mem.nativeToBig(u16, @field(ports, name));
        try bpf.map_update_elem(f.maps.ports, std.mem.asBytes(&app_id), std.mem.asBytes(&ports), 0);
    }
    pub fn track(f: *Loaded, verifier: []u8) !void {
        // Exit first, fork second, exec LAST. Pin each dependency before attaching the next.
        inline for (trace_events, 0..) |event, i| {
            const code = programs.tracing(event, f.maps);
            f.traces[i] = try load(&code, .tracing, .trace_raw_tp, trace_ids[i], "bi_af_" ++ trace_names[i], verifier);
            try pinFd(f.traces[i], "prog_" ++ trace_names[i]);
            var attr: bpf.Attr = .{ .raw_tracepoint = .{ .name = 0, .prog_fd = f.traces[i] } };
            f.trace_links[i] = try sys.fd(l.bpf(.raw_tracepoint_open, &attr, @sizeOf(bpf.RawTracepointAttr)));
            try pinFd(f.trace_links[i], "link_" ++ trace_names[i]);
        }
    }
    pub fn classifyExisting(f: *Loaded, verifier: []u8) !void {
        try bpf.map_update_elem(f.maps.existing, std.mem.asBytes(&zero), std.mem.asBytes(&zero), 0);
        const code = programs.tracing(.iterator, f.maps);
        const prog = try load(&code, .tracing, .trace_iter, pin.iter_task_btf_id, "bi_af_iter", verifier);
        defer sys.close(prog);
        var link_attr: bpf.Attr = .{ .link_create = std.mem.zeroes(bpf.LinkCreateAttr) };
        link_attr.link_create.prog_fd = prog;
        link_attr.link_create.attach_type = @backingInt(bpf.AttachType.trace_iter);
        const link = try sys.fd(l.bpf(.link_create, &link_attr, @sizeOf(bpf.LinkCreateAttr)));
        defer sys.close(link);
        var iter_attr: bpf.Attr = .{ .iter_create = .{ .link_fd = link, .flags = 0 } };
        const iter = try sys.fd(l.bpf(.iter_create, &iter_attr, @sizeOf(bpf.IterCreateAttr)));
        defer sys.close(iter);
        var buf: [256]u8 = undefined;
        while (try sys.read(iter, &buf) != 0) {}
        var app: u32 = 0;
        try bpf.map_lookup_elem(f.maps.existing, std.mem.asBytes(&zero), std.mem.asBytes(&app));
        if (app != 0) return error.CloseListedAppsFirst;
    }
    pub fn attach(f: *Loaded, cgroup: l.fd_t, verifier: []u8) !void {
        // Without CAP_SYS_ADMIN an unknown ID cannot be opened to check its name. Refuse conservatively.
        try requireVacant(cgroup);
        inline for (programs.hooks, 0..) |hook, i| {
            const code = programs.admission(hook, f.maps);
            f.sockets[i] = try load(&code, if (i == 4) .cgroup_sock else .cgroup_sock_addr, hook, 0, "bi_af_" ++ socket_names[i], verifier);
            try pinFd(f.sockets[i], "prog_" ++ socket_names[i]);
            var attr: bpf.Attr = .{ .prog_attach = std.mem.zeroes(bpf.ProgAttachAttr) };
            attr.prog_attach.target_fd = cgroup;
            attr.prog_attach.attach_bpf_fd = f.sockets[i];
            attr.prog_attach.attach_type = @backingInt(hook);
            attr.prog_attach.attach_flags = 2;
            _ = try sys.check(l.bpf(.prog_attach, &attr, @sizeOf(bpf.ProgAttachAttr)));
            if (!try attached(cgroup, hook, (try programInfo(f.sockets[i])).id)) return error.AttachmentNotVerified;
        }
    }
    pub fn verifyAttachments(f: *const Loaded, cgroup: l.fd_t) !void {
        for (f.sockets, programs.hooks) |fd, hook| if (fd < 0 or !try attached(cgroup, hook, (try programInfo(fd)).id)) return error.AttachmentNotVerified;
    }
    pub fn detach(f: *Loaded, cgroup: l.fd_t) !void {
        for (f.sockets, programs.hooks) |fd, hook| {
            if (fd < 0 or !try attached(cgroup, hook, (try programInfo(fd)).id)) continue;
            var attr: bpf.Attr = .{ .prog_attach = std.mem.zeroes(bpf.ProgAttachAttr) };
            attr.prog_attach.target_fd = cgroup;
            attr.prog_attach.attach_bpf_fd = fd;
            attr.prog_attach.attach_type = @backingInt(hook);
            _ = try sys.check(l.bpf(.prog_detach, &attr, @sizeOf(bpf.ProgAttachAttr)));
            if (try attached(cgroup, hook, (try programInfo(fd)).id)) return error.DetachmentNotVerified;
        }
    }
    pub fn loss(f: *const Loaded) !u64 {
        var n: u64 = 0;
        try bpf.map_lookup_elem(f.maps.lost, std.mem.asBytes(&zero), std.mem.asBytes(&n));
        return n;
    }
    /// Closing process FDs never detaches or unpins. Armed classification and denial survive death.
    pub fn close(f: *Loaded) void {
        for (f.trace_links) |fd| if (fd >= 0) sys.close(fd);
        for (f.traces) |fd| if (fd >= 0) sys.close(fd);
        for (f.sockets) |fd| if (fd >= 0) sys.close(fd);
        inline for (@typeInfo(programs.Fds).@"struct".field_names) |name| {
            const fd = @field(f.maps, name);
            if (fd >= 0) sys.close(fd);
        }
        f.* = .{};
    }
};

fn load(code: *const a.Program, kind: bpf.ProgType, attach_type: bpf.AttachType, btf_id: u32, name: []const u8, verifier: []u8) !l.fd_t {
    try a.validate(code);
    @memset(verifier, 0);
    var attr: bpf.Attr = .{ .prog_load = std.mem.zeroes(bpf.ProgLoadAttr) };
    attr.prog_load.prog_type = @backingInt(kind);
    attr.prog_load.expected_attach_type = @backingInt(attach_type);
    attr.prog_load.attact_btf_id = btf_id;
    attr.prog_load.insns = @intFromPtr(&code.code);
    attr.prog_load.insn_cnt = @intCast(code.len);
    attr.prog_load.license = @intFromPtr("Dual BSD/GPL");
    attr.prog_load.log_level = 1;
    attr.prog_load.log_size = @intCast(verifier.len);
    attr.prog_load.log_buf = @intFromPtr(verifier.ptr);
    if (name.len >= attr.prog_load.prog_name.len) return error.ProgramNameTooLong;
    @memcpy(attr.prog_load.prog_name[0..name.len], name);
    const fd = try sys.fd(l.bpf(.prog_load, &attr, @sizeOf(bpf.ProgLoadAttr)));
    errdefer sys.close(fd);
    try verifyProgram(fd, code);
    return fd;
}
const ProgInfo = extern struct { kind: u32, id: u32, tag: [8]u8, jited_len: u32, xlated_len: u32, jited_insns: u64, xlated_insns: u64, load_time: u64, uid: u32, map_count: u32, map_ids: u64, name: [16]u8 };
const LinkInfo = extern struct { kind: u32, id: u32, prog_id: u32, padding: u32, details: [32]u8 };
const MapInfo = extern struct { kind: u32, id: u32, key: u32, value: u32, count: u32, flags: u32 };
fn getInfo(fd: l.fd_t, value: anytype) !void {
    @memset(std.mem.asBytes(value), 0);
    var attr: bpf.Attr = .{ .info = .{ .bpf_fd = fd, .info_len = @intCast(@sizeOf(@TypeOf(value.*))), .info = @intFromPtr(value) } };
    _ = try sys.check(l.bpf(.obj_get_info_by_fd, &attr, @sizeOf(bpf.InfoAttr)));
}
fn programInfo(fd: l.fd_t) !ProgInfo {
    var info: ProgInfo = undefined;
    try getInfo(fd, &info);
    return info;
}
fn verifyProgram(fd: l.fd_t, code: *const a.Program) !void {
    var ids: [16]u32 = @splat(0);
    var info: ProgInfo = std.mem.zeroes(ProgInfo);
    info.map_count = ids.len;
    info.map_ids = @intFromPtr(&ids);
    var attr: bpf.Attr = .{ .info = .{ .bpf_fd = fd, .info_len = @sizeOf(ProgInfo), .info = @intFromPtr(&info) } };
    _ = try sys.check(l.bpf(.obj_get_info_by_fd, &attr, @sizeOf(bpf.InfoAttr)));
    if (!std.mem.eql(u8, &info.tag, &programTag(code))) return error.ProgramTagMismatch;
    if (info.map_count > ids.len) return error.ProgramMapMismatch;
    var expected: [16]u32 = @splat(0);
    var count: usize = 0;
    for (code.code[0..code.len]) |insn| {
        if (insn.code != 0x18 or insn.src != 1) continue;
        var map: MapInfo = undefined;
        try getInfo(insn.imm, &map);
        if (std.mem.findScalar(u32, expected[0..count], map.id) == null) {
            if (count == expected.len) return error.ProgramMapMismatch;
            expected[count] = map.id;
            count += 1;
        }
    }
    if (count != info.map_count) return error.ProgramMapMismatch;
    for (ids[0..info.map_count]) |id| if (std.mem.findScalar(u32, expected[0..count], id) == null) return error.ProgramMapMismatch;
}
fn verifyMap(fd: l.fd_t, want: Map) !void {
    var got: MapInfo = undefined;
    try getInfo(fd, &got);
    if (got.kind != @backingInt(want.kind) or got.key != want.key or got.value != want.value or got.count != want.count or got.flags != 0) return error.MapLayoutMismatch;
}
pub fn programTag(code: *const a.Program) [8]u8 {
    var copy = code.*;
    var pc: usize = 0;
    while (pc < copy.len) : (pc += 1) {
        if (copy.code[pc].code == 0x18 and copy.code[pc].src == 1) {
            copy.code[pc].imm = 0;
            copy.code[pc + 1].imm = 0;
            pc += 1;
        }
    }
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(std.mem.sliceAsBytes(copy.code[0..copy.len]), &digest, .{});
    return digest[0..8].*;
}
fn pinPath(name: []const u8, buf: *[160]u8) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, pin_root ++ "/{s}", .{name}, 0);
}
fn pinFd(fd: l.fd_t, name: []const u8) !void {
    var path: [160]u8 = undefined;
    var attr: bpf.Attr = .{ .obj = std.mem.zeroes(bpf.ObjAttr) };
    attr.obj.pathname = @intFromPtr((try pinPath(name, &path)).ptr);
    attr.obj.bpf_fd = fd;
    _ = try sys.check(l.bpf(.obj_pin, &attr, @sizeOf(bpf.ObjAttr)));
}
fn getPin(name: []const u8) !?l.fd_t {
    var path: [160]u8 = undefined;
    var attr: bpf.Attr = .{ .obj = std.mem.zeroes(bpf.ObjAttr) };
    attr.obj.pathname = @intFromPtr((try pinPath(name, &path)).ptr);
    const rc = l.bpf(.obj_get, &attr, @sizeOf(bpf.ObjAttr));
    if (l.errno(rc) == .NOENT) return null;
    return try sys.fd(rc);
}
pub fn unpinAll() !void {
    inline for (trace_names) |name| {
        try unpin("link_" ++ name);
        try unpin("prog_" ++ name);
    }
    inline for (socket_names) |name| try unpin("prog_" ++ name);
    // State last: an interrupted teardown can always be resumed.
    inline for (maps[1..]) |m| try unpin(m.name);
    try unpin("state");
}
fn unpin(name: []const u8) !void {
    var path: [160]u8 = undefined;
    const rc = l.unlink((try pinPath(name, &path)).ptr);
    if (l.errno(rc) != .NOENT) _ = try sys.check(rc);
}
fn query(cgroup: l.fd_t, hook: bpf.AttachType, ids: *[128]u32) ![]const u32 {
    var attr: bpf.Attr = .{ .query = std.mem.zeroes(bpf.QueryAttr) };
    attr.query.target_fd = cgroup;
    attr.query.attach_type = @backingInt(hook);
    attr.query.prog_ids = @intFromPtr(ids);
    attr.query.prog_cnt = ids.len;
    _ = try sys.check(l.bpf(.prog_query, &attr, @sizeOf(bpf.QueryAttr)));
    if (attr.query.prog_cnt > ids.len) return error.TooManyAttachedPrograms;
    return ids[0..attr.query.prog_cnt];
}
fn attached(cgroup: l.fd_t, hook: bpf.AttachType, id: u32) !bool {
    var ids: [128]u32 = undefined;
    for (try query(cgroup, hook, &ids)) |got| if (got == id) return true;
    return false;
}
pub fn requireVacant(cgroup: l.fd_t) !void {
    var ids: [128]u32 = undefined;
    for (programs.hooks) |hook| if ((try query(cgroup, hook, &ids)).len != 0) return error.AttachPointOccupiedNeedsOwnerReview;
}
fn requireSingleThread() !void {
    const fd = try sys.fd(l.open("/proc/self/task", .{ .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0));
    defer sys.close(fd);
    var buf: [4096]u8 align(8) = undefined;
    var count: usize = 0;
    while (true) {
        const n = try sys.check(l.getdents64(fd, &buf, buf.len));
        if (n == 0) break;
        var pos: usize = 0;
        while (pos < n) {
            if (n - pos < 20) return error.InvalidTaskDirectory;
            const size = std.mem.readInt(u16, buf[pos + 16 ..][0..2], .little);
            if (size < 20 or size > n - pos) return error.InvalidTaskDirectory;
            const bytes = buf[pos + 19 .. pos + size];
            const end = std.mem.findScalar(u8, bytes, 0) orelse return error.InvalidTaskDirectory;
            const name = bytes[0..end];
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                if ((std.fmt.parseInt(u32, name, 10) catch 0) != l.getpid()) return error.PrivilegedWorkerThread;
                count += 1;
            }
            pos += size;
        }
    }
    if (count != 1) return error.PrivilegedWorkerThread;
}
pub fn dropLoadCapabilities() !void {
    try requireSingleThread();
    try sys.noNewPrivileges();
    _ = try sys.check(l.prctl(47, 4, 0, 0, 0)); // PR_CAP_AMBIENT_CLEAR_ALL
    var hdr: sys.CapHeader = .{};
    const keep: u32 = (1 << 10) | (1 << 12); // bind reserved ports, detach this filter
    const caps = [_]sys.Caps{ .{ .effective = keep, .permitted = keep }, .{} };
    _ = try sys.check(l.syscall2(.capset, @intFromPtr(&hdr), @intFromPtr(&caps)));
    const actual = try sys.capabilities();
    if (actual[0].effective != keep or actual[0].permitted != keep or actual[0].inheritable != 0 or actual[1].effective != 0 or actual[1].permitted != 0 or actual[1].inheritable != 0) return error.CapabilityDropNotVerified;
    // No CAP_SETPCAP is added just to alter the bounding set. Cleared permitted/inheritable/ambient
    // plus NNP prevent regaining BPF/PERFMON at exec; the unit bounds what could ever be acquired.
}
test "appfilter program tags ignore FD numbers but detect instruction changes" {
    const one = programs.admission(.cgroup_inet4_connect, programs.fixture_fds);
    var fds = programs.fixture_fds;
    fds.tags += 100;
    var two = programs.admission(.cgroup_inet4_connect, fds);
    try std.testing.expectEqualSlices(u8, &programTag(&one), &programTag(&two));
    two.code[two.len - 2].imm = 0;
    try std.testing.expect(!std.mem.eql(u8, &programTag(&one), &programTag(&two)));
}
