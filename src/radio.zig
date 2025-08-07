const std = @import("std");
const zigradio = @import("zigradio");
const rl = @import("raylib");

pub const RadioReceiver = struct {
    allocator: std.mem.Allocator,
    context: *zigradio.Context,
    source: ?*zigradio.RtlSdrSource,
    sink: ?*zigradio.PulseAudioSink,

    // FM demodulation chain
    fm_demod: ?*zigradio.FrequencyDiscriminator,
    fm_filter: ?*zigradio.LowpassFilter,

    pub fn init(allocator: std.mem.Allocator) !RadioReceiver {
        const context = try zigradio.Context.init(allocator);

        return RadioReceiver{
            .allocator = allocator,
            .context = context,
            .source = null,
            .sink = null,
            .fm_demod = null,
            .fm_filter = null,
        };
    }

    pub fn deinit(self: *RadioReceiver) void {
        if (self.source) |source| source.deinit();
        if (self.sink) |sink| sink.deinit();
        if (self.fm_demod) |demod| demod.deinit();
        if (self.fm_filter) |filter| filter.deinit();
        self.context.deinit();
    }

    pub fn connect(self: *RadioReceiver) !void {
        // Initialize RTL-SDR source
        self.source = try zigradio.RtlSdrSource.init(self.context, .{
            .frequency = 88.5e6, // 88.5 MHz
            .sample_rate = 2.4e6, // 2.4 MS/s
            .gain = 30.0,
        });

        // Initialize FM demodulator
        self.fm_demod = try zigradio.FrequencyDiscriminator.init(self.context, .{
            .sample_rate = 2.4e6,
            .max_deviation = 75e3, // 75 kHz for broadcast FM
        });

        // Lowpass filter for audio
        self.fm_filter = try zigradio.LowpassFilter.init(self.context, .{
            .sample_rate = 48000,
            .cutoff = 15000, // 15 kHz audio bandwidth
        });

        // Audio sink (use raylib audio stream instead)
        // We'll handle audio output through raylib

        // Connect the processing chain
        try self.source.?.connect(self.fm_demod.?);
        try self.fm_demod.?.connect(self.fm_filter.?);
    }

    pub fn setFrequency(self: *RadioReceiver, freq_mhz: f32) !void {
        if (self.source) |source| {
            try source.setFrequency(freq_mhz * 1e6);
        }
    }

    pub fn setGain(self: *RadioReceiver, gain_db: f32) !void {
        if (self.source) |source| {
            try source.setGain(gain_db);
        }
    }

    pub fn start(self: *RadioReceiver) !void {
        try self.context.start();
    }

    pub fn stop(self: *RadioReceiver) !void {
        try self.context.stop();
    }

    pub fn getAudioSamples(self: *RadioReceiver, buffer: []f32) !usize {
        // Get demodulated audio samples
        if (self.fm_filter) |filter| {
            return try filter.read(buffer);
        }
        return 0;
    }
};
