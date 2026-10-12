//! X11 backend: a transparent override-redirect window the size of the
//! sprite, an XImage to blit into it, and an XFixes input shape so clicks
//! outside the pet's pixels fall through to whatever is underneath. This is
//! also what runs under XWayland on GNOME and KDE.

const std = @import("std");
const c = @import("c");
const backend = @import("../backend.zig");

pub const name = "x11";

const Error = backend.Error;
const PointerPos = backend.PointerPos;
const Rect = backend.Rect;
const Event = backend.Event;

comptime {
    // setInputShape passes a []Rect straight to XFixes, so the layouts must agree.
    std.debug.assert(@sizeOf(Rect) == @sizeOf(c.XRectangle));
    std.debug.assert(@offsetOf(Rect, "x") == @offsetOf(c.XRectangle, "x"));
    std.debug.assert(@offsetOf(Rect, "y") == @offsetOf(c.XRectangle, "y"));
    std.debug.assert(@offsetOf(Rect, "w") == @offsetOf(c.XRectangle, "width"));
    std.debug.assert(@offsetOf(Rect, "h") == @offsetOf(c.XRectangle, "height"));
}

/// Sleep until an X connection or the extra descriptor has data, or the
/// timeout passes. Each Window has its own connection, so each gets a slot.
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
    dpy: *c.Display,
    screen: c_int,
    root: c.Window,
    win: c.Window,
    gc: c.GC,
    img: [*c]c.XImage,
    /// Backing store of `img`, w*h ARGB pixels.
    pixels: [*]u32,
    w: u32,
    h: u32,
    /// True when a 32-bit visual was found, so alpha 0 really is see-through.
    argb: bool,
    screen_w: i32,
    screen_h: i32,

    pub fn init(w: u32, h: u32) Error!Window {
        const dpy = c.XOpenDisplay(null) orelse return error.NoDisplay;
        const screen = c.XDefaultScreen(dpy);
        const root = c.XRootWindow(dpy, screen);

        var vinfo: c.XVisualInfo = undefined;
        const argb = c.XMatchVisualInfo(dpy, screen, 32, c.TrueColor, &vinfo) != 0;
        if (!argb) {
            _ = c.XMatchVisualInfo(dpy, screen, c.XDefaultDepth(dpy, screen), c.TrueColor, &vinfo);
        }

        const cmap = c.XCreateColormap(dpy, root, vinfo.visual, c.AllocNone);
        var attrs: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
        attrs.colormap = cmap;
        attrs.border_pixel = 0;
        attrs.background_pixel = 0;
        attrs.override_redirect = 1;
        attrs.event_mask = c.ButtonPressMask | c.ButtonReleaseMask | c.ButtonMotionMask | c.ExposureMask;
        const mask: c_ulong = @intCast(c.CWColormap | c.CWBorderPixel | c.CWBackPixel | c.CWOverrideRedirect | c.CWEventMask);

        const win = c.XCreateWindow(dpy, root, 0, 0, w, h, 0, vinfo.depth, c.InputOutput, vinfo.visual, mask, &attrs);
        _ = c.XStoreName(dpy, win, "pet");

        const bytes: usize = @as(usize, w) * h * 4;
        const data = c.malloc(bytes) orelse return error.OutOfMemory;
        const img = c.XCreateImage(dpy, vinfo.visual, @intCast(vinfo.depth), c.ZPixmap, 0, @ptrCast(data), w, h, 32, @intCast(w * 4));
        if (img == null) return error.NoImage;
        img.*.byte_order = c.LSBFirst;

        const gc = c.XCreateGC(dpy, win, 0, null);

        return .{
            .dpy = dpy,
            .screen = screen,
            .root = root,
            .win = win,
            .gc = gc,
            .img = img,
            .pixels = @ptrCast(@alignCast(data)),
            .w = w,
            .h = h,
            .argb = argb,
            .screen_w = c.XDisplayWidth(dpy, screen),
            .screen_h = c.XDisplayHeight(dpy, screen),
        };
    }

    pub fn deinit(self: *Window) void {
        // XDestroyImage is a macro; call the destroy hook, which also frees the pixel data.
        if (self.img.*.f.destroy_image) |destroy| _ = destroy(self.img);
        _ = c.XFreeGC(self.dpy, self.gc);
        _ = c.XDestroyWindow(self.dpy, self.win);
        _ = c.XCloseDisplay(self.dpy);
    }

    /// The connection's descriptor, for `wait`.
    pub fn fd(self: *const Window) c_int {
        return c.XConnectionNumber(self.dpy);
    }

    pub fn show(self: *Window) void {
        _ = c.XMapRaised(self.dpy, self.win);
    }

    pub fn hide(self: *Window) void {
        _ = c.XUnmapWindow(self.dpy, self.win);
    }

    pub fn move(self: *Window, x: i32, y: i32) void {
        _ = c.XMoveWindow(self.dpy, self.win, x, y);
    }

    pub fn raise(self: *Window) void {
        _ = c.XRaiseWindow(self.dpy, self.win);
    }

    /// Blit the whole pixel buffer to the window.
    pub fn present(self: *Window) void {
        _ = c.XPutImage(self.dpy, self.win, self.gc, self.img, 0, 0, 0, 0, self.w, self.h);
    }

    pub fn flush(self: *Window) void {
        _ = c.XFlush(self.dpy);
    }

    /// Only these rectangles receive mouse input; everything else clicks
    /// through. An empty slice makes the whole window click-through.
    pub fn setInputShape(self: *Window, rects: []const Rect) void {
        var none: [1]c.XRectangle = undefined;
        const ptr: [*c]c.XRectangle = if (rects.len == 0) &none else @ptrCast(@constCast(rects.ptr));
        const region = c.XFixesCreateRegion(self.dpy, ptr, @intCast(rects.len));
        c.XFixesSetWindowShapeRegion(self.dpy, self.win, c.ShapeInput, 0, 0, region);
        c.XFixesDestroyRegion(self.dpy, region);
    }

    pub fn queryPointer(self: *Window) PointerPos {
        var root_ret: c.Window = 0;
        var child: c.Window = 0;
        var rx: c_int = 0;
        var ry: c_int = 0;
        var wx: c_int = 0;
        var wy: c_int = 0;
        var mask: c_uint = 0;
        _ = c.XQueryPointer(self.dpy, self.root, &root_ret, &child, &rx, &ry, &wx, &wy, &mask);
        return .{ .x = rx, .y = ry };
    }

    /// Drain one event we care about; null when the queue holds nothing useful.
    pub fn pollEvent(self: *Window) ?Event {
        while (c.XPending(self.dpy) > 0) {
            var ev: c.XEvent = undefined;
            _ = c.XNextEvent(self.dpy, &ev);
            switch (ev.type) {
                c.ButtonPress => return .{ .press = .{
                    .button = ev.xbutton.button,
                    .x_root = ev.xbutton.x_root,
                    .y_root = ev.xbutton.y_root,
                    .x = ev.xbutton.x,
                    .y = ev.xbutton.y,
                } },
                c.ButtonRelease => return .{ .release = .{
                    .button = ev.xbutton.button,
                    .x_root = ev.xbutton.x_root,
                    .y_root = ev.xbutton.y_root,
                } },
                c.MotionNotify => return .{ .motion = .{
                    .x_root = ev.xmotion.x_root,
                    .y_root = ev.xmotion.y_root,
                } },
                c.Expose => return .expose,
                else => {},
            }
        }
        return null;
    }
};
