//! Pixel-art frame format shared by every character, plus the orientation
//! mapping. The characters themselves live in src/characters/*.zig.
//! Every frame is 16x16 and drawn facing RIGHT; the renderer mirrors it.
//!
//! Palette:  .  transparent   k  outline   o  orange   d  stripe
//!           w  white         p  pink      e  eye      z  "Z"
//!           !  alarm red     h  heart     b  brown    c  tan
//!           g  grey

const std = @import("std");

pub const W = 16;
pub const H = 16;

/// ARGB, non-premultiplied is fine because alpha is always 0 or 255.
pub const Pixel = u32;
pub const Frame = struct {
    px: [H][W]Pixel,
    /// Vertical nudge in source pixels, used for the walk bob.
    dy: i8 = 0,
};

/// How a right-facing, upright frame is oriented on screen.
pub const Transform = enum { none, flip_h, flip_v, rot180, wall_left, wall_right };

/// For destination pixel (dx, dy) in 16x16 space, the source pixel to sample.
pub fn source(t: Transform, dx: i32, dy: i32) struct { x: i32, y: i32 } {
    const n: i32 = W - 1;
    return switch (t) {
        .none => .{ .x = dx, .y = dy },
        .flip_h => .{ .x = n - dx, .y = dy },
        .flip_v => .{ .x = dx, .y = n - dy },
        .rot180 => .{ .x = n - dx, .y = n - dy },
        // Head up, feet toward the wall on the right.
        .wall_right => .{ .x = n - dy, .y = dx },
        // Head up, feet toward the wall on the left.
        .wall_left => .{ .x = n - dy, .y = n - dx },
    };
}

fn color(ch: u8) Pixel {
    return switch (ch) {
        '.' => 0x00000000,
        'k' => 0xFF2B2118,
        'o' => 0xFFF2A33A,
        'd' => 0xFFC97A1E,
        'w' => 0xFFFFFFFF,
        'p' => 0xFFF28CA8,
        'e' => 0xFF3FBF6A,
        'z' => 0xFF5C7CFA,
        '!' => 0xFFE5484D,
        'h' => 0xFFE5484D,
        'b' => 0xFF9C6B3C,
        'c' => 0xFFE0B983,
        'g' => 0xFFC9C9D1,
        else => @compileError("unknown palette character"),
    };
}

pub fn parse(comptime rows: [H][]const u8, comptime dy: i8) Frame {
    @setEvalBranchQuota(20_000);
    var f: Frame = .{ .px = undefined, .dy = dy };
    for (rows, 0..) |row, y| {
        if (row.len != W) @compileError("sprite row must be exactly 16 chars");
        for (row, 0..) |ch, x| f.px[y][x] = color(ch);
    }
    return f;
}

/// One animal: every animation the state machine can ask for, plus which
/// embedded sound clip (by base name) to play for each reaction.
pub const Character = struct {
    name: []const u8,
    idle: []const Frame,
    walk: []const Frame,
    sit: []const Frame,
    sleep: []const Frame,
    alert: []const Frame,
    happy: []const Frame,
    angry: []const Frame,
    work: []const Frame,
    bat: []const Frame,
    held: []const Frame,
    sound_poke: ?[]const u8,
    sound_happy: ?[]const u8,
    sound_angry: ?[]const u8,
};

pub const cat = @import("characters/cat.zig").character;
pub const dog = @import("characters/dog.zig").character;
pub const rabbit = @import("characters/rabbit.zig").character;
pub const all = [_]*const Character{ &cat, &dog, &rabbit };

pub fn byName(name: []const u8) ?*const Character {
    for (all) |ch| if (std.mem.eql(u8, ch.name, name)) return ch;
    return null;
}

test "all characters have every animation" {
    for (all) |ch| {
        inline for (.{ "idle", "walk", "sit", "sleep", "alert", "happy", "angry", "work", "bat", "held" }) |anim| {
            try std.testing.expect(@field(ch, anim).len > 0);
        }
    }
    try std.testing.expectEqualStrings("dog", sprites_byName_dog().name);
}

fn sprites_byName_dog() *const Character {
    return byName("dog").?;
}
