//! Explicit build gate. Independent components do not make runtime reload safe.
const std = @import("std");
const ipc = @import("ipc.zig");
const polkit = @import("polkit.zig");

pub const help =
    "blackice app reload --policy FILE\n" ++
    "availability=prepared_only\n" ++
    "Reload is unavailable pending the reviewed child channel, admission fence and crash recovery.\n";

pub fn requireAvailable() error{ReloadNotReady}!void {
    return error.ReloadNotReady;
}

/// No prompt before the implementation exists. The eventual request must still
/// use the kernel-derived peer and a fresh, non-retained reload-specific action.
pub fn authorize(peer: ipc.Peer) !void {
    try requireAvailable();
    try polkit.authorizeAction(peer, .reload);
}

test "appfilter reload availability gate never requests authorization or changes policy" {
    try std.testing.expectError(error.ReloadNotReady, requireAvailable());
    // Invalid FDs make any accidental call into peer/polkit handling fail this test.
    try std.testing.expectError(error.ReloadNotReady, authorize(.{ .credentials = .{ .pid = 0, .uid = 0, .gid = 0 }, .pidfd = -1 }));
}
