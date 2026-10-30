//! The contract between the core and the platform backends.
//!
//! The core creates the scope, starts its proxy (and relay), and hands the backend a LaunchSpec. The backend
//! must confine the command BEFORE it runs, so that the command and every process it starts can open
//! network connections only to the loopback ports listed in `allowed_loopback_ports`. Everything else is
//! refused by the operating system, not by the command's cooperation.
//!
//! Owners: src/macos (lead), src/linux (Linux backend). Changing this file is a contract change between them.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const receipt = @import("receipt.zig");

pub const LaunchSpec = struct {
    scope_id: []const u8,
    /// The command and its arguments. argv[0] is resolved through PATH by the backend.
    argv: []const []const u8,
    /// The command's environment, already carrying the proxy variables.
    environ: *const std.process.Environ.Map,
    /// The only loopback TCP ports the command may connect to: the scope's proxy and, when present, its relay.
    allowed_loopback_ports: []const u16,
    /// The blackice state root (every scope's directory: receipts, policy copies, control sockets), absolute
    /// and with symlinks resolved. Backends must make it read-only or hidden inside the scope.
    state_dir: []const u8,
    /// Receipts for events the backend sees (for example kernel drops on Linux).
    receipts: *receipt.Log,
};

pub const Exit = union(enum) {
    exited: u8,
    signal: u32,
    other,

    /// Shell-style exit status: the code, or 128 + signal.
    pub fn status(e: Exit) u8 {
        return switch (e) {
            .exited => |c| c,
            .signal => |s| @truncate(128 + s),
            .other => 1,
        };
    }
};

pub const Error = error{
    /// No enforcing backend for this OS (or it is not built yet). blackice never runs a command unconfined.
    BackendUnavailable,
    SpawnFailed,
    OutOfMemory,
};

/// The enforcing backend's name, for receipts and messages.
pub const name = switch (builtin.os.tag) {
    .macos => "macos-seatbelt",
    .linux => "linux-cgroup-bpf",
    else => "none",
};

pub const available = switch (builtin.os.tag) {
    .macos => true,
    .linux => @import("../linux/backend.zig").available,
    else => false,
};

pub fn launch(gpa: std.mem.Allocator, io: Io, spec: LaunchSpec) Error!Exit {
    return switch (builtin.os.tag) {
        .macos => @import("../macos/seatbelt.zig").launch(gpa, io, spec),
        .linux => @import("../linux/backend.zig").launch(gpa, io, spec),
        else => error.BackendUnavailable,
    };
}

pub fn exitFromTerm(term: std.process.Child.Term) Exit {
    return switch (term) {
        .exited => |c| .{ .exited = c },
        .signal => |s| .{ .signal = @backingInt(s) },
        else => .other,
    };
}
