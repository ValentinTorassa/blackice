//! Experimental B instruction emitter. It is NOT called by the privileged loader.
//! Five hook programs form one B filter; base listener/tracing programs stay unchanged.
//! Refusal accounting and verified attachment/recovery are prerequisites to runtime enablement.
const std = @import("std");
const a = @import("assembler.zig");
const I = a.I;
const abi = @import("types.zig");
pub const hooks = @import("programs.zig").hooks;
pub const Fds = struct { gate: i32, tags: i32 };
pub const fixture_fds: Fds = .{ .gate = 101, .tags = 11 };
const Fixups = struct {
    sites: [32]usize = undefined,
    len: usize = 0,
    fn add(f: *Fixups, p: *a.Program, insn: I) void {
        std.debug.assert(f.len < f.sites.len);
        f.sites[f.len] = p.add(insn);
        f.len += 1;
    }
    fn patch(f: Fixups, p: *a.Program, target: usize) void {
        for (f.sites[0..f.len]) |at| p.patch(at, target);
    }
};

pub fn admission(hook: a.bpf.AttachType, fds: Fds) a.Program {
    std.debug.assert(std.mem.findScalar(a.bpf.AttachType, &hooks, hook) != null);
    const create = hook == .cgroup_inet_sock_create;
    const v6 = hook == .cgroup_inet6_connect or hook == .cgroup_udp6_sendmsg;
    var p: a.Program = .{};
    var allow: Fixups = .{};
    var deny: Fixups = .{};
    p.emit(I.mov(.r6, .r1));
    p.emit(I.st(.word, .r10, -4, 0));
    p.lookup(fds.gate, -4);
    allow.add(&p, I.jeq(.r0, 0, 0));
    p.emit(I.ldx(.word, .r1, .r0, 0)); // Gate.version
    allow.add(&p, I.jne(.r1, 1, 0));
    p.emit(I.ldx(.word, .r7, .r0, 4)); // Gate.owner_uid, real UID in initial user namespace
    allow.add(&p, I.jeq(.r7, 0, 0));
    p.emit(I.ldx(.double_word, .r1, .r0, 8)); // Gate.epoch
    allow.add(&p, I.jeq(.r1, 0, 0));
    p.emit(I.ldx(.double_word, .r8, .r0, 16)); // Gate.deny_until, CLOCK_BOOTTIME
    allow.add(&p, I.jeq(.r8, 0, 0));
    p.emit(I.call(.get_current_uid_gid));
    p.emit(I.lsh(.r0, 32));
    p.emit(I.rsh(.r0, 32));
    allow.add(&p, I.jne(.r0, .r7, 0)); // NOT effective UID; owner cron/at get no exemption
    const committed = p.add(I.jeq(.r8, -1, 0));
    p.emit(I.call(.ktime_get_boot_ns));
    allow.add(&p, I.jge(.r0, .r8, 0));
    const classify = p.len;
    p.emit(I.call(.get_current_pid_tgid));
    p.emit(I.rsh(.r0, 32));
    p.emit(I.stx(.word, .r10, -8, .r0));
    p.lookup(fds.tags, -8);
    deny.add(&p, I.jeq(.r0, 0, 0));
    p.emit(I.ldx(.word, .r0, .r0, 0));
    deny.add(&p, I.jgt(.r0, abi.max_apps, 0));
    allow.add(&p, I.jne(.r0, 0, 0)); // listed tags continue to the existing app policy
    p.patch(committed, classify);
    if (create) {
        // No destination exists here. Admit only the TCP/UDP sockets whose outgoing operations
        // are checked below. Inbound accept and existing sockets remain declared limits.
        p.emit(I.ldx(.word, .r0, .r6, 12));
        const tcp = p.add(I.jeq(.r0, 6, 0));
        deny.add(&p, I.jne(.r0, 17, 0));
        p.emit(I.ldx(.word, .r0, .r6, 8));
        deny.add(&p, I.jne(.r0, 2, 0));
        allow.add(&p, I.ja(0));
        const stream = p.len;
        p.emit(I.ldx(.word, .r0, .r6, 8));
        deny.add(&p, I.jne(.r0, 1, 0));
        allow.add(&p, I.ja(0));
        p.patch(tcp, stream);
    } else {
        // The only unlisted endpoint exemption: exact UDP stub, including its mapped-v6 spelling.
        p.emit(I.ldx(.word, .r0, .r6, 36));
        deny.add(&p, I.jne(.r0, 17, 0));
        p.emit(I.ldx(.word, .r0, .r6, 24));
        deny.add(&p, I.jne(.r0, std.mem.nativeToBig(u16, 53), 0));
        if (v6) {
            for ([_]i16{ 8, 12 }) |offset| {
                p.emit(I.ldx(.word, .r0, .r6, offset));
                deny.add(&p, I.jne(.r0, 0, 0));
            }
            p.emit(I.ldx(.word, .r0, .r6, 16));
            deny.add(&p, a.word(I.jne(.r0, @as(i32, @bitCast(std.mem.nativeToBig(u32, 65535))), 0)));
        }
        p.emit(I.ldx(.word, .r0, .r6, if (v6) 20 else 4));
        deny.add(&p, a.word(I.jne(.r0, @as(i32, @bitCast(std.mem.nativeToBig(u32, 0x7f000035))), 0)));
        allow.add(&p, I.ja(0));
    }
    const no = p.len;
    p.ret(0);
    const yes = p.len;
    p.ret(1);
    deny.patch(&p, no);
    allow.patch(&p, yes);
    return p;
}

test "appfilter unlisted emits five independent bounded programs without changing base guards" {
    const base = @import("programs.zig");
    const kernel = @import("kernel.zig");
    const before = kernel.programTag(&base.listenerGuard(.cgroup_inet4_connect, base.fixture_fds));
    for (hooks) |hook| {
        const code = admission(hook, fixture_fds);
        try a.validate(&code);
        try std.testing.expect(code.len < 128);
        for (code.code[0..code.len]) |insn| {
            // No writes to packet/socket context, base maps, ring or arbitrary helpers.
            if (insn.code & 7 == 2 or insn.code & 7 == 3) try std.testing.expectEqual(@backingInt(a.Reg.r10), insn.dst);
        }
    }
    try std.testing.expectEqualSlices(u8, &before, &kernel.programTag(&base.listenerGuard(.cgroup_inet4_connect, base.fixture_fds)));
}
