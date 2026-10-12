//! GNOME backend: each Window is a Clutter actor drawn by the Mindful Pet
//! GNOME Shell extension (gnome-extension/), reached over a Unix socket at
//! $XDG_RUNTIME_DIR/mindful-pet-shell.sock. The shell sees the pointer over
//! every window and keeps the actor above native Wayland windows, which an
//! X11 client under XWayland cannot. Protocol in extension.js: this side
//! speaks v2 (`hello W H 2`), keeps the pet on the primary monitor by
//! translating the shell's stage coordinates, and falls back to the legacy
//! whole-stage geometry when an older extension answers.

const std = @import("std");
const c = @import("c");
const backend = @import("../backend.zig");

pub const name = "gnome";
pub const socket_name = "mindful-pet-shell.sock";
/// How long `send` waits for the shell to take a full socket's worth of data
/// before giving up on it, and the poll slice between drains while waiting.
const send_timeout_ms: i32 = 2000;
const send_slice_ms: i32 = 20;

const Error = backend.Error;
const PointerPos = backend.PointerPos;
const Rect = backend.Rect;
const Event = backend.Event;

/// Path of the extension's socket, into `buf`.
fn socketPath(buf: *[256:0]u8) ?[:0]u8 {
    const dir: []const u8 = if (c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
    return std.mem.printSentinel(buf, "{s}/{s}", .{ dir, socket_name }, 0) catch null;
}

fn connectSocket() ?c_int {
    var buf: [256:0]u8 = undefined;
    const path = socketPath(&buf) orelse return null;
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return null;
    var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) {
        _ = c.close(fd);
        return null;
    }
    @memcpy(addr.sun_path[0..path.len], path);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

/// True when the extension is running and accepting connections. Used by the
/// `auto` backend to decide; costs one connect.
pub fn available() bool {
    const fd = connectSocket() orelse return false;
    _ = c.close(fd);
    return true;
}

/// Sleep until a socket or the extra descriptor has data, or the timeout passes.
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
    sock: c_int,
    /// w*h ARGB pixels painted by the caller, sent on `present`.
    pixels: [*]u32,
    /// Base64 of the pixel buffer plus the "img " prefix and newline.
    encoded: [*]u8,
    encoded_len: usize,
    w: u32,
    h: u32,
    /// The shell composites our alpha, so this is always true.
    argb: bool = true,
    /// Size of the monitor the pet lives on (the primary one).
    screen_w: i32,
    screen_h: i32,
    /// Where that monitor sits in the shell's stage coordinates. Everything
    /// on the wire is stage space; everything this type exposes is relative
    /// to the monitor, so the pet never walks off into the gap beside a
    /// smaller screen.
    origin_x: i32 = 0,
    origin_y: i32 = 0,

    pointer: PointerPos = .{ .x = 0, .y = 0 },
    /// Button held since the last `press`, so pointer updates become `motion`.
    held: ?u32 = null,
    last_move: ?[2]i32 = null,
    rx: [1024]u8 = undefined,
    rx_len: usize = 0,
    queue: [32]Event = undefined,
    queue_head: usize = 0,
    queue_len: usize = 0,
    /// Terminal connection failure; reported once as `disconnected`.
    lost: bool = false,
    disconnect_reported: bool = false,
    supports_input: bool = false,

    pub fn init(w: u32, h: u32) Error!Window {
        const sock = connectSocket() orelse {
            var buf: [256:0]u8 = undefined;
            std.debug.print("pet: cannot reach the Mindful Pet GNOME Shell extension at {s}\n" ++
                "pet: install it with scripts/install-extension, or build with -Dbackend=x11\n", .{socketPath(&buf) orelse "?"});
            return error.NoDisplay;
        };
        errdefer _ = c.close(sock);

        const bytes: usize = @as(usize, w) * h * 4;
        const pixels = c.malloc(bytes) orelse return error.OutOfMemory;
        errdefer c.free(pixels);
        const prefix = "img ";
        const enc_len = prefix.len + std.base64.standard.Encoder.calcSize(bytes) + 1;
        const encoded: [*]u8 = @ptrCast(c.malloc(enc_len) orelse return error.OutOfMemory);
        errdefer c.free(encoded);
        @memcpy(encoded[0..prefix.len], prefix);
        encoded[enc_len - 1] = '\n';

        var win: Window = .{
            .sock = sock,
            .pixels = @ptrCast(@alignCast(pixels)),
            .encoded = encoded,
            .encoded_len = enc_len,
            .w = w,
            .h = h,
            .screen_w = 0,
            .screen_h = 0,
        };
        @memset(win.pixels[0 .. w * h], 0);

        var hello: [64]u8 = undefined;
        // Older extensions ignore the optional version and retain stage coordinates.
        win.send(std.fmt.bufPrint(&hello, "hello {d} {d} 2\n", .{ w, h }) catch unreachable);

        // The extension answers with the screen size; give it a moment.
        var tries: u32 = 0;
        while (win.screen_w == 0 and tries < 50) : (tries += 1) {
            var pfd = [_]c.pollfd{.{ .fd = win.sock, .events = c.POLLIN, .revents = 0 }};
            _ = c.poll(&pfd, 1, 100);
            win.drain();
            if (win.lost) return error.NoDisplay;
        }
        if (win.screen_w == 0) {
            std.debug.print("pet: the GNOME Shell extension did not answer\n", .{});
            return error.NoDisplay;
        }
        return win;
    }

    pub fn backendName(self: *const Window) []const u8 {
        _ = self;
        return name;
    }

    /// The socket descriptor, for `wait`.
    pub fn fd(self: *const Window) c_int {
        return self.sock;
    }

    pub fn deinit(self: *Window) void {
        _ = c.close(self.sock);
        c.free(@ptrCast(self.pixels));
        c.free(@ptrCast(self.encoded));
    }

    pub fn show(self: *Window) void {
        self.send("show\n");
    }

    pub fn hide(self: *Window) void {
        self.send("hide\n");
    }

    pub fn move(self: *Window, x: i32, y: i32) void {
        if (self.last_move) |m| if (m[0] == x and m[1] == y) return;
        self.last_move = .{ x, y };
        var buf: [48]u8 = undefined;
        self.send(std.fmt.bufPrint(&buf, "move {d} {d}\n", .{ x + self.origin_x, y + self.origin_y }) catch return);
    }

    pub fn raise(self: *Window) void {
        self.send("raise\n");
    }

    /// Ship the whole pixel buffer to the shell.
    pub fn present(self: *Window) void {
        const bytes = std.mem.sliceAsBytes(self.pixels[0 .. self.w * self.h]);
        _ = std.base64.standard.Encoder.encode(self.encoded[4 .. self.encoded_len - 1], bytes);
        self.send(self.encoded[0..self.encoded_len]);
    }

    /// Writes go out immediately; nothing to flush.
    pub fn flush(self: *Window) void {
        _ = self;
    }

    /// Nonempty shapes use alpha hit-testing; an empty shape is click-through.
    pub fn setInputShape(self: *Window, rects: []const Rect) void {
        if (self.supports_input) self.send(if (rects.len == 0) "input 0\n" else "input 1\n");
    }

    pub fn queryPointer(self: *Window) PointerPos {
        self.drain();
        return self.pointer;
    }

    pub fn pollEvent(self: *Window) ?Event {
        self.drain();
        if (self.queue_len == 0) {
            if (self.lost and !self.disconnect_reported) {
                self.disconnect_reported = true;
                return .disconnected;
            }
            return null;
        }
        const ev = self.queue[self.queue_head];
        self.queue_head = (self.queue_head + 1) % self.queue.len;
        self.queue_len -= 1;
        return ev;
    }

    /// Write a whole line without ever blocking for long. The shell and the
    /// pet both write to each other, so if either side waited on a full
    /// socket while the other did the same, both would hang (and the shell
    /// is the desktop). While the socket is full the pet keeps reading the
    /// shell's lines, and after `send_timeout_ms` it treats the shell as gone.
    fn send(self: *Window, data: []const u8) void {
        if (self.lost) return;
        var off: usize = 0;
        var waited_ms: i32 = 0;
        while (off < data.len) {
            const n = c.send(self.sock, data[off..].ptr, data.len - off, c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            const err = std.posix.errno(n);
            if (n < 0 and (err == .AGAIN or err == .INTR)) {
                if (waited_ms >= send_timeout_ms) {
                    std.debug.print("pet: the GNOME Shell extension stopped reading\n", .{});
                    self.lost = true;
                    return;
                }
                var pfd = [_]c.pollfd{.{ .fd = self.sock, .events = c.POLLOUT | c.POLLIN, .revents = 0 }};
                _ = c.poll(&pfd, 1, send_slice_ms);
                waited_ms += send_slice_ms;
                self.drain();
                if (self.lost) return;
                continue;
            }
            self.lost = true; // closed or reset by the shell
            return;
        }
    }

    fn push(self: *Window, ev: Event) void {
        if (self.queue_len == self.queue.len) return; // drop the oldest-but-one; input is best effort
        self.queue[(self.queue_head + self.queue_len) % self.queue.len] = ev;
        self.queue_len += 1;
    }

    /// Read whatever the shell has sent and turn complete lines into state and events.
    fn drain(self: *Window) void {
        if (self.lost) return;
        while (true) {
            if (self.rx_len == self.rx.len) self.rx_len = 0; // garbage line, drop it
            const n = c.recv(self.sock, self.rx[self.rx_len..].ptr, self.rx.len - self.rx_len, c.MSG_DONTWAIT);
            if (n == 0) {
                self.lost = true;
                return;
            }
            if (n < 0) return; // EAGAIN: nothing more right now
            self.rx_len += @intCast(n);
            while (std.mem.indexOfScalar(u8, self.rx[0..self.rx_len], '\n')) |nl| {
                self.handle(self.rx[0..nl]);
                const rest = self.rx_len - (nl + 1);
                std.mem.copyForwards(u8, self.rx[0..rest], self.rx[nl + 1 .. self.rx_len]);
                self.rx_len = rest;
            }
        }
    }

    fn handle(self: *Window, line: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse return;
        if (std.mem.eql(u8, cmd, "capabilities")) {
            while (it.next()) |cap| {
                if (std.mem.eql(u8, cap, "input")) self.supports_input = true;
            }
            return;
        }
        var nums: [5]i32 = .{ 0, 0, 0, 0, 0 };
        var count: usize = 0;
        while (it.next()) |tok| : (count += 1) {
            if (count == nums.len) break;
            nums[count] = std.fmt.parseInt(i32, tok, 10) catch return;
        }
        if (std.mem.eql(u8, cmd, "pointer") and count >= 2) {
            const x = nums[0] - self.origin_x;
            const y = nums[1] - self.origin_y;
            self.pointer = .{ .x = x, .y = y };
            if (self.held != null) self.push(.{ .motion = .{ .x_root = x, .y_root = y } });
        } else if (std.mem.eql(u8, cmd, "press") and count >= 5) {
            self.held = @intCast(nums[0]);
            self.push(.{ .press = .{ .button = @intCast(nums[0]), .x_root = nums[1] - self.origin_x, .y_root = nums[2] - self.origin_y, .x = nums[3], .y = nums[4] } });
        } else if (std.mem.eql(u8, cmd, "release") and count >= 3) {
            self.held = null;
            self.push(.{ .release = .{ .button = @intCast(nums[0]), .x_root = nums[1] - self.origin_x, .y_root = nums[2] - self.origin_y } });
        } else if (std.mem.eql(u8, cmd, "screen") and count >= 4) {
            self.setScreen(nums[0], nums[1], nums[2], nums[3]);
        } else if (std.mem.eql(u8, cmd, "screen") and count >= 2) {
            // An older extension: the whole stage, origin 0,0.
            self.setScreen(0, 0, nums[0], nums[1]);
        }
    }

    fn setScreen(self: *Window, x: i32, y: i32, w: i32, h: i32) void {
        if (w <= 0 or h <= 0) return;
        const changed = self.screen_w != w or self.screen_h != h or self.origin_x != x or self.origin_y != y;
        if (!changed) return;
        const initialized = self.screen_w > 0;
        self.pointer.x += self.origin_x - x;
        self.pointer.y += self.origin_y - y;
        self.origin_x = x;
        self.origin_y = y;
        self.screen_w = w;
        self.screen_h = h;
        self.last_move = null;
        if (initialized) self.push(.screen_changed);
    }
};

test "shell lines become events" {
    var w: Window = undefined;
    w.held = null;
    w.queue_head = 0;
    w.queue_len = 0;
    w.pointer = .{ .x = 0, .y = 0 };
    w.screen_w = 0;
    w.screen_h = 0;
    w.origin_x = 0;
    w.origin_y = 0;
    w.handle("screen 1920 1080");
    try std.testing.expectEqual(@as(i32, 1920), w.screen_w);
    try std.testing.expectEqual(@as(i32, 0), w.origin_x);
    w.handle("pointer 10 20");
    try std.testing.expectEqual(@as(usize, 0), w.queue_len); // no drag, no motion event
    w.handle("press 1 10 20 3 4");
    w.handle("pointer 15 25");
    w.handle("release 1 15 25");
    try std.testing.expectEqual(@as(usize, 3), w.queue_len);
    try std.testing.expectEqual(@as(u32, 1), w.queue[0].press.button);
    try std.testing.expectEqual(@as(i32, 15), w.queue[1].motion.x_root);
    try std.testing.expect(w.queue[2] == .release);
}

test "a monitor away from the stage origin is reported in its own coordinates" {
    var w: Window = undefined;
    w.held = null;
    w.queue_head = 0;
    w.queue_len = 0;
    w.pointer = .{ .x = 0, .y = 0 };
    w.screen_w = 0;
    w.screen_h = 0;
    w.origin_x = 0;
    w.origin_y = 0;
    // A 1366x768 laptop panel centred under a 1920x1080 monitor.
    w.handle("screen 710 1080 1366 768");
    try std.testing.expectEqual(@as(i32, 1366), w.screen_w);
    try std.testing.expectEqual(@as(i32, 768), w.screen_h);
    w.handle("pointer 720 1100");
    try std.testing.expectEqual(@as(i32, 10), w.pointer.x);
    try std.testing.expectEqual(@as(i32, 20), w.pointer.y);
    w.handle("press 1 720 1100 3 4");
    const ev = w.queue[w.queue_head];
    try std.testing.expectEqual(@as(i32, 10), ev.press.x_root);
    try std.testing.expectEqual(@as(i32, 20), ev.press.y_root);
    try std.testing.expectEqual(@as(i32, 3), ev.press.x);
}

test "monitor changes invalidate moves and rebase the pointer" {
    var w: Window = .{ .sock = -1, .pixels = undefined, .encoded = undefined, .encoded_len = 0, .w = 64, .h = 64, .screen_w = 1366, .screen_h = 768, .origin_x = 710, .origin_y = 1080 };
    w.last_move = .{ 100, 704 };
    w.pointer = .{ .x = 10, .y = 20 };
    w.handle("screen 0 0 800 600");
    try std.testing.expect(w.last_move == null);
    try std.testing.expectEqual(@as(i32, 720), w.pointer.x);
    try std.testing.expectEqual(@as(i32, 1100), w.pointer.y);
    try std.testing.expect(w.queue[0] == .screen_changed);
    try std.testing.expectEqual(@as(i32, 600), w.screen_h);
    w.handle("screen 0 0 0 0");
    try std.testing.expectEqual(@as(i32, 800), w.screen_w);
}

test "disconnect is reported once without reviving the connection" {
    var w: Window = .{ .sock = -1, .pixels = undefined, .encoded = undefined, .encoded_len = 0, .w = 64, .h = 64, .screen_w = 800, .screen_h = 600, .lost = true };
    try std.testing.expect(w.pollEvent().? == .disconnected);
    try std.testing.expect(w.pollEvent() == null);
    try std.testing.expect(w.lost);
}

test "input control is negotiated separately from screen geometry" {
    var w: Window = .{ .sock = -1, .pixels = undefined, .encoded = undefined, .encoded_len = 0, .w = 64, .h = 64, .screen_w = 0, .screen_h = 0 };
    w.handle("screen 1280 800");
    try std.testing.expect(!w.supports_input);
    w.handle("capabilities input");
    try std.testing.expect(w.supports_input);
}
