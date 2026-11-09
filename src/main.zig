const std = @import("std");
const Allocator = std.mem.Allocator;
const tst = std.testing;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const fft_len = @import("spectrum.zig").fft_len;
const radio = @import("radio.zig");
const RadioBand = radio.Band;
const vfd = @import("vfd.zig");
const Palette = vfd.Palette;

/// Pilot level, in dBFS, above which the station is shown as stereo.
/// Set on air: the pilot's level depends on the station and the antenna.
const stereo_pilot_db: f32 = -45;

/// Redraw interval for the meters and spectrum, in milliseconds.
const refresh_ms: u32 = 50;

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var tty_buf: [4096]u8 = undefined;
    var app = try vxfw.App.init(init.io, allocator, init.environ_map, &tty_buf);
    defer app.deinit();

    // Create and initialize the radio tuner
    const tui = try allocator.create(RadioTuner);
    defer allocator.destroy(tui);

    tui.* = RadioTuner.init(init.io, allocator) catch |e| {
        std.debug.print("error: {}\n", .{e});
        return;
    };
    defer tui.deinit();
    tui.initWidgets();

    // Run the application
    try app.run(tui.widget(), .{});
}

// Radio station preset
const RadioPreset = struct {
    frequency: f32,
    name: []const u8,
    band: RadioBand,
};

/// Passed to each preset button, so a click loads the button's own preset.
const PresetRef = struct {
    tui: *RadioTuner,
    index: usize,
};

// Button styles: flat amber text, inverted on hover and focus.
const button_default: vaxis.Style = .{ .fg = Palette.amber, .bg = Palette.glass };
const button_active: vaxis.Style = .{ .fg = Palette.glass, .bg = Palette.amber, .bold = true };
const chip_default: vaxis.Style = .{ .fg = Palette.amber_dim, .bg = Palette.glass };

fn chipStyle(active: bool) vaxis.Style {
    return if (active) button_active else chip_default;
}

fn buttonWidgetStyle(active: bool) vaxis.Style {
    return if (active) button_active else button_default;
}

// Main application state
const RadioTuner = struct {
    current_band: RadioBand,
    frequency: f32,
    volume: u8,
    is_muted: bool,

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
    preset_refs: [6]PresetRef = undefined,
    current_preset: usize = 0,

    // Status
    status_text: []const u8 = "Setting up",

    //radio itself
    receiver: *radio.RadioReceiver,
    allocator: Allocator,

    const Self = @This();

    pub fn init(io: std.Io, alloc: Allocator) !Self {
        const r = try alloc.create(radio.RadioReceiver);
        errdefer alloc.destroy(r);
        r.* = try .init(alloc, io, false);
        errdefer r.deinit();

        const tui = Self{
            .allocator = alloc,
            .receiver = r,
            .current_band = .FM_Stereo,
            .frequency = RadioBand.FM_Stereo.getDefaultFreq(),
            .volume = 50,
            .is_muted = false,
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
                .label = "BAND",
                .onClick = bandToggleCallback,
                .userdata = null,
            },
            .volume_up_button = .{
                .label = "VOL +",
                .onClick = volumeUpCallback,
                .userdata = null,
            },
            .mute_button = .{
                .label = "MUTE",
                .onClick = muteCallback,
                .userdata = null,
            },
            .volume_down_button = .{
                .label = "VOL -",
                .onClick = volumeDownCallback,
                .userdata = null,
            },
            .presets = [_]RadioPreset{
                .{ .frequency = 91.9, .name = "Jeff 92", .band = .FM_Stereo },
                .{ .frequency = 105.9, .name = "WBAA Classical", .band = .FM_Stereo },
                .{ .frequency = 101.3, .name = "WBAA News", .band = .FM_Stereo },
                .{ .frequency = 98.7, .name = "WASK Classic Hits", .band = .FM_Stereo },
                .{ .frequency = 93.5, .name = "WKHY Rock", .band = .FM_Stereo },
                .{ .frequency = 95.3, .name = "WBPE Rock", .band = .FM_Stereo },
            },
            .preset_buttons = undefined, // Set up in initWidgets
            .status_text = "Ready",
        };

        return tui;
    }

    pub fn deinit(self: *Self) void {
        self.receiver.stop() catch |err| {
            std.debug.print("receiver.stop() failed: {s}\n", .{@errorName(err)});
        };
        self.receiver.deinit();
        self.allocator.destroy(self.receiver);
    }

    pub fn start(self: *Self) !void {
        try self.receiver.connect(self.current_band);
        try self.receiver.start();
        try self.receiver.setGain(@as(f32, @floatFromInt(self.volume)) / 100);
        self.setRxFrequency();
        self.status_text = "Playing";
    }

    /// Wire up the buttons. Call once, after the RadioTuner is at its final
    /// address, because the preset buttons point into it.
    pub fn initWidgets(self: *Self) void {
        for ([_]*vxfw.Button{
            &self.freq_up_button,
            &self.freq_down_button,
            &self.band_toggle_button,
            &self.volume_up_button,
            &self.volume_down_button,
            &self.mute_button,
        }) |b| {
            b.userdata = self;
            b.style = .{
                .default = button_default,
                .hover = button_active,
                .focus = button_active,
                .mouse_down = button_active,
            };
        }

        for (0..6) |i| {
            self.preset_refs[i] = .{ .tui = self, .index = i };
            self.preset_buttons[i] = .{
                .label = self.presets[i].name,
                .onClick = presetCallback,
                .userdata = &self.preset_refs[i],
                .style = .{
                    .default = chip_default,
                    .hover = button_active,
                    .focus = button_active,
                    .mouse_down = button_active,
                },
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
                try self.start();
                try ctx.tick(refresh_ms, self.widget());
            },
            .tick => {
                // Redraw the meters and spectrum, then schedule the next frame.
                try ctx.tick(refresh_ms, self.widget());
                return ctx.consumeAndRedraw();
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
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        const arena = ctx.arena;

        // The whole screen is one buffer filled with glass, so every cell
        // shows the same background.
        const buf = try arena.alloc(vaxis.Cell, @as(usize, size.width) * size.height);
        for (buf) |*c| c.* = .{ .style = .{ .bg = Palette.glass } };

        var root: vxfw.Surface = .{
            .size = size,
            .widget = self.widget(),
            .buffer = buf,
            .children = &.{},
        };
        var children = std.ArrayList(vxfw.SubSurface).empty;

        // Title, with the band and stereo state on the right.
        writeText(root, 4, 0, "TINYRADIO", .{ .fg = Palette.amber, .bg = Palette.glass, .bold = true });
        const stereo_on = self.receiver.pilotDb() > stereo_pilot_db;
        const band_tag = switch (self.current_band) {
            .AM => "AM",
            .FM => "FM",
            .FM_Stereo => "FM",
        };
        writeText(root, 52, 0, band_tag, .{ .fg = Palette.amber, .bg = Palette.glass, .bold = true });
        if (self.current_band == .FM_Stereo) {
            writeText(root, 56, 0, "STEREO", if (stereo_on)
                .{ .fg = Palette.phosphor, .bg = Palette.glass, .bold = true }
            else
                .{ .fg = Palette.amber_dim, .bg = Palette.glass });
        }
        writeRule(root, 1, size.width);

        // Frequency: a ghost of all segments, with the lit digits on top.
        const freq_text = try std.fmt.allocPrint(arena, "{d:.1}", .{self.frequency});
        const ghost_text = "8888888";
        const ghost = try vfd.Canvas.init(arena, vfd.Canvas.textWidth(ghost_text, 2), 14);
        ghost.drawText(ghost_text, 0, 0, 2);
        ghost.render(root, 4, 2, .{ .fg = Palette.amber_dim, .bg = Palette.glass }, null);

        const freq = try vfd.Canvas.init(arena, vfd.Canvas.textWidth(freq_text, 2), 14);
        freq.drawText(freq_text, 0, 0, 2);
        freq.render(root, 4, 2, .{ .fg = Palette.amber, .bg = Palette.glass, .bold = true }, null);

        const unit_col: u16 = 4 + @as(u16, @intCast(ghost.cols())) + 2;
        writeText(root, unit_col, 4, self.current_band.getUnit(), .{ .fg = Palette.amber, .bg = Palette.glass });

        // Signal and pilot meters.
        const sig_db = self.receiver.signalDb();
        try drawMeter(arena, root, 7, "SIG", normalize(sig_db, -60, 0), .{ .fg = Palette.phosphor, .bg = Palette.glass }, .{ .fg = Palette.phosphor_dim, .bg = Palette.glass });
        const sig_label = try std.fmt.allocPrint(arena, "{d:>6.1} dBFS", .{sig_db});
        writeText(root, 50, 7, sig_label, .{ .fg = Palette.phosphor, .bg = Palette.glass });

        const pilot_db = self.receiver.pilotDb();
        try drawMeter(arena, root, 8, "PLT", normalize(pilot_db, -70, -20), .{ .fg = Palette.amber, .bg = Palette.glass }, .{ .fg = Palette.amber_dim, .bg = Palette.glass });
        const pilot_label = try std.fmt.allocPrint(arena, "{d:>6.1} dBFS", .{pilot_db});
        writeText(root, 50, 8, pilot_label, .{ .fg = Palette.amber, .bg = Palette.glass });

        // Spectrum of the tuner output, one braille column per 2.7 bins.
        try self.drawSpectrum(arena, root, 10);
        writeText(root, 4, 14, "SPECTRUM", .{ .fg = Palette.amber_dim, .bg = Palette.glass });
        writeRule(root, 15, size.width);

        // Presets: six chips across.
        for (0..6) |i| {
            const label = try std.fmt.allocPrint(arena, "{d} {s}\n{d:.1} {s}", .{
                i + 1,
                self.presets[i].name[0..@min(self.presets[i].name.len, 9)],
                self.presets[i].frequency,
                self.presets[i].band.getUnit(),
            });
            // Draw the stored button, not a copy: the widget it returns points
            // back at the button for mouse events.
            const chip = &self.preset_buttons[i];
            chip.label = label;
            chip.style.default = chipStyle(self.current_preset == i);
            try children.append(arena, .{
                .origin = .{ .row = 17, .col = @as(u16, @intCast(2 + i * 13)) },
                .surface = try chip.draw(ctx.withConstraints(ctx.min, .{ .width = 12, .height = 2 })),
            });
        }

        // Controls.
        const controls = [_]*vxfw.Button{
            &self.freq_down_button,
            &self.freq_up_button,
            &self.band_toggle_button,
            &self.volume_down_button,
            &self.mute_button,
            &self.volume_up_button,
        };
        for (controls, 0..) |b, i| {
            try children.append(arena, .{
                .origin = .{ .row = 20, .col = @as(u16, @intCast(2 + i * 12)) },
                .surface = try b.draw(ctx.withConstraints(ctx.min, .{ .width = 11, .height = 1 })),
            });
        }

        // Status and volume. The dot is lit while playing.
        const status = try std.fmt.allocPrint(arena, "● {s}", .{self.status_text});
        writeText(root, 2, size.height -| 3, status, .{ .fg = Palette.phosphor, .bg = Palette.glass });

        const vol = if (self.is_muted)
            try std.fmt.allocPrint(arena, "VOL MUTE", .{})
        else
            try std.fmt.allocPrint(arena, "VOL {d:0>3}", .{self.volume});
        writeText(root, 60, size.height -| 3, vol, .{ .fg = Palette.amber, .bg = Palette.glass, .bold = true });

        // Help line, dimmed.
        const help_text = "↑/↓ tune   B band   M mute   +/- volume   1-6 presets   Q quit";
        writeText(root, 2, size.height -| 1, help_text, .{ .fg = Palette.amber_dim, .bg = Palette.glass });

        root.children = try children.toOwnedSlice(arena);
        return root;
    }

    fn drawSpectrum(self: *Self, arena: Allocator, root: vxfw.Surface, row: u16) !void {
        const cols = 48;
        const rows = 4;
        var bins: [fft_len]f32 = undefined;
        self.receiver.spectrum.read(&bins);

        const canvas = try vfd.Canvas.init(arena, cols * 2, rows * 4);
        const h = canvas.h;
        for (0..canvas.w) |x| {
            const lo = x * fft_len / canvas.w;
            const hi = @max(lo + 1, (x + 1) * fft_len / canvas.w);
            var peak: f32 = -200;
            for (bins[lo..hi]) |b| peak = @max(peak, b);
            const level: usize = @intFromFloat(normalize(peak, -90, -30) * @as(f32, @floatFromInt(h)));
            if (level > 0) canvas.fillRect(x, h - level, 1, level);
        }
        canvas.render(root, 4, row, .{ .fg = Palette.phosphor, .bg = Palette.glass }, .{ .fg = Palette.phosphor_dim, .bg = Palette.glass });
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
        self.status_text = "Tuned";
    }

    fn setRxFrequency(self: *Self) void {
        self.receiver.setFrequency(self.frequency) catch |e| {
            std.log.err("Could not set frequency: {}\n", .{e});
        };
    }

    fn toggleBand(self: *Self) void {
        self.current_band = switch (self.current_band) {
            .AM => .FM,
            .FM => .FM_Stereo,
            .FM_Stereo => .AM,
        };
        self.receiver.connect(self.current_band) catch |e| {
            self.status_text = @errorName(e);
            return;
        };
        self.frequency = self.current_band.getDefaultFreq();
        self.receiver.setFrequency(self.frequency) catch |e| {
            self.status_text = @errorName(e);
            return;
        };
        self.status_text = "Band changed";
    }

    fn adjustVolume(self: *Self, increase: bool) void {
        if (increase) {
            self.volume = @min(100, self.volume + 5);
        } else {
            self.volume = @max(0, self.volume - 5);
        }
        if (self.is_muted) {
            self.status_text = "Volume set (muted)";
            return;
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
            self.status_text = "Preset loaded";
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
            const ref: *PresetRef = @ptrCast(@alignCast(ptr));
            ref.tui.loadPreset(ref.index);
            return ctx.consumeAndRedraw();
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Drawing helpers
////////////////////////////////////////////////////////////////////////////////

/// Map `v` from [lo, hi] to [0, 1], clamped.
fn normalize(v: f32, lo: f32, hi: f32) f32 {
    return std.math.clamp((v - lo) / (hi - lo), 0.0, 1.0);
}

/// Write `text` one cell per codepoint. Clipped at the surface edge.
fn writeText(surf: vxfw.Surface, col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    const view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    var c = col;
    while (it.nextCodepointSlice()) |slice| {
        surf.writeCell(c, row, .{ .char = .{ .grapheme = slice, .width = 1 }, .style = style });
        c +|= 1;
    }
}

fn writeRule(surf: vxfw.Surface, row: u16, width: u16) void {
    for (0..width) |c| {
        surf.writeCell(@intCast(c), row, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = .{ .fg = Palette.amber_dim, .bg = Palette.glass },
        });
    }
}

/// One-row bar meter with a label on the left.
fn drawMeter(
    arena: Allocator,
    surf: vxfw.Surface,
    row: u16,
    label: []const u8,
    frac: f32,
    lit: vaxis.Style,
    ghost: vaxis.Style,
) !void {
    const cells = 40;
    const canvas = try vfd.Canvas.init(arena, cells * 2, 4);
    const filled: usize = @intFromFloat(frac * @as(f32, @floatFromInt(canvas.w)));
    canvas.fillRect(0, 0, filled, canvas.h);
    canvas.render(surf, 8, row, lit, ghost);
    writeText(surf, 4, row, label, .{ .fg = Palette.amber_dim, .bg = Palette.glass });
}

test {
    tst.refAllDecls(@This());
    _ = @import("vfd.zig");
}
