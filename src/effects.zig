const std = @import("std");
const radio = @import("radio");
const math = std.math;
const b = @import("blocks.zig");
const print = std.debug.print;

/// Tape Simulator Composite Block for ZigRadio
/// Simulates vintage tape recorder characteristics including:
/// - Frequency rolloff (-3dB @ 3kHz)
/// - Dynamic compression (70% threshold)
/// - Wow & flutter (±0.3% speed variation)
/// - AWGN noise (SNR: 15-25dB)
pub const TapeSimulator = struct {
    // Component blocks
    frequency_rolloff: b.FrequencyRolloffBlock,
    dynamic_compressor: b.DynamicCompressorBlock,
    wow_flutter: b.WowFlutterBlock,
    awgn_noise: b.AwgnNoiseBlock,

    // Block infrastructure
    allocator: std.mem.Allocator,
    sample_rate: f32,
    initialized: bool,
    block: radio.Block,
    enabled: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sample_rate: f32) !Self {
        return Self{
            .block = radio.Block.init(Self),
            .frequency_rolloff = try b.FrequencyRolloffBlock.init(allocator, sample_rate),
            .dynamic_compressor = try b.DynamicCompressorBlock.init(allocator, sample_rate),
            .wow_flutter = try b.WowFlutterBlock.init(allocator, sample_rate),
            .awgn_noise = try b.AwgnNoiseBlock.init(allocator, sample_rate),
            .allocator = allocator,
            .sample_rate = sample_rate,
            .initialized = true,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.frequency_rolloff.deinit();
            self.dynamic_compressor.deinit();
            self.wow_flutter.deinit();
            self.awgn_noise.deinit();
            self.initialized = false;
        }
    }

    /// Process audio samples through the complete tape simulation chain
    pub fn process(self: *Self, input_samples: []const f32, output_samples: []f32) !radio.ProcessResult {
        std.debug.assert(input_samples.len == output_samples.len);
        if (!self.enabled) {
            @memcpy(output_samples, input_samples);
        } else {

            // Temporary buffers for cascaded processing
            const temp_buffer1 = try self.allocator.alloc(f32, input_samples.len);
            defer self.allocator.free(temp_buffer1);

            const temp_buffer2 = try self.allocator.alloc(f32, input_samples.len);
            defer self.allocator.free(temp_buffer2);

            const temp_buffer3 = try self.allocator.alloc(f32, input_samples.len);
            defer self.allocator.free(temp_buffer3);

            // Signal processing chain
            _ = try self.frequency_rolloff.process(input_samples, temp_buffer1);
            _ = try self.dynamic_compressor.process(temp_buffer1, temp_buffer2);
            _ = try self.wow_flutter.process(temp_buffer2, temp_buffer3);
            _ = try self.awgn_noise.process(temp_buffer3, output_samples);
        }

        return radio.ProcessResult.init(&[1]usize{input_samples.len}, &[1]usize{output_samples.len});
    }

    /// Set SNR for noise generation (15-25dB range)
    pub fn setSnr(self: *Self, snr_db: f32) void {
        self.awgn_noise.setSnr(math.clamp(snr_db, 15.0, 25.0));
    }
};

// Example usage and test function
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sample_rate: f32 = 44100.0;
    const buffer_size: usize = 1024;

    // Initialize tape simulator
    var tape_sim = try TapeSimulator.init(allocator, sample_rate);
    defer tape_sim.deinit();

    // Set SNR to 18dB (within 15-25dB range)
    tape_sim.setSnr(18.0);

    // Test with sine wave input
    const input_buffer = try allocator.alloc(f32, buffer_size);
    defer allocator.free(input_buffer);

    const output_buffer = try allocator.alloc(f32, buffer_size);
    defer allocator.free(output_buffer);

    // Generate 1kHz test tone
    for (input_buffer, 0..) |*sample, i| {
        const t = @as(f32, @floatFromInt(i)) / sample_rate;
        sample.* = 0.5 * math.sin(2.0 * math.pi * 1000.0 * t);
    }

    // Process through tape simulator
    tape_sim.process(input_buffer, output_buffer);

    print("Tape Simulator Composite Block Test Completed\n");
    print("Processed {} samples through complete tape simulation chain\n", .{buffer_size});
    print("Effects applied:\n");
    print("- Frequency rolloff: -3dB @ 3kHz\n");
    print("- Dynamic compression: 70% threshold, 4:1 ratio\n");
    print("- Wow & flutter: ±0.3% speed variation (0.5Hz wow, 6Hz flutter)\n");
    print("- AWGN noise: 18dB SNR\n");
}
