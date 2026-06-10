const std = @import("std");
const log = @import("log.zig");
const Io = std.Io;

pub const Notifier = struct {
    io: Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,

    pub fn init(io: Io, allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) Notifier {
        return Notifier{ .io = io, .allocator = allocator, .environ_map = environ_map };
    }

    pub fn send(self: *Notifier, user_id: ?u32, title: []const u8, message: []const u8) void {
        if (user_id) |uid| sendAsUser(self, uid, title, message) else sendAsRoot(self, title, message);
    }
};

fn sendAsUser(self: *Notifier, uid: u32, title: []const u8, message: []const u8) void {
    var env_map = std.process.Environ.Map.init(self.allocator);
    defer env_map.deinit();
    buildUserEnv(self, uid, &env_map);

    var child = std.process.spawn(self.io, .{
        .argv = &.{ "/usr/bin/notify-send", title, message },
        .uid = uid,
        .environ_map = &env_map,
        .stderr = .ignore,
        .stdout = .ignore,
        .stdin = .ignore,
    }) catch |err| return log.l1(log.messages.notify_fail, .{ "spawn", @errorName(err) });
    errdefer child.kill(self.io);
    const term = child.wait(self.io) catch |err| return log.l1(log.messages.notify_fail, .{ "wait", @errorName(err) });
    reportResult(term, uid);
}

fn sendAsRoot(self: *Notifier, title: []const u8, message: []const u8) void {
    var child = std.process.spawn(self.io, .{
        .argv = &.{ "/usr/bin/notify-send", title, message },
        .stderr = .ignore,
        .stdout = .ignore,
        .stdin = .ignore,
    }) catch |err| return log.l1(log.messages.notify_fail, .{ "spawn", @errorName(err) });
    errdefer child.kill(self.io);
    const term = child.wait(self.io) catch |err| return log.l1(log.messages.notify_fail, .{ "wait", @errorName(err) });
    reportResult(term, 0);
}

fn buildUserEnv(self: *const Notifier, uid: u32, env_map: *std.process.Environ.Map) void {
    var dbus_buf: [128]u8 = undefined;
    const dbus = buildDbusAddr(self, uid, &dbus_buf) orelse return;
    env_map.put("DBUS_SESSION_BUS_ADDRESS", dbus) catch return;
    var home_buf: [256]u8 = undefined;
    env_map.put("HOME", buildHomeDir(self, uid, &home_buf)) catch return;
    env_map.put("DISPLAY", ":0") catch return;
}

fn buildDbusAddr(self: *const Notifier, uid: u32, buf: []u8) ?[]const u8 {
    if (self.environ_map.get("XDG_RUNTIME_DIR")) |dir| return std.fmt.bufPrint(buf, "unix:path={s}/bus", .{dir}) catch null;
    return std.fmt.bufPrint(buf, "unix:path=/run/user/{d}/bus", .{uid}) catch null;
}

fn buildHomeDir(self: *const Notifier, uid: u32, buf: []u8) []const u8 {
    if (self.environ_map.get("HOME")) |home| return home;
    return std.fmt.bufPrint(buf, "/home/user{d}", .{uid}) catch "/";
}

fn reportResult(term: std.process.Child.Term, uid: u32) void {
    switch (term) {
        .exited => |code| {
            if (code != 0) log.l1("<yellow>notify:</> exited with code {d} (uid={d})\n", .{ code, uid });
        },
        .signal => |sig| log.l1("<red>notify:</> signal {d}\n", .{sig}),
        .stopped => |sig| log.l1("<red>notify:</> stopped {d}\n", .{sig}),
        .unknown => |code| log.l1("<red>notify:</> unknown {d}\n", .{code}),
    }
}
