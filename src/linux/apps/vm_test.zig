//! Test-only interpreter for the actual emitted instructions. Never invokes bpf().
const std = @import("std");
const programs = @import("programs.zig");
const a = @import("assembler.zig");
const abi = @import("types.zig");
const pin = @import("kernel_pin.zig");
const fd = programs.fixture_fds;
const ctx = 512;
const parent = 2048;
const child = 8192;
const signal = 16384;
const cred = 18000;
const mm = 20000;
const file = 22000;
const inode = 24000;
const sb = 26000;
const bprm = 28000;
const tags_base = 32768;
const ports_base = 34000;
const file_app = 35000;
const state_value = 35100;
const existing = 35200;
const lost = 35300;
const event = 60000;
const Vm = struct {
    mem: [65536]u8 = @splat(0),
    regs: [11]u64 = @splat(0),
    tag_keys: [16]u32 = @splat(0),
    file_key: abi.FileKey = .{ .device = 259 << 20 | 2, .generation = 0x8abc1234, .inode = 123456 },
    tgid: u32 = 100,
    ring_full: bool = false,
    events: u32 = 0,

    fn init() Vm {
        var v: Vm = .{};
        v.put(parent + pin.task_struct_tgid, 100, 4);
        v.put(child + pin.task_struct_tgid, 200, 4);
        v.put(parent + pin.task_struct_signal, signal, 8);
        v.put(parent + pin.task_struct_real_cred, cred, 8);
        v.put(cred + pin.cred_uid + pin.kuid_t_val, 1000, 4);
        v.put(state_value + @offsetOf(abi.State, "owner_uid"), 1000, 4);
        v.put(parent + pin.task_struct_mm, mm, 8);
        v.put(mm + pin.mm_struct_exe_file, file, 8);
        v.put(bprm + pin.linux_binprm_file, file, 8);
        v.put(file + pin.file_f_inode, inode, 8);
        v.put(inode + pin.inode_i_ino, v.file_key.inode, 8);
        v.put(inode + pin.inode_i_sb, sb, 8);
        v.put(inode + pin.inode_i_generation, v.file_key.generation, 4);
        v.put(sb + pin.super_block_s_dev, v.file_key.device, 4);
        for (1..abi.max_apps + 1) |i| {
            const ports = abi.ports(@intCast(i));
            inline for (@typeInfo(abi.Ports).@"struct".field_names) |f| v.put(ports_base + i * 8 + @offsetOf(abi.Ports, f), std.mem.nativeToBig(u16, @field(ports, f)), 2);
        }
        return v;
    }
    fn get(v: *const Vm, at: u64, n: usize) u64 {
        std.debug.assert(at + n <= v.mem.len);
        var value: u64 = 0;
        for (0..n) |i| value |= @as(u64, v.mem[@intCast(at + i)]) << @as(u6, @intCast(i * 8));
        return value;
    }
    fn put(v: *Vm, at: u64, value: u64, n: usize) void {
        std.debug.assert(at + n <= v.mem.len);
        for (0..n) |i| v.mem[@intCast(at + i)] = @truncate(value >> @as(u6, @intCast(i * 8)));
    }
    fn slot(v: *Vm, pid: u32) u64 {
        if (pid >= abi.pid_slots) return 0;
        for (&v.tag_keys, 0..) |*key, i| {
            if (key.* == pid or key.* == 0) {
                key.* = pid;
                return tags_base + i * 4;
            }
        }
        unreachable;
    }
    fn setTag(v: *Vm, pid: u32, app: u32) void {
        v.put(v.slot(pid), app, 4);
    }
    fn tag(v: *Vm, pid: u32) u32 {
        return @intCast(v.get(v.slot(pid), 4));
    }
    fn run(v: *Vm, code: *const a.Program) !u64 {
        try a.validate(code);
        v.regs = @splat(0);
        v.regs[1] = ctx;
        v.regs[10] = 64000;
        var pc: usize = 0;
        var steps: usize = 0;
        while (pc < code.len and steps < 4096) : ({
            pc += 1;
            steps += 1;
        }) {
            const i = code.code[pc];
            const imm: u64 = @bitCast(@as(i64, i.imm));
            const src: u64 = if (i.code & 8 != 0) v.regs[i.src] else imm;
            const dst = &v.regs[i.dst];
            switch (i.code) {
                0x18 => {
                    dst.* = @as(u32, @bitCast(i.imm)) | (@as(u64, @as(u32, @bitCast(code.code[pc + 1].imm))) << 32);
                    pc += 1;
                },
                0x95 => return v.regs[0],
                0x85 => {
                    const value: u64 = switch (@as(a.bpf.Helper, @fromBackingInt(@intCast(i.imm)))) {
                        .get_current_pid_tgid => @as(u64, v.tgid) << 32 | v.tgid,
                        .ktime_get_ns => 123456789,
                        .map_lookup_elem => blk: {
                            const map = v.regs[1];
                            const k: u32 = @intCast(v.get(v.regs[2], 4));
                            if (map == fd.tags) break :blk v.slot(k);
                            if (map == fd.ports) break :blk if (k > 0 and k <= abi.max_apps) ports_base + k * 8 else 0;
                            if (map == fd.state) break :blk state_value;
                            if (map == fd.existing) break :blk existing;
                            if (map == fd.lost) break :blk lost;
                            if (map == fd.files) break :blk if (k == v.file_key.device and
                                v.get(v.regs[2] + @offsetOf(abi.FileKey, "generation"), 4) == v.file_key.generation and
                                v.get(v.regs[2] + @offsetOf(abi.FileKey, "inode"), 8) == v.file_key.inode and
                                v.get(file_app, 4) != 0) @as(u64, file_app) else 0;
                            return error.UnknownMap;
                        },
                        .ringbuf_reserve => if (v.ring_full) @as(u64, 0) else event,
                        .ringbuf_submit => blk: {
                            v.events += 1;
                            break :blk @as(u64, 0);
                        },
                        else => return error.UnknownHelper,
                    };
                    for (1..6) |r| v.regs[r] = 0xdeadbeefdeadbeef;
                    v.regs[0] = value;
                },
                else => switch (i.code & 7) {
                    7 => dst.* = switch (i.code & 0xf0) {
                        0xb0 => src,
                        0x00 => dst.* +% src,
                        0x10 => dst.* -% src,
                        0x50 => dst.* & src,
                        0x60 => dst.* << @as(u6, @truncate(src)),
                        0x70 => dst.* >> @as(u6, @truncate(src)),
                        else => return error.UnknownAlu,
                    },
                    1 => dst.* = v.get(v.regs[i.src] +% @as(u64, @bitCast(@as(i64, i.off))), size(i.code)),
                    2, 3 => {
                        const at = dst.* +% @as(u64, @bitCast(@as(i64, i.off)));
                        const value = if (i.code & 7 == 2) imm else v.regs[i.src];
                        v.put(at, if (i.code & 0xe0 == 0xc0) v.get(at, size(i.code)) +% value else value, size(i.code));
                    },
                    5, 6 => {
                        const left: u64 = if (i.code & 7 == 6) @as(u32, @truncate(dst.*)) else dst.*;
                        const right: u64 = if (i.code & 7 == 6) @as(u32, @truncate(src)) else src;
                        const jump = switch (i.code & 0xf0) {
                            0x00 => true,
                            0x10 => left == right,
                            0x50 => left != right,
                            else => return error.UnknownJump,
                        };
                        if (jump) pc += @as(usize, @intCast(i.off));
                    },
                    else => return error.UnknownInstruction,
                },
            }
        }
        return error.NoReturn;
    }
    fn socket(v: *Vm, v6: bool, port: u16, protocol: u32) void {
        @memset(v.mem[ctx .. ctx + 64], 0);
        v.put(ctx, if (v6) 10 else 2, 4);
        v.put(ctx + 24, std.mem.nativeToBig(u16, port), 4);
        v.put(ctx + 36, protocol, 4);
        v.put(ctx + 4, std.mem.nativeToBig(u32, 0x01010101), 4);
        v.put(ctx + 8, 0x2001, 4);
    }
    fn addr4(v: *Vm, ip: u32) void {
        v.put(ctx + 4, std.mem.nativeToBig(u32, ip), 4);
    }
    fn mapped(v: *Vm, ip: u32) void {
        v.put(ctx + 8, 0, 8);
        v.put(ctx + 16, std.mem.nativeToBig(u32, 65535), 4);
        v.put(ctx + 20, std.mem.nativeToBig(u32, ip), 4);
    }
};
fn size(code: u8) usize {
    return switch (code & 0x18) {
        0 => 4,
        8 => 2,
        16 => 1,
        24 => 8,
        else => unreachable,
    };
}

test "appfilter emitted programs refuse SCTP ping raw and bad protocol/type combinations" {
    const code = programs.admission(.cgroup_inet_sock_create, fd);
    for ([_]u32{ 0, 1, 6, 17, 58, 132, 136, 262 }) |protocol| for ([_]u32{ 1, 2, 3 }) |kind| {
        var v = Vm.init();
        v.setTag(100, 2);
        v.put(ctx + 4, 2, 4);
        v.put(ctx + 8, kind, 4);
        v.put(ctx + 12, protocol, 4);
        const allowed = (protocol == 6 and kind == 1) or (protocol == 17 and kind == 2);
        try std.testing.expectEqual(@as(u64, @intFromBool(allowed)), try v.run(&code));
        try std.testing.expectEqual(@as(u32, @intFromBool(!allowed)), v.events);
        try std.testing.expectEqual(@as(u64, 1), v.get(ctx, 4)); // tagged sockets are bound to lo
        v.setTag(100, 0);
        v.put(ctx, 0, 4);
        try std.testing.expectEqual(@as(u64, 1), try v.run(&code));
        try std.testing.expectEqual(@as(u64, 0), v.get(ctx, 4));
    };
}
test "appfilter emitted TCP redirects both families and mapped IPv6; unlisted stays unchanged" {
    for (programs.hooks[0..2], 0..) |hook, family| for ([_]u16{ 22, 53, 80, 443, 8080 }) |port| {
        var v = Vm.init();
        v.setTag(100, 2);
        v.socket(family == 1, port, 6);
        const code = programs.admission(hook, fd);
        const allow = port == 80 or port == 443;
        try std.testing.expectEqual(@as(u64, @intFromBool(allow)), try v.run(&code));
        if (allow) try std.testing.expectEqual(@as(u64, std.mem.nativeToBig(u16, if (port == 443) 762 else 763)), v.get(ctx + 24, 4));
        if (family == 1 and allow) {
            try std.testing.expectEqual(@as(u64, std.mem.nativeToBig(u32, 1)), v.get(ctx + 20, 4));
            v.socket(true, port, 6);
            v.mapped(0x01010101);
            try std.testing.expectEqual(@as(u64, 1), try v.run(&code));
            try std.testing.expectEqual(@as(u64, std.mem.nativeToBig(u32, 0x7f000001)), v.get(ctx + 20, 4));
        }
        v.setTag(100, 0);
        v.socket(family == 1, port, 6);
        const before = v.mem[ctx .. ctx + 64].*;
        try std.testing.expectEqual(@as(u64, 1), try v.run(&code));
        try std.testing.expectEqualSlices(u8, &before, v.mem[ctx .. ctx + 64]);
    };
}
test "appfilter emitted UDP allows only the exact system stub; full ring still denies" {
    for (programs.hooks[0..4], 0..) |hook, index| {
        const v6 = index % 2 == 1;
        const code = programs.admission(hook, fd);
        var v = Vm.init();
        v.setTag(100, 1);
        v.socket(v6, 53, 17);
        try std.testing.expectEqual(@as(u64, 0), try v.run(&code));
        try std.testing.expectEqual(@as(u64, @backingInt(if (index < 2) abi.Reason.udp_connect else abi.Reason.udp)), v.get(event + @offsetOf(abi.Event, "reason"), 4));
        v.ring_full = true;
        try std.testing.expectEqual(@as(u64, 0), try v.run(&code));
        try std.testing.expectEqual(@as(u64, 1), v.get(lost, 8));
        if (v6) v.mapped(0x7f000035) else v.addr4(0x7f000035);
        try std.testing.expectEqual(@as(u64, 1), try v.run(&code));
        v.put(ctx + 24, std.mem.nativeToBig(u16, 443), 4);
        try std.testing.expectEqual(@as(u64, 0), try v.run(&code));
    }
}
test "appfilter user and root guards cover every listener and local or unspecified spelling" {
    for (0..abi.max_apps + 1) |app| for (abi.first_port..abi.last_port + 1) |port| for (0..9) |form| for ([_]bool{ false, true }) |root| {
        const tag: u32 = @intCast(app);
        const v6 = form >= 4;
        var v = Vm.init();
        v.setTag(100, tag);
        v.socket(v6, @intCast(port), 6);
        switch (form) {
            0 => v.addr4(0x7f000001),
            1 => v.addr4(0x7f123456),
            2 => v.addr4(0),
            3 => v.addr4(0x00123456),
            4, 5 => {
                v.put(ctx + 8, 0, 8);
                v.put(ctx + 16, 0, 4);
                v.put(ctx + 20, std.mem.nativeToBig(u32, if (form == 4) 1 else 0), 4);
            },
            6 => v.mapped(0x7f123456),
            7 => v.mapped(0),
            8 => v.mapped(0x00123456),
            else => unreachable,
        }
        const hook: std.os.linux.BPF.AttachType = if (v6) .cgroup_inet6_connect else .cgroup_inet4_connect;
        const code = if (root) programs.listenerGuard(hook, fd) else programs.admission(hook, fd);
        const owns = port != abi.last_port and tag == 1 + (port - abi.first_port) / 2;
        try std.testing.expectEqual(@as(u64, @intFromBool(owns)), try v.run(&code));
        if (!owns) try std.testing.expectEqual(@as(u64, @backingInt(abi.Reason.listener_peer)), v.get(event + @offsetOf(abi.Event, "reason"), 4));
        for ([_]u32{ 17, 132, 262 }) |protocol| {
            v.put(ctx + 36, protocol, 4);
            try std.testing.expectEqual(@as(u64, @intFromBool(if (root) owns else tag == 0)), try v.run(&code));
        }
    };
}
test "appfilter root guard leaves non-listener traffic unchanged for every tag" {
    for (programs.hooks[0..2], 0..) |hook, family| for ([_]u32{ 0, 1, 7 }) |tag| for ([_]u16{ 22, 80, 443, 760, 774 }) |port| {
        var v = Vm.init();
        v.setTag(100, tag);
        v.socket(family == 1, port, 6); // non-local address
        const before = v.mem[ctx .. ctx + 64].*;
        const code = programs.listenerGuard(hook, fd);
        try std.testing.expectEqual(@as(u64, 1), try v.run(&code));
        try std.testing.expectEqualSlices(u8, &before, v.mem[ctx .. ctx + 64]);
    };
}
test "appfilter emitted exec fork exit and iterator obey lifecycle and PID reuse" {
    var v = Vm.init();
    v.put(ctx, parent, 8);
    v.put(ctx + 16, bprm, 8);
    v.put(file_app, 2, 4);
    _ = try v.run(&programs.tracing(.exec, fd));
    try std.testing.expectEqual(@as(u32, 2), v.tag(100));
    v.put(file_app, 3, 4);
    _ = try v.run(&programs.tracing(.exec, fd));
    try std.testing.expectEqual(@as(u32, 2), v.tag(100));
    v.put(ctx + 8, child, 8);
    v.setTag(200, 7);
    _ = try v.run(&programs.tracing(.fork, fd));
    try std.testing.expectEqual(@as(u32, 2), v.tag(200));
    v.setTag(100, 0);
    _ = try v.run(&programs.tracing(.fork, fd));
    try std.testing.expectEqual(@as(u32, 0), v.tag(200));
    v.setTag(100, 2);
    v.put(signal + pin.signal_struct_live, 1, 4);
    _ = try v.run(&programs.tracing(.exit, fd));
    try std.testing.expectEqual(@as(u32, 2), v.tag(100));
    v.put(signal + pin.signal_struct_live, 0, 4);
    _ = try v.run(&programs.tracing(.exit, fd));
    try std.testing.expectEqual(@as(u32, 0), v.tag(100));
    v.put(ctx + pin.bpf_iter__task_task, parent, 8);
    _ = try v.run(&programs.tracing(.iterator, fd));
    try std.testing.expectEqual(@as(u64, 3), v.get(existing, 4));
    v.put(existing, 0, 8);
    v.setTag(100, 2);
    _ = try v.run(&programs.tracing(.iterator, fd));
    try std.testing.expectEqual(@as(u64, 0), v.get(existing, 4));
}

test "appfilter exec and startup iterator reject a reused inode with a different generation" {
    for ([_]programs.trace_events{ .exec, .iterator }) |hook| {
        for ([_]u32{ 0, 1, 0x80000000, 0xffffffff }) |new_generation| {
            var v = Vm.init();
            v.put(ctx, parent, 8);
            v.put(ctx + pin.bpf_iter__task_task, parent, 8);
            v.put(ctx + 16, bprm, 8);
            v.put(file_app, 2, 4);
            v.file_key.generation = ~new_generation; // retained old (dev, ino) entry
            v.put(inode + pin.inode_i_generation, new_generation, 4);
            _ = try v.run(&programs.tracing(hook, fd));
            try std.testing.expectEqual(@as(u32, 0), v.tag(100));
            try std.testing.expectEqual(@as(u64, 0), v.get(existing, 4));

            // A listed replacement is recognized only after registering its full new identity.
            v.file_key.generation = new_generation;
            _ = try v.run(&programs.tracing(hook, fd));
            try std.testing.expectEqual(@as(u32, if (hook == .exec) 2 else 0), v.tag(100));
            try std.testing.expectEqual(@as(u64, if (hook == .iterator) 2 else 0), v.get(existing, 4));
        }
    }
}

test "appfilter identity still requires both device and full inode alongside generation" {
    for ([_]programs.trace_events{ .exec, .iterator }) |hook| {
        for ([_]bool{ false, true }) |change_device| {
            var v = Vm.init();
            v.put(ctx, parent, 8);
            v.put(ctx + pin.bpf_iter__task_task, parent, 8);
            v.put(ctx + 16, bprm, 8);
            v.put(file_app, 2, 4);
            if (change_device) v.file_key.device ^= 1 else v.file_key.inode ^= 1 << 40;
            _ = try v.run(&programs.tracing(hook, fd));
            try std.testing.expectEqual(@as(u32, 0), v.tag(100));
            try std.testing.expectEqual(@as(u64, 0), v.get(existing, 4));
        }
    }
}
