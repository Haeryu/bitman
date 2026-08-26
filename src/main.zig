const std = @import("std");

const bitman = @import("bitman");
const Individual = bitman.Individual;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var prng: std.Random.DefaultPrng = .init(0x1234_5678);
    const random = prng.random();

    const layer_settings = [_]Individual.LayerSetting{
        .{
            .cols = 128,
            .rows = 64,
        },
        .{
            .cols = 64,
            .rows = 8,
        },
    };

    var indi0: Individual = try .init(gpa, random, &layer_settings, .random);
    defer indi0.deinit(gpa);

    var indi1: Individual = try .init(gpa, random, &layer_settings, .random);
    defer indi1.deinit(gpa);

    var childs = [_]Individual{
        try .init(gpa, random, &layer_settings, .empty),
        try .init(gpa, random, &layer_settings, .empty),
    };
    defer childs[0].deinit(gpa);
    defer childs[1].deinit(gpa);

    var buffer: Individual.PerThreadBuffer = try .init(gpa, indi0.maxRowColLen(), indi0.maxElementsLen());
    defer buffer.deinit(gpa);

    var input: [128]i8 = undefined;
    @memset(&input, 1);

    buffer.loadInput(&input);

    indi0.forward(&buffer);
    indi0.fitness = 10;
    indi1.forward(&buffer);
    indi1.fitness = 20;

    bitman.genetic_algorithm.evolve(
        random,
        &.{ indi0, indi1 },
        &childs,
        &buffer,
        .roulette_wheel,
        .uniform_crossover,
        .{ .gaussian_mutation = .{ .chance = 0.1, .coeff = 0.2 } },
    );

    buffer.loadInput(&input);
    childs[0].forward(&buffer);
    childs[1].forward(&buffer);

    std.debug.print("weights = {any}\n", .{indi0.layers[0].weights});
    std.debug.print("weights = {any}\n", .{indi1.layers[0].weights});
    std.debug.print("weights = {any}\n", .{childs[0].layers[0].weights});
    std.debug.print("weights = {any}\n", .{childs[1].layers[0].weights});

    std.debug.print("output = {any}\n", .{indi0.out});
    std.debug.print("output = {any}\n", .{indi1.out});
    std.debug.print("output = {any}\n", .{childs[0].out});
    std.debug.print("output = {any}\n", .{childs[1].out});
}
