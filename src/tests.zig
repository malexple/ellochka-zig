//! src/tests.zig
//! Unit-тесты для expr.evaluate (через Parser) и execAssignment/execEsli
//! (через публичный statement.execute() — сами функции приватные).
const std = @import("std");
const lexer = @import("lexer.zig");
const expr_mod = @import("expr.zig");
const state_mod = @import("state.zig");
const program_mod = @import("program.zig");
const statement_mod = @import("statement.zig");
const errors = @import("errors.zig");

/// Заглушка вместо stdout — тестам execAssignment/execEsli реальный
/// вывод не нужен, но execute() требует anytype с .print/.flush.
const NullWriter = struct {
    pub fn print(self: *NullWriter, comptime fmt: []const u8, args: anytype) anyerror!void {
        _ = self;
        _ = fmt;
        _ = args;
    }
    pub fn flush(self: *NullWriter) anyerror!void {
        _ = self;
    }
};

fn letterOf(ch: u8) u8 {
    return state_mod.InterpreterState.letterIndex(ch).?;
}

/// Вычисляет одно выражение и возвращает f32 либо ошибку.
/// Парсинг оборачивается в ArenaAllocator — ровно как это делает сам
/// execute() в statement.zig (var arena = ...; defer arena.deinit();).
/// Без этого узлы ExprNode, создаваемые Parser.alloc() через
/// allocator.create(), никогда не освобождаются по отдельности и
/// std.testing.allocator репортует их как утечки.
fn evalExpr(src: []const u8, st: *state_mod.InterpreterState) !f32 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var toks: std.ArrayListUnmanaged(lexer.Token) = .{};
    var lx = lexer.Lexer.init(src);
    while (true) {
        const t = try lx.next();
        if (t.kind == .eof) break;
        try toks.append(allocator, t);
    }
    var parser = expr_mod.Parser.init(allocator, toks.items);
    const node = try parser.parseExpr();
    return expr_mod.evaluate(node, st, .{});
}

/// Выполняет одну строку программы через execute(). source_for_labels
/// задаёт мини-программу для разрешения меток (@label), сама тестируемая
/// строка передаётся отдельно и не обязана входить в этот источник.
/// execute() сама оборачивает парсинг в свою ArenaAllocator, поэтому
/// здесь дополнительная обёртка не нужна.
fn runLine(source_for_labels: []const u8, line: []const u8, st: *state_mod.InterpreterState) !statement_mod.ExecResult {
    const allocator = std.testing.allocator;
    var prog = try program_mod.Program.load(allocator, source_for_labels);
    defer prog.deinit();

    var null_writer = NullWriter{};
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    return statement_mod.execute(allocator, line, st, &prog, &null_writer, io);
}

// ---------------------------------------------------------------------
// expr.evaluate
// ---------------------------------------------------------------------

test "expr: приоритет умножения над сложением" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    const v = try evalExpr("2+3*4", &st);
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), v, 0.0001);
}

test "expr: скобки меняют порядок вычисления" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    const v = try evalExpr("(2+3)*4", &st);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), v, 0.0001);
}

test "expr: унарный минус и степень" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    const v = try evalExpr("-2^2", &st);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), v, 0.0001);
}

test "expr: доступ к элементу массива после SIZE" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    try st.sizeArray1D(letterOf('X'), 5);
    st.arrays1d[letterOf('X')][2] = 42.0;
    const v = try evalExpr("X[3]", &st);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), v, 0.0001);
}

test "expr: деление ненулевого на 0 - всегда ошибка" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    try std.testing.expectError(errors.RuntimeError.DivisionByZero, evalExpr("5/0", &st));
}

test "expr: 0/0 по умолчанию (!err) - ошибка" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    try std.testing.expectError(errors.RuntimeError.DivisionByZero, evalExpr("0/0", &st));
}

test "expr: 0/0 под !nul - возвращает 0" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    st.zero_div_mode = .nul;
    const v = try evalExpr("0/0", &st);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), v, 0.0001);
}

test "expr: 0/0 под !one - возвращает 1" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    st.zero_div_mode = .one;
    const v = try evalExpr("0/0", &st);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v, 0.0001);
}

// ---------------------------------------------------------------------
// execAssignment (через execute())
// ---------------------------------------------------------------------

test "assignment: простой скаляр с выражением" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    _ = try runLine("EXIT\n", "A=5+2", &st);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), st.scalars[letterOf('A')], 0.0001);
}

test "assignment: элемент одномерного массива" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    _ = try runLine("EXIT\n", "SIZE [3]=X", &st);
    _ = try runLine("EXIT\n", "X[2]=9", &st);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), st.arrays1d[letterOf('X')][1], 0.0001);
}

test "assignment: неявный цикл A[]=выражение с ?" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    _ = try runLine("EXIT\n", "SIZE [4]=X", &st);
    _ = try runLine("EXIT\n", "X[]=?*2", &st);
    const arr = st.arrays1d[letterOf('X')];
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), arr[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), arr[3], 0.0001);
}

test "assignment: короткая форма A:константа" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    _ = try runLine("EXIT\n", "A:-6.02e-2", &st);
    try std.testing.expectApproxEqAbs(@as(f32, -6.02e-2), st.scalars[letterOf('A')], 0.0001);
}

// ---------------------------------------------------------------------
// execEsli (через execute())
// ---------------------------------------------------------------------

test "esli: числовое условие true -> jump на метку" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    st.scalars[letterOf('A')] = 5;
    const result = try runLine("@target\nEXIT\n", "ESLI A == 5; @target", &st);
    switch (result) {
        .jump => |target| try std.testing.expectEqual(@as(usize, 2), target),
        else => return error.TestUnexpectedResult,
    }
}

test "esli: числовое условие false -> next" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    st.scalars[letterOf('A')] = 5;
    const result = try runLine("@target\nEXIT\n", "ESLI A == 6; @target", &st);
    try std.testing.expectEqual(statement_mod.ExecResult.next, result);
}

test "esli: оператор больше/меньше" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    st.scalars[letterOf('A')] = 10;
    const r1 = try runLine("@target\nEXIT\n", "ESLI A >> 5; @target", &st);
    switch (r1) {
        .jump => {},
        else => return error.TestUnexpectedResult,
    }
    const r2 = try runLine("@target\nEXIT\n", "ESLI A << 5; @target", &st);
    try std.testing.expectEqual(statement_mod.ExecResult.next, r2);
}

test "esli: диапазон включительно {Y,Z}" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    st.scalars[letterOf('A')] = 5;
    const inside = try runLine("@target\nEXIT\n", "ESLI A == {1,5}; @target", &st);
    switch (inside) {
        .jump => {},
        else => return error.TestUnexpectedResult,
    }
    const outside = try runLine("@target\nEXIT\n", "ESLI A == {1,4}; @target", &st);
    try std.testing.expectEqual(statement_mod.ExecResult.next, outside);
}

test "esli: сравнение строк $0 == 'text'" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    try st.dynamic_strings[0].set(std.testing.allocator, "hello");
    const result = try runLine("@target\nEXIT\n", "ESLI $0 == 'hello'; @target", &st);
    switch (result) {
        .jump => {},
        else => return error.TestUnexpectedResult,
    }
}

test "esli: без совпадения метки после ; -> продолжает следующей строкой" {
    var st = state_mod.InterpreterState.init(std.testing.allocator);
    defer st.deinit();
    st.scalars[letterOf('A')] = 1;
    const result = try runLine("@target\nEXIT\n", "ESLI A == 1; @target", &st);
    switch (result) {
        .jump => |target| try std.testing.expectEqual(@as(usize, 2), target),
        else => return error.TestUnexpectedResult,
    }
}
