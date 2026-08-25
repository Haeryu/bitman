const std = @import("std");

pub const activation_pfns = [_]*const fn ([]i32) void{ relu, leakyRelu };

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

pub fn leakyRelu(values: []i32) void {
    const vec_len = std.simd.suggestVectorLength(i32).?;
    const Vec = @Vector(vec_len, i32);

    const zero: Vec = @splat(0);
    const divisor: Vec = @splat(8);

    var i: usize = 0;
    while (i + vec_len <= values.len) : (i += vec_len) {
        const x: Vec = values[i..][0..vec_len].*;
        const neg = @divTrunc(x, divisor);

        values[i..][0..vec_len].* = @select(i32, x >= zero, x, neg);
    }

    for (values[i..]) |*x| {
        if (x.* < 0) {
            x.* = @divTrunc(x.*, 8);
        }
    }
}
