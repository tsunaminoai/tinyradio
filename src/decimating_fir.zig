//! Decimating FIR filter for complex samples with real taps.
//!
//! Only every D-th output is computed, so the cost scales with the output
//! rate instead of the input rate. Tap count and decimation factor are
//! comptime, so the vector loop is fully unrolled.
//!
//! The history is a doubled ring buffer: each sample is written at `slot` and
//! `slot + Padded`, so the newest `Padded` samples always sit contiguously in
//! memory. Each output is then a straight run of SIMD multiply-adds over that
//! window. Taps are stored reversed and zero-padded to a whole number of
//! vectors, so the padding adds no contribution.

const std = @import("std");
const Complex = std.math.Complex(f32);

pub const Lanes = 8;
const Vec = @Vector(Lanes, f32);

pub fn DecimatingFIR(comptime N: usize, comptime D: usize) type {
    comptime {
        if (N == 0) @compileError("DecimatingFIR needs at least one tap");
        if (D == 0) @compileError("DecimatingFIR decimation must be at least 1");
    }

    const Padded = std.mem.alignForward(usize, N, Lanes);
    const Chunks = Padded / Lanes;

    return struct {
        const Self = @This();

        pub const tap_count = N;
        pub const decimation = D;

        /// taps[c] holds reversed, zero-padded taps for window positions
        /// c*Lanes .. c*Lanes+Lanes-1. Window position Padded-1 is the newest
        /// sample and gets h[0].
        taps: [Chunks]Vec = @splat(@splat(0)),
        hist_re: [2 * Padded]f32 = @splat(0),
        hist_im: [2 * Padded]f32 = @splat(0),
        /// Ring slot that the next sample overwrites. It is also the oldest
        /// sample in the window.
        slot: usize = 0,
        /// Input samples since the last output, modulo D.
        phase: usize = 0,

        /// Install filter taps `h`, where h[k] multiplies the sample k steps back.
        pub fn setTaps(self: *Self, h: *const [N]f32) void {
            var rev: [Padded]f32 = @splat(0);
            for (0..N) |k| rev[Padded - 1 - k] = h[k];
            for (0..Chunks) |c| {
                self.taps[c] = rev[c * Lanes ..][0..Lanes].*;
            }
        }

        /// Clear the history and decimation phase, keeping the taps.
        pub fn reset(self: *Self) void {
            self.hist_re = @splat(0);
            self.hist_im = @splat(0);
            self.slot = 0;
            self.phase = 0;
        }

        /// Feed one sample. Returns the filtered output when this sample is
        /// one the decimator keeps, and null otherwise.
        pub inline fn step(self: *Self, s: Complex) ?Complex {
            self.hist_re[self.slot] = s.re;
            self.hist_re[self.slot + Padded] = s.re;
            self.hist_im[self.slot] = s.im;
            self.hist_im[self.slot + Padded] = s.im;
            self.slot = if (self.slot + 1 == Padded) 0 else self.slot + 1;

            const keep = self.phase == 0;
            self.phase = if (self.phase + 1 == D) 0 else self.phase + 1;
            if (!keep) return null;

            return .{ .re = self.dot(&self.hist_re), .im = self.dot(&self.hist_im) };
        }

        /// Filter `x` into `z`, keeping every D-th output. Returns the number
        /// of outputs written. `z` must hold at least ceil(x.len / D) items.
        pub fn process(self: *Self, x: []const Complex, z: []Complex) usize {
            var produced: usize = 0;
            for (x) |s| {
                if (self.step(s)) |y| {
                    z[produced] = y;
                    produced += 1;
                }
            }
            return produced;
        }

        inline fn dot(self: *const Self, hist: *const [2 * Padded]f32) f32 {
            var acc: Vec = @splat(0);
            inline for (0..Chunks) |c| {
                const w: Vec = hist[self.slot + c * Lanes ..][0..Lanes].*;
                acc += w * self.taps[c];
            }
            return @reduce(.Add, acc);
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

/// Straightforward reference: direct convolution, then keep every D-th output.
fn referenceDecimate(comptime N: usize, comptime D: usize, h: *const [N]f32, x: []const Complex, out: []Complex) usize {
    var produced: usize = 0;
    var n: usize = 0;
    while (n < x.len) : (n += D) {
        var acc = Complex{ .re = 0, .im = 0 };
        for (0..N) |k| {
            if (k > n) break;
            acc.re += h[k] * x[n - k].re;
            acc.im += h[k] * x[n - k].im;
        }
        out[produced] = acc;
        produced += 1;
    }
    return produced;
}

fn expectClose(expected: []const Complex, actual: []const Complex, tol: f32) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try std.testing.expectApproxEqAbs(e.re, a.re, tol);
        try std.testing.expectApproxEqAbs(e.im, a.im, tol);
    }
}

test "DecimatingFIR matches direct convolution" {
    const N = 64;
    const D = 4;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    var h: [N]f32 = undefined;
    for (&h) |*t| t.* = random.float(f32) - 0.5;

    var x: [1000]Complex = undefined;
    for (&x) |*s| s.* = .{ .re = random.float(f32) - 0.5, .im = random.float(f32) - 0.5 };

    var expected: [1000]Complex = undefined;
    const exp_len = referenceDecimate(N, D, &h, &x, &expected);

    var fir: DecimatingFIR(N, D) = .{};
    fir.setTaps(&h);
    var actual: [1000]Complex = undefined;
    const act_len = fir.process(&x, &actual);

    try expectClose(expected[0..exp_len], actual[0..act_len], 1e-4);
}

test "DecimatingFIR handles tap counts that are not a multiple of the lane width" {
    const N = 10;
    const D = 3;
    const h = [N]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.4, 0.3, 0.2, 0.1, 0.05 };

    var x: [50]Complex = undefined;
    for (&x, 0..) |*s, i| s.* = .{ .re = @floatFromInt(i % 7), .im = -@as(f32, @floatFromInt(i % 5)) };

    var expected: [50]Complex = undefined;
    const exp_len = referenceDecimate(N, D, &h, &x, &expected);

    var fir: DecimatingFIR(N, D) = .{};
    fir.setTaps(&h);
    var actual: [50]Complex = undefined;
    const act_len = fir.process(&x, &actual);

    try expectClose(expected[0..exp_len], actual[0..act_len], 1e-4);
}

test "DecimatingFIR is independent of how the input is split into chunks" {
    const N = 64;
    const D = 4;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var h: [N]f32 = undefined;
    for (&h) |*t| t.* = random.float(f32) - 0.5;

    var x: [600]Complex = undefined;
    for (&x) |*s| s.* = .{ .re = random.float(f32), .im = random.float(f32) };

    var whole_fir: DecimatingFIR(N, D) = .{};
    whole_fir.setTaps(&h);
    var whole: [600]Complex = undefined;
    const whole_len = whole_fir.process(&x, &whole);

    // Same input, fed in uneven chunks. Output must not change.
    var chunk_fir: DecimatingFIR(N, D) = .{};
    chunk_fir.setTaps(&h);
    var chunked: [600]Complex = undefined;
    var chunked_len: usize = 0;
    var pos: usize = 0;
    const sizes = [_]usize{ 1, 7, 64, 3, 129, 200, 196 };
    for (sizes) |sz| {
        chunked_len += chunk_fir.process(x[pos .. pos + sz], chunked[chunked_len..]);
        pos += sz;
    }
    try std.testing.expectEqual(@as(usize, 600), pos);

    try expectClose(whole[0..whole_len], chunked[0..chunked_len], 1e-5);
}
