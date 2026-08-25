const std = @import("std");

const activation_vec_len = @min(std.simd.suggestVectorLength(i8).?, 32);
const wide_vec_len = @min(std.simd.suggestVectorLength(i16).?, activation_vec_len);
const accum_vec_len = @min(std.simd.suggestVectorLength(i32).?, wide_vec_len);
const wide_chunk_count = activation_vec_len / wide_vec_len;
const accum_chunk_count = wide_vec_len / accum_vec_len;
const ActivationVector = @Vector(activation_vec_len, i8);
const WideVector = @Vector(wide_vec_len, i16);
const AccumVector = @Vector(accum_vec_len, i32);

const packed_groups = 4;
const weights_per_block = packed_groups * activation_vec_len;

const PackedBlock = [activation_vec_len]u8;
const PackedVector = @Vector(activation_vec_len, u8);
const PackedShiftVector = @Vector(activation_vec_len, u3);

const max_blocks_per_accum = std.math.maxInt(i16) / (packed_groups * 128);

const unroll_vec_count = 4;
const prefill_col_micro = 4;
const decode_row_tasks = 4;

pub const BitLinear = struct {
    weights: []PackedBlock,
    rows: usize,
    cols: usize,

    // reserve
    weights_gain: f32 = undefined,

    inline fn unpackGroup(pack: PackedBlock, comptime group: usize) ActivationVector {
        comptime std.debug.assert(group < packed_groups);

        const bytes: PackedVector = @bitCast(pack);
        const mask: PackedVector = @splat(0b11);
        const shift: PackedShiftVector = @splat(group * 2);
        const codes = (bytes >> shift) & mask;

        std.debug.assert(@reduce(.And, codes <= @as(PackedVector, @splat(2))));

        const signed: ActivationVector = @intCast(codes);

        return signed - @as(ActivationVector, @splat(1));
    }

    inline fn reduceWide(value: WideVector) i32 {
        comptime std.debug.assert(wide_vec_len % accum_vec_len == 0);

        const values: [wide_vec_len]i16 = @bitCast(value);

        var sum: i32 = 0;
        inline for (0..accum_chunk_count) |chunk| {
            const offset = chunk * accum_vec_len;
            const part16: @Vector(accum_vec_len, i16) = values[offset..][0..accum_vec_len].*;
            const part32: AccumVector = @intCast(part16);
            sum += @reduce(.Add, part32);
        }

        return sum;
    }

    inline fn packedWeightAt(pack: PackedBlock, index: usize) i8 {
        const group = index / activation_vec_len;
        const lane = index % activation_vec_len;

        std.debug.assert(group < packed_groups);

        const shift: u3 = @intCast(group * 2);
        const code: u2 = @truncate(pack[lane] >> shift);

        std.debug.assert(code != 3);

        return @as(i8, @intCast(code)) - 1;
    }

    inline fn packedDot2(
        k: usize,
        w_quant: []const PackedBlock,
        first_row: usize,
        x: []const i8,
    ) [2]i32 {
        const full_blocks = k / weights_per_block;
        const tail = k % weights_per_block;
        const blocks_per_row = (k + weights_per_block - 1) / weights_per_block;

        comptime std.debug.assert(activation_vec_len % wide_vec_len == 0);
        comptime std.debug.assert(max_blocks_per_accum > 0);
        std.debug.assert(x.len == k);
        std.debug.assert(w_quant.len >= (first_row + 2) * blocks_per_row);

        const w_rows = .{
            w_quant[(first_row + 0) * blocks_per_row ..][0..blocks_per_row],
            w_quant[(first_row + 1) * blocks_per_row ..][0..blocks_per_row],
        };

        var sums: [2]i32 = @splat(0);
        var block_start: usize = 0;
        while (block_start < full_blocks) {
            const block_end = @min(block_start + max_blocks_per_accum, full_blocks);
            var accs: [2][wide_chunk_count]WideVector = @splat(@splat(@splat(0)));

            var block_index = block_start;
            while (block_index < block_end) : (block_index += 1) {
                inline for (0..packed_groups) |group| {
                    const x_base = block_index * weights_per_block + group * activation_vec_len;
                    const x_vector: ActivationVector = x[x_base..][0..activation_vec_len].*;
                    const x_values: [activation_vec_len]i8 = @bitCast(x_vector);
                    var x_chunks: [wide_chunk_count]WideVector = undefined;

                    inline for (0..wide_chunk_count) |chunk| {
                        const offset = chunk * wide_vec_len;
                        const x8: @Vector(wide_vec_len, i8) =
                            x_values[offset..][0..wide_vec_len].*;

                        x_chunks[chunk] = @intCast(x8);
                    }

                    inline for (0..2) |r| {
                        const weights_vector = unpackGroup(w_rows[r][block_index], group);
                        const weights: [activation_vec_len]i8 = @bitCast(weights_vector);

                        inline for (0..wide_chunk_count) |chunk| {
                            const offset = chunk * wide_vec_len;
                            const w8: @Vector(wide_vec_len, i8) =
                                weights[offset..][0..wide_vec_len].*;
                            const w16: WideVector = @intCast(w8);

                            accs[r][chunk] += x_chunks[chunk] * w16;
                        }
                    }
                }
            }

            inline for (0..2) |r| {
                inline for (0..wide_chunk_count) |chunk| {
                    sums[r] += reduceWide(accs[r][chunk]);
                }
            }

            block_start = block_end;
        }

        if (tail != 0) {
            const x_base = full_blocks * weights_per_block;

            for (0..tail) |index| {
                const value: i32 = x[x_base + index];

                inline for (0..2) |r| {
                    const w: i32 = packedWeightAt(w_rows[r][full_blocks], index);

                    sums[r] += value * w;
                }
            }
        }

        return sums;
    }

    inline fn packedDot(k: usize, w_row: []const PackedBlock, x: []const i8) i32 {
        const full_blocks = k / weights_per_block;
        const tail = k % weights_per_block;
        const blocks_per_row = (k + weights_per_block - 1) / weights_per_block;

        comptime std.debug.assert(activation_vec_len % wide_vec_len == 0);
        comptime std.debug.assert(max_blocks_per_accum > 0);
        std.debug.assert(w_row.len == blocks_per_row);
        std.debug.assert(x.len == k);

        var sum: i32 = 0;
        var block_start: usize = 0;
        while (block_start < full_blocks) {
            const block_end = @min(block_start + max_blocks_per_accum, full_blocks);
            var accs: [wide_chunk_count]WideVector = @splat(@splat(0));

            var block_index = block_start;
            while (block_index < block_end) : (block_index += 1) {
                const pack = w_row[block_index];

                inline for (0..packed_groups) |group| {
                    const weights_vec = unpackGroup(pack, group);

                    const weights: [activation_vec_len]i8 = @bitCast(weights_vec);

                    inline for (0..wide_chunk_count) |chunk| {
                        const offset = chunk * wide_vec_len;
                        const x_offset = block_index * weights_per_block +
                            group * activation_vec_len + offset;
                        const x8: @Vector(wide_vec_len, i8) = x[x_offset..][0..wide_vec_len].*;
                        const w8: @Vector(wide_vec_len, i8) =
                            weights[offset..][0..wide_vec_len].*;
                        const x16: WideVector = @intCast(x8);
                        const w16: WideVector = @intCast(w8);

                        accs[chunk] += x16 * w16;
                    }
                }
            }

            inline for (accs) |acc| {
                sum += reduceWide(acc);
            }

            block_start = block_end;
        }

        if (tail != 0) {
            const pack = w_row[full_blocks];
            const x_base = full_blocks * weights_per_block;

            for (0..tail) |index| {
                const w: i32 = packedWeightAt(pack, index);
                const value: i32 = x[x_base + index];

                sum += value * w;
            }
        }

        return sum;
    }

    pub fn accumulate(self: *const BitLinear, inputs: []const i8, out_buf: []i32) void {
        std.debug.assert(inputs.len == self.cols);
        std.debug.assert(out_buf.len == self.rows);

        const m = self.rows;
        const k = self.cols;

        const blocks_per_row = (k + weights_per_block - 1) / weights_per_block;

        std.debug.assert(self.weights.len == m * blocks_per_row);
        std.debug.assert(inputs.len == k);
        std.debug.assert(out_buf.len == m);

        var row = 0;
        while (row + 2 <= self.rows) : (row += 2) {
            const values = packedDot2(k, self.weights, row, inputs);
            inline for (0..2) |r| {
                out_buf[row + r] = values[r];
            }
        }

        while (row < self.rows) : (row += 1) {
            const w_base = row * blocks_per_row;
            const w_row = self.weights[w_base..][0..blocks_per_row];

            out_buf[row] = packedDot(k, w_row, inputs);
        }
    }

    pub fn requantize(input: []const i32, output: []i8) void {
        std.debug.assert(input.len == output.len);

        var max_abs: i64 = 0;
        for (input) |value| {
            const wide: i64 = value;
            const magnitude = if (wide < 0) -wide else wide;
            max_abs = @max(max_abs, magnitude);
        }

        if (max_abs == 0) {
            @memset(output, 0);
            // return 1.0;
            return;
        }

        for (input, output) |value, *out| {
            const num = @as(i64, value) * 127;
            const half = @divTrunc(max_abs, 2);

            const q = if (num >= 0)
                @divTrunc(num + half, max_abs)
            else
                @divTrunc(num - half, max_abs);

            out.* = @intCast(std.math.clamp(q, -127, 127));
        }

        // const requant_gain = @as(f32, @floatFromInt(max_abs)) / 127.0;
        // return requant_gain;
    }
};
