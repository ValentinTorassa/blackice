//! Linux task scope. OWNER: Codex (see collaboration/lead.txt section 4).
//!
//! Placeholder so the core builds. Until the real backend lands, blackice refuses to run commands on Linux:
//! it never runs a command without an enforcing backend.
//!
//! The planned design (lead.txt section 3): a cgroup under /sys/fs/cgroup/blackice/ owned by root, a small
//! privileged helper that moves the paused child there before exec, an nftables table that drops every packet
//! from that cgroup except to the allowed loopback ports, NFLOG drops reported as receipts, and a private
//! mount namespace that hides resolver and daemon sockets.

const std = @import("std");
const backend = @import("../core/backend.zig");

pub const available = false;

pub fn launch(gpa: std.mem.Allocator, io: std.Io, spec: backend.LaunchSpec) backend.Error!backend.Exit {
    _ = gpa;
    _ = io;
    spec.receipts.write(.{ .event = "warning", .point = .control, .reason = "backend_unavailable", .detail = "linux backend not built yet" });
    return error.BackendUnavailable;
}
