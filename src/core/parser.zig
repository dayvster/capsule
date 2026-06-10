const std = @import("std");
const UEvent = @import("uevent.zig").Uevent;
const Action = @import("action.zig").Action;
const LinuxUtils = @import("utils.zig").LinuxUtils;

pub const Parser = struct {
    pub fn parse(data: []const u8) ?UEvent {
        const action = LinuxUtils.extractField(data, "ACTION=") orelse return null;
        const devpath = LinuxUtils.extractField(data, "DEVPATH=") orelse return null;
        const subsys = LinuxUtils.extractField(data, "SUBSYSTEM=") orelse return null;
        const devname = LinuxUtils.extractField(data, "DEVNAME=") orelse return null;
        return UEvent{
            .action = Action.fromBytes(action),
            .sequence_number = parseSeq(data),
            .device_path = devpath,
            .subsystem = subsys,
            .device_name = devname,
            .device_type = LinuxUtils.extractField(data, "DEVTYPE="),
            .major_number = parseIntOpt(data, "MAJOR="),
            .minor_number = parseIntOpt(data, "MINOR="),
        };
    }

    fn parseSeq(data: []const u8) u64 {
        const s = LinuxUtils.extractField(data, "SEQNUM=") orelse return 0;
        return std.fmt.parseUnsigned(u64, s, 10) catch 0;
    }

    fn parseIntOpt(data: []const u8, prefix: []const u8) ?u32 {
        const s = LinuxUtils.extractField(data, prefix) orelse return null;
        return std.fmt.parseUnsigned(u32, s, 10) catch null;
    }
};
