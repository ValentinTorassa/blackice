//! Control socket tests over a real Unix socket in a temporary scope directory.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const receipt = @import("../core/receipt.zig");
const Grants = @import("../proxy/grants.zig").Grants;
const control = @import("control.zig");

const Harness = struct {
    io: Io,
    tmp: testing.TmpDir,
    dir_buf: [128]u8 = undefined,
    dir: []const u8 = "",
    log: receipt.Log,
    grants: Grants,
    server: *control.Server,

    fn init(h: *Harness) !void {
        h.io = testing.io;
        h.tmp = testing.tmpDir(.{});
        errdefer h.tmp.cleanup();
        // Relative to the test's working directory, which keeps the socket path short.
        h.dir = try std.fmt.bufPrint(&h.dir_buf, ".zig-cache/tmp/{s}", .{h.tmp.sub_path});
        h.log = try receipt.Log.open(h.io, h.tmp.dir, "receipts.jsonl", "s-test0006", "000000000000");
        errdefer h.log.close();
        h.grants = .init(testing.allocator);
        errdefer h.grants.deinit();
        h.server = try control.Server.start(testing.allocator, h.io, h.dir, &h.grants, &h.log);
    }

    fn deinit(h: *Harness) void {
        h.server.stop();
        h.grants.deinit();
        h.log.close();
        h.tmp.cleanup();
    }

    fn receiptAt(h: *Harness, n: usize) !std.json.Parsed(std.json.Value) {
        const bytes = try h.tmp.dir.readFileAlloc(h.io, "receipts.jsonl", testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
        var i: usize = 0;
        while (it.next()) |line| : (i += 1) {
            if (i == n) return std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        }
        return error.MissingReceipt;
    }
};

fn expectField(v: std.json.Value, key: []const u8, want: []const u8) !void {
    const got = v.object.get(key) orelse {
        std.debug.print("receipt has no \"{s}\"\n", .{key});
        return error.TestExpectedEqual;
    };
    try testing.expectEqualStrings(want, got.string);
}

test "grant and revoke from outside the scope" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var rule_buf: [300]u8 = undefined;

    {
        const reply = try control.grant(testing.allocator, h.io, h.dir, "API.example.com", 600);
        defer reply.deinit();
        try testing.expect(reply.value.ok);
        try testing.expect(std.mem.endsWith(u8, reply.value.expires.?, "Z"));
    }
    try testing.expect(h.grants.check(h.io, "api.example.com", &rule_buf) != null);

    {
        const reply = try control.revoke(testing.allocator, h.io, h.dir, "api.example.com");
        defer reply.deinit();
        try testing.expect(reply.value.ok);
        try testing.expectEqual(@as(?bool, true), reply.value.removed);
    }
    try testing.expect(h.grants.check(h.io, "api.example.com", &rule_buf) == null);
    {
        const reply = try control.revoke(testing.allocator, h.io, h.dir, "api.example.com");
        defer reply.deinit();
        try testing.expectEqual(@as(?bool, false), reply.value.removed);
    }

    var r0 = try h.receiptAt(0);
    defer r0.deinit();
    try expectField(r0.value, "point", "control");
    try expectField(r0.value, "event", "grant");
    try expectField(r0.value, "verdict", "allow");
    try expectField(r0.value, "reason", "owner_grant");
    try expectField(r0.value, "host", "API.example.com");
    var pid_buf: [32]u8 = undefined;
    const want_prefix = try std.fmt.bufPrint(&pid_buf, "pid={d} for 600s until ", .{std.os.linux.getpid()});
    try testing.expect(std.mem.startsWith(u8, r0.value.object.get("detail").?.string, want_prefix));
    var r1 = try h.receiptAt(1);
    defer r1.deinit();
    try expectField(r1.value, "event", "revoke");
    try testing.expect(std.mem.endsWith(u8, r1.value.object.get("detail").?.string, " removed"));
    var r2 = try h.receiptAt(2);
    defer r2.deinit();
    try testing.expect(std.mem.endsWith(u8, r2.value.object.get("detail").?.string, " not_found"));
}

test "requests are parsed strictly and bounded" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"op\":\"grant\",\"host\":\"a.test\",\"for_s\":0}", "invalid_duration" },
        .{ "{\"op\":\"grant\",\"host\":\"a.test\",\"for_s\":3601}", "invalid_duration" },
        .{ "{\"op\":\"grant\",\"host\":\"a.test\"}", "invalid_duration" },
        .{ "{\"op\":\"grant\",\"host\":\"10.0.0.1\",\"for_s\":60}", "invalid_host" },
        .{ "{\"op\":\"grant\",\"host\":\"*\",\"for_s\":60}", "invalid_host" },
        .{ "{\"op\":\"grant\",\"host\":\"a.test\",\"for_s\":60,\"scope\":\"other\"}", "bad_request" },
        .{ "{\"op\":\"revoke\",\"host\":\"a.test\",\"for_s\":60}", "bad_request" },
        .{ "{\"op\":\"allow-all\",\"host\":\"a.test\"}", "bad_request" },
        .{ "not json", "bad_request" },
    };
    var rule_buf: [300]u8 = undefined;
    for (cases, 0..) |c, i| {
        const reply = try control.send(testing.allocator, h.io, h.dir, c[0]);
        defer reply.deinit();
        try testing.expect(!reply.value.ok);
        try testing.expectEqualStrings(c[1], reply.value.@"error".?);
        var r = try h.receiptAt(i);
        defer r.deinit();
        try expectField(r.value, "verdict", "deny");
        try expectField(r.value, "reason", c[1]);
    }
    try testing.expect(h.grants.check(h.io, "a.test", &rule_buf) == null);
}

test "the socket is 0600, a stale file is replaced, and stop removes it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = control.socket_name, .data = "stale" });
    var log = try receipt.Log.open(io, tmp.dir, "r.jsonl", "s-test0007", "000000000000");
    defer log.close();
    var grants: Grants = .init(testing.allocator);
    defer grants.deinit();

    const s = try control.Server.start(testing.allocator, io, dir, &grants, &log);
    const st = try tmp.dir.statFile(io, control.socket_name, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    try testing.expectEqual(Io.File.Kind.unix_domain_socket, st.kind);
    s.stop();
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, control.socket_name, .{}));
}

test "peerCred reports this process's uid and pid for a local peer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ h.dir, control.socket_name });
    const addr = try net.UnixAddress.init(path);
    const stream = try addr.connect(h.io);
    defer stream.close(h.io);
    const cred = control.peerCred(stream.socket.handle);
    try testing.expect(cred != null);
    try testing.expectEqual(h.server.uid, cred.?.uid);
    try testing.expectEqual(@as(?i32, std.os.linux.getpid()), cred.?.pid);
}

test "parseDuration" {
    try testing.expectEqual(@as(?u32, 600), control.parseDuration("10m"));
    try testing.expectEqual(@as(?u32, 90), control.parseDuration("90s"));
    try testing.expectEqual(@as(?u32, 3600), control.parseDuration("1h"));
    try testing.expectEqual(@as(?u32, 45), control.parseDuration("45"));
    try testing.expectEqual(@as(?u32, null), control.parseDuration("10d"));
    try testing.expectEqual(@as(?u32, null), control.parseDuration("m"));
    try testing.expectEqual(@as(?u32, null), control.parseDuration(""));
}

test "a peer that never sends a full line is disconnected" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ h.dir, control.socket_name });
    const addr = try net.UnixAddress.init(path);
    const stream = try addr.connect(h.io);
    defer stream.close(h.io);
    var wbuf: [64]u8 = undefined;
    var w = stream.writer(h.io, &wbuf);
    try w.interface.writeAll("{\"op\":\"gra");
    try w.interface.flush();
    // After its 5 s read deadline the server stops reading, records bad_request and answers it.
    var rbuf: [256]u8 = undefined;
    var r = stream.reader(h.io, &rbuf);
    const reply = try r.interface.takeDelimiterExclusive('\n');
    try testing.expectEqualStrings("{\"ok\":false,\"error\":\"bad_request\"}", reply);
    var rec = try h.receiptAt(0);
    defer rec.deinit();
    try expectField(rec.value, "reason", "bad_request");
}
