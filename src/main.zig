const std = @import("std");
const c = @import("c");
const x11 = @import("x11.zig");
const petmod = @import("pet.zig");
const sprites = @import("sprites.zig");
const events = @import("events.zig");
const font = @import("font.zig");

const default_scale: u32 = 4;
const max_scale: u32 = 12;
const default_top: u32 = 32;
const frame_ms: c_int = 33;

/// Integer zoom of the 16x16 art, chosen on the command line.
var scale: u32 = default_scale;
/// Window edge in pixels: sprites.W * scale.
var size: u32 = sprites.W * default_scale;
/// Pixels reserved at the top of the screen (GNOME's bar) that the cat hangs below.
var top: u32 = default_top;
var mute: bool = false;
var character: *const sprites.Character = &sprites.cat;
/// Instance name: selects pet-NAME.fifo so several pets can run at once.
var instance: ?[]const u8 = null;

const usage =
    \\usage: pet [--pet cat|dog|rabbit] [--name NAME] [--scale N] [--top N] [--mute] [--help]
    \\
    \\A small animal that lives on the edges of your screen.
    \\
    \\  --pet KIND  which animal: cat (default), dog or rabbit
    \\  --name NAME run as a named instance listening on pet-NAME.fifo, so you can
    \\              run several at once and address each with petctl -n NAME
    \\  --scale N   pixel zoom of the 16x16 art, 1..12 (default 4 = 64px)
    \\  --top N     pixels reserved for the top panel; the cat hangs below it (default 32)
    \\  --mute      no sounds
    \\  -h, --help  show this help
    \\
    \\Mouse:  left-click = meow, drag = carry (it falls when dropped), rest the pointer on it = paw swipe, right-click = quit
    \\Pipe:   echo fail > $XDG_RUNTIME_DIR/pet.fifo   (ok, fail, work, done, climb, sleep, wake, meow, say TEXT, goto X, quit)
    \\
;

pub fn main(init: std.process.Init) !void {
    parseArgs(init.minimal.args);

    var win = try x11.Window.init(size, size);
    defer win.deinit();
    win.show();

    // The speech bubble is a second, fully click-through window sized for the
    // longest message; only the part a message needs gets painted.
    const text_scale: u32 = @max(1, scale / 2);
    const bubble_max = font.Layout.forChars(petmod.Pet.max_say, text_scale);
    var bubble_win = try x11.Window.init(bubble_max.w, bubble_max.h);
    defer bubble_win.deinit();
    bubble_win.setInputShape(&.{});
    var bubble_shown = false;
    var bubble_text: [petmod.Pet.max_say]u8 = undefined;
    var bubble_len: usize = 0;
    var bubble_layout = bubble_max;

    var fifo: ?events.Fifo = events.Fifo.open(instance) catch |err| blk: {
        std.debug.print("pet: no command fifo ({s})\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (fifo) |*f| f.close();

    var prng = std.Random.DefaultPrng.init(@intCast(nowNs()));
    var pet = petmod.Pet.init(
        prng.random(),
        character,
        @floatFromInt(win.screen_w),
        @floatFromInt(win.screen_h),
        @floatFromInt(size),
        @floatFromInt(top),
    );

    var audio = Audio.init(!mute);

    std.debug.print("pet: a {s}{s}{s}\n", .{ character.name, if (instance != null) " named " else "", instance orelse "" });

    std.debug.print("pet: {d}x{d} screen, {s} window\n", .{ win.screen_w, win.screen_h, if (win.argb) "transparent" else "opaque (no ARGB visual)" });
    if (fifo) |f| std.debug.print("pet: commands via  echo fail > {s}\n", .{f.path()});
    std.debug.print("pet: left-click = meow, drag = carry, right-click = quit\n", .{});

    var last_ms = nowMs();
    var last_ptr = win.queryPointer();
    var drag: ?struct { ox: i32, oy: i32, px: i32, py: i32, moved: bool } = null;
    var last_frame: ?*const sprites.Frame = null;
    var last_transform = pet.transform();
    var raise_timer: f32 = 0;
    const debug_events = c.getenv("PET_DEBUG") != null;
    var bubble_logged = false;

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
            .say => |text| pet.say(text),
            .quit => return,
        };

        const now = nowMs();
        const dt: f32 = @floatCast(@min((now - last_ms) / 1000.0, 0.1));
        last_ms = now;
        pet.update(dt, input);

        if (pet.takeSound()) |snd| {
            const clip = switch (snd) {
                .poke => character.sound_poke,
                .happy => character.sound_happy,
                .angry => character.sound_angry,
            };
            if (clip) |name| audio.play(name);
        }

        const frame = pet.frame();
        const transform = pet.transform();
        if (frame != last_frame or transform != last_transform) {
            render(win.pixels, frame, transform, win.argb);
            if (win.argb) applyInputShape(&win);
            last_frame = frame;
            last_transform = transform;
            win.present();
        }
        win.move(@intFromFloat(pet.x), @intFromFloat(pet.y));

        if (pet.bubble()) |text| {
            if (!bubble_shown or !std.mem.eql(u8, text, bubble_text[0..bubble_len])) {
                @memcpy(bubble_text[0..text.len], text);
                bubble_len = text.len;
                bubble_layout = font.Layout.forChars(text.len, text_scale);
                @memset(bubble_win.pixels[0 .. bubble_win.w * bubble_win.h], if (bubble_win.argb) 0 else 0xFF1E1E1E);
                font.drawBubble(bubble_win.pixels, bubble_win.w, bubble_layout, text);
                bubble_win.present();
                if (!bubble_shown) bubble_win.show();
                bubble_shown = true;
            }
            // Centre the painted part over the cat; below it when it hangs from the top.
            const bw: i32 = @intCast(bubble_layout.w);
            const bh: i32 = @intCast(bubble_layout.h);
            const cat_x: i32 = @intFromFloat(pet.x);
            const cat_y: i32 = @intFromFloat(pet.y);
            const half: i32 = @intCast(size / 2);
            const bx = std.math.clamp(cat_x + half - @divTrunc(bw, 2), 0, win.screen_w - bw);
            const above = cat_y - bh - 2;
            const by = if (above >= 0) above else cat_y + @as(i32, @intCast(size)) + 2;
            bubble_win.move(bx, by);
            if (debug_events and !bubble_logged) {
                std.debug.print("pet: bubble '{s}' {d}x{d} at {d},{d}\n", .{ text, bw, bh, bx, by });
                bubble_logged = true;
            }
        } else if (bubble_shown) {
            bubble_win.hide();
            bubble_shown = false;
            bubble_logged = false;
        }

        raise_timer += dt;
        if (raise_timer > 1.0) {
            win.raise();
            if (bubble_shown) bubble_win.raise();
            raise_timer = 0;
        }
        win.flush();
        // The bubble has its own X connection, so it needs its own flush.
        bubble_win.flush();
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
        } else if (std.mem.eql(u8, arg, "--top")) {
            const value = it.next() orelse fail("--top needs a number");
            top = std.fmt.parseInt(u32, value, 10) catch fail("--top needs a number");
        } else if (std.mem.eql(u8, arg, "--mute")) {
            mute = true;
        } else if (std.mem.eql(u8, arg, "--pet")) {
            const value = it.next() orelse fail("--pet needs cat, dog or rabbit");
            character = sprites.byName(value) orelse fail("--pet needs cat, dog or rabbit");
        } else if (std.mem.eql(u8, arg, "--name")) {
            const value = it.next() orelse fail("--name needs a name");
            if (value.len == 0 or value.len > 32) fail("--name must be 1..32 characters");
            for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') fail("--name may only use letters, digits, - and _");
            instance = value;
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

/// Expand the 16x16 frame into the window buffer with the requested orientation.
fn render(dst: [*]u32, frame: *const sprites.Frame, transform: petmod.Transform, argb: bool) void {
    const bg: u32 = if (argb) 0 else 0xFF1E1E1E;
    for (0..size) |y| {
        for (0..size) |x| {
            const dx: i32 = @intCast(x / scale);
            const dy: i32 = @intCast(y / scale);
            const src = sprites.source(transform, dx, dy);
            const sx: i32 = src.x;
            var sy: i32 = src.y;
            sy += frame.dy;
            var px: u32 = 0;
            if (sy >= 0 and sy < sprites.H) px = frame.px[@intCast(sy)][@intCast(sx)];
            dst[y * size + x] = if (px >> 24 == 0) bg else px;
        }
    }
}

/// Plays the cat's sounds through whatever command-line player is installed.
/// The clips are embedded in the binary and written to the runtime dir once.
const Audio = struct {
    enabled: bool,
    dir: [256:0]u8 = undefined,
    dir_len: usize = 0,
    player: []const u8 = "",

    const clips = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "meow", .data = @embedFile("assets/meow.wav") },
        .{ .name = "purr", .data = @embedFile("assets/purr.wav") },
        .{ .name = "hiss", .data = @embedFile("assets/hiss.wav") },
        .{ .name = "woof", .data = @embedFile("assets/woof.wav") },
        .{ .name = "pant", .data = @embedFile("assets/pant.wav") },
        .{ .name = "growl", .data = @embedFile("assets/growl.wav") },
        .{ .name = "squeak", .data = @embedFile("assets/squeak.wav") },
        .{ .name = "thump", .data = @embedFile("assets/thump.wav") },
    };
    /// Tried in order; the first one found on PATH wins.
    const players = [_][]const u8{ "pw-play", "paplay", "aplay", "ffplay -nodisp -autoexit -loglevel quiet" };

    fn init(enabled: bool) Audio {
        var a: Audio = .{ .enabled = enabled };
        if (!enabled) return a;

        a.player = for (players) |p| {
            var probe: [128:0]u8 = undefined;
            const exe = std.mem.sliceTo(p, ' ');
            const cmd = std.mem.printSentinel(&probe, "command -v {s} >/dev/null 2>&1", .{exe}, 0) catch continue;
            if (c.system(cmd.ptr) == 0) break p;
        } else {
            std.debug.print("pet: no audio player found (tried pw-play, paplay, aplay, ffplay); running silent\n", .{});
            a.enabled = false;
            return a;
        };

        const base: []const u8 = if (c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
        const dir = std.mem.printSentinel(&a.dir, "{s}/pet-sounds", .{base}, 0) catch {
            a.enabled = false;
            return a;
        };
        a.dir_len = dir.len;
        _ = c.mkdir(dir.ptr, 0o700);
        for (clips) |clip| {
            var path: [300:0]u8 = undefined;
            const p = std.mem.printSentinel(&path, "{s}/{s}.wav", .{ dir, clip.name }, 0) catch continue;
            const f = c.fopen(p.ptr, "wb") orelse continue;
            _ = c.fwrite(clip.data.ptr, 1, clip.data.len, f);
            _ = c.fclose(f);
        }
        return a;
    }

    fn play(self: *const Audio, clip: []const u8) void {
        if (!self.enabled) return;
        var cmd: [512:0]u8 = undefined;
        const line = std.mem.printSentinel(&cmd, "{s} '{s}/{s}.wav' >/dev/null 2>&1 &", .{ self.player, self.dir[0..self.dir_len], clip }, 0) catch return;
        _ = c.system(line.ptr);
    }
};

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
