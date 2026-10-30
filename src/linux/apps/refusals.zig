//! Bounded aggregation for glibc's UDP-connect source-address sorting probes. No packets are allowed.
const std = @import("std");
const abi = @import("types.zig");
pub const Batch = struct {
    ipv4: u64 = 0,
    ipv6: u64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,
    pub fn add(b: *Batch, event: abi.Event) void {
        if (b.ipv4 == 0 and b.ipv6 == 0) b.first_ns = event.timestamp_ns;
        b.last_ns = event.timestamp_ns;
        if (event.hook == @backingInt(std.os.linux.BPF.AttachType.cgroup_inet4_connect)) b.ipv4 +|= 1 else b.ipv6 +|= 1;
    }
    pub fn empty(b: Batch) bool {
        return b.ipv4 == 0 and b.ipv6 == 0;
    }
};
test "appfilter UDP connect aggregation preserves refusal counts and event time bounds" {
    var batch: Batch = .{};
    var event: abi.Event = std.mem.zeroes(abi.Event);
    event.hook = @backingInt(std.os.linux.BPF.AttachType.cgroup_inet4_connect);
    event.timestamp_ns = 10;
    batch.add(event);
    event.hook = @backingInt(std.os.linux.BPF.AttachType.cgroup_inet6_connect);
    event.timestamp_ns = 20;
    batch.add(event);
    try std.testing.expectEqual(@as(u64, 1), batch.ipv4);
    try std.testing.expectEqual(@as(u64, 1), batch.ipv6);
    try std.testing.expectEqual(@as(u64, 10), batch.first_ns);
    try std.testing.expectEqual(@as(u64, 20), batch.last_ns);
    try std.testing.expect(!batch.empty());
}
