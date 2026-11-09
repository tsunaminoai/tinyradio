//! VFD-style drawing: a braille dot canvas, a 5x7 dot-matrix font, and a
//! phosphor palette.
//!
//! A braille cell is a 2x4 grid of dots, so each terminal cell can show 8
//! independently lit dots. A `Canvas` is a dot grid that is drawn into cells
//! at render time. Dot-matrix text is drawn into the canvas, and unlit dots in
//! each cell can show a dim ghost pattern, like the unlit segments of a VFD.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

pub const Palette = struct {
    /// Glass. Used as the background everywhere.
    pub const glass = vaxis.Color.rgbFromUint(0x08090a);
    /// Lit amber phosphor, for the frequency display and labels.
    pub const amber = vaxis.Color.rgbFromUint(0xffb000);
    /// Unlit amber, for ghost segments and secondary text.
    pub const amber_dim = vaxis.Color.rgbFromUint(0x3d2c00);
    /// Green phosphor, for the spectrum, meter, and status.
    pub const phosphor = vaxis.Color.rgbFromUint(0x5dffa6);
    /// Unlit green.
    pub const phosphor_dim = vaxis.Color.rgbFromUint(0x0f3322);
};

/// UTF-8 encodings of U+2800..U+28FF, built at compile time. Index is the dot mask.
const braille: [256][3]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256][3]u8 = undefined;
    for (0..256) |m| {
        const n = std.unicode.utf8Encode(@intCast(0x2800 + m), &t[m]) catch unreachable;
        std.debug.assert(n == 3);
    }
    break :blk t;
};

/// Bit for dot (x, y) within a braille cell, x in 0..1 and y in 0..3, using
/// braille's dot numbering.
fn dotBit(x: usize, y: usize) u8 {
    return switch (x) {
        0 => switch (y) {
            0 => 0x01,
            1 => 0x02,
            2 => 0x04,
            else => 0x40,
        },
        else => switch (y) {
            0 => 0x08,
            1 => 0x10,
            2 => 0x20,
            else => 0x80,
        },
    };
}

/// Dot pattern used for ghost cells: dots 1 and 4 at the top, so unlit
/// cells look like a faint speckled grid.
pub const ghost_mask: u8 = 0x09;

/// A dot grid that is drawn into terminal cells at render time.
pub const Canvas = struct {
    /// Width and height in dots. A terminal cell is 2 dots wide and 4 tall.
    w: usize,
    h: usize,
    dots: []bool,

    pub fn init(arena: std.mem.Allocator, w: usize, h: usize) !Canvas {
        const dots = try arena.alloc(bool, w * h);
        @memset(dots, false);
        return .{ .w = w, .h = h, .dots = dots };
    }

    pub fn cols(self: Canvas) usize {
        return (self.w + 1) / 2;
    }

    pub fn rows(self: Canvas) usize {
        return (self.h + 3) / 4;
    }

    pub fn set(self: Canvas, x: usize, y: usize) void {
        if (x < self.w and y < self.h) self.dots[y * self.w + x] = true;
    }

    pub fn fillRect(self: Canvas, x0: usize, y0: usize, w: usize, h: usize) void {
        for (y0..y0 + h) |y| {
            for (x0..x0 + w) |x| self.set(x, y);
        }
    }

    /// Width in dots of `text` at the given scale.
    pub fn textWidth(text: []const u8, scale: usize) usize {
        return text.len * glyph_advance * scale;
    }

    /// Draw `text` with the dot-matrix font. The top-left corner is (x0, y0),
    /// and `scale` is how many dots each font pixel covers.
    pub fn drawText(self: Canvas, text: []const u8, x0: usize, y0: usize, scale: usize) void {
        for (text, 0..) |ch, i| {
            const g = glyphFor(ch);
            for (0..glyph_h) |r| {
                for (0..glyph_w) |c| {
                    if (g[r][c] != '#') continue;
                    const gx = x0 + i * glyph_advance * scale + c * scale;
                    const gy = y0 + r * scale;
                    self.fillRect(gx, gy, scale, scale);
                }
            }
        }
    }

    /// Draw the canvas at (col0, row0). Lit dots use `lit`. Cells with no lit
    /// dots use `ghost` when it is non-null, and are left alone otherwise.
    pub fn render(self: Canvas, surf: vxfw.Surface, col0: u16, row0: u16, lit: vaxis.Style, ghost: ?vaxis.Style) void {
        for (0..self.rows()) |cr| {
            for (0..self.cols()) |cc| {
                var mask: u8 = 0;
                for (0..4) |dy| {
                    for (0..2) |dx| {
                        const x = cc * 2 + dx;
                        const y = cr * 4 + dy;
                        if (x < self.w and y < self.h and self.dots[y * self.w + x]) mask |= dotBit(dx, dy);
                    }
                }
                const col: u16 = col0 + @as(u16, @intCast(cc));
                const row: u16 = row0 + @as(u16, @intCast(cr));
                if (mask != 0) {
                    surf.writeCell(col, row, cell(mask, lit));
                } else if (ghost) |g| {
                    surf.writeCell(col, row, cell(ghost_mask, g));
                }
            }
        }
    }
};

/// Terminal cell showing braille pattern `mask`.
pub fn cell(mask: u8, style: vaxis.Style) vaxis.Cell {
    return .{
        .char = .{ .grapheme = braille[mask][0..], .width = 1 },
        .style = style,
    };
}

////////////////////////////////////////////////////////////////////////////////
// Dot-matrix font: 5x7 glyphs, '#' is a lit pixel
////////////////////////////////////////////////////////////////////////////////

const glyph_w = 5;
const glyph_h = 7;
/// Glyph width plus one pixel of spacing.
const glyph_advance = glyph_w + 1;

const Glyph = [glyph_h][]const u8;

const blank: Glyph = .{ "     ", "     ", "     ", "     ", "     ", "     ", "     " };

const digit_glyphs: [10]Glyph = .{
    .{ " ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### " }, // 0
    .{ "  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### " }, // 1
    .{ " ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####" }, // 2
    .{ "#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### " }, // 3
    .{ "   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # " }, // 4
    .{ "#####", "#    ", "#### ", "    #", "    #", "#   #", " ### " }, // 5
    .{ "  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### " }, // 6
    .{ "#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   " }, // 7
    .{ " ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### " }, // 8
    .{ " ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  " }, // 9
};

const dot_glyph: Glyph = .{ "     ", "     ", "     ", "     ", "     ", "  ## ", "  ## " };

fn glyphFor(ch: u8) Glyph {
    return switch (ch) {
        '0'...'9' => digit_glyphs[ch - '0'],
        '.' => dot_glyph,
        else => blank,
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "braille table encodes dot masks" {
    try std.testing.expectEqualStrings("\u{2800}", braille[0][0..]);
    try std.testing.expectEqualStrings("\u{28FF}", braille[255][0..]);
    try std.testing.expectEqualStrings("\u{2801}", braille[0x01][0..]);
}

test "dotBit covers all eight dots once" {
    var seen: u8 = 0;
    for (0..2) |x| {
        for (0..4) |y| {
            const b = dotBit(x, y);
            try std.testing.expect(seen & b == 0);
            seen |= b;
        }
    }
    try std.testing.expectEqual(@as(u8, 0xFF), seen);
}

test "Canvas text lights pixels in the expected cells" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const canvas = try Canvas.init(arena_state.allocator(), Canvas.textWidth("1", 1), 7);
    canvas.drawText("1", 0, 0, 1);
    // The '1' glyph's top row is "  #  ": pixel (2, 0) is lit.
    try std.testing.expect(canvas.dots[2]);
    try std.testing.expect(!canvas.dots[0]);
}
