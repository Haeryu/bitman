const Individual = @This();

const std = @import("std");

const requantize = @import("bitlinear.zig").BitLinear.requantize;
const Bitlinear = @import("bitlinear.zig").BitLinear;
const activation_pfns = @import("activation.zig").activation_pfns;

pub const PerThreadBuffer = struct {
    outs: []i32,
    activations: []i8,

    pub fn init(allocator: std.mem.Allocator, max_length: usize) !PerThreadBuffer {
        const outs = try allocator.alloc(i32, max_length);
        errdefer allocator.free(outs);

        const activations = try allocator.alloc(i8, max_length);

        return .{
            .outs = outs,
            .activations = activations,
        };
    }

    pub fn deinit(self: *PerThreadBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.activations);
        allocator.free(self.outs);

        self.* = undefined;
    }

    pub fn loadInput(self: *PerThreadBuffer, inputs: []const i8) void {
        std.debug.assert(inputs.len <= self.activations.len);

        @memcpy(self.activations[0..inputs.len], inputs);
    }
};

pub const LayerSetting = struct {
    rows: usize,
    cols: usize,
};

layers: []Bitlinear,
activation_pfn_index: usize,

pub fn init(
    allocator: std.mem.Allocator,
    random: std.Random,
    layer_settings: []const LayerSetting,
) !Individual {
    for (layer_settings[0 .. layer_settings.len - 1], 0..) |setting, i| {
        std.debug.assert(setting.rows == layer_settings[i + 1].cols);
    }

    var layers_init_count: usize = 0;
    const layers = try allocator.alloc(Bitlinear, layer_settings.len);
    errdefer {
        for (layers[0..layers_init_count]) |*layer| {
            layer.deinit(allocator);
        }
        allocator.free(layers);
    }

    for (layer_settings, layers) |layer_setting, *layer| {
        layer.* = try .initRandom(allocator, random, layer_setting.rows, layer_setting.cols);
        layers_init_count += 1;
    }

    const activation_pfn_index = random.uintLessThan(usize, activation_pfns.len);

    return .{
        .layers = layers,
        .activation_pfn_index = activation_pfn_index,
    };
}

pub fn deinit(self: *Individual, allocator: std.mem.Allocator) void {
    for (self.layers) |*layer| {
        layer.deinit(allocator);
    }
    allocator.free(self.layers);

    self.* = undefined;
}

pub fn maxLength(self: *const Individual) usize {
    var max: usize = 0;

    for (self.layers) |layer| {
        max = @max(max, @max(layer.rows, layer.cols));
    }

    return max;
}

pub fn forward(
    self: *const Individual,
    per_thread_buffer: *PerThreadBuffer,
) []const i8 {
    const activationPFN = activation_pfns[self.activation_pfn_index];
    for (self.layers) |*layer| {
        const input = per_thread_buffer.activations[0..layer.cols];
        const out = per_thread_buffer.outs[0..layer.rows];

        layer.accumulate(input, out);
        activationPFN(out);

        requantize(out, per_thread_buffer.activations[0..layer.rows]);
    }

    return per_thread_buffer.activations[0..self.layers[self.layers.len - 1].rows];
}
