//! Pure tuning logic for seek and auto-save: stepping, lock detection, and
//! picking the strongest stations from a band scan.

const std = @import("std");

/// Signal level, in dBFS on the channel power meter, that counts as a lock.
/// Tune on air: stronger stations read higher.
pub const lock_db: f32 = -25;

/// Seek gives up after walking the whole band this many times over.
pub const max_seek_steps = 200;

/// Next frequency one step up or down, wrapping at the band edges.
pub fn nextFrequency(freq: f32, step: f32, up: bool, min: f32, max: f32) f32 {
    const next = if (up) freq + step else freq - step;
    if (next > max + step / 2) return min;
    if (next < min - step / 2) return max;
    return std.math.clamp(next, min, max);
}

/// True if a channel level counts as a station to stop on.
pub fn isLock(signal_db: f32) bool {
    return signal_db > lock_db;
}

/// Pick up to `out.len` stations from `levels`, one per channel step: the
/// local peaks above the noise floor, strongest first. The result is in
/// band order. Returns how many were written.
pub fn pickStations(levels: []const f32, out: []usize) usize {
    if (levels.len == 0 or out.len == 0) return 0;

    // Noise floor: median level. Stations must stand well above it.
    var sorted: [256]f32 = undefined;
    const n = @min(levels.len, sorted.len);
    @memcpy(sorted[0..n], levels[0..n]);
    std.mem.sort(f32, sorted[0..n], {}, std.sort.asc(f32));
    const floor = sorted[n / 2];
    const threshold = floor + 10;

    // Collect local peaks above threshold.
    var peaks: [256]usize = undefined;
    var peak_count: usize = 0;
    for (levels, 0..) |v, i| {
        if (v <= threshold) continue;
        const left_ok = i == 0 or v >= levels[i - 1];
        const right_ok = i + 1 == levels.len or v >= levels[i + 1];
        if (left_ok and right_ok) {
            peaks[peak_count] = i;
            peak_count += 1;
        }
    }

    // Keep the strongest `out.len` peaks.
    const keep = @min(peak_count, out.len);
    std.mem.sort(usize, peaks[0..peak_count], levels, struct {
        fn lessThan(lv: []const f32, a: usize, b: usize) bool {
            return lv[a] > lv[b];
        }
    }.lessThan);
    std.mem.sort(usize, peaks[0..keep], {}, std.sort.asc(usize));
    @memcpy(out[0..keep], peaks[0..keep]);
    return keep;
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "nextFrequency steps and wraps at the band edges" {
    try std.testing.expectApproxEqAbs(@as(f32, 88.2), nextFrequency(88.1, 0.1, true, 88.1, 108.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 108.0), nextFrequency(88.1, 0.1, false, 88.1, 108.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 88.1), nextFrequency(108.0, 0.1, true, 88.1, 108.0), 0.001);
}

test "isLock uses the threshold" {
    try std.testing.expect(isLock(-10));
    try std.testing.expect(!isLock(-40));
}

test "pickStations finds the strongest peaks in band order" {
    // Noise near -60 with three stations; a shoulder bin beside one station must not count twice.
    var levels: [40]f32 = @splat(-60);
    levels[5] = -20;
    levels[6] = -22; // shoulder of the first station
    levels[20] = -30;
    levels[33] = -15;
    var out: [2]usize = undefined;
    const n = pickStations(&levels, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    // The two strongest are index 33 (-15) and index 5 (-20), returned in band order.
    try std.testing.expectEqual(@as(usize, 5), out[0]);
    try std.testing.expectEqual(@as(usize, 33), out[1]);
}

test "pickStations returns nothing on a flat band" {
    const levels: [40]f32 = @splat(-60);
    var out: [6]usize = undefined;
    try std.testing.expectEqual(@as(usize, 0), pickStations(&levels, &out));
}

/// True when the reading before `prev1` was a peak: it rose above the lock
/// level, and the reading after it (`cur`) fell. A station's neighbour can
/// pass the lock level on the first step, so seek stops at the peak, not at
/// the first reading over the threshold.
pub fn isPeak(prev2: f32, prev1: f32, cur: f32) bool {
    return prev1 > lock_db and prev1 >= prev2 and prev1 > cur;
}

test "isPeak needs a rise above the lock level, then a fall" {
    try std.testing.expect(isPeak(-40, -10, -30));
    try std.testing.expect(!isPeak(-40, -10, -5)); // still rising
    try std.testing.expect(!isPeak(-40, -30, -35)); // below the lock level
    try std.testing.expect(!isPeak(-5, -10, -30)); // falling already
}
