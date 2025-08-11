const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;

const radio = @import("radio");

pub const WBFMDemodulatorWithRDS = struct {
    pub const Options = struct {
        deviation: f32 = 75e3,
        af_bandwidth: f32 = 15e3,
        af_deemphasis_tau: f32 = 75e-6,
    };

    block: radio.CompositeBlock,

    fm_demod: radio.blocks.FrequencyDiscriminatorBlock,
    real_to_complex: radio.blocks.RealToComplexBlock,
    delay: radio.blocks.DelayBlock(std.math.Complex(f32)),
    pilot_filter: radio.blocks.ComplexBandpassFilterBlock(129),
    pilot_pll: radio.blocks.ComplexPLLBlock,
    mixer: radio.blocks.MultiplyConjugateBlock,
    // L+R
    lpr_filter: radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 128),
    lpr_am_demod: radio.blocks.ComplexToRealBlock,
    // L-R
    lmr_filter: radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 128),
    lmr_am_demod: radio.blocks.ComplexToRealBlock,
    // L
    l_summer: radio.blocks.AddBlock(f32),
    l_af_deemphasis: radio.blocks.SinglepoleLowpassFilterBlock(f32),
    // R
    r_summer: radio.blocks.SubtractBlock(f32),
    r_af_deemphasis: radio.blocks.SinglepoleLowpassFilterBlock(f32),
    const Self = @This();

    pub fn init() !Self {
        return .{
            .block = .init(Self, &.{"in1"}, &.{ "out1", "out2", "rds1" }),

            .fm_demod = .init(75e3),
            .real_to_complex = .init(),
            .delay = .init(129),
            .pilot_filter = .init(.{ 18e3, 20e3 }, .{}),
            .pilot_pll = .init(500, .{ 19e3 - 100, 19e3 + 100 }, .{ .multiplier = 2 }),
            .mixer = .init(),
            .lpr_filter = .init(15e3, .{}),
            .lpr_am_demod = .init(),
            .lmr_filter = .init(15e3, .{}),
            .lmr_am_demod = .init(),
            .l_summer = .init(),
            .l_af_deemphasis = .init(75e-6),
            .r_summer = .init(),
            .r_af_deemphasis = .init(75e-6),
        };
    }
    pub fn connect(self: *Self, fg: *radio.Flowgraph) !void {
        try fg.connect(&self.fm_demod.block, &self.real_to_complex.block);
        try fg.connect(&self.real_to_complex.block, &self.pilot_filter.block);
        try fg.connect(&self.real_to_complex.block, &self.delay.block);
        try fg.connect(&self.pilot_filter.block, &self.pilot_pll.block);
        try fg.connectPort(&self.delay.block, "out1", &self.mixer.block, "in1");
        try fg.connectPort(&self.pilot_pll.block, "out1", &self.mixer.block, "in2");
        try fg.connect(&self.delay.block, &self.lpr_filter.block);
        try fg.connect(&self.mixer.block, &self.lmr_filter.block);
        try fg.connect(&self.lpr_filter.block, &self.lpr_am_demod.block);
        try fg.connect(&self.lmr_filter.block, &self.lmr_am_demod.block);
        try fg.connectPort(&self.lpr_am_demod.block, "out1", &self.l_summer.block, "in1");
        try fg.connectPort(&self.lmr_am_demod.block, "out1", &self.l_summer.block, "in2");
        try fg.connectPort(&self.lpr_am_demod.block, "out1", &self.r_summer.block, "in1");
        try fg.connectPort(&self.lmr_am_demod.block, "out1", &self.r_summer.block, "in2");
        try fg.connect(&self.l_summer.block, &self.l_af_deemphasis.block);
        try fg.connect(&self.r_summer.block, &self.r_af_deemphasis.block);

        try fg.alias(&self.block, "in1", &self.fm_demod.block, "in1");
        try fg.alias(&self.block, "out1", &self.l_af_deemphasis.block, "out1");
        try fg.alias(&self.block, "out2", &self.r_af_deemphasis.block, "out1");
    }
};

test {
    var fm = try WBFMDemodulatorWithRDS.init();
    var top = radio.Flowgraph.init(tst.allocator, .{ .debug = true });
    defer top.deinit();
    var source = radio.blocks.ZeroSource(math.Complex(f32)).init(2);
    var tuner = radio.blocks.TunerBlock.init(0, 0, 1);
    var sink1 = radio.blocks.PrintSink(f32).init();
    var sink2 = radio.blocks.PrintSink(f32).init();
    try top.connect(&source.block, &tuner.block);
    try top.connectPort(&tuner.block, "out1", &fm.block, "in1");
    try top.connectPort(&fm.block, "out1", &sink1.block, "in1");
    try top.connectPort(&fm.block, "out2", &sink2.block, "in1");
    // try top.start();
    // _ = try top.stop();
}
