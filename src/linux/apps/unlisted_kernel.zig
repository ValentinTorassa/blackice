//! Draft B pin/attachment adapter. Not reachable from the service or CLI.
//! Preparation writes an inactive gate only; there is no activation API here yet.
//! The future controller must hold a separate B transition lock across all mutations.
const std = @import("std");
const sys = @import("../sys.zig");
const l = sys.l;
const bpf = l.BPF;
const kernel = @import("kernel.zig");
const abi = @import("types.zig");
const policy = @import("unlisted.zig");
const programs = @import("unlisted_programs.zig");
const gate_map: kernel.Map = .{ .name = "b_gate", .kind = .array, .key = 4, .value = @sizeOf(policy.Gate), .count = 1 };
// Alias of the base tag map: it keeps recovery verifiable even if a broken teardown removes base pins first.
const tags_map: kernel.Map = .{ .name = "b_tags", .kind = .array, .key = 4, .value = 4, .count = abi.pid_slots };
const program_pins = [_][:0]const u8{ "b_prog_conn4", "b_prog_conn6", "b_prog_send4", "b_prog_send6", "b_prog_create" };
const program_names = [_][]const u8{ "bi_b_conn4", "bi_b_conn6", "bi_b_send4", "bi_b_send6", "bi_b_create" };
const zero: u32 = 0;
const ProgramIds = [5]?u32;

pub fn distinctIds(ids: ProgramIds) !void {
    for (ids, 0..) |maybe_id, i| if (maybe_id) |id| {
        if (id == 0) return error.InvalidAttachmentId;
        for (ids[0..i]) |previous| if (previous == id) return error.DuplicateUnlistedProgram;
    };
}

/// Byte-identical connect/send emitters still have separate kernel identities.
/// A swapped pin must not let cleanup forget a program at another hook.
pub fn verifyPlacement(ids: ProgramIds, hook_index: usize, actual: []const u32) !void {
    if (hook_index >= ids.len) return error.InvalidAttachmentHook;
    try distinctIds(ids);
    for (ids, 0..) |maybe_id, i| if (maybe_id) |id| {
        const count = std.mem.countScalar(u32, actual, id);
        if (count > 1 or (count != 0 and i != hook_index)) return error.UnlistedProgramAtUnexpectedHook;
    };
}

pub fn expectedRootIds(base_id: ?u32, own_id: ?u32, actual: []const u32) !void {
    if (actual.len > 2) return error.ForeignRootAttachment;
    if (base_id) |id| if (id == 0) return error.InvalidAttachmentId;
    if (own_id) |id| if (id == 0 or id == base_id) return error.InvalidAttachmentId;
    const count: usize = @as(usize, @intFromBool(base_id != null)) + @intFromBool(own_id != null);
    if (actual.len != count) return error.ForeignOrMissingRootAttachment;
    if (base_id) |id| if (std.mem.countScalar(u32, actual, id) != 1) return error.ForeignOrMissingRootAttachment;
    if (own_id) |id| if (std.mem.countScalar(u32, actual, id) != 1) return error.ForeignOrMissingRootAttachment;
}

/// Recovery preserves every ID other than its verified B program, including foreign filters.
pub fn preservedAfterDetach(before: []const u32, after: []const u32, own_id: u32) !void {
    if (own_id == 0 or std.mem.countScalar(u32, before, own_id) != 1) return error.UnverifiedDetachTarget;
    if (std.mem.findScalar(u32, after, own_id) != null) return error.UnlistedDetachIncomplete;
    if (after.len + 1 != before.len) return error.OtherAttachmentChanged;
    for (before) |id| {
        if (id == own_id) continue;
        if (id == 0 or std.mem.countScalar(u32, before, id) != 1 or std.mem.countScalar(u32, after, id) != 1)
            return error.OtherAttachmentChanged;
    }
}

fn kind(index: usize) bpf.ProgType {
    return if (index == 4) .cgroup_sock else .cgroup_sock_addr;
}

pub const Loaded = struct {
    gate_fd: l.fd_t = -1,
    tags_fd: l.fd_t = -1,
    programs: [5]l.fd_t = @splat(-1),

    fn fds(f: Loaded) programs.Fds {
        return .{ .gate = f.gate_fd, .tags = f.tags_fd };
    }
    pub fn close(f: *Loaded) void {
        for (f.programs) |fd| if (fd >= 0) sys.close(fd);
        if (f.tags_fd >= 0) sys.close(f.tags_fd);
        if (f.gate_fd >= 0) sys.close(f.gate_fd);
        f.* = .{}; // descriptor close alone never removes attachments or pins
    }
    pub fn prepare(initial_gate: policy.Gate, base_tags: l.fd_t, verifier: []u8) !Loaded {
        if (!initial_gate.valid() or initial_gate.deny_until != 0) return error.InactiveUnlistedGateRequired;
        try vacantPins();
        try kernel.verifyMap(base_tags, tags_map);
        var f: Loaded = .{};
        errdefer f.close(); // pin evidence survives a partial failure, for explicit recovery
        f.gate_fd = try bpf.map_create(gate_map.kind, gate_map.key, gate_map.value, gate_map.count);
        try kernel.verifyMap(f.gate_fd, gate_map);
        try bpf.map_update_elem(f.gate_fd, std.mem.asBytes(&zero), std.mem.asBytes(&initial_gate), 0);
        try kernel.pinFd(f.gate_fd, gate_map.name); // first persistent object
        f.tags_fd = try sys.fd(l.fcntl(base_tags, l.F.DUPFD_CLOEXEC, @as(u32, 0)));
        try kernel.pinFd(f.tags_fd, tags_map.name);
        inline for (programs.hooks, 0..) |hook, i| {
            const code = programs.admission(hook, f.fds());
            f.programs[i] = try kernel.load(&code, kind(i), hook, 0, program_names[i], verifier);
            try kernel.pinFd(f.programs[i], program_pins[i]);
        }
        return f;
    }
    pub fn openExisting() !?Loaded {
        var f: Loaded = .{};
        errdefer f.close();
        f.gate_fd = (try kernel.getPin(gate_map.name)) orelse {
            // No gate is valid only when the whole B namespace is empty.
            try vacantPins();
            return null;
        };
        try kernel.verifyMap(f.gate_fd, gate_map);
        _ = try f.gate();
        f.tags_fd = (try kernel.getPin(tags_map.name)) orelse -1;
        if (f.tags_fd >= 0) try kernel.verifyMap(f.tags_fd, tags_map);
        inline for (program_pins, 0..) |name, i| {
            f.programs[i] = (try kernel.getPin(name)) orelse -1;
            if (f.programs[i] >= 0) {
                if (f.tags_fd < 0) return error.UnlistedTagAliasMissing;
                _ = try f.verifiedId(i);
            }
        }
        _ = try f.verifiedIds();
        return f;
    }
    pub fn gate(f: Loaded) !policy.Gate {
        var value: policy.Gate = undefined;
        try bpf.map_lookup_elem(f.gate_fd, std.mem.asBytes(&zero), std.mem.asBytes(&value));
        if (!value.valid()) return error.InvalidUnlistedGate;
        return value;
    }
    pub fn verifiedId(f: Loaded, index: usize) !u32 {
        if (index >= f.programs.len or f.programs[index] < 0 or f.gate_fd < 0 or f.tags_fd < 0)
            return error.IncompleteUnlistedPins;
        const code = programs.admission(programs.hooks[index], f.fds());
        try kernel.verifyProgram(f.programs[index], &code, kind(index), 0);
        const info = try kernel.programInfo(f.programs[index]);
        if (info.id == 0) return error.InvalidAttachmentId;
        return info.id;
    }
    fn verifiedIds(f: Loaded) !ProgramIds {
        var ids: ProgramIds = @splat(null);
        for (f.programs, 0..) |fd, i| if (fd >= 0) {
            ids[i] = try f.verifiedId(i);
        };
        try distinctIds(ids);
        return ids;
    }
    fn verifyAllPlacements(ids: ProgramIds, root_cgroup: l.fd_t) !void {
        for (programs.hooks, 0..) |hook, i| {
            var got: [128]u32 = undefined;
            try verifyPlacement(ids, i, try kernel.query(root_cgroup, hook, &got));
        }
    }
    /// base_ids must come from the verified base guard FDs, never from a client request.
    /// This method cannot activate denial. No service call site exists until timer/accounting are complete.
    pub fn attachPrepared(f: Loaded, root_cgroup: l.fd_t, base_ids: [2]u32) !void {
        if ((try f.gate()).deny_until != 0) return error.InactiveUnlistedGateRequired;
        if (base_ids[0] == 0 or base_ids[0] == base_ids[1] or base_ids[1] == 0) return error.InvalidAttachmentId;
        const ids = try f.verifiedIds();
        for (ids) |maybe_id| {
            const id = maybe_id orelse return error.IncompleteUnlistedPins;
            if (std.mem.findScalar(u32, &base_ids, id) != null) return error.InvalidAttachmentId;
        }
        // Validate ALL attachment points before the first attach.
        for (programs.hooks, 0..) |hook, i| {
            var got: [128]u32 = undefined;
            try expectedRootIds(if (i < 2) base_ids[i] else null, null, try kernel.query(root_cgroup, hook, &got));
        }
        for (programs.hooks, 0..) |hook, i| {
            var attr: bpf.Attr = .{ .prog_attach = std.mem.zeroes(bpf.ProgAttachAttr) };
            attr.prog_attach.target_fd = root_cgroup;
            attr.prog_attach.attach_bpf_fd = f.programs[i];
            attr.prog_attach.attach_type = @backingInt(hook);
            attr.prog_attach.attach_flags = 2; // ALLOW_MULTI, independent of the base guard
            _ = try sys.check(l.bpf(.prog_attach, &attr, @sizeOf(bpf.ProgAttachAttr)));
            var got: [128]u32 = undefined;
            try expectedRootIds(if (i < 2) base_ids[i] else null, ids[i], try kernel.query(root_cgroup, hook, &got));
        }
    }
    /// Caller already holds NET_ADMIN and the B lock. Never guess an ID or detach a whole hook.
    pub fn detachOwned(f: Loaded, root_cgroup: l.fd_t) !void {
        const ids = try f.verifiedIds();
        try verifyAllPlacements(ids, root_cgroup);
        for (programs.hooks, 0..) |hook, i| {
            const own = ids[i] orelse continue;
            var before_buf: [128]u32 = undefined;
            const before = try kernel.query(root_cgroup, hook, &before_buf);
            if (std.mem.findScalar(u32, before, own) == null) continue; // resumed partial detach
            var attr: bpf.Attr = .{ .prog_attach = std.mem.zeroes(bpf.ProgAttachAttr) };
            attr.prog_attach.target_fd = root_cgroup;
            attr.prog_attach.attach_bpf_fd = f.programs[i];
            attr.prog_attach.attach_type = @backingInt(hook);
            _ = try sys.check(l.bpf(.prog_detach, &attr, @sizeOf(bpf.ProgAttachAttr)));
            var after: [128]u32 = undefined;
            try preservedAfterDetach(before, try kernel.query(root_cgroup, hook, &after), own);
        }
    }
    pub fn unpinDetached(f: Loaded, root_cgroup: l.fd_t) !void {
        // Check the complete set before removing a single pin. Failed detach preserves recovery evidence.
        const ids = try f.verifiedIds();
        for (programs.hooks) |hook| {
            var got: [128]u32 = undefined;
            const attached = try kernel.query(root_cgroup, hook, &got);
            for (ids) |maybe_id| if (maybe_id) |own| {
                if (std.mem.findScalar(u32, attached, own) != null) return error.UnlistedDetachIncomplete;
            };
        }
        for (program_pins) |name| try kernel.unpin(name);
        try kernel.unpin(tags_map.name);
        try kernel.unpin(gate_map.name); // last, allowing interrupted recovery to reopen safely
    }
};

fn vacantPins() !void {
    for ([_][:0]const u8{ gate_map.name, tags_map.name } ++ program_pins) |name| {
        if (try kernel.getPin(name)) |fd| {
            sys.close(fd);
            return error.ExistingUnlistedPinsNeedRecovery;
        }
    }
}

test "appfilter unlisted root layout requires exact base and B identities without foreign IDs" {
    try expectedRootIds(10, null, &.{10});
    try expectedRootIds(10, 20, &.{ 20, 10 });
    try expectedRootIds(null, 20, &.{20});
    try expectedRootIds(null, null, &.{});
    for ([_][]const u32{ &.{}, &.{10}, &.{20}, &.{ 10, 10 }, &.{ 20, 20 }, &.{ 10, 30 }, &.{ 10, 20, 30 } }) |actual| {
        try std.testing.expectError(if (actual.len > 2) error.ForeignRootAttachment else error.ForeignOrMissingRootAttachment, expectedRootIds(10, 20, actual));
    }
    try std.testing.expectError(error.InvalidAttachmentId, expectedRootIds(10, 10, &.{ 10, 10 }));
    try std.testing.expectError(error.InvalidAttachmentId, expectedRootIds(0, null, &.{0}));
}

test "appfilter unlisted detach cannot silently remove base or unrelated filters" {
    try preservedAfterDetach(&.{ 10, 20, 30 }, &.{ 30, 10 }, 20);
    try preservedAfterDetach(&.{20}, &.{}, 20);
    try std.testing.expectError(error.UnlistedDetachIncomplete, preservedAfterDetach(&.{ 10, 20 }, &.{ 10, 20 }, 20));
    try std.testing.expectError(error.OtherAttachmentChanged, preservedAfterDetach(&.{ 10, 20, 30 }, &.{10}, 20));
    try std.testing.expectError(error.OtherAttachmentChanged, preservedAfterDetach(&.{ 10, 20 }, &.{30}, 20));
    try std.testing.expectError(error.UnverifiedDetachTarget, preservedAfterDetach(&.{10}, &.{}, 20));
    try std.testing.expectError(error.UnverifiedDetachTarget, preservedAfterDetach(&.{ 10, 20, 20 }, &.{10}, 20));
}

test "appfilter unlisted swapped or duplicate program pins retain recovery evidence" {
    const ids: ProgramIds = .{ 20, 21, 22, 23, 24 };
    try distinctIds(ids);
    try distinctIds(.{ null, 21, null, 23, null }); // interrupted preparation/recovery
    try std.testing.expectError(error.InvalidAttachmentId, distinctIds(.{ 0, null, null, null, null }));
    try std.testing.expectError(error.DuplicateUnlistedProgram, distinctIds(.{ 20, 21, 20, null, null }));
    try verifyPlacement(ids, 0, &.{ 10, 20 });
    try verifyPlacement(ids, 2, &.{ 30, 22 }); // foreign filters are preserved during recovery
    try verifyPlacement(ids, 3, &.{}); // already detached
    try std.testing.expectError(error.UnlistedProgramAtUnexpectedHook, verifyPlacement(ids, 0, &.{ 10, 22 }));
    try std.testing.expectError(error.UnlistedProgramAtUnexpectedHook, verifyPlacement(ids, 0, &.{ 20, 20 }));
    try std.testing.expectError(error.InvalidAttachmentHook, verifyPlacement(ids, 5, &.{}));
}

test "appfilter unlisted adapter is compiled without executing privileged methods" {
    std.testing.refAllDecls(Loaded);
    try std.testing.expectEqual(@as(usize, 5), program_pins.len);
    try std.testing.expectEqual(@as(u32, 24), gate_map.value);
    for (program_pins) |name| try std.testing.expect(std.mem.startsWith(u8, name, "b_prog_"));
}
