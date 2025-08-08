const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const radio = @import("radio.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    // Create and initialize the radio tuner
    const tui = try allocator.create(RadioTuner);
    defer allocator.destroy(tui);

    tui.* = RadioTuner.init(allocator) catch |e| {
        std.debug.print("error: {}\n", .{e});
        return;
    };
    defer tui.deinit();
    tui.initPresetButtons();

    // Run the application
    try app.run(tui.widget(), .{});
}

// Radio band definitions
const RadioBand = enum {
    AM,
    FM,

    pub fn getRange(self: RadioBand) struct { min: f32, max: f32 } {
        return switch (self) {
            .AM => .{ .min = 530.0, .max = 1710.0 }, // kHz
            .FM => .{ .min = 88.1, .max = 108.0 }, // MHz
        };
    }

    pub fn getDefaultFreq(self: RadioBand) f32 {
        return switch (self) {
            .AM => 920.0,
            .FM => 91.9,
        };
    }

    pub fn getStepSize(self: RadioBand) f32 {
        return switch (self) {
            .AM => 10.0, // 10 kHz steps
            .FM => 0.1, // 0.1 MHz steps
        };
    }

    pub fn getUnit(self: RadioBand) []const u8 {
        return switch (self) {
            .AM => "kHz",
            .FM => "MHz",
        };
    }
};

// Radio station preset
const RadioPreset = struct {
    frequency: f32,
    name: []const u8,
    band: RadioBand,
};

// Main application state
const RadioTuner = struct {
    current_band: RadioBand,
    frequency: f32,
    volume: u8,
    is_muted: bool,
    signal_strength: f32,

    // UI widgets
    freq_up_button: vxfw.Button,
    freq_down_button: vxfw.Button,
    band_toggle_button: vxfw.Button,
    volume_up_button: vxfw.Button,
    volume_down_button: vxfw.Button,
    mute_button: vxfw.Button,

    // Presets
    presets: [6]RadioPreset,
    preset_buttons: [6]vxfw.Button,

    // Status
    status_text: []const u8,

    //radio itself
    receiver: *radio.RadioReceiver,
    allocator: Allocator,

    const Self = @This();

    pub fn init(alloc: Allocator) !Self {
        const r = try alloc.create(radio.RadioReceiver);
        errdefer alloc.destroy(r);
        r.* = try .init(alloc, false);
        errdefer r.deinit();

        try r.connect();
        try r.start();

        var tui = Self{
            .allocator = alloc,
            .receiver = r,
            .current_band = .FM,
            .frequency = RadioBand.FM.getDefaultFreq(),
            .volume = 50,
            .is_muted = false,
            .signal_strength = 75, // Simulated signal strength
            .freq_up_button = .{
                .label = "FREQ +",
                .onClick = freqUpCallback,
                .userdata = null,
            },
            .freq_down_button = .{
                .label = "FREQ -",
                .onClick = freqDownCallback,
                .userdata = null,
            },
            .band_toggle_button = .{
                .label = "AM/FM",
                .onClick = bandToggleCallback,
                .userdata = null,
            },
            .volume_up_button = .{
                .label = "VOL +",
                .onClick = volumeUpCallback,
                .userdata = null,
            },
            .volume_down_button = .{
                .label = "VOL -",
                .onClick = volumeDownCallback,
                .userdata = null,
            },
            .mute_button = .{
                .label = "MUTE",
                .onClick = muteCallback,
                .userdata = null,
            },
            .presets = [_]RadioPreset{
                .{ .frequency = 91.9, .name = "Jeff 92", .band = .FM },
                .{ .frequency = 920.0, .name = "WBAA News", .band = .AM },
                .{ .frequency = 101.3, .name = "WBAA Jazz", .band = .FM },
                .{ .frequency = 98.7, .name = "WASK Classic Hits", .band = .FM },
                .{ .frequency = 93.5, .name = "KHY Rock", .band = .FM },
                .{ .frequency = 95.7, .name = "MeTV Music", .band = .FM },
            },
            .preset_buttons = undefined, // Will be initialized properly
            .status_text = "Ready",
        };
        try tui.receiver.setGain(@as(f32, @floatFromInt(tui.volume)) / 100);
        tui.setRxFrequency();
        tui.updateSignalStrength();
        return tui;
    }

    pub fn deinit(self: *Self) void {
        self.receiver.stop() catch unreachable;
        self.receiver.deinit();
        self.allocator.destroy(self.receiver);
    }

    pub fn initPresetButtons(self: *Self) void {
        for (0..6) |i| {
            self.preset_buttons[i] = .{
                .label = self.presets[i].name,
                .onClick = presetCallback,
                .userdata = @ptrFromInt(i), // Store preset index
            };
        }
    }

    pub fn widget(self: *Self) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Self.typeErasedEventHandler,
            .drawFn = Self.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                // Set initial focus to frequency up button
                return ctx.requestFocus(self.freq_up_button.widget());
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                } else if (key.matches('q', .{})) {
                    ctx.quit = true;
                    return;
                }

                // Keyboard shortcuts for radio control
                if (key.matches(vaxis.Key.up, .{})) {
                    self.adjustFrequency(true);
                    return ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.down, .{})) {
                    self.adjustFrequency(false);
                    return ctx.consumeAndRedraw();
                } else if (key.matches('b', .{})) {
                    self.toggleBand();
                    return ctx.consumeAndRedraw();
                } else if (key.matches('m', .{})) {
                    self.toggleMute();
                    return ctx.consumeAndRedraw();
                } else if (key.matches('+', .{}) or key.matches(vaxis.Key.right, .{})) {
                    self.adjustVolume(true);
                    return ctx.consumeAndRedraw();
                } else if (key.matches('-', .{}) or key.matches(vaxis.Key.left, .{})) {
                    self.adjustVolume(false);
                    return ctx.consumeAndRedraw();
                }

                // Preset shortcuts (1-6)
                if (key.codepoint >= '1' and key.codepoint <= '6') {
                    const preset_idx = key.codepoint - '1';
                    self.loadPreset(preset_idx);
                    return ctx.consumeAndRedraw();
                }
            },
            .focus_in => {
                return ctx.requestFocus(self.freq_up_button.widget());
            },
            else => {
                self.updateSignalStrength();
            },
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();

        // Update button userdata to point to self
        self.freq_up_button.userdata = self;
        self.freq_down_button.userdata = self;
        self.band_toggle_button.userdata = self;
        self.volume_up_button.userdata = self;
        self.volume_down_button.userdata = self;
        self.mute_button.userdata = self;

        for (0..6) |i| {
            self.preset_buttons[i].userdata = self;
        }

        // Create children surfaces
        var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        // Title
        const title_text = try std.fmt.allocPrint(ctx.arena, "═══ AM/FM RADIO TUNER ═══", .{});
        const title = vxfw.Text{ .text = title_text };
        try children.append(.{
            .origin = .{ .row = 1, .col = 2 },
            .surface = try title.draw(ctx),
        });

        // Current frequency display
        const freq_text = try std.fmt.allocPrint(ctx.arena, "Frequency: {d:.1} {s} [{s}]", .{
            self.frequency,
            self.current_band.getUnit(),
            @tagName(self.current_band),
        });
        const freq_display = vxfw.Text{ .text = freq_text };
        try children.append(.{
            .origin = .{ .row = 3, .col = 2 },
            .surface = try freq_display.draw(ctx),
        });

        // Signal strength meter
        const signal_bars = self.signal_strength * 10;
        var signal_display = try std.fmt.allocPrint(ctx.arena, "Signal: ", .{});
        for (0..10) |i| {
            signal_display = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{
                signal_display,
                if (i < @as(usize, @intFromFloat(signal_bars))) "█" else "░",
            });
        }
        signal_display = try std.fmt.allocPrint(ctx.arena, "{s} ({d:.1}%)", .{ signal_display, self.signal_strength * 100 });
        const signal_text = vxfw.Text{ .text = signal_display };
        try children.append(.{
            .origin = .{ .row = 4, .col = 2 },
            .surface = try signal_text.draw(ctx),
        });

        // Volume display
        const volume_text = try std.fmt.allocPrint(ctx.arena, "Volume: {d}% {s}", .{
            if (self.is_muted) 0 else self.volume,
            if (self.is_muted) "[MUTED]" else "",
        });
        const volume_display = vxfw.Text{ .text = volume_text };
        try children.append(.{
            .origin = .{ .row = 5, .col = 2 },
            .surface = try volume_display.draw(ctx),
        });

        // Control buttons row
        const button_width = 12;
        const button_height = 3;
        const button_spacing = 14;
        var col_offset: u16 = 2;

        // Frequency controls
        try children.append(.{
            .origin = .{ .row = 7, .col = col_offset },
            .surface = try self.freq_down_button.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = button_width, .height = button_height },
            )),
        });
        col_offset += button_spacing;

        try children.append(.{
            .origin = .{ .row = 7, .col = col_offset },
            .surface = try self.freq_up_button.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = button_width, .height = button_height },
            )),
        });
        col_offset += button_spacing;

        // Band toggle
        try children.append(.{
            .origin = .{ .row = 7, .col = col_offset },
            .surface = try self.band_toggle_button.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = button_width, .height = button_height },
            )),
        });
        col_offset += button_spacing;

        // Volume controls
        try children.append(.{
            .origin = .{ .row = 7, .col = col_offset },
            .surface = try self.volume_down_button.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = button_width, .height = button_height },
            )),
        });
        col_offset += button_spacing;

        try children.append(.{
            .origin = .{ .row = 7, .col = col_offset },
            .surface = try self.volume_up_button.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = button_width, .height = button_height },
            )),
        });

        // Mute button (new row)
        try children.append(.{
            .origin = .{ .row = 11, .col = 2 },
            .surface = try self.mute_button.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = button_width, .height = button_height },
            )),
        });

        // Presets section
        const presets_title = vxfw.Text{ .text = "Presets (Press 1-6):" };
        try children.append(.{
            .origin = .{ .row = 15, .col = 2 },
            .surface = try presets_title.draw(ctx),
        });

        // Preset buttons
        for (0..6) |i| {
            const preset_col = @as(u16, @intCast((i % 3) * 20 + 2));
            const preset_row = @as(u16, @intCast(17 + (i / 3) * 4));

            const preset_label = try std.fmt.allocPrint(ctx.arena, "{d}: {s}\n{d:.1} {s}", .{
                i + 1,
                self.presets[i].name,
                self.presets[i].frequency,
                self.presets[i].band.getUnit(),
            });

            // Create a button with the preset info
            var preset_button = self.preset_buttons[i];
            preset_button.label = preset_label;

            try children.append(.{
                .origin = .{ .row = preset_row, .col = preset_col },
                .surface = try preset_button.draw(ctx.withConstraints(
                    ctx.min,
                    .{ .width = 18, .height = 4 },
                )),
            });
        }

        // Status bar
        const status_display = try std.fmt.allocPrint(ctx.arena, "Status: {s}", .{self.status_text});
        const status = vxfw.Text{ .text = status_display };
        try children.append(.{
            .origin = .{ .row = @as(u16, @intCast(max_size.height - 2)), .col = 2 },
            .surface = try status.draw(ctx),
        });

        // Help text
        const help_text = "Controls: ↑/↓ Freq | B Band | M Mute | +/- Volume | 1-6 Presets | Q/Ctrl+C Quit";
        const help = vxfw.Text{ .text = help_text };
        try children.append(.{
            .origin = .{ .row = @as(u16, @intCast(max_size.height - 1)), .col = 2 },
            .surface = try help.draw(ctx),
        });

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = try children.toOwnedSlice(),
        };
    }

    // Radio control methods
    fn adjustFrequency(self: *Self, increase: bool) void {
        const range = self.current_band.getRange();
        const step = self.current_band.getStepSize();

        if (increase) {
            self.frequency = @min(range.max, self.frequency + step);
        } else {
            self.frequency = @max(range.min, self.frequency - step);
        }
        self.setRxFrequency();
        // Simulate signal strength based on frequency (for demo)
        self.updateSignalStrength();
        self.status_text = "Frequency changed";
    }

    fn setRxFrequency(self: *Self) void {
        self.receiver.setFrequency(self.frequency) catch |e| {
            std.log.err("Could not set frequency: {}\n", .{e});
        };
    }
    // TODO: Add AM chain
    fn toggleBand(self: *Self) void {
        self.current_band = switch (self.current_band) {
            .AM => .FM,
            .FM => .AM,
        };
        self.frequency = self.current_band.getDefaultFreq();
        self.updateSignalStrength();
        self.status_text = "Band changed (or did it? IMPLEMENT THIS)";
    }
    fn adjustVolume(self: *Self, increase: bool) void {
        if (increase) {
            self.volume = @min(100, self.volume + 5);
        } else {
            self.volume = @max(0, self.volume - 5);
        }
        self.receiver.setGain(@as(f32, @floatFromInt(self.volume)) / 100.0) catch |e| {
            self.status_text = @errorName(e);
            return;
        };
        self.status_text = "Volume adjusted";
    }

    fn toggleMute(self: *Self) void {
        if (self.is_muted) {
            self.receiver.setGain(@as(f32, @floatFromInt(self.volume)) / 100.0) catch unreachable;
        } else {
            self.receiver.setGain(0) catch unreachable;
        }

        self.is_muted = !self.is_muted;
        self.status_text = if (self.is_muted) "Muted" else "Unmuted";
    }

    fn loadPreset(self: *Self, index: usize) void {
        if (index < self.presets.len) {
            const preset = self.presets[index];
            self.current_band = preset.band;
            self.frequency = preset.frequency;
            self.receiver.setFrequency(self.frequency) catch |e| {
                std.log.err("Could not set frequency: {}\n", .{e});
            };
            self.updateSignalStrength();
            self.status_text = "Preset loaded";
        }
    }
    //TODO: Can this be accurate?
    fn updateSignalStrength(self: *Self) void {
        self.signal_strength = self.receiver.getPower();
    }

    // Button callbacks
    fn freqUpCallback(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        if (maybe_ptr) |ptr| {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.adjustFrequency(true);
            return ctx.consumeAndRedraw();
        }
    }

    fn freqDownCallback(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        if (maybe_ptr) |ptr| {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.adjustFrequency(false);
            return ctx.consumeAndRedraw();
        }
    }

    fn bandToggleCallback(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        if (maybe_ptr) |ptr| {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.toggleBand();
            return ctx.consumeAndRedraw();
        }
    }

    fn volumeUpCallback(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        if (maybe_ptr) |ptr| {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.adjustVolume(true);
            return ctx.consumeAndRedraw();
        }
    }

    fn volumeDownCallback(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        if (maybe_ptr) |ptr| {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.adjustVolume(false);
            return ctx.consumeAndRedraw();
        }
    }

    fn muteCallback(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        if (maybe_ptr) |ptr| {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.toggleMute();
            return ctx.consumeAndRedraw();
        }
    }

    fn presetCallback(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        if (maybe_ptr) |ptr| {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // In a real implementation, you'd need to determine which preset was clicked
            // For now, we'll just load preset 0 as an example
            self.loadPreset(0);
            return ctx.consumeAndRedraw();
        }
    }
};
