const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
const print = std.debug.print;

const radio = @import("radio");
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
        // if (output.len < input.len) {
        //     return radio.ProcessResult.init(&[1]usize{0}, &[1]usize{0});
        // }

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

    pub fn init(symbol_rate: f32, sample_rate: f32) Self {
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
pub fn SamplerBlock(comptime T: type) type {
    return struct {
        block: radio.Block,
        last_clock: f32,
        data_buffer: std.ArrayList(T),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .block = radio.Block.init(Self),
                .last_clock = 0,
                .data_buffer = std.ArrayList(T).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.data_buffer.deinit();
        }

        pub fn process(self: *Self, data_input: []const T, clock_input: []const f32, output: []T) !radio.ProcessResult {
            if (data_input.len != clock_input.len) {
                return radio.ProcessResult.init(&[2]usize{ 0, 0 }, &[1]usize{0});
            }

            var out_idx: usize = 0;

            for (data_input, 0..) |data_sample, i| {
                // Detect rising edge on clock
                const rising_edge = self.last_clock <= 0.5 and clock_input[i] > 0.5;

                if (rising_edge and out_idx < output.len) {
                    // Sample the data on rising edge
                    output[out_idx] = data_sample;
                    out_idx += 1;
                }

                self.last_clock = clock_input[i];
            }

            return radio.ProcessResult.init(&[2]usize{ data_input.len, clock_input.len }, &[1]usize{out_idx});
        }
    };
}

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
    last_bit: u1,
    invert: bool = false,

    const Self = @This();

    pub fn init() DifferentialManchesterDecoderBlock {
        return .{
            .block = radio.Block.init(Self),
            .last_bit = 0,
        };
    }

    pub fn process(self: *Self, input: []const u1, output: []u1) !radio.ProcessResult {
        if (output.len < input.len / 2) {
            return radio.ProcessResult.init(&[1]usize{0}, &[1]usize{0});
        }

        var out_idx: usize = 0;
        var prev_bit = self.last_bit;
        for (0..input.len - 1) |i| {
            const cur_bit = input[i];
            if (cur_bit == 0)
                prev_bit = cur_bit
            else {
                if (prev_bit == 0 and cur_bit == 1) {
                    output[out_idx] = @as(u1, @intFromBool(self.invert)) & 1 | 0;
                    out_idx += 1;
                    prev_bit = 0;
                } else if (prev_bit == 1 and cur_bit == 0) {
                    output[out_idx] = @as(u1, @intFromBool(self.invert)) & 0 | 1;
                    out_idx += 1;
                    prev_bit = 0;
                } else {
                    // clock skip
                    prev_bit = cur_bit;
                }
            }
        }
        self.last_bit = prev_bit;

        return radio.ProcessResult.init(&[1]usize{input.len}, &[1]usize{out_idx});
    }
};
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

/// Frequency Rolloff Filter Block (-3dB @ 3kHz)
/// Simulates tape recorder high-frequency response limitations
pub const FrequencyRolloffBlock = struct {
    // IIR filter coefficients for -3dB @ 3kHz
    b0: f32,
    b1: f32,
    a1: f32,

    // Filter state variables
    x1: f32,
    y1: f32,

    sample_rate: f32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sample_rate: f32) !Self {
        _ = allocator; // Not needed for this simple filter

        // Calculate IIR coefficients for 1-pole lowpass at 3kHz (-3dB point)
        const cutoff_freq: f32 = 3000.0;
        const omega = 2.0 * math.pi * cutoff_freq / sample_rate;
        const alpha = math.tan(omega / 2.0);
        const norm = 1.0 / (1.0 + alpha);

        return Self{
            .b0 = alpha * norm,
            .b1 = alpha * norm,
            .a1 = (1.0 - alpha) * norm,
            .x1 = 0.0,
            .y1 = 0.0,
            .sample_rate = sample_rate,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self; // No cleanup needed
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) !radio.ProcessResult {
        for (input, 0..) |sample, i| {
            // Direct Form I IIR filter
            output[i] = self.b0 * sample + self.b1 * self.x1 + self.a1 * self.y1;

            // Update state
            self.x1 = sample;
            self.y1 = output[i];
        }
        return radio.ProcessResult.init(&[1]usize{input.len}, &[1]usize{input.len});
    }
};

/// Dynamic Compression Block (70% threshold)
/// Simulates tape saturation and dynamic range compression
pub const DynamicCompressorBlock = struct {
    threshold: f32,
    ratio: f32,
    attack_coeff: f32,
    release_coeff: f32,

    // State variables
    envelope: f32,
    gain_reduction: f32,

    sample_rate: f32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sample_rate: f32) !Self {
        _ = allocator; // Not needed

        // 70% threshold = -3dB in linear terms
        const threshold_db: f32 = -3.0;
        const threshold_linear = math.pow(f32, 10.0, threshold_db / 20.0);

        // Attack/release time constants
        const attack_time_ms: f32 = 5.0; // Fast attack for tape compression
        const release_time_ms: f32 = 100.0; // Moderate release

        const attack_coeff = math.exp(-1.0 / (sample_rate * attack_time_ms / 1000.0));
        const release_coeff = math.exp(-1.0 / (sample_rate * release_time_ms / 1000.0));

        return Self{
            .threshold = threshold_linear,
            .ratio = 4.0, // 4:1 compression ratio typical for tape
            .attack_coeff = attack_coeff,
            .release_coeff = release_coeff,
            .envelope = 0.0,
            .gain_reduction = 1.0,
            .sample_rate = sample_rate,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self; // No cleanup needed
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) !radio.ProcessResult {
        for (input, 0..) |sample, i| {
            const abs_sample = @abs(sample);

            // Envelope follower with attack/release
            if (abs_sample > self.envelope) {
                self.envelope += (abs_sample - self.envelope) * (1.0 - self.attack_coeff);
            } else {
                self.envelope += (abs_sample - self.envelope) * (1.0 - self.release_coeff);
            }

            // Calculate gain reduction
            if (self.envelope > self.threshold) {
                const overshoot = self.envelope / self.threshold;
                const compressed_overshoot = math.pow(f32, overshoot, 1.0 / self.ratio);
                self.gain_reduction = self.threshold * compressed_overshoot / self.envelope;
            } else {
                self.gain_reduction = 1.0;
            }

            // Apply compression with soft knee
            output[i] = sample * self.gain_reduction;
        }
        return radio.ProcessResult.init(&[1]usize{input.len}, &[1]usize{input.len});
    }
};

/// Wow & Flutter Block (±0.3% speed variation)
/// Simulates tape transport irregularities causing pitch/speed variations
pub const WowFlutterBlock = struct {
    // Oscillators for wow and flutter
    wow_phase: f32,
    flutter_phase: f32,

    // Delay line for pitch shifting via time-domain interpolation
    delay_buffer: []f32,
    delay_length: usize,
    write_index: usize,

    sample_rate: f32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sample_rate: f32) !Self {
        // Delay buffer for ±0.3% speed variation
        const max_delay_samples = @as(usize, @intFromFloat(sample_rate * 0.01)); // 10ms buffer
        const delay_buffer = try allocator.alloc(f32, max_delay_samples);
        @memset(delay_buffer, 0.0);

        return Self{
            .wow_phase = 0.0,
            .flutter_phase = 0.0,
            .delay_buffer = delay_buffer,
            .delay_length = max_delay_samples,
            .write_index = 0,
            .sample_rate = sample_rate,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.delay_buffer);
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) !radio.ProcessResult {
        const wow_freq: f32 = 0.5; // 0.5Hz wow frequency
        const flutter_freq: f32 = 6.0; // 6Hz flutter frequency
        const speed_variation: f32 = 0.003; // ±0.3%

        for (input, 0..) |sample, i| {
            // Write input to delay buffer
            self.delay_buffer[self.write_index] = sample;

            // Calculate wow and flutter modulation
            const wow = math.sin(self.wow_phase) * speed_variation;
            const flutter = math.sin(self.flutter_phase) * speed_variation * 0.5; // Flutter is typically smaller
            const total_modulation = wow + flutter;

            // Calculate variable delay (negative modulation = faster playback)
            const delay_samples = self.sample_rate * 0.005 * (1.0 + total_modulation); // Base delay with modulation
            const delay_int = @as(usize, @intFromFloat(delay_samples));
            const delay_frac = delay_samples - @as(f32, @floatFromInt(delay_int));

            // Linear interpolation for fractional delay
            const read_index1 = (self.write_index + self.delay_length - delay_int) % self.delay_length;
            const read_index2 = (read_index1 + self.delay_length - 1) % self.delay_length;

            const sample1 = self.delay_buffer[read_index1];
            const sample2 = self.delay_buffer[read_index2];

            output[i] = sample1 * (1.0 - delay_frac) + sample2 * delay_frac;

            // Update oscillator phases
            self.wow_phase += 2.0 * math.pi * wow_freq / self.sample_rate;
            self.flutter_phase += 2.0 * math.pi * flutter_freq / self.sample_rate;

            if (self.wow_phase >= 2.0 * math.pi) self.wow_phase -= 2.0 * math.pi;
            if (self.flutter_phase >= 2.0 * math.pi) self.flutter_phase -= 2.0 * math.pi;

            // Advance write index
            self.write_index = (self.write_index + 1) % self.delay_length;
        }
        return radio.ProcessResult.init(&[1]usize{input.len}, &[1]usize{input.len});
    }
};

/// AWGN Noise Block (SNR: 15-25dB)
/// Simulates tape hiss and electronic noise
pub const AwgnNoiseBlock = struct {
    // PRNG for noise generation
    prng: std.Random.DefaultPrng,

    // Noise parameters
    signal_power: f32,
    noise_variance: f32,
    snr_db: f32,

    sample_rate: f32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sample_rate: f32) !Self {
        _ = allocator; // Not needed

        const initial_snr: f32 = 20.0; // Default 20dB SNR

        return Self{
            .prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp()))),
            .signal_power = 1.0,
            .noise_variance = math.pow(f32, 10.0, -initial_snr / 10.0),
            .snr_db = initial_snr,
            .sample_rate = sample_rate,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self; // No cleanup needed
    }

    pub fn setSnr(self: *Self, snr_db: f32) void {
        self.snr_db = snr_db;
        self.noise_variance = math.pow(f32, 10.0, -snr_db / 10.0);
    }

    pub fn process(self: *Self, input: []const f32, output: []f32) !radio.ProcessResult {
        var random = self.prng.random();

        for (input, 0..) |sample, i| {
            // Box-Muller transform for Gaussian noise
            const _u1 = random.float(f32);
            const _u2 = random.float(f32);
            const noise = math.sqrt(-2.0 * math.log(f32, math.e, _u1)) * math.cos(2.0 * math.pi * _u2) * math.sqrt(self.noise_variance);

            // Add noise to signal
            output[i] = sample + noise;
        }
        return radio.ProcessResult.init(&[1]usize{input.len}, &[1]usize{input.len});
    }
};

pub fn FFTBandAnalyzer(comptime numBands: usize, comptime fftSize: usize) type {
    std.debug.assert(math.isPowerOfTwo(fftSize));

    return struct {
        block: radio.Block,
        fft_size: usize = fftSize,
        sample_rate: f32,

        // working buffers
        time_buffer: [fftSize]f32 = undefined,
        freq_buffer: [fftSize]math.Complex(f32) = undefined,
        window_function: [fftSize]f32 = blk: {
            var tmp: [fftSize]f32 = undefined;
            for (0..fftSize) |i| {
                const n = @as(f32, @floatFromInt(i));
                const N = @as(f32, @floatFromInt(fftSize));
                tmp[i] = 0.5 * (1.0 - math.cos(2.0 * math.pi * n / (N - 1.0)));
            }
            break :blk tmp;
        },

        // band analysis
        band_mags: [numBands]f32 = undefined,
        band_freqs: [numBands]f32 = blk: {
            var tmp: [numBands]f32 = undefined;
            for (0..numBands) |i| {
                tmp[i] = (@as(f32, @floatFromInt(i)) + 0.5) * (MaxFreq / numBands);
            }
            break :blk tmp;
        },

        //processing
        input_idx: usize = 0,
        frames_processed: usize = 0,

        allocator: Allocator,

        const Self = @This();
        const MaxFreq = 20_000;

        pub fn init(alloc: Allocator, sample_rate: f32) !Self {
            if (sample_rate < MaxFreq) return error.InsufficientSampleRate;

            return Self{
                .block = radio.Block.init(Self),
                .allocator = alloc,
                .sample_rate = sample_rate,
            };
        }
        pub fn deinit(self: *Self) void {
            _ = self; // autofix

        }
        /// Process incoming audio samples and update band analysis
        pub fn process(self: *Self, input_samples: []const f32) !radio.ProcessResult {
            for (input_samples) |sample| {
                // Fill circular buffer
                self.time_buffer[self.input_idx] = sample;
                self.input_idx = (self.input_idx + 1) % self.fft_size;

                // Perform FFT when buffer is full
                if (self.input_idx == 0) {
                    self.performFFTAnalysis();
                    self.frames_processed += 1;
                }
            }
            return radio.ProcessResult.init(&[1]usize{input_samples.len}, &[0]usize{});
        }

        /// Perform FFT analysis and update band magnitudes
        fn performFFTAnalysis(self: *Self) void {
            // Apply window function to time domain data
            for (&self.freq_buffer, 0..) |*freq_sample, i| {
                const windowed_sample = self.time_buffer[i] * self.window_function[i];
                freq_sample.* = math.Complex(f32).init(windowed_sample, 0.0);
            }

            // Perform FFT (using Cooley-Tukey radix-2 algorithm)
            self.fft(&self.freq_buffer);

            // Calculate band magnitudes
            self.calculateBandMagnitudes();
        }

        /// Calculate magnitude for each of the 10 frequency bands
        fn calculateBandMagnitudes(self: *Self) void {
            const bin_resolution = self.sample_rate / @as(f32, @floatFromInt(self.fft_size));
            const band_width = MaxFreq / numBands;

            // Initialize band magnitudes
            @memset(&self.band_mags, 0.0);

            for (0..numBands) |band| {
                const band_start_freq = @as(f32, @floatFromInt(band)) * band_width;
                const band_end_freq = band_start_freq + band_width;

                const start_bin = @as(usize, @intFromFloat(band_start_freq / bin_resolution));
                const end_bin = @as(usize, @intFromFloat(band_end_freq / bin_resolution));

                var band_power: f32 = 0.0;
                var bin_count: u32 = 0;

                // Sum power in frequency band (using only positive frequencies)
                for (start_bin..@min(end_bin, self.fft_size / 2)) |bin| {
                    const magnitude = self.freq_buffer[bin].magnitude();
                    band_power += magnitude * magnitude;
                    bin_count += 1;
                }

                // Calculate RMS magnitude and convert to dB
                if (bin_count > 0) {
                    const rms_magnitude = math.sqrt(band_power / @as(f32, @floatFromInt(bin_count)));
                    // Convert to dB with reference level (prevent log(0))
                    const db_magnitude = 20.0 * math.log10(@max(rms_magnitude, 1e-10));
                    self.band_mags[band] = db_magnitude;
                }
            }
        }
        /// FFT implementation using Cooley-Tukey radix-2 algorithm
        fn fft(self: *Self, x: []math.Complex(f32)) void {
            _ = self; // autofix
            const N = x.len;
            if (N <= 1) return;

            // Bit-reversal permutation
            var j: usize = 0;
            for (x, 0..) |_, i| {
                if (i < j) {
                    const temp = x[i];
                    x[i] = x[j];
                    x[j] = temp;
                }

                var k = N >> 1;
                while (j & k != 0) {
                    j ^= k;
                    k >>= 1;
                }
                j ^= k;
            }

            // Cooley-Tukey butterfly operations
            var length: usize = 2;
            while (length <= N) {
                const angle = -2.0 * math.pi / @as(f32, @floatFromInt(length));
                const wlen = math.Complex(f32).init(math.cos(angle), math.sin(angle));

                var i: usize = 0;
                while (i < N) {
                    var w = math.Complex(f32).init(1.0, 0.0);
                    var j2: usize = 0;
                    while (j < length / 2) {
                        const u = x[i + j];
                        const v = x[i + j + length / 2].mul(w);

                        if (i + j2 >= x.len or i + j2 + length / 2 >= x.len) continue;

                        x[i + j2] = u.add(v);
                        x[i + j2 + length / 2] = u.sub(v);

                        w = w.mul(wlen);
                        j2 += 1;
                    }
                    i += length;
                }
                length *= 2;
            }
        }

        /// Get current band analysis results
        pub fn getBandMagnitudes(self: *const Self) [numBands]f32 {
            return self.band_magnitudes;
        }

        /// Get band center frequencies
        pub fn getBandFrequencies(self: *const Self) [numBands]f32 {
            return self.band_frequencies;
        }

        /// Get processing statistics
        pub fn getStats(self: *const Self) FFTAnalysisStats {
            return FFTAnalysisStats{
                .frames_processed = self.frames_processed,
                .frequency_resolution = self.sample_rate / @as(f32, @floatFromInt(self.fft_size)),
                .analysis_bandwidth = MaxFreq / numBands,
            };
        }

        pub fn printBandAnalysis(self: Self) void {
            const magnitudes = self.getBandMagnitudes();
            const frequencies = self.getBandFrequencies();
            const stats = self.getStats();

            print("\n=== 10-Band FFT Analysis (0-20kHz) ===\n");
            print("Frequency Resolution: {d:.2} Hz\n", .{stats.frequency_resolution});
            print("Frames Processed: {}\n", .{stats.frames_processed});
            print("\nBand Analysis:\n");

            for (magnitudes, frequencies, 0..) |magnitude, center_freq, i| {
                const band_start = center_freq - 1000.0;
                const band_end = center_freq + 1000.0;
                const bar_length = Self.magnitudeToBarLength(magnitude);

                print("Band {}: {d:>5.0}-{d:>5.0} Hz | {d:>6.1} dB |", .{ i + 1, band_start, band_end, magnitude });

                // Visual bar representation
                var j: usize = 0;
                while (j < bar_length) : (j += 1) {
                    print("█");
                }
                print("\n");
            }
            print("================================\n");
        }

        fn magnitudeToBarLength(magnitude_db: f32) usize {
            // Map dB range (-60 to 0 dB) to bar length (0 to 40 chars)
            const normalized = math.clamp((magnitude_db + 60.0) / 60.0, 0.0, 1.0);
            return @as(usize, @intFromFloat(normalized * 40.0));
        }
    };
}
/// Analysis statistics structure
pub const FFTAnalysisStats = struct {
    frames_processed: u64,
    frequency_resolution: f32,
    analysis_bandwidth: f32,
};

test "fft band" {}
