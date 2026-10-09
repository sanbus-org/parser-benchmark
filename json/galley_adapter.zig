const std = @import("std");
const galley = @import("galley");
const options = @import("adapter_options");

fn create() callconv(.c) ?*anyopaque {
    const session = std.heap.c_allocator.create(galley.Session) catch return null;
    session.* = galley.Session.init(std.Io.failing, std.heap.c_allocator, .{}) catch {
        std.heap.c_allocator.destroy(session);
        return null;
    };
    return session;
}

fn parse(context: ?*anyopaque, input: [*]const u8, input_len: usize) callconv(.c) bool {
    const session: *galley.Session = @ptrCast(@alignCast(context orelse return false));
    const result = session.parseBytes(input[0..input_len], null) catch return false;
    std.mem.doNotOptimizeAway(result.parsed_bytes);
    return result.parsed_bytes == input_len;
}

fn destroy(context: ?*anyopaque) callconv(.c) void {
    const session: *galley.Session = @ptrCast(@alignCast(context orelse return));
    session.deinit();
    std.heap.c_allocator.destroy(session);
}

comptime {
    @export(&create, .{ .name = options.create_symbol });
    @export(&parse, .{ .name = options.parse_symbol });
    @export(&destroy, .{ .name = options.destroy_symbol });
}
