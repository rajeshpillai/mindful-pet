//! A named pipe other programs can write one-line commands into, e.g.
//!   echo fail > "$XDG_RUNTIME_DIR/pet.fifo"
//! Opened read+write so the pipe never reports EOF when writers come and go.

const std = @import("std");
const c = @import("c");
const Pet = @import("pet.zig");

pub const Command = union(enum) {
    pet: Pet.Event,
    goto: f32,
    quit,
};

pub const Fifo = struct {
    fd: c_int,
    path_buf: [512:0]u8,
    path_len: usize,
    carry: [512]u8 = undefined,
    carry_len: usize = 0,
    /// Holds the most recently extracted line for the caller.
    line: [512]u8 = undefined,

    pub fn open() !Fifo {
        var f: Fifo = .{ .fd = -1, .path_buf = undefined, .path_len = 0 };
        const dir: []const u8 = if (c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
        const p = try std.mem.printSentinel(&f.path_buf, "{s}/pet.fifo", .{dir}, 0);
        f.path_len = p.len;

        // Ignore the result: if it already exists we just open it.
        _ = c.mkfifo(p.ptr, 0o600);
        f.fd = c.open(p.ptr, c.O_RDWR | c.O_NONBLOCK);
        if (f.fd < 0) return error.CannotOpenFifo;
        return f;
    }

    pub fn close(self: *Fifo) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    pub fn path(self: *const Fifo) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Returns the next complete command line, reading more bytes if needed.
    pub fn pollCommand(self: *Fifo) ?Command {
        if (self.takeLine()) |line| return parse(line);
        self.fill();
        if (self.takeLine()) |line| return parse(line);
        return null;
    }

    fn fill(self: *Fifo) void {
        if (self.carry_len == self.carry.len) self.carry_len = 0; // garbage line, drop it
        const n = c.read(self.fd, self.carry[self.carry_len..].ptr, self.carry.len - self.carry_len);
        if (n > 0) self.carry_len += @intCast(n);
    }

    fn takeLine(self: *Fifo) ?[]const u8 {
        const nl = std.mem.indexOfScalar(u8, self.carry[0..self.carry_len], '\n') orelse return null;
        @memcpy(self.line[0..nl], self.carry[0..nl]);
        const rest = self.carry_len - (nl + 1);
        std.mem.copyForwards(u8, self.carry[0..rest], self.carry[nl + 1 .. self.carry_len]);
        self.carry_len = rest;
        return self.line[0..nl];
    }
};

pub fn parse(raw: []const u8) ?Command {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0) return null;
    const eq = std.mem.eql;
    if (eq(u8, line, "ok") or eq(u8, line, "pass") or eq(u8, line, "happy")) return .{ .pet = .build_ok };
    if (eq(u8, line, "fail") or eq(u8, line, "error") or eq(u8, line, "angry")) return .{ .pet = .build_fail };
    if (eq(u8, line, "sleep")) return .{ .pet = .sleep };
    if (eq(u8, line, "wake")) return .{ .pet = .wake };
    if (eq(u8, line, "meow") or eq(u8, line, "alert") or eq(u8, line, "poke")) return .{ .pet = .alert };
    if (eq(u8, line, "quit") or eq(u8, line, "exit")) return .quit;
    if (std.mem.startsWith(u8, line, "goto ")) {
        const x = std.fmt.parseFloat(f32, std.mem.trim(u8, line[5..], " ")) catch return null;
        return .{ .goto = x };
    }
    std.debug.print("pet: unknown command '{s}'\n", .{line});
    return null;
}

test "parse commands" {
    try std.testing.expectEqual(Command{ .pet = .build_fail }, parse("fail\r").?);
    try std.testing.expectEqual(Command.quit, parse("quit").?);
    try std.testing.expectEqual(@as(f32, 640), parse("goto 640").?.goto);
    try std.testing.expect(parse("   ") == null);
}
