//! Policy v0: which destinations a scope may reach.
//!
//! File format (JSON, unknown fields are rejected so a typo cannot widen a policy):
//!
//!     {
//!       "version": "blackice.policy/v0",
//!       "network": {
//!         "mode": "allowlist",               // "deny-all" | "allow-all" | "allowlist"
//!         "allow": ["example.com", "*.npmjs.org"],
//!         "subnets": { "allow": ["10.20.0.0/16"], "deny": ["203.0.113.0/24"] }
//!       }
//!     }
//!
//! Matching rules:
//! - Names are compared in lowercase, without a trailing dot.
//! - "example.com" matches only example.com.
//! - "*.example.com" matches any name below example.com (a.example.com, a.b.example.com), not example.com.
//! - After a name is allowed, every address it resolves to is checked again:
//!   denied subnets always lose; allowed subnets win; loopback, private, link-local, CGNAT and multicast
//!   addresses are refused unless an allowed subnet covers them. This stops an allowed name that resolves
//!   to 127.0.0.1 from reaching local services.
//! - A destination written as an IP address is allowed only by an allowed subnet (or by allow-all, for
//!   public addresses).

const std = @import("std");
const net = std.Io.net;

pub const version_v0 = "blackice.policy/v0";
pub const max_host_len = 253;

pub const Mode = enum {
    deny_all,
    allow_all,
    allowlist,

    pub fn label(m: Mode) []const u8 {
        return switch (m) {
            .deny_all => "deny-all",
            .allow_all => "allow-all",
            .allowlist => "allowlist",
        };
    }
};

/// Stable reason codes. Receipts carry them; do not rename without a contract change.
pub const Reason = enum {
    allowed_by_rule,
    allowed_by_mode,
    allowed_subnet,
    public_address,
    no_matching_rule,
    mode_deny_all,
    ip_literal_needs_subnet,
    denied_subnet,
    local_or_private_address,
    invalid_host,

    pub fn code(r: Reason) []const u8 {
        return @tagName(r);
    }
};

pub const Verdict = struct {
    allowed: bool,
    reason: Reason,
    /// The policy entry that decided, as written in the file. Borrowed from the policy.
    rule: ?[]const u8 = null,
};

pub const Pattern = struct {
    /// Lowercase. For a wildcard: the suffix with its leading dot, e.g. ".example.com".
    text: []const u8,
    wildcard: bool,
    /// As written in the policy file, for receipts.
    source: []const u8,

    /// `host` must already be normalized (see `normalizeHost`).
    pub fn matches(p: Pattern, host: []const u8) bool {
        if (p.wildcard) return host.len > p.text.len and std.mem.endsWith(u8, host, p.text);
        return std.mem.eql(u8, host, p.text);
    }
};

pub const Cidr = struct {
    is_ip4: bool,
    /// Network bytes; IPv4 uses the first four.
    bytes: [16]u8,
    prefix: u8,
    source: []const u8,

    pub fn parse(text: []const u8) error{InvalidSubnet}!Cidr {
        const slash = std.mem.findScalar(u8, text, '/') orelse return error.InvalidSubnet;
        const addr = net.IpAddress.parse(text[0..slash], 0) catch return error.InvalidSubnet;
        const prefix = std.fmt.parseInt(u8, text[slash + 1 ..], 10) catch return error.InvalidSubnet;
        var c: Cidr = .{ .is_ip4 = addr == .ip4, .bytes = @splat(0), .prefix = prefix, .source = text };
        switch (addr) {
            .ip4 => |a| {
                if (prefix > 32) return error.InvalidSubnet;
                @memcpy(c.bytes[0..4], &a.bytes);
            },
            .ip6 => |a| {
                if (prefix > 128) return error.InvalidSubnet;
                c.bytes = a.bytes;
            },
        }
        return c;
    }

    pub fn contains(c: Cidr, addr: net.IpAddress) bool {
        var b: [16]u8 = undefined;
        const len: usize = switch (addr) {
            .ip4 => |a| blk: {
                @memcpy(b[0..4], &a.bytes);
                break :blk 4;
            },
            .ip6 => |a| blk: {
                if (mappedIp4(a.bytes)) |v4| {
                    @memcpy(b[0..4], &v4);
                    break :blk 4;
                }
                b = a.bytes;
                break :blk 16;
            },
        };
        if ((len == 4) != c.is_ip4) return false;
        return prefixMatch(c.bytes[0..len], b[0..len], c.prefix);
    }
};

fn prefixMatch(network: []const u8, addr: []const u8, prefix: u8) bool {
    const full: usize = prefix / 8;
    if (!std.mem.eql(u8, network[0..full], addr[0..full])) return false;
    const rem: u8 = prefix % 8;
    if (rem == 0) return true;
    const shift: u3 = @intCast(8 - rem);
    const mask: u8 = @as(u8, 0xff) << shift;
    return (network[full] & mask) == (addr[full] & mask);
}

/// IPv4-mapped IPv6 (::ffff:a.b.c.d) is treated as the IPv4 address it carries.
fn mappedIp4(b: [16]u8) ?[4]u8 {
    if (!std.mem.allEqual(u8, b[0..10], 0) or b[10] != 0xff or b[11] != 0xff) return null;
    return b[12..16].*;
}

fn isLocalIp4(b: [4]u8) bool {
    return b[0] == 0 or // "this network"
        b[0] == 10 or
        b[0] == 127 or
        (b[0] == 100 and (b[1] & 0xc0) == 64) or // 100.64.0.0/10, CGNAT (also Tailscale)
        (b[0] == 169 and b[1] == 254) or
        (b[0] == 172 and (b[1] & 0xf0) == 16) or
        (b[0] == 192 and b[1] == 0 and b[2] == 0) or
        (b[0] == 192 and b[1] == 168) or
        (b[0] == 198 and (b[1] & 0xfe) == 18) or // benchmarking
        b[0] >= 224; // multicast, reserved, broadcast
}

/// Loopback, unspecified, private, link-local, CGNAT, multicast and reserved addresses.
pub fn isLocalOrPrivate(addr: net.IpAddress) bool {
    switch (addr) {
        .ip4 => |a| return isLocalIp4(a.bytes),
        .ip6 => |a| {
            const b = a.bytes;
            if (mappedIp4(b)) |v4| return isLocalIp4(v4);
            if (std.mem.allEqual(u8, b[0..15], 0) and (b[15] == 0 or b[15] == 1)) return true; // :: and ::1
            if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7
            if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return true; // fe80::/10
            if (b[0] == 0xfe and (b[1] & 0xc0) == 0xc0) return true; // fec0::/10
            if (b[0] == 0xff) return true; // multicast
            return false;
        },
    }
}

/// Lowercases `raw` into `buf`, drops one trailing dot and checks the characters.
pub fn normalizeHost(buf: *[max_host_len]u8, raw: []const u8) error{InvalidHost}![]const u8 {
    var host = raw;
    if (host.len > 0 and host[host.len - 1] == '.') host = host[0 .. host.len - 1];
    if (host.len == 0 or host.len > max_host_len) return error.InvalidHost;
    var label_len: usize = 0;
    for (host, 0..) |c, i| {
        const lc = std.ascii.toLower(c);
        switch (lc) {
            'a'...'z', '0'...'9', '-', '_' => label_len += 1,
            '.' => {
                if (label_len == 0) return error.InvalidHost;
                label_len = 0;
            },
            else => return error.InvalidHost,
        }
        if (label_len > 63) return error.InvalidHost;
        buf[i] = lc;
    }
    if (label_len == 0) return error.InvalidHost;
    return buf[0..host.len];
}

/// An IPv4 address, or an IPv6 address without brackets.
pub fn parseIpLiteral(host: []const u8) ?net.IpAddress {
    return net.IpAddress.parse(host, 0) catch null;
}

pub const Diagnostic = struct {
    message: []const u8 = "",
    item: []const u8 = "",
};

const RawSubnets = struct {
    allow: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
};
const RawNetwork = struct {
    mode: []const u8,
    allow: []const []const u8 = &.{},
    subnets: RawSubnets = .{},
};
const Raw = struct {
    version: []const u8,
    network: RawNetwork,
};

pub const Policy = struct {
    arena: std.heap.ArenaAllocator,
    mode: Mode,
    allow: []const Pattern,
    allow_subnets: []const Cidr,
    deny_subnets: []const Cidr,
    /// SHA-256 of the policy file bytes, lowercase hex. Receipts carry a prefix of it.
    digest_hex: [64]u8,

    pub const ParseError = error{
        InvalidJson,
        UnsupportedVersion,
        UnknownMode,
        InvalidPattern,
        InvalidSubnet,
        OutOfMemory,
    };

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, diag: ?*Diagnostic) ParseError!Policy {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const raw = std.json.parseFromSliceLeaky(Raw, a, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (diag) |d| d.* = .{ .message = "not valid policy JSON (unknown fields are rejected)", .item = @errorName(err) };
                return error.InvalidJson;
            },
        };
        if (!std.mem.eql(u8, raw.version, version_v0)) {
            if (diag) |d| d.* = .{ .message = "unsupported policy version; expected " ++ version_v0, .item = raw.version };
            return error.UnsupportedVersion;
        }

        const mode: Mode = if (std.mem.eql(u8, raw.network.mode, "deny-all"))
            .deny_all
        else if (std.mem.eql(u8, raw.network.mode, "allow-all"))
            .allow_all
        else if (std.mem.eql(u8, raw.network.mode, "allowlist"))
            .allowlist
        else {
            if (diag) |d| d.* = .{ .message = "unknown mode; use deny-all, allow-all or allowlist", .item = raw.network.mode };
            return error.UnknownMode;
        };

        const patterns = try a.alloc(Pattern, raw.network.allow.len);
        for (raw.network.allow, patterns) |src, *p| {
            p.* = parsePattern(a, src) catch |err| {
                if (diag) |d| d.* = .{
                    .message = "invalid allow entry; use a name or *.name (addresses go in subnets.allow)",
                    .item = src,
                };
                return err;
            };
        }

        const allow_subnets = try parseCidrs(a, raw.network.subnets.allow, diag);
        const deny_subnets = try parseCidrs(a, raw.network.subnets.deny, diag);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

        return .{
            .arena = arena,
            .mode = mode,
            .allow = patterns,
            .allow_subnets = allow_subnets,
            .deny_subnets = deny_subnets,
            .digest_hex = std.fmt.bytesToHex(digest, .lower),
        };
    }

    pub fn deinit(p: *Policy) void {
        p.arena.deinit();
        p.* = undefined;
    }

    /// Short policy identifier for receipts: the first 12 hex digits of the digest.
    pub fn id(p: *const Policy) []const u8 {
        return p.digest_hex[0..12];
    }

    /// Decides a destination given by name. `host` must be normalized and must not be an IP literal.
    pub fn checkHost(p: *const Policy, host: []const u8) Verdict {
        switch (p.mode) {
            .deny_all => return .{ .allowed = false, .reason = .mode_deny_all },
            .allow_all => return .{ .allowed = true, .reason = .allowed_by_mode },
            .allowlist => {
                for (p.allow) |pat| {
                    if (pat.matches(host)) return .{ .allowed = true, .reason = .allowed_by_rule, .rule = pat.source };
                }
                return .{ .allowed = false, .reason = .no_matching_rule };
            },
        }
    }

    /// Checks one address that an allowed name resolved to.
    pub fn checkResolved(p: *const Policy, addr: net.IpAddress) Verdict {
        for (p.deny_subnets) |c| if (c.contains(addr)) return .{ .allowed = false, .reason = .denied_subnet, .rule = c.source };
        for (p.allow_subnets) |c| if (c.contains(addr)) return .{ .allowed = true, .reason = .allowed_subnet, .rule = c.source };
        if (isLocalOrPrivate(addr)) return .{ .allowed = false, .reason = .local_or_private_address };
        return .{ .allowed = true, .reason = .public_address };
    }

    /// Decides a destination written as an IP address.
    pub fn checkLiteral(p: *const Policy, addr: net.IpAddress) Verdict {
        if (p.mode == .deny_all) return .{ .allowed = false, .reason = .mode_deny_all };
        for (p.deny_subnets) |c| if (c.contains(addr)) return .{ .allowed = false, .reason = .denied_subnet, .rule = c.source };
        for (p.allow_subnets) |c| if (c.contains(addr)) return .{ .allowed = true, .reason = .allowed_subnet, .rule = c.source };
        if (p.mode == .allow_all and !isLocalOrPrivate(addr)) return .{ .allowed = true, .reason = .public_address };
        if (isLocalOrPrivate(addr)) return .{ .allowed = false, .reason = .local_or_private_address };
        return .{ .allowed = false, .reason = .ip_literal_needs_subnet };
    }
};

fn parsePattern(a: std.mem.Allocator, src: []const u8) error{ InvalidPattern, OutOfMemory }!Pattern {
    if (parseIpLiteral(src) != null) return error.InvalidPattern;
    var buf: [max_host_len]u8 = undefined;
    if (std.mem.startsWith(u8, src, "*.")) {
        const base = normalizeHost(&buf, src[2..]) catch return error.InvalidPattern;
        const text = try std.mem.concat(a, u8, &.{ ".", base });
        return .{ .text = text, .wildcard = true, .source = src };
    }
    if (std.mem.findScalar(u8, src, '*') != null) return error.InvalidPattern;
    const host = normalizeHost(&buf, src) catch return error.InvalidPattern;
    return .{ .text = try a.dupe(u8, host), .wildcard = false, .source = src };
}

fn parseCidrs(a: std.mem.Allocator, items: []const []const u8, diag: ?*Diagnostic) Policy.ParseError![]const Cidr {
    const out = try a.alloc(Cidr, items.len);
    for (items, out) |src, *c| {
        c.* = Cidr.parse(src) catch |err| {
            if (diag) |d| d.* = .{ .message = "invalid subnet; use CIDR like 10.0.0.0/8 or fd00::/8", .item = src };
            return err;
        };
    }
    return out;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn parseTest(json: []const u8) !Policy {
    return Policy.parse(testing.allocator, json, null);
}

fn ip(text: []const u8) net.IpAddress {
    return net.IpAddress.parse(text, 0) catch unreachable;
}

test "allowlist: exact and wildcard names" {
    var p = try parseTest(
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["Example.COM.","*.npmjs.org"]}}
    );
    defer p.deinit();
    try testing.expect(p.checkHost("example.com").allowed);
    try testing.expectEqualStrings("Example.COM.", p.checkHost("example.com").rule.?);
    try testing.expect(!p.checkHost("www.example.com").allowed);
    try testing.expect(p.checkHost("registry.npmjs.org").allowed);
    try testing.expect(p.checkHost("a.b.npmjs.org").allowed);
    try testing.expect(!p.checkHost("npmjs.org").allowed);
    try testing.expect(!p.checkHost("evilnpmjs.org").allowed);
    try testing.expectEqual(Reason.no_matching_rule, p.checkHost("attacker.test").reason);
}

test "deny-all and allow-all" {
    var d = try parseTest(
        \\{"version":"blackice.policy/v0","network":{"mode":"deny-all"}}
    );
    defer d.deinit();
    try testing.expectEqual(Reason.mode_deny_all, d.checkHost("example.com").reason);
    try testing.expect(!d.checkLiteral(ip("93.184.216.34")).allowed);

    var a = try parseTest(
        \\{"version":"blackice.policy/v0","network":{"mode":"allow-all"}}
    );
    defer a.deinit();
    try testing.expect(a.checkHost("anything.test").allowed);
    try testing.expect(a.checkLiteral(ip("93.184.216.34")).allowed);
    try testing.expect(!a.checkLiteral(ip("127.0.0.1")).allowed);
}

test "resolved addresses: local and private are refused, subnets decide" {
    var p = try parseTest(
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["example.com"],
        \\ "subnets":{"allow":["10.20.0.0/16"],"deny":["203.0.113.0/24","10.20.30.0/24"]}}}
    );
    defer p.deinit();
    try testing.expect(p.checkResolved(ip("93.184.216.34")).allowed);
    try testing.expectEqual(Reason.local_or_private_address, p.checkResolved(ip("127.0.0.1")).reason);
    try testing.expectEqual(Reason.local_or_private_address, p.checkResolved(ip("::1")).reason);
    try testing.expectEqual(Reason.local_or_private_address, p.checkResolved(ip("::ffff:127.0.0.1")).reason);
    try testing.expectEqual(Reason.local_or_private_address, p.checkResolved(ip("169.254.169.254")).reason);
    try testing.expectEqual(Reason.local_or_private_address, p.checkResolved(ip("100.64.62.72")).reason);
    try testing.expectEqual(Reason.local_or_private_address, p.checkResolved(ip("fd00::1")).reason);
    try testing.expectEqual(Reason.local_or_private_address, p.checkResolved(ip("192.168.100.72")).reason);
    try testing.expectEqual(Reason.allowed_subnet, p.checkResolved(ip("10.20.1.2")).reason);
    try testing.expectEqual(Reason.denied_subnet, p.checkResolved(ip("10.20.30.4")).reason);
    try testing.expectEqual(Reason.denied_subnet, p.checkResolved(ip("203.0.113.9")).reason);
}

test "IP literals need an allowed subnet in allowlist mode" {
    var p = try parseTest(
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["example.com"],
        \\ "subnets":{"allow":["198.51.100.0/24"]}}}
    );
    defer p.deinit();
    try testing.expectEqual(Reason.ip_literal_needs_subnet, p.checkLiteral(ip("93.184.216.34")).reason);
    try testing.expectEqual(Reason.allowed_subnet, p.checkLiteral(ip("198.51.100.7")).reason);
}

test "invalid policies fail closed" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidJson, Policy.parse(testing.allocator,
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","alow":["x.com"]}}
    , &diag));
    try testing.expectError(error.UnsupportedVersion, Policy.parse(testing.allocator,
        \\{"version":"v9","network":{"mode":"allowlist"}}
    , &diag));
    try testing.expectError(error.UnknownMode, Policy.parse(testing.allocator,
        \\{"version":"blackice.policy/v0","network":{"mode":"open"}}
    , &diag));
    try testing.expectError(error.InvalidPattern, Policy.parse(testing.allocator,
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["1.2.3.4"]}}
    , &diag));
    try testing.expectError(error.InvalidPattern, Policy.parse(testing.allocator,
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["*"]}}
    , &diag));
    try testing.expectError(error.InvalidPattern, Policy.parse(testing.allocator,
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["a.*.com"]}}
    , &diag));
    try testing.expectError(error.InvalidSubnet, Policy.parse(testing.allocator,
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","subnets":{"allow":["10.0.0.0/33"]}}}
    , &diag));
}

test "normalizeHost" {
    var buf: [max_host_len]u8 = undefined;
    try testing.expectEqualStrings("api.example.com", try normalizeHost(&buf, "API.Example.com."));
    try testing.expectError(error.InvalidHost, normalizeHost(&buf, "bad host"));
    try testing.expectError(error.InvalidHost, normalizeHost(&buf, "a..b"));
    try testing.expectError(error.InvalidHost, normalizeHost(&buf, ""));
}
