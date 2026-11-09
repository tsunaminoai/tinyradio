//! Preset slots and their plain-text file format.
//!
//! The file has one line per slot, in order: `BAND FREQ NAME`, or `-` for an
//! empty slot. For example:
//!
//!     FM_Stereo 91.9 Jeff 92
//!     -
//!
//! Names are copied into fixed buffers, so slots can be copied freely.

const std = @import("std");
const Band = @import("radio.zig").Band;

pub const slot_count = 6;
pub const max_name = 16;

pub const Slot = struct {
    frequency: f32 = 0,
    band: Band = .FM_Stereo,
    name_buf: [max_name]u8 = @splat(0),
    name_len: u8 = 0,

    pub fn name(self: *const Slot) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *Slot, text: []const u8) void {
        const n = @min(text.len, max_name);
        @memcpy(self.name_buf[0..n], text[0..n]);
        self.name_len = @intCast(n);
    }

    pub fn isEmpty(self: *const Slot) bool {
        return self.frequency == 0;
    }

    pub fn set(self: *Slot, frequency: f32, band: Band, text: []const u8) void {
        self.frequency = frequency;
        self.band = band;
        self.setName(text);
    }
};

/// Parse the file text into `slots`. Missing or malformed lines leave the slot empty.
pub fn parse(text: []const u8, slots: *[slot_count]Slot) void {
    // Start from empty slots, so any the file doesn't cover stay empty.
    slots.* = std.mem.zeroes([slot_count]Slot);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (slots) |*slot| {
        slot.* = .{};
        const line = std.mem.trim(u8, lines.next() orelse break, " \r");
        if (line.len == 0 or std.mem.eql(u8, line, "-")) continue;

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const band_text = fields.next() orelse continue;
        const freq_text = fields.next() orelse continue;
        const band = std.meta.stringToEnum(Band, band_text) orelse continue;
        const frequency = std.fmt.parseFloat(f32, freq_text) catch continue;
        // The name is whatever follows the frequency, spaces included.
        const rest = std.mem.trim(u8, fields.rest(), " ");
        slot.set(frequency, band, rest);
    }
}

/// Write `slots` as file text into `out`. Returns the number of bytes written.
/// `out` must be large enough: each slot takes at most 64 bytes.
pub fn format(slots: *const [slot_count]Slot, out: []u8) usize {
    var used: usize = 0;
    for (slots) |slot| {
        const line = if (slot.isEmpty())
            std.fmt.bufPrint(out[used..], "-\n", .{}) catch unreachable
        else
            std.fmt.bufPrint(out[used..], "{s} {d:.1} {s}\n", .{ @tagName(slot.band), slot.frequency, slot.name() }) catch unreachable;
        used += line.len;
    }
    return used;
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "presets round-trip through the file format" {
    var slots = std.mem.zeroes([slot_count]Slot);
    slots[0].set(91.9, .FM_Stereo, "Jeff 92");
    slots[2].set(1450.0, .AM, "WASK AM");
    slots[5].set(101.3, .FM_Stereo, "WBAA");

    var buf: [512]u8 = undefined;
    const n = format(&slots, &buf);

    var loaded: [slot_count]Slot = undefined;
    parse(buf[0..n], &loaded);

    try std.testing.expectEqualStrings("Jeff 92", loaded[0].name());
    try std.testing.expectApproxEqAbs(@as(f32, 91.9), loaded[0].frequency, 0.001);
    try std.testing.expectEqual(Band.AM, loaded[2].band);
    try std.testing.expect(loaded[1].isEmpty());
    try std.testing.expectEqualStrings("WBAA", loaded[5].name());
}

test "parse leaves missing and malformed lines empty" {
    var slots: [slot_count]Slot = undefined;
    parse("FM_Stereo 95.3 BOB\nnot a line\n", &slots);
    try std.testing.expectEqualStrings("BOB", slots[0].name());
    try std.testing.expect(slots[1].isEmpty());
    try std.testing.expect(slots[5].isEmpty());
}

test "names are clipped to the buffer" {
    var slot: Slot = .{};
    slot.setName("this name is far too long");
    try std.testing.expectEqual(@as(usize, max_name), slot.name().len);
}
