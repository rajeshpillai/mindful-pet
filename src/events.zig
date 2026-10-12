//! The command vocabulary and its parser. Lines arrive through whatever
//! `channel.zig` provides for this OS (a named pipe on Linux), e.g.
//!   echo fail > "$XDG_RUNTIME_DIR/pet.fifo"

const std = @import("std");
const Pet = @import("pet.zig");

pub const Command = union(enum) {
    pet: Pet.Event,
    goto: f32,
    /// Text to show in a bubble; valid until the next `pollCommand`.
    say: []const u8,
    quit,
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
    if (eq(u8, line, "work") or eq(u8, line, "busy")) return .{ .pet = .work };
    if (eq(u8, line, "done") or eq(u8, line, "idle")) return .{ .pet = .done };
    if (eq(u8, line, "climb")) return .{ .pet = .climb };
    if (eq(u8, line, "quit") or eq(u8, line, "exit")) return .quit;
    if (std.mem.startsWith(u8, line, "say ")) {
        const text = std.mem.trim(u8, line[4..], " ");
        if (text.len == 0) return null;
        return .{ .say = text };
    }
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
    try std.testing.expectEqualStrings("tests green", parse("say  tests green ").?.say);
    try std.testing.expect(parse("say ") == null);
}
