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
    if (first.kind != .identifier) return errors.ParseError.InvalidStatement;

    const name = first.text;

    if (eq(name, "EXIT") or eq(name, "STOP")) {
        return .halt;
    }
    if (eq(name, "MEMC")) {
        if (toks.len == 1) {
            @memset(&st.scalars, 0.0);
            return .next;
        }
        return errors.ParseError.ExtensionNotImplemented;
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
    if (first.kind == .dollar) {
        return errors.ParseError.ExtensionNotImplemented;
    }

    return errors.ParseError.ExtensionNotImplemented;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
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
    if (segment.len == 2 and segment[0].kind == .dollar and segment[1].kind == .number) {
        const idx = std.fmt.parseInt(usize, segment[1].text, 10) catch return errors.ParseError.InvalidVariableName;
        if (idx >= 10) return errors.ParseError.InvalidVariableName;
        stdout.print("{s}", .{st.dynamic_strings[idx].data}) catch {};
        return;
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
    if (segment.len == 2 and segment[0].kind == .dollar and segment[1].kind == .number) {
        const idx = std.fmt.parseInt(usize, segment[1].text, 10) catch return errors.ParseError.InvalidVariableName;
        if (idx >= 10) return errors.ParseError.InvalidVariableName;
        var buf: [1024]u8 = undefined;
        var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &buf);
        const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch "";
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        st.dynamic_strings[idx].set(st.allocator, trimmed) catch return errors.RuntimeError.StringIndexOutOfBounds;
        return;
    }
    return errors.ParseError.ExtensionNotImplemented;
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

    if (idx >= toks.len or toks[idx].kind != .equals) {
        return errors.ParseError.InvalidStatement;
    }
    idx += 1;
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
    return .next;
}