//! A deliberately limited Vercel Sandbox networkPolicy importer.
//!
//! `convert` creates a reviewable candidate. It does not install policy, grant authority or
//! establish protocol parity. `policyForBackend` refuses the candidate unless the caller
//! supplies the required, independently qualified backend capabilities. They default false.
//! The returned policy pointer and candidate JSON borrow this Import's lifetime.
//!
//! Profile: blackice.sandbox-subset/v1. Source: vercel/sandbox commit
//! 8c996641a6ceac3a186ee45d9af0e1c8fcfd4d31, src/network-policy.ts.
//! See docs/policy.md for the intentionally unsupported forms and protocol differences.

const std = @import("std");
const policy = @import("policy.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const profile_version = "blackice.sandbox-subset/v1";
pub const source_commit = "8c996641a6ceac3a186ee45d9af0e1c8fcfd4d31";
pub const max_input_bytes = 64 * 1024;
pub const max_entries = 256;
pub const max_depth = 8;
/// Explicit local restriction on every generated candidate; never inherit a changing core default.
pub const local_port_ceiling = [_]u16{ 80, 443 };

pub const Error = error{
    InputTooLarge,
    TooDeep,
    InvalidJson,
    InvalidShape,
    UnknownField,
    UnsupportedMode,
    UnsupportedHandling,
    UnsupportedWildcard,
    InvalidDomain,
    InvalidSubnet,
    UnsupportedSubnet,
    TooManyRules,
    MissingCapability,
    GeneratedPolicyRejected,
    OutOfMemory,
};

/// Diagnostics contain only static strings. Rejected input may contain credentials; never echo it.
pub const Diagnostic = struct {
    path: []const u8 = "$",
    message: []const u8 = "",
};

pub const Requirements = struct {
    bound_tls_domains: bool,
    ipv4_cidrs: bool,
    destination_ports: bool,
    local_ceiling_acknowledged: bool,
};

pub const Capabilities = struct {
    /// Qualified before-exec enforcement, descendants, protocols and no undeclared bypasses.
    native_scope: bool = false,
    /// DNS behavior qualified for this source policy; deny-all includes DNS and resolver IPC.
    dns_policy: bool = false,
    /// TLS name rules, actual dial-address binding, protocol dispatch and no plaintext-HTTP widening.
    bound_tls_domains: bool = false,
    /// Independent IPv4 range allows, deny precedence and IPv4-mapped IPv6 normalization.
    ipv4_cidrs: bool = false,
    /// Every connection checks the candidate's destination ports, including subnet allows and grants.
    destination_ports: bool = false,
    /// The operator explicitly accepts blackice's local address restrictions and 80/443 port ceiling.
    local_ceiling_acknowledged: bool = false,
};

pub const Import = struct {
    allocator: Allocator,
    _json: []u8,
    _policy: policy.Policy,
    requirements: Requirements,
    source_digest_hex: [64]u8,

    pub fn deinit(self: *Import) void {
        // The policy owns its parsed input; retain the canonical JSON separately for review/export.
        self._policy.deinit();
        self.allocator.free(self._json);
        self.* = undefined;
    }

    /// For review/export only. This byte string is not proof that any backend can enforce it.
    pub fn candidateJson(self: *const Import) []const u8 {
        return self._json;
    }

    /// The caller must derive capabilities from qualified backend support, never workload input.
    /// This only validates the contract. The launcher must still arm/acknowledge it before exec.
    pub fn policyForBackend(self: *const Import, caps: Capabilities, diag: ?*Diagnostic) Error!*const policy.Policy {
        if (diag) |d| d.* = .{};
        if (!caps.native_scope)
            return fail(diag, "$capabilities.native_scope", "native scope enforcement is not qualified", error.MissingCapability);
        if (!caps.dns_policy)
            return fail(diag, "$capabilities.dns_policy", "DNS semantics are not qualified", error.MissingCapability);
        if (self.requirements.bound_tls_domains and !caps.bound_tls_domains)
            return fail(diag, "$capabilities.bound_tls_domains", "TLS domain and destination-binding semantics are not qualified", error.MissingCapability);
        if (self.requirements.ipv4_cidrs and !caps.ipv4_cidrs)
            return fail(diag, "$capabilities.ipv4_cidrs", "independent CIDR semantics are not qualified", error.MissingCapability);
        if (self.requirements.destination_ports and !caps.destination_ports)
            return fail(diag, "$capabilities.destination_ports", "destination-port enforcement is not qualified", error.MissingCapability);
        if (self.requirements.local_ceiling_acknowledged and !caps.local_ceiling_acknowledged)
            return fail(diag, "$capabilities.local_ceiling_acknowledged", "additional local restrictions need explicit acknowledgement", error.MissingCapability);
        return &self._policy;
    }
};

fn fail(diag: ?*Diagnostic, path: []const u8, message: []const u8, err: Error) Error {
    if (diag) |d| d.* = .{ .path = path, .message = message };
    return err;
}

/// Bounded token preflight uses the standard JSON scanner, not an alternative JSON parser.
fn preflight(gpa: Allocator, bytes: []const u8, diag: ?*Diagnostic) Error!void {
    if (bytes.len > max_input_bytes)
        return fail(diag, "$", "input exceeds 64 KiB", error.InputTooLarge);
    var scanner = std.json.Scanner.initCompleteInput(gpa, bytes);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(diag, "$", "invalid JSON", error.InvalidJson),
        };
        if (scanner.stackHeight() > max_depth)
            return fail(diag, "$", "JSON nesting exceeds eight containers", error.TooDeep);
        if (token == .end_of_document) break;
    }
}

fn allowedKeys(object: std.json.ObjectMap, comptime keys: []const []const u8, path: []const u8, diag: ?*Diagnostic) Error!void {
    for (object.keys()) |key| {
        var found = false;
        inline for (keys) |known| {
            if (std.mem.eql(u8, key, known)) found = true;
        }
        if (!found) return fail(diag, path, "unknown field; no fields are silently dropped", error.UnknownField);
    }
}

fn countEntry(count: *usize, diag: ?*Diagnostic) Error!void {
    count.* += 1;
    if (count.* > max_entries)
        return fail(diag, "$", "more than 256 domain and subnet entries", error.TooManyRules);
}

fn domain(a: Allocator, raw: []const u8, diag: ?*Diagnostic) Error![]const u8 {
    const wildcard = std.mem.startsWith(u8, raw, "*.");
    const suffix = if (wildcard) raw[2..] else raw;
    if (std.mem.findScalar(u8, suffix, '*') != null)
        return fail(diag, "$.allow", "only one leading whole-label wildcard is supported", error.UnsupportedWildcard);
    var buf: [policy.max_host_len]u8 = undefined;
    const normalized = policy.normalizeHost(&buf, suffix) catch
        return fail(diag, "$.allow", "invalid ASCII domain name", error.InvalidDomain);
    if (policy.parseIpLiteral(normalized) != null)
        return fail(diag, "$.allow", "IP addresses belong in subnets, not domains", error.InvalidDomain);
    var labels = std.mem.splitScalar(u8, normalized, '.');
    while (labels.next()) |label| {
        if (label[0] == '-' or label[label.len - 1] == '-' or std.mem.findScalar(u8, label, '_') != null)
            return fail(diag, "$.allow", "domain labels must be hostname labels", error.InvalidDomain);
    }
    if (wildcard) {
        if (normalized.len + 2 > policy.max_host_len)
            return fail(diag, "$.allow", "domain pattern exceeds 253 bytes", error.InvalidDomain);
        return std.mem.concat(a, u8, &.{ "*.", normalized });
    }
    return a.dupe(u8, normalized);
}

fn subnet(a: Allocator, raw: []const u8, diag: ?*Diagnostic) Error![]const u8 {
    const slash = std.mem.findScalar(u8, raw, '/') orelse
        return fail(diag, "$.subnets", "a subnet requires a CIDR prefix", error.InvalidSubnet);
    const prefix = raw[slash + 1 ..];
    if (prefix.len == 0 or (prefix.len > 1 and prefix[0] == '0'))
        return fail(diag, "$.subnets", "prefix must be canonical decimal", error.InvalidSubnet);
    for (prefix) |c| {
        if (!std.ascii.isDigit(c))
            return fail(diag, "$.subnets", "prefix must contain decimal digits only", error.InvalidSubnet);
    }
    // The core normalizes mapped IPv6 CIDRs to IPv4. Subset v1 rejects their source syntax too.
    if (std.mem.findScalar(u8, raw[0..slash], ':') != null)
        return fail(diag, "$.subnets", "IPv6 CIDR import is outside subset v1", error.UnsupportedSubnet);
    const cidr = policy.Cidr.parse(raw) catch
        return fail(diag, "$.subnets", "invalid CIDR", error.InvalidSubnet);
    if (!cidr.is_ip4)
        return fail(diag, "$.subnets", "IPv6 CIDR import is outside subset v1", error.UnsupportedSubnet);
    var octets = std.mem.splitScalar(u8, raw[0..slash], '.');
    var octet_count: usize = 0;
    while (octets.next()) |part| {
        if (part.len == 0 or (part.len > 1 and part[0] == '0'))
            return fail(diag, "$.subnets", "IPv4 octets must be canonical decimal", error.InvalidSubnet);
        for (part) |c| {
            if (!std.ascii.isDigit(c))
                return fail(diag, "$.subnets", "IPv4 octets must be decimal", error.InvalidSubnet);
        }
        octet_count += 1;
    }
    if (octet_count != 4)
        return fail(diag, "$.subnets", "IPv4 needs four octets", error.InvalidSubnet);
    for (cidr.bytes[0..4], 0..) |b, index| {
        const start = index * 8;
        const bits = if (cidr.prefix > start) @min(@as(usize, cidr.prefix) - start, 8) else 0;
        const mask: u8 = if (bits == 0) 0 else @as(u8, 0xff) << @as(u3, @intCast(8 - bits));
        if ((b & ~mask) != 0)
            return fail(diag, "$.subnets", "CIDR host bits must be zero", error.InvalidSubnet);
    }
    return a.dupe(u8, raw);
}

fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn canonicalize(items: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, items.items, {}, less);
    var n: usize = 0;
    for (items.items) |item| {
        if (n == 0 or !std.mem.eql(u8, items.items[n - 1], item)) {
            items.items[n] = item;
            n += 1;
        }
    }
    items.items.len = n;
}

pub fn convert(gpa: Allocator, bytes: []const u8, diag: ?*Diagnostic) Error!Import {
    if (diag) |d| d.* = .{};
    try preflight(gpa, bytes, diag);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = std.json.parseFromSliceLeaky(Value, a, bytes, .{ .duplicate_field_behavior = .@"error", .max_value_len = 2048 }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(diag, "$", "invalid JSON or duplicate key", error.InvalidJson),
    };
    var names: std.ArrayList([]const u8) = .empty;
    var allows: std.ArrayList([]const u8) = .empty;
    var denies: std.ArrayList([]const u8) = .empty;
    var count: usize = 0;
    switch (raw) {
        .string => |mode| {
            if (!std.mem.eql(u8, mode, "deny-all"))
                return fail(diag, "$", "only deny-all is supported as a string; allow-all needs broader semantics", error.UnsupportedMode);
        },
        .object => |object| {
            try allowedKeys(object, &.{ "allow", "subnets" }, "$", diag);
            if (object.get("allow")) |value| switch (value) {
                .array => |array| for (array.items) |item| {
                    try countEntry(&count, diag);
                    if (item != .string)
                        return fail(diag, "$.allow", "allow entries must be strings", error.InvalidShape);
                    try names.append(a, try domain(a, item.string, diag));
                },
                .object => |record| {
                    var it = record.iterator();
                    while (it.next()) |entry| {
                        try countEntry(&count, diag);
                        const rules = entry.value_ptr.*;
                        if (rules != .array)
                            return fail(diag, "$.allow", "record values must be empty arrays", error.InvalidShape);
                        if (rules.array.items.len != 0)
                            return fail(diag, "$.allow", "request handling is unsupported; never strip match, transform, forward or response rules", error.UnsupportedHandling);
                        try names.append(a, try domain(a, entry.key_ptr.*, diag));
                    }
                },
                else => return fail(diag, "$.allow", "allow must be an array or domain map", error.InvalidShape),
            };
            if (object.get("subnets")) |value| {
                if (value != .object)
                    return fail(diag, "$.subnets", "subnets must be an object", error.InvalidShape);
                try allowedKeys(value.object, &.{ "allow", "deny" }, "$.subnets", diag);
                inline for (.{ "allow", "deny" }) |key| {
                    if (value.object.get(key)) |list| {
                        if (list != .array)
                            return fail(diag, "$.subnets", "subnet lists must be arrays", error.InvalidShape);
                        const dest = if (comptime std.mem.eql(u8, key, "allow")) &allows else &denies;
                        for (list.array.items) |item| {
                            try countEntry(&count, diag);
                            if (item != .string)
                                return fail(diag, "$.subnets", "subnet entries must be strings", error.InvalidShape);
                            try dest.append(a, try subnet(a, item.string, diag));
                        }
                    }
                }
            }
        },
        else => return fail(diag, "$", "expected a networkPolicy value, not a wrapper or null", error.InvalidShape),
    }
    canonicalize(&names);
    canonicalize(&allows);
    canonicalize(&denies);
    const has_access = names.items.len != 0 or allows.items.len != 0;
    const output = .{
        .version = policy.version_v0,
        .network = .{
            .mode = if (has_access) "allowlist" else "deny-all",
            .allow = names.items,
            .subnets = .{ .allow = allows.items, .deny = denies.items },
            .ports = local_port_ceiling,
        },
    };
    const json = try std.json.Stringify.valueAlloc(gpa, output, .{});
    errdefer gpa.free(json);
    const parsed = policy.Policy.parse(gpa, json, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(diag, "$", "generated candidate rejected by the core policy parser", error.GeneratedPolicyRejected),
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{
        .allocator = gpa,
        ._json = json,
        ._policy = parsed,
        .source_digest_hex = std.fmt.bytesToHex(digest, .lower),
        .requirements = .{
            .bound_tls_domains = names.items.len != 0,
            .ipv4_cidrs = allows.items.len != 0 or denies.items.len != 0,
            .destination_ports = has_access,
            .local_ceiling_acknowledged = has_access,
        },
    };
}

const testing = std.testing;
// Synthetic capabilities exercise the gate; these are not a statement of native support.
const test_caps: Capabilities = .{
    .native_scope = true,
    .dns_policy = true,
    .bound_tls_domains = true,
    .ipv4_cidrs = true,
    .destination_ports = true,
    .local_ceiling_acknowledged = true,
};

test "versioned acceptance and rejection vectors" {
    const Query = struct { kind: enum { host, literal, resolved, port }, value: []const u8, allowed: bool };
    const Case = struct {
        id: []const u8,
        input: []const u8,
        expected_error: ?[]const u8 = null,
        mode: ?[]const u8 = null,
        allow: []const []const u8 = &.{},
        queries: []const Query = &.{},
    };
    const Vectors = struct { version: []const u8, cases: []const Case };
    const data = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/vectors/sandbox-import-v1.json", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(data);
    const vectors = try std.json.parseFromSlice(Vectors, testing.allocator, data, .{});
    defer vectors.deinit();
    try testing.expectEqualStrings("blackice.sandbox-import-vectors/v1", vectors.value.version);
    for (vectors.value.cases) |case| {
        var diag: Diagnostic = .{};
        var imported = convert(testing.allocator, case.input, &diag) catch |err| {
            if (case.expected_error) |expected| {
                try testing.expectEqualStrings(expected, @errorName(err));
                try testing.expect(diag.message.len != 0);
                continue;
            }
            std.debug.print("vector {s}: unexpected {s}\n", .{ case.id, @errorName(err) });
            return err;
        };
        defer imported.deinit();
        if (case.expected_error != null) {
            std.debug.print("vector {s}: unexpectedly accepted\n", .{case.id});
            return error.TestExpectedError;
        }
        const p = try imported.policyForBackend(test_caps, &diag);
        try testing.expectEqualStrings(case.mode.?, p.mode.label());
        try testing.expectEqual(case.allow.len, p.allow.len);
        for (case.allow, p.allow) |expected, actual| try testing.expectEqualStrings(expected, actual.source);
        for (case.queries) |query| {
            const verdict = switch (query.kind) {
                .host => p.checkHost(query.value),
                .literal => p.checkLiteral(try std.Io.net.IpAddress.parse(query.value, 0)),
                .resolved => p.checkResolved(try std.Io.net.IpAddress.parse(query.value, 0)),
                .port => p.checkPort(try std.fmt.parseInt(u16, query.value, 10)),
            };
            if (verdict.allowed != query.allowed) std.debug.print("vector {s}, query {s}\n", .{ case.id, query.value });
            try testing.expectEqual(query.allowed, verdict.allowed);
        }
    }
}

test "conversion never implies qualified activation" {
    var imported = try convert(testing.allocator, "{\"allow\":[\"api.example.com\"],\"subnets\":{\"deny\":[\"127.0.0.0/8\"]}}", null);
    defer imported.deinit();
    var caps: Capabilities = .{};
    var diag: Diagnostic = .{};
    const checks = .{ "native_scope", "dns_policy", "bound_tls_domains", "ipv4_cidrs", "destination_ports", "local_ceiling_acknowledged" };
    inline for (checks) |field| {
        try testing.expectError(error.MissingCapability, imported.policyForBackend(caps, &diag));
        try testing.expectEqualStrings("$capabilities." ++ field, diag.path);
        @field(caps, field) = true;
    }
    _ = try imported.policyForBackend(caps, &diag);
}

test "deny-all still requires native and DNS enforcement" {
    var imported = try convert(testing.allocator, "\"deny-all\"", null);
    defer imported.deinit();
    try testing.expectError(error.MissingCapability, imported.policyForBackend(.{ .native_scope = true }, null));
    const p = try imported.policyForBackend(.{ .native_scope = true, .dns_policy = true }, null);
    try testing.expect(!p.checkHost("example.com").allowed);
}

test "review candidate records the acknowledged local port ceiling" {
    var imported = try convert(testing.allocator, "{\"allow\":[\"api.example.com\"]}", null);
    defer imported.deinit();
    try testing.expect(std.mem.find(u8, imported.candidateJson(), "\"ports\":[80,443]") != null);
    var caps = test_caps;
    caps.local_ceiling_acknowledged = false;
    try testing.expectError(error.MissingCapability, imported.policyForBackend(caps, null));
    caps.local_ceiling_acknowledged = true;
    const p = try imported.policyForBackend(caps, null);
    try testing.expectEqualSlices(u16, &local_port_ceiling, p.ports);
}

test "owned candidate survives input destruction and record-form escaping" {
    const input = try testing.allocator.dupe(u8, "{\"allow\":{\"api\\u002eexample.com\":[]}}");
    var imported = try convert(testing.allocator, input, null);
    @memset(input, 0);
    testing.allocator.free(input);
    defer imported.deinit();
    const p = try imported.policyForBackend(test_caps, null);
    try testing.expectEqualStrings("api.example.com", p.checkHost("api.example.com").rule.?);
}

test "size, depth and entry limits are enforced" {
    const big = try testing.allocator.alloc(u8, max_input_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try testing.expectError(error.InputTooLarge, convert(testing.allocator, big, null));
    try testing.expectError(error.TooDeep, convert(testing.allocator, "[[[[[[[[[0]]]]]]]]]", null));
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "{\"allow\":[");
    for (0..max_entries + 1) |i| {
        if (i != 0) try list.append(testing.allocator, ',');
        try list.appendSlice(testing.allocator, "\"a.example\"");
    }
    try list.appendSlice(testing.allocator, "]}");
    try testing.expectError(error.TooManyRules, convert(testing.allocator, list.items, null));
}

fn oomConversion(allocator: Allocator) !void {
    var imported = try convert(allocator, "{\"allow\":{\"API.EXAMPLE.COM.\":[],\"*.example.org\":[]},\"subnets\":{\"allow\":[\"10.0.0.0/8\"],\"deny\":[\"10.1.0.0/16\"]}}", null);
    defer imported.deinit();
    _ = try imported.policyForBackend(test_caps, null);
}

test "all allocation failures clean up" {
    try testing.checkAllAllocationFailures(testing.allocator, oomConversion, .{});
}
