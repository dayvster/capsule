const std = @import("std");

const Tag = enum {
    bold,
    dim,
    green,
    red,
    yellow,
    cyan,
    magenta,
    blue,
    plain,
    underline,
};

const tag_map = std.ComptimeStringMap(Tag, .{
    .{ "<bold>", .bold },
    .{ "<dim>", .dim },
    .{ "<green>", .green },
    .{ "<red>", .red },
    .{ "<yellow>", .yellow },
    .{ "<cyan>", .cyan },
    .{ "<magenta>", .magenta },
    .{ "<blue>", .blue },
    .{ "<plain>", .plain },
    .{ "<underline>", .underline },
});

const esc = "\x1b";
const Reset = esc ++ "[0m";
const Bold = esc ++ "[1m";
const Dim = esc ++ "[2m";
const Green = esc ++ "[32m";
const Red = esc ++ "[31m";
const Yellow = esc ++ "[33m";
const Cyan = esc ++ "[36m";
const Magenta = esc ++ "[35m";
const Blue = esc ++ "[34m";
const Underline = esc ++ "[4m";

pub const messages = struct {
    pub const init_msg = "<bold>Initializing Capsule...</bold>";
    pub const start_msg = "<bold>Capsule started: listening for devices</bold>";
    pub const device_arrived = "<green>Device arrived: {s}</green>";
    pub const device_removed = "<red>Device removed: {s}</red>";
};

pub const Logger = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Logger {
        return Logger{ .allocator = allocator };
    }

    pub fn log(self: *Logger, message: []const u8, timestamp: bool) !void {
        const stderr = std.io.getStdErr();
        const writer = stderr.writer();

        if (timestamp) {
            const ts = std.time.timestamp();
            const ts_str = try self.formatTimestamp(ts);
            defer self.allocator.free(ts_str);
            try writer.print("[{s}] ", .{ts_str});
        }

        try self.renderTagged(writer, message);
        try writer.writeAll("\n");
    }

    fn formatTimestamp(self: *Logger, ts: i64) ![]const u8 {
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
        const day_secs = epoch.getDaySeconds();
        const year_day = epoch.getYearDay();
        const month_day = std.time.epoch.MonthDay.calculate(year_day.day);
        return std.fmt.allocPrint(self.allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            @as(u4, month_day.month),
            @as(u8, month_day.day_index + 1),
            day_secs.hours,
            day_secs.minutes,
            day_secs.seconds,
        });
    }

    fn renderTagged(self: *Logger, writer: anytype, message: []const u8) !void {
        _ = self;
        var i: usize = 0;
        while (i < message.len) {
            if (message[i] == '<') {
                const end = std.mem.indexOfScalarPos(u8, message, i + 1, '>') orelse {
                    try writer.writeAll(message[i..]);
                    break;
                };
                const tag = message[i .. end + 1];
                if (tag.len > 2 and tag[1] == '/') {
                    try writer.writeAll(Reset);
                } else if (tag_map.get(tag)) |t| {
                    try writer.writeAll(tagToCode(t));
                } else {
                    try writer.writeAll(tag);
                }
                i = end + 1;
            } else {
                try writer.writeByte(message[i]);
                i += 1;
            }
        }
    }
};

fn tagToCode(tag: Tag) []const u8 {
    return switch (tag) {
        .bold => Bold,
        .dim => Dim,
        .green => Green,
        .red => Red,
        .yellow => Yellow,
        .cyan => Cyan,
        .magenta => Magenta,
        .blue => Blue,
        .underline => Underline,
        .plain => Reset,
    };
}
