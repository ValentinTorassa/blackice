//! Linux task scope. Owned by the Linux backend; this file is a placeholder until that code lands.
//!
//! Placeholder so the core builds. Until the real backend lands, blackice refuses to run commands on Linux:
//! it never runs a command without an enforcing backend.
//!
//! The planned design: a root-owned cgroup v2 scope whose BPF connect and sendmsg programs admit only TCP to
//! the allowed loopback ports, a small capability-bearing helper that forks the paused child and enrolls it
//! before it runs, refusals reported as receipts, and a private mount namespace that hides resolver and daemon
//! sockets and makes the state directory read-only.

const std = @import("std");
const backend = @import("../core/backend.zig");

pub const available = false;
/// LaunchSpec.protected_paths is not honored yet; blackice run refuses scopes that need it.
pub const protects_paths = false;

pub fn launch(gpa: std.mem.Allocator, io: std.Io, spec: backend.LaunchSpec) backend.Error!backend.Exit {
    _ = gpa;
    _ = io;
    spec.receipts.write(.{ .event = "warning", .point = .control, .reason = "backend_unavailable", .detail = "linux backend not built yet" });
    return error.BackendUnavailable;
}
