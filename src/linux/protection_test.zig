const std = @import("std");
const sys = @import("sys.zig");
const l = sys.l;
const confinement = @import("confinement.zig");
const protection = @import("protection.zig");
const fixture: [:0]const u8 = @embedFile("protection_fixture.py").* ++ "\x00";

test "protected files, symlink entries and state ancestors resist mutation while neighbors remain writable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    buf[n] = 0;
    try exercise(tmp.dir, buf[0..n :0], false);
}

test "protected objects outside a temporary cwd are restored without exposing other host files" {
    for ([_][]const u8{ "/tmp", "/var/tmp" }) |parent| {
        var random: [8]u8 = undefined;
        std.testing.io.random(&random);
        var buf: [128]u8 = undefined;
        const base = try std.fmt.bufPrintSentinel(&buf, "{s}/blackice-protected-{s}", .{ parent, std.fmt.bytesToHex(random, .lower) }, 0);
        try std.Io.Dir.createDirAbsolute(std.testing.io, base, .fromMode(0o700));
        defer std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
        var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, base, .{});
        defer dir.close(std.testing.io);
        try exercise(dir, base, true);
    }
}

fn exercise(dir: std.Io.Dir, base: [:0]const u8, temporary: bool) !void {
    const io = std.testing.io;
    try dir.createDirPath(io, "parent/bin");
    try dir.createDirPath(io, "parent/policy");
    try dir.createDirPath(io, "state-parent/state/scopes/one");
    try dir.writeFile(io, .{ .sub_path = "parent/unrelated", .data = "hidden in temporary views\n" });
    try dir.writeFile(io, .{ .sub_path = "parent/policy/policy.json", .data = "original-policy\n" });
    try dir.writeFile(io, .{ .sub_path = "state-parent/state/scopes/one/receipts", .data = "original-receipt\n" });
    const executable = try dir.createFile(io, "parent/bin/blackice", .{ .permissions = .fromMode(0o700) });
    try sys.writeAll(executable.handle, "#!/bin/sh\nexit 0\n");
    executable.close(io);
    try dir.symLink(io, "blackice", "parent/bin/blackice-link", .{});
    try dir.symLink(io, "bin", "parent/bin-link", .{ .is_directory = true });
    var path_buf: [6][4096]u8 = undefined;
    const cwd = try std.fmt.bufPrintSentinel(&path_buf[0], "{s}/parent/bin", .{base}, 0);
    const state = try std.fmt.bufPrintSentinel(&path_buf[1], "{s}/state-parent/state", .{base}, 0);
    var paths: [4][:0]const u8 = undefined;
    for ([_][]const u8{ "parent/bin/blackice", "parent/policy/policy.json", "parent/bin/blackice-link", "parent/bin-link" }, 0..) |suffix, i| {
        paths[i] = try std.fmt.bufPrintSentinel(&path_buf[i + 2], "{s}/{s}", .{ base, suffix }, 0);
    }
    const uid = l.getuid();
    const gid = l.getgid();
    const pid: l.pid_t = @intCast(try sys.check(l.fork()));
    if (pid == 0) {
        _ = sys.check(l.close_range(3, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = false })) catch l.exit_group(1);
        _ = sys.check(l.chdir(cwd)) catch l.exit_group(2);
        confinement.arm(uid, gid, state, &paths) catch |err| {
            sys.writeAll(2, @errorName(err)) catch {};
            l.exit_group(3);
        };
        const argv = [_:null]?[*:0]const u8{ "/usr/bin/python3", "-c", fixture.ptr, base.ptr, if (temporary) "temporary" else "normal" };
        const env = [_:null]?[*:0]const u8{};
        _ = l.execve("/usr/bin/python3", &argv, &env);
        l.exit_group(4);
    }
    try std.testing.expectEqual(@as(u32, 0), try sys.wait(pid));
}

test "pre-existing hard links and intermediate symlinks refuse protection before exec" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.createDirPath(io, "real");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/file", .data = "trusted" });
    try tmp.dir.symLink(io, "real", "redirect", .{ .is_directory = true });
    var base_buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &base_buf);
    var state_buf: [4096]u8 = undefined;
    var file_buf: [4096]u8 = undefined;
    const state = try std.fmt.bufPrintSentinel(&state_buf, "{s}/state", .{base_buf[0..n]}, 0);
    const redirected = try std.fmt.bufPrintSentinel(&file_buf, "{s}/redirect/file", .{base_buf[0..n]}, 0);
    try std.testing.expectError(error.ProtectedPathMustBeCanonical, protection.Prepared.init(state, &.{redirected}));
    _ = try sys.check(l.linkat(tmp.dir.handle, "real/file", tmp.dir.handle, "alias", 0));
    const file = try std.fmt.bufPrintSentinel(&file_buf, "{s}/real/file", .{base_buf[0..n]}, 0);
    try std.testing.expectError(error.ProtectedFileHasHardLinks, protection.Prepared.init(state, &.{file}));
}

test "an existing alternate mount view refuses protection before exec" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.createDirPath(io, "source");
    try tmp.dir.createDirPath(io, "alias");
    try tmp.dir.writeFile(io, .{ .sub_path = "source/file", .data = "trusted" });
    var base_buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &base_buf);
    var path_buf: [4][4096]u8 = undefined;
    var paths: [4][:0]const u8 = undefined;
    for ([_][]const u8{ "state", "source", "alias", "source/file" }, 0..) |suffix, i| {
        paths[i] = try std.fmt.bufPrintSentinel(&path_buf[i], "{s}/{s}", .{ base_buf[0..n], suffix }, 0);
    }
    const uid = l.getuid();
    const gid = l.getgid();
    const pid: l.pid_t = @intCast(try sys.check(l.fork()));
    if (pid == 0) {
        confinement.isolate(uid, gid) catch l.exit_group(1);
        _ = sys.check(l.mount(paths[1], paths[2], null, l.MS.BIND, 0)) catch l.exit_group(2);
        if (protection.Prepared.init(paths[0], &.{paths[3]})) |value| {
            var p = value;
            p.close();
            l.exit_group(3);
        } else |err| l.exit_group(if (err == error.ProtectionFilesystemHasAliases) 0 else 4);
    }
    try std.testing.expectEqual(@as(u32, 0), try sys.wait(pid));
}

test "stdio cannot retain protected inodes, state files or directory access through the old mount" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/receipt", .data = "receipt" });
    try tmp.dir.writeFile(io, .{ .sub_path = "trusted", .data = "trusted" });
    var base_buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &base_buf);
    var path_buf: [3][4096]u8 = undefined;
    var paths: [3][:0]const u8 = undefined;
    for ([_][]const u8{ "state", "trusted", "state/receipt" }, 0..) |suffix, i| {
        paths[i] = try std.fmt.bufPrintSentinel(&path_buf[i], "{s}/{s}", .{ base_buf[0..n], suffix }, 0);
    }
    for ([_]usize{ 1, 2, 0 }) |source| {
        const pid: l.pid_t = @intCast(try sys.check(l.fork()));
        if (pid == 0) {
            const fd = sys.fd(l.open(paths[source], .{ .CLOEXEC = true }, 0)) catch l.exit_group(1);
            _ = sys.check(l.dup3(fd, 0, 0)) catch l.exit_group(2);
            sys.close(fd);
            if (protection.Prepared.init(paths[0], &.{paths[1]})) |value| {
                var p = value;
                p.close();
                l.exit_group(3);
            } else |err| {
                const expected = if (source == 0) error.DirectoryStdioNotAllowed else error.ProtectedStdioNotAllowed;
                l.exit_group(if (err == expected) 0 else 4);
            }
        }
        try std.testing.expectEqual(@as(u32, 0), try sys.wait(pid));
    }
}
