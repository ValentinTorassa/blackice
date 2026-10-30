//! `blackice run`: runs one command in a new task scope.
//!
//!     blackice run --policy FILE [--policy-sha256 HEX] [--protect PATH]... [--env NAME]...
//!                  [--relay --model ID [--model ID]... [--upstream URL] [--max-requests N]] -- CMD [ARG]...
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
//! process has been made non-dumpable. CMD reaches the model at BLACKICE_RELAY_URL with the relay's per-scope
//! token in BLACKICE_RELAY_TOKEN (a bearer token for the relay only; the provider key never enters the scope).
//!
//! CMD cannot change blackice's own executable, the policy file, or the files named with --protect (the
//! backend refuses writes to them and renames of their parent directories), so a scoped command cannot swap
//! in what the next scope runs. With --policy-sha256 the policy must also hash to that value, or nothing runs:
//! an agent harness pins the policy once and every later scope uses exactly that policy.
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
    \\usage: blackice run --policy FILE [--policy-sha256 HEX] [--protect PATH]... [--env NAME]...
    \\                    [--relay --model ID... [--upstream URL] [--max-requests N]] -- CMD [ARG]...
    \\
;

pub const status_setup_failed: u8 = 125;
pub const status_spawn_failed: u8 = 127;

/// Variables passed from the caller's environment when present. Everything else is dropped.
pub const pass_env = [_][]const u8{
    "PATH",            "HOME",           "USER",          "LOGNAME",        "SHELL",
    "TERM",            "COLORTERM",      "NO_COLOR",      "LANG",           "LANGUAGE",
    "LC_ALL",          "LC_CTYPE",       "LC_MESSAGES",   "TZ",             "TMPDIR",
    "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "AI_AGENT",
};

const max_models = 16;
const max_env = 32;
const max_protect = 8;

pub const Options = struct {
    policy_path: []const u8 = "",
    /// 64 lowercase hex digits.
    policy_sha256: ?[]const u8 = null,
    protect: [max_protect][]const u8 = undefined,
    protect_count: usize = 0,
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
        const value_flags = [_][]const u8{ "--policy", "--policy-sha256", "--protect", "--env", "--model", "--upstream", "--max-requests" };
        var takes_value = false;
        for (value_flags) |f| takes_value = takes_value or std.mem.eql(u8, a, f);
        if (takes_value and i + 1 >= args.len) {
            err.* = "a flag is missing its value";
            return error.Usage;
        }
        if (std.mem.eql(u8, a, "--policy")) {
            i += 1;
            o.policy_path = args[i];
        } else if (std.mem.eql(u8, a, "--policy-sha256")) {
            i += 1;
            if (!isSha256Hex(args[i])) {
                err.* = "--policy-sha256 takes 64 lowercase hex digits";
                return error.Usage;
            }
            o.policy_sha256 = args[i];
        } else if (std.mem.eql(u8, a, "--protect")) {
            i += 1;
            if (o.protect_count == max_protect or args[i].len == 0 or args[i][0] != '/') {
                err.* = "--protect takes an absolute path (at most 8 of them)";
                return error.Usage;
            }
            o.protect[o.protect_count] = args[i];
            o.protect_count += 1;
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

fn isSha256Hex(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// sha256 of `bytes` as 64 lowercase hex digits.
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// The files CMD must not change, resolved: blackice's own executable, the policy file, the --protect paths.
const Protected = struct {
    store: [max_protect + 2][:0]u8 = undefined,
    view: [max_protect + 2][]const u8 = undefined,
    n: usize = 0,

    fn deinit(p: *Protected, gpa: std.mem.Allocator) void {
        for (p.store[0..p.n]) |s| gpa.free(s);
        p.n = 0;
    }

    fn add(p: *Protected, path: [:0]u8) void {
        p.store[p.n] = path;
        p.view[p.n] = path;
        p.n += 1;
    }

    fn paths(p: *const Protected) []const []const u8 {
        return p.view[0..p.n];
    }
};

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
    if (o.policy_sha256) |want| {
        const got = sha256Hex(bytes);
        if (!std.mem.eql(u8, &got, want)) {
            try errw.print("blackice run: {s} does not match --policy-sha256 (it changed after it was pinned); the command was not run\n", .{o.policy_path});
            return status_setup_failed;
        }
    }

    // The files CMD must not change, resolved before any scope exists.
    var prot: Protected = .{};
    defer prot.deinit(gpa);
    prot.add(std.process.executablePathAlloc(io, gpa) catch |err| {
        try errw.print("blackice run: cannot resolve blackice's own executable: {s}\n", .{@errorName(err)});
        return status_setup_failed;
    });
    prot.add(Io.Dir.cwd().realPathFileAlloc(io, o.policy_path, gpa) catch |err| {
        try errw.print("blackice run: cannot resolve {s}: {s}\n", .{ o.policy_path, @errorName(err) });
        return status_setup_failed;
    });
    for (o.protect[0..o.protect_count]) |path| {
        prot.add(Io.Dir.realPathFileAbsoluteAlloc(io, path, gpa) catch |err| {
            try errw.print("blackice run: cannot resolve --protect {s}: {s}\n", .{ path, @errorName(err) });
            return status_setup_failed;
        });
    }

    // 2. The relay key, before any scope exists, and only after the process cannot be inspected. A terminal
    //    would echo it, so it must come from a pipe or a file; CMD later gets /dev/null as stdin, so it cannot
    //    read the key back from the same stream.
    var key_buf: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &key_buf);
    var key: []const u8 = "";
    if (o.relay) {
        if (Io.File.stdin().isTty(io) catch true) {
            try errw.writeAll("blackice run: give the relay key on stdin from a pipe or a file, not a terminal (it would be echoed)\n");
            return status_setup_failed;
        }
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
    // The backends protect the state root by its resolved path, so the scope directory must really be inside it.
    {
        const real_dir = Io.Dir.realPathFileAbsoluteAlloc(io, created.path, gpa) catch |err| {
            try errw.print("blackice run: cannot resolve the scope directory: {s}\n", .{@errorName(err)});
            return status_setup_failed;
        };
        defer gpa.free(real_dir);
        const expected = try std.fs.path.join(gpa, &.{ state_root, "scopes", sid });
        defer gpa.free(expected);
        if (!std.mem.eql(u8, real_dir, expected)) {
            try errw.print("blackice run: the scope directory resolves to {s}, outside the state root {s}\n", .{ real_dir, state_root });
            return status_setup_failed;
        }
    }

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

    // From here on every exit goes through `svc.finish`, which stops what started and then writes scope_end,
    // so scope_end is always the last line.
    var grants: proxy.Grants = .init(gpa);
    defer grants.deinit();
    var svc: Services = .{ .log = &log, .errw = errw };
    defer svc.stopAll();

    // 4. The proxy, the owner's control socket and the relay, all outside the scope.
    svc.px = proxy.Proxy.start(gpa, io, &pol, &log, .{ .grants = &grants }) catch |err|
        return svc.finish(status_setup_failed, "proxy_start_failed", @errorName(err));
    svc.ctl = control.Server.start(gpa, io, created.path, &grants, &log) catch |err|
        return svc.finish(status_setup_failed, "control_start_failed", @errorName(err));
    const proxy_port = svc.px.?.port;
    var ports_buf: [2]u16 = .{ proxy_port, 0 };
    var ports: []const u16 = ports_buf[0..1];
    if (o.relay) {
        svc.rl = relay.Relay.start(gpa, io, .{
            .upstream = o.upstream orelse relay.default_upstream,
            .models = o.models[0..o.model_count],
            .max_requests = o.max_requests,
        }, key, &log) catch |err| return svc.finish(status_setup_failed, "relay_start_failed", @errorName(err));
        std.crypto.secureZero(u8, &key_buf);
        key = "";
        ports_buf[1] = svc.rl.?.port;
        ports = ports_buf[0..2];
    }

    // 5. The command's environment.
    var env = buildEnv(gpa, parent_env, o.env_names[0..o.env_count], sid, proxy_port) catch |err|
        return svc.finish(status_setup_failed, "environment_failed", @errorName(err));
    defer env.deinit();
    var url_buf: [64]u8 = undefined;
    if (svc.rl) |r| {
        const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1", .{r.port}) catch unreachable;
        env.put("BLACKICE_RELAY_URL", url) catch |err| return svc.finish(status_setup_failed, "environment_failed", @errorName(err));
        // The relay's per-scope caller token (not the provider key): a client in the scope sends it as a bearer
        // token, for example fx with auth {"type":"bearer","env":"BLACKICE_RELAY_TOKEN"}.
        env.put("BLACKICE_RELAY_TOKEN", r.token()) catch |err| return svc.finish(status_setup_failed, "environment_failed", @errorName(err));
    }

    var detail_buf: [160]u8 = undefined;
    const start_detail = std.fmt.bufPrint(&detail_buf, "backend {s}; command {s}; proxy port {d}{s}; {d} protected files{s}", .{
        backend.name,
        basename(o.argv[0]),
        proxy_port,
        if (svc.rl != null) "; relay on" else "",
        prot.n,
        if (o.policy_sha256 != null) "; policy pinned" else "",
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
        .protected_paths = prot.paths(),
        .receipts = &log,
        .stdin = if (o.relay) .null_device else .inherit,
    }) catch |err| {
        const status: u8 = if (err == error.BackendUnavailable) status_setup_failed else status_spawn_failed;
        return svc.finish(status, "command_not_started", @errorName(err));
    };

    // 7. Stop everything, then the last receipt.
    const status = exit.status();
    _ = try svc.finish(status, null, null);
    try errw.print("blackice: scope {s} ended with status {d}; {d} receipts", .{ sid, status, log.written });
    if (log.failures > 0) try errw.print(", {d} could not be written", .{log.failures});
    try errw.writeAll("\n");
    return status;
}

/// The services of a running scope, stopped in a fixed order: control socket, relay, proxy.
const Services = struct {
    log: *receipt.Log,
    errw: *Io.Writer,
    px: ?*proxy.Proxy = null,
    ctl: ?*control.Server = null,
    rl: ?*relay.Relay = null,
    ended: bool = false,

    fn stopAll(s: *Services) void {
        if (s.ctl) |c| c.stop();
        s.ctl = null;
        if (s.rl) |r| r.stop();
        s.rl = null;
        if (s.px) |p| p.stop();
        s.px = null;
    }

    /// Stops the services, then writes scope_end (once). With a reason it is a failure: a warning receipt and a
    /// message come first.
    fn finish(s: *Services, status: u8, reason: ?[]const u8, detail: ?[]const u8) !u8 {
        if (reason) |r| s.log.write(.{ .event = "warning", .point = .control, .reason = r, .detail = detail });
        s.stopAll();
        if (!s.ended) s.log.end(status, reason);
        s.ended = true;
        if (reason) |r| try s.errw.print("blackice run: {s}: {s}\n", .{ r, detail orelse "" });
        return status;
    }
};

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

    const pinned = try parseArgs(&.{ "--policy", "p", "--policy-sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--protect", "/usr/local/bin/fx", "--", "sh" }, &why);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", pinned.policy_sha256.?);
    try testing.expectEqualStrings("/usr/local/bin/fx", pinned.protect[0]);
    try testing.expectError(error.Usage, parseArgs(&.{ "--policy", "p", "--policy-sha256", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "--", "sh" }, &why));
    try testing.expectError(error.Usage, parseArgs(&.{ "--policy", "p", "--policy-sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--", "sh" }, &why));
    try testing.expectError(error.Usage, parseArgs(&.{ "--policy", "p", "--protect", "relative", "--", "sh" }, &why));
}

test sha256Hex {
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &sha256Hex(""));
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
