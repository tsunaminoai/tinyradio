//! Channel tuner: optional frequency shift, lowpass filtering, and decimation
//! in a single pass.
//!
//! zigradio's TunerBlock runs a full-rate lowpass and then a downsampler that
//! throws away most of the filtered samples. This block runs the decimating
//! FIR instead, so it computes only the outputs it keeps.

const std = @import("std");
const radio = @import("radio");
const ztracy = @import("ztracy");

const Complex = std.math.Complex(f32);
const DecimatingFIR = @import("decimating_fir.zig").DecimatingFIR;

/// A tuner with `taps` lowpass taps, keeping every `D`-th sample.
/// Ports: in1 (Complex(f32)) -> out1 (Complex(f32)).
pub fn TunerBlock(comptime taps: usize, comptime D: usize) type {
    return struct {
        const Self = @This();
        const Fir = DecimatingFIR(taps, D, f32);

        block: radio.Block,
        /// Frequency shift applied before filtering, in Hz.
        offset: f32,
        /// Two-sided passband width in Hz. The lowpass cutoff is bandwidth/2.
        bandwidth: f32,

        input_rate: f64 = 0,
        omega: f32 = 0,
        phase: f32 = 0,
        fir: Fir = .{},

        pub fn init(offset: f32, bandwidth: f32) Self {
            return .{ .block = radio.Block.init(@This()), .offset = offset, .bandwidth = bandwidth };
        }

        pub fn setRate(self: *Self, upstream_rate: f64) !f64 {
            self.input_rate = upstream_rate;
            return upstream_rate / @as(f64, D);
        }

        pub fn initialize(self: *Self, _: std.mem.Allocator, _: std.Io) !void {
            // Same design as zigradio's LowpassFilterBlock: Hamming-windowed sinc
            // at cutoff / nyquist, where nyquist is the input rate's half.
            const nyquist: f32 = @floatCast(self.input_rate / 2);
            const h = radio.utils.filter.firwinLowpass(taps, (self.bandwidth / 2) / nyquist, .Hamming);
            self.fir.setTaps(&h);

            self.omega = @floatCast(2 * std.math.pi * self.offset / self.input_rate);
            self.phase = 0;
        }

        pub fn process(self: *Self, x: []const Complex, z: []Complex) !radio.ProcessResult {
            const zone = ztracy.ZoneN(@src(), "tuner");
            defer zone.End();

            var produced: usize = 0;
            if (self.offset == 0) {
                // No shift needed, so skip the per-sample rotation entirely.
                produced = self.fir.process(x, z);
            } else {
                // Same convention as zigradio's FrequencyTranslatorBlock:
                // multiply by exp(j * phase), with phase += omega each sample.
                for (x) |s| {
                    const rot: Complex = .{ .re = @cos(self.phase), .im = @sin(self.phase) };
                    self.phase += self.omega;
                    if (self.phase > std.math.pi or self.phase < -std.math.pi) {
                        self.phase -= std.math.copysign(@as(f32, 2 * std.math.pi), self.omega);
                    }
                    if (self.fir.step(s.mul(rot))) |y| {
                        z[produced] = y;
                        produced += 1;
                    }
                }
            }

            return radio.ProcessResult.init(&[1]usize{x.len}, &[1]usize{produced});
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "TunerBlock output matches zigradio's lowpass + downsampler" {
    const Lowpass = radio.blocks.LowpassFilterBlock(Complex, 64);
    const Downsampler = radio.blocks.DownsamplerBlock(Complex);
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const rate: f64 = 1.2e6;
    const factor = 4;
    const bandwidth: f32 = 200e3;

    // Reference chain: lowpass at full rate, then keep every 4th sample.
    var lp = Lowpass.init(bandwidth / 2, .{});
    _ = try lp.block.setRate(rate);
    try lp.initialize(alloc, io);
    defer lp.deinitialize(alloc, io);

    var ds = Downsampler.init(factor);
    _ = try ds.block.setRate(rate);

    // Our tuner.
    var tuner = TunerBlock(64, factor).init(0, bandwidth);
    _ = try tuner.block.setRate(rate);
    try tuner.initialize(alloc, io);

    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var x: [4000]Complex = undefined;
    for (&x) |*s| s.* = .{ .re = random.float(f32) - 0.5, .im = random.float(f32) - 0.5 };

    var filtered: [4000]Complex = undefined;
    _ = try lp.process(&x, &filtered);
    var expected: [4000]Complex = undefined;
    const exp = try ds.process(&filtered, &expected);

    var actual: [4000]Complex = undefined;
    const got = try tuner.process(&x, &actual);

    try std.testing.expectEqual(exp.samples_produced[0], got.samples_produced[0]);
    for (expected[0..exp.samples_produced[0]], actual[0..got.samples_produced[0]]) |e, a| {
        try std.testing.expectApproxEqAbs(e.re, a.re, 1e-4);
        try std.testing.expectApproxEqAbs(e.im, a.im, 1e-4);
    }
}
