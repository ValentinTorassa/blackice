//! Explicit backend test harness, built only by `zig build linux-probe`.
//! It provides no policy proxy: supplied ports are controlled test receivers.
const std = @import("std");
const core = @import("blackice_core");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 5 or !std.mem.eql(u8, args[3], "--")) {
        std.debug.print("usage: blackice-linux-probe PORTS|- RECEIPTS -- COMMAND [ARGS...]\n", .{});
        return 2;
    }
    var ports_buf: [8]u16 = undefined;
    var count: usize = 0;
    if (!std.mem.eql(u8, args[1], "-")) {
        var it = std.mem.splitScalar(u8, args[1], ',');
        while (it.next()) |s| {
            if (count == ports_buf.len) return error.TooManyPorts;
            ports_buf[count] = try std.fmt.parseInt(u16, s, 10);
            count += 1;
        }
    }
    const ports = ports_buf[0..count];
    var id_buf: [core.scope.id_len]u8 = undefined;
    const id = core.scope.newId(init.io, &id_buf);
    var receipts = try core.receipt.Log.open(init.io, .cwd(), args[2], id, "linux-backend-probe");
    defer receipts.close();
    const state = try std.Io.Dir.cwd().realPathFileAlloc(init.io, std.fs.path.dirname(args[2]) orelse ".", init.gpa);
    defer init.gpa.free(state);
    const exit = core.backend.launch(init.gpa, init.io, .{
        .scope_id = id,
        .argv = args[4..],
        .environ = init.environ_map,
        .allowed_loopback_ports = ports,
        .state_dir = state,
        .receipts = &receipts,
    }) catch return 125;
    return exit.status();
}

test "the core resolves a Linux backend; invalid scope is refused before launch" {
    try std.testing.expect(core.backend.available);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try core.receipt.Log.open(std.testing.io, tmp.dir, "invalid.jsonl", "bad", "test");
    defer log.close();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.SpawnFailed, core.backend.launch(std.testing.allocator, std.testing.io, .{
        .scope_id = "bad",
        .argv = &.{"/bin/false"},
        .environ = &env,
        .allowed_loopback_ports = &.{},
        .state_dir = "/invalid",
        .receipts = &log,
    }));
}
