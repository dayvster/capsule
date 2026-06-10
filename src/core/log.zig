const std = @import("std");
const linux = std.os.linux;

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
};

const tag_open = std.ComptimeStringMap(Tag, .{
    .{ "<bold>", .bold },
    .{ "</>", .plain },
    .{ "<dim>", .dim },
    .{ "<green>", .green },
    .{ "<red>", .red },
    .{ "<yellow>", .yellow },
    .{ "<cyan>", .cyan },
    .{ "<magenta>", .magenta },
    .{ "<blue>", .blue },
});

fn tagCode(tag: Tag) []const u8 {
    return switch (tag) {
        .bold => Bold,
        .dim => Dim,
        .green => Green,
        .red => Red,
        .yellow => Yellow,
        .cyan => Cyan,
        .magenta => Magenta,
        .blue => Blue,
        .plain => Reset,
    };
}

fn matchTag(comptime fmt: []const u8, comptime i: usize) ?Tag {
    if (i + 3 <= fmt.len and std.mem.eql(u8, fmt[i..][0..3], "</>")) return .plain;
    for (std.meta.tags(Tag)) |tag| {
        if (tag == .plain) continue;
        const tagname = @tagName(tag);
        const open = "<" ++ tagname ++ ">";
        if (i + open.len <= fmt.len and std.mem.eql(u8, fmt[i .. i + open.len], open)) return tag;
    }
    return null;
}

fn extractSpec(comptime fmt: []const u8, comptime i: usize) []const u8 {
    var end = i + 1;
    while (end < fmt.len and fmt[end] != '}') end += 1;
    return fmt[i + 1 .. end];
}

fn countArgsBefore(comptime fmt: []const u8, comptime pos: usize) usize {
    @setEvalBranchQuota(10000);
    var count: usize = 0;
    var j: usize = 0;
    while (j < pos) {
        if (fmt[j] == '{' and j + 1 < fmt.len and fmt[j + 1] != '{') {
            var end = j + 1;
            while (end < fmt.len and fmt[end] != '}') end += 1;
            if (end < fmt.len) {
                count += 1;
                j = end + 1;
                continue;
            }
        }
        j += 1;
    }
    return count;
}

var current_level: u2 = 0;

pub fn setLevel(lvl: u2) void {
    current_level = lvl;
}

pub fn level() u2 {
    return current_level;
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn l1(comptime fmt: []const u8, args: anytype) void {
    if (current_level >= 1) printTagged(fmt, args);
}

pub fn l2(comptime fmt: []const u8, args: anytype) void {
    if (current_level >= 2) printTagged(fmt, args);
}

fn writeRaw(bytes: []const u8) void {
    _ = linux.write(2, bytes.ptr, bytes.len);
}

fn formatArg(comptime spec: []const u8, arg: anytype) void {
    if (comptime std.mem.eql(u8, spec, "s")) {
        writeRaw(arg);
    } else if (comptime std.mem.eql(u8, spec, "d")) {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{arg}) catch return;
        writeRaw(s);
    } else if (comptime std.mem.eql(u8, spec, "any")) {
        var buf: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{any}", .{arg}) catch return;
        writeRaw(s);
    } else if (comptime std.mem.eql(u8, spec, "")) {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{}", .{arg}) catch return;
        writeRaw(s);
    } else {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{any}", .{arg}) catch return;
        writeRaw(s);
    }
}

fn printTagged(comptime fmt: []const u8, args: anytype) void {
    var skip: usize = 0;

    inline for (fmt, 0..) |c, i| {
        if (i >= skip) {
            const arg_idx = comptime countArgsBefore(fmt, i);

            if (c == '<') {
                if (comptime matchTag(fmt, i)) |tag| {
                    writeRaw(tagCode(tag));
                    const tagname = comptime @tagName(tag);
                    skip = i + 2 + tagname.len;
                } else {
                    writeRaw(&[_]u8{c});
                }
            } else if (c == '{') {
                if (comptime (i + 1 < fmt.len and fmt[i + 1] == '{')) {
                    writeRaw(&[_]u8{'{'});
                    skip = i + 2;
                } else if (comptime blk: {
                    var end = i + 1;
                    while (end < fmt.len and fmt[end] != '}') end += 1;
                    break :blk end < fmt.len;
                }) {
                    const spec = comptime extractSpec(fmt, i);
                    formatArg(spec, args[arg_idx]);
                    skip = i + spec.len + 2;
                } else {
                    writeRaw(&[_]u8{'{'});
                }
            } else if (c == '}') {
                if (comptime (i + 1 < fmt.len and fmt[i + 1] == '}')) {
                    writeRaw(&[_]u8{'}'});
                    skip = i + 2;
                } else {
                    writeRaw(&[_]u8{'}'});
                }
            } else {
                writeRaw(&[_]u8{c});
            }
        }
    }
}

pub const messages = struct {
    pub const device_arrived = "<green>  ◆</>  <bold>{s}</>  <cyan>{s}</>\n";
    pub const device_departed = "<red>  ◆</>  <bold>{s}</>\n";
    pub const mounting = "<cyan>  ▸</>  <bold>{s}</>  <dim>→</>  <magenta>{s}</>\n";
    pub const mounted = "<green>  ✓</>  <bold>{s}</>  <dim>→</>  <cyan>/media/{s}</>  <dim>({s})</>\n";
    pub const unmounted = "<green>  ✓</>  <bold>{s}</>  <dim>←</>  <cyan>/media/{s}</>\n";
    pub const mount_fail = "<red>  ✗</>  <bold>{s}</>  <dim>→</>  mount failed\n";
    pub const unmount_dir_remains = "<yellow>  ⚠</>  <bold>{s}</>  unmounted  <dim>but</>  <cyan>/media/{s}</>  <dim>could not be deleted</>\n";
    pub const unsafe_removal = "<red>  ⚠</>  <bold>{s}</>  <dim>still mounted —</>  unsafe removal\n";
    pub const stale_cleaned = "<green>  ✓</>  cleaned <bold>{d}</> stale mount point{s}\n";
    pub const stale_failed = "<red>  ✗</>  <bold>{d}</> stale mount point{s} could not be removed\n";
    pub const device_gone = "<red>  ✗</>  <bold>{s}</>  <dim>disappeared before mount</>\n";
    pub const notify_fail = "<red>  ✗</>  <bold>notify-send</>  <dim>{s}: {s}</>\n";
};

pub const style = struct {
    pub fn bold(text: []const u8) void {
        std.debug.print(Bold ++ "{s}" ++ Reset, .{text});
    }
    pub fn green(text: []const u8) void {
        std.debug.print(Green ++ "{s}" ++ Reset, .{text});
    }
    pub fn red(text: []const u8) void {
        std.debug.print(Red ++ "{s}" ++ Reset, .{text});
    }
    pub fn cyan(text: []const u8) void {
        std.debug.print(Cyan ++ "{s}" ++ Reset, .{text});
    }
    pub fn dim(text: []const u8) void {
        std.debug.print(Dim ++ "{s}" ++ Reset, .{text});
    }
    pub fn yellow(text: []const u8) void {
        std.debug.print(Yellow ++ "{s}" ++ Reset, .{text});
    }
    pub fn magenta(text: []const u8) void {
        std.debug.print(Magenta ++ "{s}" ++ Reset, .{text});
    }
    pub fn blue(text: []const u8) void {
        std.debug.print(Blue ++ "{s}" ++ Reset, .{text});
    }
};
