const std = @import("std");
const c = @import("c");
const x11 = @import("x11.zig");
const petmod = @import("pet.zig");
const sprites = @import("sprites.zig");
const events = @import("events.zig");

const default_scale: u32 = 4;
const max_scale: u32 = 12;
const frame_ms: c_int = 33;

/// Integer zoom of the 16x16 art, chosen on the command line.
var scale: u32 = default_scale;
/// Window edge in pixels: sprites.W * scale.
var size: u32 = sprites.W * default_scale;

const usage =
    \\usage: pet [--scale N] [--help]
    \\
    \\A cat that lives at the bottom of your screen.
    \\
    \\  --scale N   pixel zoom of the 16x16 art, 1..12 (default 4 = 64px cat)
    \\  -h, --help  show this help
    \\
    \\Mouse:  left-click = meow, drag = carry (it falls when dropped), right-click = quit
    \\Pipe:   echo fail > $XDG_RUNTIME_DIR/pet.fifo   (ok, fail, work, done, sleep, wake, meow, goto X, quit)
    \\
;

pub fn main(init: std.process.Init) !void {
    parseArgs(init.minimal.args);

    var win = try x11.Window.init(size);
    defer win.deinit();

    var fifo: ?events.Fifo = events.Fifo.open() catch |err| blk: {
        std.debug.print("pet: no command fifo ({s})\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (fifo) |*f| f.close();

    var prng = std.Random.DefaultPrng.init(@intCast(nowNs()));
    var pet = petmod.Pet.init(
        prng.random(),
        @floatFromInt(win.screen_w),
        @floatFromInt(win.screen_h),
        @floatFromInt(size),
    );

    std.debug.print("pet: {d}x{d} screen, {s} window\n", .{ win.screen_w, win.screen_h, if (win.argb) "transparent" else "opaque (no ARGB visual)" });
    if (fifo) |f| std.debug.print("pet: commands via  echo fail > {s}\n", .{f.path()});
    std.debug.print("pet: left-click = meow, drag = carry, right-click = quit\n", .{});

    var last_ms = nowMs();
    var last_ptr = win.queryPointer();
    var drag: ?struct { ox: i32, oy: i32, px: i32, py: i32, moved: bool } = null;
    var last_frame: ?*const sprites.Frame = null;
    var last_facing = pet.facing;
    var raise_timer: f32 = 0;
    const debug_events = c.getenv("PET_DEBUG") != null;

    while (true) {
        var fds = [_]c.pollfd{
            .{ .fd = win.fd(), .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (fifo) |f| f.fd else -1, .events = c.POLLIN, .revents = 0 },
        };
        _ = c.poll(&fds, fds.len, frame_ms);

        var input: petmod.Input = .{ .pointer_x = 0, .pointer_y = 0, .pointer_moved = false };

        while (win.pollEvent()) |ev| switch (ev) {
            .press => |p| switch (p.button) {
                1 => {
                    if (debug_events) std.debug.print("pet: press at {d},{d}\n", .{ p.x, p.y });
                    drag = .{ .ox = p.x, .oy = p.y, .px = p.x_root, .py = p.y_root, .moved = false };
                },
                3 => return,
                else => {},
            },
            .release => |r| if (r.button == 1) {
                if (debug_events) std.debug.print("pet: release, drag={?}\n", .{drag});
                if (drag) |d| {
                    if (!d.moved) input.clicked = true;
                    input.drop = true;
                }
                drag = null;
            },
            .motion => |m| if (drag) |*d| {
                if (!d.moved and (@abs(m.x_root - d.px) > 3 or @abs(m.y_root - d.py) > 3)) d.moved = true;
                if (d.moved) input.drag = .{
                    .x = @floatFromInt(m.x_root - d.ox),
                    .y = @floatFromInt(m.y_root - d.oy),
                };
            },
            .expose => last_frame = null,
        };

        const ptr = win.queryPointer();
        input.pointer_x = @floatFromInt(ptr.x);
        input.pointer_y = @floatFromInt(ptr.y);
        input.pointer_moved = ptr.x != last_ptr.x or ptr.y != last_ptr.y;
        last_ptr = ptr;

        if (fifo) |*f| while (f.pollCommand()) |cmd| switch (cmd) {
            .pet => |e| pet.onEvent(e),
            .goto => |x| pet.goTo(x),
            .quit => return,
        };

        const now = nowMs();
        const dt: f32 = @floatCast(@min((now - last_ms) / 1000.0, 0.1));
        last_ms = now;
        pet.update(dt, input);

        const frame = pet.frame();
        if (frame != last_frame or pet.facing != last_facing) {
            render(win.pixels, frame, pet.facing, win.argb);
            if (win.argb) applyInputShape(&win);
            last_frame = frame;
            last_facing = pet.facing;
            win.present();
        }
        win.move(@intFromFloat(pet.x), @intFromFloat(pet.y));

        raise_timer += dt;
        if (raise_timer > 1.0) {
            win.raise();
            raise_timer = 0;
        }
        win.flush();
    }
}

fn parseArgs(args: std.process.Args) void {
    var it = args.iterate();
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--scale")) {
            const value = it.next() orelse fail("--scale needs a number");
            scale = std.fmt.parseInt(u32, value, 10) catch fail("--scale needs a number");
            if (scale < 1 or scale > max_scale) fail("--scale must be between 1 and 12");
        } else {
            fail(arg);
        }
    }
    size = sprites.W * scale;
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("pet: bad argument: {s}\n\n{s}", .{ msg, usage });
    std.process.exit(2);
}

/// Expand the 16x16 frame into the window buffer, mirrored when facing left.
fn render(dst: [*]u32, frame: *const sprites.Frame, facing: petmod.Facing, argb: bool) void {
    const bg: u32 = if (argb) 0 else 0xFF1E1E1E;
    for (0..size) |y| {
        const sy: i32 = @as(i32, @intCast(y / scale)) + frame.dy;
        for (0..size) |x| {
            const sx_raw = x / scale;
            const sx = if (facing == .right) sx_raw else sprites.W - 1 - sx_raw;
            var px: u32 = 0;
            if (sy >= 0 and sy < sprites.H) px = frame.px[@intCast(sy)][sx];
            dst[y * size + x] = if (px >> 24 == 0) bg else px;
        }
    }
}

/// Build horizontal runs of opaque pixels so only the cat itself is clickable.
fn applyInputShape(win: *const x11.Window) void {
    var rects: [sprites.W * max_scale * (sprites.W / 2 + 1)]c.XRectangle = undefined;
    var n: usize = 0;
    for (0..size) |y| {
        var x: usize = 0;
        while (x < size) {
            if (win.pixels[y * size + x] >> 24 == 0) {
                x += 1;
                continue;
            }
            const start = x;
            while (x < size and win.pixels[y * size + x] >> 24 != 0) x += 1;
            rects[n] = .{
                .x = @intCast(start),
                .y = @intCast(y),
                .width = @intCast(x - start),
                .height = 1,
            };
            n += 1;
        }
    }
    win.setInputShape(rects[0..n]);
}

fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

fn nowMs() f64 {
    return @as(f64, @floatFromInt(nowNs())) / 1_000_000.0;
}

test {
    std.testing.refAllDecls(@This());
}
