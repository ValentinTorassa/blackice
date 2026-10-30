//! A scripted OpenAI-compatible model, for tests and dry runs only. It never contacts the network and is
//! never the demo model: every answer it gives says it is scripted.
//!
//! Each chat call that offers a tool whose name contains "shell" gets back a call to that tool with the
//! next scripted command; once every step has a tool result, it answers with a summary of the results.
//! This is enough to drive an agent such as fx through a run without a provider key or any cost.
//!
//! Run it on its own:
//!     zig run src/relay/fake_model.zig -- 18780 [--log FILE] [--step 'COMMAND']...
//! and point the relay at it with upstream http://127.0.0.1:18780/v1.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const http = std.http;

pub const model_id = "blackice-test/scripted";

/// The default script: what a confined tool can and cannot reach.
pub const default_steps = [_][]const u8{
    // A direct connection that bypasses the proxy: the OS backend must refuse it.
    "curl -sS -m 5 --noproxy '*' -o /dev/null https://example.com; echo \"direct curl_exit=$?\"",
    // The same request through the scope's proxy (HTTPS_PROXY is set by blackice run).
    "curl -sS -m 10 -o /dev/null -w '%{http_code}' https://example.com; echo \" via-proxy curl_exit=$?\"",
    // A host the example policy does not allow: the proxy must answer 403.
    "curl -sS -m 10 -o /dev/null https://github.com; echo \"denied curl_exit=$?\"",
    "echo \"AI_AGENT=$AI_AGENT\"",
};

pub const FakeModel = struct {
    gpa: std.mem.Allocator,
    io: Io,
    server: net.Server,
    port: u16,
    steps: []const []const u8,
    log: ?Io.File,
    log_mutex: Io.Mutex = .init,
    log_offset: u64 = 0,
    calls: std.atomic.Value(u32) = .init(0),
    group: Io.Group = .init,

    /// Listens on 127.0.0.1:`port` (0 for a random port). `steps` and `log` must outlive the model.
    pub fn start(gpa: std.mem.Allocator, io: Io, port: u16, steps: []const []const u8, log: ?Io.File) !*FakeModel {
        const m = try gpa.create(FakeModel);
        errdefer gpa.destroy(m);
        const addr: net.IpAddress = .{ .ip4 = .loopback(port) };
        var server = try addr.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);
        m.* = .{
            .gpa = gpa,
            .io = io,
            .server = server,
            .port = server.socket.address.getPort(),
            .steps = steps,
            .log = log,
        };
        try m.group.concurrent(io, acceptLoop, .{m});
        return m;
    }

    pub fn stop(m: *FakeModel) void {
        m.group.cancel(m.io);
        m.server.deinit(m.io);
        m.gpa.destroy(m);
    }

    fn acceptLoop(m: *FakeModel) Io.Cancelable!void {
        while (true) {
            const s = m.server.accept(m.io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => continue,
            };
            m.group.concurrent(m.io, serve, .{ m, s }) catch s.close(m.io);
        }
    }

    fn serve(m: *FakeModel, s: net.Stream) Io.Cancelable!void {
        defer s.close(m.io);
        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var sr = s.reader(m.io, &in_buf);
        var sw = s.writer(m.io, &out_buf);
        var hs = http.Server.init(&sr.interface, &sw.interface);
        while (true) {
            var req = hs.receiveHead() catch return;
            const keep = m.handle(&req) catch return;
            if (!keep) return;
        }
    }

    fn handle(m: *FakeModel, req: *http.Server.Request) !bool {
        if (req.head.method == .GET and std.mem.endsWith(u8, req.head.target, "/models")) {
            try req.respond("{\"object\":\"list\",\"data\":[{\"id\":\"" ++ model_id ++ "\",\"object\":\"model\"}]}", .{
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return req.head.keep_alive;
        }
        if (req.head.method != .POST) {
            try req.respond("{\"error\":\"not found\"}", .{ .status = .not_found, .keep_alive = false });
            return false;
        }
        var has_auth = false;
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) has_auth = true;
        }

        var arena_state: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var body_buf: [8192]u8 = undefined;
        const body_reader = try req.readerExpectContinue(&body_buf);
        const body = try body_reader.allocRemaining(arena, .limited(4 << 20));
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch std.json.Value{ .null = {} };
        const call = try Call.read(arena, parsed);
        _ = m.calls.fetchAdd(1, .monotonic);
        m.writeLog(call, has_auth);

        const step = call.tool_results.items.len;
        var reply: Reply = undefined;
        if (call.shell_tool) |tool| {
            if (step < m.steps.len) {
                var args_w: Io.Writer.Allocating = .init(arena);
                try args_w.writer.print("{f}", .{std.json.fmt(.{ .action = "run", .command = m.steps[step] }, .{})});
                reply = .{ .tool = .{ .name = tool, .arguments = args_w.written(), .id = try std.fmt.allocPrint(arena, "call_{d}", .{step + 1}) } };
            } else reply = .{ .text = try summary(arena, call) };
        } else reply = .{ .text = try summary(arena, call) };

        if (call.stream) {
            try respondStream(req, reply);
        } else {
            try respondJson(arena, req, reply);
        }
        return req.head.keep_alive;
    }

    fn writeLog(m: *FakeModel, call: Call, has_auth: bool) void {
        const file = m.log orelse return;
        var buf: [4096]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        w.print("{f}\n", .{std.json.fmt(.{
            .stream = call.stream,
            .tools = call.tool_names.items,
            .n_messages = call.n_messages,
            .tool_results = call.tool_results.items,
            .has_authorization = has_auth,
        }, .{})}) catch {
            w.end = 0;
            w.writeAll("{\"truncated\":true}\n") catch {};
        };
        m.log_mutex.lockUncancelable(m.io);
        defer m.log_mutex.unlock(m.io);
        file.writePositionalAll(m.io, w.buffered(), m.log_offset) catch return;
        m.log_offset += w.end;
    }
};

const Call = struct {
    stream: bool = false,
    n_messages: usize = 0,
    tool_names: std.ArrayList([]const u8) = .empty,
    tool_results: std.ArrayList([]const u8) = .empty,
    shell_tool: ?[]const u8 = null,

    /// Reads what the script needs from a chat body; anything missing or malformed reads as absent.
    fn read(arena: std.mem.Allocator, v: std.json.Value) error{OutOfMemory}!Call {
        var c: Call = .{};
        const obj = switch (v) {
            .object => |o| o,
            else => return c,
        };
        if (obj.get("stream")) |st| c.stream = st == .bool and st.bool;
        if (obj.get("tools")) |tools| if (tools == .array) {
            for (tools.array.items) |t| {
                const f = (if (t == .object) t.object.get("function") else null) orelse continue;
                const name = (if (f == .object) f.object.get("name") else null) orelse continue;
                if (name != .string) continue;
                try c.tool_names.append(arena, name.string);
                if (c.shell_tool == null and std.ascii.findIgnoreCase(name.string, "shell") != null) c.shell_tool = name.string;
            }
        };
        if (obj.get("messages")) |msgs| if (msgs == .array) {
            c.n_messages = msgs.array.items.len;
            for (msgs.array.items) |msg| {
                if (msg != .object) continue;
                const role = msg.object.get("role") orelse continue;
                if (role != .string or !std.mem.eql(u8, role.string, "tool")) continue;
                const content = msg.object.get("content") orelse continue;
                try c.tool_results.append(arena, if (content == .string) content.string else "(non-text tool result)");
            }
        };
        return c;
    }
};

/// Serializes as {} (an empty anonymous literal would serialize as []).
const Empty = struct {};

const Reply = union(enum) {
    text: []const u8,
    tool: struct { id: []const u8, name: []const u8, arguments: []const u8 },
};

fn summary(arena: std.mem.Allocator, call: Call) ![]const u8 {
    var w: Io.Writer.Allocating = .init(arena);
    try w.writer.writeAll("SCRIPTED TEST MODEL (not a real model). Tool results: ");
    if (call.tool_results.items.len == 0) try w.writer.writeAll("none");
    for (call.tool_results.items, 0..) |r, i| {
        if (i > 0) try w.writer.writeAll(" | ");
        try w.writer.writeAll(std.mem.trim(u8, r[0..@min(r.len, 200)], " \r\n"));
    }
    return w.written();
}

fn respondJson(arena: std.mem.Allocator, req: *http.Server.Request, reply: Reply) !void {
    var w: Io.Writer.Allocating = .init(arena);
    switch (reply) {
        .text => |t| try w.writer.print("{f}", .{std.json.fmt(.{
            .id = "chatcmpl-scripted",
            .object = "chat.completion",
            .model = model_id,
            .choices = .{.{ .index = 0, .message = .{ .role = "assistant", .content = t }, .finish_reason = "stop" }},
            .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
        }, .{})}),
        .tool => |c| try w.writer.print("{f}", .{std.json.fmt(.{
            .id = "chatcmpl-scripted",
            .object = "chat.completion",
            .model = model_id,
            .choices = .{.{
                .index = 0,
                .message = .{
                    .role = "assistant",
                    .content = null,
                    .tool_calls = .{.{ .id = c.id, .type = "function", .function = .{ .name = c.name, .arguments = c.arguments } }},
                },
                .finish_reason = "tool_calls",
            }},
            .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
        }, .{})}),
    }
    try req.respond(w.written(), .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

fn respondStream(req: *http.Server.Request, reply: Reply) !void {
    var out: [1024]u8 = undefined;
    var bw = try req.respondStreaming(&out, .{ .respond_options = .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    } });
    const w = &bw.writer;
    const base = .{ .id = "chatcmpl-scripted", .object = "chat.completion.chunk", .model = model_id };
    switch (reply) {
        .text => |t| try w.print("data: {f}\n\n", .{std.json.fmt(.{
            .id = base.id,
            .object = base.object,
            .model = base.model,
            .choices = .{.{ .index = 0, .delta = .{ .role = "assistant", .content = t }, .finish_reason = null }},
        }, .{})}),
        .tool => |c| try w.print("data: {f}\n\n", .{std.json.fmt(.{
            .id = base.id,
            .object = base.object,
            .model = base.model,
            .choices = .{.{
                .index = 0,
                .delta = .{
                    .role = "assistant",
                    .tool_calls = .{.{ .index = 0, .id = c.id, .type = "function", .function = .{ .name = c.name, .arguments = c.arguments } }},
                },
                .finish_reason = null,
            }},
        }, .{})}),
    }
    try bw.flush();
    const finish: []const u8 = if (reply == .tool) "tool_calls" else "stop";
    try w.print("data: {f}\n\n", .{std.json.fmt(.{
        .id = base.id,
        .object = base.object,
        .model = base.model,
        .choices = .{.{ .index = 0, .delta = Empty{}, .finish_reason = finish }},
    }, .{})});
    try w.print("data: {f}\n\n", .{std.json.fmt(.{
        .id = base.id,
        .object = base.object,
        .model = base.model,
        .choices = .{},
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
    }, .{})});
    try w.writeAll("data: [DONE]\n\n");
    try bw.end();
}

/// `zig run src/relay/fake_model.zig -- PORT [--log FILE] [--step 'COMMAND']...`
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: fake_model PORT [--log FILE] [--step 'COMMAND']...\n", .{});
        return error.Usage;
    }
    const port = try std.fmt.parseInt(u16, args[1], 10);
    var steps: std.ArrayList([]const u8) = .empty;
    var log: ?Io.File = null;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--step")) {
            try steps.append(init.arena.allocator(), args[i + 1]);
        } else if (std.mem.eql(u8, args[i], "--log")) {
            log = try Io.Dir.cwd().createFile(io, args[i + 1], .{ .truncate = true });
        } else return error.Usage;
    }
    const m = try FakeModel.start(gpa, io, port, if (steps.items.len > 0) steps.items else &default_steps, log);
    defer m.stop();
    std.debug.print("scripted test model on http://127.0.0.1:{d}/v1 (model {s}); not a real model\n", .{ m.port, model_id });
    while (true) try io.sleep(.fromSeconds(3600), .awake);
}
