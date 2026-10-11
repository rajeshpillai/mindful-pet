//! A 3x5 uppercase bitmap font and the speech-bubble painter.

const std = @import("std");

pub const glyph_w = 3;
pub const glyph_h = 5;

const Glyph = [glyph_h][glyph_w]bool;

fn g(comptime rows: [glyph_h]*const [glyph_w:0]u8) Glyph {
    var out: Glyph = undefined;
    for (rows, 0..) |row, y| for (row, 0..) |ch, x| {
        out[y][x] = ch == '#';
    };
    return out;
}

const unknown = g(.{ "###", "#.#", "#.#", "#.#", "###" });

fn glyph(ch: u8) Glyph {
    return switch (std.ascii.toUpper(ch)) {
        ' ' => g(.{ "...", "...", "...", "...", "..." }),
        'A' => g(.{ ".#.", "#.#", "###", "#.#", "#.#" }),
        'B' => g(.{ "##.", "#.#", "##.", "#.#", "##." }),
        'C' => g(.{ ".##", "#..", "#..", "#..", ".##" }),
        'D' => g(.{ "##.", "#.#", "#.#", "#.#", "##." }),
        'E' => g(.{ "###", "#..", "##.", "#..", "###" }),
        'F' => g(.{ "###", "#..", "##.", "#..", "#.." }),
        'G' => g(.{ ".##", "#..", "#.#", "#.#", ".##" }),
        'H' => g(.{ "#.#", "#.#", "###", "#.#", "#.#" }),
        'I' => g(.{ "###", ".#.", ".#.", ".#.", "###" }),
        'J' => g(.{ "..#", "..#", "..#", "#.#", ".#." }),
        'K' => g(.{ "#.#", "#.#", "##.", "#.#", "#.#" }),
        'L' => g(.{ "#..", "#..", "#..", "#..", "###" }),
        'M' => g(.{ "#.#", "###", "###", "#.#", "#.#" }),
        'N' => g(.{ "#.#", "###", "###", "###", "#.#" }),
        'O' => g(.{ ".#.", "#.#", "#.#", "#.#", ".#." }),
        'P' => g(.{ "##.", "#.#", "##.", "#..", "#.." }),
        'Q' => g(.{ ".#.", "#.#", "#.#", ".#.", "..#" }),
        'R' => g(.{ "##.", "#.#", "##.", "#.#", "#.#" }),
        'S' => g(.{ ".##", "#..", ".#.", "..#", "##." }),
        'T' => g(.{ "###", ".#.", ".#.", ".#.", ".#." }),
        'U' => g(.{ "#.#", "#.#", "#.#", "#.#", "###" }),
        'V' => g(.{ "#.#", "#.#", "#.#", "#.#", ".#." }),
        'W' => g(.{ "#.#", "#.#", "###", "###", "#.#" }),
        'X' => g(.{ "#.#", "#.#", ".#.", "#.#", "#.#" }),
        'Y' => g(.{ "#.#", "#.#", ".#.", ".#.", ".#." }),
        'Z' => g(.{ "###", "..#", ".#.", "#..", "###" }),
        '0' => g(.{ "###", "#.#", "#.#", "#.#", "###" }),
        '1' => g(.{ ".#.", "##.", ".#.", ".#.", "###" }),
        '2' => g(.{ "##.", "..#", ".#.", "#..", "###" }),
        '3' => g(.{ "###", "..#", ".##", "..#", "###" }),
        '4' => g(.{ "#.#", "#.#", "###", "..#", "..#" }),
        '5' => g(.{ "###", "#..", "##.", "..#", "##." }),
        '6' => g(.{ ".##", "#..", "###", "#.#", "###" }),
        '7' => g(.{ "###", "..#", ".#.", ".#.", ".#." }),
        '8' => g(.{ "###", "#.#", "###", "#.#", "###" }),
        '9' => g(.{ "###", "#.#", "###", "..#", "##." }),
        '.' => g(.{ "...", "...", "...", "...", ".#." }),
        ',' => g(.{ "...", "...", "...", ".#.", "#.." }),
        '!' => g(.{ ".#.", ".#.", ".#.", "...", ".#." }),
        '?' => g(.{ "##.", "..#", ".#.", "...", ".#." }),
        ':' => g(.{ "...", ".#.", "...", ".#.", "..." }),
        ';' => g(.{ "...", ".#.", "...", ".#.", "#.." }),
        '-' => g(.{ "...", "...", "###", "...", "..." }),
        '_' => g(.{ "...", "...", "...", "...", "###" }),
        '\'' => g(.{ ".#.", ".#.", "...", "...", "..." }),
        '"' => g(.{ "#.#", "#.#", "...", "...", "..." }),
        '(' => g(.{ ".#.", "#..", "#..", "#..", ".#." }),
        ')' => g(.{ ".#.", "..#", "..#", "..#", ".#." }),
        '[' => g(.{ "##.", "#..", "#..", "#..", "##." }),
        ']' => g(.{ ".##", "..#", "..#", "..#", ".##" }),
        '/' => g(.{ "..#", "..#", ".#.", "#..", "#.." }),
        '\\' => g(.{ "#..", "#..", ".#.", "..#", "..#" }),
        '+' => g(.{ "...", ".#.", "###", ".#.", "..." }),
        '=' => g(.{ "...", "###", "...", "###", "..." }),
        '<' => g(.{ "..#", ".#.", "#..", ".#.", "..#" }),
        '>' => g(.{ "#..", ".#.", "..#", ".#.", "#.." }),
        '*' => g(.{ "#.#", ".#.", "###", ".#.", "#.#" }),
        '#' => g(.{ "#.#", "###", "#.#", "###", "#.#" }),
        '%' => g(.{ "#.#", "..#", ".#.", "#..", "#.#" }),
        '@' => g(.{ ".##", "#.#", "###", "#..", ".##" }),
        '&' => g(.{ ".#.", "#.#", ".#.", "#.#", ".##" }),
        '$' => g(.{ ".##", "##.", ".#.", ".##", "##." }),
        '~' => g(.{ "...", ".##", "##.", "...", "..." }),
        '|' => g(.{ ".#.", ".#.", ".#.", ".#.", ".#." }),
        else => unknown,
    };
}

pub const ink: u32 = 0xFF2B2118;
pub const paper: u32 = 0xFFFFFFFF;

/// Geometry of a bubble for `n` characters at text scale `ts`.
pub const Layout = struct {
    w: u32,
    h: u32,
    /// Height of the little tail below the box, included in `h`.
    tail: u32,
    pad: u32,
    ts: u32,

    pub fn forChars(n: usize, ts: u32) Layout {
        const pad = 3 * ts;
        const cell = (glyph_w + 1) * ts;
        const text_w = if (n == 0) cell else @as(u32, @intCast(n)) * cell - ts;
        const tail = 3 * ts;
        return .{
            .w = 2 * pad + text_w,
            .h = 2 * pad + glyph_h * ts + tail,
            .tail = tail,
            .pad = pad,
            .ts = ts,
        };
    }
};

/// Paint a bubble with `text` into the top-left of `dst` (stride `stride`,
/// at least `layout.w` x `layout.h`). Pixels outside the bubble are left
/// untouched, so clear the buffer first.
pub fn drawBubble(dst: [*]u32, stride: usize, layout: Layout, text: []const u8) void {
    const ts = layout.ts;
    const box_h = layout.h - layout.tail;
    const w = layout.w;

    // Box with clipped corners.
    for (0..box_h) |y| for (0..w) |x| {
        const corner = (x < ts or x >= w - ts) and (y < ts or y >= box_h - ts);
        if (corner) continue;
        const edge = x < ts or x >= w - ts or y < ts or y >= box_h - ts;
        dst[y * stride + x] = if (edge) ink else paper;
    };

    // Tail: a small downward wedge under the middle.
    const cx = w / 2;
    for (0..layout.tail) |i| {
        const half = (layout.tail - i) * 1; // narrows by one pixel per row
        const y = box_h + i;
        const x0 = cx - half;
        const x1 = cx + half;
        for (x0..x1 + 1) |x| {
            const edge = x == x0 or x == x1 or i == layout.tail - 1;
            dst[y * stride + x] = if (edge) ink else paper;
        }
        // Open the box's bottom border above the tail so it reads as one shape.
        if (i == 0) for (x0 + 1..x1) |x| {
            dst[(box_h - ts) * stride + x] = paper;
        };
    }

    // Text.
    var pen_x = layout.pad;
    const pen_y = layout.pad;
    for (text) |ch| {
        const gl = glyph(ch);
        for (0..glyph_h) |gy| for (0..glyph_w) |gx| {
            if (!gl[gy][gx]) continue;
            for (0..ts) |sy| for (0..ts) |sx| {
                dst[(pen_y + gy * ts + sy) * stride + pen_x + gx * ts + sx] = ink;
            };
        };
        pen_x += (glyph_w + 1) * ts;
    }
}

test "every printable ASCII character has a glyph or the fallback" {
    var ch: u8 = 32;
    while (ch < 127) : (ch += 1) _ = glyph(ch);
}

test "bubble fits its layout and places ink" {
    const layout = Layout.forChars(5, 2);
    var buf: [200 * 40]u32 = @splat(0);
    drawBubble(&buf, 200, layout, "HELLO");
    var ink_count: usize = 0;
    for (0..layout.h) |y| for (0..layout.w) |x| {
        if (buf[y * 200 + x] == ink) ink_count += 1;
    };
    try std.testing.expect(ink_count > 50);
    // Nothing painted outside the layout box.
    for (0..40) |y| for (layout.w..200) |x| try std.testing.expectEqual(@as(u32, 0), buf[y * 200 + x]);
}
