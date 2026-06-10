const std = @import("std");
const linux = std.os.linux;
const core = @import("core");

fn isPartition(event: *const core.UEvent) bool {
    return event.isBlockDevice() and event.device_type != null and std.mem.eql(u8, event.device_type.?, "partition");
}

fn logEvent(cfg: *const core.args.Config, event: core.UEvent) void {
    if (cfg.verbosity >= 2)
        return event.logAll();

    const is_partition = event.device_type != null and std.mem.eql(u8, event.device_type.?, "partition");
    const show_majmin = event.major_number != null and event.minor_number != null;

    if (cfg.verbosity >= 1) {
        switch (event.action) {
            .add => core.log.l1("<green>  ADD</>     <bold>{s}</>  <cyan>{s}</>", .{ event.device_name, event.subsystem }),
            .remove => core.log.l1("<red>  REMOVE</>  <bold>{s}</>  <cyan>{s}</>", .{ event.device_name, event.subsystem }),
            .change => core.log.l1("<yellow>  CHANGE</>  <bold>{s}</>  <cyan>{s}</>", .{ event.device_name, event.subsystem }),
            .bind => core.log.l1("<dim>  BIND</>    <bold>{s}</>  <cyan>{s}</>", .{ event.device_name, event.subsystem }),
            .unbind => core.log.l1("<dim>  UNBIND</>  <bold>{s}</>  <cyan>{s}</>", .{ event.device_name, event.subsystem }),
            .other => core.log.l1("<dim>  OTHER</>   <bold>{s}</>  <cyan>{s}</>", .{ event.device_name, event.subsystem }),
        }
        if (show_majmin) core.log.l1("  <dim>[{d}:{d}]</>", .{ event.major_number.?, event.minor_number.? });
        core.log.l1("\n", .{});
        return;
    }

    if (!is_partition) return;

    const tag = switch (event.action) {
        .add => "ADD",
        .remove => "REMOVE",
        .change => "CHANGE",
        .bind => "BIND",
        .unbind => "UNBIND",
        .other => "OTHER",
    };
    core.log.info("  {s:4}  {s}", .{ tag, event.device_name });
    if (show_majmin) core.log.info("  [{d}:{d}]", .{ event.major_number.?, event.minor_number.? });
    core.log.info("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var args_iter = init.minimal.args.iterate();
    const cfg = core.args.parse(init.environ_map, &args_iter);
    if (linux.getuid() != 0) core.log.info("warning: not root — mounting will fail (run with sudo)\n", .{});
    core.log.setLevel(cfg.verbosity);

    var mounter = core.Mounter.init(init.io, std.heap.page_allocator, cfg.uid, cfg.gid, init.environ_map);
    defer mounter.deinit();
    mounter.cleanupStale();

    var listener = try core.Listener.init();
    defer listener.deinit();
    listener.setRecvTimeout(5);

    if (cfg.verbosity >= 1) {
        core.log.style.green("  ◆  Capsule started — listening for devices\n");
    } else {
        core.log.info("  Capsule started — listening for devices\n", .{});
    }

    while (true) {
        const event = listener.next() catch |err| {
            if (err == error.TimedOut) {
                mounter.tick();
                continue;
            }
            core.log.l2("<red>  ✗</>  listener error: {s}\n", .{@errorName(err)});
            continue;
        };

        if (!event.isBlockDevice()) continue;

        logEvent(&cfg, event);

        if (isPartition(&event)) {
            if (event.action == .add) mounter.mountDevice(event.device_name);
            if (event.action == .remove) mounter.unmountDevice(event.device_name);
        }
    }
}
