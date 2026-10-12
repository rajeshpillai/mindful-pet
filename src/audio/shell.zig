//! Plays clips through whatever command-line player is installed. The
//! embedded WAVs are written to the runtime dir once at startup. Works on
//! Linux (PipeWire, PulseAudio, ALSA) and, via ffplay or afplay, elsewhere.

const std = @import("std");
const c = @import("c");
const audio = @import("../audio.zig");

pub const name = "shell";

pub const Audio = struct {
    enabled: bool,
    dir: [256:0]u8 = undefined,
    dir_len: usize = 0,
    player: []const u8 = "",

    /// Tried in order; the first one found on PATH wins.
    const players = [_][]const u8{ "pw-play", "paplay", "aplay", "afplay", "ffplay -nodisp -autoexit -loglevel quiet" };

    pub fn init(enabled: bool) Audio {
        var a: Audio = .{ .enabled = enabled };
        if (!enabled) return a;

        a.player = for (players) |p| {
            var probe: [128:0]u8 = undefined;
            const exe = std.mem.sliceTo(p, ' ');
            const cmd = std.mem.printSentinel(&probe, "command -v {s} >/dev/null 2>&1", .{exe}, 0) catch continue;
            if (c.system(cmd.ptr) == 0) break p;
        } else {
            std.debug.print("pet: no audio player found (tried pw-play, paplay, aplay, afplay, ffplay); running silent\n", .{});
            a.enabled = false;
            return a;
        };

        const base: []const u8 = if (c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
        const dir = std.mem.printSentinel(&a.dir, "{s}/pet-sounds", .{base}, 0) catch {
            a.enabled = false;
            return a;
        };
        a.dir_len = dir.len;
        _ = c.mkdir(dir.ptr, 0o700);
        for (audio.clips) |clip| {
            var path: [300:0]u8 = undefined;
            const p = std.mem.printSentinel(&path, "{s}/{s}.wav", .{ dir, clip.name }, 0) catch continue;
            const f = c.fopen(p.ptr, "wb") orelse continue;
            _ = c.fwrite(clip.data.ptr, 1, clip.data.len, f);
            _ = c.fclose(f);
        }
        return a;
    }

    pub fn play(self: *const Audio, clip: []const u8) void {
        if (!self.enabled) return;
        var cmd: [512:0]u8 = undefined;
        const line = std.mem.printSentinel(&cmd, "{s} '{s}/{s}.wav' >/dev/null 2>&1 &", .{ self.player, self.dir[0..self.dir_len], clip }, 0) catch return;
        _ = c.system(line.ptr);
    }
};
