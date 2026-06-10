const std = @import("std");
const Action = @import("action.zig").Action;

pub const Uevent = struct {
    action: Action,
    sequence_number: u64,
    device_path: []const u8,
    subsystem: []const u8,
    device_name: []const u8,
    device_type: ?[]const u8 = null,
    major_number: ?u32 = null,
    minor_number: ?u32 = null,

    pub fn isBlockDevice(self: Uevent) bool {
        if (std.mem.eql(u8, self.subsystem, "block")) return true;
        if (self.device_type) |type_name| {
            if (std.mem.eql(u8, type_name, "partition")) return true;
        }
        return false;
    }

    pub fn logAll(self: Uevent) void {
        std.debug.print("[#{d:>5}]", .{self.sequence_number});
        const al = switch (self.action) {
            .add => "ADD",
            .remove => "REMOVE",
            .change => "CHANGE",
            .bind => "BIND",
            .unbind => "UNBIND",
            .other => "OTHER",
        };
        std.debug.print(" {s:>7} ", .{al});
        std.debug.print(" {s:>12}", .{self.device_name});
        std.debug.print(" {s:>8}", .{self.subsystem});
        std.debug.print(" {s}", .{self.device_path});
        if (self.device_type) |t| std.debug.print("  ({s})", .{t});
        if (self.major_number) |maj| if (self.minor_number) |min| std.debug.print("  [{d}:{d}]", .{ maj, min });
        std.debug.print("\n", .{});
    }
};
