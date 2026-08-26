const std = @import("std");

const bitman = @import("bitman");
const Individual = bitman.Individual;

const population_size = 64;
const generations = 200;

const grid_size = 11;
const max_steps = 24;

const preview_every = 10;
const preview_delay_ms = 60;

const mutation_chance: f32 = 0.05;
const mutation_coeff: f32 = 1.0;

const Point = struct {
    x: usize,
    y: usize,
};

const Episode = struct {
    start: Point,
    food: Point,
};

const episodes = [_]Episode{
    .{ .start = .{ .x = 0, .y = 0 }, .food = .{ .x = 10, .y = 10 } },
    .{ .start = .{ .x = 10, .y = 10 }, .food = .{ .x = 0, .y = 0 } },
    .{ .start = .{ .x = 0, .y = 10 }, .food = .{ .x = 10, .y = 0 } },
    .{ .start = .{ .x = 10, .y = 0 }, .food = .{ .x = 0, .y = 10 } },

    .{ .start = .{ .x = 5, .y = 0 }, .food = .{ .x = 5, .y = 10 } },
    .{ .start = .{ .x = 5, .y = 10 }, .food = .{ .x = 5, .y = 0 } },
    .{ .start = .{ .x = 0, .y = 5 }, .food = .{ .x = 10, .y = 5 } },
    .{ .start = .{ .x = 10, .y = 5 }, .food = .{ .x = 0, .y = 5 } },

    .{ .start = .{ .x = 2, .y = 2 }, .food = .{ .x = 8, .y = 7 } },
    .{ .start = .{ .x = 8, .y = 2 }, .food = .{ .x = 1, .y = 9 } },
    .{ .start = .{ .x = 1, .y = 8 }, .food = .{ .x = 9, .y = 3 } },
    .{ .start = .{ .x = 9, .y = 7 }, .food = .{ .x = 2, .y = 1 } },
};

const Evaluation = struct {
    fitness: u64,
    foods: usize,
};

const GenerationStats = struct {
    generation: usize,
    best_fitness: u64,
    average_fitness: u64,
    best_foods: usize,
    best_activation: usize,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var prng: std.Random.DefaultPrng = .init(0x1234_5678);
    const random = prng.random();

    //
    // Tiny network:
    //
    //     dx, dy
    //       |
    //      8
    //       |
    //  L R U D
    //
    const layer_settings = [_]Individual.LayerSetting{
        .{
            .cols = 2,
            .rows = 8,
        },
        .{
            .cols = 8,
            .rows = 4,
        },
    };

    //
    // Allocate exactly two populations.
    //
    // These allocations live for the entire simulation.
    // The actual Individual objects and their layer allocations are never
    // recreated between generations.
    //
    const population_a = try allocPopulation(
        gpa,
        random,
        &layer_settings,
        population_size,
        .random,
    );
    defer freePopulation(gpa, population_a);

    const population_b = try allocPopulation(
        gpa,
        random,
        &layer_settings,
        population_size,
        .empty,
    );
    defer freePopulation(gpa, population_b);

    //
    // One scratch buffer reused by:
    //
    // - every forward()
    // - every Individual
    // - every episode
    // - crossover
    // - mutation
    // - TUI preview
    //
    var buffer: Individual.PerThreadBuffer = try .init(
        gpa,
        population_a[0].maxRowColLen(),
        population_a[0].maxElementsLen(),
    );
    defer buffer.deinit(gpa);

    //
    // These are only views.
    //
    // No population memory is moved when a generation changes.
    //
    var parents: []Individual = population_a;
    var children: []Individual = population_b;

    // Hide terminal cursor while the simulation is running.
    std.debug.print("\x1b[?25l", .{});
    defer std.debug.print("\x1b[?25h\n", .{});

    for (0..generations) |generation| {
        //
        // Evaluate the entire current population.
        //
        var total_fitness: u64 = 0;

        var best_index: usize = 0;
        var best_fitness: u64 = 0;
        var best_foods: usize = 0;

        for (parents, 0..) |*individual, index| {
            const result = evaluate(individual, &buffer);

            individual.fitness = result.fitness;
            total_fitness += result.fitness;

            if (result.fitness > best_fitness) {
                best_index = index;
                best_fitness = result.fitness;
                best_foods = result.foods;
            }
        }

        const best = &parents[best_index];

        const stats = GenerationStats{
            .generation = generation,
            .best_fitness = best_fitness,
            .average_fitness = total_fitness / parents.len,
            .best_foods = best_foods,
            .best_activation = best.activation_pfn_index,
        };

        //
        // Animate the best organism every N generations.
        //
        if (generation % preview_every == 0 or generation + 1 == generations) {
            const episode_index = generation % episodes.len;

            preview(
                init.io,
                best,
                &buffer,
                stats,
                episode_index,
            );
        } else {
            //
            // Still refresh the TUI once so the numbers keep moving
            // even when we are not playing an animated preview.
            //
            const episode = episodes[generation % episodes.len];

            renderTui(
                stats,
                generation % episodes.len,
                0,
                episode.start,
                episode.food,
                false,
            );
        }

        //
        // Last generation only needs evaluation.
        //
        if (generation + 1 == generations) {
            break;
        }

        //
        // Write the next generation directly into the other
        // already-allocated population.
        //
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

        //
        // Important part:
        //
        //     generation N:
        //
        //         parents  -> A
        //         children -> B
        //
        //     generation N + 1:
        //
        //         parents  -> B
        //         children -> A
        //
        // No allocation.
        // No copying of whole Individuals.
        // Just swap two slices.
        //
        const tmp = parents;
        parents = children;
        children = tmp;
    }
}

fn allocPopulation(
    allocator: std.mem.Allocator,
    random: std.Random,
    layer_settings: []const Individual.LayerSetting,
    count: usize,
    comptime init_method: Individual.InitMethods,
) ![]Individual {
    const population = try allocator.alloc(Individual, count);
    errdefer allocator.free(population);

    var initialized: usize = 0;
    errdefer {
        for (population[0..initialized]) |*individual| {
            individual.deinit(allocator);
        }
    }

    for (population) |*individual| {
        individual.* = try .init(
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

fn evaluate(
    individual: *Individual,
    buffer: *Individual.PerThreadBuffer,
) Evaluation {
    var fitness: u64 = 0;
    var foods: usize = 0;

    for (episodes) |episode| {
        var pos = episode.start;

        //
        // Guarantees fitness > 0.
        //
        // roulette wheel selection requires total_fitness > 0.
        //
        fitness += 1;

        var old_distance = manhattan(pos, episode.food);

        for (0..max_steps) |step| {
            const input = makeInput(pos, episode.food);

            _ = individual.forward(&input, buffer);

            const action = chooseAction(individual.out);

            move(&pos, action);

            const new_distance = manhattan(pos, episode.food);

            //
            // Smooth reward:
            //
            // closer positions get a little more reward every step.
            //
            const max_distance = (grid_size - 1) * 2;
            const proximity = max_distance - new_distance;

            fitness += @intCast(proximity);

            //
            // Explicit reward for actually moving toward food.
            //
            if (new_distance < old_distance) {
                fitness += 8;
            }

            //
            // Large terminal reward.
            //
            if (samePoint(pos, episode.food)) {
                foods += 1;

                const steps_remaining = max_steps - step;

                fitness += 500;
                fitness += @as(u64, @intCast(steps_remaining)) * 20;

                break;
            }

            old_distance = new_distance;
        }
    }

    return .{
        .fitness = fitness,
        .foods = foods,
    };
}

fn preview(
    io: std.Io,
    individual: *Individual,
    buffer: *Individual.PerThreadBuffer,
    stats: GenerationStats,
    episode_index: usize,
) void {
    const episode = episodes[episode_index];

    var pos = episode.start;

    for (0..max_steps + 1) |step| {
        const reached = samePoint(pos, episode.food);

        renderTui(
            stats,
            episode_index,
            step,
            pos,
            episode.food,
            reached,
        );

        if (reached or step == max_steps) {
            io.sleep(.fromMilliseconds(300), .awake) catch {};
            break;
        }

        const input = makeInput(pos, episode.food);

        _ = individual.forward(&input, buffer);

        const action = chooseAction(individual.out);

        move(&pos, action);

        io.sleep(.fromMilliseconds(preview_delay_ms), .awake) catch {};
    }
}

fn makeInput(
    pos: Point,
    food: Point,
) [2]i8 {
    const px: isize = @intCast(pos.x);
    const py: isize = @intCast(pos.y);

    const fx: isize = @intCast(food.x);
    const fy: isize = @intCast(food.y);

    return .{
        @intCast(fx - px),
        @intCast(fy - py),
    };
}

fn chooseAction(output: []const i8) usize {
    std.debug.assert(output.len >= 4);

    var best_index: usize = 0;
    var best_value = output[0];

    for (output[1..4], 1..) |value, index| {
        if (value > best_value) {
            best_value = value;
            best_index = index;
        }
    }

    return best_index;
}

fn move(
    pos: *Point,
    action: usize,
) void {
    switch (action) {
        // LEFT
        0 => {
            if (pos.x > 0) {
                pos.x -= 1;
            }
        },

        // RIGHT
        1 => {
            if (pos.x + 1 < grid_size) {
                pos.x += 1;
            }
        },

        // UP
        2 => {
            if (pos.y > 0) {
                pos.y -= 1;
            }
        },

        // DOWN
        3 => {
            if (pos.y + 1 < grid_size) {
                pos.y += 1;
            }
        },

        else => unreachable,
    }
}

fn manhattan(
    a: Point,
    b: Point,
) usize {
    const dx = if (a.x >= b.x)
        a.x - b.x
    else
        b.x - a.x;

    const dy = if (a.y >= b.y)
        a.y - b.y
    else
        b.y - a.y;

    return dx + dy;
}

fn samePoint(
    a: Point,
    b: Point,
) bool {
    return a.x == b.x and a.y == b.y;
}

fn renderTui(
    stats: GenerationStats,
    episode_index: usize,
    step: usize,
    bitman_pos: Point,
    food_pos: Point,
    reached: bool,
) void {
    //
    // Clear screen + move cursor to top-left.
    //
    std.debug.print("\x1b[2J\x1b[H", .{});

    std.debug.print(
        \\+------------------------ BITMAN ------------------------+
        \\| generation : {d: >6} / {d: <6}                         |
        \\| best       : {d: >12}                              |
        \\| average    : {d: >12}                              |
        \\| food       : {d: >3} / {d: <3} episodes                   |
        \\| activation : {d: >12}                              |
        \\| population : {d: >6} x 2 buffers                      |
        \\| mutation   : {d: >6.2}%  coeff={d:.2}                   |
        \\+--------------------------------------------------------+
        \\| preview     : episode {d: >2}  step {d: >2}/{d: <2}              |
        \\+--------------------------------------------------------+
        \\
    , .{
        stats.generation,
        generations - 1,
        stats.best_fitness,
        stats.average_fitness,
        stats.best_foods,
        episodes.len,
        stats.best_activation,
        population_size,
        mutation_chance * 100.0,
        mutation_coeff,
        episode_index,
        step,
        max_steps,
    });

    std.debug.print("     +", .{});

    for (0..grid_size) |_| {
        std.debug.print("--", .{});
    }

    std.debug.print("+\n", .{});

    for (0..grid_size) |y| {
        std.debug.print("     |", .{});

        for (0..grid_size) |x| {
            const here = Point{
                .x = x,
                .y = y,
            };

            const symbol: u8 =
                if (samePoint(here, bitman_pos) and
                samePoint(here, food_pos))
                    'X'
                else if (samePoint(here, bitman_pos))
                    '@'
                else if (samePoint(here, food_pos))
                    '*'
                else
                    '.';

            std.debug.print("{c} ", .{symbol});
        }

        std.debug.print("|\n", .{});
    }

    std.debug.print("     +", .{});

    for (0..grid_size) |_| {
        std.debug.print("--", .{});
    }

    std.debug.print("+\n", .{});

    if (reached) {
        std.debug.print(
            \\
            \\        @ = bitman    * = food    X = NOM NOM NOM
            \\
        , .{});
    } else {
        std.debug.print(
            \\
            \\        @ = bitman    * = food
            \\
        , .{});
    }

    std.debug.print(
        \\
        \\        input  = [food_x - x, food_y - y]
        \\        output = [LEFT, RIGHT, UP, DOWN]
        \\
    , .{});
}
