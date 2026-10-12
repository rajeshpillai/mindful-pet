//! Monitor rectangles in desktop coordinates, independent of the compositor.
const std = @import("std");

pub const Monitor = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(self: Monitor, x: i32, y: i32) bool {
        return x >= self.x and y >= self.y and
            @as(i64, x) < @as(i64, self.x) + self.w and
            @as(i64, y) < @as(i64, self.y) + self.h;
    }
};

pub const Monitors = struct {
    items: [32]Monitor = undefined,
    len: usize = 0,

    pub fn add(self: *Monitors, m: Monitor) void {
        if (m.w <= 0 or m.h <= 0 or self.len == self.items.len) return;
        for (self.items[0..self.len]) |old| if (std.meta.eql(old, m)) return;
        self.items[self.len] = m;
        self.len += 1;
    }

    pub fn at(self: *const Monitors, x: i32, y: i32) ?Monitor {
        for (self.items[0..self.len]) |m| if (m.contains(x, y)) return m;
        return null; // The desktop bounding box includes gaps: never choose one.
    }
};

test "stacked, offset and negative-origin monitors exclude desktop gaps" {
    var ms: Monitors = .{};
    ms.add(.{ .x = 0, .y = 0, .w = 1920, .h = 1080 });
    ms.add(.{ .x = 710, .y = 1080, .w = 1366, .h = 768 });
    ms.add(.{ .x = -800, .y = 0, .w = 800, .h = 600 });
    try std.testing.expectEqual(@as(i32, 710), ms.at(1000, 1800).?.x);
    try std.testing.expectEqual(@as(i32, -800), ms.at(-1, 100).?.x);
    try std.testing.expect(ms.at(100, 1800) == null);
    try std.testing.expect(ms.at(2076, 1800) == null);
    try std.testing.expect(ms.at(-1, 600) == null);
}
