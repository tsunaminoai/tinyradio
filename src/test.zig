const std = @import("std");
const rl = @import("raylib");
const radio_receiver = @import("radio.zig"); // Your RadioReceiver module

// Audio configuration
const SAMPLE_RATE = 48000; // 48 kHz output
const CHANNELS = 1; // Mono for now
const SAMPLE_SIZE = 16; // 16-bit samples
const BUFFER_SIZE = 2048; // Samples per buffer

var receiver: radio_receiver.RadioReceiver = undefined;

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize raylib window and audio
    rl.initWindow(400, 200, "Radio Audio Test");
    defer rl.closeWindow();

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    rl.setTargetFPS(60);

    // Create and initialize radio receiver
    receiver = try radio_receiver.RadioReceiver.init(allocator);
    defer receiver.deinit();

    try receiver.connect();

    // Create audio stream for output
    const audio_stream = try rl.loadAudioStream(SAMPLE_RATE, SAMPLE_SIZE, CHANNELS);
    defer rl.unloadAudioStream(audio_stream);

    // Start audio playback
    rl.playAudioStream(audio_stream);

    // Start radio receiver
    try receiver.start();
    defer receiver.stop() catch {};

    // Audio buffers
    var float_buffer: [BUFFER_SIZE]f32 = undefined;
    var audio_buffer: [BUFFER_SIZE]i16 = undefined;

    // State variables
    var frequency: f32 = 93.5; // Starting frequency in MHz
    var volume: f32 = 0.5;
    // var is_running = true;
    // _ = is_running; // autofix

    // try testAudioPipeline(&receiver);

    // Main loop
    while (!rl.windowShouldClose()) {
        // Handle input
        if (rl.isKeyPressed(.escape)) break;

        // Frequency control with arrow keys
        if (rl.isKeyPressed(.right)) {
            frequency += 0.1;
            if (frequency > 108.0) frequency = 108.0;
            try receiver.setFrequency(frequency);
        }
        if (rl.isKeyPressed(.left)) {
            frequency -= 0.1;
            if (frequency < 88.0) frequency = 88.0;
            try receiver.setFrequency(frequency);
        }

        // Volume control with up/down
        if (rl.isKeyPressed(.up)) {
            volume += 0.1;
            if (volume > 1.0) volume = 1.0;
            try receiver.setGain(volume);
        }
        if (rl.isKeyPressed(.down)) {
            volume -= 0.1;
            if (volume < 0.0) volume = 0.0;
            try receiver.setGain(volume);
        }

        // Process audio if stream needs more data
        if (rl.isAudioStreamProcessed(audio_stream)) {
            // Try to get audio samples from the receiver
            const samples_read = receiver.getAudioSamples(&float_buffer) catch 0;

            if (samples_read > 0) {
                // Convert float samples to int16 for raylib
                for (float_buffer[0..samples_read], 0..) |sample, i| {
                    // Clamp to [-1, 1] range
                    const clamped = std.math.clamp(sample, -1.0, 1.0);
                    // Convert to int16 range
                    audio_buffer[i] = @intFromFloat(clamped * 32767.0);
                }

                // Update audio stream with new samples
                rl.updateAudioStream(audio_stream, &audio_buffer, @intCast(samples_read));
            } else {
                // If no samples available, send silence to prevent underrun
                @memset(&audio_buffer, 0);
                rl.updateAudioStream(audio_stream, &audio_buffer, BUFFER_SIZE);
            }
        }

        // Draw UI
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.black);

        // Display status
        rl.drawText("Radio Audio Test", 10, 10, 20, rl.Color.white);

        var freq_text: [32]u8 = undefined;
        const freq_str = std.fmt.bufPrintZ(&freq_text, "Frequency: {d:.1} MHz", .{frequency}) catch "Error";
        rl.drawText(freq_str, 10, 40, 18, rl.Color.green);

        var vol_text: [32]u8 = undefined;
        const vol_str = std.fmt.bufPrintZ(&vol_text, "Volume: {d:.0}%", .{volume * 100}) catch "Error";
        rl.drawText(vol_str, 10, 65, 18, rl.Color.green);

        rl.drawText("Controls:", 10, 100, 16, rl.Color.light_gray);
        rl.drawText("← → : Change frequency", 10, 120, 14, rl.Color.gray);
        rl.drawText("↑ ↓ : Change volume", 10, 140, 14, rl.Color.gray);
        rl.drawText("ESC : Exit", 10, 160, 14, rl.Color.gray);
    }
}

// Alternative: Callback-based audio processing (more efficient)
pub fn audioCallback(buffer: *anyopaque, frames: u32) callconv(.C) void {
    _ = buffer;
    _ = frames;
    // This would be called by raylib when it needs audio
    // You would need to make receiver accessible here

}

// Test function for debugging audio pipeline
fn testAudioPipeline(rx: *radio_receiver.RadioReceiver) !void {
    var test_buffer: [1024]f32 = undefined;

    std.debug.print("Testing audio pipeline...\n", .{});

    // Try to read some samples
    const samples = try rx.getAudioSamples(&test_buffer);

    if (samples > 0) {
        std.debug.print("Got {} samples\n", .{samples});

        // Calculate RMS for signal level
        var sum: f32 = 0;
        for (test_buffer[0..samples]) |sample| {
            sum += sample * sample;
        }
        const rms = @sqrt(sum / @as(f32, @floatFromInt(samples)));

        std.debug.print("RMS level: {d:.4}\n", .{rms});

        // Check for clipping
        var clipped: usize = 0;
        for (test_buffer[0..samples]) |sample| {
            if (@abs(sample) >= 1.0) clipped += 1;
        }
        if (clipped > 0) {
            std.debug.print("Warning: {} samples clipped!\n", .{clipped});
        }
    } else {
        std.debug.print("No samples available\n", .{});
    }
}
