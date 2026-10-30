//! Policy v0: which destinations a scope may reach.
//!
//! File format (JSON, unknown fields are rejected so a typo cannot widen a policy):
//!
//!     {
//!       "version": "blackice.policy/v0",
//!       "network": {
//!         "mode": "allowlist",               // "deny-all" | "allow-all" | "allowlist"
//!         "allow": ["example.com", "*.npmjs.org"],
//!         "subnets": { "allow": ["10.20.0.0/16"], "deny": ["203.0.113.0/24"] },
//!         "ports": [80, 443]                 // optional; this is the default
//!       }
//!     }
//!
//! Matching rules:
//! - Ports: the destination port must be in network.ports (default 80 and 443), in every mode.
//! - Names are compared in lowercase, without a trailing dot. A name that a resolver could read as an IPv4
//!   address (2130706433, 127.1, 0x7f000001) is invalid.
//! - "example.com" matches only example.com.
//! - "*.example.com" matches any name below example.com (a.example.com, a.b.example.com), not example.com.
//! - After a name is allowed, every address it resolves to is checked again:
//!   denied subnets always lose; allowed subnets win; loopback, private, link-local, CGNAT, multicast and
//!   reserved addresses are refused unless an allowed subnet covers them. This stops an allowed name that
//!   resolves to 127.0.0.1 from reaching local services.
//! - An IPv6 address that stands for an IPv4 address is checked as that address too: IPv4-mapped addresses
//!   (::ffff:a.b.c.d) only as IPv4, NAT64 addresses (64:ff9b::a.b.c.d) as both. Other transition addresses
//!   (6to4 2002::/16, Teredo 2001::/32, IPv4-compatible ::a.b.c.d) are refused unless an allowed subnet
//!   covers them.
//! - IPv6 subnets never cover IPv4 addresses. An IPv4-mapped subnet (::ffff:a.b.c.d/96 or longer) is read as
//!   the IPv4 subnet it stands for.
//! - A destination written as an IP address is allowed only by an allowed subnet (or by allow-all, for
//!   public addresses).

const std = @import("std");
const net = std.Io.net;

pub const version_v0 = "blackice.policy/v0";
pub const max_host_len = 253;
pub const default_ports = [_]u16{ 80, 443 };

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
    allowed_port,
    public_address,
    no_matching_rule,
    mode_deny_all,
    ip_literal_needs_subnet,
    denied_subnet,
    local_or_private_address,
    transition_address,
    port_not_allowed,
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

/// An address as the subnet rules see it: IPv4 (the first four bytes) or IPv6.
const Key = struct {
    is_ip4: bool,
    bytes: [16]u8,
};

const nat64_prefix = [12]u8{ 0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0 };

fn isMapped(b: *const [16]u8) bool {
    return std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff;
}

fn isNat64(b: *const [16]u8) bool {
    return std.mem.eql(u8, b[0..12], &nat64_prefix);
}

fn ip4Key(v4: [4]u8) Key {
    var k: Key = .{ .is_ip4 = true, .bytes = @splat(0) };
    @memcpy(k.bytes[0..4], &v4);
    return k;
}

/// The forms an address is matched in: an IPv4-mapped address only as IPv4, a NAT64 address as itself and as
/// the IPv4 address it carries.
fn keys(addr: net.IpAddress, out: *[2]Key) []const Key {
    switch (addr) {
        .ip4 => |a| {
            out[0] = ip4Key(a.bytes);
            return out[0..1];
        },
        .ip6 => |a| {
            if (isMapped(&a.bytes)) {
                out[0] = ip4Key(a.bytes[12..16].*);
                return out[0..1];
            }
            out[0] = .{ .is_ip4 = false, .bytes = a.bytes };
            if (isNat64(&a.bytes)) {
                out[1] = ip4Key(a.bytes[12..16].*);
                return out[0..2];
            }
            return out[0..1];
        },
    }
}

pub const Cidr = struct {
    is_ip4: bool,
    /// Network bytes; IPv4 uses the first four.
    bytes: [16]u8,
    prefix: u8,
    source: []const u8,

    pub fn parse(text: []const u8) error{InvalidSubnet}!Cidr {
        const slash = std.mem.findScalar(u8, text, '/') orelse return error.InvalidSubnet;
        const addr = net.IpAddress.parse(text[0..slash], 0) catch return error.InvalidSubnet;
        const prefix = parsePrefix(text[slash + 1 ..]) orelse return error.InvalidSubnet;
        var c: Cidr = .{ .is_ip4 = true, .bytes = @splat(0), .prefix = prefix, .source = text };
        switch (addr) {
            .ip4 => |a| {
                if (prefix > 32) return error.InvalidSubnet;
                @memcpy(c.bytes[0..4], &a.bytes);
            },
            .ip6 => |a| {
                if (prefix > 128) return error.InvalidSubnet;
                if (prefix >= 96 and isMapped(&a.bytes)) {
                    // ::ffff:a.b.c.d/n is the IPv4 subnet a.b.c.d/(n - 96).
                    @memcpy(c.bytes[0..4], a.bytes[12..16]);
                    c.prefix = prefix - 96;
                } else {
                    c.is_ip4 = false;
                    c.bytes = a.bytes;
                }
            },
        }
        return c;
    }

    fn matchesKey(c: Cidr, k: Key) bool {
        if (k.is_ip4 != c.is_ip4) return false;
        const len: usize = if (c.is_ip4) 4 else 16;
        return prefixMatch(c.bytes[0..len], k.bytes[0..len], c.prefix);
    }

    /// True when the address, in any form it is matched in, is inside the subnet.
    pub fn contains(c: Cidr, addr: net.IpAddress) bool {
        var buf: [2]Key = undefined;
        for (keys(addr, &buf)) |k| if (c.matchesKey(k)) return true;
        return false;
    }
};

/// One to three ASCII digits.
fn parsePrefix(text: []const u8) ?u8 {
    if (text.len == 0 or text.len > 3) return null;
    var n: u16 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return if (n > 255) null else @intCast(n);
}

fn prefixMatch(network: []const u8, addr: []const u8, prefix: u8) bool {
    const full: usize = prefix / 8;
    if (!std.mem.eql(u8, network[0..full], addr[0..full])) return false;
    const rem: u8 = prefix % 8;
    if (rem == 0) return true;
    const shift: u3 = @intCast(8 - rem);
    const mask: u8 = @as(u8, 0xff) << shift;
    return (network[full] & mask) == (addr[full] & mask);
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

pub const AddressClass = enum { public, local, transition };

/// How the default rules see an address when no subnet decided.
pub fn classify(addr: net.IpAddress) AddressClass {
    switch (addr) {
        .ip4 => |a| return if (isLocalIp4(a.bytes)) .local else .public,
        .ip6 => |a| {
            const b = a.bytes;
            if (isMapped(&b) or isNat64(&b)) return if (isLocalIp4(b[12..16].*)) .local else .public;
            if (std.mem.allEqual(u8, b[0..15], 0) and (b[15] == 0 or b[15] == 1)) return .local; // :: and ::1
            if (std.mem.allEqual(u8, b[0..12], 0)) return .transition; // ::a.b.c.d, IPv4-compatible (deprecated)
            if (std.mem.allEqual(u8, b[0..8], 0) and b[8] == 0xff and b[9] == 0xff and b[10] == 0 and b[11] == 0)
                return .transition; // ::ffff:0:a.b.c.d, IPv4-translated
            if (std.mem.eql(u8, b[0..6], &.{ 0x00, 0x64, 0xff, 0x9b, 0x00, 0x01 })) return .local; // 64:ff9b:1::/48, local-use NAT64
            if (b[0] == 0x01 and b[1] == 0x00 and std.mem.allEqual(u8, b[2..8], 0)) return .local; // 100::/64, discard
            if ((b[0] & 0xfe) == 0xfc) return .local; // fc00::/7
            if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return .local; // fe80::/10
            if (b[0] == 0xfe and (b[1] & 0xc0) == 0xc0) return .local; // fec0::/10
            if (b[0] == 0xff) return .local; // multicast
            if (b[0] == 0x20 and b[1] == 0x02) return .transition; // 2002::/16, 6to4
            if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x00 and b[3] == 0x00) return .transition; // 2001::/32, Teredo
            return .public;
        },
    }
}

/// Not a public address: loopback, unspecified, private, link-local, CGNAT, multicast, reserved, or a
/// transition address.
pub fn isLocalOrPrivate(addr: net.IpAddress) bool {
    return classify(addr) != .public;
}

/// True when the last label is all digits (2130706433, 127.1, 0177.0.0.1) or a hex number (0x7f000001).
/// inet_aton-style resolvers read such names as IPv4 addresses, and no top-level domain looks like that.
pub fn looksNumeric(host: []const u8) bool {
    const last = if (std.mem.findScalarLast(u8, host, '.')) |i| host[i + 1 ..] else host;
    if (last.len == 0) return false;
    if (last.len >= 2 and last[0] == '0' and (last[1] == 'x' or last[1] == 'X')) {
        for (last[2..]) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
    for (last) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Lowercases `raw` into `buf`, drops one trailing dot and checks the characters. Numeric names are refused.
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
    const out = buf[0..host.len];
    if (looksNumeric(out)) return error.InvalidHost;
    return out;
}

/// An IPv4 address, or an IPv6 address without brackets.
pub fn parseIpLiteral(host: []const u8) ?net.IpAddress {
    return net.IpAddress.parse(host, 0) catch null;
}

/// Why a policy was rejected. The item is copied (cut to 96 bytes, with control and non-ASCII bytes shown as
/// '?'), so it stays valid after parse returns and is safe to print to a terminal.
pub const Diagnostic = struct {
    message: []const u8 = "",
    item_buf: [96]u8 = undefined,
    item_len: usize = 0,

    pub fn item(d: *const Diagnostic) []const u8 {
        return d.item_buf[0..d.item_len];
    }

    pub fn set(d: *Diagnostic, message: []const u8, text: []const u8) void {
        d.message = message;
        const n = @min(text.len, d.item_buf.len);
        for (text[0..n], d.item_buf[0..n]) |c, *o| o.* = if (c >= 0x20 and c < 0x7f) c else '?';
        d.item_len = n;
    }
};

const RawSubnets = struct {
    allow: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
};
const RawNetwork = struct {
    mode: []const u8,
    allow: []const []const u8 = &.{},
    subnets: RawSubnets = .{},
    ports: ?[]const i64 = null,
};
const Raw = struct {
    version: []const u8,
    network: RawNetwork,
};

pub const Policy = struct {
    arena: std.heap.ArenaAllocator,
    /// The exact policy file bytes, copied. Rule strings in verdicts point into this copy or the arena.
    bytes: []const u8,
    mode: Mode,
    allow: []const Pattern,
    allow_subnets: []const Cidr,
    deny_subnets: []const Cidr,
    /// Allowed destination ports, in every mode.
    ports: []const u16,
    /// SHA-256 of the policy file bytes, lowercase hex. Receipts carry a prefix of it.
    digest_hex: [64]u8,

    pub const ParseError = error{
        InvalidJson,
        UnsupportedVersion,
        UnknownMode,
        InvalidPattern,
        InvalidSubnet,
        InvalidPort,
        OutOfMemory,
    };

    fn fail(diag: ?*Diagnostic, err: ParseError, message: []const u8, item: []const u8) ParseError {
        if (diag) |d| d.set(message, item);
        return err;
    }

    /// The policy keeps its own copy of `bytes`; the caller may free them afterwards.
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, diag: ?*Diagnostic) ParseError!Policy {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const own = try a.dupe(u8, bytes);

        // Stated explicitly so a change of std defaults cannot loosen parsing: a repeated key or an unknown
        // field is an error, never a silent pick.
        const raw = std.json.parseFromSliceLeaky(Raw, a, own, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(diag, error.InvalidJson, "not valid policy JSON (unknown fields are rejected)", @errorName(err)),
        };
        if (!std.mem.eql(u8, raw.version, version_v0))
            return fail(diag, error.UnsupportedVersion, "unsupported policy version; expected " ++ version_v0, raw.version);

        const mode: Mode = if (std.mem.eql(u8, raw.network.mode, "deny-all"))
            .deny_all
        else if (std.mem.eql(u8, raw.network.mode, "allow-all"))
            .allow_all
        else if (std.mem.eql(u8, raw.network.mode, "allowlist"))
            .allowlist
        else
            return fail(diag, error.UnknownMode, "unknown mode; use deny-all, allow-all or allowlist", raw.network.mode);

        const patterns = try a.alloc(Pattern, raw.network.allow.len);
        for (raw.network.allow, patterns) |src, *p| {
            p.* = parsePattern(a, src) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidPattern => return fail(diag, error.InvalidPattern, "invalid allow entry; use a name or *.name (addresses go in subnets.allow)", src),
            };
        }

        const allow_subnets = try parseCidrs(a, raw.network.subnets.allow, diag);
        const deny_subnets = try parseCidrs(a, raw.network.subnets.deny, diag);

        const ports: []const u16 = if (raw.network.ports) |list| blk: {
            if (list.len == 0)
                return fail(diag, error.InvalidPort, "network.ports is empty; list at least one port, or use deny-all", "[]");
            const out = try a.alloc(u16, list.len);
            for (list, out) |n, *o| {
                if (n < 1 or n > 65535) {
                    var nb: [24]u8 = undefined;
                    return fail(diag, error.InvalidPort, "invalid port; use 1 to 65535", std.fmt.bufPrint(&nb, "{d}", .{n}) catch "?");
                }
                o.* = @intCast(n);
            }
            break :blk out;
        } else &default_ports;

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(own, &digest, .{});

        return .{
            .arena = arena,
            .bytes = own,
            .mode = mode,
            .allow = patterns,
            .allow_subnets = allow_subnets,
            .deny_subnets = deny_subnets,
            .ports = ports,
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

    /// Allow entries that the mode does not read: deny-all and allow-all ignore the allow list.
    pub fn ignoredAllowCount(p: *const Policy) usize {
        return if (p.mode == .allowlist) 0 else p.allow.len;
    }

    /// Decides a destination port. Callers check it first, for every destination; grants do not lift it.
    pub fn checkPort(p: *const Policy, port: u16) Verdict {
        for (p.ports) |allowed| if (allowed == port) return .{ .allowed = true, .reason = .allowed_port };
        return .{ .allowed = false, .reason = .port_not_allowed };
    }

    /// Decides a destination given by name. `host` must be normalized (see `normalizeHost`); numeric names and
    /// IP literals are refused here as well.
    pub fn checkHost(p: *const Policy, host: []const u8) Verdict {
        if (looksNumeric(host) or std.mem.findScalar(u8, host, ':') != null)
            return .{ .allowed = false, .reason = .invalid_host };
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

    fn subnetVerdict(p: *const Policy, addr: net.IpAddress) ?Verdict {
        for (p.deny_subnets) |c| if (c.contains(addr)) return .{ .allowed = false, .reason = .denied_subnet, .rule = c.source };
        for (p.allow_subnets) |c| if (c.contains(addr)) return .{ .allowed = true, .reason = .allowed_subnet, .rule = c.source };
        return null;
    }

    /// Checks one address that an allowed name resolved to.
    pub fn checkResolved(p: *const Policy, addr: net.IpAddress) Verdict {
        if (p.subnetVerdict(addr)) |v| return v;
        return switch (classify(addr)) {
            .local => .{ .allowed = false, .reason = .local_or_private_address },
            .transition => .{ .allowed = false, .reason = .transition_address },
            .public => .{ .allowed = true, .reason = .public_address },
        };
    }

    /// Decides a destination written as an IP address.
    pub fn checkLiteral(p: *const Policy, addr: net.IpAddress) Verdict {
        if (p.mode == .deny_all) return .{ .allowed = false, .reason = .mode_deny_all };
        if (p.subnetVerdict(addr)) |v| return v;
        return switch (classify(addr)) {
            .local => .{ .allowed = false, .reason = .local_or_private_address },
            .transition => .{ .allowed = false, .reason = .transition_address },
            .public => if (p.mode == .allow_all)
                .{ .allowed = true, .reason = .public_address }
            else
                .{ .allowed = false, .reason = .ip_literal_needs_subnet },
        };
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
        c.* = Cidr.parse(src) catch
            return Policy.fail(diag, error.InvalidSubnet, "invalid subnet; use CIDR like 10.0.0.0/8 or fd00::/8", src);
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

test "IPv6 forms of IPv4 addresses are checked as IPv4" {
    var p = try parseTest(
        \\{"version":"blackice.policy/v0","network":{"mode":"allow-all",
        \\ "subnets":{"deny":["203.0.113.0/24","::ffff:198.51.100.0/120"]}}}
    );
    defer p.deinit();
    // NAT64 (64:ff9b::/96) carries the IPv4 address in its last four bytes.
    try testing.expectEqual(Reason.denied_subnet, p.checkResolved(ip("64:ff9b::cb00:7109")).reason); // 203.0.113.9
    try testing.expectEqual(Reason.denied_subnet, p.checkLiteral(ip("64:ff9b::cb00:7109")).reason);
    try testing.expectEqual(Reason.local_or_private_address, p.checkResolved(ip("64:ff9b::7f00:1")).reason); // 127.0.0.1
    try testing.expectEqual(Reason.local_or_private_address, p.checkLiteral(ip("64:ff9b::a00:1")).reason); // 10.0.0.1
    try testing.expectEqual(Reason.public_address, p.checkResolved(ip("64:ff9b::5db8:d822")).reason); // 93.184.216.34
    // An IPv4-mapped subnet is an IPv4 subnet, for both forms of the address.
    try testing.expectEqual(Reason.denied_subnet, p.checkLiteral(ip("198.51.100.7")).reason);
    try testing.expectEqual(Reason.denied_subnet, p.checkLiteral(ip("::ffff:198.51.100.7")).reason);
    try testing.expectEqual(Reason.denied_subnet, p.checkLiteral(ip("::ffff:203.0.113.1")).reason);
}

test "transition addresses are refused unless a subnet allows them" {
    var p = try parseTest(
        \\{"version":"blackice.policy/v0","network":{"mode":"allow-all","subnets":{"allow":["2001::/32"]}}}
    );
    defer p.deinit();
    try testing.expectEqual(Reason.transition_address, p.checkResolved(ip("2002:cb00:7109::1")).reason); // 6to4
    try testing.expectEqual(Reason.transition_address, p.checkLiteral(ip("::cb00:7109")).reason); // IPv4-compatible
    try testing.expectEqual(Reason.local_or_private_address, p.checkResolved(ip("64:ff9b:1::1")).reason);
    try testing.expectEqual(Reason.allowed_subnet, p.checkResolved(ip("2001:0:4136:e378:8000:63bf:3fff:fdd2")).reason); // Teredo, allowed
    try testing.expectEqual(Reason.public_address, p.checkResolved(ip("2606:4700::1111")).reason);
    try testing.expect(isLocalOrPrivate(ip("2002::1")));
}

test "IPv6 subnets do not cover IPv4 addresses" {
    var p = try parseTest(
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","subnets":{"allow":["::/0"]}}}
    );
    defer p.deinit();
    try testing.expectEqual(Reason.allowed_subnet, p.checkLiteral(ip("2606:4700::1111")).reason);
    try testing.expectEqual(Reason.ip_literal_needs_subnet, p.checkLiteral(ip("93.184.216.34")).reason);
    try testing.expectEqual(Reason.local_or_private_address, p.checkLiteral(ip("::ffff:127.0.0.1")).reason);
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

test "ports: default 80 and 443, explicit list, every mode" {
    var d = try parseTest(
        \\{"version":"blackice.policy/v0","network":{"mode":"allow-all"}}
    );
    defer d.deinit();
    try testing.expect(d.checkPort(443).allowed);
    try testing.expect(d.checkPort(80).allowed);
    try testing.expectEqual(Reason.port_not_allowed, d.checkPort(22).reason);

    var p = try parseTest(
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["github.com"],"ports":[443,22]}}
    );
    defer p.deinit();
    try testing.expect(p.checkPort(22).allowed);
    try testing.expectEqual(Reason.allowed_port, p.checkPort(443).reason);
    try testing.expectEqual(Reason.port_not_allowed, p.checkPort(80).reason);
}

test "numeric names are not names" {
    var buf: [max_host_len]u8 = undefined;
    for ([_][]const u8{ "2130706433", "127.1", "0x7f000001", "0X7F.1", "0177.0.0.1", "1.2.3.4.", "foo.0x" }) |h| {
        try testing.expectError(error.InvalidHost, normalizeHost(&buf, h));
    }
    try testing.expectEqualStrings("1password.com", try normalizeHost(&buf, "1password.com"));
    try testing.expectEqualStrings("a.0xyz", try normalizeHost(&buf, "a.0xyz"));

    var p = try parseTest(
        \\{"version":"blackice.policy/v0","network":{"mode":"allow-all"}}
    );
    defer p.deinit();
    try testing.expectEqual(Reason.invalid_host, p.checkHost("2130706433").reason);
    try testing.expectEqual(Reason.invalid_host, p.checkHost("127.1").reason);
    try testing.expectEqual(Reason.invalid_host, p.checkHost("::1").reason);
}

test "invalid policies fail closed" {
    const cases = [_]struct { Policy.ParseError, []const u8 }{
        .{
            error.InvalidJson,
            \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","alow":["x.com"]}}
        },
        .{
            error.InvalidJson,
            \\{"version":"blackice.policy/v0","network":{"mode":"deny-all","mode":"allow-all"}}
        },
        .{
            error.InvalidJson,
            \\{"version":"blackice.policy/v0","network":{"mode":"deny-all"},"network":{"mode":"allow-all"}}
        },
        .{
            error.UnsupportedVersion,
            \\{"version":"v9","network":{"mode":"allowlist"}}
        },
        .{
            error.UnknownMode,
            \\{"version":"blackice.policy/v0","network":{"mode":"open"}}
        },
        .{
            error.InvalidPattern,
            \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["1.2.3.4"]}}
        },
        .{
            error.InvalidPattern,
            \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["2130706433"]}}
        },
        .{
            error.InvalidPattern,
            \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["*"]}}
        },
        .{
            error.InvalidPattern,
            \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["a.*.com"]}}
        },
        .{
            error.InvalidSubnet,
            \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","subnets":{"allow":["10.0.0.0/33"]}}}
        },
        .{
            error.InvalidSubnet,
            \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","subnets":{"allow":["10.0.0.0/1_6"]}}}
        },
        .{
            error.InvalidPort,
            \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","ports":[]}}
        },
        .{
            error.InvalidPort,
            \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","ports":[0]}}
        },
        .{
            error.InvalidPort,
            \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","ports":[443,65536]}}
        },
    };
    for (cases) |c| {
        var diag: Diagnostic = .{};
        try testing.expectError(c[0], Policy.parse(testing.allocator, c[1], &diag));
        try testing.expect(diag.message.len > 0);
    }
}

test "diagnostics own their item, and it is safe to print" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnsupportedVersion, Policy.parse(testing.allocator,
        \\{"version":"v9\u001b[2J","network":{"mode":"allowlist"}}
    , &diag));
    try testing.expectEqualStrings("v9?[2J", diag.item());
    try testing.expectError(error.InvalidPort, Policy.parse(testing.allocator,
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","ports":[80,70000]}}
    , &diag));
    try testing.expectEqualStrings("70000", diag.item());
}

test "the policy owns a copy of its input" {
    const src =
        \\{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["Example.COM."]}}
    ;
    const buf = try testing.allocator.dupe(u8, src);
    var p = try Policy.parse(testing.allocator, buf, null);
    defer p.deinit();
    @memset(buf, 'X');
    testing.allocator.free(buf);
    try testing.expectEqualStrings("Example.COM.", p.checkHost("example.com").rule.?);
    try testing.expectEqualStrings(src, p.bytes);
    try testing.expectEqual(@as(usize, 0), p.ignoredAllowCount());
}

test "normalizeHost" {
    var buf: [max_host_len]u8 = undefined;
    try testing.expectEqualStrings("api.example.com", try normalizeHost(&buf, "API.Example.com."));
    try testing.expectError(error.InvalidHost, normalizeHost(&buf, "bad host"));
    try testing.expectError(error.InvalidHost, normalizeHost(&buf, "a..b"));
    try testing.expectError(error.InvalidHost, normalizeHost(&buf, ""));
}
