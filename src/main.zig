const std = @import("std");
const builtins = @import("builtin");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const radio = @import("radio.zig");
const RadioBand = radio.Band;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    // Create and initialize the radio tuner
    const tuner = try allocator.create(Application);
    defer allocator.destroy(tuner);

    tuner.* = Application.init(allocator) catch |e| {
        std.debug.print("error: {}\n", .{e});
        return e;
    };
    defer tuner.deinit();
    tuner.initPresetButtons();
    // var view = ViewModel.init(allocator, tuner);

    // Run the application
    try app.run(tuner.widget(), .{});
}

// Radio station preset
const RadioPreset = struct {
    frequency: f32,
    name: []const u8,
    band: RadioBand,
};

// Main application state
const Application = struct {
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
    current_preset: usize = 0,

    // Status
    status_text: []const u8 = "Setting up",

    //radio itself
    receiver: *radio.RadioReceiver,
    allocator: Allocator,
    view_model: ?ViewModel = null,

    const Self = @This();

    pub fn init(alloc: Allocator) !Self {
        const r = try alloc.create(radio.RadioReceiver);
        errdefer alloc.destroy(r);
        r.* = try .init(alloc, !builtins.strip_debug_info);
        errdefer r.deinit();

        const app = Self{
            .allocator = alloc,
            .receiver = r,
            .current_band = .FM,
            .frequency = RadioBand.FM.getDefaultFreq(),
            .volume = 50,
            .is_muted = false,
            .signal_strength = 75, // Simulated signal strength
            .freq_up_button = .{
                .label = "Freq +",
                .onClick = freqUpCallback,
                .userdata = null,
            },
            .freq_down_button = .{
                .label = "Freq -",
                .onClick = freqDownCallback,
                .userdata = null,
            },
            .band_toggle_button = .{
                .label = "AM/FM",
                .onClick = bandToggleCallback,
                .userdata = null,
            },
            .volume_up_button = .{
                .label = "Vol +",
                .onClick = volumeUpCallback,
                .userdata = null,
            },
            .mute_button = .{
                .label = "Mute",
                .onClick = muteCallback,
                .userdata = null,
            },
            .volume_down_button = .{
                .label = "Vol -",
                .onClick = volumeDownCallback,
                .userdata = null,
            },
            .presets = [_]RadioPreset{
                .{ .frequency = 91.9, .name = "Jeff 92", .band = .FM },
                .{ .frequency = 920.0, .name = "WBAA News", .band = .AM },
                .{ .frequency = 101.3, .name = "WBAA Jazz", .band = .FM },
                .{ .frequency = 98.7, .name = "WASK Classic Hits", .band = .FM },
                .{ .frequency = 93.5, .name = "KHY Rock", .band = .FM },
                .{ .frequency = 1450.0, .name = "WASK", .band = .AM },
            },
            .preset_buttons = undefined, // Will be initialized properly
            .status_text = "Ready",
        };

        return app;
    }

    pub fn deinit(self: *Self) void {
        self.receiver.stop() catch unreachable;
        self.receiver.deinit();
        self.allocator.destroy(self.receiver);
    }

    pub fn start(self: *Self) !void {
        self.receiver.connect(self.current_band) catch |e| {
            std.log.err("Error connecting reciever: {}", .{e});
            self.status_text = "Could not connect to reciever";
            return;
        };
        self.receiver.start() catch |e| {
            std.log.err("Error starting reciever: {}", .{e});
            self.status_text = "Could not start reciever";
            return;
        };
        try self.receiver.setGain(@as(f32, @floatFromInt(self.volume)) / 100);
        self.setRxFrequency();
        self.updateSignalStrength();
        self.status_text = "Playing";
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

    // Alternative widget using ViewModel - more efficient vaxis usage

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                try self.start();
                // Set initial focus to frequency up button
                // return ctx.requestFocus(self.freq_up_button.widget());
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
                // return ctx.requestFocus(self.freq_up_button.widget());
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
        self.signal_strength = self.receiver.getPower();

        for (0..6) |i| {
            self.preset_buttons[i].userdata = self;
        }

        // Create children surfaces
        var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        // title row
        const titleRow = vxfw.FlexRow{
            .children = &[_]vxfw.FlexItem{
                .{
                    .flex = 1,
                    .widget = (vxfw.Text{
                        .text = "TinyRadio",
                        .style = .{
                            .bold = true,
                        },
                        .text_align = .center,
                    }).widget(),
                },
            },
        };
        try children.append(.{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try titleRow.draw(ctx),
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
        const volume_text = try std.fmt.allocPrint(ctx.arena, "Volume: {d}% {s}", .{
            if (self.is_muted) 0 else self.volume,
            if (self.is_muted) "[MUTED]" else "",
        });

        const statusRow = vxfw.FlexRow{
            .children = &[_]vxfw.FlexItem{
                .{
                    .flex = 1,
                    .widget = (vxfw.Text{
                        .text = try std.fmt.allocPrint(ctx.arena, "Frequency: {d:.1} {s} [{s}]", .{
                            self.frequency,
                            self.current_band.getUnit(),
                            @tagName(self.current_band),
                        }),
                    }).widget(),
                },
                .{
                    .flex = 1,
                    .widget = (vxfw.Text{ .text = volume_text }).widget(),
                },
                .{
                    .flex = 1,
                    .widget = (vxfw.Text{
                        .text = signal_display,
                        .style = .{
                            .fg = vaxis.Color.rgbFromUint(0x00FF00),
                            .bg = vaxis.Color.rgbFromUint(0x0000FF),
                        },
                    }).widget(),
                },
            },
        };
        try children.append(.{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try titleRow.draw(ctx),
        });
        try children.append(.{
            .origin = .{ .row = 1, .col = 0 },
            .surface = try statusRow.draw(ctx),
        });

        const control_buttons = [_]*vxfw.Button{
            &self.freq_up_button,
            &self.freq_down_button,
            &self.band_toggle_button,
            &self.volume_up_button,
            &self.volume_down_button,
            &self.mute_button,
        };

        var flexbuttons = Array(vxfw.FlexItem).init(ctx.arena);
        for (&control_buttons) |button| {
            try flexbuttons.append(.{ .flex = 1, .widget = button.widget() });
        }
        const controlRow = vxfw.FlexRow{
            .children = flexbuttons.items,
        };
        try children.append(.{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try controlRow.draw(ctx),
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
            if (self.current_preset == i)
                preset_button.style.default = .{ .fg = .{ .rgb = [_]u8{ 0, 130, 200 } }, .reverse = true };

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
        self.receiver.connect(self.current_band) catch unreachable;
        self.frequency = self.current_band.getDefaultFreq();
        self.receiver.setFrequency(self.frequency) catch unreachable;
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
            self.current_preset = index;
            self.current_band = preset.band;
            self.frequency = preset.frequency;
            self.receiver.setFrequency(self.frequency) catch |e| {
                std.log.err("Could not set frequency: {}\n", .{e});
            };
            self.updateSignalStrength();
            self.status_text = "Preset loaded";
        }
    }
    fn updateSignalStrength(self: *Self) void {
        const raw_power = self.receiver.getPower();
        if (raw_power <= 0) {
            self.signal_strength = 0.0;
        } else {
            // Convert to dBFS
            const dbfs = 10.0 * std.math.log10(raw_power);
            // Normalize dBFS to 0-1 range (assuming -60dBFS to 0dBFS is useful range)
            const normalized = @max(0.0, @min(1.0, (dbfs + 60.0) / 60.0));
            self.signal_strength = normalized;
        }
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

const ViewModel = struct {
    tuner: *Application,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, tuner: *Application) Self {
        return .{
            .tuner = tuner,
            .allocator = allocator,
        };
    }

    pub fn createMainLayout(self: *Self, ctx: vxfw.DrawContext) !vxfw.Surface {
        // Update all button userdata
        self.updateButtonUserData();

        const layout = vxfw.FlexColumn{
            .children = &[_]vxfw.FlexItem{
                // Title
                .{ .flex = 0, .widget = self.titleWidget(ctx) },
                // Radio Info
                .{ .flex = 0, .widget = try self.infoWidget(ctx) },
                // Controls
                .{ .flex = 0, .widget = self.controlsWidget() },
                // Presets
                .{ .flex = 1, .widget = try self.presetsWidget(ctx) },
                // Status
                .{ .flex = 0, .widget = try self.statusWidget(ctx) },
            },
        };

        return try layout.draw(ctx);
    }

    fn updateButtonUserData(self: *Self) void {
        // Update all button userdata to point to tuner
        self.tuner.freq_up_button.userdata = self.tuner;
        self.tuner.freq_down_button.userdata = self.tuner;
        self.tuner.band_toggle_button.userdata = self.tuner;
        self.tuner.volume_up_button.userdata = self.tuner;
        self.tuner.volume_down_button.userdata = self.tuner;
        self.tuner.mute_button.userdata = self.tuner;

        for (0..6) |i| {
            self.tuner.preset_buttons[i].userdata = self.tuner;
        }
    }

    fn titleWidget(self: *Self, _: vxfw.DrawContext) vxfw.Widget {
        _ = self;
        return (vxfw.Text{
            .text = "═══ TinyRadio ═══",
            .style = .{ .bold = true },
            .text_align = .center,
        }).widget();
    }

    fn infoWidget(self: *Self, ctx: vxfw.DrawContext) !vxfw.Widget {
        const freq_text = try std.fmt.allocPrint(ctx.arena, "Frequency: {d:.1} {s} [{s}]", .{
            self.tuner.frequency,
            self.tuner.current_band.getUnit(),
            @tagName(self.tuner.current_band),
        });

        // Create signal meter
        const signal_bars = self.tuner.signal_strength * 10;
        var signal_display = try std.fmt.allocPrint(ctx.arena, "Signal: ", .{});
        for (0..10) |i| {
            signal_display = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{
                signal_display,
                if (i < @as(usize, @intFromFloat(signal_bars))) "█" else "░",
            });
        }
        signal_display = try std.fmt.allocPrint(ctx.arena, "{s} ({d:.1}%)", .{ signal_display, self.tuner.signal_strength * 100 });

        const volume_text = try std.fmt.allocPrint(ctx.arena, "Volume: {d}% {s}", .{
            if (self.tuner.is_muted) 0 else self.tuner.volume,
            if (self.tuner.is_muted) "[MUTED]" else "",
        });

        const info_layout = vxfw.FlexColumn{
            .children = &[_]vxfw.FlexItem{
                .{ .flex = 0, .widget = (vxfw.Text{ .text = freq_text }).widget() },
                .{ .flex = 0, .widget = (vxfw.Text{
                    .text = signal_display,
                    .style = .{ .fg = vaxis.Color.rgbFromSpec("00FF00") catch .default },
                }).widget() },
                .{ .flex = 0, .widget = (vxfw.Text{ .text = volume_text }).widget() },
            },
        };

        return info_layout.widget();
    }

    fn controlsWidget(self: *Self) vxfw.Widget {
        const controls_layout = vxfw.FlexColumn{
            .children = &[_]vxfw.FlexItem{
                // Frequency and band controls
                .{
                    .flex = 0,
                    .widget = (vxfw.FlexRow{
                        .children = &[_]vxfw.FlexItem{
                            .{ .flex = 1, .widget = self.tuner.freq_down_button.widget() },
                            .{ .flex = 1, .widget = self.tuner.freq_up_button.widget() },
                            .{ .flex = 1, .widget = self.tuner.band_toggle_button.widget() },
                        },
                    }).widget(),
                },
                // Volume controls
                .{
                    .flex = 0,
                    .widget = (vxfw.FlexRow{
                        .children = &[_]vxfw.FlexItem{
                            .{ .flex = 1, .widget = self.tuner.volume_down_button.widget() },
                            .{ .flex = 1, .widget = self.tuner.mute_button.widget() },
                            .{ .flex = 1, .widget = self.tuner.volume_up_button.widget() },
                        },
                    }).widget(),
                },
            },
        };

        return controls_layout.widget();
    }

    fn presetsWidget(self: *Self, ctx: vxfw.DrawContext) !vxfw.Widget {
        // Update preset buttons with current state
        for (0..6) |i| {
            self.tuner.preset_buttons[i].label = try std.fmt.allocPrint(ctx.arena, "{d}: {s}\n{d:.1} {s}", .{
                i + 1,
                self.tuner.presets[i].name,
                self.tuner.presets[i].frequency,
                self.tuner.presets[i].band.getUnit(),
            });

            if (self.tuner.current_preset == i) {
                self.tuner.preset_buttons[i].style.default = .{ .fg = .{ .rgb = [_]u8{ 0, 130, 200 } }, .reverse = true };
            } else {
                self.tuner.preset_buttons[i].style.default = .{};
            }
        }

        const presets_layout = vxfw.FlexColumn{
            .children = &[_]vxfw.FlexItem{
                .{ .flex = 0, .widget = (vxfw.Text{ .text = "Presets (Press 1-6):" }).widget() },
                // First row (presets 1-3)
                .{
                    .flex = 0,
                    .widget = (vxfw.FlexRow{
                        .children = &[_]vxfw.FlexItem{
                            .{ .flex = 1, .widget = self.tuner.preset_buttons[0].widget() },
                            .{ .flex = 1, .widget = self.tuner.preset_buttons[1].widget() },
                            .{ .flex = 1, .widget = self.tuner.preset_buttons[2].widget() },
                        },
                    }).widget(),
                },
                // Second row (presets 4-6)
                .{
                    .flex = 0,
                    .widget = (vxfw.FlexRow{
                        .children = &[_]vxfw.FlexItem{
                            .{ .flex = 1, .widget = self.tuner.preset_buttons[3].widget() },
                            .{ .flex = 1, .widget = self.tuner.preset_buttons[4].widget() },
                            .{ .flex = 1, .widget = self.tuner.preset_buttons[5].widget() },
                        },
                    }).widget(),
                },
            },
        };

        return presets_layout.widget();
    }

    fn statusWidget(self: *Self, ctx: vxfw.DrawContext) !vxfw.Widget {
        const status_text = try std.fmt.allocPrint(ctx.arena, "Status: {s}", .{self.tuner.status_text});
        const help_text = "Controls: ↑/↓ Freq | B Band | M Mute | +/- Volume | 1-6 Presets | Q/Ctrl+C Quit";

        const status_layout = vxfw.FlexColumn{
            .children = &[_]vxfw.FlexItem{
                .{ .flex = 0, .widget = (vxfw.Text{ .text = status_text }).widget() },
                .{ .flex = 0, .widget = (vxfw.Text{ .text = help_text }).widget() },
            },
        };

        return status_layout.widget();
    }
    pub fn widget(self: *Self) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = null,
            .drawFn = Self.typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();

        // Update signal strength from receiver
        const raw_power = self.tuner.receiver.getPower();
        if (raw_power <= 0) {
            self.tuner.signal_strength = 0.0;
        } else {
            const dbfs = 10.0 * std.math.log10(raw_power);
            const normalized = @max(0.0, @min(1.0, (dbfs + 60.0) / 60.0));
            self.tuner.signal_strength = normalized;
        }
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try self.createMainLayout(ctx),
        };

        // Initialize or get ViewModel

        // Use ViewModel to create the layout and return the surface directly
        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};
