//! Benchmark for the receive chain: tuner -> WBFM stereo demodulator.
//!
//! Feeds a synthetic complex tone through the chain, with no dongle or audio
//! device needed. It runs the zigradio tuner as a baseline and our decimating
//! tuner, and reports the median wall time over several runs.
//!
//! Build and run with: zig build bench
//! Add -Denable_ztracy=true to record Tracy zones for the Tracy GUI.

const std = @import("std");
const radio = @import("radio");
const ztracy = @import("ztracy");
const TunerBlock = @import("tuner.zig").TunerBlock;
const WBFMStereoDemodulatorBlock = @import("stereo.zig").WBFMStereoDemodulatorBlock;

const Complex = std.math.Complex(f32);

const sample_rate: f64 = 1.2e6; // same as the RTL-SDR setup in radio.zig
const audio_seconds: f64 = 5;
const warmup_runs = 1;
const timed_runs = 5;

/// Complex sine source that ends after `total` samples.
const ToneSource = struct {
    block: radio.Block,
    rate: f64,
    remaining: usize,
    phasor: Complex = .{ .re = 1, .im = 0 },
    step: Complex,

    fn init(rate: f64, total: usize, freq_hz: f64) ToneSource {
        const w = 2 * std.math.pi * freq_hz / rate;
        return .{
            .block = radio.Block.init(@This()),
            .rate = rate,
            .remaining = total,
            .step = .{ .re = @floatCast(@cos(w)), .im = @floatCast(@sin(w)) },
        };
    }

    pub fn setRate(self: *ToneSource, _: f64) !f64 {
        return self.rate;
    }

    pub fn process(self: *ToneSource, z: []Complex) !radio.ProcessResult {
        const n = @min(z.len, self.remaining);
        for (z[0..n]) |*s| {
            s.* = self.phasor;
            self.phasor = self.phasor.mul(self.step);
        }
        self.remaining -= n;

        var result = radio.ProcessResult.init(&[0]usize{}, &[1]usize{n});
        result.eos = self.remaining == 0;
        return result;
    }
};

/// Sink that drops everything it receives.
fn Discard(comptime T: type) type {
    return struct {
        const Self = @This();
        block: radio.Block,

        fn init() Self {
            return .{ .block = radio.Block.init(@This()) };
        }

        pub fn process(_: *Self, x: []const T) !radio.ProcessResult {
            return radio.ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
        }
    };
}

/// Which part of the receive chain a run includes.
const Stage = enum {
    /// Tuner only. Output goes to a discard sink.
    tuner,
    /// Tuner plus the WBFM stereo demodulator. This is what the app runs.
    full,
};

/// Run one pass of `total` samples through `tuner`, and through the FM stereo
/// demodulator too when `stage` is `.full`.
fn runChain(comptime TunerT: type, tuner: *TunerT, comptime DemodT: type, comptime stage: Stage, allocator: std.mem.Allocator, io: std.Io, total: usize) !void {
    const zone = ztracy.ZoneN(@src(), "chain run");
    defer zone.End();

    var src = ToneSource.init(sample_rate, total, 100e3);

    var fg = radio.Flowgraph.init(allocator, io, .{});
    defer fg.deinit();
    try fg.connect(&src.block, &tuner.block);

    switch (stage) {
        .tuner => {
            var sink = Discard(Complex).init();
            try fg.connectPort(&tuner.block, "out1", &sink.block, "in1");
        },
        .full => {
            var demod = DemodT.init(.{});
            var left = Discard(f32).init();
            var right = Discard(f32).init();
            try fg.connectPort(&tuner.block, "out1", &demod.block, "in1");
            try fg.connectPort(&demod.block, "out1", &left.block, "in1");
            try fg.connectPort(&demod.block, "out2", &right.block, "in1");
        },
    }
    _ = try fg.run();
}

/// Median wall time in nanoseconds of `timed_runs` passes over `total` samples.
fn benchTuner(comptime TunerT: type, tuner: *TunerT, comptime DemodT: type, comptime stage: Stage, allocator: std.mem.Allocator, io: std.Io, total: usize) !i96 {
    var i: usize = 0;
    while (i < warmup_runs) : (i += 1) try runChain(TunerT, tuner, DemodT, stage, allocator, io, total);

    var times: [timed_runs]i96 = undefined;
    for (&times) |*t| {
        const start = std.Io.Clock.awake.now(io);
        try runChain(TunerT, tuner, DemodT, stage, allocator, io, total);
        const end = std.Io.Clock.awake.now(io);
        t.* = std.Io.Timestamp.durationTo(start, end).toNanoseconds();
        ztracy.FrameMark();
    }
    std.mem.sort(i96, &times, {}, std.sort.asc(i96));
    return times[timed_runs / 2];
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const total: usize = @intFromFloat(sample_rate * audio_seconds);

    const audio_ns: f64 = audio_seconds * std.time.ns_per_s;

    // Baseline: zigradio's lowpass + downsampler tuner.
    var baseline = radio.blocks.TunerBlock.init(0, 200e3, 4);
    const base_tuner = try benchTuner(radio.blocks.TunerBlock, &baseline, radio.blocks.WBFMStereoDemodulatorBlock, .tuner, allocator, io, total);
    var baseline_full = radio.blocks.TunerBlock.init(0, 200e3, 4);
    const base_full = try benchTuner(radio.blocks.TunerBlock, &baseline_full, radio.blocks.WBFMStereoDemodulatorBlock, .full, allocator, io, total);

    // Ours: decimating FIR, 64 taps, keep every 4th sample.
    var ours = TunerBlock(64, 4).init(0, 200e3);
    const ours_tuner = try benchTuner(TunerBlock(64, 4), &ours, WBFMStereoDemodulatorBlock, .tuner, allocator, io, total);
    var ours_full = TunerBlock(64, 4).init(0, 200e3);
    const ours_full_ns = try benchTuner(TunerBlock(64, 4), &ours_full, WBFMStereoDemodulatorBlock, .full, allocator, io, total);

    report("tuner: zigradio", base_tuner, audio_ns);
    report("tuner: decimating FIR", ours_tuner, audio_ns);
    report("full chain: zigradio tuner", base_full, audio_ns);
    report("full chain: decimating FIR", ours_full_ns, audio_ns);
    std.debug.print("tuner speedup: {d:.2}x, full chain speedup: {d:.2}x\n", .{
        ratio(base_tuner, ours_tuner),
        ratio(base_full, ours_full_ns),
    });
}

fn ratio(slow: i96, fast: i96) f64 {
    return @as(f64, @floatFromInt(slow)) / @as(f64, @floatFromInt(fast));
}

fn report(name: []const u8, ns: i96, audio_ns: f64) void {
    const wall_ms = @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
    // Real-time factor: seconds of signal processed per second of wall time.
    const realtime = audio_ns / @as(f64, @floatFromInt(ns));
    std.debug.print("{s:<28} median {d:>8.1} ms for {d:.0} s of 1.2 MS/s IQ  ({d:.1}x realtime)\n", .{ name, wall_ms, audio_seconds, realtime });
}
