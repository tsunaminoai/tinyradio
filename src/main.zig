const std = @import("std");
const radio = @import("radio.zig");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
const rl = @import("raylib");
const rg = @import("raygui");

// UI State
const RadioState = struct {
    // Core radio state
    frequency: f32 = 88.1,
    mode: RadioMode = .FM,
    band: Band = .FM_US,
    volume: f32 = 0.5,
    squelch: f32 = 0.0,
    gain: f32 = 30.0,

    // UI state
    is_scanning: bool = false,
    is_recording: bool = false,
    is_powered: bool = false,
    signal_strength: f32 = 0.0,
    stereo_detected: bool = false,

    // Frequency editor
    freq_editing: bool = false,
    freq_input_buf: [16]u8 = undefined,
    freq_input_len: usize = 0,

    // Presets
    presets: [12]Preset = [_]Preset{.{}} ** 12,
    selected_preset: ?usize = null,

    // Audio stream for radio output
    audio_stream: ?rl.AudioStream = null,
};

const RadioMode = enum(u8) {
    FM,
    AM,
    NFM,
    USB,
    LSB,
};

const Band = enum(u8) {
    FM_US, // 88-108 MHz
    FM_Japan, // 76-95 MHz
    Weather, // 162.4-162.55 MHz
    AM_MW, // 530-1700 kHz
    Free, // Free tuning mode
};

const Preset = struct {
    frequency: f32 = 0.0,
    mode: RadioMode = .FM,
    band: Band = .FM_US,
    name: [32]u8 = [_]u8{0} ** 32,
    active: bool = false,
};

const BandLimits = struct {
    min: f32,
    max: f32,
    step: f32,
    unit: []const u8,
};

fn getBandLimits(band: Band) BandLimits {
    return switch (band) {
        .FM_US => .{ .min = 88.0, .max = 108.0, .step = 0.1, .unit = "MHz" },
        .FM_Japan => .{ .min = 76.0, .max = 95.0, .step = 0.1, .unit = "MHz" },
        .Weather => .{ .min = 162.400, .max = 162.550, .step = 0.025, .unit = "MHz" },
        .AM_MW => .{ .min = 530.0, .max = 1700.0, .step = 10.0, .unit = "kHz" },
        .Free => .{ .min = 0.1, .max = 2000.0, .step = 0.001, .unit = "MHz" },
    };
}

pub fn main() !void {
    // Window configuration
    const screenWidth = 480;
    const screenHeight = 640;

    rl.initWindow(screenWidth, screenHeight, "AM/FM Radio - ZigRadio");
    defer rl.closeWindow();

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    rl.setTargetFPS(60);

    // Load custom raygui style (dark theme)
    rg.setStyle(rg.Control.default, .{ .control = .base_color_normal }, 0x2b2d30ff);
    // rg.setStyle(rg.Control.default, rg.ControlOrDefaultProperty.text_color_normal, 0xffffffff);
    // rg.setStyle(rg.Control.default, rg.ControlOrDefaultProperty.base_color_focused, 0x5cb3ccff);
    // rg.setStyle(rg.Control.default, rg.ControlOrDefaultProperty.border_color_focused, 0x84d7f2ff);
    // rg.setStyle(rg.Control.default, rg.ControlProperty., 14);

    var state = RadioState{};

    // Initialize some demo presets
    @memcpy(state.presets[0].name[0..16], "Classic Rock FM\x00");
    state.presets[0].frequency = 88.5;
    state.presets[0].mode = .FM;
    state.presets[0].band = .FM_US;
    state.presets[0].active = true;

    // @memcpy(state.presets[1].name[0..7], "Jazz FM\x00");
    // state.presets[1].frequency = 94.7;
    // state.presets[1].mode = .FM;
    // state.presets[1].band = .FM_US;
    // state.presets[1].active = true;

    // @memcpy(state.presets[2].name[0..10], "News Radio\x00");
    // state.presets[2].frequency = 101.1;
    // state.presets[2].mode = .FM;
    // state.presets[2].band = .FM_US;
    // state.presets[2].active = true;

    // @memcpy(state.presets[3].name[0..9], "Sports AM\x00");
    // state.presets[3].frequency = 650.0;
    // state.presets[3].mode = .AM;
    // state.presets[3].band = .AM_MW;
    // state.presets[3].active = true;

    // Main loop
    while (!rl.windowShouldClose()) {
        // Update
        updateRadio(&state);

        // Draw
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color{ .r = 32, .g = 34, .b = 37, .a = 255 });

        try drawUI(&state);
    }
}

fn updateRadio(state: *RadioState) void {
    // Simulate signal strength based on frequency
    if (state.is_powered) {
        const time = @as(f32, @floatCast(rl.getTime()));
        state.signal_strength = (@sin(time * 2.0) * 0.1 + 0.9) *
            (@cos(state.frequency * 0.1) * 0.2 + 0.8);

        // Stereo detection for FM
        state.stereo_detected = state.mode == .FM and state.signal_strength > 0.7;

        // Update audio stream if needed
        if (state.audio_stream) |stream| {
            if (rl.isAudioStreamProcessed(stream)) {
                // In a real implementation, this would be filled with demodulated audio
                var audio_buffer: [2048]c_short = undefined;
                for (&audio_buffer) |*sample| {
                    // Generate some white noise as placeholder
                    sample.* = @intCast(@as(i32, @intFromFloat(@sin(rl.getTime() * 1000.0) * 1000.0)));
                }
                rl.updateAudioStream(stream, &audio_buffer, 2048);
            }
        }
    } else {
        state.signal_strength = 0.0;
        state.stereo_detected = false;
    }

    // Auto-scan simulation
    if (state.is_scanning and state.is_powered) {
        const limits = getBandLimits(state.band);
        state.frequency += limits.step * 5.0; // Fast scan
        if (state.frequency > limits.max) {
            state.frequency = limits.min;
        }

        // Stop on "strong signal"
        if (state.signal_strength > 0.85) {
            state.is_scanning = false;
        }
    }
}

fn drawUI(state: *RadioState) !void {
    const w = @as(f32, @floatFromInt(rl.getScreenWidth()));

    // Title Bar
    try drawTitleBar(state, w);

    // Main Frequency Display
    drawFrequencyDisplay(state, w);

    // Signal Meter
    drawSignalMeter(state, w);

    // Mode and Band Selection
    drawModeAndBandSelection(state, w);

    // Tuning Controls
    drawTuningControls(state, w);

    // Volume and Squelch
    drawVolumeAndSquelch(state, w);

    // Presets
    drawPresets(state, w);

    // Bottom Controls
    drawBottomControls(state, w);
}

fn drawTitleBar(state: *RadioState, w: f32) !void {
    // Background
    rl.drawRectangle(0, 0, @intFromFloat(w), 40, rl.Color{ .r = 43, .g = 45, .b = 48, .a = 255 });

    // Title
    rl.drawText("AM/FM Radio", 10, 10, 20, rl.Color.white);

    // Power button
    const power_rect = rl.Rectangle{ .x = w - 50, .y = 5, .width = 40, .height = 30 };

    if (rg.button(power_rect, if (state.is_powered) "ON" else "OFF")) {
        state.is_powered = !state.is_powered;
        if (state.is_powered) {
            // Initialize audio stream
            state.audio_stream = try rl.loadAudioStream(48000, 16, 1);
            rl.playAudioStream(state.audio_stream.?);
        } else {
            // Cleanup
            if (state.audio_stream) |stream| {
                rl.unloadAudioStream(stream);
                state.audio_stream = null;
            }
            state.is_scanning = false;
            state.is_recording = false;
        }
    }

    // Status indicators
    if (state.is_powered) {
        if (state.stereo_detected) {
            rl.drawText("STEREO", @intFromFloat(w - 150), 12, 16, rl.Color.green);
        } else if (state.mode == .FM) {
            rl.drawText("MONO", @intFromFloat(w - 150), 12, 16, rl.Color.yellow);
        }

        if (state.is_recording) {
            rl.drawCircle(@intFromFloat(w - 200), 20, 5, rl.Color.red);
            rl.drawText("REC", @intFromFloat(w - 190), 12, 16, rl.Color.red);
        }
    }
}

fn drawFrequencyDisplay(state: *RadioState, w: f32) void {
    const y_base = 50;

    // Background
    rl.drawRectangle(10, y_base, @intFromFloat(w - 20), 80, rl.Color{ .r = 20, .g = 22, .b = 25, .a = 255 });
    rl.drawRectangleLines(10, y_base, @intFromFloat(w - 20), 80, rl.Color{ .r = 92, .g = 179, .b = 204, .a = 255 });

    if (!state.is_powered) {
        rl.drawText("---.--", @intFromFloat(w / 2 - 80), y_base + 20, 48, rl.Color.dark_gray);
        return;
    }

    // Format frequency display
    var freq_buf: [32]u8 = undefined;
    const limits = getBandLimits(state.band);
    const freq_str = std.fmt.bufPrintZ(&freq_buf, "{d:.2} {s}", .{ state.frequency, limits.unit }) catch "Error";

    // Draw frequency (clickable for editing)
    const freq_rect = rl.Rectangle{ .x = w / 2 - 100, .y = @floatFromInt(y_base + 15), .width = 200, .height = 50 };

    if (rl.checkCollisionPointRec(rl.getMousePosition(), freq_rect) and rl.isMouseButtonPressed(rl.MouseButton.left)) {
        state.freq_editing = true;
        // Initialize input buffer with current frequency
        state.freq_input_len = (std.fmt.bufPrint(&state.freq_input_buf, "{d:.2}", .{state.frequency}) catch "").len;
    }

    if (state.freq_editing) {
        // Frequency input mode
        var input_str: [17:0]u8 = undefined;
        @memcpy(input_str[0..state.freq_input_len], state.freq_input_buf[0..state.freq_input_len]);
        input_str[state.freq_input_len] = 0;

        if (rg.textBox(freq_rect, &input_str, 16, true)) {
            // Parse and validate frequency
            if (std.fmt.parseFloat(f32, input_str[0..std.mem.len(@as([*:0]u8, &input_str))]) catch null) |new_freq| {
                if (new_freq >= limits.min and new_freq <= limits.max) {
                    state.frequency = new_freq;
                }
            }
            state.freq_editing = false;
        }
    } else {
        // Normal display
        const text_width = rl.measureText(freq_str, 48);
        rl.drawText(freq_str, @as(i32, @intFromFloat(w / 2)) - @divTrunc(text_width, 2), y_base + 20, 48, rl.Color.white);
    }
}

fn drawSignalMeter(state: *RadioState, w: f32) void {
    const y_base = 140;

    rl.drawText("Signal", 15, y_base, 14, rl.Color.light_gray);

    // Signal strength bar
    const bar_rect = rl.Rectangle{ .x = 60, .y = @floatFromInt(y_base - 2), .width = w - 80, .height = 20 };
    const signal_pct = if (state.is_powered) state.signal_strength else 0.0;

    // Background
    rl.drawRectangleRec(bar_rect, rl.Color{ .r = 40, .g = 42, .b = 45, .a = 255 });

    // Signal level
    var signal_color = rl.Color.red;
    if (signal_pct > 0.3) signal_color = rl.Color.yellow;
    if (signal_pct > 0.6) signal_color = rl.Color.green;

    rl.drawRectangle(@intFromFloat(bar_rect.x), @intFromFloat(bar_rect.y), @intFromFloat(bar_rect.width * signal_pct), @intFromFloat(bar_rect.height), signal_color);

    // Border
    rl.drawRectangleLinesEx(bar_rect, 1, rl.Color.dark_gray);

    // Signal strength text
    var sig_buf: [16]u8 = undefined;
    const sig_str = std.fmt.bufPrintZ(&sig_buf, "{d:.0}%", .{signal_pct * 100}) catch "0%";
    rl.drawText(sig_str, @intFromFloat(w - 50), y_base, 14, rl.Color.light_gray);
}

fn drawModeAndBandSelection(state: *RadioState, w: f32) void {
    const y_base = 170;

    // Mode selection
    rl.drawText("Mode", 15, y_base, 14, rl.Color.light_gray);
    var mode_index: c_int = @intFromEnum(state.mode);

    const mode_rect = rl.Rectangle{ .x = 60, .y = @floatFromInt(y_base - 2), .width = 160, .height = 25 };
    if (state.is_powered) {
        _ = rg.comboBox(mode_rect, "FM;AM;NFM;USB;LSB", &mode_index);
        if (mode_index != @intFromEnum(state.mode)) {
            state.mode = @enumFromInt(@as(u8, @intCast(mode_index)));
        }
    } else {
        rg.setState(@intFromEnum(rg.State.disabled));
        _ = rg.comboBox(mode_rect, "FM;AM;NFM;USB;LSB", &mode_index);
        rg.setState(@intFromEnum(rg.State.normal));
    }

    // Band selection
    rl.drawText("Band", 240, y_base, 14, rl.Color.light_gray);
    var band_index: c_int = @intFromEnum(state.band);

    const band_rect = rl.Rectangle{ .x = 280, .y = @floatFromInt(y_base - 2), .width = w - 290, .height = 25 };
    if (state.is_powered) {
        _ = rg.comboBox(band_rect, "FM US;FM Japan;Weather;AM MW;Free", &band_index);
        if (band_index != @intFromEnum(state.band)) {
            state.band = @enumFromInt(@as(u8, @intCast(band_index)));
            // Reset frequency to band minimum
            const limits = getBandLimits(state.band);
            state.frequency = limits.min;
        }
    } else {
        rg.setState(@intFromEnum(rg.State.disabled));
        _ = rg.comboBox(band_rect, "FM US;FM Japan;Weather;AM MW;Free", &band_index);
        rg.setState(@intFromEnum(rg.State.normal));
    }
}

fn drawTuningControls(state: *RadioState, w: f32) void {
    const y_base = 210;
    const button_width = (w - 40) / 6;

    // Fine tune buttons
    const tune_down_fine = rl.Rectangle{ .x = 10, .y = @floatFromInt(y_base), .width = button_width, .height = 35 };
    const tune_down = rl.Rectangle{ .x = 10 + button_width + 5, .y = @floatFromInt(y_base), .width = button_width, .height = 35 };
    const scan_down = rl.Rectangle{ .x = 10 + (button_width + 5) * 2, .y = @floatFromInt(y_base), .width = button_width, .height = 35 };
    const scan_up = rl.Rectangle{ .x = 10 + (button_width + 5) * 3, .y = @floatFromInt(y_base), .width = button_width, .height = 35 };
    const tune_up = rl.Rectangle{ .x = 10 + (button_width + 5) * 4, .y = @floatFromInt(y_base), .width = button_width, .height = 35 };
    const tune_up_fine = rl.Rectangle{ .x = 10 + (button_width + 5) * 5, .y = @floatFromInt(y_base), .width = button_width, .height = 35 };

    if (state.is_powered) {
        const limits = getBandLimits(state.band);

        if (rg.button(tune_down_fine, "<<")) {
            state.frequency -= limits.step;
            if (state.frequency < limits.min) state.frequency = limits.max;
            state.is_scanning = false;
        }

        if (rg.button(tune_down, "<")) {
            state.frequency -= limits.step * 10;
            if (state.frequency < limits.min) state.frequency = limits.max;
            state.is_scanning = false;
        }

        if (rg.button(scan_down, "SCAN-")) {
            state.is_scanning = true;
            state.frequency -= limits.step;
        }

        if (rg.button(scan_up, "SCAN+")) {
            state.is_scanning = true;
            state.frequency += limits.step;
        }

        if (rg.button(tune_up, ">")) {
            state.frequency += limits.step * 10;
            if (state.frequency > limits.max) state.frequency = limits.min;
            state.is_scanning = false;
        }

        if (rg.button(tune_up_fine, ">>")) {
            state.frequency += limits.step;
            if (state.frequency > limits.max) state.frequency = limits.min;
            state.is_scanning = false;
        }
    } else {
        // Disabled state
        rg.setState(@intFromEnum(rg.State.disabled));
        _ = rg.button(tune_down_fine, "<<");
        _ = rg.button(tune_down, "<");
        _ = rg.button(scan_down, "SCAN-");
        _ = rg.button(scan_up, "SCAN+");
        _ = rg.button(tune_up, ">");
        _ = rg.button(tune_up_fine, ">>");
        rg.setState(@intFromEnum(rg.State.normal));
    }

    // Scan indicator
    if (state.is_scanning) {
        rl.drawText("SCANNING...", @intFromFloat(w / 2 - 40), y_base + 40, 14, rl.Color.yellow);
    }
}

fn drawVolumeAndSquelch(state: *RadioState, w: f32) void {
    const y_base = 270;

    // Volume
    rl.drawText("Volume", 15, y_base, 14, rl.Color.light_gray);
    const vol_rect = rl.Rectangle{ .x = 70, .y = @floatFromInt(y_base - 2), .width = w - 140, .height = 20 };
    _ = rg.sliderBar(vol_rect, "", "", &state.volume, 0.0, 1.0);

    var vol_buf: [16]u8 = undefined;
    const vol_str = std.fmt.bufPrintZ(&vol_buf, "{d:.0}%", .{state.volume * 100}) catch "0%";
    rl.drawText(vol_str, @intFromFloat(w - 50), y_base, 14, rl.Color.light_gray);

    // Squelch
    rl.drawText("Squelch", 15, y_base + 30, 14, rl.Color.light_gray);
    const sq_rect = rl.Rectangle{ .x = 70, .y = @floatFromInt(y_base + 28), .width = w - 140, .height = 20 };
    _ = rg.sliderBar(sq_rect, "", "", &state.squelch, 0.0, 1.0);

    var sq_buf: [16]u8 = undefined;
    const sq_str = std.fmt.bufPrintZ(&sq_buf, "{d:.0}%", .{state.squelch * 100}) catch "0%";
    rl.drawText(sq_str, @intFromFloat(w - 50), y_base + 30, 14, rl.Color.light_gray);

    // Gain (for SDR control)
    rl.drawText("Gain", 15, y_base + 60, 14, rl.Color.light_gray);
    const gain_rect = rl.Rectangle{ .x = 70, .y = @floatFromInt(y_base + 58), .width = w - 140, .height = 20 };
    _ = rg.sliderBar(gain_rect, "", "", &state.gain, 0.0, 50.0);

    var gain_buf: [16]u8 = undefined;
    const gain_str = std.fmt.bufPrintZ(&gain_buf, "{d:.0} dB", .{state.gain}) catch "0 dB";
    rl.drawText(gain_str, @intFromFloat(w - 50), y_base + 60, 14, rl.Color.light_gray);
}

fn drawPresets(state: *RadioState, w: f32) void {
    const y_base = 370;

    rl.drawText("Presets", 15, y_base, 14, rl.Color.light_gray);
    rl.drawLine(10, y_base + 20, @intFromFloat(w - 10), y_base + 20, rl.Color.dark_gray);

    // Preset buttons (3 rows of 4)
    const button_width = (w - 50) / 4;
    const button_height: f32 = 35;

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const row = i / 4;
        const col = i % 4;

        const x = 10 + @as(f32, @floatFromInt(col)) * (button_width + 10);
        const y = @as(f32, @floatFromInt(y_base + 30)) + @as(f32, @floatFromInt(row)) * (button_height + 5);

        const preset_rect = rl.Rectangle{ .x = x, .y = y, .width = button_width, .height = button_height };

        if (state.presets[i].active) {
            // Active preset
            var label_buf: [64]u8 = undefined;

            // Find null terminator in name
            var name_len: usize = 0;
            for (state.presets[i].name) |c| {
                if (c == 0) break;
                name_len += 1;
            }

            const label = std.fmt.bufPrintZ(&label_buf, "{d:.1}\n{s}", .{ state.presets[i].frequency, state.presets[i].name[0..name_len] }) catch "Empty";

            const is_selected = state.selected_preset == i;
            if (is_selected) {
                rl.drawRectangleRec(preset_rect, rl.Color{ .r = 92, .g = 179, .b = 204, .a = 100 });
            }

            if (rg.button(preset_rect, label) and state.is_powered) {
                // Load preset
                state.frequency = state.presets[i].frequency;
                state.mode = state.presets[i].mode;
                state.band = state.presets[i].band;
                state.selected_preset = i;
                state.is_scanning = false;
            }
        } else {
            // Empty preset slot
            if (rg.button(preset_rect, "+") and state.is_powered) {
                // Save current station to preset
                // @memcpy(state.presets[i].name[0..11], "New Station\x00");
                // state.presets[i].frequency = state.frequency;
                // state.presets[i].mode = state.mode;
                // state.presets[i].band = state.band;
                // state.presets[i].active = true;
            }
        }
    }
}

fn drawBottomControls(state: *RadioState, w: f32) void {
    const y_base = 550;
    const button_width = (w - 40) / 3;

    // Record button
    const rec_rect = rl.Rectangle{ .x = 10, .y = @floatFromInt(y_base), .width = button_width, .height = 40 };
    if (state.is_powered) {
        const rec_label = if (state.is_recording) "STOP REC" else "RECORD";
        if (rg.button(rec_rect, rec_label)) {
            state.is_recording = !state.is_recording;
        }
    } else {
        rg.setState(@intFromEnum(rg.State.disabled));
        _ = rg.button(rec_rect, "RECORD");
        rg.setState(@intFromEnum(rg.State.normal));
    }

    // Stop scan button
    const stop_rect = rl.Rectangle{ .x = 15 + button_width, .y = @floatFromInt(y_base), .width = button_width, .height = 40 };
    if (state.is_powered and state.is_scanning) {
        if (rg.button(stop_rect, "STOP SCAN")) {
            state.is_scanning = false;
        }
    } else {
        rg.setState(@intFromEnum(rg.State.disabled));
        _ = rg.button(stop_rect, "STOP SCAN");
        rg.setState(@intFromEnum(rg.State.normal));
    }

    // Settings button (placeholder)
    const settings_rect = rl.Rectangle{ .x = 20 + button_width * 2, .y = @floatFromInt(y_base), .width = button_width, .height = 40 };
    if (rg.button(settings_rect, "SETTINGS")) {
        // TODO: Open settings dialog
    }

    // Status line
    if (state.is_powered) {
        var status_buf: [64]u8 = undefined;
        const limits = getBandLimits(state.band);
        const status = std.fmt.bufPrintZ(&status_buf, "Step: {d:.3} {s} | RTL-SDR: Connected", .{ limits.step, limits.unit }) catch "Status";
        rl.drawText(status, 10, y_base + 50, 12, rl.Color.light_gray);
    } else {
        rl.drawText("RTL-SDR: Disconnected", 10, y_base + 50, 12, rl.Color.dark_gray);
    }
}
