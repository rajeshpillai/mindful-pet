//! The cat's brain: a small state machine driven by time, the pointer,
//! and external events. Knows nothing about X11.

const std = @import("std");
const sprites = @import("sprites.zig");

pub const Facing = enum { left, right };

pub const State = enum { idle, walk, run, sit, sleep, alert, happy, angry, held, fall };

/// Things the outside world can tell the cat.
pub const Event = enum { build_ok, build_fail, sleep, wake, alert };

pub const Input = struct {
    pointer_x: f32,
    pointer_y: f32,
    pointer_moved: bool,
    /// While the user drags the cat: the wanted top-left corner.
    drag: ?struct { x: f32, y: f32 } = null,
    /// Mouse button released this frame.
    drop: bool = false,
    /// A click that did not turn into a drag.
    clicked: bool = false,
};

pub const Pet = struct {
    /// Top-left corner of the sprite window in root coordinates.
    x: f32,
    y: f32,
    size: f32,
    screen_w: f32,
    screen_h: f32,
    rand: std.Random,

    facing: Facing = .right,
    state: State = .idle,
    state_time: f32 = 0,
    state_limit: f32 = 1.5,
    anim_time: f32 = 0,
    target_x: f32 = 0,
    vy: f32 = 0,
    /// Seconds since anything interesting happened near the cat.
    idle_for: f32 = 0,
    /// Seconds since the pointer last moved while the cat was chasing it.
    chase_stale: f32 = 0,

    const walk_speed: f32 = 55;
    const run_speed: f32 = 230;
    const gravity: f32 = 1800;
    const nap_after: f32 = 45;
    const forever: f32 = 1e9;

    pub fn init(rand: std.Random, screen_w: f32, screen_h: f32, size: f32) Pet {
        var p: Pet = .{
            .x = 0,
            .y = 0,
            .size = size,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .rand = rand,
        };
        p.y = p.floorY();
        p.x = p.randRange(size, screen_w - 2 * size);
        p.target_x = p.x;
        return p;
    }

    pub fn floorY(self: *const Pet) f32 {
        return self.screen_h - self.size;
    }

    pub fn onEvent(self: *Pet, ev: Event) void {
        self.idle_for = 0;
        if (self.state == .held or self.state == .fall) return;
        switch (ev) {
            .build_ok => self.enter(.happy, 2.5),
            .build_fail => self.enter(.angry, 2.5),
            .sleep => self.enter(.sleep, forever),
            .wake => if (self.state == .sleep) self.enter(.alert, 0.6),
            .alert => self.meow(),
        }
    }

    /// Walk to a screen x coordinate (centre of the sprite ends up there).
    pub fn goTo(self: *Pet, x: f32) void {
        if (self.state == .held or self.state == .fall) return;
        self.idle_for = 0;
        self.target_x = self.clampX(x - self.size / 2);
        self.enter(.walk, forever);
    }

    pub fn update(self: *Pet, dt: f32, in: Input) void {
        self.state_time += dt;
        self.anim_time += dt;
        self.idle_for += dt;

        const floor = self.floorY();
        const cx = self.x + self.size / 2;
        const cy = self.y + self.size / 2;
        const dxp = in.pointer_x - cx;
        const dyp = in.pointer_y - cy;
        const dist = @sqrt(dxp * dxp + dyp * dyp);
        const pointer_near = in.pointer_moved and dist < 260 and dist > 40;

        if (in.pointer_moved and dist < 400) self.idle_for = 0;

        if (in.drag) |d| {
            self.x = self.clampX(d.x);
            self.y = std.math.clamp(d.y, 0, floor);
            if (self.state != .held) self.enter(.held, forever);
            return;
        }
        if (in.drop and self.state == .held) {
            if (self.y < floor - 1) {
                self.vy = 0;
                self.enter(.fall, forever);
            } else {
                self.enter(.alert, 0.5);
            }
        }
        if (in.clicked) self.meow();

        switch (self.state) {
            .held => {},
            .fall => {
                self.vy += gravity * dt;
                self.y += self.vy * dt;
                if (self.y >= floor) {
                    self.y = floor;
                    self.vy = 0;
                    self.enter(.alert, 0.4);
                }
            },
            .sleep => {
                if ((in.pointer_moved and dist < 140) or self.state_time > self.state_limit) {
                    self.enter(.alert, 0.6);
                }
            },
            .alert, .happy, .angry => {
                if (self.state_time > self.state_limit) self.enter(.sit, self.randRange(3, 7));
            },
            .idle, .sit => {
                if (pointer_near) {
                    self.startChase(in);
                } else if (self.state_time > self.state_limit) {
                    self.decide();
                }
            },
            .walk => {
                if (pointer_near) {
                    self.startChase(in);
                } else if (self.step(dt, walk_speed)) {
                    self.enter(.idle, self.randRange(1, 3));
                }
            },
            .run => {
                if (in.pointer_moved) {
                    self.target_x = self.clampX(in.pointer_x - self.size / 2);
                    self.chase_stale = 0;
                } else {
                    self.chase_stale += dt;
                }
                if (self.step(dt, run_speed)) {
                    self.enter(.sit, self.randRange(3, 6));
                } else if (self.chase_stale > 2) {
                    self.enter(.idle, self.randRange(1, 2));
                }
            },
        }

        if (self.state != .held and self.state != .fall and self.y != floor) self.y = floor;
    }

    pub fn frame(self: *const Pet) *const sprites.Frame {
        const t = self.anim_time;
        return switch (self.state) {
            .idle => &sprites.idle[cycle(t, 0.7, sprites.idle.len)],
            .walk => &sprites.walk[cycle(t, 0.12, sprites.walk.len)],
            .run => &sprites.walk[cycle(t, 0.06, sprites.walk.len)],
            .sit => &sprites.sit[if (@mod(t, 4.0) > 3.8) 1 else 0],
            .sleep => &sprites.sleep[cycle(t, 0.9, sprites.sleep.len)],
            .alert => &sprites.alert[0],
            .happy => &sprites.happy[cycle(t, 0.4, sprites.happy.len)],
            .angry => &sprites.angry[cycle(t, 0.15, sprites.angry.len)],
            .held, .fall => &sprites.held[0],
        };
    }

    // --- internals ---------------------------------------------------------

    fn meow(self: *Pet) void {
        if (self.state == .held or self.state == .fall) return;
        std.debug.print("meow!\n", .{});
        self.idle_for = 0;
        self.enter(.alert, 0.8);
    }

    fn startChase(self: *Pet, in: Input) void {
        self.target_x = self.clampX(in.pointer_x - self.size / 2);
        self.chase_stale = 0;
        self.enter(.run, forever);
    }

    fn decide(self: *Pet) void {
        if (self.idle_for > nap_after) {
            self.enter(.sleep, self.randRange(60, 150));
            return;
        }
        const r = self.rand.float(f32);
        if (r < 0.5) {
            self.target_x = self.randRange(0, self.screen_w - self.size);
            self.enter(.walk, forever);
        } else if (r < 0.8) {
            self.enter(.sit, self.randRange(3, 8));
        } else {
            self.enter(.idle, self.randRange(1, 3));
        }
    }

    /// Move toward target_x. Returns true once it has been reached.
    fn step(self: *Pet, dt: f32, speed: f32) bool {
        const dx = self.target_x - self.x;
        if (@abs(dx) <= speed * dt) {
            self.x = self.target_x;
            return true;
        }
        self.facing = if (dx > 0) .right else .left;
        self.x += std.math.sign(dx) * speed * dt;
        return false;
    }

    fn enter(self: *Pet, state: State, limit: f32) void {
        self.state = state;
        self.state_time = 0;
        self.state_limit = limit;
        self.anim_time = 0;
    }

    fn clampX(self: *const Pet, x: f32) f32 {
        return std.math.clamp(x, 0, self.screen_w - self.size);
    }

    fn randRange(self: *const Pet, lo: f32, hi: f32) f32 {
        return lo + self.rand.float(f32) * (hi - lo);
    }

    fn cycle(t: f32, period: f32, n: usize) usize {
        return @as(usize, @intFromFloat(t / period)) % n;
    }
};

test "cat walks to a target and arrives" {
    var prng = std.Random.DefaultPrng.init(1);
    var pet = Pet.init(prng.random(), 1920, 1080, 64);
    pet.goTo(1000);
    const still: Input = .{ .pointer_x = -1000, .pointer_y = -1000, .pointer_moved = false };
    var i: usize = 0;
    while (pet.state == .walk and i < 60 * 60) : (i += 1) pet.update(1.0 / 60.0, still);
    try std.testing.expect(pet.state != .walk);
    try std.testing.expectApproxEqAbs(@as(f32, 1000 - 32), pet.x, 1.0);
}

test "build failure makes the cat angry, then it sits" {
    var prng = std.Random.DefaultPrng.init(2);
    var pet = Pet.init(prng.random(), 1920, 1080, 64);
    pet.onEvent(.build_fail);
    try std.testing.expectEqual(State.angry, pet.state);
    const still: Input = .{ .pointer_x = -1000, .pointer_y = -1000, .pointer_moved = false };
    pet.update(3.0, still);
    try std.testing.expectEqual(State.sit, pet.state);
}
