const Individual = @This();

const std = @import("std");

const requantize = @import("bitlinear.zig").BitLinear.requantize;
const Bitlinear = @import("bitlinear.zig").BitLinear;
const activation_pfns = @import("activation.zig").activation_pfns;

pub const PerThreadBuffer = struct {
    outs: []i32,
    activations: []i8,
    dequant: []f32,

    pub fn init(allocator: std.mem.Allocator, max_row_col_len: usize, max_element_len: usize) !PerThreadBuffer {
        const outs = try allocator.alloc(i32, max_row_col_len);
        errdefer allocator.free(outs);

        const activations = try allocator.alloc(i8, max_row_col_len);
        errdefer allocator.free(activations);

        const dequant = try allocator.alloc(f32, max_element_len);

        return .{
            .outs = outs,
            .activations = activations,
            .dequant = dequant,
        };
    }

    pub fn deinit(self: *PerThreadBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.dequant);
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

pub const InitMethods = enum {
    empty,
    random,
};

layers: []Bitlinear,
activation_pfn_index: usize,
out: []i8,
fitness: u64,

pub fn init(
    allocator: std.mem.Allocator,
    random: std.Random,
    layer_settings: []const LayerSetting,
    comptime init_method: InitMethods,
    comptime make_bias: bool,
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
        layer.* = switch (comptime init_method) {
            .random => try .initRandom(
                allocator,
                random,
                layer_setting.rows,
                layer_setting.cols,
                make_bias,
            ),
            .empty => try .initUndefined(
                allocator,
                layer_setting.rows,
                layer_setting.cols,
                make_bias,
            ),
        };
        layers_init_count += 1;
    }

    const out = try allocator.alloc(i8, layers[layers.len - 1].rows);

    const activation_pfn_index = random.uintLessThan(usize, activation_pfns.len);

    return .{
        .layers = layers,
        .activation_pfn_index = activation_pfn_index,
        .out = out,
        .fitness = 0,
    };
}

pub fn deinit(self: *Individual, allocator: std.mem.Allocator) void {
    allocator.free(self.out);

    for (self.layers) |*layer| {
        layer.deinit(allocator);
    }
    allocator.free(self.layers);

    self.* = undefined;
}

pub fn maxRowColLen(self: *const Individual) usize {
    var max: usize = 0;

    for (self.layers) |layer| {
        max = @max(max, @max(layer.rows, layer.cols));
    }

    return max;
}

pub fn maxElementsLen(self: *const Individual) usize {
    var max: usize = 0;

    for (self.layers) |layer| {
        max = @max(max, layer.rows * layer.cols);
    }

    return max;
}

pub fn forward(self: *Individual, inputs: []const i8, per_thread_buffer: *PerThreadBuffer) f32 {
    per_thread_buffer.loadInput(inputs);
    const activationPFN = activation_pfns[self.activation_pfn_index];
    var activation_gain: f32 = 1.0;
    for (self.layers) |*layer| {
        const input = per_thread_buffer.activations[0..layer.cols];
        const out = per_thread_buffer.outs[0..layer.rows];

        layer.accumulate(input, out);
        activationPFN(out);

        layer.activation_gain = requantize(out, per_thread_buffer.activations[0..layer.rows]);

        activation_gain *= layer.weights_gain * layer.activation_gain;
    }

    @memcpy(self.out, per_thread_buffer.activations[0..self.layers[self.layers.len - 1].rows]);

    return activation_gain;
}
