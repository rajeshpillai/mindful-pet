//! The cat's brain: a small state machine driven by time, the pointer,
//! and external events. Knows nothing about X11 or audio; it only reports
//! which frame to draw, how to orient it, and which sound to play.

const std = @import("std");
const sprites = @import("sprites.zig");

pub const Facing = enum { left, right };
pub const Wall = enum { left, right };

pub const State = enum {
    idle,
    walk,
    run,
    sit,
    sleep,
    alert,
    happy,
    angry,
    work,
    bat,
    /// Moving vertically along a screen edge.
    climb,
    /// Paused on the wall.
    cling,
    /// Walking upside down along the top edge.
    hang,
    held,
    fall,
};

/// Things the outside world can tell the cat.
pub const Event = enum { build_ok, build_fail, sleep, wake, alert, work, done, climb };

pub const Sound = enum { meow, purr, hiss };

/// How the renderer should orient the (right-facing) source frame.
pub const Transform = sprites.Transform;

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
    /// The "ceiling": lowest y the cat hangs at (below the GNOME top bar).
    top: f32,
    rand: std.Random,

    facing: Facing = .right,
    wall: Wall = .right,
    state: State = .idle,
    state_time: f32 = 0,
    state_limit: f32 = 1.5,
    anim_time: f32 = 0,
    target_x: f32 = 0,
    target_y: f32 = 0,
    vy: f32 = 0,
    /// Set while walking toward a wall with the intention of climbing it.
    climb_next: bool = false,
    /// Seconds since anything interesting happened near the cat.
    idle_for: f32 = 0,
    /// Seconds since the pointer last moved while the cat was chasing it.
    chase_stale: f32 = 0,
    /// Seconds the pointer has rested motionless on top of the cat.
    pointer_rest: f32 = 0,
    bat_cooldown: f32 = 0,
    /// Sound requested since the last `takeSound`.
    sound: ?Sound = null,

    const walk_speed: f32 = 55;
    const run_speed: f32 = 230;
    const climb_speed: f32 = 80;
    const gravity: f32 = 1800;
    const nap_after: f32 = 45;
    /// A `work` command without a matching ok/fail/done gives up after this.
    const work_timeout: f32 = 15 * 60;
    const forever: f32 = 1e9;

    pub fn init(rand: std.Random, screen_w: f32, screen_h: f32, size: f32, top: f32) Pet {
        var p: Pet = .{
            .x = 0,
            .y = 0,
            .size = size,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .top = top,
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
            .build_ok => {
                self.sound = .purr;
                self.enter(.happy, 2.5);
            },
            .build_fail => {
                self.sound = .hiss;
                self.enter(.angry, 2.5);
            },
            .sleep => self.enter(.sleep, forever),
            .wake => if (self.state == .sleep) self.enter(.alert, 0.6),
            .alert => self.meow(),
            .work => self.enter(.work, work_timeout),
            .done => if (self.state == .work) self.enter(.idle, self.randRange(1, 2)),
            .climb => self.startClimb(),
        }
    }

    /// Walk to a screen x coordinate (centre of the sprite ends up there).
    pub fn goTo(self: *Pet, x: f32) void {
        if (self.state == .held or self.state == .fall) return;
        self.idle_for = 0;
        self.climb_next = false;
        self.target_x = self.clampX(x - self.size / 2);
        self.enter(.walk, forever);
    }

    /// Head for the nearest screen edge and climb it.
    pub fn startClimb(self: *Pet) void {
        if (!self.onFloor()) return;
        self.idle_for = 0;
        self.wall = if (self.x + self.size / 2 < self.screen_w / 2) .left else .right;
        self.target_x = if (self.wall == .left) 0 else self.screen_w - self.size;
        self.climb_next = true;
        self.enter(.walk, forever);
    }

    /// Returns and clears the pending sound.
    pub fn takeSound(self: *Pet) ?Sound {
        defer self.sound = null;
        return self.sound;
    }

    pub fn update(self: *Pet, dt: f32, in: Input) void {
        self.state_time += dt;
        self.anim_time += dt;
        self.idle_for += dt;
        if (self.bat_cooldown > 0) self.bat_cooldown -= dt;

        const floor = self.floorY();
        const cx = self.x + self.size / 2;
        const cy = self.y + self.size / 2;
        const dxp = in.pointer_x - cx;
        const dyp = in.pointer_y - cy;
        const dist = @sqrt(dxp * dxp + dyp * dyp);
        const pointer_near = in.pointer_moved and dist < 260 and dist > 40;
        const pointer_over = in.pointer_x >= self.x and in.pointer_x < self.x + self.size and
            in.pointer_y >= self.y and in.pointer_y < self.y + self.size;

        if (in.pointer_moved and dist < 400) self.idle_for = 0;
        self.pointer_rest = if (pointer_over and !in.pointer_moved) self.pointer_rest + dt else 0;

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
            .bat => {
                if (self.state_time > self.state_limit) self.enter(.sit, self.randRange(2, 4));
            },
            // Working cats ignore the pointer; only events or the timeout end it.
            .work => {
                if (self.state_time > self.state_limit) self.enter(.idle, 1);
            },
            .idle, .sit => {
                if (self.pointer_rest > 0.8 and self.bat_cooldown <= 0) {
                    self.pointer_rest = 0;
                    self.bat_cooldown = 4;
                    self.enter(.bat, 0.7);
                } else if (pointer_near) {
                    self.startChase(in);
                } else if (self.state_time > self.state_limit) {
                    self.decide();
                }
            },
            .walk => {
                if (pointer_near) {
                    self.startChase(in);
                } else if (self.step(dt, walk_speed)) {
                    if (self.climb_next) {
                        self.climb_next = false;
                        self.target_y = self.top;
                        self.enter(.climb, forever);
                    } else {
                        self.enter(.idle, self.randRange(1, 3));
                    }
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
            .climb => {
                const dy = self.target_y - self.y;
                if (@abs(dy) <= climb_speed * dt) {
                    self.y = self.target_y;
                    if (self.y <= self.top) {
                        // Reached the ceiling: hang and walk along it, or rest.
                        if (self.rand.float(f32) < 0.5) {
                            self.target_x = self.randRange(self.size, self.screen_w - 2 * self.size);
                            self.enter(.hang, forever);
                        } else {
                            self.enter(.cling, self.randRange(1, 3));
                        }
                    } else {
                        self.enter(.idle, self.randRange(1, 2));
                    }
                } else {
                    self.y += std.math.sign(dy) * climb_speed * dt;
                }
            },
            .cling => {
                if (self.state_time > self.state_limit) {
                    self.target_y = floor;
                    self.enter(.climb, forever);
                }
            },
            .hang => {
                self.y = self.top;
                if (self.step(dt, walk_speed)) {
                    self.vy = 0;
                    self.enter(.fall, forever);
                }
            },
        }

        if (self.onFloorState() and self.y != floor) self.y = floor;
    }

    pub fn frame(self: *const Pet) *const sprites.Frame {
        const t = self.anim_time;
        return switch (self.state) {
            .idle => &sprites.idle[cycle(t, 0.7, sprites.idle.len)],
            .walk, .hang => &sprites.walk[cycle(t, 0.12, sprites.walk.len)],
            .run => &sprites.walk[cycle(t, 0.06, sprites.walk.len)],
            .climb => &sprites.walk[cycle(t, 0.15, sprites.walk.len)],
            .cling => &sprites.idle[0],
            .sit => &sprites.sit[if (@mod(t, 4.0) > 3.8) 1 else 0],
            .sleep => &sprites.sleep[cycle(t, 0.9, sprites.sleep.len)],
            .alert => &sprites.alert[0],
            .happy => &sprites.happy[cycle(t, 0.4, sprites.happy.len)],
            .angry => &sprites.angry[cycle(t, 0.15, sprites.angry.len)],
            .work => &sprites.work[cycle(t, 0.2, sprites.work.len)],
            .bat => &sprites.bat[cycle(t, 0.35, sprites.bat.len)],
            .held, .fall => &sprites.held[0],
        };
    }

    pub fn transform(self: *const Pet) Transform {
        return switch (self.state) {
            .climb, .cling => if (self.wall == .right) .wall_right else .wall_left,
            .hang => if (self.facing == .right) .flip_v else .rot180,
            else => if (self.facing == .right) .none else .flip_h,
        };
    }

    // --- internals ---------------------------------------------------------

    fn onFloor(self: *const Pet) bool {
        return self.onFloorState() and self.y == self.floorY();
    }

    fn onFloorState(self: *const Pet) bool {
        return switch (self.state) {
            .held, .fall, .climb, .cling, .hang => false,
            else => true,
        };
    }

    fn meow(self: *Pet) void {
        if (self.state == .held or self.state == .fall) return;
        std.debug.print("meow!\n", .{});
        self.sound = .meow;
        self.idle_for = 0;
        // Stay on the job: a poke while working is a glance up, not a break.
        if (self.state == .work) {
            self.anim_time = 0;
            return;
        }
        if (!self.onFloorState()) return;
        self.enter(.alert, 0.8);
    }

    fn startChase(self: *Pet, in: Input) void {
        self.climb_next = false;
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
        if (r < 0.4) {
            self.climb_next = false;
            self.target_x = self.randRange(0, self.screen_w - self.size);
            self.enter(.walk, forever);
        } else if (r < 0.55) {
            self.startClimb();
        } else if (r < 0.85) {
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

// --- tests ------------------------------------------------------------------

const still: Input = .{ .pointer_x = -1000, .pointer_y = -1000, .pointer_moved = false };

fn run(pet: *Pet, seconds: f32, in: Input) void {
    var t: f32 = 0;
    while (t < seconds) : (t += 1.0 / 60.0) pet.update(1.0 / 60.0, in);
}

test "cat walks to a target and arrives" {
    var prng = std.Random.DefaultPrng.init(1);
    var pet = Pet.init(prng.random(), 1920, 1080, 64, 32);
    pet.goTo(1000);
    var i: usize = 0;
    while (pet.state == .walk and i < 60 * 60) : (i += 1) pet.update(1.0 / 60.0, still);
    try std.testing.expect(pet.state != .walk);
    try std.testing.expectApproxEqAbs(@as(f32, 1000 - 32), pet.x, 1.0);
}

test "work lasts until a result arrives and ignores the pointer" {
    var prng = std.Random.DefaultPrng.init(3);
    var pet = Pet.init(prng.random(), 1920, 1080, 64, 32);
    pet.onEvent(.work);
    try std.testing.expectEqual(State.work, pet.state);
    const nearby: Input = .{ .pointer_x = pet.x + 150, .pointer_y = pet.y, .pointer_moved = true };
    run(&pet, 30, nearby);
    try std.testing.expectEqual(State.work, pet.state);
    pet.onEvent(.build_ok);
    try std.testing.expectEqual(State.happy, pet.state);
    try std.testing.expectEqual(Sound.purr, pet.takeSound().?);
    try std.testing.expect(pet.takeSound() == null);
}

test "build failure makes the cat angry, then it sits" {
    var prng = std.Random.DefaultPrng.init(2);
    var pet = Pet.init(prng.random(), 1920, 1080, 64, 32);
    pet.onEvent(.build_fail);
    try std.testing.expectEqual(State.angry, pet.state);
    pet.update(3.0, still);
    try std.testing.expectEqual(State.sit, pet.state);
}

test "climb goes to the wall, up to the ceiling, and ends back on the floor" {
    var prng = std.Random.DefaultPrng.init(5);
    var pet = Pet.init(prng.random(), 1920, 1080, 64, 32);
    pet.x = 300; // nearer the left edge
    pet.onEvent(.climb);
    try std.testing.expectEqual(State.walk, pet.state);
    try std.testing.expectEqual(Wall.left, pet.wall);
    // Walk 300px at 55px/s, climb ~1000px at 80px/s: well under 30s.
    var seen_climb = false;
    var seen_top = false;
    var t: f32 = 0;
    while (t < 60) : (t += 1.0 / 60.0) {
        pet.update(1.0 / 60.0, still);
        if (pet.state == .climb) {
            seen_climb = true;
            try std.testing.expectEqual(Transform.wall_left, pet.transform());
            try std.testing.expectEqual(@as(f32, 0), pet.x);
        }
        if (pet.y <= 32) seen_top = true;
        if (seen_top and pet.y == pet.floorY() and pet.onFloorState()) break;
    }
    try std.testing.expect(seen_climb);
    try std.testing.expect(seen_top);
    try std.testing.expectEqual(pet.floorY(), pet.y);
}

test "pointer resting on the cat makes it bat, once per cooldown" {
    var prng = std.Random.DefaultPrng.init(8);
    var pet = Pet.init(prng.random(), 1920, 1080, 64, 32);
    const over: Input = .{ .pointer_x = pet.x + 30, .pointer_y = pet.y + 30, .pointer_moved = false };
    run(&pet, 1.0, over);
    try std.testing.expectEqual(State.bat, pet.state);
    run(&pet, 1.0, over);
    try std.testing.expect(pet.state != .bat); // swipe over, cooldown running
}
