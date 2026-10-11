//! Pixel-art frames for the cat, authored as ASCII and expanded at comptime.
//! Every frame is 16x16 and drawn facing RIGHT; the renderer mirrors it.
//!
//! Palette:  .  transparent   k  outline   o  orange   d  stripe
//!           w  white         p  pink      e  eye      z  "Z"
//!           !  alarm red     h  heart

pub const W = 16;
pub const H = 16;

/// ARGB, non-premultiplied is fine because alpha is always 0 or 255.
pub const Pixel = u32;
pub const Frame = struct {
    px: [H][W]Pixel,
    /// Vertical nudge in source pixels, used for the walk bob.
    dy: i8 = 0,
};

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
        else => @compileError("unknown palette character"),
    };
}

fn parse(comptime rows: [H][]const u8, comptime dy: i8) Frame {
    @setEvalBranchQuota(20_000);
    var f: Frame = .{ .px = undefined, .dy = dy };
    for (rows, 0..) |row, y| {
        if (row.len != W) @compileError("sprite row must be exactly 16 chars");
        for (row, 0..) |ch, x| f.px[y][x] = color(ch);
    }
    return f;
}

// --- standing / idle -------------------------------------------------------

pub const idle = [_]Frame{
    parse(.{
        "................",
        "..........k..k..",
        "..........kokok.",
        "..........kooook",
        "..k.......koeook",
        "..ko......kooook",
        "..ko...kkkkoopk.",
        "...kk.koooooook.",
        "....kkooodooook.",
        "....kooodooook..",
        "....kooooooook..",
        "....kkkkkkkkkk..",
        ".....ko.....ko..",
        ".....ko.....ko..",
        ".....kk.....kk..",
        "................",
    }, 0),
    parse(.{
        "................",
        "..........k..k..",
        "..........kokok.",
        "..k.......kooook",
        "..ko......koeook",
        "..ko......kooook",
        "...ko..kkkkoopk.",
        "....kkkoooooook.",
        "....kkooodooook.",
        "....kooodooook..",
        "....kooooooook..",
        "....kkkkkkkkkk..",
        ".....ko.....ko..",
        ".....ko.....ko..",
        ".....kk.....kk..",
        "................",
    }, 0),
};

// --- walking (4 frames, legs scissor, slight bob) --------------------------

pub const walk = [_]Frame{
    parse(.{
        "................",
        "..........k..k..",
        "..........kokok.",
        "..........kooook",
        "..k.......koeook",
        "..ko......kooook",
        "..ko...kkkkoopk.",
        "...kk.koooooook.",
        "....kkooodooook.",
        "....kooodooook..",
        "....kooooooook..",
        "....kkkkkkkkkk..",
        ".....ko.....ko..",
        ".....ko.....ko..",
        ".....kk.....kk..",
        "................",
    }, 0),
    parse(.{
        "................",
        "..........k..k..",
        "..........kokok.",
        "..k.......kooook",
        "..ko......koeook",
        "..ko......kooook",
        "...ko..kkkkoopk.",
        "....kkkoooooook.",
        "....kkooodooook.",
        "....kooodooook..",
        "....kooooooook..",
        "....kkkkkkkkkk..",
        "....ko.k...ko.k.",
        "....ko..k..ko..k",
        "....kk..k..kk..k",
        "................",
    }, 1),
    parse(.{
        "................",
        "..........k..k..",
        "..........kokok.",
        "..........kooook",
        "..k.......koeook",
        "..ko......kooook",
        "..ko...kkkkoopk.",
        "...kk.koooooook.",
        "....kkooodooook.",
        "....kooodooook..",
        "....kooooooook..",
        "....kkkkkkkkkk..",
        "......ko.....ko.",
        "......ko.....ko.",
        "......kk.....kk.",
        "................",
    }, 0),
    parse(.{
        "................",
        "..........k..k..",
        "..........kokok.",
        "..k.......kooook",
        "..ko......koeook",
        "..ko......kooook",
        "...ko..kkkkoopk.",
        "....kkkoooooook.",
        "....kkooodooook.",
        "....kooodooook..",
        "....kooooooook..",
        "....kkkkkkkkkk..",
        "...k..ko..k..ko.",
        "....k.ko...k.ko.",
        "....k.kk...k.kk.",
        "................",
    }, 1),
};

// --- sitting (second frame blinks) ----------------------------------------

pub const sit = [_]Frame{
    parse(.{
        "................",
        "..........k..k..",
        "..........kokok.",
        "..........kooook",
        "..........koeook",
        "..........kooook",
        "........kkkoopk.",
        ".......kooooook.",
        "......koodoook..",
        "..k..kooodoook..",
        "..k.kooooooook..",
        "..kokooooooooook",
        "...kkoooooooook.",
        "....kooookkoook.",
        "....kkkkkkkkkkk.",
        "................",
    }, 0),
    parse(.{
        "................",
        "..........k..k..",
        "..........kokok.",
        "..........kooook",
        "..........kokook",
        "..........kooook",
        "........kkkoopk.",
        ".......kooooook.",
        "......koodoook..",
        "..k..kooodoook..",
        "..k.kooooooook..",
        "..kokooooooooook",
        "...kkoooooooook.",
        "....kooookkoook.",
        "....kkkkkkkkkkk.",
        "................",
    }, 0),
};

// --- sleeping loaf with drifting Z ----------------------------------------

pub const sleep = [_]Frame{
    parse(.{
        "................",
        "................",
        "................",
        "..............z.",
        ".............z..",
        "................",
        "................",
        "..........kk.kk.",
        "......kkkkkoook.",
        ".....koooooookok",
        "....kooodooooook",
        "...koooodoooook.",
        "...kkooooooooook",
        "....kkkkkkkkkkk.",
        "................",
        "................",
    }, 0),
    parse(.{
        "................",
        "...............z",
        "................",
        "............z...",
        "................",
        "................",
        "................",
        "..........kk.kk.",
        "......kkkkkoook.",
        ".....koooooookok",
        "....kooodooooook",
        "...koooodoooook.",
        "...kkooooooooook",
        "....kkkkkkkkkkk.",
        "................",
        "................",
    }, 0),
};

// --- reactions --------------------------------------------------------------

/// Startled: tail straight up, wide eye, exclamation mark.
pub const alert = [_]Frame{
    parse(.{
        "...............!",
        "..k.......k..k.!",
        "..k.......kokok!",
        "..k.......kooook",
        "..k.......kwkook",
        "..k.......kooook",
        "..k....kkkkoopk.",
        "...kk.koooooook.",
        "....kkooodooook.",
        "....kooodooook..",
        "....kooooooook..",
        "....kkkkkkkkkk..",
        ".....ko.....ko..",
        ".....ko.....ko..",
        ".....kk.....kk..",
        "................",
    }, 0),
};

/// Content: eyes closed, tail up, little heart.
pub const happy = [_]Frame{
    parse(.{
        ".............h.h",
        "..k.......k..khh",
        "..k.......kokokh",
        "..k.......kooook",
        "..k.......kokook",
        "..k.......kooook",
        "..k....kkkkoopk.",
        "...kk.koooooook.",
        "....kkooodooook.",
        "....kooodooook..",
        "....kooooooook..",
        "....kkkkkkkkkk..",
        ".....ko.....ko..",
        ".....ko.....ko..",
        ".....kk.....kk..",
        "................",
    }, 0),
    parse(.{
        "................",
        "..k.......k..k..",
        "..k.......kokok.",
        "..k.......kooook",
        "..k.......kokook",
        "..k.......kooook",
        "..k....kkkkoopk.",
        "...kk.koooooook.",
        "....kkooodooook.",
        "....kooodooook..",
        "....kooooooook..",
        "....kkkkkkkkkk..",
        ".....ko.....ko..",
        ".....ko.....ko..",
        ".....kk.....kk..",
        "................",
    }, 0),
};

/// Hissing: red eye, bared teeth, tail bristled.
pub const angry = [_]Frame{
    parse(.{
        "................",
        ".kk.......k..k..",
        ".kk.......kokok.",
        ".kk.......kooook",
        ".kk.......k!kook",
        "..k.......kooook",
        "..k....kkkkoowk.",
        "...kk.koooooook.",
        "....kkooodooook.",
        "....kooodooook..",
        "....kooooooook..",
        "....kkkkkkkkkk..",
        ".....ko.....ko..",
        ".....ko.....ko..",
        ".....kk.....kk..",
        "................",
    }, 0),
    parse(.{
        "................",
        ".kk.......k..k..",
        ".kk.......kokok.",
        ".kk.......kooook",
        ".kk.......k!kook",
        "..k.......kooook",
        "..k....kkkkoopk.",
        "...kk.koooooook.",
        "....kkooodooook.",
        "....kooodooook..",
        "....kooooooook..",
        "....kkkkkkkkkk..",
        ".....ko.....ko..",
        ".....ko.....ko..",
        ".....kk.....kk..",
        "................",
    }, 0),
};

/// Held by the scruff: legs dangling.
pub const held = [_]Frame{
    parse(.{
        "................",
        "..........k..k..",
        "..........kokok.",
        "..........kooook",
        "..........kwkook",
        "..........kooook",
        ".......kkkkoopk.",
        "......koooooook.",
        "......kooodoook.",
        "..k...koooooook.",
        "..k...kooooook..",
        "...k..kkkkkkkk..",
        "....k..ko...ko..",
        "....k..ko...ko..",
        ".....k.kk...kk..",
        "................",
    }, 0),
};
