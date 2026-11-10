//! Decimating FIR filter for complex samples, with real or complex taps.
//!
//! Only every D-th output is computed, so the cost scales with the output
//! rate instead of the input rate. Tap count, decimation factor, and tap type
//! are comptime, so the vector loop is fully unrolled.
//!
//! The history is a doubled ring buffer: each sample is written at `slot` and
//! `slot + Padded`, so the newest `Padded` samples always sit contiguously in
//! memory. Each output is then a straight run of SIMD multiply-adds over that
//! window. Taps are stored reversed and zero-padded to a whole number of
//! vectors, so the padding adds no contribution.

const std = @import("std");
const radio = @import("radio");
const Complex = std.math.Complex(f32);

pub const Lanes = 8;
const Vec = @Vector(Lanes, f32);

/// `Tap` is `f32` (real taps) or `Complex` (complex taps).
pub fn DecimatingFIR(comptime N: usize, comptime D: usize, comptime Tap: type) type {
    comptime {
        if (N == 0) @compileError("DecimatingFIR needs at least one tap");
        if (D == 0) @compileError("DecimatingFIR decimation must be at least 1");
        if (Tap != f32 and Tap != Complex) @compileError("DecimatingFIR taps must be f32 or Complex(f32)");
    }

    const is_complex = Tap == Complex;
    const Padded = std.mem.alignForward(usize, N, Lanes);
    const Chunks = Padded / Lanes;

    return struct {
        const Self = @This();

        pub const tap_count = N;
        pub const decimation = D;

        /// taps_re[c] (and taps_im[c], for complex taps) hold reversed,
        /// zero-padded taps for window positions c*Lanes .. c*Lanes+Lanes-1.
        /// Window position Padded-1 is the newest sample and gets h[0].
        taps_re: [Chunks]Vec = @splat(@splat(0)),
        taps_im: [if (is_complex) Chunks else 0]Vec = if (is_complex) @splat(@splat(0)) else .{},
        hist_re: [2 * Padded]f32 = @splat(0),
        hist_im: [2 * Padded]f32 = @splat(0),
        /// Ring slot that the next sample overwrites. It is also the oldest
        /// sample in the window.
        slot: usize = 0,
        /// Input samples since the last output, modulo D.
        phase: usize = 0,

        /// Install filter taps `h`, where h[k] multiplies the sample k steps back.
        pub fn setTaps(self: *Self, h: *const [N]Tap) void {
            var rev_re: [Padded]f32 = @splat(0);
            var rev_im: [Padded]f32 = @splat(0);
            for (0..N) |k| {
                if (is_complex) {
                    rev_re[Padded - 1 - k] = h[k].re;
                    rev_im[Padded - 1 - k] = h[k].im;
                } else {
                    rev_re[Padded - 1 - k] = h[k];
                }
            }
            for (0..Chunks) |c| {
                self.taps_re[c] = rev_re[c * Lanes ..][0..Lanes].*;
                if (is_complex) self.taps_im[c] = rev_im[c * Lanes ..][0..Lanes].*;
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

            return self.dot();
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

        inline fn dot(self: *const Self) Complex {
            if (is_complex) {
                // (tr + j ti)(xr + j xi) = (tr xr - ti xi) + j (tr xi + ti xr)
                var acc_re: Vec = @splat(0);
                var acc_im: Vec = @splat(0);
                inline for (0..Chunks) |c| {
                    const xr: Vec = self.hist_re[self.slot + c * Lanes ..][0..Lanes].*;
                    const xi: Vec = self.hist_im[self.slot + c * Lanes ..][0..Lanes].*;
                    const tr = self.taps_re[c];
                    const ti = self.taps_im[c];
                    acc_re += tr * xr - ti * xi;
                    acc_im += tr * xi + ti * xr;
                }
                return .{ .re = @reduce(.Add, acc_re), .im = @reduce(.Add, acc_im) };
            } else {
                var acc_re: Vec = @splat(0);
                var acc_im: Vec = @splat(0);
                inline for (0..Chunks) |c| {
                    const xr: Vec = self.hist_re[self.slot + c * Lanes ..][0..Lanes].*;
                    const xi: Vec = self.hist_im[self.slot + c * Lanes ..][0..Lanes].*;
                    acc_re += xr * self.taps_re[c];
                    acc_im += xi * self.taps_re[c];
                }
                return .{ .re = @reduce(.Add, acc_re), .im = @reduce(.Add, acc_im) };
            }
        }
    };
}

/// Flowgraph block for a complex lowpass with `N` real taps and decimation `D`.
/// Taps are designed in `initialize` from the input rate, using the same
/// Hamming-windowed sinc as zigradio's LowpassFilterBlock.
/// Ports: in1 (Complex(f32)) -> out1 (Complex(f32)).
pub fn LowpassFIRBlock(comptime N: usize, comptime D: usize) type {
    return struct {
        const Self = @This();

        block: radio.Block,
        /// Lowpass cutoff in Hz.
        cutoff: f32,
        input_rate: f64 = 0,
        fir: DecimatingFIR(N, D, f32) = .{},

        pub fn init(cutoff: f32) Self {
            return .{ .block = radio.Block.init(@This()), .cutoff = cutoff };
        }

        pub fn setRate(self: *Self, upstream_rate: f64) !f64 {
            self.input_rate = upstream_rate;
            return upstream_rate / @as(f64, D);
        }

        pub fn initialize(self: *Self, _: std.mem.Allocator, _: std.Io) !void {
            const nyquist: f32 = @floatCast(self.input_rate / 2);
            const h = radio.utils.filter.firwinLowpass(N, self.cutoff / nyquist, .Hamming);
            self.fir.setTaps(&h);
            self.fir.reset();
        }

        pub fn process(self: *Self, x: []const Complex, z: []Complex) !radio.ProcessResult {
            const produced = self.fir.process(x, z);
            return radio.ProcessResult.init(&[1]usize{x.len}, &[1]usize{produced});
        }
    };
}

/// Flowgraph block for a complex bandpass with `N` complex taps and decimation 1.
/// Taps are designed in `initialize` from the input rate, using the same design
/// as zigradio's ComplexBandpassFilterBlock.
/// Ports: in1 (Complex(f32)) -> out1 (Complex(f32)).
pub fn BandpassFIRBlock(comptime N: usize) type {
    return struct {
        const Self = @This();

        block: radio.Block,
        /// Passband edges in Hz.
        cutoffs: struct { f32, f32 },
        input_rate: f64 = 0,
        fir: DecimatingFIR(N, 1, Complex) = .{},

        pub fn init(cutoffs: struct { f32, f32 }) Self {
            return .{ .block = radio.Block.init(@This()), .cutoffs = cutoffs };
        }

        pub fn setRate(self: *Self, upstream_rate: f64) !f64 {
            self.input_rate = upstream_rate;
            return upstream_rate;
        }

        pub fn initialize(self: *Self, _: std.mem.Allocator, _: std.Io) !void {
            const nyquist: f32 = @floatCast(self.input_rate / 2);
            const taps = radio.utils.filter.firwinComplexBandpass(N, .{ self.cutoffs[0] / nyquist, self.cutoffs[1] / nyquist }, .Hamming);
            self.fir.setTaps(&taps);
            self.fir.reset();
        }

        pub fn process(self: *Self, x: []const Complex, z: []Complex) !radio.ProcessResult {
            const produced = self.fir.process(x, z);
            return radio.ProcessResult.init(&[1]usize{x.len}, &[1]usize{produced});
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

/// Same as referenceDecimate, for complex taps.
fn referenceDecimateComplex(comptime N: usize, comptime D: usize, h: *const [N]Complex, x: []const Complex, out: []Complex) usize {
    var produced: usize = 0;
    var n: usize = 0;
    while (n < x.len) : (n += D) {
        var acc = Complex{ .re = 0, .im = 0 };
        for (0..N) |k| {
            if (k > n) break;
            acc = acc.add(h[k].mul(x[n - k]));
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

    var fir: DecimatingFIR(N, D, f32) = .{};
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

    var fir: DecimatingFIR(N, D, f32) = .{};
    fir.setTaps(&h);
    var actual: [50]Complex = undefined;
    const act_len = fir.process(&x, &actual);

    try expectClose(expected[0..exp_len], actual[0..act_len], 1e-4);
}

test "DecimatingFIR with complex taps matches direct convolution" {
    const N = 13;
    const D = 2;
    var prng = std.Random.DefaultPrng.init(11);
    const random = prng.random();

    var h: [N]Complex = undefined;
    for (&h) |*t| t.* = .{ .re = random.float(f32) - 0.5, .im = random.float(f32) - 0.5 };

    var x: [200]Complex = undefined;
    for (&x) |*s| s.* = .{ .re = random.float(f32) - 0.5, .im = random.float(f32) - 0.5 };

    var expected: [200]Complex = undefined;
    const exp_len = referenceDecimateComplex(N, D, &h, &x, &expected);

    var fir: DecimatingFIR(N, D, Complex) = .{};
    fir.setTaps(&h);
    var actual: [200]Complex = undefined;
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

    var whole_fir: DecimatingFIR(N, D, f32) = .{};
    whole_fir.setTaps(&h);
    var whole: [600]Complex = undefined;
    const whole_len = whole_fir.process(&x, &whole);

    // Same input, fed in uneven chunks. Output must not change.
    var chunk_fir: DecimatingFIR(N, D, f32) = .{};
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

test "LowpassFIRBlock matches zigradio's LowpassFilterBlock" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const rate: f64 = 300e3;
    const cutoff: f32 = 15e3;

    var reference = radio.blocks.LowpassFilterBlock(Complex, 128).init(cutoff, .{});
    _ = try reference.block.setRate(rate);
    try reference.initialize(alloc, io);
    defer reference.deinitialize(alloc, io);

    var ours = LowpassFIRBlock(128, 1).init(cutoff);
    _ = try ours.block.setRate(rate);
    try ours.initialize(alloc, io);

    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    var x: [3000]Complex = undefined;
    for (&x) |*s| s.* = .{ .re = random.float(f32) - 0.5, .im = random.float(f32) - 0.5 };

    var expected: [3000]Complex = undefined;
    const exp = try reference.process(&x, &expected);
    var actual: [3000]Complex = undefined;
    const got = try ours.process(&x, &actual);

    try std.testing.expectEqual(exp.samples_produced[0], got.samples_produced[0]);
    for (expected[0..exp.samples_produced[0]], actual[0..got.samples_produced[0]]) |e, a| {
        try std.testing.expectApproxEqAbs(e.re, a.re, 1e-4);
        try std.testing.expectApproxEqAbs(e.im, a.im, 1e-4);
    }
}

test "BandpassFIRBlock matches zigradio's ComplexBandpassFilterBlock" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const rate: f64 = 300e3;
    const cutoffs = .{ 18e3, 20e3 };

    var reference = radio.blocks.ComplexBandpassFilterBlock(129).init(cutoffs, .{});
    _ = try reference.block.setRate(rate);
    try reference.initialize(alloc, io);
    defer reference.deinitialize(alloc, io);

    var ours = BandpassFIRBlock(129).init(cutoffs);
    _ = try ours.block.setRate(rate);
    try ours.initialize(alloc, io);

    var prng = std.Random.DefaultPrng.init(5);
    const random = prng.random();
    var x: [3000]Complex = undefined;
    for (&x) |*s| s.* = .{ .re = random.float(f32) - 0.5, .im = random.float(f32) - 0.5 };

    var expected: [3000]Complex = undefined;
    const exp = try reference.process(&x, &expected);
    var actual: [3000]Complex = undefined;
    const got = try ours.process(&x, &actual);

    try std.testing.expectEqual(exp.samples_produced[0], got.samples_produced[0]);
    for (expected[0..exp.samples_produced[0]], actual[0..got.samples_produced[0]]) |e, a| {
        try std.testing.expectApproxEqAbs(e.re, a.re, 1e-4);
        try std.testing.expectApproxEqAbs(e.im, a.im, 1e-4);
    }
}
