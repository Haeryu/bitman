const std = @import("std");

const bitman = @import("bitman");
const Individual = bitman.Individual;

// ============================================================================
// BITMAN x SHORELARK (pt4) - Win32 console experiment
//
// Based on the simulation described in:
//   https://pwy.io/posts/learning-to-fly-pt4/
//
// This file intentionally keeps everything in one place.
// Bitman provides the quantized neural network + genetic algorithm.
// Everything else (world, eye, physics, rendering) lives here.
//
// Controls:
//   1  slow
//   2  normal
//   3  fast
//   4  turbo
//   Q / Esc  print full generation history, then quit
//
// World note:
//   The original Shorelark wraps at the edges. This experiment bounces from
//   walls instead, so a bird does not teleport to the opposite side.
// ============================================================================

// ============================================================================
// RAW WIN32 CONSOLE
// ============================================================================

const BOOL = i32;
const DWORD = u32;
const WORD = u16;
const SHORT = i16;
const WCHAR = u16;
const HANDLE = *anyopaque;

const COORD = extern struct {
    x: SHORT,
    y: SHORT,
};

const SMALL_RECT = extern struct {
    left: SHORT,
    top: SHORT,
    right: SHORT,
    bottom: SHORT,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    size: COORD,
    cursor_position: COORD,
    attributes: WORD,
    window: SMALL_RECT,
    maximum_window_size: COORD,
};

const CONSOLE_CURSOR_INFO = extern struct {
    size: DWORD,
    visible: BOOL,
};

const CHAR_UNION = extern union {
    UnicodeChar: WCHAR,
    AsciiChar: u8,
};

const CHAR_INFO = extern struct {
    char: CHAR_UNION,
    attributes: WORD,
};

const KEY_EVENT_RECORD = extern struct {
    key_down: BOOL,
    repeat_count: WORD,
    virtual_key_code: WORD,
    virtual_scan_code: WORD,
    char: extern union {
        unicode_char: WCHAR,
        ascii_char: u8,
    },
    control_key_state: DWORD,
};

const INPUT_RECORD = extern struct {
    event_type: WORD,
    event: extern union {
        key_event: KEY_EVENT_RECORD,
        raw: [16]u8,
    },
};

const STD_INPUT_HANDLE: DWORD = 0xfffffff6;
const STD_OUTPUT_HANDLE: DWORD = 0xfffffff5;

const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const FILE_SHARE_READ: DWORD = 0x00000001;
const FILE_SHARE_WRITE: DWORD = 0x00000002;
const CONSOLE_TEXTMODE_BUFFER: DWORD = 1;

const KEY_EVENT: WORD = 0x0001;
const VK_ESCAPE: WORD = 0x1b;

const FG_BLUE: WORD = 0x0001;
const FG_GREEN: WORD = 0x0002;
const FG_RED: WORD = 0x0004;
const FG_INTENSITY: WORD = 0x0008;

const COLOR_DIM: WORD = FG_BLUE | FG_GREEN;
const COLOR_WHITE: WORD = FG_RED | FG_GREEN | FG_BLUE | FG_INTENSITY;
const COLOR_GREEN: WORD = FG_GREEN | FG_INTENSITY;
const COLOR_YELLOW: WORD = FG_RED | FG_GREEN | FG_INTENSITY;
const COLOR_CYAN: WORD = FG_GREEN | FG_BLUE | FG_INTENSITY;
const COLOR_RED: WORD = FG_RED | FG_INTENSITY;

extern "kernel32" fn GetStdHandle(
    nStdHandle: DWORD,
) callconv(.winapi) ?HANDLE;

extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: HANDLE,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) BOOL;

extern "kernel32" fn GetConsoleCursorInfo(
    hConsoleOutput: HANDLE,
    lpConsoleCursorInfo: *CONSOLE_CURSOR_INFO,
) callconv(.winapi) BOOL;

extern "kernel32" fn SetConsoleCursorInfo(
    hConsoleOutput: HANDLE,
    lpConsoleCursorInfo: *const CONSOLE_CURSOR_INFO,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreateConsoleScreenBuffer(
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*const anyopaque,
    dwFlags: DWORD,
    lpScreenBufferData: ?*anyopaque,
) callconv(.winapi) ?HANDLE;

extern "kernel32" fn SetConsoleActiveScreenBuffer(
    hConsoleOutput: HANDLE,
) callconv(.winapi) BOOL;

extern "kernel32" fn SetConsoleScreenBufferSize(
    hConsoleOutput: HANDLE,
    dwSize: COORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn WriteConsoleOutputW(
    hConsoleOutput: HANDLE,
    lpBuffer: [*]const CHAR_INFO,
    dwBufferSize: COORD,
    dwBufferCoord: COORD,
    lpWriteRegion: *SMALL_RECT,
) callconv(.winapi) BOOL;

extern "kernel32" fn GetNumberOfConsoleInputEvents(
    hConsoleInput: HANDLE,
    lpcNumberOfEvents: *DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn ReadConsoleInputW(
    hConsoleInput: HANDLE,
    lpBuffer: [*]INPUT_RECORD,
    nLength: DWORD,
    lpNumberOfEventsRead: *DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn CloseHandle(
    hObject: HANDLE,
) callconv(.winapi) BOOL;

const render_width = 128;
const render_height = 42;

const Frame = struct {
    cells: [render_width * render_height]CHAR_INFO,

    fn init() Frame {
        var frame: Frame = undefined;
        frame.clear(COLOR_WHITE);
        return frame;
    }

    fn clear(self: *Frame, attributes: WORD) void {
        for (&self.cells) |*cell| {
            cell.* = .{
                .char = .{ .UnicodeChar = ' ' },
                .attributes = attributes,
            };
        }
    }

    fn put(
        self: *Frame,
        x: usize,
        y: usize,
        ch: u8,
        attributes: WORD,
    ) void {
        if (x >= render_width or y >= render_height) return;

        self.cells[y * render_width + x] = .{
            .char = .{ .UnicodeChar = @intCast(ch) },
            .attributes = attributes,
        };
    }

    fn write(
        self: *Frame,
        x: usize,
        y: usize,
        text: []const u8,
        attributes: WORD,
    ) void {
        if (y >= render_height) return;

        for (text, 0..) |ch, i| {
            if (x + i >= render_width) break;
            self.put(x + i, y, ch, attributes);
        }
    }

    fn writeFmt(
        self: *Frame,
        x: usize,
        y: usize,
        attributes: WORD,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write(x, y, text, attributes);
    }
};

const SpeedMode = enum {
    slow,
    normal,
    fast,
    turbo,

    fn ticksPerFrame(self: SpeedMode) usize {
        return switch (self) {
            .slow => 1,
            .normal => 1,
            .fast => 16,
            .turbo => 128,
        };
    }

    fn delayMs(self: SpeedMode) i64 {
        return switch (self) {
            .slow => 50,
            .normal => 16,
            .fast => 1,
            .turbo => 0,
        };
    }

    fn name(self: SpeedMode) []const u8 {
        return switch (self) {
            .slow => "slow",
            .normal => "normal",
            .fast => "fast",
            .turbo => "turbo",
        };
    }
};

const InputAction = struct {
    quit: bool = false,
    mode: ?SpeedMode = null,
};

const WinConsole = struct {
    input: HANDLE,
    original: HANDLE,
    render_buffer: HANDLE,
    original_cursor: CONSOLE_CURSOR_INFO,

    pub fn init() !WinConsole {
        const input = GetStdHandle(STD_INPUT_HANDLE) orelse
            return error.NoConsole;
        const original = GetStdHandle(STD_OUTPUT_HANDLE) orelse
            return error.NoConsole;

        if (isInvalidHandle(input) or isInvalidHandle(original)) {
            return error.NoConsole;
        }

        var screen_info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(original, &screen_info) == 0) {
            return error.NoConsole;
        }

        var cursor_info: CONSOLE_CURSOR_INFO = undefined;
        if (GetConsoleCursorInfo(original, &cursor_info) == 0) {
            cursor_info = .{
                .size = 25,
                .visible = 1,
            };
        }

        const render_buffer =
            CreateConsoleScreenBuffer(
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                null,
                CONSOLE_TEXTMODE_BUFFER,
                null,
            ) orelse return error.NoConsole;

        if (isInvalidHandle(render_buffer)) {
            return error.NoConsole;
        }

        errdefer _ = CloseHandle(render_buffer);

        const visible_width =
            screen_info.window.right - screen_info.window.left + 1;
        const visible_height =
            screen_info.window.bottom - screen_info.window.top + 1;

        const desired_width: SHORT = @max(
            visible_width,
            @as(SHORT, @intCast(render_width)),
        );
        const desired_height: SHORT = @max(
            visible_height,
            @as(SHORT, @intCast(render_height)),
        );

        _ = SetConsoleScreenBufferSize(
            render_buffer,
            .{
                .x = desired_width,
                .y = desired_height,
            },
        );

        var hidden_cursor = cursor_info;
        hidden_cursor.visible = 0;
        _ = SetConsoleCursorInfo(render_buffer, &hidden_cursor);

        return .{
            .input = input,
            .original = original,
            .render_buffer = render_buffer,
            .original_cursor = cursor_info,
        };
    }

    pub fn begin(self: *WinConsole) void {
        _ = SetConsoleActiveScreenBuffer(self.render_buffer);
    }

    pub fn end(self: *WinConsole) void {
        _ = SetConsoleActiveScreenBuffer(self.original);
        _ = SetConsoleCursorInfo(self.original, &self.original_cursor);
        _ = CloseHandle(self.render_buffer);
    }

    pub fn present(
        self: *WinConsole,
        frame: *const Frame,
    ) void {
        var region = SMALL_RECT{
            .left = 0,
            .top = 0,
            .right = @intCast(render_width - 1),
            .bottom = @intCast(render_height - 1),
        };

        _ = WriteConsoleOutputW(
            self.render_buffer,
            frame.cells[0..].ptr,
            .{
                .x = @intCast(render_width),
                .y = @intCast(render_height),
            },
            .{ .x = 0, .y = 0 },
            &region,
        );
    }

    pub fn pollInput(self: *WinConsole) InputAction {
        var action = InputAction{};

        var pending: DWORD = 0;
        if (GetNumberOfConsoleInputEvents(self.input, &pending) == 0) {
            return action;
        }

        while (pending != 0) {
            var records: [32]INPUT_RECORD = undefined;
            const request: DWORD = @min(
                pending,
                @as(DWORD, @intCast(records.len)),
            );

            var read: DWORD = 0;
            if (ReadConsoleInputW(
                self.input,
                records[0..].ptr,
                request,
                &read,
            ) == 0) {
                break;
            }

            for (records[0..@intCast(read)]) |record| {
                if (record.event_type != KEY_EVENT) continue;

                const key = record.event.key_event;
                if (key.key_down == 0) continue;

                if (key.virtual_key_code == VK_ESCAPE) {
                    action.quit = true;
                    continue;
                }

                const ch = key.char.ascii_char;
                switch (ch) {
                    'q', 'Q' => action.quit = true,
                    '1' => action.mode = .slow,
                    '2' => action.mode = .normal,
                    '3' => action.mode = .fast,
                    '4' => action.mode = .turbo,
                    else => {},
                }
            }

            if (GetNumberOfConsoleInputEvents(self.input, &pending) == 0) {
                break;
            }
        }

        return action;
    }

    fn isInvalidHandle(handle: HANDLE) bool {
        return @intFromPtr(handle) == std.math.maxInt(usize);
    }
};

// ============================================================================
// SHORELARK-LIKE WORLD
// ============================================================================

const population_size = 40;
const food_count = 60;
const generation_length = 2500;

const eye_cells = 9;
const input_count = eye_cells;

const pi: f32 = std.math.pi;
const tau: f32 = 2.0 * pi;

const fov_range: f32 = 0.25;
const fov_angle: f32 = pi + pi / 4.0;

const collision_radius: f32 = 0.01;

const speed_min: f32 = 0.001;
const speed_max: f32 = 0.005;
const speed_initial: f32 = 0.002;

// Bitman returns quantized i8 activations, so these are deliberately much
// smaller than the raw f32 constants in the article.
const speed_accel: f32 = 0.00025;
const rotation_accel: f32 = pi / 16.0;

// Bitman's ternary weights need a mutation large enough to cross a
// requantization boundary.
const mutation_chance: f32 = 0.01;
const mutation_coeff: f32 = 1.0;

const grid_width = 88;
const grid_height = 30;

const history_capacity = 28;
const initial_generation_log_capacity = 128;

const Vec2 = struct {
    x: f32,
    y: f32,
};

const Food = struct {
    pos: Vec2,
};

const Animal = struct {
    pos: Vec2,

    // 0 = up, PI/2 = right.
    rotation: f32,
    speed: f32,

    satiation: u64,
};

const GenerationStats = struct {
    generation: usize = 0,
    age: usize = 0,
    best: u64 = 0,
    best_index: usize = 0,
    worst: u64 = 0,
    average: f64 = 0.0,
    median: f64 = 0.0,
    stddev: f64 = 0.0,
    total: u64 = 0,
    zero_count: usize = 0,
    wall_bounces: u64 = 0,
};

const BrainDiagnostics = struct {
    output0_mean: f64 = 0.0,
    output1_mean: f64 = 0.0,
    output0_edge_count: usize = 0,
    output1_edge_count: usize = 0,
    speed_mean: f64 = 0.0,
};

const Simulation = struct {
    animals: [population_size]Animal,
    foods: [food_count]Food,

    parents: []Individual,
    children: []Individual,
    buffer: Individual.PerThreadBuffer,

    allocator: std.mem.Allocator,
    generation: usize,
    age: usize,

    last_stats: GenerationStats,
    best_ever: u64,
    generation_bounces: u64,

    // Full, dynamically-grown completed-generation log.
    // Q/Esc prints every entry before the process exits.
    stats_log: []GenerationStats,
    stats_len: usize,

    // Small rolling window used only by the live graph.
    history: [history_capacity]f64,
    history_len: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        random: std.Random,
    ) !Simulation {
        const layer_settings = [_]Individual.LayerSetting{
            .{
                .cols = input_count,
                .rows = 2 * input_count,
            },
            .{
                .cols = 2 * input_count,
                .rows = 2,
            },
        };

        const population_a = try allocPopulation(
            allocator,
            random,
            &layer_settings,
            population_size,
            .random,
        );
        errdefer freePopulation(allocator, population_a);

        const population_b = try allocPopulation(
            allocator,
            random,
            &layer_settings,
            population_size,
            .empty,
        );
        errdefer freePopulation(allocator, population_b);

        // Shorelark's original network uses ReLU. Keep Bitman's activation
        // fixed to ReLU too, so output mapping remains predictable.
        for (population_a) |*brain| {
            brain.activation_pfn_index = 0;
        }
        for (population_b) |*brain| {
            brain.activation_pfn_index = 0;
        }

        var buffer = try Individual.PerThreadBuffer.init(
            allocator,
            population_a[0].maxRowColLen(),
            population_a[0].maxElementsLen(),
        );
        errdefer buffer.deinit(allocator);

        const stats_log = try allocator.alloc(
            GenerationStats,
            initial_generation_log_capacity,
        );
        errdefer allocator.free(stats_log);

        var sim = Simulation{
            .animals = undefined,
            .foods = undefined,
            .parents = population_a,
            .children = population_b,
            .buffer = buffer,
            .allocator = allocator,
            .generation = 0,
            .age = 0,
            .last_stats = .{},
            .best_ever = 0,
            .generation_bounces = 0,
            .stats_log = stats_log,
            .stats_len = 0,
            .history = @splat(0.0),
            .history_len = 0,
        };

        sim.resetBodies(random);
        sim.resetFoods(random);

        return sim;
    }

    pub fn deinit(
        self: *Simulation,
        allocator: std.mem.Allocator,
    ) void {
        self.buffer.deinit(allocator);
        freePopulation(allocator, self.parents);
        freePopulation(allocator, self.children);
        allocator.free(self.stats_log);
        self.* = undefined;
    }

    pub fn step(
        self: *Simulation,
        random: std.Random,
    ) ?GenerationStats {
        self.processCollisions(random);
        self.processBrains();
        self.processMovements();

        self.age += 1;

        if (self.age >= generation_length) {
            return self.evolve(random);
        }

        return null;
    }

    fn processCollisions(
        self: *Simulation,
        random: std.Random,
    ) void {
        const radius_sq = collision_radius * collision_radius;

        for (&self.animals) |*animal| {
            for (&self.foods) |*food| {
                const dx = food.pos.x - animal.pos.x;
                const dy = food.pos.y - animal.pos.y;
                const dist_sq = dx * dx + dy * dy;

                if (dist_sq <= radius_sq) {
                    animal.satiation += 1;
                    food.pos = randomPosition(random);
                }
            }
        }
    }

    fn processBrains(self: *Simulation) void {
        for (
            &self.animals,
            self.parents,
        ) |*animal, *brain| {
            const vision = makeVision(
                animal,
                &self.foods,
            );

            _ = brain.forward(
                &vision,
                &self.buffer,
            );

            applyBrain(
                animal,
                brain.out,
            );
        }
    }

    fn processMovements(self: *Simulation) void {
        for (&self.animals) |*animal| {
            self.generation_bounces += @as(u64, moveAnimal(animal));
        }
    }

    fn evolve(
        self: *Simulation,
        random: std.Random,
    ) GenerationStats {
        const stats = self.currentStats();

        for (
            &self.animals,
            self.parents,
        ) |*animal, *brain| {
            // +1 keeps roulette-wheel selection defined even if nobody
            // managed to eat in the first generation.
            brain.fitness = animal.satiation + 1;
        }

        bitman.genetic_algorithm.evolve(
            random,
            self.parents,
            self.children,
            &self.buffer,
            .roulette_wheel,
            .uniform_crossover,
            .{
                .gaussian_mutation = .{
                    .chance = mutation_chance,
                    .coeff = mutation_coeff,
                },
            },
        );

        // Keep activation semantics fixed across generations.
        for (self.children) |*brain| {
            brain.activation_pfn_index = 0;
            brain.fitness = 0;
        }

        const temp = self.parents;
        self.parents = self.children;
        self.children = temp;

        self.last_stats = stats;
        self.best_ever = @max(self.best_ever, stats.best);
        self.appendStats(stats);
        self.pushHistory(stats.average);

        self.generation += 1;
        self.age = 0;
        self.generation_bounces = 0;

        // Only the genome survives. Physical state is born again.
        self.resetBodies(random);
        self.resetFoods(random);

        return stats;
    }

    fn currentStats(self: *const Simulation) GenerationStats {
        var sorted: [population_size]u64 = undefined;
        var total: u64 = 0;
        var best: u64 = 0;
        var best_index: usize = 0;
        var worst: u64 = std.math.maxInt(u64);
        var zero_count: usize = 0;

        for (self.animals, 0..) |animal, i| {
            const eaten = animal.satiation;
            sorted[i] = eaten;
            total += eaten;

            if (eaten > best) {
                best = eaten;
                best_index = i;
            }
            worst = @min(worst, eaten);
            if (eaten == 0) zero_count += 1;
        }

        // population_size is tiny (40), so an allocation-free insertion sort
        // is simpler and more stable across Zig versions than pulling in a
        // generic sort helper just to compute the median.
        for (1..population_size) |i| {
            const value = sorted[i];
            var j = i;
            while (j > 0 and sorted[j - 1] > value) {
                sorted[j] = sorted[j - 1];
                j -= 1;
            }
            sorted[j] = value;
        }

        const average =
            @as(f64, @floatFromInt(total)) /
            @as(f64, @floatFromInt(population_size));

        const middle = population_size / 2;
        const median = if (population_size % 2 == 0)
            (@as(f64, @floatFromInt(sorted[middle - 1])) +
                @as(f64, @floatFromInt(sorted[middle]))) / 2.0
        else
            @as(f64, @floatFromInt(sorted[middle]));

        var variance_sum: f64 = 0.0;
        for (self.animals) |animal| {
            const value = @as(f64, @floatFromInt(animal.satiation));
            const delta = value - average;
            variance_sum += delta * delta;
        }

        const variance = variance_sum /
            @as(f64, @floatFromInt(population_size));

        return .{
            .generation = self.generation,
            .age = self.age,
            .best = best,
            .best_index = best_index,
            .worst = worst,
            .average = average,
            .median = median,
            .stddev = @sqrt(variance),
            .total = total,
            .zero_count = zero_count,
            .wall_bounces = self.generation_bounces,
        };
    }

    fn brainDiagnostics(self: *const Simulation) BrainDiagnostics {
        var result = BrainDiagnostics{};

        for (self.animals, self.parents) |animal, brain| {
            result.speed_mean += @as(f64, @floatCast(animal.speed));

            if (brain.out.len >= 2) {
                const out0 = brain.out[0];
                const out1 = brain.out[1];

                result.output0_mean += @as(f64, @floatFromInt(out0));
                result.output1_mean += @as(f64, @floatFromInt(out1));

                // Both ends map to near-full control: 0 -> -1, 127 -> +1.
                if (out0 <= 7 or out0 >= 120) result.output0_edge_count += 1;
                if (out1 <= 7 or out1 >= 120) result.output1_edge_count += 1;
            }
        }

        const count = @as(f64, @floatFromInt(population_size));
        result.speed_mean /= count;
        result.output0_mean /= count;
        result.output1_mean /= count;
        return result;
    }

    fn appendStats(self: *Simulation, stats: GenerationStats) void {
        if (self.stats_len == self.stats_log.len) {
            const new_capacity = @max(self.stats_log.len * 2, 1);
            self.stats_log = self.allocator.realloc(
                self.stats_log,
                new_capacity,
            ) catch @panic("out of memory while growing generation history");
        }

        self.stats_log[self.stats_len] = stats;
        self.stats_len += 1;
    }

    fn pushHistory(
        self: *Simulation,
        value: f64,
    ) void {
        if (self.history_len < history_capacity) {
            self.history[self.history_len] = value;
            self.history_len += 1;
            return;
        }

        for (0..history_capacity - 1) |i| {
            self.history[i] = self.history[i + 1];
        }
        self.history[history_capacity - 1] = value;
    }

    fn resetBodies(
        self: *Simulation,
        random: std.Random,
    ) void {
        for (&self.animals) |*animal| {
            animal.* = .{
                .pos = randomPosition(random),
                .rotation = random.float(f32) * tau - pi,
                .speed = speed_initial,
                .satiation = 0,
            };
        }
    }

    fn resetFoods(
        self: *Simulation,
        random: std.Random,
    ) void {
        for (&self.foods) |*food| {
            food.* = .{
                .pos = randomPosition(random),
            };
        }
    }

    fn leaderIndex(self: *const Simulation) usize {
        var leader: usize = 0;
        var best: u64 = self.animals[0].satiation;

        for (self.animals[1..], 1..) |animal, i| {
            if (animal.satiation > best) {
                best = animal.satiation;
                leader = i;
            }
        }

        return leader;
    }

    fn currentAverage(self: *const Simulation) f64 {
        var total: u64 = 0;

        for (self.animals) |animal| {
            total += animal.satiation;
        }

        return @as(f64, @floatFromInt(total)) /
            @as(f64, @floatFromInt(population_size));
    }
};

fn allocPopulation(
    allocator: std.mem.Allocator,
    random: std.Random,
    layer_settings: []const Individual.LayerSetting,
    count: usize,
    comptime init_method: Individual.InitMethods,
) ![]Individual {
    const population = try allocator.alloc(
        Individual,
        count,
    );
    errdefer allocator.free(population);

    var initialized: usize = 0;
    errdefer {
        for (population[0..initialized]) |*individual| {
            individual.deinit(allocator);
        }
    }

    for (population) |*individual| {
        individual.* = try Individual.init(
            allocator,
            random,
            layer_settings,
            init_method,
        );
        initialized += 1;
    }

    return population;
}

fn freePopulation(
    allocator: std.mem.Allocator,
    population: []Individual,
) void {
    for (population) |*individual| {
        individual.deinit(allocator);
    }
    allocator.free(population);
}

fn randomPosition(random: std.Random) Vec2 {
    return .{
        .x = random.float(f32),
        .y = random.float(f32),
    };
}

// ============================================================================
// EYE
// ============================================================================

fn makeVision(
    animal: *const Animal,
    foods: *const [food_count]Food,
) [input_count]i8 {
    var cells: [eye_cells]f32 = @splat(0.0);

    for (foods) |food| {
        const dx = food.pos.x - animal.pos.x;
        const dy = food.pos.y - animal.pos.y;

        const dist_sq = dx * dx + dy * dy;
        if (dist_sq >= fov_range * fov_range) continue;

        const dist = @sqrt(dist_sq);

        // With our convention:
        //   0      = up
        //   PI/2   = right
        // atan2(dx, -dy) follows exactly that coordinate system.
        const absolute_angle = std.math.atan2(
            dx,
            -dy,
        );

        const relative_angle = wrapAngle(
            absolute_angle - animal.rotation,
        );

        const half_fov = fov_angle / 2.0;
        if (relative_angle < -half_fov or
            relative_angle > half_fov)
        {
            continue;
        }

        const unit =
            (relative_angle + half_fov) /
            fov_angle;

        var cell: usize = @intFromFloat(
            unit *
                @as(f32, @floatFromInt(eye_cells)),
        );

        cell = @min(cell, eye_cells - 1);

        const energy =
            (fov_range - dist) /
            fov_range;

        cells[cell] += energy;
    }

    var result: [input_count]i8 = @splat(0);

    for (cells, 0..) |energy, i| {
        const clamped = std.math.clamp(
            energy,
            0.0,
            1.0,
        );

        result[i] = @intFromFloat(
            clamped * 127.0,
        );
    }

    return result;
}

// ============================================================================
// BRAIN + PHYSICS
// ============================================================================

fn applyBrain(
    animal: *Animal,
    output: []const i8,
) void {
    std.debug.assert(output.len >= 2);

    const speed_control = outputControl(output[0]);
    const turn_control = outputControl(output[1]);

    animal.speed = std.math.clamp(
        animal.speed +
            speed_control * speed_accel,
        speed_min,
        speed_max,
    );

    animal.rotation = wrapAngle(
        animal.rotation +
            turn_control * rotation_accel,
    );
}

// ReLU output is quantized to roughly 0..127.
// Map it to the relative command range -1..+1.
//
//   0   -> -1
//   64  -> ~0
//   127 -> +1
fn outputControl(value: i8) f32 {
    const positive: i16 = std.math.clamp(
        @as(i16, value),
        0,
        127,
    );

    const unit =
        @as(f32, @floatFromInt(positive)) /
        127.0;

    return unit * 2.0 - 1.0;
}

fn moveAnimal(animal: *Animal) u8 {
    var bounces: u8 = 0;
    var vx =
        @sin(animal.rotation) *
        animal.speed;
    var vy =
        -@cos(animal.rotation) *
        animal.speed;

    var x = animal.pos.x + vx;
    var y = animal.pos.y + vy;

    // Bounce from walls instead of wrapping to the opposite edge.
    if (x < 0.0) {
        x = -x;
        vx = -vx;
        bounces += 1;
    } else if (x > 1.0) {
        x = 2.0 - x;
        vx = -vx;
        bounces += 1;
    }

    if (y < 0.0) {
        y = -y;
        vy = -vy;
        bounces += 1;
    } else if (y > 1.0) {
        y = 2.0 - y;
        vy = -vy;
        bounces += 1;
    }

    animal.pos.x = std.math.clamp(x, 0.0, 1.0);
    animal.pos.y = std.math.clamp(y, 0.0, 1.0);

    // Recover our angle convention from the reflected velocity.
    animal.rotation = wrapAngle(
        std.math.atan2(
            vx,
            -vy,
        ),
    );

    return bounces;
}

fn wrapAngle(value: f32) f32 {
    var angle = value;

    while (angle < -pi) {
        angle += tau;
    }

    while (angle >= pi) {
        angle -= tau;
    }

    return angle;
}

// ============================================================================
// RENDERING
// ============================================================================

fn render(
    console: *WinConsole,
    sim: *const Simulation,
    mode: SpeedMode,
) void {
    var frame = Frame.init();

    const leader_index = sim.leaderIndex();
    const leader = &sim.animals[leader_index];
    const leader_brain = &sim.parents[leader_index];
    const leader_vision = makeVision(
        leader,
        &sim.foods,
    );
    const current_stats = sim.currentStats();
    const brain_diag = sim.brainDiagnostics();

    frame.write(
        0,
        0,
        "BITMAN SHORELARK // pt4 live evolution // Win32 console",
        COLOR_CYAN,
    );

    frame.writeFmt(
        0,
        1,
        COLOR_WHITE,
        "generation {d:<6} age {d:>4}/{d:<4} population {d} food {d} speed-mode {s}",
        .{
            sim.generation,
            sim.age,
            generation_length,
            population_size,
            food_count,
            mode.name(),
        },
    );

    frame.writeFmt(
        0,
        2,
        COLOR_WHITE,
        "current: leader eaten {d:<5} avg {d:<8.3}    previous: best {d:<5} avg {d:<8.3}    best-ever {d}",
        .{
            leader.satiation,
            current_stats.average,
            sim.last_stats.best,
            sim.last_stats.average,
            sim.best_ever,
        },
    );

    frame.writeFmt(
        0,
        3,
        COLOR_DIM,
        "brain 9->18->2 | eye 9 cells / range .25 / fov 225deg | mutation {d:.2}% coeff {d:.2} | walls=bounce",
        .{
            mutation_chance * 100.0,
            mutation_coeff,
        },
    );

    frame.writeFmt(
        0,
        4,
        COLOR_WHITE,
        "population now: best {d:<4} median {d:<6.2} avg {d:<7.3} worst {d:<4} sd {d:<6.2} zero {d:<3} bounces {d}",
        .{
            current_stats.best,
            current_stats.median,
            current_stats.average,
            current_stats.worst,
            current_stats.stddev,
            current_stats.zero_count,
            current_stats.wall_bounces,
        },
    );

    frame.write(
        0,
        5,
        "keys: [1] slow  [2] normal  [3] fast  [4] turbo  [Q/Esc] print full history + quit",
        COLOR_YELLOW,
    );

    const grid_x: usize = 1;
    const grid_y: usize = 7;

    drawWorldBorder(
        &frame,
        grid_x,
        grid_y,
    );

    for (sim.foods) |food| {
        const gx, const gy = worldToGrid(food.pos);

        frame.put(
            grid_x + 1 + gx,
            grid_y + 1 + gy,
            '*',
            COLOR_GREEN,
        );
    }

    // Ordinary animals first.
    for (sim.animals, 0..) |animal, i| {
        if (i == leader_index) continue;

        const gx, const gy = worldToGrid(animal.pos);

        frame.put(
            grid_x + 1 + gx,
            grid_y + 1 + gy,
            directionChar(animal.rotation),
            COLOR_WHITE,
        );
    }

    // Current leader last, so it remains visible if cells overlap.
    {
        const gx, const gy = worldToGrid(leader.pos);

        frame.put(
            grid_x + 1 + gx,
            grid_y + 1 + gy,
            '@',
            COLOR_YELLOW,
        );
    }

    const panel_x: usize = 94;

    frame.write(
        panel_x,
        8,
        "CURRENT LEADER",
        COLOR_YELLOW,
    );

    frame.writeFmt(
        panel_x,
        10,
        COLOR_WHITE,
        "index      {d}",
        .{leader_index},
    );

    frame.writeFmt(
        panel_x,
        11,
        COLOR_WHITE,
        "eaten      {d}",
        .{leader.satiation},
    );

    frame.writeFmt(
        panel_x,
        12,
        COLOR_WHITE,
        "speed      {d:.5}",
        .{leader.speed},
    );

    frame.writeFmt(
        panel_x,
        13,
        COLOR_WHITE,
        "angle      {d:.1} deg",
        .{angleDegrees(leader.rotation)},
    );

    frame.write(
        panel_x,
        15,
        "eye",
        COLOR_CYAN,
    );

    frame.write(
        panel_x,
        16,
        "[",
        COLOR_WHITE,
    );

    var eye_chars: [eye_cells]u8 = undefined;
    for (leader_vision, 0..) |value, i| {
        eye_chars[i] = visionChar(value);
    }

    frame.write(
        panel_x + 1,
        16,
        eye_chars[0..],
        COLOR_GREEN,
    );

    frame.write(
        panel_x + 1 + eye_cells,
        16,
        "]",
        COLOR_WHITE,
    );

    if (leader_brain.out.len >= 2) {
        frame.writeFmt(
            panel_x,
            18,
            COLOR_WHITE,
            "brain[0]   {d:>4}",
            .{leader_brain.out[0]},
        );

        frame.writeFmt(
            panel_x,
            19,
            COLOR_WHITE,
            "brain[1]   {d:>4}",
            .{leader_brain.out[1]},
        );
    }

    frame.writeFmt(
        panel_x,
        20,
        COLOR_DIM,
        "out mean {d:>5.1}/{d:<5.1}",
        .{ brain_diag.output0_mean, brain_diag.output1_mean },
    );

    frame.writeFmt(
        panel_x,
        21,
        COLOR_DIM,
        "edge     {d:>3}%/{d:<3}%",
        .{
            brain_diag.output0_edge_count * 100 / population_size,
            brain_diag.output1_edge_count * 100 / population_size,
        },
    );

    frame.write(
        panel_x,
        23,
        "AVG / GENERATION",
        COLOR_CYAN,
    );

    drawHistory(
        &frame,
        panel_x,
        25,
        &sim.history,
        sim.history_len,
    );

    frame.write(
        panel_x,
        38,
        "* food",
        COLOR_GREEN,
    );

    frame.write(
        panel_x,
        39,
        "@ current leader",
        COLOR_YELLOW,
    );

    frame.write(
        panel_x,
        40,
        "^ > v < birds",
        COLOR_WHITE,
    );

    console.present(&frame);
}

fn drawWorldBorder(
    frame: *Frame,
    x: usize,
    y: usize,
) void {
    frame.put(x, y, '+', COLOR_DIM);

    for (0..grid_width) |ix| {
        frame.put(
            x + 1 + ix,
            y,
            '-',
            COLOR_DIM,
        );
    }

    frame.put(
        x + grid_width + 1,
        y,
        '+',
        COLOR_DIM,
    );

    for (0..grid_height) |iy| {
        frame.put(
            x,
            y + 1 + iy,
            '|',
            COLOR_DIM,
        );

        frame.put(
            x + grid_width + 1,
            y + 1 + iy,
            '|',
            COLOR_DIM,
        );
    }

    const bottom = y + grid_height + 1;

    frame.put(
        x,
        bottom,
        '+',
        COLOR_DIM,
    );

    for (0..grid_width) |ix| {
        frame.put(
            x + 1 + ix,
            bottom,
            '-',
            COLOR_DIM,
        );
    }

    frame.put(
        x + grid_width + 1,
        bottom,
        '+',
        COLOR_DIM,
    );
}

fn drawHistory(
    frame: *Frame,
    x: usize,
    y: usize,
    history: *const [history_capacity]f64,
    history_len: usize,
) void {
    const graph_height: usize = 10;

    if (history_len == 0) {
        frame.write(
            x,
            y + 2,
            "finish generation 0...",
            COLOR_DIM,
        );
        return;
    }

    var max_value: f64 = 1.0;

    for (history[0..history_len]) |value| {
        max_value = @max(
            max_value,
            value,
        );
    }

    for (0..history_len) |i| {
        const normalized = std.math.clamp(
            history[i] / max_value,
            0.0,
            1.0,
        );

        const height_f =
            normalized *
            @as(f64, @floatFromInt(graph_height - 1));

        const graph_y: usize =
            graph_height - 1 -
            @as(usize, @intFromFloat(@round(height_f)));

        frame.put(
            x + i,
            y + graph_y,
            '#',
            COLOR_GREEN,
        );
    }

    frame.writeFmt(
        x,
        y + graph_height + 1,
        COLOR_DIM,
        "max avg {d:.2}",
        .{max_value},
    );
}

fn worldToGrid(
    pos: Vec2,
) struct { usize, usize } {
    var x: usize = @intFromFloat(
        pos.x *
            @as(f32, @floatFromInt(grid_width)),
    );

    var y: usize = @intFromFloat(
        pos.y *
            @as(f32, @floatFromInt(grid_height)),
    );

    x = @min(x, grid_width - 1);
    y = @min(y, grid_height - 1);

    return .{ x, y };
}

fn directionChar(rotation: f32) u8 {
    var r = rotation;
    if (r < 0.0) r += tau;

    const sector: usize = @intFromFloat(
        (r + pi / 4.0) /
            (pi / 2.0),
    );

    return switch (sector % 4) {
        0 => '^',
        1 => '>',
        2 => 'v',
        3 => '<',
        else => unreachable,
    };
}

fn visionChar(value: i8) u8 {
    if (value >= 96) return '#';
    if (value >= 48) return '+';
    if (value > 0) return '.';
    return ' ';
}

fn angleDegrees(rotation: f32) f32 {
    var r = rotation;
    if (r < 0.0) r += tau;

    return r * 180.0 / pi;
}

fn printFinalReport(sim: *const Simulation) void {
    const current = sim.currentStats();

    std.debug.print(
        "\n\n================ BITMAN SHORELARK: FULL EVOLUTION HISTORY ================\n",
        .{},
    );
    std.debug.print(
        "completed generations: {d} | stopped at generation {d}, age {d}/{d}\n",
        .{ sim.stats_len, sim.generation, sim.age, generation_length },
    );
    std.debug.print(
        "brain {d}->{d}->2 | population {d} | food {d} respawning | mutation {d:.2}% coeff {d:.2}\n",
        .{
            input_count,
            2 * input_count,
            population_size,
            food_count,
            mutation_chance * 100.0,
            mutation_coeff,
        },
    );
    std.debug.print(
        "walls=bounce | generation ticks={d} | eye={d} cells range={d:.2} fov={d:.1}deg\n\n",
        .{ generation_length, eye_cells, fov_range, fov_angle * 180.0 / pi },
    );

    if (sim.stats_len == 0) {
        std.debug.print("No generation finished before quit.\n", .{});
    } else {
        std.debug.print(
            " gen | best(idx) |    avg | median | worst |  stddev | zero | total | bounces\n",
            .{},
        );
        std.debug.print(
            "-----+-----------+--------+--------+-------+---------+------+-------+--------\n",
            .{},
        );

        for (sim.stats_log[0..sim.stats_len]) |stats| {
            std.debug.print(
                "{d:>4} | {d:>4}({d:>2}) | {d:>6.2} | {d:>6.2} | {d:>5} | {d:>7.2} | {d:>4} | {d:>5} | {d}\n",
                .{
                    stats.generation,
                    stats.best,
                    stats.best_index,
                    stats.average,
                    stats.median,
                    stats.worst,
                    stats.stddev,
                    stats.zero_count,
                    stats.total,
                    stats.wall_bounces,
                },
            );
        }

        const first = sim.stats_log[0];
        const last = sim.stats_log[sim.stats_len - 1];

        var best_avg = sim.stats_log[0];
        var best_peak = sim.stats_log[0];
        for (sim.stats_log[1..sim.stats_len]) |stats| {
            if (stats.average > best_avg.average) best_avg = stats;
            if (stats.best > best_peak.best) best_peak = stats;
        }

        const recent_count = @min(sim.stats_len, 10);
        const recent_start = sim.stats_len - recent_count;
        var recent_avg_sum: f64 = 0.0;
        for (sim.stats_log[recent_start..sim.stats_len]) |stats| {
            recent_avg_sum += stats.average;
        }
        const recent_avg = recent_avg_sum /
            @as(f64, @floatFromInt(recent_count));

        std.debug.print("\n------------------------------ SUMMARY ------------------------------------\n", .{});
        std.debug.print(
            "first completed : gen {d}  best {d}  avg {d:.3}  median {d:.3}\n",
            .{ first.generation, first.best, first.average, first.median },
        );
        std.debug.print(
            "last completed  : gen {d}  best {d}  avg {d:.3}  median {d:.3}\n",
            .{ last.generation, last.best, last.average, last.median },
        );
        std.debug.print(
            "best avg ever   : gen {d}  avg {d:.3}  best {d}\n",
            .{ best_avg.generation, best_avg.average, best_avg.best },
        );
        std.debug.print(
            "best peak ever  : gen {d}  best {d}  avg {d:.3}\n",
            .{ best_peak.generation, best_peak.best, best_peak.average },
        );
        std.debug.print(
            "recent {d} avg   : {d:.3}\n",
            .{ recent_count, recent_avg },
        );
        std.debug.print(
            "avg delta       : {d:.3} food/bird ({d:.3} -> {d:.3})\n",
            .{ last.average - first.average, first.average, last.average },
        );

        if (first.average > 0.0) {
            std.debug.print(
                "avg ratio       : {d:.3}x of first completed generation\n",
                .{last.average / first.average},
            );
        }
    }

    std.debug.print("\n------------------------- CURRENT PARTIAL GEN ------------------------------\n", .{});
    std.debug.print(
        "generation {d}  age {d}/{d} ({d:.1}%)\n",
        .{
            current.generation,
            current.age,
            generation_length,
            @as(f64, @floatFromInt(current.age)) * 100.0 /
                @as(f64, @floatFromInt(generation_length)),
        },
    );
    std.debug.print(
        "best {d} (bird {d}) | avg {d:.3} | median {d:.3} | worst {d} | stddev {d:.3} | zero {d}\n",
        .{
            current.best,
            current.best_index,
            current.average,
            current.median,
            current.worst,
            current.stddev,
            current.zero_count,
        },
    );
    std.debug.print(
        "food eaten total {d} | wall bounces {d}\n",
        .{ current.total, current.wall_bounces },
    );

    if (current.age > 0) {
        const scale = @as(f64, @floatFromInt(generation_length)) /
            @as(f64, @floatFromInt(current.age));
        std.debug.print(
            "rough linear pace: best ~{d:.1}, avg ~{d:.1} by tick {d} (diagnostic only)\n",
            .{
                @as(f64, @floatFromInt(current.best)) * scale,
                current.average * scale,
                generation_length,
            },
        );
    }

    const brain_diag = sim.brainDiagnostics();
    std.debug.print(
        "brain now: output mean {d:.2}/{d:.2}, edge-control {d}/{d} birds, mean speed {d:.6}\n",
        .{
            brain_diag.output0_mean,
            brain_diag.output1_mean,
            brain_diag.output0_edge_count,
            brain_diag.output1_edge_count,
            brain_diag.speed_mean,
        },
    );
    std.debug.print(
        "===========================================================================\n",
        .{},
    );
}

// ============================================================================
// MAIN
// ============================================================================

pub fn main(
    init: std.process.Init,
) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(
        init.arena.allocator(),
    );

    var mode: SpeedMode = .normal;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--slow")) {
            mode = .slow;
        } else if (std.mem.eql(u8, arg, "--fast")) {
            mode = .fast;
        } else if (std.mem.eql(u8, arg, "--turbo")) {
            mode = .turbo;
        }
    }

    var prng: std.Random.DefaultPrng =
        .init(0x5348_4f52_454c_4152);

    const random = prng.random();

    var sim = try Simulation.init(
        allocator,
        random,
    );
    defer sim.deinit(allocator);

    var console = try WinConsole.init();

    console.begin();
    var console_active = true;

    defer {
        if (console_active) {
            console.end();
        }
    }

    render(
        &console,
        &sim,
        mode,
    );

    var running = true;

    while (running) {
        const action = console.pollInput();

        if (action.quit) {
            running = false;
            break;
        }

        if (action.mode) |new_mode| {
            mode = new_mode;
        }

        for (0..mode.ticksPerFrame()) |_| {
            _ = sim.step(random);
        }

        render(
            &console,
            &sim,
            mode,
        );

        const delay_ms = mode.delayMs();
        if (delay_ms != 0) {
            io.sleep(
                .fromMilliseconds(delay_ms),
                .awake,
            ) catch {};
        }
    }

    console.end();
    console_active = false;

    printFinalReport(&sim);
}
