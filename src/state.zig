//! src/state.zig
//! Состояние интерпретатора языка Ellochka: таблицы переменных,
//! массивов, строк и режимов исполнения.

const std = @import("std");
const errors = @import("errors.zig");

pub const NUM_LETTERS: usize = 26;
pub const MAX_DYNAMIC_STRING_LEN: usize = 1024;
pub const MAX_STATIC_STRINGS: usize = 850;
/// Максимальное число Unicode code points в элементе строкового массива $$.
pub const STATIC_STRING_CODEPOINT_LIMIT: usize = 75;

/// Максимум UTF-8 байтов: каждый Unicode code point занимает до 4 байтов.
pub const STATIC_STRING_LEN: usize = STATIC_STRING_CODEPOINT_LIMIT * 4;
pub const MAX_PROGRAM_LINES: usize = 1000;

pub const AngleMode = enum { radians, degrees };
pub const OrdinateDirection = enum { up, down };

pub const Array2D = struct {
    data: []f32 = &[_]f32{},
    rows: usize = 0,
    cols: usize = 0,

    pub fn deinit(self: *Array2D, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) allocator.free(self.data);
        self.* = .{};
    }

    pub fn indexOf(self: Array2D, row: usize, col: usize) usize {
        return row * self.cols + col;
    }
};

pub const DynamicString = struct {
    data: []u8 = &[_]u8{},

    pub fn deinit(self: *DynamicString, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) allocator.free(self.data);
        self.* = .{};
    }

    pub fn set(self: *DynamicString, allocator: std.mem.Allocator, value: []const u8) !void {
        if (self.data.len > 0) allocator.free(self.data);
        self.data = try allocator.alloc(u8, value.len);
        @memcpy(self.data, value);
    }
};

/// Стандартная 16-цветная палитра VGA/EGA в формате Win32 COLORREF
/// (0x00BBGGRR). Используется как значение по умолчанию и для сброса
/// оператором CVET без аргументов.
pub const DEFAULT_PALETTE = [16]u32{
    0x00000000, // 0: чёрный
    0x00800000, // 1: синий
    0x00008000, // 2: зелёный
    0x00808000, // 3: голубой
    0x00000080, // 4: красный
    0x00800080, // 5: фиолетовый
    0x00008080, // 6: коричневый
    0x00C0C0C0, // 7: светло-серый
    0x00808080, // 8: тёмно-серый
    0x00FF0000, // 9: ярко-синий
    0x0000FF00, // 10: ярко-зелёный
    0x00FFFF00, // 11: ярко-голубой
    0x000000FF, // 12: ярко-красный
    0x00FF00FF, // 13: ярко-фиолетовый
    0x0000FFFF, // 14: жёлтый
    0x00FFFFFF, // 15: белый
};

pub const InterpreterState = struct {
    pub const ZeroDivMode = enum { err, nul, one };
    allocator: std.mem.Allocator,

    scalars: [NUM_LETTERS]f32 = [_]f32{0.0} ** NUM_LETTERS,
    arrays1d: [NUM_LETTERS][]f32 = [_][]f32{&[_]f32{}} ** NUM_LETTERS,
    arrays2d: [NUM_LETTERS]Array2D = [_]Array2D{.{}} ** NUM_LETTERS,
    dynamic_strings: [10]DynamicString = [_]DynamicString{.{}} ** 10,

    /// Каждый slot имеет 300 байт UTF-8, но логический предел — 75 code points.
    static_strings: [][STATIC_STRING_LEN]u8 = &[_][STATIC_STRING_LEN]u8{},

    /// Реальная длина строки в UTF-8 байтах, максимум 300.
    static_strings_lens: []u16 = &[_]u16{},

    array1d_len: usize = 0,
    array2d_rows: usize = 0,
    array2d_cols: usize = 0,

    angle_mode: AngleMode = .radians,
    ordinate_direction: OrdinateDirection = .up,
    zero_div_mode: ZeroDivMode = .err,

    program_counter: usize = 1,
    should_exit: bool = false,

    last_menu_selection: usize = 1,

    /// Палитра для графического режима (0x00BBGGRR), правится через CVET.
    palette: [16]u32 = DEFAULT_PALETTE,
    /// Текущий цвет (0-15), общий для текста (CSIM) и графики.
    current_color_index: u8 = 15,
    // Current text background colour, selected by CFON.
    current_background_color_index: u8 = 0,

    // Text cursor for the 80 x 30 GDI text grid.
    // text_col may become greater than 80 after LIST ending in '\\'.
    text_row: u8 = 1,
    text_col: usize = 1,
    /// Текущая точка для MOVE (в логических координатах Эллочки, до
    /// применения инверсии оси Y).
    graphics_cursor_x: f32 = 0.0,
    graphics_cursor_y: f32 = 0.0,


    // UI routing mode. The DIB may remain initialized while this is false:
    // graphics operators continue to draw into the hidden framebuffer.
    graphics_mode: bool = false,

    pub fn init(allocator: std.mem.Allocator) InterpreterState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InterpreterState) void {
        for (&self.arrays1d) |*arr| {
            if (arr.len > 0) self.allocator.free(arr.*);
        }
        for (&self.arrays2d) |*arr| {
            arr.deinit(self.allocator);
        }
        for (&self.dynamic_strings) |*s| {
            s.deinit(self.allocator);
        }
        if (self.static_strings.len > 0) {
            self.allocator.free(self.static_strings);
            self.allocator.free(self.static_strings_lens);
        }
    }

    pub const Utf8Char = struct {
        start: usize,
        end: usize,
        codepoint: u21,
    };

    /// Считает Unicode code points. Невалидный UTF-8 недопустим во внутренней
    /// строковой памяти интерпретатора.
    pub fn unicodeCodepointCount(bytes: []const u8) errors.EllochkaError!usize {
        return std.unicode.utf8CountCodepoints(bytes) catch
            errors.RuntimeError.InvalidUnicodeCodePoint;
    }

    /// Возвращает байтовый диапазон и Unicode-код N-го символа UTF-8 строки.
    /// Индексация Эллочки начинается с 1.
    pub fn utf8CharAt(
        bytes: []const u8,
        char_index: usize,
    ) errors.EllochkaError!Utf8Char {
        if (char_index == 0) return errors.RuntimeError.IndexOutOfBounds;

        const view = std.unicode.Utf8View.init(bytes) catch
            return errors.RuntimeError.InvalidUnicodeCodePoint;
        var iter = view.iterator();
        var current: usize = 1;

        while (iter.nextCodepointSlice()) |slice| {
            if (current == char_index) {
                const start = @intFromPtr(slice.ptr) - @intFromPtr(bytes.ptr);
                const codepoint = std.unicode.utf8Decode(slice) catch
                    return errors.RuntimeError.InvalidUnicodeCodePoint;

                return .{
                    .start = start,
                    .end = start + slice.len,
                    .codepoint = codepoint,
                };
            }
            current += 1;
        }

        return errors.RuntimeError.IndexOutOfBounds;
    }

    /// Добавляет один допустимый Unicode code point в UTF-8 буфер.
    pub fn appendUtf8Codepoint(
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        code: u32,
    ) errors.EllochkaError!void {
        if (code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF)) {
            return errors.RuntimeError.InvalidUnicodeCodePoint;
        }

        const point: u21 = @intCast(code);
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(point, &encoded) catch
            return errors.RuntimeError.InvalidUnicodeCodePoint;

        out.appendSlice(allocator, encoded[0..len]) catch
            return errors.RuntimeError.MemoryAllocationFailed;
    }

    /// Атомарно заменяет один Unicode code point в `$0..$9` или `$A..$Z`.
    /// При ошибке старая строка остаётся без изменений.
    pub fn writeUnicodeCodepoint(
        self: *InterpreterState,
        ch: u8,
        index1based: usize,
        code: u32,
    ) errors.EllochkaError!void {
        const old_bytes = try self.resolveStringBytes(ch);
        const target = try utf8CharAt(old_bytes, index1based);

        var replacement: std.ArrayListUnmanaged(u8) = .{};
        defer replacement.deinit(self.allocator);

        replacement.appendSlice(self.allocator, old_bytes[0..target.start]) catch
            return errors.RuntimeError.MemoryAllocationFailed;
        try appendUtf8Codepoint(self.allocator, &replacement, code);
        replacement.appendSlice(self.allocator, old_bytes[target.end..]) catch
            return errors.RuntimeError.MemoryAllocationFailed;

        if (ch >= '0' and ch <= '9') {
            if (replacement.items.len > MAX_DYNAMIC_STRING_LEN) {
                return errors.RuntimeError.StringTooLong;
            }
            self.dynamic_strings[ch - '0'].set(self.allocator, replacement.items) catch
                return errors.RuntimeError.MemoryAllocationFailed;
            return;
        }

        // setStaticString дополнительно проверит 75 code points и ёмкость.
    try self.setStaticString(ch, replacement.items);
    }

    pub fn sizeArray1D(self: *InterpreterState, letter_index: u8, new_len: usize) !void {
        var arr = &self.arrays1d[letter_index];
        if (arr.len > 0) self.allocator.free(arr.*);
        arr.* = try self.allocator.alloc(f32, new_len);
        @memset(arr.*, 0.0);
        self.array1d_len = new_len;
    }

    pub fn sizeArray2D(self: *InterpreterState, letter_index: u8, rows: usize, cols: usize) !void {
        var arr = &self.arrays2d[letter_index];
        arr.deinit(self.allocator);
        arr.data = try self.allocator.alloc(f32, rows * cols);
        arr.rows = rows;
        arr.cols = cols;
        @memset(arr.data, 0.0);
        self.array2d_rows = rows;
        self.array2d_cols = cols;
    }

    pub fn sizeStringArray(self: *InterpreterState, new_len: usize) !void {
        if (self.static_strings.len > 0) {
            self.allocator.free(self.static_strings);
            self.allocator.free(self.static_strings_lens);
        }
        self.static_strings = try self.allocator.alloc([STATIC_STRING_LEN]u8, new_len);
        self.static_strings_lens = try self.allocator.alloc(u16, new_len);
        for (self.static_strings) |*s| @memset(s, 0);
        @memset(self.static_strings_lens, 0);
    }

    pub fn umem(self: *InterpreterState, category: u8) void {
        switch (category) {
            1 => {
                for (&self.arrays1d) |*arr| {
                    if (arr.len > 0) self.allocator.free(arr.*);
                    arr.* = &[_]f32{};
                }
                self.array1d_len = 0;
            },
            2 => {
                for (&self.arrays2d) |*arr| {
                    arr.deinit(self.allocator);
                }
                self.array2d_rows = 0;
                self.array2d_cols = 0;
            },
            3 => {
                if (self.static_strings.len > 0) {
                    self.allocator.free(self.static_strings);
                    self.allocator.free(self.static_strings_lens);
                }
                self.static_strings = &[_][STATIC_STRING_LEN]u8{};
                self.static_strings_lens = &[_]u16{};
            },
            else => {},
        }
    }

    pub fn letterIndex(ch: u8) ?u8 {
        if (ch >= 'A' and ch <= 'Z') return ch - 'A';
        if (ch >= 'a' and ch <= 'z') return ch - 'a';
        return null;
    }

    pub fn resolveStringBytes(self: *InterpreterState, ch: u8) errors.EllochkaError![]const u8 {
        if (ch >= '0' and ch <= '9') {
            return self.dynamic_strings[ch - '0'].data;
        }
        const letter = letterIndex(ch) orelse return errors.ParseError.InvalidVariableName;
        if (self.static_strings.len == 0) return errors.RuntimeError.ArrayNotSized;
        const scalar_val = self.scalars[letter];
        if (std.math.isNan(scalar_val) or scalar_val < 1) return errors.RuntimeError.IndexOutOfBounds;
        const index: usize = @intFromFloat(scalar_val);
        if (index == 0 or index > self.static_strings.len) return errors.RuntimeError.IndexOutOfBounds;
        const slot = index - 1;
        return self.static_strings[slot][0..self.static_strings_lens[slot]];
    }

    pub fn setStaticString(
        self: *InterpreterState,
        ch: u8,
        value: []const u8,
    ) errors.EllochkaError!void {
        const letter = letterIndex(ch) orelse
            return errors.ParseError.InvalidVariableName;

        if (self.static_strings.len == 0) {
            return errors.RuntimeError.ArrayNotSized;
        }

        const scalar_value = self.scalars[letter];
        if (std.math.isNan(scalar_value) or scalar_value < 1) {
            return errors.RuntimeError.IndexOutOfBounds;
        }

        const index: usize = @intFromFloat(scalar_value);
        if (index == 0 or index > self.static_strings.len) {
            return errors.RuntimeError.IndexOutOfBounds;
        }

        const char_count = try unicodeCodepointCount(value);
        if (char_count > STATIC_STRING_CODEPOINT_LIMIT or value.len > STATIC_STRING_LEN) {
            return errors.RuntimeError.StringTooLong;
        }

        const slot = index - 1;
        @memcpy(self.static_strings[slot][0..value.len], value);
        self.static_strings_lens[slot] = @intCast(value.len);
    }

    pub fn setStaticStringByIndex(
        self: *InterpreterState,
        index1based: usize,
        value: []const u8,
    ) errors.EllochkaError!void {
        if (self.static_strings.len == 0) {
            return errors.RuntimeError.ArrayNotSized;
        }

        if (index1based == 0 or index1based > self.static_strings.len) {
            return errors.RuntimeError.IndexOutOfBounds;
        }

        const char_count = try unicodeCodepointCount(value);
        if (char_count > STATIC_STRING_CODEPOINT_LIMIT or value.len > STATIC_STRING_LEN) {
            return errors.RuntimeError.StringTooLong;
        }

        const slot = index1based - 1;
        @memcpy(self.static_strings[slot][0..value.len], value);
        self.static_strings_lens[slot] = @intCast(value.len);
    }

    /// Историческое имя сохранено для совместимости внутренних вызовов.
    /// Теперь индекс и значение имеют Unicode-семантику.
    pub fn writeCharCode(
        self: *InterpreterState,
        ch: u8,
        index1based: usize,
        value: u8,
    ) errors.EllochkaError!void {
        try self.writeUnicodeCodepoint(ch, index1based, value);
    }
};
