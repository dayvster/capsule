const std = @import("std");
const linux = std.os.linux;
const Error = @import("errors.zig").Error;

pub const LinuxUtils = struct {
    pub fn openNetlinkSocket() !i32 {
        const raw = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, linux.NETLINK.KOBJECT_UEVENT);
        if (linux.errno(raw) != .SUCCESS) return Error.SocketFailed;
        return @intCast(raw);
    }

    pub fn bindSocket(sock: i32) !void {
        var addr = linux.sockaddr.nl{ .pid = 0, .groups = 1 };
        const rc = linux.bind(sock, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl));
        if (linux.errno(rc) != .SUCCESS) return Error.BindFailed;
    }

    pub fn extractField(data: []const u8, prefix: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, data, 0);
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
        }
        return null;
    }
};
