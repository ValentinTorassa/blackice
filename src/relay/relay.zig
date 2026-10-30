//! The scope's model relay: an OpenAI-compatible endpoint that keeps the provider key out of the scope.
//!
//! It runs outside the scope and listens on 127.0.0.1:<random>. A tool inside the scope (fx in the fallback
//! mode, where all of fx runs in one scope) is configured with a provider at http://127.0.0.1:<port>/v1 and
//! auth "none". The relay forwards each allowed call to the upstream (by default the Vercel AI Gateway) with
//! the key added there, so the key never enters the scope: not in its environment, its files or its memory.
//!
//! Endpoints:
//!   POST /v1/chat/completions   forwarded when the body's "model" is on the allow list; streamed back as it
//!                               arrives, so server-sent events (stream: true) work
//!   GET  /v1/models             answered locally with the allow list
//!   anything else               404
//!
//! Limits per relay (one relay per scope): model allow list, request body size, number of forwarded calls.
//! Only Content-Type, Accept-Encoding: identity, User-Agent and the key's Authorization header go upstream;
//! the caller's own headers, including any Authorization, are dropped. Redirects are not followed.
//!
//! One receipt per call, point "relay", event "relay_call". Reason codes:
//!   model_allowed      forwarded (rule = the model; detail = status, bytes in and out, stream)
//!   model_not_allowed  the model is not on the allow list (403)
//!   request_too_large  the body is over the size cap (413)
//!   request_cap        the scope used up its calls (429)
//!   bad_request        the body is not JSON with a string "model" (400)
//!   unknown_endpoint   not one of the endpoints above (404)
//!   upstream_error     the upstream could not be reached or failed mid-call (502 when nothing was sent yet)
//!   models_list        GET /v1/models, answered locally
//! The key never appears in receipts, errors or logs.
//!
//! Declared limits (v0):
//! - The relay bounds who pays and how much, not what is said: an allowed call can carry any content to the
//!   allowed provider.
//! - Spend is capped by call count, not by tokens.
//! - Every process that can reach the port can use the relay; no per-scope credential yet (TODO).
//! - The key lives in this process's memory; `hardenProcess` keeps same-user debuggers and core dumps out.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const http = std.http;
const receipt = @import("../core/receipt.zig");

pub const default_upstream = "https://ai-gateway.vercel.sh/v1";

pub const Config = struct {
    /// Base URL of the upstream OpenAI-compatible API, ending in the version (no trailing slash).
    /// https, or http to a loopback address (tests and local stand-ins).
    upstream: []const u8 = default_upstream,
    /// Models the scope may call, compared exactly (for example "anthropic/claude-sonnet-4.5").
    /// Empty refuses every call.
    models: []const []const u8 = &.{},
    /// Largest request body.
    max_request_bytes: usize = 1 << 20,
    /// Calls forwarded upstream over the relay's lifetime.
    max_requests: u32 = 100,
    /// Connections served at the same time.
    max_connections: u32 = 32,
};

pub const KeyError = error{ KeyMissing, KeyTooLong, KeyInvalid, ReadFailed };

/// Reads the provider key from `file` (normally stdin) into `buf`. Surrounding whitespace is trimmed; the key
/// itself must be printable ASCII without spaces, so it cannot inject a header. The caller zeroes `buf` with
/// `std.crypto.secureZero` once the relay has started (the relay keeps its own copy).
pub fn readKey(io: Io, file: Io.File, buf: []u8) KeyError![]u8 {
    var rbuf: [256]u8 = undefined;
    var r = file.readerStreaming(io, &rbuf);
    defer std.crypto.secureZero(u8, &rbuf);
    const n = r.interface.readSliceShort(buf) catch return error.ReadFailed;
    if (n == buf.len) {
        // Anything after a full buffer, other than whitespace, means the key did not fit.
        while (true) {
            const b = r.interface.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
            };
            if (!std.ascii.isWhitespace(b)) return error.KeyTooLong;
        }
    }
    const key = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (key.len == 0) return error.KeyMissing;
    for (key) |ch| if (ch <= ' ' or ch >= 0x7f) return error.KeyInvalid;
    // Move the key to the start of buf so the caller can zero exactly buf.
    const start = @intFromPtr(key.ptr) - @intFromPtr(buf.ptr);
    std.mem.copyForwards(u8, buf[0..key.len], key);
    if (start > 0) @memset(buf[key.len .. key.len + start], 0);
    return buf[0..key.len];
}

/// Keeps same-user debuggers and core dumps away from the key: PR_SET_DUMPABLE 0 on Linux, PT_DENY_ATTACH
/// on macOS. Process-wide and permanent. On Linux it also makes /proc/self owned by root until the next
/// execve, so call it after any setup that writes /proc/self (for example user-namespace id maps).
/// Returns false when the call failed or the OS has no equivalent.
pub fn hardenProcess() bool {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            const rc = linux.prctl(@backingInt(linux.PR.SET_DUMPABLE), 0, 0, 0, 0);
            return linux.errno(rc) == .SUCCESS;
        },
        .macos => return std.c.ptrace(.DENY_ATTACH, 0, null, 0) == 0,
        else => return false,
    }
}

pub const Relay = struct {
    gpa: std.mem.Allocator,
    io: Io,
    config: Config,
    receipts: *receipt.Log,
    server: net.Server,
    /// The port the relay listens on, on 127.0.0.1.
    port: u16,
    client: http.Client,
    /// "Bearer <key>". Zeroed in stop().
    auth: []u8,
    chat_uri: std.Uri,
    chat_url: []u8,
    upstream_host: []u8,
    upstream_port: u16,
    group: Io.Group = .init,
    active: std.atomic.Value(u32) = .init(0),
    calls: std.atomic.Value(u32) = .init(0),

    pub const StartError = net.IpAddress.ListenError || Io.ConcurrentError ||
        error{ OutOfMemory, InvalidUpstream, KeyInvalid };

    /// Listens on 127.0.0.1:<random> and starts serving. `key` is copied; `config.models` and `receipts`
    /// must outlive the relay.
    pub fn start(gpa: std.mem.Allocator, io: Io, config: Config, key: []const u8, receipts: *receipt.Log) StartError!*Relay {
        if (key.len == 0) return error.KeyInvalid;
        for (key) |ch| if (ch <= ' ' or ch >= 0x7f) return error.KeyInvalid;

        const up = try parseUpstream(gpa, config.upstream);
        errdefer {
            gpa.free(up.chat_url);
            gpa.free(up.host);
        }

        const auth = try std.mem.concat(gpa, u8, &.{ "Bearer ", key });
        errdefer {
            std.crypto.secureZero(u8, auth);
            gpa.free(auth);
        }

        const r = try gpa.create(Relay);
        errdefer gpa.destroy(r);
        const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try addr.listen(io, .{});
        errdefer server.deinit(io);

        r.* = .{
            .gpa = gpa,
            .io = io,
            .config = config,
            .receipts = receipts,
            .server = server,
            .port = server.socket.address.getPort(),
            .client = .{ .allocator = gpa, .io = io },
            .auth = auth,
            .chat_uri = std.Uri.parse(up.chat_url) catch unreachable,
            .chat_url = up.chat_url,
            .upstream_host = up.host,
            .upstream_port = up.port,
        };
        // The relay must never route through a proxy from its own environment.
        r.client.http_proxy = null;
        r.client.https_proxy = null;
        try r.group.concurrent(io, acceptLoop, .{r});
        return r;
    }

    /// Stops serving, closes every connection, zeroes the key and frees the relay.
    pub fn stop(r: *Relay) void {
        const io = r.io;
        r.group.cancel(io);
        r.server.deinit(io);
        r.client.deinit();
        std.crypto.secureZero(u8, r.auth);
        r.gpa.free(r.auth);
        r.gpa.free(r.chat_url);
        r.gpa.free(r.upstream_host);
        r.gpa.destroy(r);
    }

    /// Calls forwarded so far.
    pub fn callCount(r: *const Relay) u32 {
        return r.calls.load(.monotonic);
    }

    fn acceptLoop(r: *Relay) Io.Cancelable!void {
        const io = r.io;
        while (true) {
            const stream = r.server.accept(io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.ConnectionAborted, error.WouldBlock => continue,
                error.SocketNotListening => return,
                else => {
                    r.receipts.write(.{ .event = "warning", .point = .relay, .reason = "accept_failed", .detail = @errorName(err) });
                    try io.sleep(.fromMilliseconds(100), .awake);
                    continue;
                },
            };
            if (r.active.fetchAdd(1, .monotonic) >= r.config.max_connections) {
                _ = r.active.fetchSub(1, .monotonic);
                var wbuf: [256]u8 = undefined;
                var w = stream.writer(io, &wbuf);
                w.interface.writeAll("HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n") catch {};
                w.interface.flush() catch {};
                stream.close(io);
                continue;
            }
            r.group.concurrent(io, serveConnection, .{ r, stream }) catch {
                _ = r.active.fetchSub(1, .monotonic);
                stream.close(io);
            };
        }
    }

    fn serveConnection(r: *Relay, stream: net.Stream) Io.Cancelable!void {
        defer {
            stream.close(r.io);
            _ = r.active.fetchSub(1, .monotonic);
        }
        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var sr = stream.reader(r.io, &in_buf);
        var sw = stream.writer(r.io, &out_buf);
        var hs = http.Server.init(&sr.interface, &sw.interface);
        while (true) {
            var req = hs.receiveHead() catch return;
            const keep = r.handle(&req) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => return,
            };
            if (!keep) return;
            if (sr.err) |e| if (e == error.Canceled) return error.Canceled;
        }
    }

    const HandleError = Io.Cancelable || error{WriteFailed};

    /// Serves one request. Returns whether the connection may serve another.
    fn handle(r: *Relay, req: *http.Server.Request) HandleError!bool {
        const target = req.head.target;
        const path = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;
        if (req.head.method == .GET and std.mem.eql(u8, path, "/v1/models")) return r.listModels(req);
        if (req.head.method == .POST and std.mem.eql(u8, path, "/v1/chat/completions")) return r.chat(req);

        var detail_buf: [160]u8 = undefined;
        r.writeReceipt(.{ .verdict = .deny, .reason = "unknown_endpoint", .detail = describeTarget(&detail_buf, req) });
        try r.respondError(req, .not_found, "unknown_endpoint", "blackice relay serves POST /v1/chat/completions and GET /v1/models");
        return req.head.keep_alive;
    }

    fn listModels(r: *Relay, req: *http.Server.Request) HandleError!bool {
        var aw: Io.Writer.Allocating = .init(r.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\"object\":\"list\",\"data\":[") catch return error.WriteFailed;
        for (r.config.models, 0..) |m, i| {
            if (i > 0) w.writeByte(',') catch return error.WriteFailed;
            w.print("{{\"id\":{f},\"object\":\"model\",\"owned_by\":\"blackice-relay\"}}", .{std.json.fmt(m, .{})}) catch return error.WriteFailed;
        }
        w.writeAll("]}") catch return error.WriteFailed;
        r.writeReceipt(.{ .verdict = .allow, .reason = "models_list" });
        req.respond(aw.written(), .{
            .keep_alive = req.head.keep_alive,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        }) catch return error.WriteFailed;
        return req.head.keep_alive;
    }

    fn chat(r: *Relay, req: *http.Server.Request) HandleError!bool {
        const keep_alive = req.head.keep_alive;
        if (req.head.content_length) |len| if (len > r.config.max_request_bytes) {
            r.writeReceipt(.{ .verdict = .deny, .reason = "request_too_large", .detail = "content_length" });
            // The body is not read, so the connection cannot be reused.
            try r.respondErrorClose(req, .payload_too_large, "request_too_large", "request body over the relay's size cap");
            return false;
        };

        var body_buf: [8192]u8 = undefined;
        const body_reader = req.readerExpectContinue(&body_buf) catch return error.WriteFailed;
        const body = body_reader.allocRemaining(r.gpa, .limited(r.config.max_request_bytes)) catch |err| switch (err) {
            error.StreamTooLong => {
                r.writeReceipt(.{ .verdict = .deny, .reason = "request_too_large", .detail = "body" });
                try r.respondErrorClose(req, .payload_too_large, "request_too_large", "request body over the relay's size cap");
                return false;
            },
            error.OutOfMemory => return error.WriteFailed,
            error.ReadFailed => return false,
        };
        defer r.gpa.free(body);

        const Fields = struct { model: []const u8, stream: ?bool = null };
        const parsed = std.json.parseFromSlice(Fields, r.gpa, body, .{ .ignore_unknown_fields = true }) catch {
            r.writeReceipt(.{ .verdict = .deny, .reason = "bad_request", .detail = "body must be JSON with a string \"model\"" });
            try r.respondError(req, .bad_request, "bad_request", "body must be JSON with a string \"model\"");
            return keep_alive;
        };
        defer parsed.deinit();
        const model = parsed.value.model;
        const stream = parsed.value.stream orelse false;

        var model_buf: [128]u8 = undefined;
        const model_label = printable(&model_buf, model);
        if (!r.modelAllowed(model)) {
            r.writeReceipt(.{ .verdict = .deny, .reason = "model_not_allowed", .rule = model_label });
            try r.respondError(req, .forbidden, "model_not_allowed", "model not on the relay's allow list");
            return keep_alive;
        }
        if (r.calls.fetchAdd(1, .monotonic) >= r.config.max_requests) {
            _ = r.calls.fetchSub(1, .monotonic);
            r.writeReceipt(.{ .verdict = .deny, .reason = "request_cap", .rule = model_label });
            try r.respondError(req, .too_many_requests, "request_cap", "the scope used up its relay calls");
            return keep_alive;
        }

        return r.forward(req, body, model_label, stream);
    }

    fn forward(r: *Relay, req: *http.Server.Request, body: []u8, model: []const u8, stream: bool) HandleError!bool {
        const keep_alive = req.head.keep_alive;
        var stats: CallStats = .{ .model = model, .stream = stream, .bytes_in = body.len };

        var up = r.client.request(.POST, r.chat_uri, .{
            .keep_alive = true,
            .redirect_behavior = .not_allowed,
            .headers = .{
                .authorization = .{ .override = r.auth },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = "blackice-relay" },
            },
        }) catch |err| return r.upstreamFailed(req, &stats, err);
        defer up.deinit();
        up.sendBodyComplete(body) catch |err| return r.upstreamFailed(req, &stats, err);
        var redirect_buf: [0]u8 = undefined;
        var resp = up.receiveHead(&redirect_buf) catch |err| return r.upstreamFailed(req, &stats, err);
        stats.status = @backingInt(resp.head.status);

        // Header strings are invalidated once the body is read, so copy what goes back to the caller.
        var ct_buf: [128]u8 = undefined;
        const content_type = copyHeader(&ct_buf, resp.head.content_type orelse "application/json");

        var out_buf: [4096]u8 = undefined;
        var bw = req.respondStreaming(&out_buf, .{ .respond_options = .{
            .status = resp.head.status,
            .keep_alive = keep_alive,
            .extra_headers = &.{
                .{ .name = "content-type", .value = content_type },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        } }) catch {
            stats.err = "client_write_failed";
            r.writeCallReceipt(&stats);
            return false;
        };

        var transfer_buf: [16 * 1024]u8 = undefined;
        const rr = resp.reader(&transfer_buf);
        var ok = true;
        while (true) {
            const data = rr.peekGreedy(1) catch |err| {
                if (err == error.ReadFailed) {
                    ok = false;
                    stats.err = if (resp.bodyErr()) |e| @errorName(e) else "upstream_read_failed";
                }
                break;
            };
            bw.writer.writeAll(data) catch {
                ok = false;
                stats.err = "client_write_failed";
                break;
            };
            // Flush every read so streamed events reach the caller as they arrive.
            bw.flush() catch {
                ok = false;
                stats.err = "client_write_failed";
                break;
            };
            stats.bytes_out += data.len;
            rr.toss(data.len);
        }
        if (ok) bw.end() catch {
            ok = false;
            stats.err = "client_write_failed";
        };
        r.writeCallReceipt(&stats);
        return ok and keep_alive;
    }

    fn upstreamFailed(r: *Relay, req: *http.Server.Request, stats: *CallStats, err: anyerror) HandleError!bool {
        if (err == error.Canceled) return error.Canceled;
        stats.err = @errorName(err);
        r.writeCallReceipt(stats);
        try r.respondError(req, .bad_gateway, "upstream_error", "the relay could not reach the model provider");
        return req.head.keep_alive;
    }

    fn modelAllowed(r: *const Relay, model: []const u8) bool {
        for (r.config.models) |m| if (std.mem.eql(u8, m, model)) return true;
        return false;
    }

    const CallStats = struct {
        model: []const u8,
        stream: bool,
        bytes_in: usize,
        bytes_out: usize = 0,
        status: ?u16 = null,
        err: ?[]const u8 = null,
    };

    fn writeCallReceipt(r: *Relay, s: *const CallStats) void {
        var buf: [256]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        if (s.status) |st| w.print("status={d} ", .{st}) catch {};
        w.print("bytes_in={d} bytes_out={d} stream={}", .{ s.bytes_in, s.bytes_out, s.stream }) catch {};
        if (s.err) |e| w.print(" error={s}", .{e}) catch {};
        r.writeReceipt(.{
            .verdict = .allow,
            .reason = if (s.err != null and s.status == null) "upstream_error" else "model_allowed",
            .rule = s.model,
            .detail = w.buffered(),
            .upstream = true,
        });
    }

    const ReceiptArgs = struct {
        verdict: receipt.Verdict,
        reason: []const u8,
        rule: ?[]const u8 = null,
        detail: ?[]const u8 = null,
        /// Include the upstream host and port.
        upstream: bool = false,
    };

    fn writeReceipt(r: *Relay, a: ReceiptArgs) void {
        r.receipts.write(.{
            .event = "relay_call",
            .point = .relay,
            .verdict = a.verdict,
            .reason = a.reason,
            .rule = a.rule,
            .host = if (a.upstream) r.upstream_host else null,
            .port = if (a.upstream) r.upstream_port else null,
            .detail = a.detail,
        });
    }

    fn respondError(r: *Relay, req: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) HandleError!void {
        return r.respondErrorOpts(req, status, code, message, req.head.keep_alive);
    }

    fn respondErrorClose(r: *Relay, req: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) HandleError!void {
        return r.respondErrorOpts(req, status, code, message, false);
    }

    fn respondErrorOpts(r: *Relay, req: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8, keep_alive: bool) HandleError!void {
        _ = r;
        // OpenAI-style error body, so callers show a readable message.
        var buf: [512]u8 = undefined;
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "blackice relay: {s}", .{message}) catch "blackice relay";
        const body = std.fmt.bufPrint(&buf, "{{\"error\":{{\"message\":{f},\"type\":\"blackice_relay\",\"code\":\"{s}\"}}}}", .{ std.json.fmt(msg, .{}), code }) catch unreachable;
        req.respond(body, .{
            .status = status,
            .keep_alive = keep_alive,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        }) catch return error.WriteFailed;
    }
};

const Upstream = struct { chat_url: []u8, host: []u8, port: u16 };

/// Validates the upstream base URL and derives the chat-completions URL. Caller owns both strings.
fn parseUpstream(gpa: std.mem.Allocator, base: []const u8) error{ InvalidUpstream, OutOfMemory }!Upstream {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    const uri = std.Uri.parse(trimmed) catch return error.InvalidUpstream;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidUpstream;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = (std.Io.net.HostName.fromUri(uri, &host_buf) catch return error.InvalidUpstream).bytes;
    const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!https) {
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidUpstream;
        // Plain http only to this machine, where nothing crosses the network.
        const lit = std.Io.net.IpAddress.parse(host, 0) catch return error.InvalidUpstream;
        const loopback = switch (lit) {
            .ip4 => |a| a.bytes[0] == 127,
            .ip6 => |a| std.mem.eql(u8, &a.bytes, &std.Io.net.Ip6Address.loopback(0).bytes),
        };
        if (!loopback) return error.InvalidUpstream;
    }
    const chat_url = try std.mem.concat(gpa, u8, &.{ trimmed, "/chat/completions" });
    errdefer gpa.free(chat_url);
    _ = std.Uri.parse(chat_url) catch return error.InvalidUpstream;
    return .{
        .chat_url = chat_url,
        .host = try gpa.dupe(u8, host),
        .port = uri.port orelse if (https) 443 else 80,
    };
}

/// Model names go into receipts; keep them printable and bounded.
fn printable(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], buf[0..n]) |ch, *o| o.* = if (ch >= 0x20 and ch < 0x7f) ch else '?';
    return buf[0..n];
}

fn copyHeader(buf: []u8, s: []const u8) []const u8 {
    const v = printable(buf, s);
    return v;
}

fn describeTarget(buf: []u8, req: *const http.Server.Request) []const u8 {
    var w: Io.Writer = .fixed(buf);
    w.print("{s} ", .{@tagName(req.head.method)}) catch {};
    const t = req.head.target;
    const path = if (std.mem.findScalar(u8, t, '?')) |q| t[0..q] else t;
    var tmp: [128]u8 = undefined;
    w.writeAll(printable(&tmp, path)) catch {};
    return w.buffered();
}

test {
    _ = @import("test.zig");
}
