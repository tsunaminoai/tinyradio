//! Spectrum analyzer sink.
//!
//! Takes complex samples (the tuner output), runs a Hann-windowed radix-2 FFT
//! over each block of `fft_len` samples, and publishes the magnitudes in dB.
//! The UI reads them from another thread. Each bin is a separate atomic, so
//! readers never block the audio path and may see a mix of two frames. For a
//! display that is fine.
//!
//! The twiddle factors, bit-reversal table, and window are all built at
//! compile time.

const std = @import("std");
const radio = @import("radio");

const Complex = std.math.Complex(f32);

pub const fft_len = 256;

const twiddles = blk: {
    @setEvalBranchQuota(100_000);
    var t: [fft_len / 2]Complex = undefined;
    for (0..fft_len / 2) |k| {
        const angle = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / fft_len;
        t[k] = .{ .re = @floatCast(@cos(angle)), .im = @floatCast(@sin(angle)) };
    }
    break :blk t;
};

const bit_reverse = blk: {
    @setEvalBranchQuota(100_000);
    const bits = std.math.log2_int(usize, fft_len);
    var r: [fft_len]usize = undefined;
    for (0..fft_len) |i| {
        var x = i;
        var y: usize = 0;
        for (0..bits) |_| {
            y = (y << 1) | (x & 1);
            x >>= 1;
        }
        r[i] = y;
    }
    break :blk r;
};

const hann = blk: {
    @setEvalBranchQuota(100_000);
    var w: [fft_len]f32 = undefined;
    for (0..fft_len) |n| {
        const phase = 2.0 * std.math.pi * @as(f64, @floatFromInt(n)) / (fft_len - 1);
        w[n] = @floatCast(0.5 - 0.5 * @cos(phase));
    }
    break :blk w;
};

/// In-place iterative radix-2 decimation-in-time FFT.
fn fft(buf: *[fft_len]Complex) void {
    for (0..fft_len) |i| {
        const j = bit_reverse[i];
        if (i < j) std.mem.swap(Complex, &buf[i], &buf[j]);
    }

    var len: usize = 2;
    while (len <= fft_len) : (len *= 2) {
        const half = len / 2;
        const step = fft_len / len;
        var start: usize = 0;
        while (start < fft_len) : (start += len) {
            for (0..half) |k| {
                const w = twiddles[k * step];
                const t = w.mul(buf[start + k + half]);
                const u = buf[start + k];
                buf[start + k] = u.add(t);
                buf[start + k + half] = u.sub(t);
            }
        }
    }
}

fn emptyBins() [fft_len]std.atomic.Value(u32) {
    var bins: [fft_len]std.atomic.Value(u32) = undefined;
    for (&bins) |*b| b.* = .init(0);
    return bins;
}

pub const Spectrum = struct {
    block: radio.Block,
    fill: usize = 0,
    buf: [fft_len]Complex = @splat(.{ .re = 0, .im = 0 }),
    /// Latest bin magnitudes in dB, lowest frequency first (fftshifted). Bits
    /// of an f32, so each one can be stored atomically.
    db: [fft_len]std.atomic.Value(u32) = emptyBins(),

    pub fn init() Spectrum {
        return .{ .block = radio.Block.init(@This()) };
    }

    pub fn process(self: *Spectrum, x: []const Complex) !radio.ProcessResult {
        for (x) |s| {
            const w = hann[self.fill];
            self.buf[self.fill] = .{ .re = s.re * w, .im = s.im * w };
            self.fill += 1;
            if (self.fill == fft_len) {
                fft(&self.buf);
                self.publish();
                self.fill = 0;
            }
        }
        return radio.ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
    }

    fn publish(self: *Spectrum) void {
        const norm = @as(f32, fft_len) * @as(f32, fft_len);
        for (0..fft_len) |i| {
            // Shift so the DC bin sits in the middle of the display.
            const bin = self.buf[(i + fft_len / 2) % fft_len];
            const power = (bin.re * bin.re + bin.im * bin.im) / norm;
            const db: f32 = 10.0 * std.math.log10(power + 1e-12);
            self.db[i].store(@bitCast(db), .monotonic);
        }
    }

    /// Copy the latest spectrum (dB, lowest frequency first) into `out`.
    pub fn read(self: *const Spectrum, out: *[fft_len]f32) void {
        for (0..fft_len) |i| out[i] = @bitCast(self.db[i].load(.monotonic));
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "Spectrum puts a tone in the right bin" {
    var spec = Spectrum.init();

    // A complex tone at bin 64 of 256 (a quarter of the sample rate).
    var x: [fft_len]Complex = undefined;
    for (&x, 0..) |*s, n| {
        const phase = 2.0 * std.math.pi * 64.0 * @as(f32, @floatFromInt(n)) / @as(f32, fft_len);
        s.* = .{ .re = @cos(phase), .im = @sin(phase) };
    }
    _ = try spec.process(&x);

    var out: [fft_len]f32 = undefined;
    spec.read(&out);

    var peak: usize = 0;
    for (out, 0..) |v, i| {
        if (v > out[peak]) peak = i;
    }
    // After fftshift, bin 64 lands at (64 + 128) % 256 = 192.
    try std.testing.expectEqual(@as(usize, 192), peak);
}
