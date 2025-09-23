const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
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
