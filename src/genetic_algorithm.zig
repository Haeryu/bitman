const std = @import("std");
const Individual = @import("Individual.zig");
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
) void {
    std.debug.assert(parent0.layers.len == parent1.layers.len);
    std.debug.assert(parent0.layers.len == out_child.layers.len);

    const RandomInt = @Int(.unsigned, activation_vec_len);

    const BoolVector = @Vector(activation_vec_len, bool);

    for (parent0.layers, parent1.layers, out_child.layers) |*p0_l, *p1_l, *oc_l| {
        std.debug.assert(p0_l.weights.len == p1_l.weights.len);
        std.debug.assert(p0_l.weights.len == oc_l.weights.len);

        for (p0_l.weights, p1_l.weights, oc_l.weights) |p0_w, p1_w, *oc_w| {
            const p0: PackedVector = @bitCast(p0_w);
            const p1: PackedVector = @bitCast(p1_w);

            var result: PackedVector = @splat(0);

            inline for (0..packed_groups) |group| {
                const choices: BoolVector = @bitCast(random.int(RandomInt));

                const shift: u3 = @intCast(group * 2);

                const mask: PackedVector = @splat(@as(u8, 0b11) << shift);

                const p0_gene = p0 & mask;
                const p1_gene = p1 & mask;

                result |= @select(u8, choices, p0_gene, p1_gene);
            }

            oc_w.* = @bitCast(result);
        }

        oc_l.weights_gain = (p0_l.weights_gain + p1_l.weights_gain) * 0.5;
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

                gene.* += sign * coeff * random.float(f32);
            }
        }

        layer.quantizeFrom(buf);
    }
}
