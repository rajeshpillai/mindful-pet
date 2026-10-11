//! Dev tool: writes every sprite frame, scaled 4x on a checkerboard, to a
//! binary PPM so the art can be reviewed with any image viewer.
//! Usage: sheet OUT.ppm

const std = @import("std");
const c = @import("c");
const sprites = @import("sprites");

const scale = 4;
const cell = sprites.W * scale;
const gap = 4;

const Row = struct { name: []const u8, frames: []const sprites.Frame };
const rows = [_]Row{
    .{ .name = "idle", .frames = &sprites.idle },
    .{ .name = "walk", .frames = &sprites.walk },
    .{ .name = "sit", .frames = &sprites.sit },
    .{ .name = "sleep", .frames = &sprites.sleep },
    .{ .name = "alert", .frames = &sprites.alert },
    .{ .name = "happy", .frames = &sprites.happy },
    .{ .name = "angry", .frames = &sprites.angry },
    .{ .name = "work", .frames = &sprites.work },
    .{ .name = "bat", .frames = &sprites.bat },
    .{ .name = "held", .frames = &sprites.held },
};

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.skip();
    const out_path = it.next() orelse "sheet.ppm";

    const transforms = [_]sprites.Transform{ .none, .flip_h, .flip_v, .rot180, .wall_left, .wall_right };
    var max_frames: usize = transforms.len;
    for (rows) |r| max_frames = @max(max_frames, r.frames.len);
    const width = max_frames * (cell + gap) + gap;
    const height = (rows.len + 1) * (cell + gap) + gap;

    const buf = try init.gpa.alloc(u8, width * height * 3);
    defer init.gpa.free(buf);

    // Checkerboard background makes transparency visible.
    for (0..height) |y| for (0..width) |x| {
        const light = ((x / 8) + (y / 8)) % 2 == 0;
        const v: u8 = if (light) 0x9a else 0x7a;
        const i = (y * width + x) * 3;
        buf[i] = v;
        buf[i + 1] = v;
        buf[i + 2] = v;
    };

    for (rows, 0..) |r, ri| for (r.frames, 0..) |frame, fi| {
        const ox = gap + fi * (cell + gap);
        const oy = gap + ri * (cell + gap);
        for (0..cell) |y| for (0..cell) |x| {
            const px = frame.px[y / scale][x / scale];
            if (px >> 24 == 0) continue;
            const i = ((oy + y) * width + (ox + x)) * 3;
            buf[i] = @truncate(px >> 16);
            buf[i + 1] = @truncate(px >> 8);
            buf[i + 2] = @truncate(px);
        };
    };

    // Last row: the standing frame in every orientation the renderer supports.
    for (transforms, 0..) |t, ti| {
        const ox = gap + ti * (cell + gap);
        const oy = gap + rows.len * (cell + gap);
        for (0..cell) |y| for (0..cell) |x| {
            const src = sprites.source(t, @intCast(x / scale), @intCast(y / scale));
            const px = sprites.idle[0].px[@intCast(src.y)][@intCast(src.x)];
            if (px >> 24 == 0) continue;
            const i = ((oy + y) * width + (ox + x)) * 3;
            buf[i] = @truncate(px >> 16);
            buf[i + 1] = @truncate(px >> 8);
            buf[i + 2] = @truncate(px);
        };
    }

    var path_buf: [1024:0]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "{s}", .{out_path}, 0);
    const f = c.fopen(path.ptr, "wb") orelse return error.CannotOpenOutput;
    defer _ = c.fclose(f);
    var header: [64]u8 = undefined;
    const h = try std.mem.print(&header, "P6\n{d} {d}\n255\n", .{ width, height });
    _ = c.fwrite(h.ptr, 1, h.len, f);
    _ = c.fwrite(buf.ptr, 1, buf.len, f);
    std.debug.print("sheet: wrote {s} ({d}x{d})\n", .{ out_path, width, height });
}
