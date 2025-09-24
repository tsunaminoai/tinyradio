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
    snr: SNRSink,

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
            .snr = try .init(allocator, 31, 32_000, 100),
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
        self.snr.deinit();
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
                try self.flowgraph.connectPort(&self.fm_stereo.block, "out1", &self.snr.block, "in1");
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
        return dbfsToPercent(self.snr.getSNRResults().signal_power_db / 100);
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

/// Convert dBFS signal power to percentage (0-100%)
pub fn dbfsToPercent(dbfs: f32) f32 {
    // Formula: percentage = 10^(dBFS/20) * 100
    return math.pow(f32, 10.0, dbfs / 20.0) * 100.0;
}

/// Convert percentage (0-100%) back to dBFS
pub fn percentToDbfs(percent: f32) f32 {
    // Formula: dBFS = 20 * log10(percent/100)
    const normalized = @max(percent / 100.0, 1e-10); // Prevent log(0)
    return 20.0 * math.log10(normalized);
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

pub const SNRSink = struct {
    block: radio.Block,

    // Configuration
    filter_length: usize,
    sample_rate: f32,
    analysis_window_size: usize,

    // Buffering for median filter
    signal_buffer: []f32,
    filtered_buffer: []f32,
    temp_buffer: []f32,
    buffer_index: usize,

    // Statistical accumulators
    signal_power_accumulator: f64 = 0,
    noise_power_accumulator: f64 = 0,
    sample_count: u64 = 0,
    peak_tracker: f32 = 0,

    // Analysis results
    current_snr_db: f32 = -60.0,
    signal_power_db: f32 = -80.0,
    noise_power_db: f32 = -20.0,
    confidence_level: f32 = 0,

    // Configuration parameters
    tracking_speed: f32 = 1.0,
    noise_floor_db: f32 = -80.0,

    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, filter_length: usize, sample_rate: f32, window_size: usize) !Self {
        // Validate parameters
        if (filter_length == 0 or filter_length % 2 == 0) {
            return error.InvalidFilterLength; // Must be odd
        }
        if (window_size < filter_length) {
            return error.InvalidWindowSize;
        }

        // Allocate buffers
        const signal_buffer = try allocator.alloc(f32, window_size);
        @memset(signal_buffer, 0.0);

        const filtered_buffer = try allocator.alloc(f32, window_size);
        @memset(filtered_buffer, 0.0);

        const temp_buffer = try allocator.alloc(f32, filter_length);
        @memset(temp_buffer, 0.0);

        return Self{
            .filter_length = filter_length,
            .allocator = allocator,
            .block = radio.Block.init(Self),
            .analysis_window_size = window_size,
            .sample_rate = sample_rate,
            .signal_buffer = signal_buffer,
            .filtered_buffer = filtered_buffer,
            .temp_buffer = temp_buffer,
            .buffer_index = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.signal_buffer);
        self.allocator.free(self.filtered_buffer);
        self.allocator.free(self.temp_buffer);
    }

    pub fn process(self: *Self, input: []const f32) !radio.ProcessResult {
        // Fill circular buffer and process when full
        for (input) |sample| {
            self.signal_buffer[self.buffer_index] = self.autoNormalize(sample);
            self.buffer_index = (self.buffer_index + 1) % self.analysis_window_size;

            // Process when buffer is full
            if (self.buffer_index == 0) {
                self.performSNRAnalysis();
            }
        }

        self.sample_count += input.len;

        // Print SNR every second
        // if (@mod(self.sample_count, @as(u64, @intFromFloat(self.sample_rate))) == 0) {
        //     std.debug.print("SNR: {d:.1} dB | Signal: {d:.1} dBFS | Noise: {d:.1} dBFS | Confidence: {d:.1}%\n", .{
        //         self.current_snr_db,
        //         self.signal_power_db,
        //         self.noise_power_db,
        //         self.confidence_level * 100.0,
        //     });
        // }

        return radio.ProcessResult.init(&[1]usize{input.len}, &[0]usize{});
    }

    /// Perform median filtering and SNR analysis on full buffer
    fn performSNRAnalysis(self: *Self) void {
        // Apply median filter to separate signal from noise
        self.medianFilter();

        // Calculate signal and noise power
        var signal_power: f64 = 0.0;
        var noise_power: f64 = 0.0;

        for (self.signal_buffer, self.filtered_buffer) |original, filtered| {
            const noise_sample = original - filtered;

            signal_power += @as(f64, filtered * filtered);
            noise_power += @as(f64, noise_sample * noise_sample);
        }

        // Calculate RMS values
        const signal_rms = math.sqrt(signal_power / @as(f64, @floatFromInt(self.analysis_window_size)));
        const noise_rms = math.sqrt(noise_power / @as(f64, @floatFromInt(self.analysis_window_size)));

        // Convert to dB with proper reference level
        const full_scale: f32 = 1.0;

        const signal_db = 20.0 * math.log10(@max(@as(f32, @floatCast(signal_rms)) / full_scale, 1e-10));
        const noise_db = 20.0 * math.log10(@max(@as(f32, @floatCast(noise_rms)) / full_scale, 1e-10));

        // Apply exponential smoothing based on tracking speed
        const alpha = self.tracking_speed * 0.1 + 0.01; // 0.01 to 0.11

        self.signal_power_db += alpha * (signal_db - self.signal_power_db);
        self.noise_power_db += alpha * (noise_db - self.noise_power_db);

        // Calculate SNR
        const new_snr = self.signal_power_db - self.noise_power_db;
        self.current_snr_db += alpha * (new_snr - self.current_snr_db);

        // Update confidence based on measurement stability
        self.updateConfidence();
    }

    /// Automatic gain control to keep signals in reasonable range
    fn autoNormalize(self: *Self, sample: f32) f32 {
        const abs_sample = @abs(sample);

        // Track peak with slow decay
        const attack_coeff: f32 = 0.99;
        const release_coeff: f32 = 0.9999;

        if (abs_sample > self.peak_tracker) {
            self.peak_tracker += (abs_sample - self.peak_tracker) * (1.0 - attack_coeff);
        } else {
            self.peak_tracker *= release_coeff;
        }

        // Apply automatic gain adjustment
        if (self.peak_tracker > 0.1) { // Avoid division by very small numbers
            const target_peak: f32 = 0.7; // Target 70% of full scale
            const gain = target_peak / self.peak_tracker;
            const limited_gain = math.clamp(gain, 0.1, 10.0); // Limit gain range
            return sample * limited_gain;
        }

        return sample;
    }

    /// Apply median filter to signal buffer
    fn medianFilter(self: *Self) void {
        const half_length = self.filter_length / 2;

        for (self.signal_buffer, 0..) |_, i| {
            // Collect surrounding samples for median calculation
            var sample_count: usize = 0;

            for (0..self.filter_length) |j| {
                const offset = j -| half_length; // Saturating subtraction
                var input_index: usize = undefined;

                if (i >= offset) {
                    input_index = i - offset;
                } else {
                    input_index = 0; // Boundary condition: use first sample
                }

                if (input_index >= self.analysis_window_size) {
                    input_index = self.analysis_window_size - 1; // Boundary condition: use last sample
                }

                self.temp_buffer[sample_count] = self.signal_buffer[input_index];
                sample_count += 1;
            }

            // Sort samples and find median
            std.sort.heap(f32, self.temp_buffer[0..sample_count], {}, comptime std.sort.asc(f32));
            self.filtered_buffer[i] = self.temp_buffer[sample_count / 2];
        }
    }

    /// Update confidence level based on measurement stability
    fn updateConfidence(self: *Self) void {
        // Confidence increases with more processed frames
        const frames_processed = self.sample_count / self.analysis_window_size;
        const sample_confidence = 1.0 - math.exp(-@as(f32, @floatFromInt(frames_processed)) / 10.0);

        // Reduce confidence if SNR is very low (likely unreliable measurement)
        const snr_confidence = math.clamp((self.current_snr_db + 40.0) / 40.0, 0.1, 1.0);

        self.confidence_level = @min(sample_confidence * snr_confidence, 0.95);
    }

    /// Configure SNR measurement parameters
    pub fn configure(self: *Self, tracking_speed: f32, noise_floor_db: f32) void {
        self.tracking_speed = math.clamp(tracking_speed, 0.0, 1.0);
        self.noise_floor_db = noise_floor_db;
    }

    /// Get current SNR measurement results
    pub fn getSNRResults(self: *const Self) SNRResults {
        return SNRResults{
            .snr_db = self.current_snr_db,
            .signal_power_db = self.signal_power_db,
            .noise_power_db = self.noise_power_db,
            .confidence_level = self.confidence_level,
            .sample_count = self.sample_count,
        };
    }

    /// Reset measurement accumulator
    pub fn reset(self: *Self) void {
        self.signal_power_accumulator = 0.0;
        self.noise_power_accumulator = 0.0;
        self.sample_count = 0;
        self.confidence_level = 0.0;
        self.buffer_index = 0;

        @memset(self.signal_buffer, 0.0);
        @memset(self.filtered_buffer, 0.0);
        @memset(self.temp_buffer, 0.0);
    }
};

/// SNR measurement results structure
pub const SNRResults = struct {
    snr_db: f32,
    signal_power_db: f32,
    noise_power_db: f32,
    confidence_level: f32,
    sample_count: u64,
};
