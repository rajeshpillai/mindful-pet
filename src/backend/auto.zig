//! Auto backend: use the GNOME Shell extension when it is running, X11
//! otherwise. The first Window decides for the whole process, so the pet and
//! its speech bubble always share one backend. This is the default build, so
//! a single `pet` binary works on an X11 desktop, under XWayland, and with the
//! extension, and the hooks never need to know which.

const std = @import("std");
const c = @import("c");
const backend = @import("../backend.zig");
const gnome = @import("gnome.zig");
const x11 = @import("x11.zig");

pub const name = "auto";

const Error = backend.Error;
const PointerPos = backend.PointerPos;
const Rect = backend.Rect;
const Event = backend.Event;

const Kind = enum { gnome, x11 };
var chosen: ?Kind = null;

pub fn wait(windows: []const *const Window, extra_fd: ?c_int, timeout_ms: i32) void {
    var fds: [8]c.pollfd = undefined;
    var n: usize = 0;
    for (windows) |w| {
        if (n == fds.len) break;
        fds[n] = .{ .fd = w.fd(), .events = c.POLLIN, .revents = 0 };
        n += 1;
    }
    if (extra_fd) |fd| if (n < fds.len) {
        fds[n] = .{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        n += 1;
    };
    _ = c.poll(&fds, @intCast(n), timeout_ms);
}

pub const Window = struct {
    impl: union(Kind) {
        gnome: gnome.Window,
        x11: x11.Window,
    },
    pixels: [*]u32,
    w: u32,
    h: u32,
    argb: bool,
    screen_w: i32,
    screen_h: i32,

    pub fn init(w: u32, h: u32) Error!Window {
        const kind = chosen orelse blk: {
            const k: Kind = if (gnome.available()) .gnome else .x11;
            chosen = k;
            break :blk k;
        };
        var win: Window = undefined;
        switch (kind) {
            .gnome => win.impl = .{ .gnome = try gnome.Window.init(w, h) },
            .x11 => win.impl = .{ .x11 = try x11.Window.init(w, h) },
        }
        // Mirror the fields main.zig reads; they never change after init.
        switch (win.impl) {
            inline else => |*inner| {
                win.pixels = inner.pixels;
                win.w = inner.w;
                win.h = inner.h;
                win.argb = inner.argb;
                win.screen_w = inner.screen_w;
                win.screen_h = inner.screen_h;
            },
        }
        return win;
    }

    pub fn backendName(self: *const Window) []const u8 {
        return switch (self.impl) {
            inline else => |*inner| inner.backendName(),
        };
    }

    pub fn fd(self: *const Window) c_int {
        return switch (self.impl) {
            inline else => |*inner| inner.fd(),
        };
    }

    pub fn deinit(self: *Window) void {
        switch (self.impl) {
            inline else => |*inner| inner.deinit(),
        }
    }

    pub fn show(self: *Window) void {
        switch (self.impl) {
            inline else => |*inner| inner.show(),
        }
    }

    pub fn hide(self: *Window) void {
        switch (self.impl) {
            inline else => |*inner| inner.hide(),
        }
    }

    pub fn move(self: *Window, x: i32, y: i32) void {
        switch (self.impl) {
            inline else => |*inner| inner.move(x, y),
        }
    }

    pub fn raise(self: *Window) void {
        switch (self.impl) {
            inline else => |*inner| inner.raise(),
        }
    }

    pub fn present(self: *Window) void {
        switch (self.impl) {
            inline else => |*inner| inner.present(),
        }
    }

    pub fn flush(self: *Window) void {
        switch (self.impl) {
            inline else => |*inner| inner.flush(),
        }
    }

    pub fn setInputShape(self: *Window, rects: []const Rect) void {
        switch (self.impl) {
            inline else => |*inner| inner.setInputShape(rects),
        }
    }

    pub fn queryPointer(self: *Window) PointerPos {
        return switch (self.impl) {
            inline else => |*inner| inner.queryPointer(),
        };
    }

    pub fn pollEvent(self: *Window) ?Event {
        return switch (self.impl) {
            inline else => |*inner| inner.pollEvent(),
        };
    }
};
