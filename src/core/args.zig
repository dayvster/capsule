const std = @import("std");

pub const Config = struct {
    verbosity: u2 = 0,
    uid: ?u32 = null,
    gid: ?u32 = null,
};

pub fn parse(env_map: *const std.process.Environ.Map, args_iter: anytype) Config {
    var cfg = Config{};
    if (env_map.get("SUDO_UID")) |v| cfg.uid = std.fmt.parseUnsigned(u32, v, 10) catch null;
    if (env_map.get("SUDO_GID")) |v| cfg.gid = std.fmt.parseUnsigned(u32, v, 10) catch null;
    if (env_map.get("CAPSULE_UID")) |v| cfg.uid = std.fmt.parseUnsigned(u32, v, 10) catch null;
    if (env_map.get("CAPSULE_GID")) |v| cfg.gid = std.fmt.parseUnsigned(u32, v, 10) catch null;
    _ = args_iter.next();
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) {
            cfg.verbosity = 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-v") and cfg.verbosity < 2) {
            cfg.verbosity += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--uid")) {
            const val = args_iter.next() orelse continue;
            cfg.uid = std.fmt.parseUnsigned(u32, val, 10) catch continue;
            continue;
        }
        if (std.mem.eql(u8, arg, "--gid")) {
            const val = args_iter.next() orelse continue;
            cfg.gid = std.fmt.parseUnsigned(u32, val, 10) catch continue;
            continue;
        }
    }
    return cfg;
}
