const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;

const radio = @import("radio");
const TunerBlock = @import("tuner.zig").TunerBlock;
const WBFMStereoDemodulatorBlock = @import("stereo.zig").WBFMStereoDemodulatorBlock;
const Spectrum = @import("spectrum.zig").Spectrum;
const rds = @import("rds.zig");
const e = @import("effects.zig");
const Complex = std.math.Complex(f32);

test {
    _ = @import("tuner.zig");
    _ = @import("decimating_fir.zig");
    _ = @import("stereo.zig");
    _ = @import("spectrum.zig");
    _ = @import("rds.zig");
    _ = @import("effects.zig");
}

pub const RadioReceiver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    flowgraph: radio.Flowgraph,
    source: radio.blocks.RtlSdrSource,
    sink: radio.blocks.PulseAudioSink(2),
    data_sink: radio.blocks.PrintSink(rds.RDSDecoderBlock.RDSData),

    // base nodes
    tuner: TunerBlock(64, 4),
    af_gain_left: GainBlock,
    af_gain_right: GainBlock,
    /// Power of the tuner output, i.e. the signal in the selected channel.
    power_meter: radio.blocks.PowerMeterBlock(Complex),
    /// FFT of the tuner output, read by the UI.
    spectrum: Spectrum,
    agc: radio.blocks.AGCBlock(f32),
    /// Tape-style effect on the mono FM path. Toggled with toggleEffects().
    effect: e.TapeSimulator,
    effect2: e.TapeSimulator,

    // demodulators
    fm: radio.blocks.WBFMMonoDemodulatorBlock,
    fm_stereo: WBFMStereoDemodulatorBlock,
    am: radio.blocks.AMEnvelopeDemodulatorBlock,
    debug: bool = false,

    // RDS, decoded from the tuner output in stereo FM. Rebuilt on each connect().
    rds: rds.RDS,
    rds_initialized: bool = false,

    const tune_offset = -0e3;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, debug: bool) !RadioReceiver {
        const r = RadioReceiver{
            .allocator = allocator,
            .io = io,
            .debug = debug,
            .flowgraph = radio.Flowgraph.init(allocator, io, .{ .debug = debug }),
            .source = undefined,
            .sink = radio.blocks.PulseAudioSink(2).init(),
            .data_sink = .init(),
            .tuner = .init(tune_offset, 200e3),
            .af_gain_left = GainBlock.init(0.3),
            .af_gain_right = GainBlock.init(0.3),
            .fm = .init(.{}),
            .fm_stereo = .init(.{}),
            .am = .init(.{}),
            .power_meter = .init(50, .{ .power_tau = 0.05 }),
            .spectrum = Spectrum.init(),
            .effect = try .init(allocator, 32_000),
            .effect2 = try .init(allocator, 32_000),
            .rds = undefined,

            .agc = radio.blocks.AGCBlock(f32).init(.{ .preset = .Fast }, .{}),
        };
        return r;
    }

    // The flowgraph owns the RTL-SDR source lifecycle: it initializes the
    // source in start() and deinitializes all blocks when a run ends (wait()).
    // Deinitializing the source here as well would close the device and free
    // its buffer a second time.
    pub fn deinit(self: *RadioReceiver) void {
        self.flowgraph.deinit();
        if (self.rds_initialized) self.rds.deinit();
        self.effect.deinit();
        self.effect2.deinit();
    }

    fn setupRTL(self: *RadioReceiver, band: Band) !void {
        self.source = switch (band) {
            .FM, .FM_Stereo => radio.blocks.RtlSdrSource.init(
                91.9e6,
                1_200_000,
                .{
                    .rf_gain = 30.0,
                },
            ),
            .AM => radio.blocks.RtlSdrSource.init(
                1450e3,
                960_000,
                .{
                    .direct_sampling = .Q, // Enable direct sampling
                    .rf_gain = 30.0,
                },
            ),
        };
        if (self.rds_initialized) self.rds.deinit();
        self.rds = try .init(self.allocator, .{
            .frequency = @as(f32, @floatCast(self.source.frequency)),
        });
        self.rds_initialized = true;
    }

    pub fn connect(self: *RadioReceiver, band: Band) !void {
        // Source → [TunerBlock] → [Demodulator] → [LowpassFilterBlock] →
        // [PowerMeterBlock] → [Audio Sink (e.g., PulseAudioSink)]
        var wasRunning = false;
        if (self.flowgraph.run_state) |_| {
            _ = try self.flowgraph.stop();
            wasRunning = true;
            self.flowgraph.deinit();
            self.flowgraph = .init(self.allocator, self.io, .{ .debug = self.debug });
        }
        try self.setupRTL(band);

        // Connect the processing chain
        try self.flowgraph.connect(&self.source.block, &self.tuner.block);
        try self.flowgraph.connectPort(&self.tuner.block, "out1", &self.power_meter.block, "in1");
        try self.flowgraph.connectPort(&self.tuner.block, "out1", &self.spectrum.block, "in1");
        switch (band) {
            .FM => {
                try self.flowgraph.connectPort(&self.tuner.block, "out1", &self.fm.block, "in1");
                try self.flowgraph.connectPort(&self.fm.block, "out1", &self.effect.block, "in1");
                try self.flowgraph.connectPort(&self.effect.block, "out1", &self.af_gain_left.block, "in1");
                try self.flowgraph.connectPort(&self.effect.block, "out1", &self.af_gain_right.block, "in1");
                try self.flowgraph.connectPort(&self.af_gain_left.block, "out1", &self.sink.block, "in1");
                try self.flowgraph.connectPort(&self.af_gain_right.block, "out1", &self.sink.block, "in2");
            },
            .AM => {
                try self.flowgraph.connectPort(&self.tuner.block, "out1", &self.am.block, "in1");
                try self.flowgraph.connectPort(&self.am.block, "out1", &self.af_gain_left.block, "in1");
                try self.flowgraph.connectPort(&self.am.block, "out1", &self.af_gain_right.block, "in1");
                try self.flowgraph.connectPort(&self.af_gain_left.block, "out1", &self.sink.block, "in1");
                try self.flowgraph.connectPort(&self.af_gain_right.block, "out1", &self.sink.block, "in2");
            },
            .FM_Stereo => {
                try self.flowgraph.connectPort(&self.tuner.block, "out1", &self.fm_stereo.block, "in1");
                try self.flowgraph.connectPort(&self.tuner.block, "out1", &self.rds.block, "in1");
                try self.flowgraph.connectPort(&self.rds.block, "out1", &self.data_sink.block, "in1");
                try self.flowgraph.connectPort(&self.fm_stereo.block, "out1", &self.af_gain_left.block, "in1");
                try self.flowgraph.connectPort(&self.fm_stereo.block, "out2", &self.af_gain_right.block, "in1");
                try self.flowgraph.connectPort(&self.af_gain_left.block, "out1", &self.sink.block, "in1");
                try self.flowgraph.connectPort(&self.af_gain_right.block, "out1", &self.sink.block, "in2");
            },
        }
        if (wasRunning)
            try self.flowgraph.start();
    }

    pub fn setFrequency(self: *RadioReceiver, freq_mhz: f32) !void {
        try self.source.setFrequency(freq_mhz * 1e6);
    }

    pub fn setGain(self: *RadioReceiver, linear_gain: f32) !void {
        self.af_gain_left.setGain(linear_gain); // Set gain in dB
        self.af_gain_right.setGain(linear_gain); // Set gain in dB
    }

    pub fn start(self: *RadioReceiver) !void {
        _ = try self.flowgraph.start();
    }

    pub fn stop(self: *RadioReceiver) !void {
        // Nothing to stop if the flowgraph isn't running (e.g. quit before play).
        if (self.flowgraph.run_state == null) return;
        _ = try self.flowgraph.stop();
    }
    pub fn getPower(self: RadioReceiver) f32 {
        return self.power_meter.average_power;
    }

    /// Latest decoded RDS group data, or null before RDS is set up.
    pub fn getRDSData(self: *RadioReceiver) ?rds.RDSDecoderBlock.RDSData {
        if (!self.rds_initialized) return null;
        return self.rds.decoder.getRDSData();
    }

    pub fn toggleEffects(self: *RadioReceiver) void {
        self.effect.enabled = !self.effect.enabled;
        self.effect2.enabled = !self.effect2.enabled;
    }

    /// Channel power in dBFS. Full-scale complex input is 0 dB.
    pub fn signalDb(self: *const RadioReceiver) f32 {
        return powerToDb(self.power_meter.average_power);
    }

    /// 19 kHz pilot power in dBFS. A strong pilot means the station is in stereo.
    pub fn pilotDb(self: *const RadioReceiver) f32 {
        return powerToDb(self.fm_stereo.pilot_power.average_power);
    }

    fn powerToDb(power: f32) f32 {
        return 10.0 * math.log10(power + 1e-12);
    }

    pub fn getAudioSamples(self: *RadioReceiver, buffer: []f32) !usize {
        _ = self; // autofix
        _ = buffer; // autofix
        // Get demodulated audio samples
        // return self.sink.read(buffer);
        return 0;
    }
};

// Skipping hardware-dependent test in ci-builds
// test {
//     var r = try RadioReceiver.init(tst.allocator, true);
//     defer r.deinit();
//
//     try r.connect(.FM);
//     try r.start();
//     // radio.platform.waitForInterrupt();
//     try r.stop();
// }

/// Audio gain that glides to its target instead of jumping, so mute, unmute,
/// and volume changes don't click. The target is set from the UI thread and
/// read by the audio thread, so it is stored atomically.
pub const GainBlock = struct {
    /// Time constant of the glide, in seconds. About 99% of a change is
    /// done after five of these.
    const glide_seconds = 0.02;

    block: radio.Block,
    /// Current gain, updated once per sample by the audio thread.
    gain: f32,
    target: std.atomic.Value(u32),
    /// Per-sample smoothing factor. Set from the sample rate. Until then
    /// gain jumps straight to the target.
    alpha: f32 = 1,
    const Self = @This();

    pub fn init(initial_gain: f32) GainBlock {
        return .{
            .block = radio.Block.init(Self),
            .gain = initial_gain,
            .target = .init(@bitCast(initial_gain)),
        };
    }

    /// Set the linear gain to glide to. Safe to call from another thread.
    pub fn setGain(self: *Self, linear_gain: f32) void {
        self.target.store(@bitCast(linear_gain), .monotonic);
    }

    pub fn setGainDB(self: *Self, gain_db: f32) void {
        self.setGain(std.math.pow(f32, 10.0, gain_db / 20.0));
    }

    pub fn setRate(self: *Self, upstream_rate: f64) !f64 {
        self.alpha = 1 - @exp(-1.0 / (glide_seconds * @as(f32, @floatCast(upstream_rate))));
        return upstream_rate;
    }

    // ZigRadio block interface method

    pub fn process(self: *Self, input: []const f32, output: []f32) !radio.ProcessResult {
        const target: f32 = @bitCast(self.target.load(.monotonic));
        for (input, output) |x, *y| {
            self.gain += self.alpha * (target - self.gain);
            y.* = x * self.gain;
        }
        return radio.ProcessResult.init(&[1]usize{input.len}, &[1]usize{input.len});
    }
};

test "GainBlock glides to its target" {
    const rate: f64 = 48_000;
    var g = GainBlock.init(0);
    _ = try g.block.setRate(rate);
    g.setGain(1);

    var in: [4800]f32 = @splat(1);
    var out: [4800]f32 = undefined;
    _ = try g.process(&in, &out);

    // Starts near silence, not at full level, so there's no click.
    try tst.expect(out[0] < 0.01);
    // Settled after 100 ms, five time constants.
    try tst.expectApproxEqAbs(@as(f32, 1), out[4799], 0.01);
}

// Radio band definitions
pub const Band =
    enum {
        AM,
        FM,
        FM_Stereo,

        pub fn getRange(self: Band) struct { min: f32, max: f32 } {
            return switch (self) {
                .AM => .{ .min = 530.0, .max = 1710.0 }, // kHz
                .FM, .FM_Stereo => .{ .min = 88.1, .max = 108.0 }, // MHz
            };
        }

        pub fn getDefaultFreq(self: Band) f32 {
            return switch (self) {
                .AM => 1450.0,
                .FM, .FM_Stereo => 91.9,
            };
        }

        pub fn getStepSize(self: Band) f32 {
            return switch (self) {
                .AM => 10.0, // 10 kHz steps
                .FM, .FM_Stereo => 0.1, // 0.1 MHz steps
            };
        }

        pub fn getUnit(self: Band) []const u8 {
            return switch (self) {
                .AM => "kHz",
                .FM, .FM_Stereo => "MHz",
            };
        }
    };

test {
    tst.refAllDecls(@This());
}
