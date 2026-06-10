const std = @import("std");
const linux = std.os.linux;
const UEvent = @import("uevent.zig").Uevent;
const Parser = @import("parser.zig").Parser;
const Error = @import("errors.zig").Error;

pub const Listener = struct {
    socket: i32,
    buffer: [8192]u8,

    pub fn init() !Listener {
        const fd = try openNetlinkSocket();
        const sock: i32 = @intCast(fd);
        errdefer _ = linux.close(sock);
        try bindSocket(sock);
        return Listener{ .socket = sock, .buffer = undefined };
    }

    pub fn setRecvTimeout(self: *Listener, seconds: i64) void {
        var tv = linux.timeval{ .sec = seconds, .usec = 0 };
        _ = linux.setsockopt(self.socket, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
    }

    pub fn deinit(self: *Listener) void {
        _ = linux.close(self.socket);
    }

    pub fn next(self: *Listener) !UEvent {
        const bytes_received = linux.recvfrom(self.socket, &self.buffer, self.buffer.len, 0, null, null);
        if (linux.errno(bytes_received) != .SUCCESS) {
            if (linux.errno(bytes_received) == .AGAIN) return Error.TimedOut;
            return Error.RecvFailed;
        }
        const data = self.buffer[0..bytes_received];
        return Parser.parse(data) orelse Error.InvalidUevent;
    }
};

fn openNetlinkSocket() !i32 {
    const raw = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, linux.NETLINK.KOBJECT_UEVENT);
    if (linux.errno(raw) != .SUCCESS) return Error.SocketFailed;
    return @intCast(raw);
}

fn bindSocket(sock: i32) !void {
    var addr = linux.sockaddr.nl{ .pid = 0, .groups = 1 };
    const rc = linux.bind(sock, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl));
    if (linux.errno(rc) != .SUCCESS) return Error.BindFailed;
}
