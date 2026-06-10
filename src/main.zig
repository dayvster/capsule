const std = @import("std");
const core = @import("core");

pub fn main() !void {
    var listener = try core.Listener.init();
    defer listener.deinit();

    listener.setRecvTimeout(5);

    while (true) {
        const event = listener.next() catch |err| {
            std.log.warn("Error receiving event: {s}\n", .{@errorName(err)});
            continue;
        };
        event.logAll();
    }
}
