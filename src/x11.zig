//! Thin Xlib layer: a transparent override-redirect window the size of the
//! sprite, an XImage to blit into it, and an XFixes input shape so clicks
//! outside the cat's pixels fall through to whatever is underneath.

const std = @import("std");
const c = @import("c");

pub const Error = error{ NoDisplay, NoImage, OutOfMemory };

pub const PointerPos = struct { x: i32, y: i32 };

pub const Event = union(enum) {
    press: struct { button: u32, x_root: i32, y_root: i32, x: i32, y: i32 },
    release: struct { button: u32, x_root: i32, y_root: i32 },
    motion: struct { x_root: i32, y_root: i32 },
    expose,
};

pub const Window = struct {
    dpy: *c.Display,
    screen: c_int,
    root: c.Window,
    win: c.Window,
    gc: c.GC,
    img: [*c]c.XImage,
    /// Backing store of `img`, size*size ARGB pixels.
    pixels: [*]u32,
    size: u32,
    /// True when a 32-bit visual was found, so alpha 0 really is see-through.
    argb: bool,
    screen_w: i32,
    screen_h: i32,

    pub fn init(size: u32) Error!Window {
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

        const win = c.XCreateWindow(dpy, root, 0, 0, size, size, 0, vinfo.depth, c.InputOutput, vinfo.visual, mask, &attrs);
        _ = c.XStoreName(dpy, win, "pet");

        const bytes: usize = @as(usize, size) * size * 4;
        const data = c.malloc(bytes) orelse return error.OutOfMemory;
        const img = c.XCreateImage(dpy, vinfo.visual, @intCast(vinfo.depth), c.ZPixmap, 0, @ptrCast(data), size, size, 32, @intCast(size * 4));
        if (img == null) return error.NoImage;
        img.*.byte_order = c.LSBFirst;

        const gc = c.XCreateGC(dpy, win, 0, null);
        _ = c.XMapRaised(dpy, win);

        return .{
            .dpy = dpy,
            .screen = screen,
            .root = root,
            .win = win,
            .gc = gc,
            .img = img,
            .pixels = @ptrCast(@alignCast(data)),
            .size = size,
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

    pub fn fd(self: *const Window) c_int {
        return c.XConnectionNumber(self.dpy);
    }

    pub fn move(self: *const Window, x: i32, y: i32) void {
        _ = c.XMoveWindow(self.dpy, self.win, x, y);
    }

    pub fn raise(self: *const Window) void {
        _ = c.XRaiseWindow(self.dpy, self.win);
    }

    /// Blit the whole pixel buffer to the window.
    pub fn present(self: *const Window) void {
        _ = c.XPutImage(self.dpy, self.win, self.gc, self.img, 0, 0, 0, 0, self.size, self.size);
    }

    pub fn flush(self: *const Window) void {
        _ = c.XFlush(self.dpy);
    }

    /// Only these rectangles receive mouse input; everything else clicks through.
    pub fn setInputShape(self: *const Window, rects: []const c.XRectangle) void {
        const region = c.XFixesCreateRegion(self.dpy, @constCast(rects.ptr), @intCast(rects.len));
        c.XFixesSetWindowShapeRegion(self.dpy, self.win, c.ShapeInput, 0, 0, region);
        c.XFixesDestroyRegion(self.dpy, region);
    }

    pub fn queryPointer(self: *const Window) PointerPos {
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
    pub fn pollEvent(self: *const Window) ?Event {
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
