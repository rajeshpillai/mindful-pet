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
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    monitors: backend.Monitors = .{},
    randr_event: ?c_int = null,
    primary: ?backend.Monitor = null,
    last_monitor_check: i64 = 0,

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

        var result: Window = .{
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
        var event_base: c_int = 0;
        var error_base: c_int = 0;
        var major: c_int = 0;
        var minor: c_int = 0;
        if (c.XRRQueryExtension(dpy, &event_base, &error_base) != 0 and
            c.XRRQueryVersion(dpy, &major, &minor) != 0 and
            (major > 1 or (major == 1 and minor >= 5)))
        {
            result.randr_event = event_base;
            c.XRRSelectInput(dpy, root, c.RRScreenChangeNotifyMask | c.RRCrtcChangeNotifyMask |
                c.RROutputChangeNotifyMask | c.RROutputPropertyNotifyMask | c.RRResourceChangeNotifyMask);
        }
        _ = result.refreshMonitors();
        return result;
    }

    fn refreshMonitors(self: *Window) bool {
        const previous = self.monitors;
        self.monitors = .{};
        var primary: ?backend.Monitor = null;
        if (self.randr_event != null) {
            var count: c_int = 0;
            const info = c.XRRGetMonitors(self.dpy, self.root, 1, &count);
            if (info != null) {
                defer c.XRRFreeMonitors(info);
                const primary_output = c.XRRGetOutputPrimary(self.dpy, self.root);
                for (0..@intCast(@max(0, count))) |i| {
                    const m: backend.Monitor = .{ .x = info[i].x, .y = info[i].y, .w = info[i].width, .h = info[i].height };
                    if (m.w <= 0 or m.h <= 0) continue;
                    self.monitors.add(m);
                    if (info[i].primary != 0) primary = m;
                    if (primary == null and primary_output != 0) {
                        for (0..@intCast(@max(0, info[i].noutput))) |j| {
                            if (info[i].outputs[j] == primary_output) primary = m;
                        }
                    }
                }
            }
        }
        if (self.monitors.len == 0) self.monitors.add(.{
            .x = 0,
            .y = 0,
            .w = c.XDisplayWidth(self.dpy, self.screen),
            .h = c.XDisplayHeight(self.dpy, self.screen),
        });
        if (self.monitors.len == 0) return false;
        const chosen = primary orelse self.monitors.items[0];
        var changed = !std.meta.eql(self.primary, @as(?backend.Monitor, chosen)) or previous.len != self.monitors.len;
        if (!changed) for (previous.items[0..previous.len], self.monitors.items[0..self.monitors.len]) |old, new| {
            if (!std.meta.eql(old, new)) changed = true;
        };
        self.primary = chosen;
        if (changed) self.useMonitor(chosen);
        return changed;
    }

    pub fn useMonitor(self: *Window, m: backend.Monitor) void {
        self.origin_x = m.x;
        self.origin_y = m.y;
        self.screen_w = m.w;
        self.screen_h = m.h;
    }

    pub fn deinit(self: *Window) void {
        // XDestroyImage is a macro; call the destroy hook, which also frees the pixel data.
        if (self.img.*.f.destroy_image) |destroy| _ = destroy(self.img);
        _ = c.XFreeGC(self.dpy, self.gc);
        _ = c.XDestroyWindow(self.dpy, self.win);
        _ = c.XCloseDisplay(self.dpy);
    }

    pub fn backendName(self: *const Window) []const u8 {
        _ = self;
        return name;
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
        _ = c.XMoveWindow(self.dpy, self.win, x + self.origin_x, y + self.origin_y);
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
        return .{ .x = rx - self.origin_x, .y = ry - self.origin_y };
    }

    /// Drain one event we care about; null when the queue holds nothing useful.
    pub fn pollEvent(self: *Window) ?Event {
        // Some X servers do not notify clients about logical monitor edits.
        // Check once a second too, without undoing an unchanged roaming selection.
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        if (ts.tv_sec != self.last_monitor_check) {
            self.last_monitor_check = ts.tv_sec;
            if (self.refreshMonitors()) return .screen_changed;
        }
        while (c.XPending(self.dpy) > 0) {
            var ev: c.XEvent = undefined;
            _ = c.XNextEvent(self.dpy, &ev);
            if (self.randr_event) |base| {
                if (ev.type == base + c.RRScreenChangeNotify or ev.type == base + c.RRNotify) {
                    _ = c.XRRUpdateConfiguration(&ev);
                    if (self.refreshMonitors()) return .screen_changed;
                    continue;
                }
            }
            switch (ev.type) {
                c.ButtonPress => return .{ .press = .{
                    .button = ev.xbutton.button,
                    .x_root = ev.xbutton.x_root - self.origin_x,
                    .y_root = ev.xbutton.y_root - self.origin_y,
                    .x = ev.xbutton.x,
                    .y = ev.xbutton.y,
                } },
                c.ButtonRelease => return .{ .release = .{
                    .button = ev.xbutton.button,
                    .x_root = ev.xbutton.x_root - self.origin_x,
                    .y_root = ev.xbutton.y_root - self.origin_y,
                } },
                c.MotionNotify => return .{ .motion = .{
                    .x_root = ev.xmotion.x_root - self.origin_x,
                    .y_root = ev.xmotion.y_root - self.origin_y,
                } },
                c.Expose => return .expose,
                else => {},
            }
        }
        return null;
    }
};
