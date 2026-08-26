const std = @import("std");
const Individual = @import("Individual.zig");
const BitLinear = @import("bitlinear.zig").BitLinear;
const PackedVector = @import("bitlinear.zig").PackedVector;
const activation_vec_len = @import("bitlinear.zig").activation_vec_len;
const packed_groups = @import("bitlinear.zig").packed_groups;
const PerThreadBuffer = Individual.PerThreadBuffer;

pub const SelectionMethod = enum {
    roulette_wheel,
};

pub const CrossoverMethod = enum {
    uniform_crossover,
};

pub const MutationMethod = union(enum) {
    gaussian_mutation: struct {
        chance: f32,
        coeff: f32,
    },
};

pub fn evolve(
    random: std.Random,
    individuals: []const Individual,
    childs: []Individual,
    per_thread_buffer: *PerThreadBuffer,
    comptime selection_method: SelectionMethod,
    comptime crossover_method: CrossoverMethod,
    comptime mutation_method: MutationMethod,
) void {
    var total_fitness: if (selection_method == .roulette_wheel) u64 else void =
        if (comptime selection_method == .roulette_wheel)
            0
        else {};

    if (comptime selection_method == .roulette_wheel) {
        for (individuals) |individual| {
            total_fitness += individual.fitness;
        }
    }

    for (childs) |*child| {
        const index_p0, const index_p1 = sw: switch (comptime selection_method) {
            .roulette_wheel => {
                const p0 = rouletteWheelSelection(random, individuals, total_fitness);
                const p1 = rouletteWheelSelection(random, individuals, total_fitness);

                break :sw .{ p0, p1 };
            },
        };

        switch (comptime crossover_method) {
            .uniform_crossover => {
                uniformCrossover(
                    random,
                    &individuals[index_p0],
                    &individuals[index_p1],
                    child,
                    per_thread_buffer,
                );
            },
        }

        switch (comptime mutation_method) {
            .gaussian_mutation => |v| {
                gaussianMutation(v.chance, v.coeff, random, child, per_thread_buffer);
            },
        }
    }
}

fn rouletteWheelSelection(
    random: std.Random,
    individuals: []const Individual,
    total_fitness: u64,
) usize {
    std.debug.assert(individuals.len > 0);
    std.debug.assert(total_fitness > 0);

    const target = random.uintLessThan(u64, total_fitness);

    var accumulated: u64 = 0;
    for (individuals, 0..) |individual, i| {
        const fitness: u64 = @intCast(individual.fitness);
        accumulated += fitness;

        if (target < accumulated) {
            return i;
        }
    }

    unreachable;
}

fn uniformCrossover(
    random: std.Random,
    parent0: *const Individual,
    parent1: *const Individual,
    out_child: *Individual,
    buffer: *PerThreadBuffer,
) void {
    for (parent0.layers, parent1.layers, out_child.layers) |*p0, *p1, *child| {
        const floats = buffer.dequant[0 .. child.rows * child.cols];
        var abs_sum: f64 = 0;
        var nonzero_count: usize = 0;

        for (0..child.rows) |row| {
            for (0..child.cols) |col| {
                const use_p0 = random.boolean();
                const parent = if (use_p0) p0 else p1;
                const q = parent.weightAt(row, col);
                const value = @as(f32, @floatFromInt(q)) * parent.weights_gain;

                floats[row * child.cols + col] = value;

                if (q != 0) {
                    abs_sum += @abs(value);
                    nonzero_count += 1;
                }
            }
        }

        const eps: f32 = 1e-5;
        const child_gain = @max(BitLinear.absMean(f32, floats), eps);

        child.quantizeFromGain(floats, child_gain);
    }

    out_child.activation_pfn_index = if (random.boolean())
        parent0.activation_pfn_index
    else
        parent1.activation_pfn_index;
}

fn gaussianMutation(
    chance: f32,
    coeff: f32,
    random: std.Random,
    child: *Individual,
    per_thread_buffer: *PerThreadBuffer,
) void {
    for (child.layers) |*layer| {
        const buf = per_thread_buffer.dequant[0 .. layer.rows * layer.cols];

        layer.dequantizeInto(buf);

        for (buf) |*gene| {
            if (random.float(f32) < chance) {
                const sign: f32 = if (random.boolean()) -1.0 else 1.0;

                gene.* += sign * coeff * layer.weights_gain * random.float(f32);
            }
        }

        layer.quantizeFrom(buf);
    }
}
