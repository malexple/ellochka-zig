//! src/statement.zig
const std = @import("std");
const lexer = @import("lexer.zig");
const expr_mod = @import("expr.zig");
const state_mod = @import("state.zig");
const program_mod = @import("program.zig");
const errors = @import("errors.zig");

const InterpreterState = state_mod.InterpreterState;
const Program = program_mod.Program;

pub const ExecResult = union(enum) {
    next,
    jump: usize,
    halt,
};

fn tokenizeLine(allocator: std.mem.Allocator, line: []const u8) ![]lexer.Token {
    var toks = std.ArrayListUnmanaged(lexer.Token){};
    var lx = lexer.Lexer.init(line);
    while (true) {
        const t = try lx.next();
        if (t.kind == .eof) break;
        try toks.append(allocator, t);
    }
    return toks.toOwnedSlice(allocator);
}

/// Если токен обозначает цифру 0-9 или букву A-Z (регистронезависимо),
/// возвращает этот символ в верхнем регистре / как цифру. Используется
/// для разбора конструкций `$0`..`$9` и `$A`..`$Z` после токена `.dollar`.
fn dollarTargetChar(tok: lexer.Token) ?u8 {
    if (tok.kind == .number and tok.text.len == 1 and tok.text[0] >= '0' and tok.text[0] <= '9') {
        return tok.text[0];
    }
    if (tok.kind == .identifier and tok.text.len == 1) {
        const c = tok.text[0];
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) return c;
    }
    return null;
}

/// Форматирует f32 в строку без лишних хвостовых нулей: 5.0 -> "5", 5.5 -> "5.5".
fn formatScalar(buf: []u8, val: f32) []const u8 {
    if (val == @trunc(val) and @abs(val) < 1.0e15) {
        const i: i64 = @intFromFloat(val);
        return std.fmt.bufPrint(buf, "{d}", .{i}) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}", .{val}) catch "";
}

pub fn execute(
    allocator: std.mem.Allocator,
    line: []const u8,
    st: *InterpreterState,
    prog: *const Program,
    stdout: anytype,
    io: std.Io,
) errors.EllochkaError!ExecResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const toks = tokenizeLine(a, line) catch return errors.ParseError.InvalidStatement;
    if (toks.len == 0) return .next;

    const first = toks[0];

    if (first.kind == .dollar) {
        return execDollarStatement(a, toks, st);
    }

    if (first.kind != .identifier) return errors.ParseError.InvalidStatement;

    const name = first.text;

    if (eq(name, "EXIT") or eq(name, "STOP")) {
        return .halt;
    }
    if (eq(name, "MEMC")) {
        return execMemc(toks[1..], st);
    }
    if (eq(name, "SIZE")) {
        return execSize(a, toks[1..], st);
    }
    if (eq(name, "UMEM")) {
        return execUmem(a, toks[1..], st);
    }
    if (eq(name, "CURR")) {
        return execCurr(toks[1..], st);
    }
    if (eq(name, "INCR")) {
        return execIncrDecr(toks[1..], st, 1.0);
    }
    if (eq(name, "DECR")) {
        return execIncrDecr(toks[1..], st, -1.0);
    }

    if (eq(name, "RADI")) { st.angle_mode = .radians; return .next; }
    if (eq(name, "GRDS")) { st.angle_mode = .degrees; return .next; }
    if (eq(name, "ORUP")) { st.ordinate_direction = .up; return .next; }
    if (eq(name, "ORDN")) { st.ordinate_direction = .down; return .next; }

    if (eq(name, "GOTO")) {
        return execGoto(a, toks[1..], st, prog);
    }
    if (eq(name, "ESLI")) {
        return execEsli(a, toks[1..], st, prog);
    }
    if (eq(name, "SLEP")) {
        var parser = expr_mod.Parser.init(a, toks[1..]);
        const node = try parser.parseExpr();
        const ms = try expr_mod.evaluate(node, st, .{});
        io.sleep(.fromMilliseconds(@as(i64, @intFromFloat(ms))), .awake) catch {};
        return .next;
    }

    if (eq(name, "CLSC")) {
        stdout.print("\x1B[2J\x1B[H", .{}) catch {};
        return .next;
    }
    if (eq(name, "TEXT") or eq(name, "GRAF")) {
        return .next;
    }
    if (eq(name, "CFON") or eq(name, "CSIM") or eq(name, "STRO") or eq(name, "STLB")) {
        return execAnsiControl(a, name, toks[1..], st, stdout);
    }
    if (eq(name, "LIST")) {
        return execList(a, toks[1..], st, stdout);
    }
    if (eq(name, "VVOD")) {
        return execVvod(a, toks[1..], st, stdout, io);
    }

    if (name.len == 1 and InterpreterState.letterIndex(name[0]) != null) {
        return execAssignment(a, toks, st);
    }

    return errors.ParseError.ExtensionNotImplemented;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Разбирает токен-число (например, "1", "2", "3") в u8-категорию.
/// Используется для SIZE/UMEM/CURR/MEMC вида "<цифра><буква>".
fn parseCategoryDigit(tok: lexer.Token) errors.EllochkaError!u8 {
    if (tok.kind != .number) return errors.ParseError.InvalidStatement;
    const val = std.fmt.parseInt(u32, tok.text, 10) catch return errors.ParseError.InvalidStatement;
    if (val > 255) return errors.ParseError.InvalidStatement;
    return @intCast(val);
}

/// INCR A / DECR A — увеличивает/уменьшает простую переменную на 1.
fn execIncrDecr(
    args: []lexer.Token,
    st: *InterpreterState,
    delta: f32,
) errors.EllochkaError!ExecResult {
    if (args.len != 1 or args[0].kind != .identifier or args[0].text.len != 1) {
        return errors.ParseError.InvalidStatement;
    }
    const letter = InterpreterState.letterIndex(args[0].text[0]) orelse return errors.ParseError.InvalidVariableName;
    st.scalars[letter] += delta;
    return .next;
}

/// MEMC            — обнулить простые переменные;
/// MEMC $$         — очистить все элементы строкового массива;
/// MEMC 1M         — обнулить все элементы одномерного массива M;
/// MEMC 2K         — обнулить все элементы двумерного массива K.
fn execMemc(
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    if (args.len == 0) {
        @memset(&st.scalars, 0.0);
        return .next;
    }
    if (args.len == 2 and args[0].kind == .dollar and args[1].kind == .dollar) {
        for (st.static_strings) |*s| @memset(s, 0);
        @memset(st.static_strings_lens, 0);
        return .next;
    }
    if (args.len == 2 and args[0].kind == .number and args[1].kind == .identifier and args[1].text.len == 1) {
        const category = try parseCategoryDigit(args[0]);
        const letter = InterpreterState.letterIndex(args[1].text[0]) orelse return errors.ParseError.InvalidVariableName;
        switch (category) {
            1 => {
                const arr = st.arrays1d[letter];
                if (arr.len == 0) return errors.RuntimeError.ArrayNotSized;
                @memset(arr, 0.0);
            },
            2 => {
                const arr = st.arrays2d[letter];
                if (arr.data.len == 0) return errors.RuntimeError.ArrayNotSized;
                @memset(arr.data, 0.0);
            },
            else => return errors.ParseError.InvalidStatement,
        }
        return .next;
    }
    return errors.ParseError.ExtensionNotImplemented;
}

/// SIZE L               — задать размер строкового массива L элементов;
/// SIZE [K]=A;X;R        — задать размер K для одномерных массивов A,X,R;
/// SIZE [N,M]=X;Y;W      — задать размер N x M для двумерных массивов X,Y,W.
fn execSize(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    if (args.len == 0) return errors.ParseError.InvalidStatement;

    if (args[0].kind != .lbracket) {
        var parser = expr_mod.Parser.init(allocator, args);
        const node = try parser.parseExpr();
        const len_f = try expr_mod.evaluate(node, st, .{});
        const len: usize = @intFromFloat(len_f);
        st.sizeStringArray(len) catch return errors.RuntimeError.MemoryAllocationFailed;
        return .next;
    }

    var idx: usize = 1;
    var depth: usize = 1;
    var comma_pos: ?usize = null;
    while (idx < args.len and depth > 0) {
        if (args[idx].kind == .lbracket) depth += 1;
        if (args[idx].kind == .rbracket) { depth -= 1; if (depth == 0) break; }
        if (args[idx].kind == .comma and depth == 1 and comma_pos == null) comma_pos = idx;
        idx += 1;
    }
    if (idx >= args.len) return errors.ParseError.UnbalancedBrackets;
    const bracket_end = idx;
    idx += 1;
    if (idx >= args.len or args[idx].kind != .equals) return errors.ParseError.InvalidStatement;
    idx += 1;
    const var_tokens = args[idx..];

    if (comma_pos) |cp| {
        const row_tokens = args[1..cp];
        const col_tokens = args[cp + 1 .. bracket_end];
        var rp = expr_mod.Parser.init(allocator, row_tokens);
        const rnode = try rp.parseExpr();
        const rows_f = try expr_mod.evaluate(rnode, st, .{});
        var cp2 = expr_mod.Parser.init(allocator, col_tokens);
        const cnode = try cp2.parseExpr();
        const cols_f = try expr_mod.evaluate(cnode, st, .{});
        const rows: usize = @intFromFloat(rows_f);
        const cols: usize = @intFromFloat(cols_f);

        var start: usize = 0;
        var i: usize = 0;
        while (i <= var_tokens.len) {
            if (i == var_tokens.len or var_tokens[i].kind == .semicolon) {
                const seg = var_tokens[start..i];
                if (seg.len == 1 and seg[0].kind == .identifier and seg[0].text.len == 1) {
                    const letter = InterpreterState.letterIndex(seg[0].text[0]) orelse return errors.ParseError.InvalidVariableName;
                    st.sizeArray2D(letter, rows, cols) catch return errors.RuntimeError.MemoryAllocationFailed;
                } else if (seg.len > 0) {
                    return errors.ParseError.InvalidStatement;
                }
                start = i + 1;
            }
            i += 1;
        }
    } else {
        const idx_tokens = args[1..bracket_end];
        var ip = expr_mod.Parser.init(allocator, idx_tokens);
        const inode = try ip.parseExpr();
        const len_f = try expr_mod.evaluate(inode, st, .{});
        const len: usize = @intFromFloat(len_f);

        var start: usize = 0;
        var i: usize = 0;
        while (i <= var_tokens.len) {
            if (i == var_tokens.len or var_tokens[i].kind == .semicolon) {
                const seg = var_tokens[start..i];
                if (seg.len == 1 and seg[0].kind == .identifier and seg[0].text.len == 1) {
                    const letter = InterpreterState.letterIndex(seg[0].text[0]) orelse return errors.ParseError.InvalidVariableName;
                    st.sizeArray1D(letter, len) catch return errors.RuntimeError.MemoryAllocationFailed;
                } else if (seg.len > 0) {
                    return errors.ParseError.InvalidStatement;
                }
                start = i + 1;
            }
            i += 1;
        }
    }
    return .next;
}

/// UMEM D — уничтожить все одномерные (D=1), двумерные (D=2)
/// или строковый (D=3) массивы.
fn execUmem(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    var parser = expr_mod.Parser.init(allocator, args);
    const node = try parser.parseExpr();
    const val = try expr_mod.evaluate(node, st, .{});
    const category: u8 = @intFromFloat(val);
    if (category < 1 or category > 3) return errors.ParseError.InvalidStatement;
    st.umem(category);
    return .next;
}

/// CURR 1K / CURR 2K / CURR 3K — записать в переменную K текущий размер
/// одномерных массивов, число строк двумерных массивов или число
/// элементов строкового массива соответственно (по официальному help DIKAR v7).
fn execCurr(
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    if (args.len != 2 or args[1].kind != .identifier or args[1].text.len != 1) {
        return errors.ParseError.InvalidStatement;
    }
    const category = try parseCategoryDigit(args[0]);
    const letter = InterpreterState.letterIndex(args[1].text[0]) orelse return errors.ParseError.InvalidVariableName;
    const val: f32 = switch (category) {
        1 => @floatFromInt(st.array1d_len),
        2 => @floatFromInt(st.array2d_rows),
        3 => @floatFromInt(st.static_strings.len),
        else => return errors.ParseError.InvalidStatement,
    };
    st.scalars[letter] = val;
    return .next;
}

fn execGoto(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    prog: *const Program,
) errors.EllochkaError!ExecResult {
    if (args.len == 0) return errors.ParseError.InvalidStatement;
    if (args[0].kind == .at and args.len > 1 and args[1].kind == .identifier) {
        const target = prog.resolveLabel(args[1].text) orelse return errors.RuntimeError.LabelNotFound;
        return .{ .jump = target };
    }
    var parser = expr_mod.Parser.init(allocator, args);
    const node = try parser.parseExpr();
    const val = try expr_mod.evaluate(node, st, .{});
    const relative = parser.pos < args.len and args[parser.pos].kind == .backslash;
    var target: i64 = @intFromFloat(val);
    if (relative) {
        target += @as(i64, @intCast(st.program_counter));
    }
    if (target < 1 or target > @as(i64, @intCast(state_mod.MAX_PROGRAM_LINES))) {
        return errors.RuntimeError.LineOutOfRange;
    }
    return .{ .jump = @intCast(target) };
}

fn execEsli(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    prog: *const Program,
) errors.EllochkaError!ExecResult {
    var semi_pos: ?usize = null;
    for (args, 0..) |t, i| {
        if (t.kind == .semicolon) { semi_pos = i; break; }
    }
    const sep = semi_pos orelse return errors.ParseError.InvalidStatement;
    const cond_tokens = args[0..sep];
    const goto_tokens = args[sep + 1 ..];

    var op_idx: ?usize = null;
    for (cond_tokens, 0..) |t, i| {
        switch (t.kind) {
            .gt_gt, .lt_lt, .gt_eq, .lt_eq, .eq_eq, .pipe_eq => { op_idx = i; break; },
            else => {},
        }
    }
    const oi = op_idx orelse return errors.ParseError.InvalidStatement;
    var lp = expr_mod.Parser.init(allocator, cond_tokens[0..oi]);
    const lhs_node = try lp.parseExpr();
    const lhs_val = try expr_mod.evaluate(lhs_node, st, .{});

    var rp = expr_mod.Parser.init(allocator, cond_tokens[oi + 1 ..]);
    const rhs_node = try rp.parseExpr();
    const rhs_val = try expr_mod.evaluate(rhs_node, st, .{});

    const cond_true = switch (cond_tokens[oi].kind) {
        .gt_gt => lhs_val > rhs_val,
        .lt_lt => lhs_val < rhs_val,
        .gt_eq => lhs_val >= rhs_val,
        .lt_eq => lhs_val <= rhs_val,
        .eq_eq => lhs_val == rhs_val,
        .pipe_eq => lhs_val != rhs_val,
        else => unreachable,
    };

    if (!cond_true) return .next;
    return execGoto(allocator, goto_tokens, st, prog);
}

fn execAnsiControl(
    allocator: std.mem.Allocator,
    name: []const u8,
    args: []lexer.Token,
    st: *InterpreterState,
    stdout: anytype,
) errors.EllochkaError!ExecResult {
    var parser = expr_mod.Parser.init(allocator, args);
    const node = try parser.parseExpr();
    const val = try expr_mod.evaluate(node, st, .{});
    const n: u32 = @intFromFloat(val);

    if (eq(name, "CSIM")) {
        const code: u32 = if (n < 8) 30 + n else 90 + (n - 8);
        stdout.print("\x1B[{d}m", .{code}) catch {};
    } else if (eq(name, "CFON")) {
        const code: u32 = 40 + (n % 8);
        stdout.print("\x1B[{d}m", .{code}) catch {};
    } else if (eq(name, "STRO")) {
        stdout.print("\x1B[{d};1H", .{n}) catch {};
    } else if (eq(name, "STLB")) {
        stdout.print("\x1B[{d}G", .{n}) catch {};
    }
    return .next;
}

fn execList(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    stdout: anytype,
) errors.EllochkaError!ExecResult {
    var newline = true;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= args.len) {
        if (i == args.len or args[i].kind == .semicolon) {
            const segment = args[start..i];
            if (segment.len > 0) {
                try printSegment(allocator, segment, st, stdout);
            }
            start = i + 1;
        }
        i += 1;
    }
    if (args.len > 0 and args[args.len - 1].kind == .backslash) newline = false;
    if (newline) stdout.print("\n", .{}) catch {};
    return .next;
}

fn printSegment(
    allocator: std.mem.Allocator,
    segment: []lexer.Token,
    st: *InterpreterState,
    stdout: anytype,
) errors.EllochkaError!void {
    if (segment.len == 1 and segment[0].kind == .string_literal) {
        stdout.print("{s}", .{segment[0].text}) catch {};
        return;
    }
    if (segment.len == 2 and segment[0].kind == .dollar) {
        if (dollarTargetChar(segment[1])) |ch| {
            const bytes = try st.resolveStringBytes(ch);
            stdout.print("{s}", .{bytes}) catch {};
            return;
        }
    }
    var parser = expr_mod.Parser.init(allocator, segment);
    const node = try parser.parseExpr();
    const val = try expr_mod.evaluate(node, st, .{});
    stdout.print("{d}", .{val}) catch {};
}

fn execVvod(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    stdout: anytype,
    io: std.Io,
) errors.EllochkaError!ExecResult {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= args.len) {
        if (i == args.len or args[i].kind == .semicolon) {
            const segment = args[start..i];
            if (segment.len > 0) {
                try readSegment(allocator, segment, st, stdout, io);
            }
            start = i + 1;
        }
        i += 1;
    }
    return .next;
}

fn readSegment(
    allocator: std.mem.Allocator,
    segment: []lexer.Token,
    st: *InterpreterState,
    stdout: anytype,
    io: std.Io,
) errors.EllochkaError!void {
    _ = allocator;
    if (segment.len == 1 and segment[0].kind == .string_literal) {
        stdout.print("{s}", .{segment[0].text}) catch {};
        return;
    }
    if (segment.len == 1 and segment[0].kind == .identifier and segment[0].text.len == 1) {
        const letter = InterpreterState.letterIndex(segment[0].text[0]) orelse return errors.ParseError.InvalidVariableName;
        var buf: [128]u8 = undefined;
        var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &buf);
        const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch "";
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len > 0) {
            st.scalars[letter] = std.fmt.parseFloat(f32, trimmed) catch return errors.ParseError.InvalidNumber;
        }
        return;
    }
    if (segment.len == 2 and segment[0].kind == .dollar) {
        if (dollarTargetChar(segment[1])) |ch| {
            var buf: [1024]u8 = undefined;
            var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &buf);
            const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch "";
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (ch >= '0' and ch <= '9') {
                if (trimmed.len > state_mod.MAX_DYNAMIC_STRING_LEN) return errors.RuntimeError.StringTooLong;
                st.dynamic_strings[ch - '0'].set(st.allocator, trimmed) catch return errors.RuntimeError.MemoryAllocationFailed;
            } else {
                try st.setStaticString(ch, trimmed);
            }
            return;
        }
    }
    return errors.ParseError.ExtensionNotImplemented;
}

/// Разбирает и выполняет присваивание текстовой переменной:
/// $0 = ... / $A = ... (конкатенация через +), либо запись кода символа
/// $?[индекс] = выражение. `toks[0]` обязан быть токеном `.dollar`.
fn execDollarStatement(
    allocator: std.mem.Allocator,
    toks: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    if (toks.len < 2 or toks[0].kind != .dollar) return errors.ParseError.InvalidStatement;
    const ch = dollarTargetChar(toks[1]) orelse return errors.ParseError.InvalidVariableName;
    var idx: usize = 2;

    if (idx < toks.len and toks[idx].kind == .lbracket) {
        idx += 1;
        const bracket_start = idx;
        var depth: usize = 1;
        while (idx < toks.len and depth > 0) {
            if (toks[idx].kind == .lbracket) depth += 1;
            if (toks[idx].kind == .rbracket) { depth -= 1; if (depth == 0) break; }
            idx += 1;
        }
        if (idx >= toks.len) return errors.ParseError.UnbalancedBrackets;
        const bracket_end = idx;
        idx += 1;
        if (idx >= toks.len or toks[idx].kind != .equals) return errors.ParseError.InvalidStatement;
        idx += 1;

        var ip = expr_mod.Parser.init(allocator, toks[bracket_start..bracket_end]);
        const inode = try ip.parseExpr();
        const idx_f = try expr_mod.evaluate(inode, st, .{});
        if (idx_f < 1) return errors.RuntimeError.IndexOutOfBounds;
        const char_index: usize = @intFromFloat(idx_f);

        var vp = expr_mod.Parser.init(allocator, toks[idx..]);
        const vnode = try vp.parseExpr();
        const val_f = try expr_mod.evaluate(vnode, st, .{});
        const clamped = std.math.clamp(val_f, 0.0, 255.0);
        const byte_val: u8 = @intFromFloat(clamped);

        try st.writeCharCode(ch, char_index, byte_val);
        return .next;
    }

    if (idx >= toks.len or toks[idx].kind != .equals) return errors.ParseError.InvalidStatement;
    idx += 1;
    const rhs = toks[idx..];
    if (rhs.len == 0) return errors.ParseError.InvalidStatement;

    var buf = std.ArrayListUnmanaged(u8){};
    var start: usize = 0;
    var i: usize = 0;
    while (i <= rhs.len) {
        if (i == rhs.len or rhs[i].kind == .plus) {
            const seg = rhs[start..i];
            try appendStringComponent(allocator, &buf, seg, st);
            start = i + 1;
        }
        i += 1;
    }
    const result = buf.items;

    if (ch >= '0' and ch <= '9') {
        if (result.len > state_mod.MAX_DYNAMIC_STRING_LEN) return errors.RuntimeError.StringTooLong;
        st.dynamic_strings[ch - '0'].set(st.allocator, result) catch return errors.RuntimeError.MemoryAllocationFailed;
    } else {
        try st.setStaticString(ch, result);
    }
    return .next;
}

/// Один компонент конкатенации: строковая константа, ссылка на текстовую
/// переменную ($0-$9 / $A-$Z) или простая переменная (число -> строка).
fn appendStringComponent(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    seg: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!void {
    if (seg.len == 0) return errors.ParseError.InvalidStatement;
    if (seg.len == 1 and seg[0].kind == .string_literal) {
        buf.appendSlice(allocator, seg[0].text) catch return errors.RuntimeError.MemoryAllocationFailed;
        return;
    }
    if (seg.len == 2 and seg[0].kind == .dollar) {
        if (dollarTargetChar(seg[1])) |ch| {
            const bytes = try st.resolveStringBytes(ch);
            buf.appendSlice(allocator, bytes) catch return errors.RuntimeError.MemoryAllocationFailed;
            return;
        }
        return errors.ParseError.InvalidVariableName;
    }
    if (seg.len == 1 and seg[0].kind == .identifier and seg[0].text.len == 1) {
        const letter = InterpreterState.letterIndex(seg[0].text[0]) orelse return errors.ParseError.InvalidVariableName;
        var numbuf: [64]u8 = undefined;
        const s = formatScalar(&numbuf, st.scalars[letter]);
        buf.appendSlice(allocator, s) catch return errors.RuntimeError.MemoryAllocationFailed;
        return;
    }
    return errors.ParseError.ExtensionNotImplemented;
}

/// Токенизирует и вычисляет арифметическое выражение, хранящееся внутри
/// текстовой переменной (оператор присваивания `A#$текст`, вариант 6).
/// Ошибки разбора конвертируются в RuntimeError.InvalidExpressionInString;
/// ошибки самого вычисления (деление на ноль и т.д.) передаются как есть.
fn evalStringExpression(
    allocator: std.mem.Allocator,
    content: []const u8,
    st: *InterpreterState,
) errors.EllochkaError!f32 {
    const toks = tokenizeLine(allocator, content) catch return errors.RuntimeError.InvalidExpressionInString;
    if (toks.len == 0) return errors.RuntimeError.InvalidExpressionInString;
    var parser = expr_mod.Parser.init(allocator, toks);
    const node = parser.parseExpr() catch return errors.RuntimeError.InvalidExpressionInString;
    return expr_mod.evaluate(node, st, .{});
}

/// Записывает вычисленное значение val в цель присваивания: простую
/// переменную, элемент одномерного или двумерного массива.
fn storeAssignedValue(
    allocator: std.mem.Allocator,
    st: *InterpreterState,
    letter: u8,
    is_array1d: bool,
    is_array2d: bool,
    index1_tokens: []lexer.Token,
    index2_tokens: []lexer.Token,
    val: f32,
) errors.EllochkaError!void {
    if (is_array1d) {
        var ip = expr_mod.Parser.init(allocator, index1_tokens);
        const inode = try ip.parseExpr();
        const idx_f = try expr_mod.evaluate(inode, st, .{});
        const i: usize = @intFromFloat(idx_f);
        const arr = st.arrays1d[letter];
        if (i < 1 or i > arr.len) return errors.RuntimeError.IndexOutOfBounds;
        arr[i - 1] = val;
    } else if (is_array2d) {
        var rp = expr_mod.Parser.init(allocator, index1_tokens);
        const rnode = try rp.parseExpr();
        const row_f = try expr_mod.evaluate(rnode, st, .{});
        var cp = expr_mod.Parser.init(allocator, index2_tokens);
        const cnode = try cp.parseExpr();
        const col_f = try expr_mod.evaluate(cnode, st, .{});
        const row: usize = @intFromFloat(row_f);
        const col: usize = @intFromFloat(col_f);
        const arr = st.arrays2d[letter];
        if (row < 1 or row > arr.rows or col < 1 or col > arr.cols)
            return errors.RuntimeError.IndexOutOfBounds;
        arr.data[arr.indexOf(row - 1, col - 1)] = val;
    } else {
        st.scalars[letter] = val;
    }
}

fn execAssignment(
    allocator: std.mem.Allocator,
    toks: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const letter = InterpreterState.letterIndex(toks[0].text[0]).?;

    var idx: usize = 1;
    var is_array1d = false;
    var is_array2d = false;
    var is_implicit_1d = false;
    var is_implicit_2d = false;
    var index1_tokens: []lexer.Token = &[_]lexer.Token{};
    var index2_tokens: []lexer.Token = &[_]lexer.Token{};

    if (idx < toks.len and toks[idx].kind == .lbracket) {
        idx += 1;
        const bracket_start = idx;
        var depth: usize = 1;
        var comma_pos: ?usize = null;
        while (idx < toks.len and depth > 0) {
            if (toks[idx].kind == .lbracket) depth += 1;
            if (toks[idx].kind == .rbracket) { depth -= 1; if (depth == 0) break; }
            if (toks[idx].kind == .comma and depth == 1 and comma_pos == null) comma_pos = idx;
            idx += 1;
        }
        if (idx >= toks.len) return errors.ParseError.UnbalancedBrackets;
        const bracket_end = idx;
        idx += 1;

        if (comma_pos) |cp| {
            index1_tokens = toks[bracket_start..cp];
            index2_tokens = toks[cp + 1 .. bracket_end];
            if (index1_tokens.len == 0 and index2_tokens.len == 0) {
                is_implicit_2d = true;
            } else {
                is_array2d = true;
            }
        } else {
            index1_tokens = toks[bracket_start..bracket_end];
            if (index1_tokens.len == 0) {
                is_implicit_1d = true;
            } else {
                is_array1d = true;
            }
        }
    }

    if (idx >= toks.len) return errors.ParseError.InvalidStatement;
    const op = toks[idx].kind;
    idx += 1;

    // Вариант 6: A#$текст — вычислить выражение, хранящееся в строке.
    if (op == .hash) {
        if (is_implicit_1d or is_implicit_2d) return errors.ParseError.InvalidStatement;
        if (idx >= toks.len or toks[idx].kind != .dollar) return errors.ParseError.InvalidStatement;
        idx += 1;
        if (idx >= toks.len) return errors.ParseError.InvalidStatement;
        const ch = dollarTargetChar(toks[idx]) orelse return errors.ParseError.InvalidVariableName;
        const content = try st.resolveStringBytes(ch);
        const val = try evalStringExpression(allocator, content, st);
        try storeAssignedValue(allocator, st, letter, is_array1d, is_array2d, index1_tokens, index2_tokens, val);
        return .next;
    }

    if (op != .equals and op != .colon) return errors.ParseError.InvalidStatement;

    // Вариант 5: A:$?[индекс] — присвоить код символа из строки.
    if (op == .colon and idx < toks.len and toks[idx].kind == .dollar) {
        if (is_implicit_1d or is_implicit_2d) return errors.ParseError.InvalidStatement;
        idx += 1;
        if (idx >= toks.len) return errors.ParseError.InvalidStatement;
        const ch = dollarTargetChar(toks[idx]) orelse return errors.ParseError.InvalidVariableName;
        idx += 1;
        if (idx >= toks.len or toks[idx].kind != .lbracket) return errors.ParseError.InvalidStatement;
        idx += 1;
        const bracket_start = idx;
        var depth: usize = 1;
        while (idx < toks.len and depth > 0) {
            if (toks[idx].kind == .lbracket) depth += 1;
            if (toks[idx].kind == .rbracket) { depth -= 1; if (depth == 0) break; }
            idx += 1;
        }
        if (idx >= toks.len) return errors.ParseError.UnbalancedBrackets;
        const bracket_end = idx;

        var ip = expr_mod.Parser.init(allocator, toks[bracket_start..bracket_end]);
        const inode = try ip.parseExpr();
        const idxf = try expr_mod.evaluate(inode, st, .{});
        if (idxf < 1) return errors.RuntimeError.IndexOutOfBounds;
        const char_index: usize = @intFromFloat(idxf);
        const bytes = try st.resolveStringBytes(ch);
        if (char_index == 0 or char_index > bytes.len) return errors.RuntimeError.IndexOutOfBounds;
        const val: f32 = @floatFromInt(bytes[char_index - 1]);
        try storeAssignedValue(allocator, st, letter, is_array1d, is_array2d, index1_tokens, index2_tokens, val);
        return .next;
    }

    // Варианты 1-4: обычное выражение (= или синоним :).
    const expr_tokens = toks[idx..];

    if (is_implicit_1d) {
        const arr = st.arrays1d[letter];
        if (arr.len == 0) return errors.RuntimeError.ArrayNotSized;
        var i: usize = 0;
        while (i < arr.len) : (i += 1) {
            var parser = expr_mod.Parser.init(allocator, expr_tokens);
            const node = try parser.parseExpr();
            const ctx = expr_mod.LoopContext{ .idx1 = @floatFromInt(i + 1) };
            arr[i] = try expr_mod.evaluate(node, st, ctx);
        }
        return .next;
    }

    if (is_implicit_2d) {
        const arr = st.arrays2d[letter];
        if (arr.rows == 0 or arr.cols == 0) return errors.RuntimeError.ArrayNotSized;
        var r: usize = 0;
        while (r < arr.rows) : (r += 1) {
            var c: usize = 0;
            while (c < arr.cols) : (c += 1) {
                var parser = expr_mod.Parser.init(allocator, expr_tokens);
                const node = try parser.parseExpr();
                const ctx = expr_mod.LoopContext{
                    .idx1 = @floatFromInt(r + 1),
                    .idx2 = @floatFromInt(c + 1),
                };
                arr.data[arr.indexOf(r, c)] = try expr_mod.evaluate(node, st, ctx);
            }
        }
        return .next;
    }

    var parser = expr_mod.Parser.init(allocator, expr_tokens);
    const node = try parser.parseExpr();
    const val = try expr_mod.evaluate(node, st, .{});
    try storeAssignedValue(allocator, st, letter, is_array1d, is_array2d, index1_tokens, index2_tokens, val);
    return .next;
}
