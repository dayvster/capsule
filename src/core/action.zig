const std = @import("std");
pub const Action = enum {
    add,
    remove,
    change,
    bind,
    unbind,
    other,

    pub fn fromBytes(bytes: []const u8) Action {
        if (std.mem.eql(u8, bytes, "add")) return .add;
        if (std.mem.eql(u8, bytes, "remove")) return .remove;
        if (std.mem.eql(u8, bytes, "change")) return .change;
        if (std.mem.eql(u8, bytes, "bind")) return .bind;
        if (std.mem.eql(u8, bytes, "unbind")) return .unbind;
        return .other;
    }
};
