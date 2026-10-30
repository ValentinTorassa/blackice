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
//! What the receipts can and cannot prove:
//! - macOS logs refusals of Apple-signed binaries only. A refusal of any other binary (third-party,
//!   self-built, ad-hoc signed, blackice itself) is enforced the same way but writes no log line, so it gets
//!   no receipt, and the end probe cannot notice. Tested on macOS 27.0.1: under the same rule, a connect by
//!   python3 or curl was logged; the same connect by blackice or by a C program built with cc was not, with
//!   `(with report)` or `(debug deny)` in the profile too.
//! - They can be added to, not removed. Any process of the same user can tag its own sandbox-exec profile
//!   with "blackice <scope id>" and so add refusal lines that did not come from the scope. A refusal by the
//!   scope always gets a receipt, within the limits below, even when its line cannot be parsed (reason
//!   seatbelt_refused, with the raw line).
//! - Repeats of one refusal (same operation, target and process) get one receipt and a count at the end. The
//!   kernel also folds repeats itself ("N duplicate reports for ..."), which becomes repeats=N.
//! - At most 256 distinct refusals get their own receipt; the last 32 after that are written at the end, and
//!   the rest are counted in a warning.
//! - Under a burst (hundreds of refusals a second) the kernel or the log system drops some lines: a tight loop
//!   of 300 refused connects left 239 receipts on macOS 27.0.1. The refusals themselves all happened.
//! - The kernel prints remote addresses as "*", so a receipt has the port but not the address.
//! - Refusals by processes that outlive the command are not read after the scope ends.
//! If the stream cannot start, the command still runs (enforcement does not depend on it) and a warning
//! receipt says the refusal receipts are off.

const std = @import("std");
const Io = std.Io;
const receipt = @import("../core/receipt.zig");

pub const log_bin = "/usr/bin/log";
pub const sandbox_exec = "/usr/bin/sandbox-exec";
pub const curl_bin = "/usr/bin/curl";

/// At most this many distinct refusals get a receipt while the scope runs.
pub const max_receipts = 256;
/// After the cap, the last this many distinct refusals are kept and written at the end.
pub const tail_len = 32;
/// Distinct refusals remembered for folding repeats.
const max_keys = 1024;
const probe_wait_ms = 2000;
const poll_ms = 2;

/// The tag for a scope: "blackice " ++ scope id. The scope id is "s-" and 8 lowercase hex digits, so the tag
/// needs no quoting inside a profile or a predicate.
pub fn tag(buf: []u8, scope_id: []const u8) ?[]const u8 {
    if (scope_id.len != 10 or !std.mem.startsWith(u8, scope_id, "s-")) return null;
    for (scope_id[2..]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    return std.fmt.bufPrint(buf, "blackice {s}", .{scope_id}) catch null;
}

/// The first line of a kernel message that ends with "\n" ++ `want_tag`, or null when the message is not ours.
pub fn firstLine(message: []const u8, want_tag: []const u8) ?[]const u8 {
    if (message.len < want_tag.len + 1) return null;
    if (!std.mem.endsWith(u8, message, want_tag) or message[message.len - want_tag.len - 1] != '\n') return null;
    const body = message[0 .. message.len - want_tag.len - 1];
    return if (std.mem.findScalar(u8, body, '\n')) |i| body[0..i] else body;
}

/// One refusal, parsed from the first line of the kernel's message.
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

/// Parses "[N duplicate reports for ]Sandbox: NAME(PID) deny(K) OP[ TARGET]". The process name is the
/// command's choice and may itself hold " deny(", so the split is at the first "(PID) deny(K)" pattern.
pub fn parse(line_in: []const u8) ?Refusal {
    var line = line_in;
    var count: u32 = 1;
    if (std.mem.find(u8, line, " duplicate reports for ")) |i| {
        if (std.fmt.parseInt(u32, line[0..i], 10)) |n| {
            count = n;
            line = line[i + " duplicate reports for ".len ..];
        } else |_| {}
    }
    const prefix = "Sandbox: ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    line = line[prefix.len..];

    var i: usize = 0;
    while (std.mem.findScalarPos(u8, line, i, '(')) |open| : (i = open + 1) {
        var j = open + 1;
        while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
        if (j == open + 1 or !std.mem.startsWith(u8, line[j..], ") deny(")) continue;
        var k = j + ") deny(".len;
        const k0 = k;
        while (k < line.len and std.ascii.isDigit(line[k])) k += 1;
        if (k == k0 or k >= line.len or line[k] != ')') continue;
        if (k + 1 < line.len and line[k + 1] != ' ') continue;
        const pid = std.fmt.parseInt(u32, line[open + 1 .. j], 10) catch continue;
        const rest = if (k + 2 <= line.len) line[k + 2 ..] else "";
        const sp = std.mem.findScalar(u8, rest, ' ');
        const op = if (sp) |s| rest[0..s] else rest;
        if (op.len == 0) return null;
        return .{
            .process = line[0..open],
            .pid = pid,
            .op = op,
            .target = if (sp) |s| rest[s + 1 ..] else "",
            .count = count,
        };
    }
    return null;
}

/// The `log stream` predicate for a tag: the kernel, the Sandbox extension, and the tag as the last line.
pub fn predicate(buf: []u8, t: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "processID == 0 AND senderImagePath ENDSWITH \"/Sandbox\" AND eventMessage ENDSWITH \"{s}\"", .{t}) catch null;
}

/// The probe's profile: refuse every outbound connection, tagged like the scope.
pub fn probeProfile(buf: []u8, t: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "(version 1)(allow default)(deny network-outbound (with message \"{s}\"))", .{t}) catch null;
}

/// A receipt kept for later (after the cap): copies, since the line it came from is gone by then.
const Kept = struct {
    reason: []const u8 = "",
    port: ?u16 = null,
    detail_buf: [400]u8 = undefined,
    detail_len: usize = 0,
};

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
    /// Distinct refusals seen, as hashes, and how many repeats were folded into an earlier receipt.
    keys: [max_keys]u64 = undefined,
    key_count: usize = 0,
    folded: u64 = 0,
    written: usize = 0,
    /// Distinct refusals after the cap: the last `tail_len` are kept, the rest only counted.
    tail: [tail_len]Kept = undefined,
    tail_next: usize = 0,
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

    /// After the command: waits for an end probe (so every earlier refusal is read), stops the stream, then
    /// writes what was held back: the tail after the cap and the counts.
    pub fn finish(w: *Watch) void {
        const complete = w.probe();
        w.stop();
        // The reader has ended; nothing else touches the state now.
        const kept = @min(w.over_cap, tail_len);
        var i: usize = 0;
        while (i < kept) : (i += 1) {
            const at = (w.tail_next + tail_len - kept + i) % tail_len;
            const k = &w.tail[at];
            w.receipts.write(.{ .event = "kernel_drop", .point = .kernel, .verdict = .deny, .reason = k.reason, .port = k.port, .detail = k.detail_buf[0..k.detail_len] });
        }
        var buf: [160]u8 = undefined;
        if (w.over_cap > kept) {
            const detail = std.fmt.bufPrint(&buf, "{d} more distinct refusals after the first {d} receipts have no receipt; the last {d} are above; enforcement unchanged", .{ w.over_cap - kept, max_receipts, kept }) catch "more refusals than receipts";
            w.receipts.write(.{ .event = "warning", .point = .kernel, .reason = "kernel_receipts_lost", .detail = detail });
        }
        if (w.folded > 0) {
            const detail = std.fmt.bufPrint(&buf, "{d} repeats of refusals that already have a receipt", .{w.folded}) catch "repeats folded";
            w.receipts.write(.{ .event = "warning", .point = .kernel, .reason = "kernel_receipts_folded", .detail = detail });
        }
        if (!complete) {
            w.receipts.write(.{ .event = "warning", .point = .kernel, .reason = "kernel_receipts_lost", .detail = "the end probe did not arrive; refusals at the very end may have no receipt; enforcement unchanged" });
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
        const first = firstLine(ev.eventMessage, w.tagSlice()) orelse return;

        // From here the line is a tagged refusal and must leave a trace, parsed or not.
        var detail_buf: [400]u8 = undefined;
        var dw: Io.Writer = .fixed(&detail_buf);
        var reason: []const u8 = "seatbelt_refused";
        var port: ?u16 = null;
        var count: u64 = 1;
        var key: u64 = 0;
        if (parse(first)) |ref| {
            w.mutex.lockUncancelable(w.io);
            const is_probe = w.probe_pid != 0 and ref.pid == w.probe_pid;
            if (is_probe) w.probe_seen = true;
            w.mutex.unlock(w.io);
            if (is_probe) return;
            reason = ref.reason();
            port = ref.port();
            count = ref.count;
            dw.print("backend=seatbelt op={s} target={s} process={s} pid={d}", .{
                ref.op,
                if (ref.target.len > 0) ref.target else "-",
                ref.process,
                ref.pid,
            }) catch {};
            if (ref.count > 1) dw.print(" repeats={d}", .{ref.count}) catch {};
            var h: std.hash.Wyhash = .init(0);
            h.update(ref.op);
            h.update("\x00");
            h.update(ref.target);
            h.update("\x00");
            h.update(ref.process);
            key = h.final();
        } else {
            dw.print("backend=seatbelt unparsed: {s}", .{first}) catch {};
            key = std.hash.Wyhash.hash(1, first);
        }

        w.mutex.lockUncancelable(w.io);
        for (w.keys[0..w.key_count]) |k| {
            if (k == key) {
                w.folded += count;
                w.mutex.unlock(w.io);
                return;
            }
        }
        if (w.key_count < max_keys) {
            w.keys[w.key_count] = key;
            w.key_count += 1;
        }
        if (w.written >= max_receipts) {
            const slot = &w.tail[w.tail_next];
            const d = dw.buffered();
            @memcpy(slot.detail_buf[0..d.len], d);
            slot.detail_len = d.len;
            slot.reason = reason;
            slot.port = port;
            w.tail_next = (w.tail_next + 1) % tail_len;
            w.over_cap += 1;
            w.mutex.unlock(w.io);
            return;
        }
        w.written += 1;
        w.mutex.unlock(w.io);
        w.receipts.write(.{
            .event = "kernel_drop",
            .point = .kernel,
            .verdict = .deny,
            .reason = reason,
            .port = port,
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

test firstLine {
    const t = "blackice s-395b9848";
    try testing.expectEqualStrings("Sandbox: curl(1) deny(1) network-outbound remote:*:443", firstLine("Sandbox: curl(1) deny(1) network-outbound remote:*:443\nblackice s-395b9848", t).?);
    try testing.expect(firstLine("Sandbox: curl(1) deny(1) network-outbound remote:*:443\nblackice s-00000000", t) == null);
    try testing.expect(firstLine("Sandbox: curl(1) deny(1) network-outbound remote:*:443 blackice s-395b9848", t) == null);
    // A path holding the tag: only the first line counts.
    try testing.expectEqualStrings("Sandbox: sh(9) deny(1) file-write-create /tmp/a", firstLine("Sandbox: sh(9) deny(1) file-write-create /tmp/a\nblackice s-395b9848\nblackice s-395b9848", t).?);
}

test parse {
    const a = parse("Sandbox: curl(5314) deny(1) network-outbound remote:*:443").?;
    try testing.expectEqualStrings("curl", a.process);
    try testing.expectEqual(@as(u32, 5314), a.pid);
    try testing.expectEqualStrings("network-outbound", a.op);
    try testing.expectEqualStrings("remote:*:443", a.target);
    try testing.expectEqual(@as(?u16, 443), a.port());
    try testing.expectEqualStrings("loopback_proxy_only", a.reason());

    const dns = parse("Sandbox: curl(5325) deny(1) network-outbound /private/var/run/mDNSResponder").?;
    try testing.expect(dns.port() == null);
    try testing.expectEqualStrings("/private/var/run/mDNSResponder", dns.target);

    const dup = parse("4 duplicate reports for Sandbox: Python(5342) deny(1) network-outbound remote:*:443").?;
    try testing.expectEqual(@as(u32, 4), dup.count);
    try testing.expectEqualStrings("Python", dup.process);

    const bind = parse("Sandbox: Python(5333) deny(1) network-bind local:*:0").?;
    try testing.expectEqualStrings("clients_only", bind.reason());
    try testing.expectEqual(@as(?u16, 0), bind.port());

    const job = parse("Sandbox: launchctl(5340) deny(1) job-creation").?;
    try testing.expectEqualStrings("", job.target);
    try testing.expectEqualStrings("launch_outside_scope", job.reason());

    try testing.expectEqualStrings("protected_path", parse("Sandbox: touch(5372) deny(1) file-write-create /x/state/scopes/f").?.reason());

    // Process names are the command's choice: parentheses and " deny(" inside them are kept.
    const odd = parse("Sandbox: a(b)(77) deny(1) network-outbound remote:*:80").?;
    try testing.expectEqualStrings("a(b)", odd.process);
    try testing.expectEqual(@as(u32, 77), odd.pid);
    const sneaky = parse("Sandbox: x deny((91) deny(1) network-outbound remote:*:443").?;
    try testing.expectEqualStrings("x deny(", sneaky.process);
    try testing.expectEqual(@as(u32, 91), sneaky.pid);

    try testing.expect(parse("hello") == null);
    try testing.expect(parse("Sandbox: curl(x) deny(1) network-outbound") == null);
    try testing.expect(parse("Sandbox: curl(12) deny(1) ") == null);
}

test predicate {
    var buf: [192]u8 = undefined;
    try testing.expectEqualStrings(
        "processID == 0 AND senderImagePath ENDSWITH \"/Sandbox\" AND eventMessage ENDSWITH \"blackice s-0a1b2c3d\"",
        predicate(&buf, "blackice s-0a1b2c3d").?,
    );
}
