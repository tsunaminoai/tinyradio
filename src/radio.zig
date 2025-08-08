const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
const radio = @import("radio");
const rl = @import("raylib");

pub const RadioReceiver = struct {
    allocator: std.mem.Allocator,
    flowgraph: radio.Flowgraph,
    source: radio.blocks.RtlSdrSource,
    sink: radio.blocks.PulseAudioSink(1),

    // FM demodulation chain

    tuner: radio.blocks.TunerBlock,
    fm_demod: radio.blocks.FrequencyDiscriminatorBlock,
    af_filter: radio.blocks.LowpassFilterBlock(f32, 128),
    af_deemphasis: radio.blocks.SinglepoleLowpassFilterBlock(f32),
    af_downsampler: radio.blocks.DownsamplerBlock(f32),
    af_gain: GainBlock,
    agc: radio.blocks.AGCBlock(f32),

    const tune_offset = -0e3;

    pub fn init(allocator: std.mem.Allocator, debug: bool) !RadioReceiver {
        const r = RadioReceiver{
            .allocator = allocator,
            .flowgraph = radio.Flowgraph.init(allocator, .{ .debug = debug }),
            .source = radio.blocks.RtlSdrSource.init(
                88.5e6, // 88.5 MHz
                2.4e6, // 2.4 MS/s
                .{
                    .rf_gain = 30.0,
                },
            ),
            .sink = radio.blocks.PulseAudioSink(1).init(),
            .tuner = radio.blocks.TunerBlock.init(tune_offset, 200e3, 4),
            .fm_demod = radio.blocks.FrequencyDiscriminatorBlock.init(75e3),
            .af_filter = radio.blocks.LowpassFilterBlock(f32, 128).init(15e3, .{}),
            .af_deemphasis = radio.blocks.FMDeemphasisFilterBlock.init(75e-6),
            .af_downsampler = radio.blocks.DownsamplerBlock(f32).init(5),
            .af_gain = GainBlock.init(0.3),
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

    pub fn connect(self: *RadioReceiver) !void {

        // Connect the processing chain
        try self.flowgraph.connect(&self.source.block, &self.tuner.block);
        // try self.flowgraph.connect(&self.agc.block, &self.tuner.block);
        try self.flowgraph.connect(&self.tuner.block, &self.fm_demod.block);
        try self.flowgraph.connect(&self.fm_demod.block, &self.af_filter.block);
        try self.flowgraph.connect(&self.af_filter.block, &self.af_deemphasis.block);
        try self.flowgraph.connect(&self.af_deemphasis.block, &self.af_downsampler.block);
        try self.flowgraph.connect(&self.af_downsampler.block, &self.af_gain.block);
        try self.flowgraph.connect(&self.af_gain.block, &self.sink.block);
    }

    pub fn setFrequency(self: *RadioReceiver, freq_mhz: f32) !void {
        try self.source.setFrequency(freq_mhz * 1e6);
    }

    pub fn setGain(self: *RadioReceiver, gain_db: f32) !void {
        self.af_gain.setGainDB(gain_db); // Set gain in dB
    }

    pub fn start(self: *RadioReceiver) !void {
        try self.flowgraph.start();
    }

    pub fn stop(self: *RadioReceiver) !void {
        _ = try self.flowgraph.stop();
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

    try r.connect();
    try r.start();
    radio.platform.waitForInterrupt();
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
    pub fn setGain(self: *Self, new_gain: f32) void {
        self.gain = new_gain;
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
pub const ComplexGainBlock = struct {
    block: radio.Block,
    gain: f32,

    const Self = @This();
    const Complex = std.math.Complex(f32);

    pub fn init(initial_gain: f32) Self {
        return Self{
            .block = radio.Block.init("ComplexGainBlock", Self, &.{
                .{ .name = "in", .type = Complex },
            }, &.{
                .{ .name = "out", .type = Complex },
            }),
            .gain = initial_gain,
        };
    }

    pub fn setGain(self: *Self, new_gain: f32) void {
        self.gain = new_gain;
    }

    pub fn setGainDB(self: *Self, gain_db: f32) void {
        const linear_gain = std.math.pow(f32, 10.0, gain_db / 20.0);
        self.gain = linear_gain;
    }

    pub fn process(self: *Self, input: []const Complex, output: []Complex) void {
        for (input, 0..) |sample, i| {
            output[i] = Complex{
                .re = sample.re * self.gain,
                .im = sample.im * self.gain,
            };
        }
    }
};
