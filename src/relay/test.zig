//! Relay tests against a local stand-in upstream on loopback. No test reaches a real provider; the key is
//! synthetic.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const http = std.http;
const testing = std.testing;
const receipt = @import("../core/receipt.zig");
const relay = @import("relay.zig");

const test_key = "sk-test-0123456789";

/// Stand-in for the provider: checks the key, records what it received, answers JSON or server-sent events.
const Upstream = struct {
    io: Io,
    server: net.Server,
    port: u16,
    group: Io.Group = .init,
    mutex: Io.Mutex = .init,
    calls: u32 = 0,
    last_auth: [128]u8 = undefined,
    last_auth_len: usize = 0,
    last_body: [512]u8 = undefined,
    last_body_len: usize = 0,
    saw_client_header: bool = false,

    fn start(u: *Upstream, io: Io) !void {
        const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try addr.listen(io, .{});
        u.* = .{ .io = io, .server = server, .port = server.socket.address.getPort() };
        try u.group.concurrent(io, loop, .{u});
    }

    fn stop(u: *Upstream) void {
        u.group.cancel(u.io);
        u.server.deinit(u.io);
    }

    fn loop(u: *Upstream) Io.Cancelable!void {
        while (true) {
            const s = u.server.accept(u.io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => return,
            };
            u.group.concurrent(u.io, serve, .{ u, s }) catch s.close(u.io);
        }
    }

    fn serve(u: *Upstream, s: net.Stream) Io.Cancelable!void {
        defer s.close(u.io);
        var in_buf: [8192]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var sr = s.reader(u.io, &in_buf);
        var sw = s.writer(u.io, &out_buf);
        var hs = http.Server.init(&sr.interface, &sw.interface);
        while (true) {
            var req = hs.receiveHead() catch return;
            u.handle(&req) catch return;
        }
    }

    fn handle(u: *Upstream, req: *http.Server.Request) !void {
        var got_auth: []const u8 = "";
        var it = req.iterateHeaders();
        var client_header = false;
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) got_auth = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "x-from-client")) client_header = true;
        }
        u.mutex.lockUncancelable(u.io);
        u.calls += 1;
        @memcpy(u.last_auth[0..got_auth.len], got_auth);
        u.last_auth_len = got_auth.len;
        u.saw_client_header = client_header;
        u.mutex.unlock(u.io);
        const authorized = std.mem.eql(u8, got_auth, "Bearer " ++ test_key);

        var body_buf: [1024]u8 = undefined;
        const r = try req.readerExpectContinue(&body_buf);
        var body_store: [512]u8 = undefined;
        const n = try r.readSliceShort(&body_store);
        @memcpy(u.last_body[0..n], body_store[0..n]);
        u.last_body_len = n;

        if (!authorized) {
            try req.respond("{\"error\":\"bad key\"}", .{ .status = .unauthorized });
            return;
        }
        if (std.mem.find(u8, body_store[0..n], "\"user\":\"slow\"") != null) {
            try u.io.sleep(.fromSeconds(3), .awake);
        }
        if (std.mem.find(u8, body_store[0..n], "\"stream\":true") != null) {
            var out: [256]u8 = undefined;
            var bw = try req.respondStreaming(&out, .{ .respond_options = .{
                .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
            } });
            try bw.writer.writeAll("data: {\"choices\":[{\"delta\":{\"content\":\"he\"}}]}\n\n");
            try bw.flush();
            try bw.writer.writeAll("data: {\"choices\":[{\"delta\":{\"content\":\"llo\"}}]}\n\n");
            try bw.writer.writeAll("data: [DONE]\n\n");
            try bw.end();
            return;
        }
        try req.respond("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hello\"}}]}", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }

    fn auth(u: *Upstream) []const u8 {
        return u.last_auth[0..u.last_auth_len];
    }
};

const Harness = struct {
    io: Io,
    tmp: testing.TmpDir,
    log: receipt.Log,
    up: Upstream,
    r: *relay.Relay,
    url_buf: [64]u8 = undefined,

    fn init(h: *Harness, config: relay.Config) !void {
        h.io = testing.io;
        h.tmp = testing.tmpDir(.{});
        errdefer h.tmp.cleanup();
        h.log = try receipt.Log.open(h.io, h.tmp.dir, "receipts.jsonl", "s-test0003", "000000000000");
        errdefer h.log.close();
        try h.up.start(h.io);
        errdefer h.up.stop();
        var c = config;
        c.upstream = try std.fmt.bufPrint(&h.url_buf, "http://127.0.0.1:{d}/v1", .{h.up.port});
        h.r = try relay.Relay.start(testing.allocator, h.io, c, test_key, &h.log);
    }

    fn deinit(h: *Harness) void {
        h.r.stop();
        h.up.stop();
        h.log.close();
        h.tmp.cleanup();
    }

    fn receipts(h: *Harness) ![]u8 {
        return h.tmp.dir.readFileAlloc(h.io, "receipts.jsonl", testing.allocator, .limited(1 << 20));
    }

    fn receiptAt(h: *Harness, n: usize) !std.json.Parsed(std.json.Value) {
        const bytes = try h.receipts();
        defer testing.allocator.free(bytes);
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
        var i: usize = 0;
        while (it.next()) |line| : (i += 1) {
            if (i == n) return std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        }
        return error.MissingReceipt;
    }

    const Response = struct {
        status: http.Status,
        body: []u8,
    };

    const CallOptions = struct {
        content_type: []const u8 = "application/json",
        host: ?[]const u8 = null,
        extra: []const http.Header = &.{.{ .name = "x-from-client", .value = "1" }},
    };

    /// One call through std.http.Client, the way a real OpenAI-compatible client would make it.
    fn call(h: *Harness, method: http.Method, path: []const u8, payload: ?[]const u8) !Response {
        return h.callWith(method, path, payload, .{});
    }

    fn callWith(h: *Harness, method: http.Method, path: []const u8, payload: ?[]const u8, o: CallOptions) !Response {
        var client: http.Client = .{ .allocator = testing.allocator, .io = h.io };
        defer client.deinit();
        var url_buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ h.r.port, path });
        var aw: Io.Writer.Allocating = .init(testing.allocator);
        errdefer aw.deinit();
        const res = try client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .response_writer = &aw.writer,
            .headers = .{
                .authorization = .{ .override = "Bearer client-supplied-junk" },
                .content_type = .{ .override = o.content_type },
                .host = if (o.host) |x| .{ .override = x } else .default,
            },
            .extra_headers = o.extra,
        });
        return .{ .status = res.status, .body = try aw.toOwnedSlice() };
    }
};

fn expectField(v: std.json.Value, key: []const u8, want: []const u8) !void {
    const got = v.object.get(key) orelse {
        std.debug.print("receipt has no \"{s}\"\n", .{key});
        return error.TestExpectedEqual;
    };
    try testing.expectEqualStrings(want, got.string);
}

const models = [_][]const u8{"test/allowed-model"};

test "an allowed model is forwarded with the relay's key, never the caller's headers" {
    var h: Harness = undefined;
    try h.init(.{ .models = &models });
    defer h.deinit();

    const res = try h.call(.POST, "/v1/chat/completions",
        \\{"model":"test/allowed-model","messages":[{"role":"user","content":"hi"}]}
    );
    defer testing.allocator.free(res.body);
    try testing.expectEqual(http.Status.ok, res.status);
    try testing.expect(std.mem.find(u8, res.body, "\"content\":\"hello\"") != null);
    try testing.expectEqualStrings("Bearer " ++ test_key, h.up.auth());
    try testing.expect(!h.up.saw_client_header);
    try testing.expectEqual(@as(u32, 1), h.r.callCount());

    var r = try h.receiptAt(0);
    defer r.deinit();
    try expectField(r.value, "point", "relay");
    try expectField(r.value, "event", "relay_call");
    try expectField(r.value, "verdict", "allow");
    try expectField(r.value, "reason", "model_allowed");
    try expectField(r.value, "rule", "test/allowed-model");
    try expectField(r.value, "host", "127.0.0.1");
    try testing.expect(std.mem.startsWith(u8, r.value.object.get("detail").?.string, "status=200 bytes_in="));

    const all = try h.receipts();
    defer testing.allocator.free(all);
    try testing.expect(std.mem.find(u8, all, test_key) == null);
}

test "streamed responses pass through as server-sent events" {
    var h: Harness = undefined;
    try h.init(.{ .models = &models });
    defer h.deinit();
    const res = try h.call(.POST, "/v1/chat/completions",
        \\{"model":"test/allowed-model","stream":true,"messages":[]}
    );
    defer testing.allocator.free(res.body);
    try testing.expectEqual(http.Status.ok, res.status);
    try testing.expect(std.mem.startsWith(u8, res.body, "data: {\"choices\":[{\"delta\":{\"content\":\"he\"}}]}\n\n"));
    try testing.expect(std.mem.endsWith(u8, res.body, "data: [DONE]\n\n"));
    var r = try h.receiptAt(0);
    defer r.deinit();
    try testing.expect(std.mem.endsWith(u8, r.value.object.get("detail").?.string, "stream=true"));
}

test "models off the allow list, oversized bodies, bad JSON and other endpoints are refused locally" {
    var h: Harness = undefined;
    try h.init(.{ .models = &models, .max_request_bytes = 256 });
    defer h.deinit();

    const denied = try h.call(.POST, "/v1/chat/completions",
        \\{"model":"test/expensive-model","messages":[]}
    );
    defer testing.allocator.free(denied.body);
    try testing.expectEqual(http.Status.forbidden, denied.status);
    try testing.expect(std.mem.find(u8, denied.body, "model_not_allowed") != null);

    const pad: [300]u8 = @splat('x');
    const big = "{\"model\":\"test/allowed-model\",\"pad\":\"" ++ pad ++ "\"}";
    const too_large = try h.call(.POST, "/v1/chat/completions", big);
    defer testing.allocator.free(too_large.body);
    try testing.expectEqual(http.Status.payload_too_large, too_large.status);

    const bad = try h.call(.POST, "/v1/chat/completions", "{\"messages\":[]}");
    defer testing.allocator.free(bad.body);
    try testing.expectEqual(http.Status.bad_request, bad.status);

    const dup = try h.call(.POST, "/v1/chat/completions",
        \\{"model":"test/allowed-model","model":"test/expensive-model"}
    );
    defer testing.allocator.free(dup.body);
    try testing.expectEqual(http.Status.bad_request, dup.status);

    const other = try h.call(.POST, "/v1/embeddings", "{}");
    defer testing.allocator.free(other.body);
    try testing.expectEqual(http.Status.not_found, other.status);

    try testing.expectEqual(@as(u32, 0), h.up.calls);
    const reasons = [_][]const u8{ "model_not_allowed", "request_too_large", "bad_request", "bad_request", "unknown_endpoint" };
    for (reasons, 0..) |want, i| {
        var r = try h.receiptAt(i);
        defer r.deinit();
        try expectField(r.value, "verdict", "deny");
        try expectField(r.value, "reason", want);
    }
}

test "browser pages, foreign Host headers, non-JSON bodies and routing fields are refused" {
    var h: Harness = undefined;
    try h.init(.{ .models = &models });
    defer h.deinit();
    const body =
        \\{"model":"test/allowed-model","messages":[]}
    ;
    const origin = try h.callWith(.POST, "/v1/chat/completions", body, .{ .extra = &.{.{ .name = "Origin", .value = "https://evil.test" }} });
    defer testing.allocator.free(origin.body);
    try testing.expectEqual(http.Status.forbidden, origin.status);

    const fetch_meta = try h.callWith(.POST, "/v1/chat/completions", body, .{ .extra = &.{.{ .name = "Sec-Fetch-Mode", .value = "no-cors" }} });
    defer testing.allocator.free(fetch_meta.body);
    try testing.expectEqual(http.Status.forbidden, fetch_meta.status);

    const rebound = try h.callWith(.POST, "/v1/chat/completions", body, .{ .host = "evil.test" });
    defer testing.allocator.free(rebound.body);
    try testing.expectEqual(http.Status.forbidden, rebound.status);

    const plain = try h.callWith(.POST, "/v1/chat/completions", body, .{ .content_type = "text/plain" });
    defer testing.allocator.free(plain.body);
    try testing.expectEqual(http.Status.unsupported_media_type, plain.status);

    const routed = try h.call(.POST, "/v1/chat/completions",
        \\{"model":"test/allowed-model","providerOptions":{"gateway":{"models":["test/expensive-model"]}}}
    );
    defer testing.allocator.free(routed.body);
    try testing.expectEqual(http.Status.forbidden, routed.status);

    try testing.expectEqual(@as(u32, 0), h.up.calls);
    const reasons = [_][]const u8{ "browser_request", "browser_request", "bad_host_header", "bad_content_type", "routing_not_allowed" };
    for (reasons, 0..) |want, i| {
        var r = try h.receiptAt(i);
        defer r.deinit();
        try expectField(r.value, "verdict", "deny");
        try expectField(r.value, "reason", want);
    }
    var r4 = try h.receiptAt(4);
    defer r4.deinit();
    try expectField(r4.value, "detail", "providerOptions");
}

test "only standard chat-completion fields pass the relay" {
    var h: Harness = undefined;
    try h.init(.{ .models = &models });
    defer h.deinit();
    const full = try h.call(.POST, "/v1/chat/completions",
        \\{"model":"test/allowed-model","messages":[{"role":"user","content":"hi","name":"x"}],"tools":[],
        \\ "tool_choice":"auto","stream":false,"stream_options":null,"temperature":0.2,"top_p":1,"max_tokens":50,
        \\ "max_completion_tokens":50,"response_format":{"type":"text"},"stop":["\\n"],"seed":1,"n":1,"user":"u",
        \\ "parallel_tool_calls":true,"reasoning_effort":"low"}
    );
    defer testing.allocator.free(full.body);
    try testing.expectEqual(http.Status.ok, full.status);
    const unknown = [_][]const u8{
        \\{"model":"test/allowed-model","messages":[],"models":["test/expensive-model"]}
        ,
        \\{"model":"test/allowed-model","messages":[],"order":["openai"]}
        ,
        \\{"model":"test/allowed-model","messages":[],"\u0070roviderOptions":{}}
        ,
    };
    for (unknown) |body| {
        const res = try h.call(.POST, "/v1/chat/completions", body);
        defer testing.allocator.free(res.body);
        try testing.expectEqual(http.Status.forbidden, res.status);
    }
    try testing.expectEqual(@as(u32, 1), h.up.calls);
    var r = try h.receiptAt(3);
    defer r.deinit();
    try expectField(r.value, "reason", "routing_not_allowed");
    try expectField(r.value, "detail", "providerOptions");
}

test "the response cap and the call time limit cut a call" {
    var h: Harness = undefined;
    try h.init(.{ .models = &models, .max_response_bytes = 16, .call_timeout = .fromMilliseconds(300) });
    defer h.deinit();
    if (h.call(.POST, "/v1/chat/completions",
        \\{"model":"test/allowed-model","messages":[]}
    )) |res| {
        defer testing.allocator.free(res.body);
        try testing.expect(res.body.len <= 16);
    } else |_| {}
    if (h.call(.POST, "/v1/chat/completions",
        \\{"model":"test/allowed-model","user":"slow"}
    )) |res| {
        defer testing.allocator.free(res.body);
        try testing.expect(res.status != .ok);
    } else |_| {}
    var r0 = try h.receiptAt(0);
    defer r0.deinit();
    try testing.expect(std.mem.endsWith(u8, r0.value.object.get("detail").?.string, "error=response_cap"));
    var r1 = try h.receiptAt(1);
    defer r1.deinit();
    try testing.expect(std.mem.endsWith(u8, r1.value.object.get("detail").?.string, "error=call_timeout"));
}

test "a call whose time limit cannot be armed is refused" {
    var h: Harness = undefined;
    try h.init(.{ .models = &models });
    defer h.deinit();
    relay.test_fail_watchdog = true;
    defer relay.test_fail_watchdog = false;
    const res = try h.call(.POST, "/v1/chat/completions",
        \\{"model":"test/allowed-model","messages":[]}
    );
    defer testing.allocator.free(res.body);
    try testing.expectEqual(http.Status.service_unavailable, res.status);
    var r = try h.receiptAt(0);
    defer r.deinit();
    try expectField(r.value, "reason", "relay_watchdog_failed");
}

test "the call cap refuses calls once used up" {
    var h: Harness = undefined;
    try h.init(.{ .models = &models, .max_requests = 2 });
    defer h.deinit();
    const body =
        \\{"model":"test/allowed-model","messages":[]}
    ;
    for (0..2) |_| {
        const ok = try h.call(.POST, "/v1/chat/completions", body);
        defer testing.allocator.free(ok.body);
        try testing.expectEqual(http.Status.ok, ok.status);
    }
    const capped = try h.call(.POST, "/v1/chat/completions", body);
    defer testing.allocator.free(capped.body);
    try testing.expectEqual(http.Status.too_many_requests, capped.status);
    try testing.expectEqual(@as(u32, 2), h.up.calls);
    var r = try h.receiptAt(2);
    defer r.deinit();
    try expectField(r.value, "reason", "request_cap");
}

test "GET /v1/models lists the allow list" {
    var h: Harness = undefined;
    try h.init(.{ .models = &models });
    defer h.deinit();
    const res = try h.call(.GET, "/v1/models", null);
    defer testing.allocator.free(res.body);
    try testing.expectEqual(http.Status.ok, res.status);
    try testing.expectEqualStrings(
        \\{"object":"list","data":[{"id":"test/allowed-model","object":"model","owned_by":"blackice-relay"}]}
    , res.body);
}

test "an unreachable upstream gives 502 and a receipt" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try receipt.Log.open(io, tmp.dir, "r.jsonl", "s-test0004", "000000000000");
    defer log.close();
    // A port that was just free: bind, read the port, close.
    const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
    var probe = try addr.listen(io, .{});
    const dead_port = probe.socket.address.getPort();
    probe.deinit(io);
    var url_buf: [64]u8 = undefined;
    const r = try relay.Relay.start(testing.allocator, io, .{
        .models = &models,
        .upstream = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1", .{dead_port}),
    }, test_key, &log);
    defer r.stop();

    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var call_url: [64]u8 = undefined;
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = try std.fmt.bufPrint(&call_url, "http://127.0.0.1:{d}/v1/chat/completions", .{r.port}) },
        .payload = "{\"model\":\"test/allowed-model\"}",
        .response_writer = &aw.writer,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    });
    try testing.expectEqual(http.Status.bad_gateway, res.status);
    const bytes = try tmp.dir.readFileAlloc(io, "r.jsonl", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.find(u8, bytes, "\"reason\":\"upstream_error\"") != null);
    try testing.expect(std.mem.find(u8, bytes, "ConnectionRefused") != null);
}

test "upstream URLs: https anywhere, plain http only to loopback" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try receipt.Log.open(io, tmp.dir, "r.jsonl", "s-test0005", "000000000000");
    defer log.close();
    const bad = [_][]const u8{ "http://example.com/v1", "ftp://127.0.0.1/v1", "https://user:pw@example.com/v1", "https://example.com/v1?x=1", "not a url" };
    for (bad) |u| {
        try testing.expectError(error.InvalidUpstream, relay.Relay.start(testing.allocator, io, .{ .upstream = u }, test_key, &log));
    }
    try testing.expectError(error.KeyInvalid, relay.Relay.start(testing.allocator, io, .{}, "has space", &log));
    const r = try relay.Relay.start(testing.allocator, io, .{ .upstream = "https://ai-gateway.vercel.sh/v1/" }, test_key, &log);
    defer r.stop();
    try testing.expectEqualStrings("https://ai-gateway.vercel.sh/v1/chat/completions", r.chat_url);
    try testing.expectEqualStrings("ai-gateway.vercel.sh", r.upstream_host);
    try testing.expectEqual(@as(u16, 443), r.upstream_port);
}

test "readKey" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { []const u8, ?[]const u8, ?relay.KeyError }{
        .{ "  sk-abc123\n", "sk-abc123", null },
        .{ "sk-abc123", "sk-abc123", null },
        .{ "\n\n", null, error.KeyMissing },
        .{ "sk abc\n", null, error.KeyInvalid },
        .{ "sk-" ++ @as([40]u8, @splat('a')), null, error.KeyTooLong },
    };
    for (cases) |c| {
        try tmp.dir.writeFile(io, .{ .sub_path = "key", .data = c[0] });
        const f = try tmp.dir.openFile(io, "key", .{});
        defer f.close(io);
        var buf: [32]u8 = undefined;
        if (c[2]) |want_err| {
            try testing.expectError(want_err, relay.readKey(io, f, &buf));
        } else {
            try testing.expectEqualStrings(c[1].?, try relay.readKey(io, f, &buf));
        }
    }
}

test "hardenProcess compiles for this target" {
    // Not called: it would change the test runner itself. Referencing it makes the compiler check the
    // Linux (prctl) and macOS (ptrace) paths when the tests are built for each target.
    _ = &relay.hardenProcess;
}

const fake_model = @import("fake_model.zig");

fn postJson(io: Io, port: u16, body: []const u8) ![]u8 {
    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{port}) },
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    });
    try testing.expectEqual(http.Status.ok, res.status);
    return aw.toOwnedSlice();
}

test "end to end with the scripted model: tool calls stream through the relay" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try receipt.Log.open(io, tmp.dir, "r.jsonl", "s-test0008", "000000000000");
    defer log.close();
    const steps = [_][]const u8{ "echo one", "echo two" };
    const m = try fake_model.FakeModel.start(testing.allocator, io, 0, &steps, null);
    defer m.stop();
    var url_buf: [64]u8 = undefined;
    const allowed = [_][]const u8{fake_model.model_id};
    const r = try relay.Relay.start(testing.allocator, io, .{
        .models = &allowed,
        .upstream = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1", .{m.port}),
    }, test_key, &log);
    defer r.stop();

    const first = try postJson(io, r.port,
        \\{"model":"blackice-test/scripted","stream":true,"messages":[{"role":"user","content":"go"}],
        \\ "tools":[{"type":"function","function":{"name":"shell","parameters":{}}}]}
    );
    defer testing.allocator.free(first);
    try testing.expect(std.mem.find(u8, first, "\"tool_calls\"") != null);
    try testing.expect(std.mem.find(u8, first, "echo one") != null);
    try testing.expect(std.mem.find(u8, first, "\"delta\":{},\"finish_reason\":\"tool_calls\"") != null);
    try testing.expect(std.mem.endsWith(u8, first, "data: [DONE]\n\n"));

    const last = try postJson(io, r.port,
        \\{"model":"blackice-test/scripted","messages":[{"role":"user","content":"go"},
        \\ {"role":"tool","tool_call_id":"call_1","content":"one\n"},{"role":"tool","tool_call_id":"call_2","content":"two\n"}],
        \\ "tools":[{"type":"function","function":{"name":"shell","parameters":{}}}]}
    );
    defer testing.allocator.free(last);
    try testing.expect(std.mem.find(u8, last, "SCRIPTED TEST MODEL (not a real model). Tool results: one | two") != null);
    try testing.expectEqual(@as(u32, 2), m.calls.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), r.callCount());
}
