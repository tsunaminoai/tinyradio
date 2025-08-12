const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
const radio = @import("radio");

pub const RadioReceiver = struct {
    allocator: std.mem.Allocator,
    flowgraph: radio.Flowgraph,
    source: radio.blocks.RtlSdrSource,
    sink: radio.blocks.PulseAudioSink(2),

    // base nodes
    tuner: radio.blocks.TunerBlock,
    af_gain_left: GainBlock,
    af_gain_right: GainBlock,
    power_meter: radio.blocks.PowerMeterBlock(f32),
    agc: radio.blocks.AGCBlock(f32),

    // demodulators
    fm: radio.blocks.WBFMMonoDemodulatorBlock,
    fm_stereo: radio.blocks.WBFMStereoDemodulatorBlock,
    am: radio.blocks.AMEnvelopeDemodulatorBlock,
    debug: bool = false,

    const tune_offset = -0e3;

    pub fn init(allocator: std.mem.Allocator, debug: bool) !RadioReceiver {
        var r = RadioReceiver{
            .allocator = allocator,
            .debug = debug,
            .flowgraph = radio.Flowgraph.init(allocator, .{ .debug = debug }),
            .source = undefined,
            .sink = radio.blocks.PulseAudioSink(2).init(),
            .tuner = radio.blocks.TunerBlock.init(tune_offset, 200e3, 4),
            .af_gain_left = GainBlock.init(0.3),
            .af_gain_right = GainBlock.init(0.3),
            .fm = .init(.{}),
            .fm_stereo = .init(.{}),
            .am = .init(.{}),
            .power_meter = .init(50, .{}),

            .agc = radio.blocks.AGCBlock(f32).init(.{ .preset = .Fast }, .{}),
        };
        errdefer r.source.deinitialize(allocator);
        errdefer r.flowgraph.deinit();

        return r;
    }

    pub fn deinit(self: *RadioReceiver) void {
        self.flowgraph.deinit();
        // if (self.source) |source| source.deinit();
        // if (self.sink) |sink| sink.deinit();
        // if (self.fm_demod) |demod| demod.deinit();
        // if (self.fm_filter) |filter| filter.deinit();
        // self.context.deinit();
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
    }

    pub fn connect(self: *RadioReceiver, band: Band) !void {
        // Source → [TunerBlock] → [Demodulator] → [LowpassFilterBlock] →
        // [PowerMeterBlock] → [Audio Sink (e.g., PulseAudioSink)]
        var wasRunning = false;
        if (self.flowgraph.run_state) |_| {
            _ = try self.flowgraph.stop();
            wasRunning = true;
            self.flowgraph.deinit();
            self.flowgraph = .init(self.allocator, .{ .debug = self.debug });
        }
        try self.setupRTL(band);

        // Connect the processing chain
        try self.flowgraph.connect(&self.source.block, &self.tuner.block);
        switch (band) {
            .FM => {
                try self.flowgraph.connectPort(&self.tuner.block, "out1", &self.fm.block, "in1");
                try self.flowgraph.connectPort(&self.fm.block, "out1", &self.power_meter.block, "in1");
                try self.flowgraph.connectPort(&self.fm.block, "out1", &self.af_gain_left.block, "in1");
                try self.flowgraph.connectPort(&self.fm.block, "out1", &self.af_gain_right.block, "in1");
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
        _ = try self.flowgraph.stop();
    }
    pub fn getPower(self: RadioReceiver) f32 {
        return self.power_meter.average_power;
    }

    pub fn getAudioSamples(self: *RadioReceiver, buffer: []f32) !usize {
        _ = self; // autofix
        _ = buffer; // autofix
        // Get demodulated audio samples
        // return self.sink.read(buffer);
        return 0;
    }
};

test {
    var r = try RadioReceiver.init(tst.allocator, true);
    defer r.deinit();

    try r.connect(.FM);
    try r.start();
    // radio.platform.waitForInterrupt();
    try r.stop();
}

pub const GainBlock = struct {
    block: radio.Block,
    gain: f32,
    const Self = @This();

    pub fn init(initial_gain: f32) GainBlock {
        return .{
            .block = radio.Block.init(Self),
            .gain = initial_gain,
        };
    }
    pub fn setGain(self: *Self, linear_gain: f32) void {
        self.gain = linear_gain;
    }

    pub fn setGainDB(self: *Self, gain_db: f32) void {
        const linear_gain = std.math.pow(f32, 10.0, gain_db / 20.0);
        self.gain = linear_gain;
    }

    // ZigRadio block interface method

    pub fn process(self: *Self, input: []const f32, output: []f32) !radio.ProcessResult {
        var idx: usize = 0;
        while (idx < input.len) {
            output[idx] = input[idx] * self.gain;
            idx += 1;
        }
        return radio.ProcessResult.init(&[1]usize{input.len}, &[1]usize{idx});
    }
};

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
