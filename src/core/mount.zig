const std = @import("std");
const linux = std.os.linux;
const log = @import("log.zig");
const Notifier = @import("notify.zig").Notifier;
const Io = std.Io;

const NOSUID: u32 = 2;
const NODEV: u32 = 4;
const NOEXEC: u32 = 8;
const MNT_DETACH: u32 = 0x00000001;
const POLL_ATTEMPTS: usize = 20;
const POLL_INTERVAL_NS: u64 = 100_000_000;

const MountEntry = struct { device: []const u8, label: []const u8 };

const FsType = enum {
    vfat,
    exfat,
    ext4,
    ntfs3,
    ntfs,
    ext3,
    ext2,
    btrfs,
    xfs,
    iso9660,
    hfsplus,
    msdos,
};

const UnmountOut = enum { ok, dir_remains, failed };

pub const Mounter = struct {
    io: Io,
    allocator: std.mem.Allocator,
    notifier: Notifier,
    entries: std.ArrayList(MountEntry),
    owner_uid: ?u32,
    owner_gid: ?u32,
    last_cleanup: i64,

    pub fn init(io: Io, a: std.mem.Allocator, uid: ?u32, gid: ?u32, env: *const std.process.Environ.Map) Mounter {
        return Mounter{ .io = io, .allocator = a, .notifier = Notifier.init(io, a, env), .entries = .empty, .owner_uid = uid, .owner_gid = gid, .last_cleanup = 0 };
    }

    pub fn deinit(self: *Mounter) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.device);
            self.allocator.free(e.label);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn tick(self: *Mounter) void {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(linux.clockid_t.MONOTONIC, &ts);
        if (ts.sec - self.last_cleanup < 5) return;
        self.last_cleanup = ts.sec;
        self.cleanupStale();
    }

    pub fn cleanupStale(self: *Mounter) void {
        const dir = Io.Dir.openDirAbsolute(self.io, "/media", .{ .iterate = true }) catch return log.l2("mount: /media not available\n", .{});
        defer Io.Dir.close(dir, self.io);
        var cleaned: usize = 0;
        var failed: usize = 0;
        var it = Io.Dir.iterate(dir);
        while (true) {
            const e = Io.Dir.Iterator.next(&it, self.io) catch break orelse break;
            if (e.kind != .directory) continue;
            if (cleanStaleEntry(e.name)) cleaned += 1 else failed += 1;
        }
        if (cleaned > 0) log.l1(log.messages.stale_cleaned, .{ cleaned, if (cleaned == 1) "" else "s" });
        if (failed > 0) log.l1(log.messages.stale_failed, .{ failed, if (failed == 1) "" else "s" });
    }

    pub fn mountDevice(self: *Mounter, name: []const u8) void {
        self.tick();
        if (!waitForNode(name)) {
            if (log.level() < 1) log.info("  {s}  disappeared before mount\n", .{name});
            return log.l1(log.messages.device_gone, .{name});
        }
        const owned = self.resolveLabel(name);
        const label = owned orelse name;
        log.l1(log.messages.mounting, .{ name, label });
        if (tryMount(name, label)) |fs| {
            if (log.level() < 1) log.info("  {s}  →  mounted  \"{s}\"  ({s})  /media/{s}\n", .{ name, label, @tagName(fs), label });
            log.l1(log.messages.mounted, .{ name, @tagName(fs), label });
            self.doChown(label);
            self.storeEntry(name, label);
            self.notifier.send(self.owner_uid, "Device Mounted", label);
            if (owned) |l| self.allocator.free(l);
        } else {
            if (log.level() < 1) log.info("  {s}  →  mount failed\n", .{name});
            log.l1(log.messages.mount_fail, .{name});
            if (owned) |l| self.allocator.free(l);
        }
    }

    pub fn unmountDevice(self: *Mounter, name: []const u8) void {
        const idx = findEntryIndex(self, name);
        const stored = if (idx) |i| self.entries.items[i].label else null;
        const owned = if (stored == null) self.resolveLabel(name) else null;
        const label = stored orelse owned orelse name;
        const dev_rc = unmountAndCleanDir(name);
        const lbl_rc = if (!std.mem.eql(u8, label, name)) unmountAndCleanDir(label) else UnmountOut.failed;
        reportUnmountResult(self, name, label, dev_rc, lbl_rc);
        if (idx != null) self.removeEntry(name);
        if (owned) |l| self.allocator.free(l);
    }

    fn removeEntry(self: *Mounter, name: []const u8) void {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.device, name)) {
                self.allocator.free(e.device);
                self.allocator.free(e.label);
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    fn resolveLabel(self: *Mounter, name: []const u8) ?[]const u8 {
        var attempt: usize = 0;
        while (attempt < POLL_ATTEMPTS) : (attempt += 1) {
            if (findLabelInDir(self, name)) |l| return l;
            if (attempt + 1 < POLL_ATTEMPTS) sleepNs(POLL_INTERVAL_NS);
        }
        log.l2("mount: by-label timed out, trying direct read\n", .{});
        if (readLabelFromDev(self, name)) |l| return l;
        log.l2("mount: no label found, using device name\n", .{});
        return null;
    }

    fn doChown(self: *Mounter, label: []const u8) void {
        if (self.owner_uid) |uid| if (self.owner_gid) |gid| {
            var buf: [256]u8 = undefined;
            const p = std.fmt.bufPrintZ(&buf, "/media/{s}", .{label}) catch return;
            log.l2("chown: {s} → {}\n", .{ p, linux.errno(linux.chown(p, uid, gid)) });
        };
    }

    fn storeEntry(self: *Mounter, name: []const u8, label: []const u8) void {
        const d = self.allocator.dupe(u8, name) catch return;
        const l = self.allocator.dupe(u8, label) catch return self.allocator.free(d);
        self.entries.append(self.allocator, .{ .device = d, .label = l }) catch {
            self.allocator.free(d);
            self.allocator.free(l);
        };
    }
};

fn findEntryIndex(m: *const Mounter, name: []const u8) ?usize {
    for (m.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.device, name)) return i;
    return null;
}

fn sleepNs(ns: u64) void {
    var req = linux.timespec{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    _ = linux.nanosleep(&req, null);
}

fn waitForNode(name: []const u8) bool {
    var buf: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, "/dev/{s}", .{name}) catch return false;
    var attempt: usize = 0;
    while (attempt < POLL_ATTEMPTS) : (attempt += 1) {
        if (linux.errno(linux.access(p, 0)) == .SUCCESS) return true;
        if (attempt + 1 < POLL_ATTEMPTS) sleepNs(POLL_INTERVAL_NS);
    }
    log.l2("access: /dev/{s} never appeared\n", .{name});
    return false;
}

fn cleanStaleEntry(name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, "/media/{s}", .{name}) catch return false;
    _ = linux.umount2(p, MNT_DETACH);
    const rc = linux.errno(linux.rmdir(p));
    return rc == .SUCCESS or rc == .NOENT;
}

fn makeDir(p: [:0]const u8) bool {
    const rc = linux.errno(linux.mkdir(p, 0o755));
    log.l2("mkdir: {s} → {}\n", .{ p, rc });
    return rc == .SUCCESS or rc == .EXIST;
}

fn findLabelInDir(m: *Mounter, name: []const u8) ?[]const u8 {
    const dir = Io.Dir.openDirAbsolute(m.io, "/dev/disk/by-label", .{ .iterate = true }) catch return null;
    defer Io.Dir.close(dir, m.io);
    var buf: [256]u8 = undefined;
    var it = Io.Dir.iterate(dir);
    while (true) {
        const e = Io.Dir.Iterator.next(&it, m.io) catch break orelse break;
        if (e.kind != .sym_link) continue;
        const n = Io.Dir.readLink(dir, m.io, e.name, &buf) catch continue;
        if (!std.mem.endsWith(u8, buf[0..n], name)) continue;
        log.l2("mount: found label \"{s}\" for {s}\n", .{ e.name, name });
        return m.allocator.dupe(u8, e.name) catch null;
    }
    return null;
}

fn readLabelFromDev(m: *Mounter, name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, "/dev/{s}", .{name}) catch return null;
    const raw = linux.open(p, linux.O{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(raw) != .SUCCESS) return null;
    const fd: i32 = @intCast(raw);
    defer _ = linux.close(fd);
    if (readFatLabel(fd, m.allocator)) |l| return l;
    if (readExt4Label(fd, m.allocator)) |l| return l;
    return null;
}

fn readFatLabel(fd: i32, a: std.mem.Allocator) ?[]const u8 {
    var sector: [512]u8 = undefined;
    const n = linux.read(fd, &sector, sector.len);
    if (linux.errno(n) != .SUCCESS or n != 512) return null;
    if (sector[510] != 0x55 or sector[511] != 0xAA) return null;
    const is32 = std.mem.readInt(u16, sector[0x16..][0..2], .little) == 0;
    const off: usize = if (is32) 0x47 else 0x2B;
    const raw = trimLabel(sector[off..][0..11]) orelse return null;
    const label = a.dupe(u8, raw) catch return null;
    log.l2("read: FAT label \"{s}\" (fat32={any})\n", .{ label, is32 });
    return label;
}

fn readExt4Label(fd: i32, a: std.mem.Allocator) ?[]const u8 {
    var sb: [512]u8 = undefined;
    const n = linux.pread(fd, &sb, sb.len, 0x400);
    if (linux.errno(n) != .SUCCESS or n != 512) return null;
    const end = std.mem.indexOfScalar(u8, sb[0x78..][0..16], 0) orelse 16;
    if (end == 0) return null;
    for (sb[0x78..][0..end]) |c| if (c < 0x20 or c > 0x7E) return null;
    const label = a.dupe(u8, sb[0x78..][0..end]) catch return null;
    log.l2("pread: ext4 label \"{s}\"\n", .{label});
    return label;
}

fn trimLabel(raw: []const u8) ?[]const u8 {
    var end: usize = raw.len;
    while (end > 0 and (raw[end - 1] == ' ' or raw[end - 1] == 0)) end -= 1;
    if (end == 0) return null;
    for (raw[0..end]) |c| if (c < 0x20 or c > 0x7E) return null;
    return raw[0..end];
}

fn tryMount(name: []const u8, label: []const u8) ?FsType {
    var mp_buf: [256]u8 = undefined;
    var dp_buf: [64]u8 = undefined;
    const mp = std.fmt.bufPrintZ(&mp_buf, "/media/{s}", .{label}) catch return null;
    const dp = std.fmt.bufPrintZ(&dp_buf, "/dev/{s}", .{name}) catch return null;
    if (!makeDir("/media")) return null;
    if (!makeDir(mp)) return null;
    var retry: usize = 0;
    while (retry < 3) : (retry += 1) {
        if (tryAllFs(dp, mp)) |fs| return fs;
        if (retry < 2) sleepNs(POLL_INTERVAL_NS);
    }
    return null;
}

fn tryAllFs(dev: [:0]const u8, mp: [:0]const u8) ?FsType {
    inline for (std.meta.tags(FsType)) |fs| {
        const name = @tagName(fs);
        const rc = linux.errno(linux.mount(dev, mp, name, NOSUID | NODEV | NOEXEC, 0));
        switch (rc) {
            .SUCCESS => return fs,
            .PERM, .BUSY => return null,
            .INVAL, .NODEV => {},
            else => log.l2("mount: {s} → {}\n", .{ name, rc }),
        }
    }
    return null;
}

fn unmountAndCleanDir(name: []const u8) UnmountOut {
    var buf: [256]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, "/media/{s}", .{name}) catch return .failed;
    if (doUnmount(p)) {
        const rc = linux.errno(linux.rmdir(p));
        if (rc != .SUCCESS and rc != .NOENT) log.l2("rmdir: {s} → {}\n", .{ p, rc });
        return if (rc == .SUCCESS or rc == .NOENT) .ok else .dir_remains;
    }
    if (linux.errno(linux.rmdir(p)) == .SUCCESS) log.l2("mount: cleaned orphan {s}\n", .{p});
    return .failed;
}

fn doUnmount(p: [:0]const u8) bool {
    const rc = linux.errno(linux.umount(p));
    log.l2("umount: {s} → {}\n", .{ p, rc });
    if (rc == .SUCCESS) return true;
    log.l2("mount: trying lazy unmount for {s}\n", .{p});
    const lrc = linux.errno(linux.umount2(p, MNT_DETACH));
    log.l2("umount2: {s} → {}\n", .{ p, lrc });
    return lrc == .SUCCESS;
}

fn reportUnmountResult(m: *Mounter, name: []const u8, label: []const u8, d_rc: UnmountOut, l_rc: UnmountOut) void {
    if (d_rc == .ok or l_rc == .ok) {
        const which = if (d_rc == .ok) name else label;
        if (log.level() < 1) log.info("  {s}  →  unmounted  from  /media/{s}\n", .{ which, label });
        log.l1(log.messages.unmounted, .{ which, label });
        m.notifier.send(m.owner_uid, "Device Removed", label);
    } else if (d_rc == .dir_remains or l_rc == .dir_remains) {
        if (log.level() < 1) log.info("  {s}  →  unmounted  but  /media/{s}  remains\n", .{ name, label });
        log.l1(log.messages.unmount_dir_remains, .{ name, label });
        m.notifier.send(m.owner_uid, "Device Removed", label);
    } else {
        if (log.level() < 1) log.info("  {s}  →  still mounted  (unsafe removal)\n", .{name});
        log.l1(log.messages.unsafe_removal, .{name});
    }
}
