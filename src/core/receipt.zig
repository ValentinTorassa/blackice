//! Receipts: one JSON line per decision or scope event.
//!
//! A scope has a single writer, the blackice process. Backends (for example the Linux helper) report their
//! events to it instead of writing the file, so lines never interleave.
//!
//! Example line:
//!     {"ts":"2026-10-30T04:12:33.123Z","scope":"s-1a2b3c4d","policy":"cae35a3beb20","gen":1,"point":"proxy",
//!      "event":"connect","verdict":"deny","reason":"no_matching_rule","host":"attacker.test","port":443}

const std = @import("std");
const Io = std.Io;

/// Where the decision was enforced.
pub const Point = enum { proxy, kernel, relay, control };
pub const Verdict = enum { allow, deny };

pub const Entry = struct {
    /// connect | http | scope_start | scope_end | grant | relay_call | kernel_drop | warning
    event: []const u8,
    point: Point,
    verdict: ?Verdict = null,
    /// A stable reason code (see policy.Reason) or a short error name.
    reason: ?[]const u8 = null,
    /// The policy entry that decided, as written in the file.
    rule: ?[]const u8 = null,
    host: ?[]const u8 = null,
    ip: ?[]const u8 = null,
    port: ?u16 = null,
    detail: ?[]const u8 = null,
};

const Line = struct {
    ts: []const u8,
    scope: []const u8,
    policy: []const u8,
    gen: u32,
    point: Point,
    event: []const u8,
    verdict: ?Verdict,
    reason: ?[]const u8,
    rule: ?[]const u8,
    host: ?[]const u8,
    ip: ?[]const u8,
    port: ?u16,
    detail: ?[]const u8,
};

pub const Log = struct {
    io: Io,
    file: Io.File,
    offset: u64,
    mutex: Io.Mutex = .init,
    scope: []const u8,
    policy_id: []const u8,
    generation: u32 = 1,
    written: u64 = 0,
    /// Lines that could not be written. Reported in scope_end, so a gap in the log is visible.
    failures: u64 = 0,

    /// Opens (or creates) the receipts file and appends to it.
    pub fn open(io: Io, dir: Io.Dir, sub_path: []const u8, scope: []const u8, policy_id: []const u8) !Log {
        const file = try dir.createFile(io, sub_path, .{ .truncate = false });
        errdefer file.close(io);
        return .{ .io = io, .file = file, .offset = try file.length(io), .scope = scope, .policy_id = policy_id };
    }

    pub fn close(log: *Log) void {
        log.file.close(log.io);
    }

    pub fn write(log: *Log, e: Entry) void {
        var ts_buf: [32]u8 = undefined;
        const line: Line = .{
            .ts = formatTimestamp(&ts_buf, Io.Clock.real.now(log.io)),
            .scope = log.scope,
            .policy = log.policy_id,
            .gen = log.generation,
            .point = e.point,
            .event = e.event,
            .verdict = e.verdict,
            .reason = e.reason,
            .rule = e.rule,
            .host = e.host,
            .ip = e.ip,
            .port = e.port,
            .detail = e.detail,
        };
        var buf: [4096]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        w.print("{f}\n", .{std.json.fmt(line, .{ .emit_null_optional_fields = false })}) catch {
            log.countFailure();
            return;
        };
        const bytes = w.buffered();
        log.mutex.lockUncancelable(log.io);
        defer log.mutex.unlock(log.io);
        log.file.writePositionalAll(log.io, bytes, log.offset) catch {
            log.failures += 1;
            return;
        };
        log.offset += bytes.len;
        log.written += 1;
    }

    fn countFailure(log: *Log) void {
        log.mutex.lockUncancelable(log.io);
        defer log.mutex.unlock(log.io);
        log.failures += 1;
    }
};

/// RFC 3339 in UTC with milliseconds, e.g. 2026-10-30T04:12:33.123Z.
pub fn formatTimestamp(buf: *[32]u8, t: Io.Timestamp) []const u8 {
    const ms = t.toMilliseconds();
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const milli: u64 = @intCast(@mod(ms, 1000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        milli,
    }) catch unreachable;
}

test formatTimestamp {
    var buf: [32]u8 = undefined;
    const t: Io.Timestamp = .{ .nanoseconds = 1761800000123 * std.time.ns_per_ms };
    try std.testing.expectEqualStrings("2025-10-30T04:53:20.123Z", formatTimestamp(&buf, t));
}

test "receipt lines are JSON with nulls omitted" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try Log.open(io, tmp.dir, "r.jsonl", "s-00000000", "abc123abc123");
    log.write(.{ .event = "connect", .point = .proxy, .verdict = .deny, .reason = "no_matching_rule", .host = "a\"b.test", .port = 443 });
    log.write(.{ .event = "scope_end", .point = .control });
    log.close();
    const bytes = try tmp.dir.readFileAlloc(io, "r.jsonl", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(bytes);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
    const first = it.next().?;
    try std.testing.expect(std.mem.find(u8, first, "\"verdict\":\"deny\"") != null);
    try std.testing.expect(std.mem.find(u8, first, "\"host\":\"a\\\"b.test\"") != null);
    const second = it.next().?;
    try std.testing.expect(std.mem.find(u8, second, "verdict") == null);
    try std.testing.expect(it.next() == null);
}
