const std = @import("std");

const bitman = @import("bitman");
const Individual = bitman.Individual;

// ============================================================
// RAW WIN32 CONSOLE
// ============================================================

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

const STD_ERROR_HANDLE: DWORD = 0xfffffff4;

const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;

const FILE_SHARE_READ: DWORD = 0x00000001;
const FILE_SHARE_WRITE: DWORD = 0x00000002;

const CONSOLE_TEXTMODE_BUFFER: DWORD = 1;

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

extern "kernel32" fn CloseHandle(
    hObject: HANDLE,
) callconv(.winapi) BOOL;

const render_width = 112;
const render_height = 38;

const Frame = struct {
    cells: [render_width * render_height]CHAR_INFO,

    fn init(attributes: WORD) Frame {
        var frame: Frame = undefined;
        frame.clear(attributes);
        return frame;
    }

    fn clear(
        self: *Frame,
        attributes: WORD,
    ) void {
        for (&self.cells) |*cell| {
            cell.* = .{
                .char = .{
                    .UnicodeChar = ' ',
                },
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
        if (x >= render_width or y >= render_height) {
            return;
        }

        self.cells[y * render_width + x] = .{
            .char = .{
                .UnicodeChar = @intCast(ch),
            },
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
        if (y >= render_height) {
            return;
        }

        for (text, 0..) |ch, i| {
            if (x + i >= render_width) {
                break;
            }

            self.put(
                x + i,
                y,
                ch,
                attributes,
            );
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

        const text = std.fmt.bufPrint(
            &buf,
            fmt,
            args,
        ) catch return;

        self.write(
            x,
            y,
            text,
            attributes,
        );
    }
};

const WinConsole = struct {
    original: HANDLE,
    render_buffer: HANDLE,

    attributes: WORD,
    original_cursor: CONSOLE_CURSOR_INFO,

    pub fn init() !WinConsole {
        const original =
            GetStdHandle(STD_ERROR_HANDLE) orelse
            return error.NoConsole;

        if (isInvalidHandle(original)) {
            return error.NoConsole;
        }

        var screen_info: CONSOLE_SCREEN_BUFFER_INFO = undefined;

        if (GetConsoleScreenBufferInfo(
            original,
            &screen_info,
        ) == 0) {
            return error.NoConsole;
        }

        var cursor_info: CONSOLE_CURSOR_INFO = undefined;

        if (GetConsoleCursorInfo(
            original,
            &cursor_info,
        ) == 0) {
            cursor_info = .{
                .size = 25,
                .visible = 1,
            };
        }

        const maybe_render =
            CreateConsoleScreenBuffer(
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                null,
                CONSOLE_TEXTMODE_BUFFER,
                null,
            );

        const render_buffer =
            maybe_render orelse
            return error.NoConsole;

        if (isInvalidHandle(render_buffer)) {
            return error.NoConsole;
        }

        const visible_width =
            screen_info.window.right -
            screen_info.window.left +
            1;

        const visible_height =
            screen_info.window.bottom -
            screen_info.window.top +
            1;

        const desired_width: SHORT =
            @max(
                visible_width,
                @as(
                    SHORT,
                    @intCast(render_width),
                ),
            );

        const desired_height: SHORT =
            @max(
                visible_height,
                @as(
                    SHORT,
                    @intCast(render_height),
                ),
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

        _ = SetConsoleCursorInfo(
            render_buffer,
            &hidden_cursor,
        );

        return .{
            .original = original,
            .render_buffer = render_buffer,

            .attributes = screen_info.attributes,
            .original_cursor = cursor_info,
        };
    }

    pub fn begin(
        self: *WinConsole,
    ) void {
        _ = SetConsoleActiveScreenBuffer(
            self.render_buffer,
        );
    }

    pub fn end(
        self: *WinConsole,
    ) void {
        _ = SetConsoleActiveScreenBuffer(
            self.original,
        );

        _ = SetConsoleCursorInfo(
            self.original,
            &self.original_cursor,
        );

        _ = CloseHandle(
            self.render_buffer,
        );
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
            .{
                .x = 0,
                .y = 0,
            },
            &region,
        );
    }

    fn isInvalidHandle(
        handle: HANDLE,
    ) bool {
        return @intFromPtr(handle) ==
            std.math.maxInt(usize);
    }
};

// ============================================================
// SHORELARK-LIKE EVOLUTION WORLD
//
// Adapted for Bitman's ternary network.
//
// World:
//   - [0, 1) x [0, 1)
//   - toroidal / wrap-around
//
// Creature:
//   eye[9]
//       |
//       v
//   9 -> 18 -> 2
//              |
//              +-> relative speed
//              +-> relative rotation
//
// Fitness:
//   food eaten.
//
// Every generation:
//   - organisms get new random physical state
//   - food gets new random positions
//   - brains survive through the genome only
// ============================================================

const population_size = 48;
const food_count = 60;

const generations = 500;
const generation_length = 2500;

// Every genome is evaluated independently on the SAME four training
// episode seeds for a generation.  The seeds change next generation,
// so genomes cannot win by sharing/stealing food or by memorizing one
// permanent layout.
const train_world_count = 4;

// The champion from each training generation is evaluated again on
// the exact same fixed-seed worlds. These scores NEVER participate
// in selection; they exist only to measure real progress with much
// less generation-to-generation noise.
const eval_world_count = 8;
const eval_seeds = [_]u64{
    0x4556_414c_0000_0001,
    0x4556_414c_0000_0002,
    0x4556_414c_0000_0003,
    0x4556_414c_0000_0004,
    0x4556_414c_0000_0005,
    0x4556_414c_0000_0006,
    0x4556_414c_0000_0007,
    0x4556_414c_0000_0008,
};

// TUI.
//
// A watched generation renders only every N simulation ticks.
// The simulation itself still runs every tick.
const preview_every = 10;
const preview_stride = 10;
const preview_delay_ms = 5;

// Eye settings from Shorelark.
const eye_cells = 9;
const input_count = eye_cells;

const pi: f32 = std.math.pi;
const tau: f32 = 2.0 * pi;

const fov_range: f32 = 0.25;
const fov_angle: f32 =
    pi + pi / 4.0;

// Physics.
const collision_radius: f32 = 0.015;

const speed_min: f32 = 0.001;
const speed_max: f32 = 0.005;
const speed_initial: f32 = 0.002;

// Shorelark's neural network produces ordinary f32 values.
//
// Bitman produces quantized i8 outputs, so applying an acceleration
// of 0.2 directly would slam the speed into min/max immediately.
//
// These values retain the same "relative speed / relative rotation"
// semantics but work better with the quantized output.
const speed_accel: f32 = 0.00025;
const rotation_accel: f32 =
    pi / 16.0;

// Shorelark used GaussianMutation(0.01, 0.3).
//
// Bitman however mutates a dequantized ternary value and then
// requantizes back to {-1, 0, 1}.  A coefficient below ~0.5 can
// therefore mutate a float without changing the resulting ternary
// gene at all.
//
// Keep the 1% mutation probability, but allow enough movement to
// actually cross a ternary quantization boundary.
const mutation_chance: f32 = 0.01;
const mutation_coeff: f32 = 1.0;

// Display world.
const grid_width = 80;
const grid_height = 26;

const Vec2 = struct {
    x: f32,
    y: f32,
};

const Food = struct {
    pos: Vec2,
};

const Creature = struct {
    pos: Vec2,

    // 0      = up
    // PI/2   = right
    // PI     = down
    // 3PI/2  = left
    rotation: f32,

    speed: f32,

    // Fitness-producing state.
    eaten: usize,
};

const PopulationStats = struct {
    best_index: usize,

    // Scores are food-per-episode averages, so train/eval curves use
    // the same unit even though training uses 4 worlds and eval uses 8.
    best_eaten: f64,
    average_eaten: f64,
};

// ============================================================
// MAIN
// ============================================================

pub fn main(
    init: std.process.Init,
) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args =
        try init.minimal.args.toSlice(
            init.arena.allocator(),
        );

    const fast_mode =
        args.len >= 2 and
        std.mem.eql(
            u8,
            args[1],
            "--fast",
        );

    var prng: std.Random.DefaultPrng =
        .init(0x53_48_4f_52_45_4c_41_52);

    const random =
        prng.random();

    const layer_settings =
        [_]Individual.LayerSetting{
            .{
                .cols = input_count,
                .rows = 18,
            },
            .{
                .cols = 18,
                .rows = 2,
            },
        };

    const population_a =
        try allocPopulation(
            gpa,
            random,
            &layer_settings,
            population_size,
            .random,
        );

    defer freePopulation(
        gpa,
        population_a,
    );

    const population_b =
        try allocPopulation(
            gpa,
            random,
            &layer_settings,
            population_size,
            .empty,
        );

    defer freePopulation(
        gpa,
        population_b,
    );

    var buffer: Individual.PerThreadBuffer =
        try .init(
            gpa,
            population_a[0].maxRowColLen(),
            population_a[0].maxElementsLen(),
        );

    defer buffer.deinit(gpa);

    var parents: []Individual =
        population_a;

    var children: []Individual =
        population_b;

    var console =
        try WinConsole.init();

    console.begin();

    var console_active = true;

    defer {
        if (console_active) {
            console.end();
        }
    }

    var last_stats = PopulationStats{
        .best_index = 0,
        .best_eaten = 0.0,
        .average_eaten = 0.0,
    };

    var average_history: [generations]f64 = @splat(0.0);
    var best_history: [generations]f64 = @splat(0.0);
    var eval_history: [generations]f64 = @splat(0.0);
    var history_len: usize = 0;

    var best_train_ever: f64 = 0.0;
    var last_eval_score: f64 = 0.0;
    var best_eval_ever: f64 = 0.0;

    for (0..generations) |generation| {
        // ----------------------------------------------------
        // TRAIN
        //
        // Every individual gets its own Creature/Food state.
        // Every individual receives the same 4 episode seeds.
        // There is no shared food array and therefore no competition
        // or population-order effect in the fitness measurement.
        // ----------------------------------------------------

        const stats =
            evaluateTrainingPopulation(
                parents,
                &buffer,
                generation,
            );

        // Fixed eight-world benchmark of this generation's training
        // champion.  Measurement only; never used for selection.
        const eval_score =
            evaluateChampion(
                &parents[stats.best_index],
                &buffer,
            );

        average_history[generation] =
            stats.average_eaten;

        best_history[generation] =
            stats.best_eaten;

        eval_history[generation] =
            eval_score;

        history_len =
            generation + 1;

        last_stats = stats;
        last_eval_score = eval_score;

        best_train_ever =
            @max(
                best_train_ever,
                stats.best_eaten,
            );

        best_eval_ever =
            @max(
                best_eval_ever,
                eval_score,
            );

        // The TUI is a completely separate replay.  It never changes
        // fitness.  We watch one champion in one independent preview
        // world because drawing 128 independent food worlds on one
        // screen would be misleading.
        const watch =
            !fast_mode and
            (generation % preview_every == 0 or
                generation + 1 == generations);

        if (watch) {
            previewChampion(
                io,
                &console,
                &parents[stats.best_index],
                &buffer,
                generation,
                stats,
                best_train_ever,
                eval_score,
                best_eval_ever,
                &average_history,
                &best_history,
                &eval_history,
                history_len,
            );
        }

        if (generation + 1 == generations) {
            break;
        }

        bitman.genetic_algorithm.evolve(
            random,
            parents,
            children,
            &buffer,
            .roulette_wheel,
            .uniform_crossover,
            .{
                .gaussian_mutation = .{
                    .chance = mutation_chance,
                    .coeff = mutation_coeff,
                },
            },
        );

        // One-member elitism: exact training champion survives.
        copyGenome(
            &parents[stats.best_index],
            &children[0],
        );

        const tmp =
            parents;

        parents =
            children;

        children =
            tmp;
    }

    console.end();
    console_active = false;

    printLearningCurve(
        &average_history,
        &best_history,
        &eval_history,
        history_len,
    );

    std.debug.print(
        "\n" ++
            "================ BITMAN SHORELARK =================\n" ++
            "generations       : {d}\n" ++
            "population        : {d}\n" ++
            "generation ticks  : {d}\n" ++
            "brain             : 9 -> 18 -> 2\n" ++
            "ternary genes     : {d}\n" ++
            "train worlds      : {d} common seeds / generation\n" ++
            "last train best   : {d:.3}\n" ++
            "last train avg    : {d:.3}\n" ++
            "best train ever   : {d:.3}\n" ++
            "eval worlds       : {d} fixed seeds\n" ++
            "last eval champ   : {d:.3}\n" ++
            "best eval champ   : {d:.3}\n" ++
            "mutation          : {d:.2}% / coeff {d:.2}\n" ++
            "===================================================\n\n",
        .{
            generations,
            population_size,
            generation_length,
            genomeValueCount(),
            train_world_count,
            last_stats.best_eaten,
            last_stats.average_eaten,
            best_train_ever,
            eval_world_count,
            last_eval_score,
            best_eval_ever,
            mutation_chance * 100.0,
            mutation_coeff,
        },
    );
}

// ============================================================
// POPULATION
// ============================================================

fn allocPopulation(
    allocator: std.mem.Allocator,
    random: std.Random,
    layer_settings: []const Individual.LayerSetting,
    count: usize,
    comptime init_method: Individual.InitMethods,
) ![]Individual {
    const population =
        try allocator.alloc(
            Individual,
            count,
        );

    errdefer allocator.free(
        population,
    );

    var initialized: usize = 0;

    errdefer {
        for (population[0..initialized]) |*individual| {
            individual.deinit(
                allocator,
            );
        }
    }

    for (population) |*individual| {
        individual.* =
            try .init(
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
        individual.deinit(
            allocator,
        );
    }

    allocator.free(
        population,
    );
}

// Exact genome copy.
//
// Individual and BitLinear already own their destination allocations;
// only the actual packed data / scale metadata gets copied.
fn copyGenome(
    src: *const Individual,
    dst: *Individual,
) void {
    std.debug.assert(
        src.layers.len ==
            dst.layers.len,
    );

    for (
        src.layers,
        dst.layers,
    ) |*src_layer, *dst_layer| {
        std.debug.assert(
            src_layer.weights.len ==
                dst_layer.weights.len,
        );

        @memcpy(
            dst_layer.weights,
            src_layer.weights,
        );

        dst_layer.weights_gain =
            src_layer.weights_gain;

        dst_layer.activation_gain =
            src_layer.activation_gain;
    }

    dst.activation_pfn_index =
        src.activation_pfn_index;

    dst.fitness = 0;
}

// ============================================================
// WORLD RESET
// ============================================================

fn resetCreatures(
    random: std.Random,
    creatures: *[population_size]Creature,
) void {
    for (creatures) |*creature| {
        creature.* = .{
            .pos = randomPosition(
                random,
            ),

            .rotation = random.float(f32) *
                tau,

            .speed = speed_initial,

            .eaten = 0,
        };
    }
}

fn resetFoods(
    random: std.Random,
    foods: *[food_count]Food,
) void {
    for (foods) |*food| {
        food.* = .{
            .pos = randomPosition(
                random,
            ),
        };
    }
}

fn randomPosition(
    random: std.Random,
) Vec2 {
    return .{
        .x = random.float(f32),
        .y = random.float(f32),
    };
}

// ============================================================
// INDEPENDENT TRAINING EPISODES
// ============================================================

fn evaluateTrainingPopulation(
    population: []Individual,
    buffer: *Individual.PerThreadBuffer,
    generation: usize,
) PopulationStats {
    std.debug.assert(
        population.len == population_size,
    );

    var best_index: usize = 0;
    var best_total: usize = 0;
    var population_total: usize = 0;

    for (population, 0..) |*individual, index| {
        var individual_total: usize = 0;

        // SAME seeds for every genome in this generation.
        // Each runEpisode() creates private Creature/Food state.
        for (0..train_world_count) |world_index| {
            const eaten =
                runEpisode(
                    individual,
                    buffer,
                    trainingSeed(
                        generation,
                        world_index,
                    ),
                );

            individual_total += eaten;
        }

        // Roulette wheel only cares about relative fitness.  The +1
        // guarantees a valid total even if generation 0 eats nothing.
        individual.fitness =
            1 +
            @as(
                u64,
                @intCast(individual_total),
            );

        population_total +=
            individual_total;

        if (individual_total > best_total) {
            best_total = individual_total;
            best_index = index;
        }
    }

    const denom =
        @as(
            f64,
            @floatFromInt(train_world_count),
        );

    const population_denom =
        @as(
            f64,
            @floatFromInt(
                population_size * train_world_count,
            ),
        );

    return .{
        .best_index = best_index,
        .best_eaten = @as(
            f64,
            @floatFromInt(best_total),
        ) / denom,
        .average_eaten = @as(
            f64,
            @floatFromInt(population_total),
        ) / population_denom,
    };
}

fn runEpisode(
    individual: *Individual,
    buffer: *Individual.PerThreadBuffer,
    seed: u64,
) usize {
    var episode_prng: std.Random.DefaultPrng =
        .init(seed);

    const random =
        episode_prng.random();

    var creature = Creature{
        .pos = randomPosition(random),
        .rotation = random.float(f32) * tau,
        .speed = speed_initial,
        .eaten = 0,
    };

    var foods: [food_count]Food =
        undefined;

    resetFoods(
        random,
        &foods,
    );

    for (0..generation_length) |_| {
        const vision =
            senseAndEat(
                random,
                &creature,
                &foods,
            );

        _ = individual.forward(
            &vision,
            buffer,
        );

        applyBrain(
            &creature,
            individual.out,
        );

        moveCreature(
            &creature,
        );
    }

    return creature.eaten;
}

// ------------------------------------------------------------
// Training seeds
// ------------------------------------------------------------
//
// One generation == one common exam sheet of four worlds.
// Next generation gets a different exam sheet.
//
// splitMix64 gives us deterministic, well-separated seeds without
// sharing a mutable RNG stream between individuals.

fn trainingSeed(
    generation: usize,
    world_index: usize,
) u64 {
    const serial =
        @as(u64, @intCast(generation)) *%
        @as(u64, train_world_count) +%
        @as(u64, @intCast(world_index));

    return splitMix64(
        0x5452_4149_4e00_0000 +% serial,
    );
}

fn previewSeed(
    generation: usize,
) u64 {
    return splitMix64(
        0x5052_4556_4945_5700 +%
            @as(u64, @intCast(generation)),
    );
}

fn splitMix64(
    input: u64,
) u64 {
    var z =
        input +% 0x9E37_79B9_7F4A_7C15;

    z =
        (z ^ (z >> 30)) *%
        0xBF58_476D_1CE4_E5B9;

    z =
        (z ^ (z >> 27)) *%
        0x94D0_49BB_1331_11EB;

    return z ^ (z >> 31);
}

// ============================================================
// FIXED-SEED CHAMPION EVALUATION
// ============================================================

fn evaluateChampion(
    champion: *Individual,
    buffer: *Individual.PerThreadBuffer,
) f64 {
    var total_eaten: usize = 0;

    for (eval_seeds) |seed| {
        total_eaten +=
            runEpisode(
                champion,
                buffer,
                seed,
            );
    }

    return @as(
        f64,
        @floatFromInt(total_eaten),
    ) / @as(
        f64,
        @floatFromInt(eval_world_count),
    );
}

// ============================================================
// CHAMPION PREVIEW -- DISPLAY ONLY
// ============================================================

fn previewChampion(
    io: std.Io,
    console: *WinConsole,
    champion: *Individual,
    buffer: *Individual.PerThreadBuffer,
    generation: usize,
    train_stats: PopulationStats,
    best_train_ever: f64,
    eval_score: f64,
    best_eval_ever: f64,
    average_history: *const [generations]f64,
    best_history: *const [generations]f64,
    eval_history: *const [generations]f64,
    history_len: usize,
) void {
    var preview_prng: std.Random.DefaultPrng =
        .init(previewSeed(generation));

    const random =
        preview_prng.random();

    var creature = Creature{
        .pos = randomPosition(random),
        .rotation = random.float(f32) * tau,
        .speed = speed_initial,
        .eaten = 0,
    };

    var foods: [food_count]Food =
        undefined;

    resetFoods(
        random,
        &foods,
    );

    for (0..generation_length) |tick| {
        const vision =
            senseAndEat(
                random,
                &creature,
                &foods,
            );

        _ = champion.forward(
            &vision,
            buffer,
        );

        applyBrain(
            &creature,
            champion.out,
        );

        moveCreature(
            &creature,
        );

        const age = tick + 1;

        if (age % preview_stride == 0 or
            age == generation_length)
        {
            renderTui(
                console,
                champion,
                &creature,
                &foods,
                generation,
                age,
                train_stats,
                best_train_ever,
                eval_score,
                best_eval_ever,
                average_history,
                best_history,
                eval_history,
                history_len,
            );

            io.sleep(
                .fromMilliseconds(
                    preview_delay_ms,
                ),
                .awake,
            ) catch {};
        }
    }

    io.sleep(
        .fromMilliseconds(180),
        .awake,
    ) catch {};
}

// ============================================================
// EYE
// ============================================================
//
// 9 cells span 225 degrees.
//
// Cell 0                 Cell 8
//   \                      /
//    \                    /
//     \                  /
//            ^
//            |
//         creature
//
// Each cell accumulates:
//     1 - distance / FOV_RANGE
//
// Multiple foods can land in the same cell.
// Bitman's i8 input saturates the final result to 127.
// ============================================================

fn senseAndEat(
    random: std.Random,
    creature: *Creature,
    foods: *[food_count]Food,
) [input_count]i8 {
    var cells: [eye_cells]f32 =
        @splat(0.0);

    for (foods) |*food| {
        var dx =
            wrappedDelta(
                creature.pos.x,
                food.pos.x,
            );

        var dy =
            wrappedDelta(
                creature.pos.y,
                food.pos.y,
            );

        var dist_sq =
            dx * dx +
            dy * dy;

        // ----------------------------------------------------
        // Food collision.
        //
        // Food immediately respawns at another random position.
        // ----------------------------------------------------

        if (dist_sq <=
            collision_radius *
                collision_radius)
        {
            creature.eaten += 1;

            food.pos =
                randomPosition(
                    random,
                );

            // The food has moved; this creature sees the
            // newly-spawned food during this same sense pass.

            dx =
                wrappedDelta(
                    creature.pos.x,
                    food.pos.x,
                );

            dy =
                wrappedDelta(
                    creature.pos.y,
                    food.pos.y,
                );

            dist_sq =
                dx * dx +
                dy * dy;
        }

        accumulateVision(
            &cells,
            creature.rotation,
            dx,
            dy,
            dist_sq,
        );
    }

    return quantizeVision(
        &cells,
    );
}

// Pure vision version used by TUI.
fn makeVision(
    creature: *const Creature,
    foods: *const [food_count]Food,
) [input_count]i8 {
    var cells: [eye_cells]f32 =
        @splat(0.0);

    for (foods) |food| {
        const dx =
            wrappedDelta(
                creature.pos.x,
                food.pos.x,
            );

        const dy =
            wrappedDelta(
                creature.pos.y,
                food.pos.y,
            );

        const dist_sq =
            dx * dx +
            dy * dy;

        accumulateVision(
            &cells,
            creature.rotation,
            dx,
            dy,
            dist_sq,
        );
    }

    return quantizeVision(
        &cells,
    );
}

fn accumulateVision(
    cells: *[eye_cells]f32,
    rotation: f32,
    dx: f32,
    dy: f32,
    dist_sq: f32,
) void {
    const range_sq =
        fov_range *
        fov_range;

    if (dist_sq >= range_sq) {
        return;
    }

    const dist =
        @sqrt(dist_sq);

    // Our rotation convention:
    //
    //       up = 0
    //     right = +PI/2
    //
    // atan2 normally measures around +X.
    //
    // atan2(dx, -dy) gives exactly the convention above.

    const absolute_angle =
        std.math.atan2(
            dx,
            -dy,
        );

    const relative_angle =
        wrapAngle(
            absolute_angle -
                rotation,
        );

    const half_fov =
        fov_angle / 2.0;

    if (relative_angle <
        -half_fov or
        relative_angle >
            half_fov)
    {
        return;
    }

    // [-half_fov, +half_fov]
    //       ->
    // [0, 1]
    //       ->
    // eye cell index.

    const unit =
        (relative_angle +
            half_fov) /
        fov_angle;

    const cell_float =
        unit *
        @as(
            f32,
            @floatFromInt(
                eye_cells,
            ),
        );

    var cell_index: usize =
        @intFromFloat(
            cell_float,
        );

    cell_index =
        @min(
            cell_index,
            eye_cells - 1,
        );

    const energy =
        (fov_range -
            dist) /
        fov_range;

    cells[cell_index] +=
        energy;
}

fn quantizeVision(
    cells: *const [eye_cells]f32,
) [input_count]i8 {
    var input: [input_count]i8 =
        @splat(0);

    for (
        cells,
        0..,
    ) |energy, i| {
        const clamped =
            std.math.clamp(
                energy,
                0.0,
                1.0,
            );

        input[i] =
            @intFromFloat(
                clamped *
                    127.0,
            );
    }

    return input;
}

// ============================================================
// BRAIN / MOVEMENT
// ============================================================

fn applyBrain(
    creature: *Creature,
    output: []const i8,
) void {
    std.debug.assert(
        output.len >= 2,
    );

    const speed_control =
        outputControl(
            output[0],
        );

    const rotation_control =
        outputControl(
            output[1],
        );

    // Relative controls:
    //
    // 0 means "keep doing what you're doing".
    //
    // No speed / orientation are provided as inputs, matching the
    // original Shorelark idea.

    creature.speed =
        std.math.clamp(
            creature.speed +
                speed_control *
                    speed_accel,

            speed_min,
            speed_max,
        );

    creature.rotation =
        wrapAngle(
            creature.rotation +
                rotation_control *
                    rotation_accel,
        );
}

// Bitman's final activation can be ReLU.
//
// ReLU gives [0,127], but we need a signed control [-1,+1].
//
//    0   -> -1
//    64  -> ~0
//    127 -> +1
//
// Negative leaky-ReLU output is treated the same as zero.
fn outputControl(
    output: i8,
) f32 {
    const positive: i16 =
        std.math.clamp(
            @as(
                i16,
                output,
            ),
            0,
            127,
        );

    const normalized =
        @as(
            f32,
            @floatFromInt(
                positive,
            ),
        ) / 127.0;

    return normalized *
        2.0 -
        1.0;
}

fn moveCreature(
    creature: *Creature,
) void {
    // 0 radians points up.

    const dx =
        @sin(
            creature.rotation,
        ) *
        creature.speed;

    const dy =
        -@cos(
            creature.rotation,
        ) *
        creature.speed;

    creature.pos.x =
        wrap01(
            creature.pos.x +
                dx,
        );

    creature.pos.y =
        wrap01(
            creature.pos.y +
                dy,
        );
}

// ============================================================
// TOROIDAL WORLD HELPERS
// ============================================================

// Shortest direction from -> to in a [0,1) torus.
fn wrappedDelta(
    from: f32,
    to: f32,
) f32 {
    var d =
        to - from;

    if (d > 0.5) {
        d -= 1.0;
    } else if (d < -0.5) {
        d += 1.0;
    }

    return d;
}

fn wrap01(
    value: f32,
) f32 {
    var v =
        value;

    while (v < 0.0) {
        v += 1.0;
    }

    while (v >= 1.0) {
        v -= 1.0;
    }

    return v;
}

fn wrapAngle(
    value: f32,
) f32 {
    var angle =
        value;

    while (angle < -pi) {
        angle += tau;
    }

    while (angle >= pi) {
        angle -= tau;
    }

    return angle;
}

// ============================================================
// TUI
// ============================================================

fn renderTui(
    console: *WinConsole,
    champion: *const Individual,
    creature: *const Creature,
    foods: *const [food_count]Food,
    generation: usize,
    age: usize,
    train_stats: PopulationStats,
    best_train_ever: f64,
    eval_score: f64,
    best_eval_ever: f64,
    average_history: *const [generations]f64,
    best_history: *const [generations]f64,
    eval_history: *const [generations]f64,
    history_len: usize,
) void {
    var frame =
        Frame.init(
            console.attributes,
        );

    const attr =
        console.attributes;

    const vision =
        makeVision(
            creature,
            foods,
        );

    frame.write(
        0,
        0,
        "BITMAN SHORELARK | independent episodes | champion preview",
        attr,
    );

    frame.writeFmt(
        0,
        1,
        attr,
        "generation {d:>3}/{d:<3}   preview age {d:>4}/{d:<4}   population {d}   food {d}",
        .{
            generation,
            generations - 1,
            age,
            generation_length,
            population_size,
            food_count,
        },
    );

    frame.writeFmt(
        0,
        2,
        attr,
        "train: best {d:<8.3} avg {d:<8.3} best-ever {d:<8.3}   worlds/genome {d}",
        .{
            train_stats.best_eaten,
            train_stats.average_eaten,
            best_train_ever,
            train_world_count,
        },
    );

    frame.writeFmt(
        0,
        3,
        attr,
        "fixed eval: champion {d:<8.3} best-ever {d:<8.3}   eval worlds {d}",
        .{
            eval_score,
            best_eval_ever,
            eval_world_count,
        },
    );

    frame.writeFmt(
        0,
        4,
        attr,
        "brain 9->18->2   genes {d}   mutation {d:.2}% coeff {d:.2}   elite 1",
        .{
            genomeValueCount(),
            mutation_chance * 100.0,
            mutation_coeff,
        },
    );

    var eye_chars: [eye_cells]u8 =
        undefined;

    for (vision, 0..) |value, i| {
        eye_chars[i] =
            visionChar(value);
    }

    frame.write(
        0,
        5,
        "champ eye [",
        attr,
    );

    frame.write(
        11,
        5,
        eye_chars[0..],
        attr,
    );

    frame.write(
        20,
        5,
        "]",
        attr,
    );

    if (champion.out.len >= 2) {
        frame.writeFmt(
            24,
            5,
            attr,
            "brain speed={d:>4} turn={d:>4}   preview eaten={d}",
            .{
                champion.out[0],
                champion.out[1],
                creature.eaten,
            },
        );
    }

    const grid_x: usize = 1;
    const grid_y: usize = 8;

    frame.put(grid_x, grid_y, '+', attr);

    for (0..grid_width) |x| {
        frame.put(
            grid_x + 1 + x,
            grid_y,
            '-',
            attr,
        );
    }

    frame.put(
        grid_x + grid_width + 1,
        grid_y,
        '+',
        attr,
    );

    for (0..grid_height) |y| {
        const row = grid_y + 1 + y;

        frame.put(
            grid_x,
            row,
            '|',
            attr,
        );

        frame.put(
            grid_x + grid_width + 1,
            row,
            '|',
            attr,
        );
    }

    const bottom =
        grid_y + grid_height + 1;

    frame.put(
        grid_x,
        bottom,
        '+',
        attr,
    );

    for (0..grid_width) |x| {
        frame.put(
            grid_x + 1 + x,
            bottom,
            '-',
            attr,
        );
    }

    frame.put(
        grid_x + grid_width + 1,
        bottom,
        '+',
        attr,
    );

    for (foods) |food| {
        const gx, const gy =
            worldToGrid(food.pos);

        frame.put(
            grid_x + 1 + gx,
            grid_y + 1 + gy,
            '*',
            attr,
        );
    }

    const gx, const gy =
        worldToGrid(creature.pos);

    frame.put(
        grid_x + 1 + gx,
        grid_y + 1 + gy,
        directionChar(creature.rotation),
        attr,
    );

    const panel_x: usize = 86;

    frame.write(panel_x, 9, "* food", attr);
    frame.write(panel_x, 10, "^ champion", attr);
    frame.write(panel_x, 12, "PREVIEW ONLY", attr);
    frame.write(panel_x, 13, "not fitness", attr);

    frame.writeFmt(
        panel_x,
        15,
        attr,
        "eaten {d}",
        .{creature.eaten},
    );

    frame.writeFmt(
        panel_x,
        16,
        attr,
        "speed {d:.5}",
        .{creature.speed},
    );

    frame.writeFmt(
        panel_x,
        17,
        attr,
        "angle {d:.1}",
        .{angleDegrees(creature.rotation)},
    );

    frame.write(panel_x, 19, "EYE", attr);
    frame.write(panel_x, 20, "[", attr);
    frame.write(panel_x + 1, 20, eye_chars[0..], attr);
    frame.write(panel_x + 1 + eye_cells, 20, "]", attr);

    frame.write(panel_x, 22, "4 train worlds", attr);
    frame.write(panel_x, 23, "private state", attr);
    frame.write(panel_x, 24, "same seeds/gen", attr);

    drawLearningCurve(
        &frame,
        panel_x,
        26,
        attr,
        average_history,
        best_history,
        eval_history,
        history_len,
    );

    console.present(&frame);
}

fn worldToGrid(
    pos: Vec2,
) struct {
    usize,
    usize,
} {
    const xf =
        pos.x *
        @as(
            f32,
            @floatFromInt(
                grid_width,
            ),
        );

    const yf =
        pos.y *
        @as(
            f32,
            @floatFromInt(
                grid_height,
            ),
        );

    var x: usize =
        @intFromFloat(
            xf,
        );

    var y: usize =
        @intFromFloat(
            yf,
        );

    x =
        @min(
            x,
            grid_width - 1,
        );

    y =
        @min(
            y,
            grid_height - 1,
        );

    return .{
        x,
        y,
    };
}

fn visionChar(
    value: i8,
) u8 {
    if (value >= 90) {
        return '#';
    }

    if (value >= 35) {
        return '+';
    }

    if (value > 0) {
        return '.';
    }

    return ' ';
}

fn directionChar(
    rotation: f32,
) u8 {
    var r =
        rotation;

    if (r < 0.0) {
        r += tau;
    }

    const sector_float =
        (r +
            pi / 4.0) /
        (pi / 2.0);

    const sector: usize =
        @intFromFloat(
            sector_float,
        );

    return switch (sector % 4) {
        0 => '^',
        1 => '>',
        2 => 'v',
        3 => '<',
        else => unreachable,
    };
}

fn angleDegrees(
    rotation: f32,
) f32 {
    var r =
        rotation;

    if (r < 0.0) {
        r += tau;
    }

    return r *
        180.0 /
        pi;
}

fn drawLearningCurve(
    frame: *Frame,
    x: usize,
    y: usize,
    attr: WORD,
    average_history: *const [generations]f64,
    best_history: *const [generations]f64,
    eval_history: *const [generations]f64,
    history_len: usize,
) void {
    const graph_width = 24;
    const graph_height = 8;

    frame.write(x, y, "LEARNING CURVE", attr);
    frame.write(x, y + 1, "@eval #train .avg", attr);

    if (history_len == 0) {
        frame.write(x, y + 3, "waiting for gen 0...", attr);
        return;
    }

    var max_value: f64 = 1.0;

    for (best_history.*[0..history_len]) |value| {
        max_value = @max(max_value, value);
    }

    for (eval_history.*[0..history_len]) |value| {
        max_value = @max(max_value, value);
    }

    const max_label: usize =
        @intFromFloat(@ceil(max_value));

    const used_width =
        @min(graph_width, history_len);

    for (0..used_width) |column| {
        const history_index = if (used_width == 1)
            0
        else
            (column * (history_len - 1)) / (used_width - 1);

        const screen_x = if (used_width == 1)
            0
        else
            (column * (graph_width - 1)) / (used_width - 1);

        const avg_normalized = std.math.clamp(
            average_history.*[history_index] / max_value,
            0.0,
            1.0,
        );

        const best_normalized = std.math.clamp(
            best_history.*[history_index] / max_value,
            0.0,
            1.0,
        );

        const eval_normalized = std.math.clamp(
            eval_history.*[history_index] / max_value,
            0.0,
            1.0,
        );

        const avg_row = curveRow(
            avg_normalized,
            graph_height,
        );

        const best_row = curveRow(
            best_normalized,
            graph_height,
        );

        const eval_row = curveRow(
            eval_normalized,
            graph_height,
        );

        frame.put(
            x + screen_x,
            y + 2 + avg_row,
            '.',
            attr,
        );

        frame.put(
            x + screen_x,
            y + 2 + best_row,
            '#',
            attr,
        );

        // Draw eval last so the low-noise measurement remains visible
        // if it happens to overlap a training curve.
        frame.put(
            x + screen_x,
            y + 2 + eval_row,
            '@',
            attr,
        );
    }

    frame.writeFmt(
        x,
        y + 10,
        attr,
        "max {d} gen 0..{d}",
        .{ max_label, history_len - 1 },
    );
}

fn curveRow(
    normalized: f64,
    comptime graph_height: usize,
) usize {
    const height: usize =
        @intFromFloat(
            @round(
                normalized *
                    @as(
                        f64,
                        @floatFromInt(graph_height - 1),
                    ),
            ),
        );

    return graph_height -
        1 -
        @min(height, graph_height - 1);
}

fn printLearningCurve(
    average_history: *const [generations]f64,
    best_history: *const [generations]f64,
    eval_history: *const [generations]f64,
    history_len: usize,
) void {
    const graph_width = 60;
    const graph_height = 16;

    if (history_len == 0) {
        return;
    }

    var max_value: f64 = 1.0;

    for (best_history.*[0..history_len]) |value| {
        max_value = @max(max_value, value);
    }

    for (eval_history.*[0..history_len]) |value| {
        max_value = @max(max_value, value);
    }

    const max_label: usize =
        @intFromFloat(@ceil(max_value));

    var graph: [graph_height][graph_width]u8 =
        @splat(@splat(' '));

    for (0..graph_width) |column| {
        const index = if (graph_width == 1)
            0
        else
            (column * (history_len - 1)) / (graph_width - 1);

        const avg = std.math.clamp(
            average_history.*[index] / max_value,
            0.0,
            1.0,
        );

        const best = std.math.clamp(
            best_history.*[index] / max_value,
            0.0,
            1.0,
        );

        const eval_score = std.math.clamp(
            eval_history.*[index] / max_value,
            0.0,
            1.0,
        );

        const avg_row = curveRow(
            avg,
            graph_height,
        );

        const best_row = curveRow(
            best,
            graph_height,
        );

        const eval_row = curveRow(
            eval_score,
            graph_height,
        );

        graph[avg_row][column] = '.';
        graph[best_row][column] = '#';

        // Evaluation is the most useful curve, so keep it visible on
        // collisions with training curves.
        graph[eval_row][column] = '@';
    }

    std.debug.print(
        "\nLEARNING CURVE   @ fixed-seed eval   # train best(avg/4)   . population avg\n",
        .{},
    );

    for (graph, 0..) |row, row_index| {
        if (row_index == 0) {
            std.debug.print(
                "{d:>4} |{s}|\n",
                .{ max_label, row[0..] },
            );
        } else if (row_index == graph_height - 1) {
            std.debug.print(
                "{d:>4} |{s}|\n",
                .{ 0, row[0..] },
            );
        } else {
            std.debug.print(
                "     |{s}|\n",
                .{row[0..]},
            );
        }
    }

    std.debug.print(
        "      +------------------------------------------------------------+\n",
        .{},
    );

    std.debug.print(
        "       gen 0{d:>54}\n\n",
        .{history_len - 1},
    );
}

// ============================================================
// MISC
// ============================================================

fn genomeValueCount() usize {
    return eye_cells * 18 +
        18 * 2;
}
