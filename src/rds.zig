const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
const radio = @import("radio");
const b = @import("blocks.zig");

pub const SignalSlicer = struct {
    pub inline fn process(value: f32) f32 {
        return if (value > 0) 1 else 0;
    }
};

/// https://luaradio.io/examples/rtlsdr-rds.html
pub const RDS = struct {
    block: radio.CompositeBlock,
    frequency: f32,

    signal: RDSSignalBlock,
    bb_filter: radio.blocks.LowpassFilterBlock(math.Complex(f32), 128),
    bb_rrc: radio.blocks.LowpassFilterBlock(math.Complex(f32), 101),
    ck_demod: radio.blocks.ComplexToRealBlock,
    ck_recover: b.ZeroCrossingClockRecoveryBlock,
    sampler: b.SamplerBlock(math.Complex(f32)),
    bp_corrector: b.BinaryPhaseCorrectorBlock,
    bit_demod: radio.blocks.ComplexToRealBlock,
    bit_slicer: radio.blocks.SlicerBlock(radio.blocks.BinarySlicer),
    bit_decoder: b.DifferentialManchesterDecoderBlock,
    bit_diff_decode: radio.blocks.DifferentialDecoderBlock(false),
    framer: RDSFramerBlock,
    decoder: RDSDecoderBlock,

    pub fn init(alloc: Allocator, options: anytype) !RDS {
        return RDS{
            .frequency = options.frequency,
            .block = .init(RDS, &.{"in1"}, &.{"out1"}),

            .signal = try .init(alloc),
            .bb_filter = .init(128, .{ .nyquist = 4e3 }),
            .bb_rrc = .init(101, .{}),
            .ck_demod = .init(),
            .ck_recover = .init(1187.5 * 2, 44_000),
            .sampler = try .init(alloc),
            .bp_corrector = .init(8e3),
            .bit_demod = .init(),
            .bit_slicer = .init(),
            .bit_decoder = .init(),
            .bit_diff_decode = .init(),
            .framer = .init(),
            .decoder = .init(alloc),
        };
    }

    pub fn deinit(self: *RDS) void {
        self.signal.deinit();
        self.sampler.deinit();
        // Other blocks that need deinitialization can be added here
    }

    pub fn connect(self: *RDS, fg: *radio.Flowgraph) !void {
        try fg.connect(&self.signal.block, &self.bb_filter.block);
        try fg.connect(&self.bb_filter.block, &self.bb_rrc.block);
        try fg.connect(&self.bb_rrc.block, &self.bp_corrector.block);
        try fg.connect(&self.bp_corrector.block, &self.ck_demod.block);
        try fg.connect(&self.ck_demod.block, &self.ck_recover.block);
        try fg.connectPort(&self.bp_corrector.block, "out1", &self.sampler.block, "in1");
        try fg.connectPort(&self.ck_recover.block, "out1", &self.sampler.block, "in2");
        try fg.connect(&self.sampler.block, &self.bit_demod.block);
        try fg.connect(&self.bit_demod.block, &self.bit_slicer.block);
        try fg.connect(&self.bit_slicer.block, &self.bit_decoder.block);
        try fg.connect(&self.bit_decoder.block, &self.bit_diff_decode.block);
        try fg.connect(&self.bit_diff_decode.block, &self.framer.block);
        try fg.connect(&self.framer.block, &self.decoder.block);

        try fg.alias(&self.block, "in1", &self.signal.block, "in1");
        try fg.alias(&self.block, "out1", &self.decoder.block, "out1");
    }

    pub fn setFrequency(self: *RDS, freq: f32) !void {
        self.frequency = freq;
    }
};

pub fn RootRaisedCosineFilter(
    comptime T: type,
    taps: usize,
    comptime options: anytype,
) type {
    std.debug.assert(@typeInfo(T) == .float);
    return struct {
        block: radio.Block,
        taps: [taps]T = computeRCCTaps(options.rolloff),
        delay_line: [taps]math.Complex(T) = [_]math.Complex(T){.init(0, 0)} ** taps,
        index: usize = 0,

        fn computeRCCTaps(rolloff: T) [taps]T {
            var t: [taps]T = undefined;
            const center = @divFloor(taps, 2);
            @setEvalBranchQuota(100_000);
            for (0..taps) |i| {
                const n = @as(T, @floatFromInt(i)) - @as(T, @floatFromInt(center));
                if (n == 0) {
                    t[i] = 1.0 - rolloff + 4.0 * rolloff / math.pi;
                } else {
                    const pin = math.pi * n;
                    const num = @sin(pin * (1.0 - rolloff) + 4.0 * rolloff * n * @cos(pin * (1 + rolloff)));
                    const denom = pin * (1.0 - (4.0 * rolloff * n) * (4.0 * rolloff * n));
                    t[i] = num / denom;
                }
            }
            return t;
        }
        const Self = @This();

        pub fn init() Self {
            return .{
                .block = radio.Block.init(Self),
            };
        }
        pub fn process(
            self: *Self,
            input: []const math.Complex(T),
            output: []math.Complex(T),
        ) !radio.ProcessResult {
            //add sample to delay line
            self.delay_line[self.index] = input[0];
            self.index = @mod(self.index + 1, self.delay_line.len);

            // convolve
            var out: math.Complex(T) = .init(0, 0);

            for (0..self.taps.len) |i| {
                const delay_idx = @mod(self.index + self.delay_line.len - i, self.delay_line.len);
                const sample = self.delay_line[delay_idx];
                const tap: math.Complex(T) = .init(self.taps[i], 0);
                out = out.add(sample.mul(tap));
            }
            output[0] = out;
            // std.debug.print("{}\n", .{output});

            return radio.ProcessResult.init(&[1]usize{1}, &[1]usize{1});
        }
    };
}

test "RRC" {
    var mf = RootRaisedCosineFilter(f32, 100, .{ .rolloff = 0.2 }).init();
    mf.index += 1;
}

pub const RDSSignalBlock = struct {
    block: radio.CompositeBlock,

    fm_demod: radio.blocks.FrequencyDiscriminatorBlock,
    hilbert: b.HilbertTransformBlock,
    mixer_delay: radio.blocks.DelayBlock(math.Complex(f32)),
    pilot_filter: radio.blocks.ComplexBandpassFilterBlock(129),
    pll_baseband: radio.blocks.ComplexPLLBlock,
    mixer: radio.blocks.MultiplyConjugateBlock,

    pub fn init(alloc: Allocator) !RDSSignalBlock {
        return .{
            .block = radio.CompositeBlock.init(RDSSignalBlock, &.{"in1"}, &.{"out1"}),

            .fm_demod = .init(1.25),
            .hilbert = try .init(alloc, 129),
            .mixer_delay = .init(129),
            .pilot_filter = .init(.{ 18e3, 20e3 }, .{}),
            .pll_baseband = .init(1500, .{ 19e3 - 100, 19e3 + 100 }, .{ .multiplier = 3.0 }),
            .mixer = .init(),
        };
    }
    pub fn deinit(self: *RDSSignalBlock) void {
        self.hilbert.deinit();
    }

    pub fn connect(self: *RDSSignalBlock, fg: *radio.Flowgraph) !void {
        try fg.connect(&self.fm_demod.block, &self.hilbert.block);
        try fg.connect(&self.hilbert.block, &self.mixer_delay.block);
        try fg.connect(&self.hilbert.block, &self.pilot_filter.block);
        try fg.connect(&self.pilot_filter.block, &self.pll_baseband.block);
        try fg.connectPort(&self.mixer_delay.block, "out1", &self.mixer.block, "in1");
        try fg.connectPort(&self.pll_baseband.block, "out1", &self.mixer.block, "in2");

        try fg.alias(&self.block, "in1", &self.fm_demod.block, "in1");
        try fg.alias(&self.block, "out1", &self.mixer.block, "out1");
    }
};

/// https://github.com/vsergeev/luaradio/blob/master/radio/blocks/protocol/rdsdecoder.lua
// RDS Decoder Block - decodes RDS groups and extracts information
pub const RDSDecoderBlock = struct {
    block: radio.Block,
    allocator: std.mem.Allocator,

    // RDS data storage
    pi_code: u16,
    pty: u8,
    tp: bool,
    ta: bool,
    ms: bool,
    di: u4,

    // Program Service name (8 characters)
    ps_name: [8]u8,
    ps_segments: [4][2]u8, // 4 segments of 2 chars each
    ps_segment_flags: u4, // Which segments have been received

    // RadioText (64 characters for type A, 32 for type B)
    radio_text: [64]u8,
    rt_segments: [16][4]u8, // Type A: 16 segments of 4 chars
    rt_segment_flags: u16,
    rt_ab_flag: bool,

    // Alternative frequencies
    af_list: [25]u8,
    af_count: usize,

    // Clock time
    clock_time: struct {
        hours: u8,
        minutes: u8,
        mjd: u32, // Modified Julian Day
    },

    // Statistics
    groups_decoded: u32,
    error_count: u32,

    const Self = @This();

    pub const RDSData = struct {
        pi_code: u16,
        ps_name: []const u8,
        radio_text: []const u8,
        pty: u8,
        tp: bool,
        ta: bool,

        pub fn typeName() []const u8 {
            return "RDSData";
        }
    };

    pub fn init(allocator: std.mem.Allocator) RDSDecoderBlock {
        return .{
            .block = radio.Block.init(RDSDecoderBlock),
            .allocator = allocator,
            .pi_code = 0,
            .pty = 0,
            .tp = false,
            .ta = false,
            .ms = false,
            .di = 0,
            .ps_name = [_]u8{' '} ** 8,
            .ps_segments = [_][2]u8{[_]u8{' '} ** 2} ** 4,
            .ps_segment_flags = 0,
            .radio_text = [_]u8{' '} ** 64,
            .rt_segments = [_][4]u8{[_]u8{' '} ** 4} ** 16,
            .rt_segment_flags = 0,
            .rt_ab_flag = false,
            .af_list = [_]u8{0} ** 25,
            .af_count = 0,
            .clock_time = .{
                .hours = 0,
                .minutes = 0,
                .mjd = 0,
            },
            .groups_decoded = 0,
            .error_count = 0,
        };
    }

    pub fn process(self: *Self, input: []const u8, output: []RDSData) !radio.ProcessResult {
        // Input should be 13 bytes (104 bits) representing one RDS group
        if (input.len < 13) {
            self.error_count += 1;
            return error.InvalidInput;
        }

        // Extract the 4 blocks (A, B, C, D) from the frame.
        // Each block is 26 bits: 16 bits data + 10 bits checkword.
        // Data words are not byte-aligned; extractDataWord handles bit offsets.
        const block_a = extractDataWord(input[0..13], 0);
        const block_b = extractDataWord(input[0..13], 1);
        const block_c = extractDataWord(input[0..13], 2);
        const block_d = extractDataWord(input[0..13], 3);

        // Block A is always the PI code
        self.pi_code = block_a;

        // Block B contains group type and version
        const group_type = @as(u8, @intCast((block_b >> 12) & 0x0F));
        const version = @as(u1, @intCast((block_b >> 11) & 0x01)); // 0 = A, 1 = B
        self.tp = (block_b >> 10) & 0x01 == 1;
        self.pty = @as(u8, @intCast((block_b >> 5) & 0x1F));

        // Process based on group type
        switch (group_type) {
            0 => {
                // Group 0A/0B: Basic tuning and switching information
                self.ta = (block_b >> 4) & 0x01 == 1;
                self.ms = (block_b >> 3) & 0x01 == 1;
                const di_bit = @as(u1, @intCast((block_b >> 2) & 0x01));
                const ps_index = @as(u2, @intCast(block_b & 0x03));

                // Update DI bit
                self.di = (self.di & ~(@as(u4, 1) << ps_index)) | (@as(u4, di_bit) << ps_index);

                // Store PS name segment
                self.ps_segments[ps_index][0] = @as(u8, @intCast((block_d >> 8) & 0xFF));
                self.ps_segments[ps_index][1] = @as(u8, @intCast(block_d & 0xFF));
                self.ps_segment_flags |= @as(u4, 1) << ps_index;

                // If we have all segments, update PS name
                if (self.ps_segment_flags == 0x0F) {
                    for (0..4) |i| {
                        self.ps_name[i * 2] = self.ps_segments[i][0];
                        self.ps_name[i * 2 + 1] = self.ps_segments[i][1];
                    }
                }

                // Handle alternative frequencies in version A
                if (version == 0) {
                    self.processAF(block_c);
                }
            },
            1 => {
                // Group 1A/1B: Program Item Number
                // Not commonly used, skip for now
            },
            2 => {
                // Group 2A/2B: RadioText
                const text_ab = @as(u1, @intCast((block_b >> 4) & 0x01));
                const text_index = @as(u4, @intCast(block_b & 0x0F));

                // Check if A/B flag changed (indicates new message)
                if (text_ab != @intFromBool(self.rt_ab_flag)) {
                    self.rt_ab_flag = text_ab == 1;
                    self.rt_segment_flags = 0;
                    self.radio_text = [_]u8{' '} ** 64;
                }

                if (version == 0) {
                    // Type 2A: 64-character RadioText
                    if (text_index < 16) {
                        const idx = text_index * 4;
                        self.radio_text[idx] = @as(u8, @intCast((block_c >> 8) & 0xFF));
                        self.radio_text[idx + 1] = @as(u8, @intCast(block_c & 0xFF));
                        self.radio_text[idx + 2] = @as(u8, @intCast((block_d >> 8) & 0xFF));
                        self.radio_text[idx + 3] = @as(u8, @intCast(block_d & 0xFF));
                        self.rt_segment_flags |= @as(u16, 1) << text_index;
                    }
                } else {
                    // Type 2B: 32-character RadioText
                    if (text_index < 8) {
                        const idx = text_index * 2;
                        self.radio_text[idx] = @as(u8, @intCast((block_d >> 8) & 0xFF));
                        self.radio_text[idx + 1] = @as(u8, @intCast(block_d & 0xFF));
                        self.rt_segment_flags |= @as(u16, 1) << text_index;
                    }
                }
            },
            3 => {
                // Group 3A: Application identification for Open Data
                // Group 3B: Open data application
            },
            4 => {
                // Group 4A: Clock-time and date
                if (version == 0) {
                    const mjd = (@as(u32, @intCast((block_b & 0x03))) << 15) |
                        (@as(u32, @intCast(block_c >> 1)));
                    const hours = @as(u8, @intCast(((block_c & 0x01) << 4) | ((block_d >> 12) & 0x0F)));
                    const minutes = @as(u8, @intCast((block_d >> 6) & 0x3F));

                    self.clock_time.mjd = mjd;
                    self.clock_time.hours = hours;
                    self.clock_time.minutes = minutes;
                }
            },
            10 => {
                // Group 10A: Program Type Name (PTYN)
                const ptyn_index = @as(u1, @intCast(block_b & 0x01));
                _ = ptyn_index;
                // Store PTYN characters (8 chars total)
            },
            else => {
                // Other group types not implemented
            },
        }

        self.groups_decoded += 1;
        output[0] = self.getRDSData();

        return radio.ProcessResult.init(&[1]usize{13}, &[1]usize{1});
    }

    pub fn getRDSData(self: *Self) RDSData {
        return RDSData{
            .pi_code = self.pi_code,
            .ps_name = &self.ps_name,
            .radio_text = &self.radio_text,
            .pty = self.pty,
            .tp = self.tp,
            .ta = self.ta,
        };
    }

    /// Extract the 16-bit data word for block N (0=A, 1=B, 2=C, 3=D) from
    /// the packed 13-byte (104-bit) RDS frame. Each block is 26 bits so the
    /// data words are not byte-aligned for blocks B, C, D.
    fn extractDataWord(frame: []const u8, block_idx: u2) u16 {
        const bit_start: u32 = @as(u32, block_idx) * 26;
        const bs: usize = bit_start / 8;
        const bo: u5 = @intCast(bit_start % 8);
        // Read 3 consecutive bytes that span the 16-bit data word
        const v: u32 = (@as(u32, frame[bs]) << 16) |
            (@as(u32, frame[bs + 1]) << 8) |
            @as(u32, frame[bs + 2]);
        return @truncate((v >> (8 - bo)) & 0xFFFF);
    }

    fn processAF(self: *Self, af_data: u16) void {
        const af1 = @as(u8, @intCast((af_data >> 8) & 0xFF));
        const af2 = @as(u8, @intCast(af_data & 0xFF));

        // AF codes 1-204 represent frequencies
        // 205-223 are filler codes
        // 224-249 indicate number of AFs
        // 250 = LF/MF frequency follows

        if (af1 >= 224 and af1 <= 249) {
            // Number of AFs
            const num_afs = af1 - 224;
            _ = num_afs;
            // Reset AF list
            self.af_count = 0;
        } else if (af1 <= 204 and self.af_count < self.af_list.len) {
            self.af_list[self.af_count] = af1;
            self.af_count += 1;
        }

        if (af2 <= 204 and self.af_count < self.af_list.len) {
            self.af_list[self.af_count] = af2;
            self.af_count += 1;
        }
    }

    pub fn getProgramService(self: *Self) []const u8 {
        return &self.ps_name;
    }

    pub fn getRadioText(self: *Self) []const u8 {
        // Find the end of the radio text (look for CR or null terminator)
        for (self.radio_text, 0..) |char, i| {
            if (char == 0x0D or char == 0) {
                return self.radio_text[0..i];
            }
        }
        return &self.radio_text;
    }

    pub fn getProgramType(self: *Self) []const u8 {
        // Return PTY description based on code
        return switch (self.pty) {
            0 => "None",
            1 => "News",
            2 => "Information",
            3 => "Sports",
            4 => "Talk",
            5 => "Rock",
            6 => "Classic Rock",
            7 => "Adult Hits",
            8 => "Soft Rock",
            9 => "Top 40",
            10 => "Country",
            11 => "Oldies",
            12 => "Soft",
            13 => "Nostalgia",
            14 => "Jazz",
            15 => "Classical",
            16 => "Rhythm and Blues",
            17 => "Soft R&B",
            18 => "Foreign Language",
            19 => "Religious Music",
            20 => "Religious Talk",
            21 => "Personality",
            22 => "Public",
            23 => "College",
            24 => "Spanish Talk",
            25 => "Spanish Music",
            26 => "Hip Hop",
            29 => "Weather",
            30 => "Emergency Test",
            31 => "Emergency",
            else => "Unknown",
        };
    }

    pub fn getAlternativeFrequencies(self: *Self) []f32 {
        var frequencies: [25]f32 = undefined;
        var count: usize = 0;

        for (self.af_list[0..self.af_count]) |af_code| {
            if (af_code >= 1 and af_code <= 204) {
                // Convert AF code to frequency
                // 1-204 corresponds to 87.6-107.9 MHz in 0.1 MHz steps
                frequencies[count] = 87.5 + @as(f32, @floatFromInt(af_code)) * 0.1;
                count += 1;
            }
        }

        return frequencies[0..count];
    }

    pub fn formatTime(self: *Self) ![]u8 {
        if (self.clock_time.mjd == 0) {
            return error.NoTimeAvailable;
        }

        // Convert MJD to year, month, day
        const mjd = self.clock_time.mjd;
        const j = mjd + 2400001 + 68569;
        const n = 4 * j / 146097;
        const j2 = j - (146097 * n + 3) / 4;
        const i = 4000 * (j2 + 1) / 1461001;
        const j3 = j2 - 1461 * i / 4 + 31;
        const k = 80 * j3 / 2447;
        const day = j3 - 2447 * k / 80;
        const l = k / 11;
        const month = k + 2 - 12 * l;
        const year = 100 * (n - 49) + i + l;

        _ = year;
        _ = month;
        _ = day;

        // Format as string
        var buffer: [32]u8 = undefined;
        const result = std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}", .{
            self.clock_time.hours,
            self.clock_time.minutes,
        }) catch return error.FormattingError;

        return self.allocator.dupe(u8, result) catch return error.OutOfMemory;
    }
};

/// https://github.com/vsergeev/luaradio/blob/master/radio/blocks/protocol/rdsframer.lua
pub const RDSFramerBlock = struct {
    block: radio.Block,
    /// 104-bit shift register: oldest bit at [0], newest at [FrameLen-1].
    frame: [FrameLen]u1 = [_]u1{0} ** FrameLen,
    /// How many bits have been loaded into `frame` (saturates at FrameLen).
    fill: usize = 0,
    synchronized: bool = false,
    /// Counts bits received since the last frame boundary (locked mode).
    bit_counter: usize = 0,

    const FrameLen = 104;
    const BlockLen = 26;
    const OffsetWord = enum(u10) {
        A = 0x0fc,
        B = 0x198,
        C = 0x168,
        Cp = 0x340, // version-B block 3
        D = 0x1b4,
    };

    pub fn init() RDSFramerBlock {
        return .{ .block = radio.Block.init(RDSFramerBlock) };
    }

    pub fn process(self: *RDSFramerBlock, x: []const u1, y: []u8) !radio.ProcessResult {
        var frames_out: usize = 0;

        for (x) |bit| {
            // Shift bit into the 104-bit window.
            if (self.fill < FrameLen) {
                self.frame[self.fill] = bit;
                self.fill += 1;
                if (self.fill < FrameLen) continue;
            } else {
                // Slide left: discard oldest bit, append new bit at end.
                std.mem.copyForwards(u1, self.frame[0 .. FrameLen - 1], self.frame[1..FrameLen]);
                self.frame[FrameLen - 1] = bit;
            }

            // frame now contains exactly FrameLen bits.
            if (!self.synchronized) {
                // Hunting: accept when 3 of 4 block syndromes are valid.
                if (countValidBlocks(&self.frame) >= 3) {
                    self.synchronized = true;
                    self.bit_counter = 0;
                }
            } else {
                self.bit_counter += 1;
                if (self.bit_counter >= FrameLen) {
                    self.bit_counter = 0;
                    const valid = countValidBlocks(&self.frame);
                    if (valid >= 2) {
                        // Output the frame (pack 104 bits → 13 bytes).
                        if ((frames_out + 1) * 13 <= y.len) {
                            for (0..13) |bi| {
                                var byte: u8 = 0;
                                for (0..8) |bj| {
                                    byte |= @as(u8, self.frame[bi * 8 + bj]) << @intCast(7 - bj);
                                }
                                y[frames_out * 13 + bi] = byte;
                            }
                            frames_out += 1;
                        }
                    } else {
                        // Lost lock.
                        self.synchronized = false;
                    }
                }
            }
        }

        return radio.ProcessResult.init(&[1]usize{x.len}, &[1]usize{frames_out * 13});
    }

    /// Count how many of the 4 RDS blocks in `frame` have valid BCH syndromes.
    /// Block C accepts either the C or C' offset word (version A vs version B).
    fn countValidBlocks(frame: []const u1) u32 {
        var count: u32 = 0;
        const offsets = [4]OffsetWord{ .A, .B, .C, .D };
        for (0..4) |i| {
            const start = i * BlockLen;
            const block = frame[start .. start + BlockLen];
            if (i == 2) {
                if (validateBlock(block, .C) or validateBlock(block, .Cp)) count += 1;
            } else {
                if (validateBlock(block, offsets[i])) count += 1;
            }
        }
        return count;
    }

    /// Compute the 10-bit BCH syndrome for a 26-bit block.
    /// RDS uses G(x) = x^10 + x^8 + x^7 + x^5 + x^4 + x^3 + 1 (feedback = 0x1B9).
    fn computeSyndrome(block_bits: []const u1) u10 {
        const poly: u10 = 0x1B9;
        var reg: u10 = 0;
        for (block_bits[0..BlockLen]) |bit| {
            const feedback: u1 = @truncate(reg >> 9);
            reg = ((reg << 1) | @as(u10, bit)) & 0x3FF;
            if (feedback != 0) reg ^= poly;
        }
        return reg;
    }

    fn validateBlock(block_bits: []const u1, expected_offset: OffsetWord) bool {
        if (block_bits.len < BlockLen) return false;
        return computeSyndrome(block_bits[0..BlockLen]) == @intFromEnum(expected_offset);
    }
};

test "RDS" {
    var fg = radio.Flowgraph.init(tst.allocator, .{ .debug = true });
    defer fg.deinit();

    var iq_file = try std.fs.cwd().openFile("test/rds/SDRSharp_20150804_204012Z_0Hz_IQ.wav", .{ .mode = .read_only });
    defer iq_file.close();

    var read_buf: [4096]u8 = undefined;
    var reader = iq_file.reader(&read_buf);

    var iq = radio.blocks.IQStreamSource.init(&reader.interface, .s16le, 192_000, .{});
    var tuner = radio.blocks.TunerBlock.init(0, 1_200_000, 2);
    var rds = try RDS.init(tst.allocator, .{ .frequency = 81e6 });
    // var rds = try RDSSignalBlock.init(tst.allocator);
    defer rds.deinit();

    // var sink = radio.blocks.JSONStreamSink(RDSDecoderBlock.RDSData).init(std.io.getStdErr().writer().any(), .{});
    var sink = radio.blocks.PrintSink(RDSDecoderBlock.RDSData).init();
    // Connect the IQ source to the RDS decoder
    try fg.connect(&iq.block, &tuner.block);
    try fg.connect(&tuner.block, &rds.block);
    try fg.connect(&rds.block, &sink.block);

    try fg.start();

    // Run for a short time to test
    std.Thread.sleep(100 * std.time.ns_per_ms);

    _ = try fg.stop();
}
