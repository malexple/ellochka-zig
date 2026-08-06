const std = @import("std");
const lexer = @import("lexer.zig");
const errors = @import("errors.zig");
const state_mod = @import("state.zig");

pub const MAX_LINE_LEN: usize = 75;

/// Одна значимая инструкция программы: очищенный текст строки и
/// её физический номер (для GOTO по номеру строки).
pub const Instruction = struct {
    text: []const u8,
    line_number: usize, // 1..MAX_PROGRAM_LINES
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    /// Инструкции в порядке физических строк файла (индекс = line_number).
    /// Пустые/комментарийные/лейбл-строки хранятся как null.
    lines: std.ArrayListUnmanaged(?[]const u8) = .{},
    /// Отображение имени метки (без @, регистронезависимо в верхнем регистре)
    /// на номер строки, следующей за строкой метки.
    labels: std.StringHashMapUnmanaged(usize) = .{},
    owned_source: []u8,

    pub fn deinit(self: *Program) void {
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.labels.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.allocator.free(self.owned_source);
    }

    /// Загрузить программу из текста. Копирует source, чтобы срезы строк
    /// оставались валидными на весь срок жизни программы.
pub fn load(allocator: std.mem.Allocator, source: []const u8) !Program {
        const owned = try allocator.dupe(u8, source);

        var prog = Program{ .allocator = allocator, .owned_source = owned };
        errdefer prog.deinit();

        var line_number: usize = 1;
        var iter = std.mem.splitScalar(u8, owned, '\n');
        while (iter.next()) |raw_line| {
            const line = lexer.trimLine(raw_line);

            if (line.len == 0 or (lexer.isCommentLine(line) and !lexer.isMetaCommandLine(line))) {
                try prog.lines.append(allocator, null);
            } else if (lexer.isLabelLine(line)) {
                if (lineCharLen(line) > MAX_LINE_LEN) {
                    return errors.ParseError.LineTooLong;
                }
                const label_name_raw = line[1..];
                const upper = try allocator.alloc(u8, label_name_raw.len);
                for (label_name_raw, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
                try prog.labels.put(allocator, upper, line_number + 1);
                try prog.lines.append(allocator, null);
            } else {
                if (lineCharLen(line) > MAX_LINE_LEN) {
                    return errors.ParseError.LineTooLong;
                }
                try prog.lines.append(allocator, line);
            }

            line_number += 1;
            if (line_number > state_mod.MAX_PROGRAM_LINES) break;
        }

        return prog;
    }

    /// Получить текст исполняемой инструкции по номеру строки, либо null
    /// если строка пуста/комментарий/метка.
    pub fn getLine(self: *const Program, line_number: usize) ?[]const u8 {
        if (line_number == 0 or line_number > self.lines.items.len) return null;
        return self.lines.items[line_number - 1];
    }

    pub fn lineCount(self: *const Program) usize {
        return self.lines.items.len;
    }

    /// Найти номер строки по имени метки (без @).
    pub fn resolveLabel(self: *const Program, name: []const u8) ?usize {
        var buf: [64]u8 = undefined;
        if (name.len > buf.len) return null;
        for (name, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        return self.labels.get(buf[0..name.len]);
    }
};

/// Считает длину строки в Unicode-кодпоинтах (символах), а не в байтах,
/// как требует спецификация языка ("не более 75 символов"). Кириллица
/// в UTF-8 занимает 2 байта на символ, поэтому проверка по байтам
/// ошибочно бракует валидные строки с кириллицей. При невалидном UTF-8
/// (не должно происходить для .ela/.ell-файлов) откатываемся на длину
/// в байтах, чтобы не уронить загрузку программы по нашей же вине.
fn lineCharLen(line: []const u8) usize {
    return std.unicode.utf8CountCodepoints(line) catch line.len;
}