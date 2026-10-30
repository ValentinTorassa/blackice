//! Experimental B control contract. Pure functions only: no BPF, polkit, timer or filesystem calls.
//! The runtime remains disabled until attachment, independent root recovery and VM evidence are reviewed.
const std = @import("std");

pub const Mode = enum { allow, deny };
pub const vm_window_ns: u64 = 5 * 60 * std.time.ns_per_s;
pub const committed: u64 = std.math.maxInt(u64);
pub const required_hooks: u8 = 0b11111;

/// Independent map ABI. Zero, incomplete and expired records disable B only.
/// Return 1 from B still leaves every other attached filter free to refuse.
pub const Gate = extern struct {
    version: u32 = 1,
    owner_uid: u32,
    epoch: u64,
    deny_until: u64 = 0,

    pub fn valid(g: Gate) bool {
        return g.version == 1 and g.owner_uid != 0 and g.epoch != 0;
    }
    pub fn active(g: Gate, boot_ns: u64) bool {
        return g.valid() and (g.deny_until == committed or boot_ns < g.deny_until);
    }
};

/// An arming transaction has an immutable epoch and deadline. Loading and timer registration
/// happen while gate.deny_until is zero; activation must be its last enforcing write.
pub const Preparation = struct {
    gate: Gate,
    deadline: u64,

    pub fn begin(owner_uid: u32, epoch: u64, boot_ns: u64) !Preparation {
        if (owner_uid == 0 or epoch == 0) return error.InvalidUnlistedOwnerOrEpoch;
        const until = std.math.add(u64, boot_ns, vm_window_ns) catch return error.InvalidUnlistedDeadline;
        if (until == committed) return error.InvalidUnlistedDeadline;
        return .{ .gate = .{ .owner_uid = owner_uid, .epoch = epoch }, .deadline = until };
    }
    pub fn activate(p: Preparation, epoch: u64, hooks: u8, root_timer_registered: bool, boot_ns: u64) !Gate {
        if (!p.gate.valid() or p.gate.deny_until != 0 or p.deadline == 0 or p.deadline == committed)
            return error.InvalidUnlistedPreparation;
        if (epoch != p.gate.epoch) return error.StaleUnlistedEpoch;
        if (hooks != required_hooks) return error.UnlistedAttachmentsIncomplete;
        if (!root_timer_registered) return error.UnlistedRecoveryTimerMissing;
        if (boot_ns >= p.deadline) return error.UnlistedTryWindowExpired;
        if (p.deadline - boot_ns > vm_window_ns) return error.InvalidUnlistedDeadline;
        var gate = p.gate;
        gate.deny_until = p.deadline;
        return gate;
    }
};

/// Observations must be collected again AFTER polkit, under the B transition lock.
/// They are not fields accepted from a client. A live peer pidfd and the kernel tag map
/// supply these observations; the future privileged adapter owns that work.
pub const ConfirmPeer = struct {
    uid: u32,
    tag: u32,
    live: bool,
    fresh_admin_authorization: bool,
};

pub fn confirm(gate: Gate, expected_epoch: u64, peer: ConfirmPeer, boot_ns: u64) !Gate {
    if (!gate.valid() or gate.deny_until == 0) return error.UnlistedNotArmed;
    if (expected_epoch != gate.epoch) return error.StaleUnlistedEpoch;
    if (peer.uid == 0 or peer.uid != gate.owner_uid) return error.NotOwner;
    if (!peer.live) return error.PeerExited;
    if (peer.tag != 0) return error.TaggedCaller;
    if (!peer.fresh_admin_authorization) return error.NotAuthorized;
    if (!gate.active(boot_ns)) return error.UnlistedTryWindowExpired;
    var result = gate;
    result.deny_until = committed; // no additive extension, even on repeated confirmation
    return result;
}

pub const TimerAction = enum { ignore, detach_b_only };
pub fn timerAction(gate: Gate, expected_epoch: u64, boot_ns: u64) TimerAction {
    if (!gate.valid() or gate.epoch != expected_epoch or gate.deny_until == 0 or
        gate.deny_until == committed or boot_ns < gate.deny_until) return .ignore;
    return .detach_b_only;
}

pub fn requireRuntimeSupport(mode: Mode) !void {
    if (mode == .deny) return error.ExperimentalUnlistedRuntimeNotReady;
}

test "appfilter unlisted preparation never enforces before all hooks and the independent timer" {
    const p = try Preparation.begin(1000, 9, 100);
    try std.testing.expect(!p.gate.active(101));
    for (0..required_hooks) |hooks|
        try std.testing.expectError(error.UnlistedAttachmentsIncomplete, p.activate(9, @intCast(hooks), true, 101));
    try std.testing.expectError(error.UnlistedRecoveryTimerMissing, p.activate(9, required_hooks, false, 101));
    try std.testing.expectError(error.StaleUnlistedEpoch, p.activate(10, required_hooks, true, 101));
    try std.testing.expectError(error.UnlistedTryWindowExpired, p.activate(9, required_hooks, true, p.deadline));
    const gate = try p.activate(9, required_hooks, true, 101);
    try std.testing.expectEqual(100 + vm_window_ns, gate.deny_until);
    try std.testing.expect(gate.active(p.deadline - 1));
    try std.testing.expect(!gate.active(p.deadline));
    try std.testing.expect(!gate.active(p.deadline + vm_window_ns)); // suspend consumes boot time too
}

test "appfilter unlisted confirmation rechecks owner pidfd tag authorization epoch and deadline" {
    const p = try Preparation.begin(1000, 9, 100);
    const gate = try p.activate(9, required_hooks, true, 101);
    const owner: ConfirmPeer = .{ .uid = 1000, .tag = 0, .live = true, .fresh_admin_authorization = true };
    var peer = owner;
    peer.uid = 0;
    try std.testing.expectError(error.NotOwner, confirm(gate, 9, peer, 102));
    peer.uid = 1001;
    try std.testing.expectError(error.NotOwner, confirm(gate, 9, peer, 102));
    peer = owner;
    peer.live = false;
    try std.testing.expectError(error.PeerExited, confirm(gate, 9, peer, 102));
    peer = owner;
    peer.tag = 1;
    try std.testing.expectError(error.TaggedCaller, confirm(gate, 9, peer, 102));
    peer = owner;
    peer.fresh_admin_authorization = false;
    try std.testing.expectError(error.NotAuthorized, confirm(gate, 9, peer, 102));
    try std.testing.expectError(error.StaleUnlistedEpoch, confirm(gate, 8, owner, 102));
    try std.testing.expectError(error.UnlistedTryWindowExpired, confirm(gate, 9, owner, p.deadline));
    const approved = try confirm(gate, 9, owner, p.deadline - 1);
    try std.testing.expectEqual(committed, approved.deny_until);
    try std.testing.expectEqualDeep(approved, try confirm(approved, 9, owner, p.deadline + 100));
}

test "appfilter unlisted old timers cannot revert a new epoch or an authenticated commit" {
    const p = try Preparation.begin(1000, 9, 100);
    const gate = try p.activate(9, required_hooks, true, 101);
    try std.testing.expectEqual(TimerAction.ignore, timerAction(gate, 8, p.deadline + 1));
    try std.testing.expectEqual(TimerAction.ignore, timerAction(gate, 9, p.deadline - 1));
    try std.testing.expectEqual(TimerAction.detach_b_only, timerAction(gate, 9, p.deadline));
    const approved = try confirm(gate, 9, .{ .uid = 1000, .tag = 0, .live = true, .fresh_admin_authorization = true }, p.deadline - 1);
    try std.testing.expectEqual(TimerAction.ignore, timerAction(approved, 9, p.deadline + 1));
    try std.testing.expectEqual(TimerAction.ignore, timerAction(p.gate, 9, p.deadline + 1));
}

test "appfilter unlisted invalid state disarms only B and the runtime cannot arm this draft" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Gate));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Gate, "owner_uid"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Gate, "epoch"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Gate, "deny_until"));
    try requireRuntimeSupport(.allow);
    try std.testing.expectError(error.ExperimentalUnlistedRuntimeNotReady, requireRuntimeSupport(.deny));
    try std.testing.expectError(error.InvalidUnlistedOwnerOrEpoch, Preparation.begin(0, 1, 0));
    try std.testing.expectError(error.InvalidUnlistedOwnerOrEpoch, Preparation.begin(1000, 0, 0));
    try std.testing.expectError(error.InvalidUnlistedDeadline, Preparation.begin(1000, 1, committed - vm_window_ns));
    try std.testing.expectError(error.InvalidUnlistedDeadline, Preparation.begin(1000, 1, committed));
    for ([_]Gate{
        .{ .owner_uid = 0, .epoch = 1, .deny_until = committed },
        .{ .owner_uid = 1000, .epoch = 0, .deny_until = committed },
        .{ .owner_uid = 1000, .epoch = 1, .version = 2, .deny_until = committed },
    }) |gate| try std.testing.expect(!gate.active(0));
    var p = try Preparation.begin(1000, 9, 100);
    p.deadline = committed;
    try std.testing.expectError(error.InvalidUnlistedPreparation, p.activate(9, required_hooks, true, 101));
}
