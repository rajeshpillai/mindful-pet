//! Optional monitor visits. The pet's brain still sees one real screen at a time.
const std = @import("std");
const geometry = @import("monitors.zig");
const petmod = @import("pet.zig");
const sprites = @import("sprites.zig");

pub const Roaming = struct {
    remaining: f32,

    pub fn init(rand: std.Random) Roaming {
        return .{ .remaining = interval(rand) };
    }

    pub fn reset(self: *Roaming, rand: std.Random) void {
        self.remaining = interval(rand);
    }

    /// Pick a different actual monitor every 30..60 seconds. Wait for a quiet
    /// floor state instead of interrupting a command, a nap, climbing or carrying.
    pub fn tick(self: *Roaming, dt: f32, monitors: *const geometry.Monitors, current: geometry.Monitor, pet: *const petmod.Pet) ?geometry.Monitor {
        self.remaining -= dt;
        if (self.remaining > 0 or monitors.len < 2 or pet.climb_next) return null;
        switch (pet.state) {
            .idle, .sit, .walk => {},
            else => return null,
        }
        var candidates: [32]geometry.Monitor = undefined;
        var n: usize = 0;
        for (monitors.items[0..monitors.len]) |m| {
            if (std.meta.eql(m, current)) continue;
            candidates[n] = m;
            n += 1;
        }
        if (n == 0) return null;
        self.reset(pet.rand);
        return candidates[pet.rand.uintLessThan(usize, n)];
    }

    fn interval(rand: std.Random) f32 {
        return 30 + rand.float(f32) * 30;
    }
};

test "autonomous roaming visits another real monitor and waits for interrupted states" {
    var rand = std.Random.DefaultPrng.init(9);
    const primary: geometry.Monitor = .{ .x = 710, .y = 1080, .w = 1366, .h = 768 };
    const other: geometry.Monitor = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    var monitors: geometry.Monitors = .{};
    monitors.add(primary);
    monitors.add(other);
    var pet = petmod.Pet.init(rand.random(), &sprites.cat, 1366, 768, 64, 32);
    var roaming: Roaming = .{ .remaining = 0 };
    for ([_]petmod.State{ .held, .work, .sleep, .happy, .angry, .fall, .climb, .hang }) |state| {
        pet.state = state;
        try std.testing.expect(roaming.tick(0.1, &monitors, primary, &pet) == null);
    }
    pet.state = .idle;
    try std.testing.expectEqualDeep(other, roaming.tick(0.1, &monitors, primary, &pet).?);
    try std.testing.expect(roaming.remaining >= 30 and roaming.remaining < 60);
    try std.testing.expect(roaming.tick(0.1, &monitors, other, &pet) == null);
    monitors.len = 1;
    roaming.remaining = 0;
    try std.testing.expect(roaming.tick(1, &monitors, primary, &pet) == null);
}
