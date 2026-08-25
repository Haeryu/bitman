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

    var individual: Individual = try .init(gpa, random, &layer_settings);
    defer individual.deinit(gpa);

    var buffer: Individual.PerThreadBuffer = try .init(gpa, individual.maxLength());
    defer buffer.deinit(gpa);

    var input: [128]i8 = undefined;
    @memset(&input, 1);

    buffer.loadInput(&input);

    const out = individual.forward(&buffer);

    std.debug.print("output = {any}\n", .{out});
}
