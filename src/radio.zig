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

// test {
//     var r = try RadioReceiver.init(tst.allocator, true);
//     defer r.deinit();

//     try r.connect(.FM);
//     try r.start();
//     radio.platform.waitForInterrupt();
//     try r.stop();
// }

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
/// https://luaradio.io/examples/rtlsdr-rds.html
pub const RDS = struct {
    block: radio.CompositeBlock,
    frequency: f32,

    hilbert: HilbertTransformBlock,
    mixer_delay: radio.blocks.DelayBlock(f32),
    pilot_filter: radio.blocks.ComplexBandpassFilterBlock(129),
    pll_baseband: radio.blocks.ComplexPLLBlock,
    mixer: radio.blocks.MultiplyConjugateBlock,
    bb_filter: radio.blocks.LowpassFilterBlock(math.Complex(f32), 128),
    bb_rrc: radio.blocks.RectangularMatchedFilterBlock,
    ck_demod: radio.blocks.ComplexToRealBlock,
    ck_recover: ZeroCrossingClockRecoveryBlock,
    sampler: SamplerBlock,
    bit_demod: radio.blocks.ComplexToRealBlock,
    bit_decode: radio.blocks.SlicerBlock(void),
    bit_diff_decode: radio.blocks.DifferentialDecoderBlock(false),
    framer: RDSFramerBlock,
    decoder: RDSDecoderBlock,
    sink: radio.blocks.JSONStreamSink(void),

    pub fn init(options: anytype) RDS {
        return RDS{
            .frequency = options.frequency,
            .block = .init(RDS, &.{"in1"}, &.{"out1"}),
        };
    }

    pub fn connect(self: *RDS, fg: *radio.Flowgraph) !void {
        _ = self; // autofix
        _ = fg; // autofix
        // top:connect(source, tuner, fm_demod, hilbert, mixer_delay)
        // top:connect(hilbert, pilot_filter, pll_baseband)
        // top:connect(mixer_delay, 'out', mixer, 'in1')
        // top:connect(pll_baseband, 'out', mixer, 'in2')
        // top:connect(mixer, baseband_filter, baseband_rrc, phase_corrector)
        // top:connect(phase_corrector, clock_demod, clock_recoverer)
        // top:connect(phase_corrector, 'out', sampler, 'data')
        // top:connect(clock_recoverer, 'out', sampler, 'clock')
        // top:connect(sampler, bit_demod, bit_slicer, bit_decoder, bit_diff_decoder, framer, decoder, sink)
    }

    pub fn setFrequency(self: *RDS, freq: f32) !void {
        self.frequency = freq;
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

/// https://github.com/vsergeev/luaradio/blob/master/radio/blocks/protocol/rdsdecoder.lua
pub const RDSDecoderBlock = struct {
    block: radio.Block,
};

/// https://github.com/vsergeev/luaradio/blob/master/radio/blocks/protocol/rdsframer.lua
pub const RDSFramerBlock = struct {
    block: radio.Block,
    synchronized: bool = false,
    rds_frame: [FrameLen]u1,
    rds_frame_len: usize = 0,
    bit_buffer: [FrameLen * 2]u1,
    bit_buffer_len: usize = 0,
    allocator: std.mem.Allocator,

    const FrameLen = 104;
    const BlockLen = 26;
    const OffsetWord = enum(u12) {
        A = 0x0fc,
        B = 0x198,
        C = 0x168,
        Cp = 0x350,
        D = 0x1b4,
    };

    pub fn init(allocator: std.mem.Allocator) RDSFramerBlock {
        return .{
            .block = radio.Block.init(RDSFramerBlock),
            .synchronized = false,
            .rds_frame = [_]u1{0} ** FrameLen,
            .rds_frame_len = 0,
            .bit_buffer = [_]u1{0} ** (FrameLen * 2),
            .bit_buffer_len = 0,
            .allocator = allocator,
        };
    }
    pub fn process(self: *RDSFramerBlock, x: []const f32, y: [][]const u8) !radio.ProcessResult {
        var frames_out: usize = 0;

        for (x) |sample| {
            // Convert float to bit (threshold at 0)
            const bit: u1 = if (sample > 0) 1 else 0;

            // Add to bit buffer
            if (self.bit_buffer_len < self.bit_buffer.len) {
                self.bit_buffer[self.bit_buffer_len] = bit;
                self.bit_buffer_len += 1;
            } else {
                // Shift buffer left and add new bit
                std.mem.copyForwards(u1, self.bit_buffer[0 .. self.bit_buffer.len - 1], self.bit_buffer[1..]);
                self.bit_buffer[self.bit_buffer.len - 1] = bit;
            }

            // Try to synchronize if we have enough bits
            if (self.bit_buffer_len >= FrameLen) {
                if (!self.synchronized) {
                    // Try to find sync by checking for valid syndrome
                    if (try self.checkSync()) {
                        self.synchronized = true;
                        // Copy frame
                        std.mem.copyForwards(u1, &self.rds_frame, self.bit_buffer[0..FrameLen]);
                        self.rds_frame_len = FrameLen;
                    }
                } else {
                    // We're synchronized, check if we still have valid frames
                    self.rds_frame_len += 1;
                    if (self.rds_frame_len >= FrameLen) {
                        // Output frame
                        if (frames_out < y.len) {
                            // Convert bits to bytes for output
                            var frame_bytes: [13]u8 = undefined; // 104 bits = 13 bytes
                            for (0..13) |byte_idx| {
                                var byte: u8 = 0;
                                for (0..8) |bit_idx| {
                                    const bit_pos = byte_idx * 8 + bit_idx;
                                    if (bit_pos < FrameLen) {
                                        byte |= @as(u8, self.rds_frame[bit_pos]) << @intCast(7 - bit_idx);
                                    }
                                }
                                frame_bytes[byte_idx] = byte;
                            }
                            y[frames_out] = &frame_bytes;
                            frames_out += 1;
                        }

                        // Shift in new frame
                        std.mem.copyForwards(u1, &self.rds_frame, self.bit_buffer[0..FrameLen]);
                        self.rds_frame_len = 0;

                        // Check if still synchronized
                        if (!self.validateFrame(&self.rds_frame)) {
                            self.synchronized = false;
                        }
                    }
                }
            }
        }

        return radio.ProcessResult.init(&[1]usize{x.len}, &[1]usize{frames_out});
    }
    /// Block bits layout:
    ///  MMMM MMMM MMMM MMMM CC CCCC CCCC
    /// 26-bits block = 16-bits message + 10-bits error correcting code
    fn correct_block(self: *RDSFramerBlock, block_bits: []const u1, offset: OffsetWord) !void {
        _ = block_bits; // autofix
        _ = self; // autofix
        _ = offset; // autofix
    }

    fn checkSync(self: *RDSFramerBlock) !bool {
        // Try different bit positions to find valid RDS frame
        for (0..BlockLen) |offset| {
            var valid_blocks: u32 = 0;

            // Check each block in the frame
            for (0..4) |block_idx| {
                const start = offset + block_idx * BlockLen;
                if (start + BlockLen <= self.bit_buffer_len) {
                    const block = self.bit_buffer[start .. start + BlockLen];
                    if (self.validateBlock(block)) {
                        valid_blocks += 1;
                    }
                }
            }

            // If we have at least 3 valid blocks, we're likely synchronized
            if (valid_blocks >= 3) {
                // Shift buffer to align with frame start
                if (offset > 0) {
                    std.mem.copyForwards(u1, self.bit_buffer[0..], self.bit_buffer[offset..self.bit_buffer_len]);
                    self.bit_buffer_len -= offset;
                }
                return true;
            }
        }
        return false;
    }

    fn validateBlock(self: *RDSFramerBlock, block_bits: []const u1) bool {
        _ = self;
        if (block_bits.len != BlockLen) return false;

        // Simple validation: check if block has reasonable bit patterns
        // In real implementation, would check CRC/syndrome
        var ones: u32 = 0;
        for (block_bits) |bit| {
            ones += bit;
        }

        // Blocks shouldn't be all ones or all zeros
        return ones > 5 and ones < 21;
    }

    fn validateFrame(self: *RDSFramerBlock, frame: []const u1) bool {
        if (frame.len != FrameLen) return false;

        // Check each block
        for (0..4) |i| {
            const start = i * BlockLen;
            const block = frame[start .. start + BlockLen];
            if (!self.validateBlock(block)) {
                return false;
            }
        }
        return true;
    }
};

/// Hilbert Transform Block - converts real signal to complex analytic signal
///
/// This block implements a 90-degree phase shift filter to create the imaginary
/// component of a complex signal from a real input. The real part is the original
/// signal delayed by half the filter length to maintain time alignment.
///
/// Used in RDS demodulation to convert the real FM multiplex baseband signal
/// into a complex representation needed for further processing.
pub const HilbertTransformBlock = struct {
    block: radio.Block,

    // Filter coefficients and state
    filter_taps: []f32,
    filter_length: usize,
    delay_line: []f32,
    write_index: usize,

    // Real signal delay line (for time alignment)
    real_delay: []f32,
    real_delay_samples: usize,

    // Memory management
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize Hilbert transform with specified filter length
    /// filter_length should be odd for proper Hilbert transform
    pub fn init(allocator: std.mem.Allocator, filter_length: usize) !Self {
        // Ensure odd filter length for symmetric Hilbert transform
        const actual_length = if (filter_length % 2 == 0) filter_length + 1 else filter_length;

        // Allocate memory for filter taps and delay lines
        const filter_taps = try allocator.alloc(f32, actual_length);
        const delay_line = try allocator.alloc(f32, actual_length);

        // Real signal delay - half the filter length for time alignment
        const real_delay_samples = actual_length / 2;
        const real_delay = try allocator.alloc(f32, real_delay_samples);

        // Initialize delay lines to zero
        @memset(delay_line, 0.0);
        @memset(real_delay, 0.0);

        var self = Self{
            .block = radio.Block.init(Self),
            .filter_taps = filter_taps,
            .filter_length = actual_length,
            .delay_line = delay_line,
            .write_index = 0,
            .real_delay = real_delay,
            .real_delay_samples = real_delay_samples,
            .allocator = allocator,
        };

        // Calculate Hilbert transform filter coefficients
        try self.calculateHilbertCoefficients();

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.filter_taps);
        self.allocator.free(self.delay_line);
        self.allocator.free(self.real_delay);
    }

    /// Calculate Hilbert transform FIR filter coefficients
    /// Uses windowed sinc function approach with Hamming window
    fn calculateHilbertCoefficients(self: *Self) !void {
        const center = @as(f32, @floatFromInt(self.filter_length / 2));

        for (self.filter_taps, 0..) |*tap, i| {
            const n = @as(f32, @floatFromInt(i)) - center;

            if (i == self.filter_length / 2) {
                // Center tap is always zero for Hilbert transform
                tap.* = 0.0;
            } else {
                // Hilbert transform impulse response: h[n] = 2/(π*n) for odd n, 0 for even n
                const n_int = @as(i32, @intFromFloat(n));
                if (@mod(n_int, 2) != 0) {
                    // Odd samples: sinc function
                    const pi_n = math.pi * n;
                    tap.* = 2.0 / pi_n;

                    // Apply Hamming window to reduce sidelobes
                    const window_arg = 2.0 * math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(self.filter_length - 1));
                    const window = 0.54 - 0.46 * math.cos(window_arg);
                    tap.* *= window;
                } else {
                    // Even samples: zero
                    tap.* = 0.0;
                }
            }
        }
    }

    /// ZigRadio block interface - process samples
    /// Input: real-valued signal
    /// Output: complex-valued analytic signal (real + j*hilbert(real))
    pub fn process(self: *Self, input: []const f32, output: []math.Complex(f32)) !radio.ProcessResult {
        if (output.len < input.len) {
            return radio.ProcessResult.init(&[1]usize{0}, &[1]usize{0});
        }

        for (input, 0..) |sample, i| {
            // Store input sample in delay line
            self.delay_line[self.write_index] = sample;

            // Calculate Hilbert transform (imaginary component)
            var imaginary_part: f32 = 0.0;
            for (self.filter_taps, 0..) |tap, j| {
                const delay_idx = (self.write_index + self.filter_length - j) % self.filter_length;
                imaginary_part += tap * self.delay_line[delay_idx];
            }

            // Real part: delayed input for time alignment
            const real_delay_idx = (self.write_index + self.real_delay_samples) % self.real_delay_samples;
            const real_part = self.real_delay[real_delay_idx];

            // Store current sample in real delay line
            self.real_delay[self.write_index % self.real_delay_samples] = sample;

            // Output complex sample
            output[i] = math.Complex(f32).init(real_part, imaginary_part);

            // Advance write index
            self.write_index = (self.write_index + 1) % self.filter_length;
        }

        return radio.ProcessResult.init(&[1]usize{input.len}, &[1]usize{input.len});
    }
};

// Test the Hilbert transform block
test "HilbertTransformBlock basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create Hilbert transform block
    var hilbert = try HilbertTransformBlock.init(allocator, 129);
    defer hilbert.deinit();

    // Test with a simple sinusoid
    const test_freq = 1000.0; // 1 kHz
    const sample_rate = 44100.0;
    const num_samples = 1024;

    var input_buffer: [num_samples]f32 = undefined;
    var output_buffer: [num_samples]math.Complex(f32) = undefined;

    // Generate test sinusoid
    for (&input_buffer, 0..) |*sample, i| {
        const t = @as(f32, @floatFromInt(i)) / sample_rate;
        sample.* = math.sin(2.0 * math.pi * test_freq * t);
    }

    // Process through Hilbert transform
    _ = try hilbert.process(&input_buffer, &output_buffer);

    // Check that we have complex output
    // The imaginary part should be approximately -cos(2πft) for sin(2πft) input
    // This is a basic sanity check - full validation would require more sophisticated testing

    var has_nonzero_imaginary = false;
    for (output_buffer[hilbert.filter_length..]) |complex_sample| {
        if (@abs(complex_sample.im) > 0.1) {
            has_nonzero_imaginary = true;
            break;
        }
    }

    try testing.expect(has_nonzero_imaginary);
}

// Zero Crossing Clock Recovery Block
pub const ZeroCrossingClockRecoveryBlock = struct {
    block: radio.Block,
    symbol_rate: f32,
    sample_rate: f32,
    samples_per_symbol: f32,
    clock_phase: f32,
    last_sample: f32,
    zero_crossing_count: u32,
    phase_error_integrator: f32,
    loop_gain: f32,

    const Self = @This();

    pub fn init(symbol_rate: f32, sample_rate: f32) ZeroCrossingClockRecoveryBlock {
        const samples_per_symbol = sample_rate / symbol_rate;
        return .{
            .block = radio.Block.init(Self),
            .symbol_rate = symbol_rate,
            .sample_rate = sample_rate,
            .samples_per_symbol = samples_per_symbol,
            .clock_phase = 0,
            .last_sample = 0,
            .zero_crossing_count = 0,
            .phase_error_integrator = 0,
            .loop_gain = 0.01, // Typical value for loop gain
        };
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) !radio.ProcessResult {
        if (output.len < input.len) {
            return radio.ProcessResult.init(&[1]usize{0}, &[1]usize{0});
        }

        var out_idx: usize = 0;

        for (input) |sample| {
            // Detect zero crossing
            const zero_crossing = (self.last_sample < 0 and sample >= 0) or
                (self.last_sample >= 0 and sample < 0);

            if (zero_crossing) {
                // Calculate phase error
                const expected_phase = @mod(self.clock_phase, self.samples_per_symbol);
                const phase_error = expected_phase - (self.samples_per_symbol / 2.0);

                // Update phase with proportional-integral control
                self.phase_error_integrator += phase_error * self.loop_gain * 0.1;
                self.phase_error_integrator = math.clamp(self.phase_error_integrator, -1.0, 1.0);

                const phase_correction = phase_error * self.loop_gain + self.phase_error_integrator;
                self.clock_phase -= phase_correction;

                self.zero_crossing_count += 1;
            }

            // Generate clock output
            const clock_output = if (@mod(self.clock_phase, self.samples_per_symbol) < 1.0)
                @as(f32, 1.0)
            else
                @as(f32, 0.0);

            output[out_idx] = clock_output;
            out_idx += 1;

            // Update phase and last sample
            self.clock_phase += 1.0;
            if (self.clock_phase >= self.samples_per_symbol * 100) {
                self.clock_phase = @mod(self.clock_phase, self.samples_per_symbol * 100);
            }
            self.last_sample = sample;
        }

        return radio.ProcessResult.init(&[1]usize{input.len}, &[1]usize{out_idx});
    }
};

// Symbol sampler triggered by clock recovery
pub const SamplerBlock = struct {
    block: radio.Block,
    last_clock: f32,
    data_buffer: std.ArrayList(f32),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !SamplerBlock {
        return .{
            .block = radio.Block.init(Self),
            .last_clock = 0,
            .data_buffer = std.ArrayList(f32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.data_buffer.deinit();
    }

    pub fn process(self: *Self, data_input: []const f32, clock_input: []const f32, output: []f32) !radio.ProcessResult {
        if (data_input.len != clock_input.len) {
            return radio.ProcessResult.init(&[2]usize{ 0, 0 }, &[1]usize{0});
        }

        var out_idx: usize = 0;

        for (data_input, clock_input) |data_sample, clock_sample| {
            // Detect rising edge on clock
            const rising_edge = self.last_clock <= 0.5 and clock_sample > 0.5;

            if (rising_edge and out_idx < output.len) {
                // Sample the data on rising edge
                output[out_idx] = data_sample;
                out_idx += 1;
            }

            self.last_clock = clock_sample;
        }

        return radio.ProcessResult.init(&[2]usize{ data_input.len, clock_input.len }, &[1]usize{out_idx});
    }
};

// Phase correction for BPSK constellation
pub const BinaryPhaseCorrectorBlock = struct {
    block: radio.Block,
    phase_error: f32,
    phase_accumulator: f32,
    loop_bandwidth: f32,
    loop_gain_alpha: f32,
    loop_gain_beta: f32,

    const Self = @This();

    pub fn init(loop_bandwidth: f32) BinaryPhaseCorrectorBlock {
        // Calculate loop filter gains from bandwidth
        const damping = 0.707; // Critical damping
        const theta = loop_bandwidth / (damping + 1.0 / (4.0 * damping));
        const d = 1.0 + 2.0 * damping * theta + theta * theta;

        return .{
            .block = radio.Block.init(Self),
            .phase_error = 0,
            .phase_accumulator = 0,
            .loop_bandwidth = loop_bandwidth,
            .loop_gain_alpha = (4.0 * damping * theta) / d,
            .loop_gain_beta = (4.0 * theta * theta) / d,
        };
    }

    pub fn process(self: *Self, input: []const math.Complex(f32), output: []math.Complex(f32)) !radio.ProcessResult {
        if (output.len < input.len) {
            return radio.ProcessResult.init(&[1]usize{0}, &[1]usize{0});
        }

        for (input, 0..) |sample, i| {
            // Apply current phase correction
            const correction = math.Complex(f32).init(math.cos(self.phase_accumulator), -math.sin(self.phase_accumulator));
            const corrected = sample.mul(correction);

            // For BPSK, detect phase error using decision-directed method
            // Make hard decision on real part
            const decision = if (corrected.re > 0) @as(f32, 1.0) else @as(f32, -1.0);

            // Phase error is proportional to imaginary part when real part is decided
            self.phase_error = -corrected.im * decision;

            // Update phase accumulator with PI loop filter
            self.phase_accumulator += self.loop_gain_alpha * self.phase_error +
                self.loop_gain_beta * self.phase_error;

            // Wrap phase to [-π, π]
            while (self.phase_accumulator > math.pi) {
                self.phase_accumulator -= 2.0 * math.pi;
            }
            while (self.phase_accumulator < -math.pi) {
                self.phase_accumulator += 2.0 * math.pi;
            }

            output[i] = corrected;
        }

        return radio.ProcessResult.init(&[1]usize{input.len}, &[1]usize{input.len});
    }
};

// Manchester decoder for RDS bit stream
pub const DifferentialManchesterDecoderBlock = struct {
    block: radio.Block,
    last_phase: u1,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) DifferentialManchesterDecoderBlock {
        return .{
            .block = radio.Block.init(Self),
            .last_phase = 0,
            .allocator = allocator,
        };
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) !radio.ProcessResult {
        if (output.len < input.len / 2) {
            return radio.ProcessResult.init(&[1]usize{0}, &[1]usize{0});
        }

        var out_idx: usize = 0;
        var i: usize = 0;

        // Differential Manchester:
        // Transition at start of bit period = '0'
        // No transition at start of bit period = '1'

        while (i + 1 < input.len and out_idx < output.len) {
            const bit1 = if (input[i] > 0) @as(u1, 1) else @as(u1, 0);
            const bit2 = if (input[i + 1] > 0) @as(u1, 1) else @as(u1, 0);

            // Check for transition at bit boundary
            const transition = (bit1 != self.last_phase);

            if (transition) {
                output[out_idx] = 0.0; // '0' - transition present
            } else {
                output[out_idx] = 1.0; // '1' - no transition
            }

            out_idx += 1;
            self.last_phase = bit2;
            i += 2;
        }

        return radio.ProcessResult.init(&[1]usize{i}, &[1]usize{out_idx});
    }
};
