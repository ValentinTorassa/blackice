//! cgroup sock_addr admission: explicit hooks for TCP/connected UDP and unconnected UDP, both families.
//! Programs stay attached until the empty cgroup is removed, including if the helper crashes.
const std = @import("std");
const sys = @import("sys.zig");
const l = sys.l;
const bpf = l.BPF;
const I = bpf.Insn;
const protocol = @import("protocol.zig");

pub const hooks = [_]bpf.AttachType{ .cgroup_inet4_connect, .cgroup_inet6_connect, .cgroup_udp4_sendmsg, .cgroup_udp6_sendmsg };
pub const ring_size = 65536;
pub const Drop = extern struct {
    family: u32,
    protocol: u32,
    port: u32, // __be16 in the low half of the u32, as in struct bpf_sock_addr.
    hook: u32,
    pid_tgid: u64,
    ip: [16]u8,
};
pub const Program = struct {
    code: [256]I = undefined,
    len: usize = 0,
    fn add(p: *Program, i: I) usize {
        const n = p.len;
        p.code[n] = i;
        p.len += 1;
        return n;
    }
    fn patch(p: *Program, at: usize, target: usize) void {
        p.code[at].off = @intCast(target - at - 1);
    }
    fn map(p: *Program, reg: I.Reg, fd: l.fd_t) void {
        _ = p.add(I.ld_map_fd1(reg, fd));
        _ = p.add(I.ld_map_fd2(fd));
    }
};

pub fn generate(hook: bpf.AttachType, ports: []const u16, ring_fd: l.fd_t, lost_fd: l.fd_t) Program {
    std.debug.assert(ports.len <= protocol.max_ports);
    var p: Program = .{};
    _ = p.add(I.mov(.r6, .r1)); // preserve context across helper calls
    var refuses: [5]usize = undefined;
    var refuses_len: usize = 0;
    var permits: [protocol.max_ports]usize = undefined;
    var permits_len: usize = 0;
    if (hook == .cgroup_inet4_connect and ports.len > 0) {
        const checks = [_]struct { off: i16, value: i32 }{
            .{ .off = 0, .value = l.AF.INET },
            .{ .off = 28, .value = l.AF.INET },
            .{ .off = 32, .value = l.SOCK.STREAM },
            .{ .off = 36, .value = 6 }, // IPPROTO_TCP (not MPTCP or UDP)
            .{ .off = 4, .value = @bitCast(std.mem.nativeToBig(u32, 0x7f000001)) },
        };
        for (checks) |c| {
            _ = p.add(I.ldx(.word, .r0, .r6, c.off));
            refuses[refuses_len] = p.add(I.jne(.r0, c.value, 0));
            refuses_len += 1;
        }
        _ = p.add(I.ldx(.word, .r0, .r6, 24));
        for (ports) |port| {
            permits[permits_len] = p.add(I.jeq(.r0, std.mem.nativeToBig(u16, port), 0));
            permits_len += 1;
        }
    }
    const deny_label = p.len;
    // Ring-buffer reservation failure must take exactly the same deny verdict.
    p.map(.r1, ring_fd);
    _ = p.add(I.mov(.r2, @sizeOf(Drop)));
    _ = p.add(I.mov(.r3, 0));
    _ = p.add(I.call(.ringbuf_reserve));
    const no_space = p.add(I.jeq(.r0, 0, 0));
    _ = p.add(I.mov(.r7, .r0));
    for ([_]struct { src: i16, dst: i16 }{ .{ .src = 0, .dst = 0 }, .{ .src = 36, .dst = 4 }, .{ .src = 24, .dst = 8 } }) |f| {
        _ = p.add(I.ldx(.word, .r1, .r6, f.src));
        _ = p.add(I.stx(.word, .r7, f.dst, .r1));
    }
    _ = p.add(I.st(.word, .r7, 12, @intCast(@backingInt(hook))));
    _ = p.add(I.call(.get_current_pid_tgid));
    _ = p.add(I.stx(.double_word, .r7, 16, .r0));
    const v6 = hook == .cgroup_inet6_connect or hook == .cgroup_udp6_sendmsg;
    for (0..4) |i| {
        const dst: i16 = @intCast(24 + 4 * i);
        if (v6 or i == 0) {
            _ = p.add(I.ldx(.word, .r1, .r6, @intCast(if (v6) 8 + 4 * i else 4)));
            _ = p.add(I.stx(.word, .r7, dst, .r1));
        } else _ = p.add(I.st(.word, .r7, dst, 0));
    }
    _ = p.add(I.mov(.r1, .r7));
    _ = p.add(I.mov(.r2, 0));
    _ = p.add(I.call(.ringbuf_submit));
    _ = p.add(I.mov(.r0, 0));
    _ = p.add(I.exit());
    const lost_label = p.len;
    _ = p.add(I.st(.word, .r10, -4, 0)); // array key
    p.map(.r1, lost_fd);
    _ = p.add(I.mov(.r2, .r10));
    _ = p.add(I.add(.r2, -4));
    _ = p.add(I.call(.map_lookup_elem));
    _ = p.add(I.jeq(.r0, 0, 2));
    _ = p.add(I.mov(.r1, 1));
    _ = p.add(I.xadd(.r0, .r1));
    _ = p.add(I.mov(.r0, 0));
    _ = p.add(I.exit());
    const allow_label = p.len;
    // The verifier rejects unreachable instructions, even an unused return block.
    if (permits_len > 0) {
        _ = p.add(I.mov(.r0, 1));
        _ = p.add(I.exit());
    }
    for (refuses[0..refuses_len]) |at| p.patch(at, deny_label);
    for (permits[0..permits_len]) |at| p.patch(at, allow_label);
    p.patch(no_space, lost_label);
    return p;
}

pub const Filter = struct {
    ring_fd: l.fd_t,
    lost_fd: l.fd_t,
    programs: [4]l.fd_t = @splat(-1),
    attached: usize = 0,

    pub fn create() !Filter {
        const ring = try bpf.map_create(.ringbuf, 0, 0, ring_size);
        errdefer sys.close(ring);
        return .{ .ring_fd = ring, .lost_fd = try bpf.map_create(.array, 4, 8, 1) };
    }
    pub fn arm(f: *Filter, cgroup: l.fd_t, ports: []const u16, verifier: []u8) !void {
        for (hooks, 0..) |hook, i| {
            const p = generate(hook, ports, f.ring_fd, f.lost_fd);
            var attr: bpf.Attr = .{ .prog_load = std.mem.zeroes(bpf.ProgLoadAttr) };
            attr.prog_load.prog_type = @backingInt(bpf.ProgType.cgroup_sock_addr);
            attr.prog_load.expected_attach_type = @backingInt(hook);
            attr.prog_load.insns = @intFromPtr(&p.code);
            attr.prog_load.insn_cnt = @intCast(p.len);
            attr.prog_load.license = @intFromPtr("Apache-2.0");
            attr.prog_load.log_level = 1;
            attr.prog_load.log_size = @intCast(verifier.len);
            attr.prog_load.log_buf = @intFromPtr(verifier.ptr);
            f.programs[i] = try sys.fd(l.bpf(.prog_load, &attr, @sizeOf(bpf.ProgLoadAttr)));
            var attach: bpf.Attr = .{ .prog_attach = std.mem.zeroes(bpf.ProgAttachAttr) };
            attach.prog_attach.target_fd = cgroup;
            attach.prog_attach.attach_bpf_fd = f.programs[i];
            attach.prog_attach.attach_type = @backingInt(hook);
            // Neither ALLOW_OVERRIDE nor ALLOW_MULTI: descendants cannot replace this policy.
            _ = try sys.check(l.bpf(.prog_attach, &attach, @sizeOf(bpf.ProgAttachAttr)));
            f.attached += 1;
            // A successful load is not an enrollment acknowledgement: query the actual attachment.
            var ids: [8]u32 = @splat(0);
            var query: bpf.Attr = .{ .query = std.mem.zeroes(bpf.QueryAttr) };
            query.query.target_fd = cgroup;
            query.query.attach_type = @backingInt(hook);
            query.query.prog_ids = @intFromPtr(&ids);
            query.query.prog_cnt = ids.len;
            _ = try sys.check(l.bpf(.prog_query, &query, @sizeOf(bpf.QueryAttr)));
            if (query.query.prog_cnt != 1 or ids[0] == 0 or query.query.attach_flags != 0) return error.AttachmentNotVerified;
        }
    }
    pub fn loss(f: *const Filter) !u64 {
        const key: u32 = 0;
        var count: u64 = 0;
        try bpf.map_lookup_elem(f.lost_fd, std.mem.asBytes(&key), std.mem.asBytes(&count));
        return count;
    }
    /// Closing descriptors deliberately does NOT detach. Delete only an empty cgroup.
    pub fn close(f: *Filter) void {
        for (f.programs) |p| if (p >= 0) sys.close(p);
        sys.close(f.ring_fd);
        sys.close(f.lost_fd);
    }
};

pub const Ring = struct {
    consumer_map: []align(4096) u8,
    producer_map: []align(4096) u8,
    page: usize,

    pub fn open(fd: l.fd_t) !Ring {
        const page = std.heap.pageSize();
        const a = try sys.check(l.mmap(null, page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0));
        errdefer _ = l.munmap(@ptrFromInt(a), page);
        const b = try sys.check(l.mmap(null, page + 2 * ring_size, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, @intCast(page)));
        return .{ .consumer_map = @as([*]align(4096) u8, @ptrFromInt(a))[0..page], .producer_map = @as([*]align(4096) u8, @ptrFromInt(b))[0 .. page + 2 * ring_size], .page = page };
    }
    pub fn close(r: *Ring) void {
        _ = l.munmap(r.consumer_map.ptr, r.consumer_map.len);
        _ = l.munmap(r.producer_map.ptr, r.producer_map.len);
    }
    pub fn next(r: *Ring) !?Drop {
        const consumer: *u64 = @ptrCast(r.consumer_map.ptr);
        const producer: *const u64 = @ptrCast(r.producer_map.ptr);
        var pos = @atomicLoad(u64, consumer, .acquire);
        const end = @atomicLoad(u64, producer, .acquire);
        if (end -% pos > ring_size) return error.InvalidRing;
        while (pos != end) {
            const start: usize = r.page + @as(usize, @intCast(pos & (ring_size - 1)));
            const header: *const u32 = @ptrCast(@alignCast(r.producer_map.ptr + start));
            const len_flags = @atomicLoad(u32, header, .acquire);
            if (len_flags & (1 << 31) != 0) return null; // producer still writing
            const len = len_flags & 0x3fffffff;
            if (len != @sizeOf(Drop)) return error.InvalidRing;
            pos +%= std.mem.alignForward(u64, len + 8, 8);
            if (len_flags & (1 << 30) != 0) {
                @atomicStore(u64, consumer, pos, .release);
                continue;
            }
            var result: Drop = undefined;
            @memcpy(std.mem.asBytes(&result), r.producer_map[start + 8 ..][0..@sizeOf(Drop)]);
            @atomicStore(u64, consumer, pos, .release);
            return result;
        }
        return null;
    }
};

test "all generated BPF branches stay in bounds; only IPv4 TCP has an allow branch" {
    for (hooks) |hook| {
        const p = generate(hook, &.{ 18780, 18781 }, 10, 11);
        var allow_jumps: usize = 0;
        for (p.code[0..p.len], 0..) |i, pc| {
            if (i.code & 7 != bpf.JMP or i.code == 0x85 or i.code == 0x95) continue;
            const target: i64 = @as(i64, @intCast(pc)) + 1 + i.off;
            try std.testing.expect(target >= 0 and target < p.len);
            if (std.meta.eql(p.code[@intCast(target)], I.mov(.r0, 1))) allow_jumps += 1;
        }
        try std.testing.expectEqual(@as(usize, if (hook == .cgroup_inet4_connect) 2 else 0), allow_jumps);
    }
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Drop));
}

test "generated BPF has no unreachable instructions for any hook or port count" {
    const ports = [_]u16{ 18780, 18781, 18782, 18783, 18784, 18785, 18786, 18787 };
    for (hooks) |hook| {
        for (0..protocol.max_ports + 1) |count| {
            const p = generate(hook, ports[0..count], 10, 11);
            var seen: [256]bool = @splat(false);
            var pending: [512]usize = undefined;
            pending[0] = 0;
            var len: usize = 1;
            while (len > 0) {
                len -= 1;
                const pc = pending[len];
                try std.testing.expect(pc < p.len);
                if (seen[pc]) continue;
                seen[pc] = true;
                const insn = p.code[pc];
                // LD_IMM64's second slot is data, not a separately executable instruction.
                try std.testing.expect(insn.code != 0);
                if (insn.code == 0x95) continue; // EXIT
                var next = pc + 1;
                if (insn.code == bpf.LD | bpf.DW | bpf.IMM) {
                    try std.testing.expect(next < p.len);
                    try std.testing.expectEqual(@as(u8, 0), p.code[next].code);
                    seen[next] = true;
                    next += 1;
                } else if (insn.code & 7 == bpf.JMP and insn.code != 0x85) {
                    const target: i64 = @as(i64, @intCast(pc)) + 1 + insn.off;
                    try std.testing.expect(target >= 0 and target < p.len);
                    pending[len] = @intCast(target);
                    len += 1;
                    if (insn.code == 0x05) continue; // unconditional jump
                }
                pending[len] = next;
                len += 1;
            }
            for (seen[0..p.len], 0..) |reachable, pc| {
                if (!reachable) std.debug.print("unreachable BPF instruction {d}, hook {s}, {d} ports\n", .{ pc, @tagName(hook), count });
                try std.testing.expect(reachable);
            }
        }
    }
}
