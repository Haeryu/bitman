const std = @import("std");

pub const activation_pfns = [_]*const fn ([]i32) void{ relu, leakyRelu8 };

pub fn relu(values: []i32) void {
    const vec_len = std.simd.suggestVectorLength(i32).?;
    const Vec = @Vector(vec_len, i32);

    const zero: Vec = @splat(0);

    var i: usize = 0;
    while (i + vec_len <= values.len) : (i += vec_len) {
        const x: Vec = values[i..][0..vec_len].*;
        values[i..][0..vec_len].* = @max(x, zero);
    }

    for (values[i..]) |*x| {
        x.* = @max(x.*, 0);
    }
}

inline fn leakyRelu(comptime divisor: comptime_int, values: []i32) void {
    comptime std.debug.assert(divisor > 0);
    comptime std.debug.assert(divisor % 2 == 0);
    comptime std.debug.assert(std.math.isPowerOfTwo(divisor));

    const vec_len = std.simd.suggestVectorLength(i32).?;
    const Vec = @Vector(vec_len, i32);

    const zero: Vec = @splat(0);
    const divisor_vec: Vec = @splat(divisor);
    const bias_vec: Vec = @splat(divisor / 2);

    var i: usize = 0;
    while (i + vec_len <= values.len) : (i += vec_len) {
        const x: Vec = values[i..][0..vec_len].*;
        const neg = @divTrunc(x - bias_vec, divisor_vec);

        values[i..][0..vec_len].* = @select(i32, x >= zero, x, neg);
    }

    for (values[i..]) |*x| {
        if (x.* < 0) {
            x.* = @divTrunc(x.* - divisor / 2, divisor);
        }
    }
}

pub fn leakyRelu4(values: []i32) void {
    leakyRelu(4, values);
}

pub fn leakyRelu8(values: []i32) void {
    leakyRelu(8, values);
}

pub fn leakyRelu16(values: []i32) void {
    leakyRelu(16, values);
}
