//! `blackice run`: runs one command in a new task scope.
//!
//!     blackice run --policy FILE [--env NAME]... [--relay --model ID [--model ID]... [--upstream URL]
//!                  [--max-requests N]] -- CMD [ARG]...
//!
//! Order: the policy is read and checked, the scope directory is created (receipts and an exact copy of the
//! policy), the proxy and the owner's control socket start (and the relay, when asked), and only then does the
//! backend start CMD, already confined. blackice never runs CMD without an enforcing backend.
//!
//! CMD gets a clean environment: a short list of variables (PATH, HOME, TERM, locale and a few more), the ones
//! named with --env, BLACKICE_SCOPE, and the proxy variables. Nothing else from the caller's environment
//! passes, so tokens and keys in it stay out of the scope.
//!
//! With --relay, the provider key is read from stdin, never from argv, the environment or a file, after the
//! process has been made non-dumpable. CMD reaches the model at BLACKICE_RELAY_URL.
//!
//! Exit status: CMD's own status (128 + signal when it was killed), 125 when blackice could not set up the
//! scope, 127 when the backend could not start CMD.

const std = @import("std");
const Io = std.Io;
const policy = @import("../core/policy.zig");
const receipt = @import("../core/receipt.zig");
const scope = @import("../core/scope.zig");
const backend = @import("../core/backend.zig");
const proxy = @import("../proxy/proxy.zig");
const relay = @import("../relay/relay.zig");
const control = @import("../control/control.zig");

pub const usage =
    \\usage: blackice run --policy FILE [--env NAME]... [--relay --model ID... [--upstream URL] [--max-requests N]]
    \\                    -- CMD [ARG]...
    \\
;

pub const status_setup_failed: u8 = 125;
pub const status_spawn_failed: u8 = 127;

/// Variables passed from the caller's environment when present. Everything else is dropped.
pub const pass_env = [_][]const u8{
    "PATH",            "HOME",           "USER",          "LOGNAME",        "SHELL",
    "TERM",            "COLORTERM",      "NO_COLOR",      "LANG",           "LANGUAGE",
    "LC_ALL",          "LC_CTYPE",       "LC_MESSAGES",   "TZ",             "TMPDIR",
    "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
};

const max_models = 16;
const max_env = 32;

pub const Options = struct {
    policy_path: []const u8 = "",
    env_names: [max_env][]const u8 = undefined,
    env_count: usize = 0,
    relay: bool = false,
    models: [max_models][]const u8 = undefined,
    model_count: usize = 0,
    upstream: ?[]const u8 = null,
    max_requests: u32 = 50,
    argv: []const []const u8 = &.{},
};

/// Parses the arguments after "run". `err` gets a one-line reason on failure.
pub fn parseArgs(args: []const []const u8, err: *[]const u8) error{Usage}!Options {
    var o: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            o.argv = args[i + 1 ..];
            break;
        }
        const value_flags = [_][]const u8{ "--policy", "--env", "--model", "--upstream", "--max-requests" };
        var takes_value = false;
        for (value_flags) |f| takes_value = takes_value or std.mem.eql(u8, a, f);
        if (takes_value and i + 1 >= args.len) {
            err.* = "a flag is missing its value";
            return error.Usage;
        }
        if (std.mem.eql(u8, a, "--policy")) {
            i += 1;
            o.policy_path = args[i];
        } else if (std.mem.eql(u8, a, "--env")) {
            i += 1;
            if (o.env_count == max_env or args[i].len == 0 or std.mem.findScalar(u8, args[i], '=') != null) {
                err.* = "--env takes a variable name (at most 32 of them); values are copied from your environment";
                return error.Usage;
            }
            o.env_names[o.env_count] = args[i];
            o.env_count += 1;
        } else if (std.mem.eql(u8, a, "--relay")) {
            o.relay = true;
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (o.model_count == max_models) {
                err.* = "at most 16 --model flags";
                return error.Usage;
            }
            o.models[o.model_count] = args[i];
            o.model_count += 1;
        } else if (std.mem.eql(u8, a, "--upstream")) {
            i += 1;
            o.upstream = args[i];
        } else if (std.mem.eql(u8, a, "--max-requests")) {
            i += 1;
            o.max_requests = std.fmt.parseInt(u32, args[i], 10) catch {
                err.* = "--max-requests takes a number";
                return error.Usage;
            };
        } else {
            err.* = "unknown flag; the command goes after --";
            return error.Usage;
        }
    }
    if (o.policy_path.len == 0) {
        err.* = "--policy FILE is required";
        return error.Usage;
    }
    if (o.argv.len == 0) {
        err.* = "no command; put it after --";
        return error.Usage;
    }
    if (!o.relay and (o.model_count > 0 or o.upstream != null)) {
        err.* = "--model and --upstream need --relay";
        return error.Usage;
    }
    if (o.relay and o.model_count == 0) {
        err.* = "--relay needs at least one --model";
        return error.Usage;
    }
    return o;
}

/// Builds CMD's environment: the passed variables that exist, the --env ones, BLACKICE_SCOPE, then the proxy
/// variables (which win over anything with the same name).
pub fn buildEnv(
    gpa: std.mem.Allocator,
    parent: *const std.process.Environ.Map,
    extra: []const []const u8,
    scope_id: []const u8,
    proxy_port: u16,
) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(gpa);
    errdefer env.deinit();
    for (pass_env) |name| if (parent.get(name)) |v| try env.put(name, v);
    for (extra) |name| if (parent.get(name)) |v| try env.put(name, v);
    try env.put("BLACKICE_SCOPE", scope_id);
    try proxy.setEnv(&env, proxy_port);
    return env;
}

fn basename(path: []const u8) []const u8 {
    return if (std.mem.findScalarLast(u8, path, '/')) |i| path[i + 1 ..] else path;
}

pub fn run(gpa: std.mem.Allocator, io: Io, parent_env: *const std.process.Environ.Map, args: []const []const u8, errw: *Io.Writer) !u8 {
    var why: []const u8 = "";
    const o = parseArgs(args, &why) catch {
        try errw.print("blackice run: {s}\n{s}", .{ why, usage });
        return 2;
    };

    if (!backend.available) {
        try errw.print("blackice run: no enforcing backend on this system ({s}); the command was not run\n", .{backend.name});
        return status_setup_failed;
    }

    // 1. The policy, checked before anything else happens.
    const bytes = Io.Dir.cwd().readFileAlloc(io, o.policy_path, gpa, .limited(1 << 20)) catch |err| {
        try errw.print("blackice run: cannot read {s}: {s}\n", .{ o.policy_path, @errorName(err) });
        return status_setup_failed;
    };
    defer gpa.free(bytes);
    var diag: policy.Diagnostic = .{};
    var pol = policy.Policy.parse(gpa, bytes, &diag) catch |err| {
        try errw.print("blackice run: {s}: {s}: {s} ({s})\n", .{ o.policy_path, @errorName(err), diag.message, diag.item() });
        return status_setup_failed;
    };
    defer pol.deinit();
    if (pol.ignoredAllowCount() > 0) {
        try errw.print("blackice run: warning: mode {s} ignores the {d} allow entries\n", .{ pol.mode.label(), pol.ignoredAllowCount() });
    }

    // 2. The relay key, before any scope exists, and only after the process cannot be inspected.
    var key_buf: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &key_buf);
    var key: []const u8 = "";
    if (o.relay) {
        if (!relay.hardenProcess()) {
            try errw.writeAll("blackice run: cannot make this process non-dumpable; refusing to read the relay key\n");
            return status_setup_failed;
        }
        key = relay.readKey(io, .stdin(), &key_buf) catch |err| {
            try errw.print("blackice run: relay key on stdin: {s}\n", .{@errorName(err)});
            return status_setup_failed;
        };
    }

    // 3. The scope: directory, exact policy copy, receipts.
    const created = scope.create(gpa, io, parent_env) catch |err| {
        try errw.print("blackice run: cannot create the scope directory: {s}\n", .{@errorName(err)});
        return status_setup_failed;
    };
    defer gpa.free(created.path);
    const sid = created.id();
    const state_root = scope.realStateRoot(gpa, io, parent_env) catch |err| {
        try errw.print("blackice run: cannot resolve the state root: {s}\n", .{@errorName(err)});
        return status_setup_failed;
    };
    defer gpa.free(state_root);

    var scope_dir = Io.Dir.cwd().openDir(io, created.path, .{}) catch |err| {
        try errw.print("blackice run: cannot open {s}: {s}\n", .{ created.path, @errorName(err) });
        return status_setup_failed;
    };
    defer scope_dir.close(io);
    {
        const f = scope_dir.createFile(io, "policy.json", .{ .exclusive = true, .permissions = receipt.private_file }) catch |err| {
            try errw.print("blackice run: cannot write the policy copy: {s}\n", .{@errorName(err)});
            return status_setup_failed;
        };
        defer f.close(io);
        f.writePositionalAll(io, pol.bytes, 0) catch |err| {
            try errw.print("blackice run: cannot write the policy copy: {s}\n", .{@errorName(err)});
            return status_setup_failed;
        };
    }
    var log = receipt.Log.open(io, scope_dir, "receipts.jsonl", sid, pol.id()) catch |err| {
        try errw.print("blackice run: cannot create the receipts file: {s}\n", .{@errorName(err)});
        return status_setup_failed;
    };
    defer log.close();

    // 4. The proxy (and the relay), outside the scope.
    var grants: proxy.Grants = .init(gpa);
    defer grants.deinit();
    const px = proxy.Proxy.start(gpa, io, &pol, &log, .{ .grants = &grants }) catch |err| {
        log.write(.{ .event = "warning", .point = .control, .reason = "proxy_start_failed", .detail = @errorName(err) });
        log.end(status_setup_failed, "proxy did not start");
        try errw.print("blackice run: the proxy did not start: {s}\n", .{@errorName(err)});
        return status_setup_failed;
    };
    var px_running = true;
    defer if (px_running) px.stop();

    // The owner's control socket (grants), unreachable from inside the scope.
    const ctl = control.Server.start(gpa, io, created.path, &grants, &log) catch |err| {
        log.write(.{ .event = "warning", .point = .control, .reason = "control_start_failed", .detail = @errorName(err) });
        log.end(status_setup_failed, "control socket did not start");
        try errw.print("blackice run: the control socket did not start: {s}\n", .{@errorName(err)});
        return status_setup_failed;
    };
    var ctl_running = true;
    defer if (ctl_running) ctl.stop();

    var ports_buf: [2]u16 = .{ px.port, 0 };
    var ports: []const u16 = ports_buf[0..1];
    var rl: ?*relay.Relay = null;
    defer if (rl) |r| r.stop();
    if (o.relay) {
        rl = relay.Relay.start(gpa, io, .{
            .upstream = o.upstream orelse relay.default_upstream,
            .models = o.models[0..o.model_count],
            .max_requests = o.max_requests,
        }, key, &log) catch |err| {
            log.write(.{ .event = "warning", .point = .control, .reason = "relay_start_failed", .detail = @errorName(err) });
            log.end(status_setup_failed, "relay did not start");
            try errw.print("blackice run: the relay did not start: {s}\n", .{@errorName(err)});
            return status_setup_failed;
        };
        std.crypto.secureZero(u8, &key_buf);
        key = "";
        ports_buf[1] = rl.?.port;
        ports = ports_buf[0..2];
    }

    // 5. The command's environment.
    var env = try buildEnv(gpa, parent_env, o.env_names[0..o.env_count], sid, px.port);
    defer env.deinit();
    var url_buf: [64]u8 = undefined;
    if (rl) |r| try env.put("BLACKICE_RELAY_URL", try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1", .{r.port}));

    var detail_buf: [160]u8 = undefined;
    const start_detail = std.fmt.bufPrint(&detail_buf, "backend {s}; command {s}; proxy port {d}{s}", .{
        backend.name,
        basename(o.argv[0]),
        px.port,
        if (rl != null) "; relay on" else "",
    }) catch "backend";
    log.write(.{ .event = "scope_start", .point = .control, .detail = start_detail });
    try errw.print("blackice: scope {s} (policy {s}, {s}); receipts: {s}/receipts.jsonl\n", .{ sid, pol.id(), backend.name, created.path });
    try errw.print("blackice: to allow one more host for a while: blackice grant {s} HOST --for 10m\n", .{sid});
    try errw.flush();

    // 6. The command, confined before it runs.
    const exit: backend.Exit = backend.launch(gpa, io, .{
        .scope_id = sid,
        .argv = o.argv,
        .environ = &env,
        .allowed_loopback_ports = ports,
        .state_dir = state_root,
        .receipts = &log,
    }) catch |err| {
        const status: u8 = if (err == error.BackendUnavailable) status_setup_failed else status_spawn_failed;
        ctl.stop();
        ctl_running = false;
        if (rl) |r| r.stop();
        rl = null;
        px.stop();
        px_running = false;
        log.end(status, @errorName(err));
        try errw.print("blackice run: the command was not started: {s}\n", .{@errorName(err)});
        return status;
    };

    // 7. Stop the control socket, the relay and the proxy before the last receipt, so scope_end is the final line.
    ctl.stop();
    ctl_running = false;
    if (rl) |r| r.stop();
    rl = null;
    px.stop();
    px_running = false;
    const status = exit.status();
    log.end(status, null);
    try errw.print("blackice: scope {s} ended with status {d}; {d} receipts", .{ sid, status, log.written });
    if (log.failures > 0) try errw.print(", {d} could not be written", .{log.failures});
    try errw.writeAll("\n");
    return status;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test parseArgs {
    var why: []const u8 = "";
    const ok = try parseArgs(&.{ "--policy", "p.json", "--env", "GITHUB_TOKEN", "--", "curl", "-s", "https://example.com" }, &why);
    try testing.expectEqualStrings("p.json", ok.policy_path);
    try testing.expectEqual(@as(usize, 1), ok.env_count);
    try testing.expectEqual(@as(usize, 3), ok.argv.len);
    try testing.expectEqualStrings("--", (try parseArgs(&.{ "--policy", "p", "--", "echo", "--" }, &why)).argv[1]);

    const relay_ok = try parseArgs(&.{ "--policy", "p", "--relay", "--model", "openai/gpt-5", "--max-requests", "7", "--", "fx" }, &why);
    try testing.expect(relay_ok.relay);
    try testing.expectEqual(@as(u32, 7), relay_ok.max_requests);

    try testing.expectError(error.Usage, parseArgs(&.{ "--", "echo" }, &why));
    try testing.expectError(error.Usage, parseArgs(&.{ "--policy", "p" }, &why));
    try testing.expectError(error.Usage, parseArgs(&.{ "--policy", "p", "echo" }, &why));
    try testing.expectError(error.Usage, parseArgs(&.{ "--policy", "p", "--env", "A=1", "--", "echo" }, &why));
    try testing.expectError(error.Usage, parseArgs(&.{ "--policy", "p", "--relay", "--", "fx" }, &why));
    try testing.expectError(error.Usage, parseArgs(&.{ "--policy", "p", "--model", "m", "--", "fx" }, &why));
    try testing.expectError(error.Usage, parseArgs(&.{"--policy"}, &why));
}

test buildEnv {
    var parent: std.process.Environ.Map = .init(testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin");
    try parent.put("HOME", "/home/u");
    try parent.put("AWS_SECRET_ACCESS_KEY", "synthetic-not-a-key");
    try parent.put("GITHUB_TOKEN", "synthetic-token");
    try parent.put("NO_PROXY", "*");
    try parent.put("HTTPS_PROXY", "http://elsewhere:1");

    var env = try buildEnv(testing.allocator, &parent, &.{"GITHUB_TOKEN"}, "s-0000abcd", 18780);
    defer env.deinit();
    try testing.expectEqualStrings("/usr/bin", env.get("PATH").?);
    try testing.expectEqualStrings("synthetic-token", env.get("GITHUB_TOKEN").?);
    try testing.expect(env.get("AWS_SECRET_ACCESS_KEY") == null);
    try testing.expectEqualStrings("s-0000abcd", env.get("BLACKICE_SCOPE").?);
    try testing.expect(std.mem.endsWith(u8, env.get("HTTPS_PROXY").?, ":18780"));
    try testing.expect(!std.mem.eql(u8, env.get("NO_PROXY").?, "*"));
}
