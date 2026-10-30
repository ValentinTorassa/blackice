//! Receipts for Seatbelt refusals (macOS).
//!
//! Every deny rule of a scope's profile carries `(with message "blackice <scope id>")`. When the kernel's
//! Sandbox extension refuses an operation it logs a line such as
//!     Sandbox: curl(4963) deny(1) network-outbound remote:*:443
//!     blackice s-1a2b3c4d
//! and the tag is the last line. While the command runs, blackice reads those lines back with `log stream`,
//! filtered to messages the kernel (process 0) sent from the Sandbox extension and ending with the tag, and
//! writes one kernel_drop receipt per refusal. No privileges are needed.
//!
//! Start and end: a probe (a tiny sandboxed curl whose loopback connection the probe profile refuses, tagged
//! the same way) runs before the command starts and again after it ends. Seeing the first probe's line proves
//! the stream is live (a backend_armed receipt); seeing the last one proves every earlier refusal has been
//! read, since the kernel delivers its lines in order. Probe lines are recognised by the probe's pid.
//!
//! Best effort, and stated in the receipts: the kernel folds repeated refusals by one process into
//! "N duplicate reports for ...", which becomes one receipt with the count; it prints remote addresses as
//! "*", so a receipt has the port but not the address; refusals by processes that outlive the command are
//! not read after the scope ends. If the stream cannot start, the command still runs (enforcement does not
//! depend on it) and a warning receipt says the refusal receipts are off.

const std = @import("std");
const Io = std.Io;
const receipt = @import("../core/receipt.zig");

pub const log_bin = "/usr/bin/log";
pub const sandbox_exec = "/usr/bin/sandbox-exec";
pub const curl_bin = "/usr/bin/curl";

/// At most this many refusal receipts per scope; the rest are counted in one warning.
pub const max_receipts = 256;
const probe_wait_ms = 2000;
const poll_ms = 2;

/// The tag for a scope: "blackice " ++ scope id. The scope id is "s-" and 8 lowercase hex digits, so the tag
/// needs no quoting inside a profile or a predicate.
pub fn tag(buf: []u8, scope_id: []const u8) ?[]const u8 {
    if (scope_id.len != 10 or !std.mem.startsWith(u8, scope_id, "s-")) return null;
    for (scope_id[2..]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    return std.fmt.bufPrint(buf, "blackice {s}", .{scope_id}) catch null;
}

/// One refusal, parsed from the kernel's message.
pub const Refusal = struct {
    process: []const u8,
    pid: u32,
    /// Seatbelt's operation name, such as network-outbound or file-write-create.
    op: []const u8,
    /// What was refused, as the kernel prints it ("remote:*:443", a path), or "".
    target: []const u8,
    /// 1, or the count of a "N duplicate reports for" line.
    count: u32,

    /// The port of a network target ("remote:*:443", "local:*:0").
    pub fn port(r: Refusal) ?u16 {
        if (!std.mem.startsWith(u8, r.target, "remote:") and !std.mem.startsWith(u8, r.target, "local:")) return null;
        const i = std.mem.findScalarLast(u8, r.target, ':') orelse return null;
        return std.fmt.parseInt(u16, r.target[i + 1 ..], 10) catch null;
    }

    /// A stable reason code, by the rule family that refused.
    pub fn reason(r: Refusal) []const u8 {
        if (std.mem.eql(u8, r.op, "network-outbound")) return "loopback_proxy_only";
        if (std.mem.startsWith(u8, r.op, "network-")) return "clients_only";
        if (std.mem.startsWith(u8, r.op, "file-write")) return "protected_path";
        if (std.mem.eql(u8, r.op, "job-creation") or std.mem.eql(u8, r.op, "lsopen") or std.mem.eql(u8, r.op, "appleevent-send"))
            return "launch_outside_scope";
        return "seatbelt_refused";
    }
};

/// Parses a kernel Sandbox message that ends with "\n" ++ `want_tag`. Null for anything else.
pub fn parse(message: []const u8, want_tag: []const u8) ?Refusal {
    if (message.len < want_tag.len + 1) return null;
    if (!std.mem.endsWith(u8, message, want_tag) or message[message.len - want_tag.len - 1] != '\n') return null;
    var line = message[0 .. message.len - want_tag.len - 1];
    if (std.mem.findScalar(u8, line, '\n')) |i| line = line[0..i];

    var count: u32 = 1;
    if (std.mem.find(u8, line, " duplicate reports for ")) |i| {
        count = std.fmt.parseInt(u32, line[0..i], 10) catch return null;
        line = line[i + " duplicate reports for ".len ..];
    }
    const prefix = "Sandbox: ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    line = line[prefix.len..];

    const deny_at = std.mem.find(u8, line, " deny(") orelse return null;
    const who = line[0..deny_at];
    const open = std.mem.findScalarLast(u8, who, '(') orelse return null;
    if (who.len < open + 2 or who[who.len - 1] != ')') return null;
    const pid = std.fmt.parseInt(u32, who[open + 1 .. who.len - 1], 10) catch return null;

    var rest = line[deny_at + " deny(".len ..];
    const close = std.mem.find(u8, rest, ") ") orelse return null;
    rest = rest[close + 2 ..];
    const sp = std.mem.findScalar(u8, rest, ' ');
    const op = if (sp) |i| rest[0..i] else rest;
    if (op.len == 0) return null;
    return .{
        .process = who[0..open],
        .pid = pid,
        .op = op,
        .target = if (sp) |i| rest[i + 1 ..] else "",
        .count = count,
    };
}

/// The `log stream` predicate for a tag: the kernel, the Sandbox extension, and the tag as the last line.
pub fn predicate(buf: []u8, t: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "processID == 0 AND senderImagePath ENDSWITH \"/Sandbox\" AND eventMessage ENDSWITH \"{s}\"", .{t}) catch null;
}

/// The probe's profile: refuse every outbound connection, tagged like the scope.
pub fn probeProfile(buf: []u8, t: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "(version 1)(allow default)(deny network-outbound (with message \"{s}\"))", .{t}) catch null;
}

pub const Watch = struct {
    gpa: std.mem.Allocator,
    io: Io,
    receipts: *receipt.Log,
    tag_buf: [32]u8 = undefined,
    tag_len: usize = 0,
    child: std.process.Child,
    reader: Io.Future(void),
    empty_env: std.process.Environ.Map,

    mutex: Io.Mutex = .init,
    /// The pid of the probe in flight, 0 when none.
    probe_pid: u32 = 0,
    probe_seen: bool = false,
    written: usize = 0,
    over_cap: u64 = 0,

    fn tagSlice(w: *const Watch) []const u8 {
        return w.tag_buf[0..w.tag_len];
    }

    /// Starts the stream and waits for the first probe. Null when the receipts cannot be had; the reason is
    /// already in a warning receipt.
    pub fn start(gpa: std.mem.Allocator, io: Io, scope_id: []const u8, receipts: *receipt.Log) ?*Watch {
        var tag_buf: [32]u8 = undefined;
        const t = tag(&tag_buf, scope_id) orelse return warn(receipts, "invalid scope id");
        const w = gpa.create(Watch) catch return warn(receipts, "OutOfMemory");
        w.* = .{
            .gpa = gpa,
            .io = io,
            .receipts = receipts,
            .tag_buf = tag_buf,
            .tag_len = t.len,
            .child = undefined,
            .reader = undefined,
            .empty_env = .init(gpa),
        };
        var pred_buf: [192]u8 = undefined;
        const pred = predicate(&pred_buf, w.tagSlice()).?;
        w.child = std.process.spawn(io, .{
            .argv = &.{ log_bin, "stream", "--style", "ndjson", "--predicate", pred },
            .environ_map = &w.empty_env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| {
            w.empty_env.deinit();
            gpa.destroy(w);
            return warn(receipts, @errorName(err));
        };
        // The reader owns the pipe, so killing `log` at the end cannot close it under the reader.
        const out = w.child.stdout.?;
        w.child.stdout = null;
        w.reader = io.concurrent(readLoop, .{ w, out }) catch |err| {
            out.close(io);
            w.child.kill(io);
            w.empty_env.deinit();
            gpa.destroy(w);
            return warn(receipts, @errorName(err));
        };
        if (!w.probe()) {
            w.stop();
            w.destroy();
            return warn(receipts, "the stream did not deliver the start probe");
        }
        receipts.write(.{ .event = "backend_armed", .point = .kernel, .reason = "macos_seatbelt", .detail = "profile applied before the command runs; refusal receipts from the kernel log" });
        return w;
    }

    fn warn(receipts: *receipt.Log, why: []const u8) ?*Watch {
        var buf: [160]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s}; Seatbelt still refuses, without receipts", .{why}) catch why;
        receipts.write(.{ .event = "warning", .point = .kernel, .reason = "kernel_receipts_off", .detail = detail });
        return null;
    }

    /// After the command: waits for an end probe (so every earlier refusal is read), then stops the stream.
    pub fn finish(w: *Watch) void {
        const complete = w.probe();
        w.stop();
        w.mutex.lockUncancelable(w.io);
        const over = w.over_cap;
        w.mutex.unlock(w.io);
        if (!complete) {
            w.receipts.write(.{ .event = "warning", .point = .kernel, .reason = "kernel_receipts_lost", .detail = "the end probe did not arrive; refusals at the very end may have no receipt; enforcement unchanged" });
        }
        if (over > 0) {
            var buf: [128]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "{d} more refusals after the first {d} receipts; enforcement unchanged", .{ over, max_receipts }) catch "more refusals than receipts";
            w.receipts.write(.{ .event = "warning", .point = .kernel, .reason = "kernel_receipts_lost", .detail = detail });
        }
        w.destroy();
    }

    fn stop(w: *Watch) void {
        w.child.kill(w.io);
        w.reader.await(w.io);
    }

    fn destroy(w: *Watch) void {
        w.empty_env.deinit();
        w.gpa.destroy(w);
    }

    /// Runs one probe and waits until its line arrives. False on timeout or if the probe cannot run.
    fn probe(w: *Watch) bool {
        const io = w.io;
        var prof_buf: [160]u8 = undefined;
        const prof = probeProfile(&prof_buf, w.tagSlice()).?;
        var child = std.process.spawn(io, .{
            .argv = &.{ sandbox_exec, "-p", prof, curl_bin, "-s", "-o", "/dev/null", "-m", "2", "http://127.0.0.1:9/" },
            .environ_map = &w.empty_env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return false;
        const pid: u32 = @intCast(child.id.?);
        w.mutex.lockUncancelable(io);
        w.probe_pid = pid;
        w.probe_seen = false;
        w.mutex.unlock(io);
        _ = child.wait(io) catch {};

        var waited: u32 = 0;
        while (waited < probe_wait_ms) : (waited += poll_ms) {
            w.mutex.lockUncancelable(io);
            const seen = w.probe_seen;
            w.mutex.unlock(io);
            if (seen) break;
            io.sleep(.fromMilliseconds(poll_ms), .awake) catch break;
        }
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        const seen = w.probe_seen;
        w.probe_pid = 0;
        return seen;
    }

    fn readLoop(w: *Watch, out: Io.File) void {
        const io = w.io;
        defer out.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var fr = out.reader(io, &buf);
        const r = &fr.interface;
        var arena_state: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena_state.deinit();
        while (true) {
            const line = r.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    _ = r.discardDelimiterInclusive('\n') catch return;
                    continue;
                },
                else => return,
            } orelse return;
            _ = arena_state.reset(.retain_capacity);
            w.handleLine(arena_state.allocator(), line);
        }
    }

    const Event = struct {
        eventMessage: []const u8 = "",
        processID: i64 = -1,
        senderImagePath: []const u8 = "",
    };

    fn handleLine(w: *Watch, arena: std.mem.Allocator, line: []const u8) void {
        if (line.len == 0 or line[0] != '{') return; // the "Filtering the log data ..." header
        const ev = std.json.parseFromSliceLeaky(Event, arena, line, .{ .ignore_unknown_fields = true }) catch return;
        // The predicate already asks for this; checked again so a change in `log` cannot widen it.
        if (ev.processID != 0 or !std.mem.endsWith(u8, ev.senderImagePath, "/Sandbox")) return;
        const ref = parse(ev.eventMessage, w.tagSlice()) orelse return;

        const io = w.io;
        w.mutex.lockUncancelable(io);
        if (w.probe_pid != 0 and ref.pid == w.probe_pid) {
            w.probe_seen = true;
            w.mutex.unlock(io);
            return;
        }
        if (w.written >= max_receipts) {
            w.over_cap += ref.count;
            w.mutex.unlock(io);
            return;
        }
        w.written += 1;
        w.mutex.unlock(io);

        var detail_buf: [512]u8 = undefined;
        var dw: Io.Writer = .fixed(&detail_buf);
        dw.print("backend=seatbelt op={s} target={s} process={s} pid={d}", .{
            ref.op,
            if (ref.target.len > 0) ref.target else "-",
            ref.process,
            ref.pid,
        }) catch {};
        if (ref.count > 1) dw.print(" repeats={d}", .{ref.count}) catch {};
        w.receipts.write(.{
            .event = "kernel_drop",
            .point = .kernel,
            .verdict = .deny,
            .reason = ref.reason(),
            .port = ref.port(),
            .detail = dw.buffered(),
        });
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test tag {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("blackice s-0a1b2c3d", tag(&buf, "s-0a1b2c3d").?);
    try testing.expect(tag(&buf, "s-0A1B2C3D") == null);
    try testing.expect(tag(&buf, "s-0a1b2c3d\"") == null);
    try testing.expect(tag(&buf, "x-0a1b2c3d") == null);
}

test parse {
    const t = "blackice s-395b9848";
    const a = parse("Sandbox: curl(5314) deny(1) network-outbound remote:*:443\nblackice s-395b9848", t).?;
    try testing.expectEqualStrings("curl", a.process);
    try testing.expectEqual(@as(u32, 5314), a.pid);
    try testing.expectEqualStrings("network-outbound", a.op);
    try testing.expectEqualStrings("remote:*:443", a.target);
    try testing.expectEqual(@as(?u16, 443), a.port());
    try testing.expectEqualStrings("loopback_proxy_only", a.reason());

    const dns = parse("Sandbox: curl(5325) deny(1) network-outbound /private/var/run/mDNSResponder\nblackice s-395b9848", t).?;
    try testing.expect(dns.port() == null);
    try testing.expectEqualStrings("/private/var/run/mDNSResponder", dns.target);

    const dup = parse("4 duplicate reports for Sandbox: Python(5342) deny(1) network-outbound remote:*:443\nblackice s-395b9848", t).?;
    try testing.expectEqual(@as(u32, 4), dup.count);
    try testing.expectEqualStrings("Python", dup.process);

    const bind = parse("Sandbox: Python(5333) deny(1) network-bind local:*:0\nblackice s-395b9848", t).?;
    try testing.expectEqualStrings("clients_only", bind.reason());
    try testing.expectEqual(@as(?u16, 0), bind.port());

    const job = parse("Sandbox: launchctl(5340) deny(1) job-creation\nblackice s-395b9848", t).?;
    try testing.expectEqualStrings("", job.target);
    try testing.expectEqualStrings("launch_outside_scope", job.reason());

    const file = parse("Sandbox: touch(5372) deny(1) file-write-create /private/tmp/x/state/scopes/forged\nblackice s-395b9848", t).?;
    try testing.expectEqualStrings("protected_path", file.reason());

    // A process name with parentheses keeps them.
    const odd = parse("Sandbox: a(b)(77) deny(1) network-outbound remote:*:80\nblackice s-395b9848", t).?;
    try testing.expectEqualStrings("a(b)", odd.process);
    try testing.expectEqual(@as(u32, 77), odd.pid);

    // Not ours, or not the kernel's format.
    try testing.expect(parse("Sandbox: curl(1) deny(1) network-outbound remote:*:443\nblackice s-00000000", t) == null);
    try testing.expect(parse("Sandbox: curl(1) deny(1) network-outbound remote:*:443 blackice s-395b9848", t) == null);
    try testing.expect(parse("hello\nblackice s-395b9848", t) == null);
    try testing.expect(parse("Sandbox: curl(x) deny(1) network-outbound\nblackice s-395b9848", t) == null);
    // A path holding the tag is still parsed from the first line only.
    const path = parse("Sandbox: sh(9) deny(1) file-write-create /tmp/a\nblackice s-395b9848\nblackice s-395b9848", t).?;
    try testing.expectEqualStrings("/tmp/a", path.target);
}

test predicate {
    var buf: [192]u8 = undefined;
    try testing.expectEqualStrings(
        "processID == 0 AND senderImagePath ENDSWITH \"/Sandbox\" AND eventMessage ENDSWITH \"blackice s-0a1b2c3d\"",
        predicate(&buf, "blackice s-0a1b2c3d").?,
    );
}
