//! Fixed host paths and root-trusted executable identities. No caller path is opened with DAC privileges.
const std = @import("std");
const sys = @import("../sys.zig");
const l = sys.l;
const abi = @import("types.zig");
const kernel = @import("kernel.zig");
pub const state_root = "/var/lib/blackice-appfilter";
pub const Install = struct { version: u32, owner_uid: u32, owner_gid: u32, service_uid: u32, service_gid: u32 };
pub fn installation(gpa: std.mem.Allocator) !Install {
    const fd = try sys.fd(l.open("/etc/blackice-appfilter/owner.json", .{ .CLOEXEC = true, .NOFOLLOW = true }, 0));
    defer sys.close(fd);
    try sys.rootOwned(fd);
    var bytes: [512]u8 = undefined;
    const n = try sys.read(fd, &bytes);
    if (n == bytes.len) return error.BadInstallation;
    const parsed = try std.json.parseFromSlice(Install, gpa, bytes[0..n], .{ .ignore_unknown_fields = false, .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    const cfg = parsed.value;
    if (cfg.version != 1 or cfg.owner_uid == 0 or cfg.service_uid == 0 or cfg.owner_uid == cfg.service_uid) return error.BadInstallation;
    return cfg;
}
pub fn directories(cfg: Install) !void {
    const p = try sys.fd(l.open(kernel.pin_root, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0));
    defer sys.close(p);
    const s = try sys.stat(p);
    if (s.uid != cfg.service_uid or s.mode & 0o777 != 0o700) return error.UnprotectedPins;
    var fs: [32]u64 = @splat(0);
    _ = try sys.check(l.syscall2(.fstatfs, @as(usize, @intCast(p)), @intFromPtr(&fs)));
    if (fs[0] != 0xcafe4a11) return error.PrivateBpffsRequired;
    const d = try sys.fd(l.open(state_root, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0));
    defer sys.close(d);
    const ds = try sys.stat(d);
    if (ds.uid != cfg.service_uid or ds.gid != cfg.owner_gid or ds.mode & 0o7777 != 0o2750) return error.UnprotectedServiceState;
}
pub fn cgroup() !l.fd_t {
    return openCgroup(kernel.cgroup_path);
}
pub fn rootCgroup() !l.fd_t {
    return openCgroup(kernel.root_cgroup_path);
}
fn openCgroup(path: [:0]const u8) !l.fd_t {
    const fd = try sys.fd(l.open(path, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0));
    errdefer sys.close(fd);
    try sys.rootOwned(fd);
    var fs: [32]u64 = @splat(0);
    _ = try sys.check(l.syscall2(.fstatfs, @as(usize, @intCast(fd)), @intFromPtr(&fs)));
    if (fs[0] != 0x63677270) return error.CgroupV2Required;
    return fd;
}
pub fn portFloor() !void {
    const fd = try sys.fd(l.open("/proc/sys/net/ipv4/ip_unprivileged_port_start", .{ .CLOEXEC = true, .NOFOLLOW = true }, 0));
    defer sys.close(fd);
    var buf: [32]u8 = undefined;
    const n = try sys.read(fd, &buf);
    const value = std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..n], "\n"), 10) catch return error.InvalidPortFloor;
    if (!@import("state.zig").validPortFloor(value)) return error.ListenerPortsAreUnprivileged;
}
pub fn identity(gpa: std.mem.Allocator, path: []const u8) !abi.FileKey {
    if (!@import("config.zig").validPath(path)) return error.InvalidExecutablePath;
    var dir = try sys.fd(l.open("/", .{ .PATH = true, .DIRECTORY = true, .CLOEXEC = true }, 0));
    defer sys.close(dir);
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        const name = try gpa.dupeSentinel(u8, part, 0);
        defer gpa.free(name);
        const next = try sys.fd(l.openat(dir, name, .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }, 0));
        errdefer sys.close(next);
        try sys.rootOwned(next);
        const s = try sys.stat(next);
        const last = parts.peek() == null;
        if (s.mode & 0o170000 != (if (last) @as(u16, 0o100000) else @as(u16, 0o040000))) return error.CanonicalRootOwnedExecutableRequired;
        sys.close(dir);
        dir = next;
        if (last) {
            if (s.mode & 0o111 == 0) return error.ExecutableRequired;
            var fs: [32]u64 = @splat(0);
            _ = try sys.check(l.syscall2(.fstatfs, @as(usize, @intCast(dir)), @intFromPtr(&fs)));
            if (!identityFilesystemSupported(fs[0])) return error.UnsupportedExecutableFilesystem;
            return .{ .device = try abi.kernelDevice(s.dev_major, s.dev_minor), .inode = s.ino };
        }
    }
    return error.ExecutableRequired;
}
pub fn identityFilesystemSupported(magic: u64) bool {
    // statx st_dev must equal inode->i_sb->s_dev. btrfs subvolumes and overlayfs do not meet this contract.
    return magic == 0xef53 or magic == 0x58465342; // ext4 (ext family ABI) / xfs
}
test "appfilter executable filesystem identity rejects overlay and btrfs" {
    try std.testing.expect(identityFilesystemSupported(0xef53));
    try std.testing.expect(identityFilesystemSupported(0x58465342));
    for ([_]u64{ 0x9123683e, 0x794c7630, 0x01021994, 0 }) |magic| try std.testing.expect(!identityFilesystemSupported(magic));
}
pub fn writePolicy(gpa: std.mem.Allocator, io: std.Io, digest: []const u8, bytes: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(gpa, state_root ++ "/policy-{s}.json", .{digest}, 0);
    defer gpa.free(path);
    const opened = l.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    if (l.errno(opened) == .EXIST) {
        const old = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(@import("config.zig").max_bytes));
        defer gpa.free(old);
        if (!std.mem.eql(u8, old, bytes)) return error.StoredPolicyMismatch;
        return;
    }
    const fd = try sys.fd(opened);
    defer sys.close(fd);
    try sys.writeAll(fd, bytes);
    _ = try sys.check(l.fsync(fd));
    const dir = try sys.fd(l.open(state_root, .{ .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0));
    defer sys.close(dir);
    _ = try sys.check(l.fsync(dir));
}
pub fn watch(gpa: std.mem.Allocator, paths: []const @import("config.zig").App) !l.fd_t {
    const fd = try sys.fd(l.inotify_init1(l.SOCK.CLOEXEC | l.SOCK.NONBLOCK));
    errdefer sys.close(fd);
    for (paths) |app| {
        // Watch the containing directory: rename-over replaces the file being watched.
        const slash = std.mem.findScalarLast(u8, app.executable, '/') orelse return error.InvalidExecutablePath;
        const parent = try gpa.dupeSentinel(u8, if (slash == 0) "/" else app.executable[0..slash], 0);
        defer gpa.free(parent);
        _ = try sys.check(l.inotify_add_watch(fd, parent, l.IN.CREATE | l.IN.MOVED_TO | l.IN.DELETE_SELF | l.IN.MOVE_SELF | l.IN.ATTRIB | l.IN.CLOSE_WRITE));
    }
    return fd;
}
