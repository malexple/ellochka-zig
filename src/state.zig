//! src/state.zig
//! Состояние интерпретатора языка Ellochka: таблицы переменных,
//! массивов, строк и режимов исполнения.

const std = @import("std");

/// Число простых переменных / массивов A-Z.
pub const NUM_LETTERS: usize = 26;
/// Максимальная длина динамической строковой переменной ($0-$9).
pub const MAX_DYNAMIC_STRING_LEN: usize = 1024;
/// Максимальное число элементов строкового массива ($A-$Z аналог).
pub const MAX_STATIC_STRINGS: usize = 850;
/// Фиксированная длина одного элемента строкового массива.
pub const STATIC_STRING_LEN: usize = 75;
/// Максимальный номер строки программы (адрес для GOTO).
pub const MAX_PROGRAM_LINES: usize = 1000;

/// Режим измерения углов для тригонометрических функций.
pub const AngleMode = enum { radians, degrees };

/// Направление оси ординат в графическом режиме.
pub const OrdinateDirection = enum { up, down };

/// Двумерный числовой массив: данные хранятся как плоский срез f32,
/// адрес элемента [row, col] = row * cols + col.
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

/// Динамическая строка переменной длины (используется для $0-$9).
pub const DynamicString = struct {
    data: []u8 = &[_]u8{},

    pub fn deinit(self: *DynamicString, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) allocator.free(self.data);
        self.* = .{};
    }

    pub fn set(self: *DynamicString, allocator: std.mem.Allocator, value: []const u8) !void {
        const capped_len = @min(value.len, MAX_DYNAMIC_STRING_LEN);
        if (self.data.len > 0) allocator.free(self.data);
        self.data = try allocator.alloc(u8, capped_len);
        @memcpy(self.data, value[0..capped_len]);
    }
};

/// Полное состояние интерпретатора на момент выполнения программы.
pub const InterpreterState = struct {
    allocator: std.mem.Allocator,

    /// 26 простых переменных A-Z.
    scalars: [NUM_LETTERS]f32 = [_]f32{0.0} ** NUM_LETTERS,

    /// 26 одномерных массивов A-Z (динамически выделяемые срезы).
    arrays1d: [NUM_LETTERS][]f32 = [_][]f32{&[_]f32{}} ** NUM_LETTERS,

    /// 26 двумерных массивов A-Z.
    arrays2d: [NUM_LETTERS]Array2D = [_]Array2D{.{}} ** NUM_LETTERS,

    /// 10 динамических строковых переменных $0-$9.
    dynamic_strings: [10]DynamicString = [_]DynamicString{.{}} ** 10,

    /// Строковый массив (аналог $A-$Z / индексных строк), до 850 элементов.
    /// Реальное число используемых элементов задаётся через SIZE.
    static_strings: [][STATIC_STRING_LEN]u8 = &[_][STATIC_STRING_LEN]u8{},
    static_strings_lens: []u8 = &[_]u8{},

    /// Текущий (единый для группы) размер одномерных массивов,
    /// обновляется при каждом успешном вызове SIZE [K]=... .
    /// Используется оператором CURR 1K.
    array1d_len: usize = 0,
    /// Текущее число строк двумерных массивов (CURR 2K).
    array2d_rows: usize = 0,
    /// Текущее число столбцов двумерных массивов (запасное поле,
    /// официальный help DIKAR v7 отдаёт CURR 3K под строковый массив,
    /// но столбцы храним отдельно на случай уточнения семантики).
    array2d_cols: usize = 0,

    /// Режимы вычисления.
    angle_mode: AngleMode = .radians,
    ordinate_direction: OrdinateDirection = .up,

    /// Счётчик текущей исполняемой строки (Program Counter).
    /// Используется как значение спецсимвола `@` в выражениях.
    program_counter: usize = 1,

    /// Флаг остановки программы (EXIT/STOP).
    should_exit: bool = false,

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

    /// Реализация оператора SIZE для одномерного массива.
    /// Уничтожает старые данные и выделяет новый чистый срез.
    /// Обновляет общий счётчик array1d_len для оператора CURR.
    pub fn sizeArray1D(self: *InterpreterState, letter_index: u8, new_len: usize) !void {
        var arr = &self.arrays1d[letter_index];
        if (arr.len > 0) self.allocator.free(arr.*);
        arr.* = try self.allocator.alloc(f32, new_len);
        @memset(arr.*, 0.0);
        self.array1d_len = new_len;
    }

    /// Реализация оператора SIZE для двумерного массива.
    /// Обновляет общие счётчики array2d_rows/array2d_cols для CURR.
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

    /// Реализация оператора SIZE для строкового массива.
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

    /// Реализация оператора UMEM: уничтожает все массивы указанной категории.
    /// category: 1 - все одномерные, 2 - все двумерные, 3 - строковый массив.
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

    /// Преобразование буквы A-Z (регистронезависимо) в индекс 0-25.
    pub fn letterIndex(ch: u8) ?u8 {
        if (ch >= 'A' and ch <= 'Z') return ch - 'A';
        if (ch >= 'a' and ch <= 'z') return ch - 'a';
        return null;
    }
};
