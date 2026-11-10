//! RDS receiver front end, ported from LuaRadio's RDSReceiver (MIT,
//! github.com/vsergeev/luaradio, radio/composites/rdsreceiver.lua).
//!
//! The chain is a set of plain stage structs, each with a `process` function
//! over slices. That lets the chain run offline on a recording, and lets each
//! stage be checked on its own. Stage parameters match LuaRadio's example.

const std = @import("std");
const math = std.math;
const radio = @import("radio");
const dfir = @import("decimating_fir.zig");

const Complex = std.math.Complex(f32);
const Fir = dfir.DecimatingFIR;

/// Symbol rate of RDS data, in bits per second.
pub const bit_rate: f32 = 1187.5;

////////////////////////////////////////////////////////////////////////////////
// FM demodulation: phase difference between consecutive samples
////////////////////////////////////////////////////////////////////////////////

pub const FmDemod = struct {
    prev: Complex = .{ .re = 0, .im = 0 },
    /// Scale: out = arg(x * conj(prev)) / (2*pi*modulation_index).
    gain: f32 = 2.0 * math.pi * 1.25,

    pub fn process(self: *FmDemod, x: []const Complex, out: []f32) void {
        for (x, out) |s, *o| {
            const p = s.mul(conj(self.prev));
            o.* = math.atan2(p.im, p.re) / self.gain;
            self.prev = s;
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Hilbert transform: real part delayed, imaginary part the Hilbert FIR
////////////////////////////////////////////////////////////////////////////////

pub const hilbert_taps = 129;

pub const Hilbert = struct {
    /// Shared with the real-part delay: (taps - 1) / 2 samples.
    const delay_len = (hilbert_taps - 1) / 2;

    fir: Fir(hilbert_taps, 1, f32) = .{},
    delay: [delay_len]f32 = @splat(0),
    delay_pos: usize = 0,

    pub fn init() Hilbert {
        var h: Hilbert = .{};
        var taps: [hilbert_taps]f32 = undefined;
        for (&taps, 0..) |*t, n| {
            const shifted: f32 = @as(f32, @floatFromInt(n)) - @as(f32, delay_len);
            const odd = @mod(@as(i32, @intCast(n)) - delay_len, 2) != 0;
            const raw: f32 = if (odd) 2.0 / (shifted * math.pi) else 0;
            // Hamming window, as in LuaRadio's window_utils.
            const w = 0.54 - 0.46 * @cos(2.0 * math.pi * @as(f32, @floatFromInt(n)) / @as(f32, hilbert_taps - 1));
            t.* = raw * w;
        }
        h.fir.setTaps(&taps);
        return h;
    }

    pub fn process(self: *Hilbert, x: []const f32, out: []Complex) void {
        for (x, out) |s, *o| {
            // Real part: the input delayed by (taps - 1) / 2 samples.
            o.re = self.delay[self.delay_pos];
            self.delay[self.delay_pos] = s;
            self.delay_pos = (self.delay_pos + 1) % delay_len;
            // Imaginary part: the Hilbert FIR on the input.
            o.im = self.fir.step(.{ .re = s, .im = 0 }).?.re;
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Complex delay line
////////////////////////////////////////////////////////////////////////////////

pub fn ComplexDelay(comptime n: usize) type {
    return struct {
        const Self = @This();
        buf: [n]Complex = @splat(.{ .re = 0, .im = 0 }),
        pos: usize = 0,

        pub fn process(self: *Self, x: []const Complex, out: []Complex) void {
            for (x, out) |s, *o| {
                o.* = self.buf[self.pos];
                self.buf[self.pos] = s;
                self.pos = (self.pos + 1) % n;
            }
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Costas-style PLL, LuaRadio's PLLBlock
////////////////////////////////////////////////////////////////////////////////

pub const Pll = struct {
    loop_bw: f32,
    freq_min: f32,
    freq_max: f32,
    multiplier: f32,

    alpha: f32 = 0,
    beta: f32 = 0,
    phi_locked: f32 = 0,
    phi_multiplied: f32 = 0,
    freq_locked: f32 = 0,
    freq_min_rad: f32 = 0,
    freq_max_rad: f32 = 0,

    /// Frequencies are in Hz, and are converted to radians per sample here.
    pub fn init(rate: f32, loop_bandwidth: f32, freq_min: f32, freq_max: f32, multiplier: f32) Pll {
        var p: Pll = .{ .loop_bw = loop_bandwidth, .freq_min = freq_min, .freq_max = freq_max, .multiplier = multiplier };
        var bw = 2.0 * math.pi * (loop_bandwidth / rate);
        p.freq_min_rad = 2.0 * math.pi * (freq_min / rate);
        p.freq_max_rad = 2.0 * math.pi * (freq_max / rate);
        const damping: f32 = @sqrt(2.0) / 2.0;
        bw = bw / (damping + 1.0 / (4.0 * damping));
        const denom = 1.0 + 2.0 * damping * bw + bw * bw;
        p.alpha = (4.0 * damping * bw) / denom;
        p.beta = (4.0 * bw * bw) / denom;
        p.freq_locked = (p.freq_min_rad + p.freq_max_rad) / 2.0;
        return p;
    }

    /// `out` gets the VCO output at the multiplied phase. `err` gets the phase error.
    pub fn process(self: *Pll, x: []const Complex, out: []Complex, err: []f32) void {
        const two_pi = 2.0 * math.pi;
        for (x, out, err) |s, *o, *e| {
            const vco: Complex = .{ .re = @cos(self.phi_locked), .im = @sin(self.phi_locked) };
            o.* = .{ .re = @cos(self.phi_multiplied), .im = @sin(self.phi_multiplied) };

            // Phase detector.
            const pd = s.mul(conj(vco));
            e.* = math.atan2(pd.im, pd.re);

            // Loop filter.
            self.freq_locked += self.beta * e.*;
            self.phi_locked += self.freq_locked + self.alpha * e.*;
            self.phi_multiplied += self.freq_locked * self.multiplier + self.alpha * e.*;

            // Clamp frequency.
            if (self.freq_locked > self.freq_max_rad) self.freq_locked = self.freq_max_rad;
            if (self.freq_locked < self.freq_min_rad) self.freq_locked = self.freq_min_rad;

            // Wrap phases.
            if (self.phi_locked > two_pi) self.phi_locked -= two_pi;
            if (self.phi_locked < -two_pi) self.phi_locked += two_pi;
            if (self.phi_multiplied > two_pi) self.phi_multiplied -= two_pi;
            if (self.phi_multiplied < -two_pi) self.phi_multiplied += two_pi;
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Binary phase corrector: moving average of the BPSK phase, sampled every 32 samples
////////////////////////////////////////////////////////////////////////////////

pub fn BinaryPhaseCorrector(comptime num_samples: usize) type {
    return struct {
        const Self = @This();
        const interval = 32;

        phi_state: [num_samples]f32 = @splat(0),
        phi_pos: usize = 0,
        phi_avg: f32 = 0,
        sample_index: usize = 0,

        pub fn process(self: *Self, x: []const Complex, out: []Complex) void {
            for (x, out, 0..) |s, *o, i| {
                if (i == self.sample_index) {
                    var phi = math.atan2(s.im, s.re);
                    // Clamp the angle to the right half-plane.
                    if (phi < -math.pi / 2.0) phi += math.pi;
                    if (phi > math.pi / 2.0) phi -= math.pi;

                    // Replace the oldest phase with this one, and update the average.
                    const last = self.phi_state[self.phi_pos];
                    self.phi_state[self.phi_pos] = phi;
                    self.phi_pos = (self.phi_pos + 1) % num_samples;
                    self.phi_avg += phi / @as(f32, num_samples) - last / @as(f32, num_samples);

                    self.sample_index += interval;
                }
                // Rotate this sample by the averaged phase.
                const r: Complex = .{ .re = @cos(-self.phi_avg), .im = @sin(-self.phi_avg) };
                o.* = s.mul(r);
            }
            if (self.sample_index >= x.len) self.sample_index -= x.len;
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Root raised cosine taps, LuaRadio's fir_root_raised_cosine
////////////////////////////////////////////////////////////////////////////////

pub fn rrcTaps(comptime num_taps: usize, sample_rate: f32, beta: f32, symbol_rate: f32) [num_taps]f32 {
    var h: [num_taps]f32 = undefined;
    const symbol_period = 1.0 / symbol_rate;
    const center = (@as(f32, num_taps) - 1.0) / 2.0;
    for (&h, 0..) |*t, n| {
        const time = (@as(f32, @floatFromInt(n)) - center) / sample_rate;
        if (time == 0) {
            t.* = (1.0 / @sqrt(symbol_period)) * (1.0 - beta + 4.0 * beta / math.pi);
        } else if (@abs(time - symbol_period / (4.0 * beta)) < 1e-5 or @abs(time + symbol_period / (4.0 * beta)) < 1e-5) {
            t.* = (beta / @sqrt(2.0 * symbol_period)) * ((1.0 + 2.0 / math.pi) * @sin(math.pi / (4.0 * beta)) + (1.0 - 2.0 / math.pi) * @cos(math.pi / (4.0 * beta)));
        } else {
            const num = @cos((1.0 + beta) * math.pi * time / symbol_period) + @sin((1.0 - beta) * math.pi * time / symbol_period) / (4.0 * beta * time / symbol_period);
            const denom = 1.0 - (4.0 * beta * time / symbol_period) * (4.0 * beta * time / symbol_period);
            t.* = ((4.0 * beta) / (math.pi * @sqrt(symbol_period))) * num / denom;
        }
    }
    var scale: f32 = 0;
    for (h) |v| scale += v;
    for (&h) |*v| v.* /= scale;
    return h;
}

////////////////////////////////////////////////////////////////////////////////
// Zero-crossing clock recovery, LuaRadio's ZeroCrossingClockRecoveryBlock
////////////////////////////////////////////////////////////////////////////////

pub const ZeroCrossingClock = struct {
    symbol_period: f32,
    sample_offset: f32,
    hysteresis: bool = false,

    pub fn init(sample_rate: f32, baud: f32) ZeroCrossingClock {
        const sp = sample_rate / baud;
        return .{ .symbol_period = sp, .sample_offset = sp };
    }

    /// Output is +1 at each sampling instant, and -1 otherwise.
    pub fn process(self: *ZeroCrossingClock, x: []const f32, out: []f32) void {
        for (x, out) |v, *o| {
            // A zero crossing re-aligns the clock to half a symbol.
            if (!self.hysteresis and v > 0) {
                self.hysteresis = true;
                self.sample_offset = self.symbol_period / 2;
            } else if (self.hysteresis and v < 0) {
                self.hysteresis = false;
                self.sample_offset = self.symbol_period / 2;
            }
            self.sample_offset -= 1;
            if (self.sample_offset < 1) {
                o.* = 1;
                self.sample_offset += self.symbol_period;
            } else {
                o.* = -1;
            }
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Sampler: keeps the data sample at each rising clock edge
////////////////////////////////////////////////////////////////////////////////

pub const Sampler = struct {
    high: bool = false,

    /// Appends the samples taken into `out` and returns how many.
    pub fn process(self: *Sampler, data: []const Complex, clock: []const f32, out: []Complex) usize {
        var n: usize = 0;
        for (data, clock) |d, c| {
            if (!self.high and c > 0) {
                out[n] = d;
                n += 1;
                self.high = true;
            } else if (self.high and c < 0) {
                self.high = false;
            }
        }
        return n;
    }
};

////////////////////////////////////////////////////////////////////////////////
// Bit stages
////////////////////////////////////////////////////////////////////////////////

/// Manchester decoder, LuaRadio's ManchesterDecoderBlock (invert = false).
pub const Manchester = struct {
    prev: ?u1 = null,

    pub fn process(self: *Manchester, bits: []const u1, out: []u1) usize {
        var n: usize = 0;
        for (bits) |cur| {
            const p = self.prev orelse {
                self.prev = cur;
                continue;
            };
            if (p == 0 and cur == 1) {
                out[n] = 0;
                n += 1;
                self.prev = null;
            } else if (p == 1 and cur == 0) {
                out[n] = 1;
                n += 1;
                self.prev = null;
            } else {
                // Clock slip: start over from this bit.
                self.prev = cur;
            }
        }
        return n;
    }
};

/// Differential decoder, LuaRadio's DifferentialDecoderBlock (invert = false).
pub const DifferentialDecoder = struct {
    prev: u1 = 0,

    pub fn process(self: *DifferentialDecoder, bits: []const u1, out: []u1) void {
        for (bits, out) |cur, *o| {
            o.* = self.prev ^ cur;
            self.prev = cur;
        }
    }
};

fn conj(c: Complex) Complex {
    return .{ .re = c.re, .im = -c.im };
}

////////////////////////////////////////////////////////////////////////////////
// RDS framing, LuaRadio's RDSFramerBlock
////////////////////////////////////////////////////////////////////////////////

const frame_len = 104;
const block_len = 26;

/// Offset words that mark each block. C' is the version-B block C.
const offset_a: u32 = 0x0fc;
const offset_b: u32 = 0x198;
const offset_c: u32 = 0x168;
const offset_cp: u32 = 0x350;
const offset_d: u32 = 0x1b4;

/// Generator polynomial of the RDS checkword code (x^10 + x^8 + x^7 + x^5 + x^4 + x^3 + 1).
const generator: u32 = 0x5b9;

/// Syndrome of a single-bit error at each bit position: x^i mod g.
const syndrome_of_bit: [block_len]u32 = blk: {
    var t: [block_len]u32 = undefined;
    var r: u32 = 1;
    for (0..block_len) |i| {
        t[i] = r;
        r <<= 1;
        if (r & 0x400 != 0) r ^= generator;
    }
    break :blk t;
};

/// Syndrome of a 26-bit block, computed from its bits.
fn syndrome(word: u32) u32 {
    var s: u32 = 0;
    for (0..block_len) |i| {
        if ((word >> @intCast(i)) & 1 != 0) s ^= syndrome_of_bit[i];
    }
    return s;
}

/// Check one block against an offset word, correcting a single-bit error.
/// Returns the corrected 26-bit block, or null if it can't be corrected.
fn correctBlock(block: u32, offset: u32) ?u32 {
    const received = block ^ offset;
    const s = syndrome(received);
    if (s == 0) return block;
    for (0..block_len) |i| {
        if (syndrome_of_bit[i] == s) return block ^ (@as(u32, 1) << @intCast(i));
    }
    return null;
}

pub const Frame = [4]u16;

pub const Framer = struct {
    bits: [frame_len]u1 = @splat(0),
    filled: usize = 0,
    synchronized: bool = false,

    /// Feed bits, and write each frame that checks out into `frames`.
    /// Returns how many frames were written.
    pub fn process(self: *Framer, x: []const u1, frames: []Frame) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < x.len) {
            if (self.filled < frame_len) {
                const take = @min(frame_len - self.filled, x.len - i);
                @memcpy(self.bits[self.filled..][0..take], x[i..][0..take]);
                self.filled += take;
                i += take;
            } else {
                // Slide the window by one bit.
                std.mem.copyForwards(u1, self.bits[0 .. frame_len - 1], self.bits[1..frame_len]);
                self.bits[frame_len - 1] = x[i];
                i += 1;
            }

            if (self.filled == frame_len) {
                if (self.tryFrame()) |frame| {
                    frames[n] = frame;
                    n += 1;
                    self.synchronized = true;
                    self.filled = 0;
                } else {
                    self.synchronized = false;
                }
            }
        }
        return n;
    }

    fn tryFrame(self: *const Framer) ?Frame {
        var raw: [4]u32 = undefined;
        for (0..4) |b| {
            var word: u32 = 0;
            for (0..block_len) |k| {
                word = (word << 1) | self.bits[b * block_len + k];
            }
            raw[b] = word;
        }
        const a = correctBlock(raw[0], offset_a) orelse return null;
        const bb = correctBlock(raw[1], offset_b) orelse return null;
        const c = correctBlock(raw[2], offset_c) orelse correctBlock(raw[2], offset_cp) orelse return null;
        const d = correctBlock(raw[3], offset_d) orelse return null;
        return .{ @intCast(a >> 10), @intCast(bb >> 10), @intCast(c >> 10), @intCast(d >> 10) };
    }
};

////////////////////////////////////////////////////////////////////////////////
// RDS group decoding, LuaRadio's RDSDecoderBlock (PI, PS, radio text)
////////////////////////////////////////////////////////////////////////////////

pub const GroupDecoder = struct {
    pi_code: u16 = 0,
    ps: [8]u8 = @splat(' '),
    rt: [64]u8 = @splat(' '),

    pub fn decode(self: *GroupDecoder, f: Frame) void {
        self.pi_code = f[0];
        const group_code: u16 = f[1] >> 12;
        const version: u16 = (f[1] >> 11) & 0x1;
        switch (group_code) {
            0 => {
                // Program service name: two characters per group, at text address 0..3.
                const addr: usize = f[1] & 0x3;
                self.ps[addr * 2] = @truncate(f[3] >> 8);
                self.ps[addr * 2 + 1] = @truncate(f[3] & 0xff);
            },
            2 => {
                // Radio text: four characters per version-A group, two per version-B group.
                const addr: usize = f[1] & 0x0f;
                if (version == 0) {
                    const base = addr * 4;
                    if (base + 3 < self.rt.len) {
                        self.rt[base] = @truncate(f[2] >> 8);
                        self.rt[base + 1] = @truncate(f[2] & 0xff);
                        self.rt[base + 2] = @truncate(f[3] >> 8);
                        self.rt[base + 3] = @truncate(f[3] & 0xff);
                    }
                } else {
                    const base = addr * 2;
                    if (base + 1 < self.rt.len) {
                        self.rt[base] = @truncate(f[3] >> 8);
                        self.rt[base + 1] = @truncate(f[3] & 0xff);
                    }
                }
            },
            else => {},
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// The whole receiver as one sink block, fed from the tuner output
////////////////////////////////////////////////////////////////////////////////

/// What the receiver has decoded so far.
pub const RdsInfo = struct {
    pi: u16 = 0,
    ps: [8]u8 = @splat(' '),
    rt: [64]u8 = @splat(' '),
};

pub const RdsSink = struct {
    block: radio.Block,
    alloc: std.mem.Allocator,
    fmd: FmDemod = .{},
    hilbert: Hilbert,
    mdelay: ComplexDelay(129) = .{},
    pilot_fir: dfir.DecimatingFIR(129, 1, Complex),
    pll: Pll,
    bb_fir: dfir.DecimatingFIR(128, 1, f32),
    rrc_fir: dfir.DecimatingFIR(101, 1, f32),
    corr: BinaryPhaseCorrector(8000) = .{},
    zc: ZeroCrossingClock,
    sampler: Sampler = .{},
    manchester: Manchester = .{},
    diff: DifferentialDecoder = .{},
    framer: Framer = .{},
    group: GroupDecoder = .{},
    fs: f32,
    reset_pending: std.atomic.Value(bool) = .init(false),

    /// `fs` is the sample rate of the samples fed in (the tuner output).
    pub fn init(alloc: std.mem.Allocator, fs: f32) RdsSink {
        const nyq = fs / 2;
        const pilot_taps = radio.utils.filter.firwinComplexBandpass(129, .{ 18e3 / nyq, 20e3 / nyq }, .Hamming);
        const bb_taps = radio.utils.filter.firwinLowpass(128, 4e3 / nyq, .Hamming);
        const rrc = rrcTaps(101, fs, 1.0, bit_rate);
        var s: RdsSink = .{
            .block = radio.Block.init(RdsSink),
            .alloc = alloc,
            .hilbert = Hilbert.init(),
            .pilot_fir = .{},
            .pll = Pll.init(fs, 1500.0, 19e3 - 100, 19e3 + 100, 3.0),
            .bb_fir = .{},
            .rrc_fir = .{},
            .zc = ZeroCrossingClock.init(fs, bit_rate * 2),
            .fs = fs,
        };
        s.pilot_fir.setTaps(&pilot_taps);
        s.bb_fir.setTaps(&bb_taps);
        s.rrc_fir.setTaps(&rrc);
        return s;
    }

    /// Run the chain over one chunk of samples. Decoded groups update `info`.
    /// Forget everything decoded and reset the chain, e.g. after a retune.
    /// Called from the audio thread: `requestReset` is the thread-safe entry.
    pub fn requestReset(self: *RdsSink) void {
        self.reset_pending.store(true, .release);
    }

    fn resetState(self: *RdsSink) void {
        const block = self.block;
        self.* = RdsSink.init(self.alloc, self.fs);
        self.block = block;
    }

    pub fn process(self: *RdsSink, x: []const Complex) !radio.ProcessResult {
        if (self.reset_pending.swap(false, .acquire)) self.resetState();
        const n = x.len;
        const a = self.alloc;

        const mpx = try a.alloc(f32, n);
        defer a.free(mpx);
        self.fmd.process(x, mpx);

        const analytic = try a.alloc(Complex, n);
        defer a.free(analytic);
        self.hilbert.process(mpx, analytic);

        const delayed = try a.alloc(Complex, n);
        defer a.free(delayed);
        self.mdelay.process(analytic, delayed);

        const pilot = try a.alloc(Complex, n);
        defer a.free(pilot);
        _ = self.pilot_fir.process(analytic, pilot);

        const pll_out = try a.alloc(Complex, n);
        defer a.free(pll_out);
        const pll_err = try a.alloc(f32, n);
        defer a.free(pll_err);
        self.pll.process(pilot, pll_out, pll_err);

        const mixed = try a.alloc(Complex, n);
        defer a.free(mixed);
        for (mixed, delayed, pll_out) |*m, d, p| m.* = d.mul(.{ .re = p.re, .im = -p.im });

        const baseband = try a.alloc(Complex, n);
        defer a.free(baseband);
        _ = self.bb_fir.process(mixed, baseband);

        const shaped = try a.alloc(Complex, n);
        defer a.free(shaped);
        _ = self.rrc_fir.process(baseband, shaped);

        const corrected = try a.alloc(Complex, n);
        defer a.free(corrected);
        self.corr.process(shaped, corrected);

        const real_part = try a.alloc(f32, n);
        defer a.free(real_part);
        for (real_part, corrected) |*v, c| v.* = c.re;

        const clock = try a.alloc(f32, n);
        defer a.free(clock);
        self.zc.process(real_part, clock);

        const sampled = try a.alloc(Complex, n);
        defer a.free(sampled);
        const ns = self.sampler.process(corrected, clock, sampled);

        const raw_bits = try a.alloc(u1, ns);
        defer a.free(raw_bits);
        for (raw_bits, sampled[0..ns]) |*b, s| b.* = if (s.re > 0) 1 else 0;

        const manch = try a.alloc(u1, ns);
        defer a.free(manch);
        const nm = self.manchester.process(raw_bits, manch);

        const bits = try a.alloc(u1, nm);
        defer a.free(bits);
        self.diff.process(manch[0..nm], bits);

        const frames = try a.alloc(Frame, nm / 26 + 1);
        defer a.free(frames);
        const nframes = self.framer.process(bits, frames);
        for (frames[0..nframes]) |f| self.group.decode(f);

        return radio.ProcessResult.init(&[1]usize{n}, &[0]usize{});
    }

    pub fn info(self: *const RdsSink) RdsInfo {
        return .{ .pi = self.group.pi_code, .ps = self.group.ps, .rt = self.group.rt };
    }
};

test "RDS sink decodes the reference recording, in chunks" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var file = try std.Io.Dir.cwd().openFile(io, "test/rds/fm_rds_250k_1Msamples.iq", .{ .mode = .read_only });
    defer file.close(io);
    const n = (try file.stat(io)).size / @sizeOf(Complex);
    const iq = try alloc.alloc(Complex, n);
    defer alloc.free(iq);
    var rbuf: [4096]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    try reader.interface.readSliceAll(std.mem.sliceAsBytes(iq));

    var sink = RdsSink.init(alloc, 250e3);
    // Feed in uneven chunks, to exercise the state carried between calls.
    var pos: usize = 0;
    var size: usize = 1;
    while (pos < n) {
        const take = @min(size, n - pos);
        _ = try sink.process(iq[pos..][0..take]);
        pos += take;
        size = (size * 7 + 3) % 70_000 + 1;
    }

    const info = sink.info();
    try std.testing.expectEqual(@as(u16, 0x571d), info.pi);
    try std.testing.expectEqualStrings("Upli", info.ps[0..4]);
}
