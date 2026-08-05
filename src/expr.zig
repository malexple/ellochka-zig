//! src/expr.zig
//! Парсер и вычислитель арифметических/строковых выражений языка Ellochka.
//!
//! Грамматика выражений (приоритет по возрастанию, слева-направо
//! при равном приоритете, согласно спецификации):
//!   expr    := term (("+" | "-") term)*
//!   term    := factor (("*" | "/") factor)*
//!   factor  := power ("^" power)*
//!   power   := unary
//!   unary   := "-"? primary
//!   primary := number | variable | array_access | func_call
//!            | "(" expr ")" | "@" | "?"
//!
//! Спецсимволы:
//!   @  -> текущий номер строки (program_counter)
//!   ?  -> индекс текущей итерации неявного цикла (только в контексте A[]=)
//!
//! Математические функции вызываются через префикс & (например &SIN(X)),
//! строковые через префикс % (например %MID(P,I,N)).

const std = @import("std");
const lexer = @import("lexer.zig");
const state_mod = @import("state.zig");
const errors = @import("errors.zig");

const Token = lexer.Token;
const TokenType = lexer.TokenType;
const InterpreterState = state_mod.InterpreterState;

/// Контекст неявного цикла (для спецсимвола `?`), передаётся при
/// вычислении выражений внутри A[]= и A[,]=.
pub const LoopContext = struct {
    /// Значение первого индекса цикла (?1 либо просто ? для 1D).
    idx1: ?f32 = null,
    /// Значение второго индекса цикла (?2, используется в 2D-циклах).
    idx2: ?f32 = null,
};

/// Математические функции, вызываемые через префикс &.
pub const MathFunc = enum {
    ran, // &RAN# - случайное число [0,1)
    sin,
    cos,
    tan,
    asn,
    acs,
    atn,
    exp,
    log,
    int,
    frc,
    abs,
    sgn,
    sqr,

    pub fn fromName(name: []const u8) ?MathFunc {
        const map = .{
            .{ "RAN", MathFunc.ran },
            .{ "SIN", MathFunc.sin },
            .{ "COS", MathFunc.cos },
            .{ "TAN", MathFunc.tan },
            .{ "ASN", MathFunc.asn },
            .{ "ACS", MathFunc.acs },
            .{ "ATN", MathFunc.atn },
            .{ "EXP", MathFunc.exp },
            .{ "LOG", MathFunc.log },
            .{ "INT", MathFunc.int },
            .{ "FRC", MathFunc.frc },
            .{ "ABS", MathFunc.abs },
            .{ "SGN", MathFunc.sgn },
            .{ "SQR", MathFunc.sqr },
        };
        inline for (map) |pair| {
            if (std.ascii.eqlIgnoreCase(name, pair[0])) return pair[1];
        }
        return null;
    }
};

/// Узел разобранного выражения (простое дерево, вычисляется рекурсивно
/// сразу без промежуточного байткода — этого достаточно для интерпретатора
/// построчного языка).
pub const ExprNode = union(enum) {
    number: f32,
    at_symbol: void, // @
    question_symbol: u8, // ? или ?1 / ?2 (0 = обычный ?, 1/2 = индекс цикла)
    scalar: u8, // простая переменная A-Z (индекс 0-25)
    array1d: struct { letter: u8, index: *ExprNode },
    array2d: struct { letter: u8, row: *ExprNode, col: *ExprNode },
    binary: struct { op: u8, lhs: *ExprNode, rhs: *ExprNode },
    negate: *ExprNode,
    math_call: struct { func: MathFunc, arg: ?*ExprNode },
    string_char_code: struct { // A = $?[i]  (код символа строки)
        which: u8, // '0'-'9' либо 'A'-'Z'
        index: *ExprNode,
    },
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []Token,
    pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, tokens: []Token) Parser {
        return .{ .allocator = allocator, .tokens = tokens };
    }

    fn peek(self: *Parser) Token {
        if (self.pos >= self.tokens.len) return Token{ .kind = .eof, .text = "", .pos = 0 };
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) Token {
        const t = self.peek();
        if (self.pos < self.tokens.len) self.pos += 1;
        return t;
    }

    fn expect(self: *Parser, kind: TokenType) errors.ParseError!Token {
        const t = self.peek();
        if (t.kind != kind) return errors.ParseError.InvalidStatement;
        return self.advance();
    }

    fn alloc(self: *Parser, node: ExprNode) errors.ParseError!*ExprNode {
        const ptr = self.allocator.create(ExprNode) catch return errors.ParseError.InvalidStatement;
        ptr.* = node;
        return ptr;
    }

    /// Точка входа: разобрать полное арифметическое выражение.
    pub fn parseExpr(self: *Parser) errors.ParseError!*ExprNode {
        var lhs = try self.parseTerm();
        while (true) {
            const t = self.peek();
            if (t.kind == .plus or t.kind == .minus) {
                const op: u8 = if (t.kind == .plus) '+' else '-';
                _ = self.advance();
                const rhs = try self.parseTerm();
                lhs = try self.alloc(.{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } });
            } else break;
        }
        return lhs;
    }

    fn parseTerm(self: *Parser) errors.ParseError!*ExprNode {
        var lhs = try self.parseFactor();
        while (true) {
            const t = self.peek();
            if (t.kind == .star or t.kind == .slash) {
                const op: u8 = if (t.kind == .star) '*' else '/';
                _ = self.advance();
                const rhs = try self.parseFactor();
                lhs = try self.alloc(.{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } });
            } else break;
        }
        return lhs;
    }

    fn parseFactor(self: *Parser) errors.ParseError!*ExprNode {
        var lhs = try self.parseUnary();
        while (self.peek().kind == .caret) {
            _ = self.advance();
            const rhs = try self.parseUnary();
            lhs = try self.alloc(.{ .binary = .{ .op = '^', .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) errors.ParseError!*ExprNode {
        if (self.peek().kind == .minus) {
            _ = self.advance();
            const operand = try self.parseUnary();
            return self.alloc(.{ .negate = operand });
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) errors.ParseError!*ExprNode {
        const t = self.peek();
        switch (t.kind) {
            .number => {
                _ = self.advance();
                const val = std.fmt.parseFloat(f32, t.text) catch return errors.ParseError.InvalidNumber;
                return self.alloc(.{ .number = val });
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.parseExpr();
                _ = try self.expect(.rparen);
                return inner;
            },
            .at => {
                _ = self.advance();
                return self.alloc(.{ .at_symbol = {} });
            },
            .question => {
                _ = self.advance();
                var which: u8 = 0;
                if (self.peek().kind == .number and self.peek().text.len == 1) {
                    const c = self.peek().text[0];
                    if (c == '1' or c == '2') {
                        which = c;
                        _ = self.advance();
                    }
                }
                return self.alloc(.{ .question_symbol = which });
            },
            .ampersand => {
                _ = self.advance();
                return self.parseMathCall();
            },
            .identifier => {
                return self.parseIdentifierExpr();
            },
            else => return errors.ParseError.InvalidStatement,
        }
    }

    fn parseMathCall(self: *Parser) errors.ParseError!*ExprNode {
        const name_tok = try self.expect(.identifier);
        // &RAN# — особый случай без скобок и с завершающим #
        const name = name_tok.text;
        if (std.ascii.eqlIgnoreCase(name, "RAN")) {
            if (self.peek().kind == .hash) _ = self.advance();
            return self.alloc(.{ .math_call = .{ .func = .ran, .arg = null } });
        }
        const func = MathFunc.fromName(name) orelse return errors.ParseError.UnknownFunction;
        _ = try self.expect(.lparen);
        const arg = try self.parseExpr();
        _ = try self.expect(.rparen);
        return self.alloc(.{ .math_call = .{ .func = func, .arg = arg } });
    }

    /// Разбор идентификатора в контексте выражения: либо простая
    /// переменная A, либо A[i] (1D), либо A[i,j] (2D).
    fn parseIdentifierExpr(self: *Parser) errors.ParseError!*ExprNode {
        const name_tok = try self.expect(.identifier);
        if (name_tok.text.len != 1) return errors.ParseError.InvalidVariableName;
        const letter = state_mod.InterpreterState.letterIndex(name_tok.text[0]) orelse
            return errors.ParseError.InvalidVariableName;

        if (self.peek().kind != .lbracket) {
            return self.alloc(.{ .scalar = letter });
        }
        _ = self.advance(); // [

        // X[] внутри выражения - сокращение для "X по индексу текущей
        // неявной итерации", то же самое, что и X[?]. Встречается в
        // конструкциях вида Y[]=A*X[]^B*&exp(-C*X[])+&ran#, где X[]
        // на правой части ссылается на тот же индекс, что и Y[] слева.
        if (self.peek().kind == .rbracket) {
            _ = self.advance();
            const idx_node = try self.alloc(.{ .question_symbol = 0 });
            return self.alloc(.{ .array1d = .{ .letter = letter, .index = idx_node } });
        }

        const first = try self.parseExpr();
        if (self.peek().kind == .comma) {
            _ = self.advance();
            const second = try self.parseExpr();
            _ = try self.expect(.rbracket);
            return self.alloc(.{ .array2d = .{ .letter = letter, .row = first, .col = second } });
        }
        _ = try self.expect(.rbracket);
        return self.alloc(.{ .array1d = .{ .letter = letter, .index = first } });
    }
};

/// Вычислить разобранное выражение с учётом текущего состояния
/// интерпретатора и контекста неявного цикла (если применимо).
pub fn evaluate(
    node: *const ExprNode,
    st: *InterpreterState,
    loop_ctx: LoopContext,
) errors.EllochkaError!f32 {
    switch (node.*) {
        .number => |v| return v,
        .at_symbol => return @floatFromInt(st.program_counter),
        .question_symbol => |which| {
            const val = switch (which) {
                0 => loop_ctx.idx1,
                '1' => loop_ctx.idx1,
                '2' => loop_ctx.idx2,
                else => null,
            };
            return val orelse errors.RuntimeError.TypeMismatch;
        },
        .scalar => |letter| return st.scalars[letter],
        .array1d => |a| {
            const idx_f = try evaluate(a.index, st, loop_ctx);
            const idx: usize = @intFromFloat(idx_f);
            const arr = st.arrays1d[a.letter];
            if (idx < 1 or idx > arr.len) return errors.RuntimeError.IndexOutOfBounds;
            return arr[idx - 1];
        },
        .array2d => |a| {
            const row_f = try evaluate(a.row, st, loop_ctx);
            const col_f = try evaluate(a.col, st, loop_ctx);
            const row: usize = @intFromFloat(row_f);
            const col: usize = @intFromFloat(col_f);
            const arr = st.arrays2d[a.letter];
            if (row < 1 or row > arr.rows or col < 1 or col > arr.cols)
                return errors.RuntimeError.IndexOutOfBounds;
            return arr.data[arr.indexOf(row - 1, col - 1)];
        },
        .binary => |b| {
            const l = try evaluate(b.lhs, st, loop_ctx);
            const r = try evaluate(b.rhs, st, loop_ctx);
            return switch (b.op) {
                '+' => l + r,
                '-' => l - r,
                '*' => l * r,
                '/' => if (r == 0) errors.RuntimeError.DivisionByZero else l / r,
                '^' => std.math.pow(f32, l, r),
                else => errors.RuntimeError.TypeMismatch,
            };
        },
        .negate => |n| return -(try evaluate(n, st, loop_ctx)),
        .math_call => |m| return evalMathFunc(m.func, m.arg, st, loop_ctx),
        .string_char_code => return errors.RuntimeError.TypeMismatch, // обрабатывается на уровне statement.zig
    }
}

fn toRadians(x: f32, st: *InterpreterState) f32 {
    return if (st.angle_mode == .degrees) x * std.math.pi / 180.0 else x;
}

fn fromRadians(x: f32, st: *InterpreterState) f32 {
    return if (st.angle_mode == .degrees) x * 180.0 / std.math.pi else x;
}

fn evalMathFunc(
    func: MathFunc,
    arg: ?*ExprNode,
    st: *InterpreterState,
    loop_ctx: LoopContext,
) errors.EllochkaError!f32 {
    if (func == .ran) {
        // Примечание: для воспроизводимого рандома в проде нужен PRNG
        // с явным seed, здесь используется системный источник.
        var buf: [8]u8 = undefined;
        std.crypto.random.bytes(&buf);
        const bits = std.mem.readInt(u64, &buf, .little);
        const as_f: f64 = @floatFromInt(bits >> 11);
        return @floatCast(as_f / @as(f64, @floatFromInt(@as(u64, 1) << 53)));
    }
    const x = try evaluate(arg.?, st, loop_ctx);
    return switch (func) {
        .sin => @sin(toRadians(x, st)),
        .cos => @cos(toRadians(x, st)),
        .tan => @tan(toRadians(x, st)),
        .asn => fromRadians(std.math.asin(x), st),
        .acs => fromRadians(std.math.acos(x), st),
        .atn => fromRadians(std.math.atan(x), st),
        .exp => @exp(x),
        .log => @log(x),
        .int => @trunc(x),
        .frc => x - @trunc(x),
        .abs => @abs(x),
        .sgn => if (x > 0) @as(f32, 1) else if (x < 0) @as(f32, -1) else @as(f32, 0),
        .sqr => std.math.sqrt(x),
        .ran => unreachable,
    };
}
