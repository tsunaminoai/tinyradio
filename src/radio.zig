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
    agc: radio.blocks.AGCBlock(f32),

    const tune_offset = -250e3;

    pub fn init(allocator: std.mem.Allocator) !RadioReceiver {
        const r = RadioReceiver{
            .allocator = allocator,
            .flowgraph = radio.Flowgraph.init(allocator, .{ .debug = true }),
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
            .agc = radio.blocks.AGCBlock(f32).init(.{ .preset = .Fast }, .{}),
        };
        // try r.connect();
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
        try self.flowgraph.connect(&self.source.block, &self.agc.block);
        try self.flowgraph.connect(&self.agc.block, &self.tuner.block);
        try self.flowgraph.connect(&self.tuner.block, &self.fm_demod.block);
        try self.flowgraph.connect(&self.fm_demod.block, &self.af_filter.block);
        try self.flowgraph.connect(&self.af_filter.block, &self.af_deemphasis.block);
        try self.flowgraph.connect(&self.af_deemphasis.block, &self.af_downsampler.block);
        try self.flowgraph.connect(&self.af_downsampler.block, &self.sink.block);
    }

    pub fn setFrequency(self: *RadioReceiver, freq_mhz: f32) !void {
        try self.source.setFrequency(freq_mhz * 1e6);
    }

    pub fn setGain(self: *RadioReceiver, gain_db: f32) !void {
        try self.source.setGain(gain_db);
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
    var r = try RadioReceiver.init(tst.allocator);
    defer r.deinit();

    try r.connect();
    try r.start();
    radio.platform.waitForInterrupt();
    try r.stop();
}
