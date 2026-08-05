//! src/state.zig
//! Состояние интерпретатора языка Ellochka: таблицы переменных,
//! массивов, строк и режимов исполнения.

const std = @import("std");
const errors = @import("errors.zig");

pub const NUM_LETTERS: usize = 26;
pub const MAX_DYNAMIC_STRING_LEN: usize = 1024;
pub const MAX_STATIC_STRINGS: usize = 850;
pub const STATIC_STRING_LEN: usize = 75;
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

pub const InterpreterState = struct {
    allocator: std.mem.Allocator,

    scalars: [NUM_LETTERS]f32 = [_]f32{0.0} ** NUM_LETTERS,
    arrays1d: [NUM_LETTERS][]f32 = [_][]f32{&[_]f32{}} ** NUM_LETTERS,
    arrays2d: [NUM_LETTERS]Array2D = [_]Array2D{.{}} ** NUM_LETTERS,
    dynamic_strings: [10]DynamicString = [_]DynamicString{.{}} ** 10,

    static_strings: [][STATIC_STRING_LEN]u8 = &[_][STATIC_STRING_LEN]u8{},
    static_strings_lens: []u8 = &[_]u8{},

    array1d_len: usize = 0,
    array2d_rows: usize = 0,
    array2d_cols: usize = 0,

    angle_mode: AngleMode = .radians,
    ordinate_direction: OrdinateDirection = .up,

    program_counter: usize = 1,
    should_exit: bool = false,

    /// Индекс последнего выбранного элемента MENU (1-based), запоминается
    /// между вызовами MENU в рамках всей программы (см. спецификацию: "номер
    /// выбранного элемента запоминается и предлагается в следующих вызовах").
    last_menu_selection: usize = 1,

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
        self.static_strings_lens = try self.allocator.alloc(u8, new_len);
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
                self.static_strings_lens = &[_]u8{};
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

    pub fn setStaticString(self: *InterpreterState, ch: u8, value: []const u8) errors.EllochkaError!void {
        const letter = letterIndex(ch) orelse return errors.ParseError.InvalidVariableName;
        if (self.static_strings.len == 0) return errors.RuntimeError.ArrayNotSized;
        const scalar_val = self.scalars[letter];
        if (std.math.isNan(scalar_val) or scalar_val < 1) return errors.RuntimeError.IndexOutOfBounds;
        const index: usize = @intFromFloat(scalar_val);
        if (index == 0 or index > self.static_strings.len) return errors.RuntimeError.IndexOutOfBounds;
        if (value.len > STATIC_STRING_LEN) return errors.RuntimeError.StringTooLong;
        const slot = index - 1;
        @memcpy(self.static_strings[slot][0..value.len], value);
        self.static_strings_lens[slot] = @intCast(value.len);
    }

    pub fn setStaticStringByIndex(self: *InterpreterState, index_1based: usize, value: []const u8) errors.EllochkaError!void {
        if (self.static_strings.len == 0) return errors.RuntimeError.ArrayNotSized;
        if (index_1based == 0 or index_1based > self.static_strings.len) return errors.RuntimeError.IndexOutOfBounds;
        if (value.len > STATIC_STRING_LEN) return errors.RuntimeError.StringTooLong;
        const slot = index_1based - 1;
        @memcpy(self.static_strings[slot][0..value.len], value);
        self.static_strings_lens[slot] = @intCast(value.len);
    }

    pub fn writeCharCode(self: *InterpreterState, ch: u8, index_1based: usize, value: u8) errors.EllochkaError!void {
        if (ch >= '0' and ch <= '9') {
            const buf = self.dynamic_strings[ch - '0'].data;
            if (index_1based == 0 or index_1based > buf.len) return errors.RuntimeError.IndexOutOfBounds;
            buf[index_1based - 1] = value;
            return;
        }
        const letter = letterIndex(ch) orelse return errors.ParseError.InvalidVariableName;
        if (self.static_strings.len == 0) return errors.RuntimeError.ArrayNotSized;
        const scalar_val = self.scalars[letter];
        if (std.math.isNan(scalar_val) or scalar_val < 1) return errors.RuntimeError.IndexOutOfBounds;
        const sidx: usize = @intFromFloat(scalar_val);
        if (sidx == 0 or sidx > self.static_strings.len) return errors.RuntimeError.IndexOutOfBounds;
        const slot = sidx - 1;
        const len = self.static_strings_lens[slot];
        if (index_1based == 0 or index_1based > len) return errors.RuntimeError.IndexOutOfBounds;
        self.static_strings[slot][index_1based - 1] = value;
    }
};
