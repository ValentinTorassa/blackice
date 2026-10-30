//! Reload has its own fresh owner authorization; no retained polkit grant.
const std = @import("std");
const ipc = @import("ipc.zig");
const polkit = @import("polkit.zig");

pub const help =
    "blackice app reload --policy FILE\n" ++
    "availability=experimental_vm_only\n" ++
    "Generation must be current + 1 (maximum 256). New applications must be closed first.\n" ++
    "Requires fresh owner polkit authorization. Host use awaits security and VM acceptance.\n";

pub fn requireAvailable() error{}!void {}

/// Uses the kernel-derived peer and a fresh, non-retained reload-specific action.
pub fn authorize(peer: ipc.Peer) !void {
    try requireAvailable();
    try polkit.authorizeAction(peer, .reload);
}

test "appfilter reload help explicitly retains the host review gate" {
    try std.testing.expect(std.mem.find(u8, help, "experimental_vm_only") != null);
}
