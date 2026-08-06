//! src/lexer.zig
//! Построчный лексер языка Ellochka.
//! Каждая строка программы разбирается независимо: комментарии (!)
//! и метки (@name) отбрасываются до вызова токенайзера, здесь же
//! разбирается содержимое одного оператора на токены.

const std = @import("std");
const errors = @import("errors.zig");

pub const TokenType = enum {
    identifier, // буквенные последовательности: имена операторов, переменных
    number, // числовая константа (в т.ч. с плавающей точкой и экспонентой)
    string_literal, // 'текст в апострофах'
    dollar, // $
    ampersand, // &  (префикс математических функций)
    percent, // %   (префикс строковых функций)
    lbracket, // [
    rbracket, // ]
    lparen, // (
    rparen, // )
    lbrace, // {
    rbrace, // }
    comma, // ,
    semicolon, // ;
    colon, // :
    hash, // #
    at, // @
    question, // ?
    equals, // =
    plus, // +
    minus, // -
    star, // *
    slash, // /
    caret, // ^
    backslash, // \
    gt_gt, // >>
    lt_lt, // <<
    gt_eq, // >=
    lt_eq, // <=
    eq_eq, // ==
    pipe_eq, // |=
    star_star, // ** (диапазонное условие)
    eof,
};

pub const Token = struct {
    kind: TokenType,
    text: []const u8, // срез на исходную строку (без копирования)
    pos: usize, // позиция начала токена в строке (для диагностики)
};

pub const Lexer = struct {
    line: []const u8,
    pos: usize = 0,

    pub fn init(line: []const u8) Lexer {
        return .{ .line = line, .pos = 0 };
    }

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.line.len) return null;
        return self.line[self.pos];
    }

    fn peekAt(self: *Lexer, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.line.len) return null;
        return self.line[idx];
    }

    fn advance(self: *Lexer) void {
        self.pos += 1;
    }

    fn skipSpaces(self: *Lexer) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t') {
                self.advance();
            } else break;
        }
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
    }

    fn isAlnum(c: u8) bool {
        return isAlpha(c) or isDigit(c);
    }

    /// Получить следующий токен строки. Возвращает TokenType.eof
    /// после достижения конца строки.
    pub fn next(self: *Lexer) errors.ParseError!Token {
        self.skipSpaces();
        const start = self.pos;
        const c = self.peek() orelse {
            return Token{ .kind = .eof, .text = self.line[start..start], .pos = start };
        };

        // Числовая константа: цифры, точка, экспонента (1.5, 6.02e-23)
        // Также поддерживаем запись без ведущего нуля: .011 (как в
        // "X[]=1+.011*(?-1)" из sample.ela).
        if (isDigit(c)) {
            return self.lexNumber(start);
        }
        if (c == '.') {
            if (self.peekAt(1)) |next_ch| {
                if (isDigit(next_ch)) return self.lexNumber(start);
            }
        }

        // Идентификатор: буквенная последовательность (операторы, переменные)
        if (isAlpha(c)) {
            while (self.peek()) |ch| {
                if (isAlnum(ch)) self.advance() else break;
            }
            return Token{ .kind = .identifier, .text = self.line[start..self.pos], .pos = start };
        }

        // Строковый литерал в апострофах
        if (c == '\'') {
            return self.lexString(start);
        }

        // Двухсимвольные операторы сравнения и диапазона
        if (c == '>' and self.peekAt(1) == '>') return self.two(start, .gt_gt);
        if (c == '<' and self.peekAt(1) == '<') return self.two(start, .lt_lt);
        if (c == '>' and self.peekAt(1) == '=') return self.two(start, .gt_eq);
        if (c == '<' and self.peekAt(1) == '=') return self.two(start, .lt_eq);
        if (c == '=' and self.peekAt(1) == '=') return self.two(start, .eq_eq);
        if (c == '|' and self.peekAt(1) == '=') return self.two(start, .pipe_eq);
        if (c == '*' and self.peekAt(1) == '*') return self.two(start, .star_star);

        // Односимвольные токены
        const kind: TokenType = switch (c) {
            '$' => .dollar,
            '&' => .ampersand,
            '%' => .percent,
            '[' => .lbracket,
            ']' => .rbracket,
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            ',' => .comma,
            ';' => .semicolon,
            ':' => .colon,
            '#' => .hash,
            '@' => .at,
            '?' => .question,
            '=' => .equals,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '^' => .caret,
            '\\' => .backslash,
            else => return errors.ParseError.UnexpectedCharacter,
        };
        self.advance();
        return Token{ .kind = kind, .text = self.line[start..self.pos], .pos = start };
    }

    fn two(self: *Lexer, start: usize, kind: TokenType) errors.ParseError!Token {
        self.advance();
        self.advance();
        return Token{ .kind = kind, .text = self.line[start..self.pos], .pos = start };
    }

    fn lexNumber(self: *Lexer, start: usize) errors.ParseError!Token {
        while (self.peek()) |ch| {
            if (isDigit(ch)) {
                self.advance();
            } else break;
        }
        if (self.peek() == '.') {
            self.advance();
            while (self.peek()) |ch| {
                if (isDigit(ch)) self.advance() else break;
            }
        }
        // Экспонента: e/E, опционально знак, затем цифры
        if (self.peek()) |ch| {
            if (ch == 'e' or ch == 'E') {
                const save = self.pos;
                self.advance();
                if (self.peek()) |sign| {
                    if (sign == '+' or sign == '-') self.advance();
                }
                if (self.peek() == null or !isDigit(self.peek().?)) {
                    // Не экспонента — откатываемся, буква станет отдельным идентификатором
                    self.pos = save;
                } else {
                    while (self.peek()) |d| {
                        if (isDigit(d)) self.advance() else break;
                    }
                }
            }
        }
        return Token{ .kind = .number, .text = self.line[start..self.pos], .pos = start };
    }

    fn lexString(self: *Lexer, start: usize) errors.ParseError!Token {
        self.advance(); // пропускаем открывающий апостроф
        while (self.peek()) |ch| {
            if (ch == '\'') {
                self.advance();
                // текст без апострофов на границах
                return Token{ .kind = .string_literal, .text = self.line[start + 1 .. self.pos - 1], .pos = start };
            }
            self.advance();
        }
        return errors.ParseError.UnterminatedString;
    }
};

/// Разбить исходный текст программы на строки и очистить их:
/// пустые строки и строки-комментарии (начинаются с !) отбрасываются
/// на уровне отдельного флага, метки (начинаются с @) распознаются
/// отдельно вызывающей стороной (см. program.zig).
pub fn trimLine(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \r\t\n");
}

pub fn isCommentLine(line: []const u8) bool {
    return line.len > 0 and line[0] == '!';
}

pub fn isLabelLine(line: []const u8) bool {
    return line.len > 0 and line[0] == '@';
}

pub fn isMetaCommandLine(line: []const u8) bool {
    return std.ascii.eqlIgnoreCase(line, "!nul") or
        std.ascii.eqlIgnoreCase(line, "!one") or
        std.ascii.eqlIgnoreCase(line, "!err");
}