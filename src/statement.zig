//! src/statement.zig
const std = @import("std");
const builtin = @import("builtin");
const lexer = @import("lexer.zig");
const expr_mod = @import("expr.zig");
const state_mod = @import("state.zig");
const program_mod = @import("program.zig");
const errors = @import("errors.zig");
const graphics = @import("graphics.zig");

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

fn resolveStringOperand(tokens: []lexer.Token, st: *InterpreterState) errors.EllochkaError![]const u8 {
    if (tokens.len == 1 and tokens[0].kind == .string_literal) return tokens[0].text;
    if (tokens.len == 2 and tokens[0].kind == .dollar) {
        const ch = dollarTargetChar(tokens[1]) orelse return errors.ParseError.InvalidVariableName;
        return st.resolveStringBytes(ch);
    }
    return errors.ParseError.InvalidStatement;
}

fn formatScalar(buf: []u8, val: f32) []const u8 {
    // Оригинал резервирует один печатный столбец под знак числа: у
    // положительных (и нуля) там пробел, у отрицательных - сам минус.
    // Без этого наш вывод визуально плотнее, но по значению не отличается.
    if (val == @trunc(val) and @abs(val) < 1.0e15) {
        const i: i64 = @intFromFloat(val);
        return if (i < 0)
            std.fmt.bufPrint(buf, "{d}", .{i}) catch ""
        else
            std.fmt.bufPrint(buf, " {d}", .{i}) catch "";
    }
    return if (val < 0)
        std.fmt.bufPrint(buf, "{d}", .{val}) catch ""
    else
        std.fmt.bufPrint(buf, " {d}", .{val}) catch "";
}

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;

const STD_INPUT_HANDLE: i32 = -10;
const ENABLE_LINE_INPUT: u32 = 0x0002;
const ENABLE_ECHO_INPUT: u32 = 0x0004;
const KEY_EVENT: u16 = 0x0001;
const VK_UP: u16 = 0x26;
const VK_DOWN: u16 = 0x28;
const VK_PRIOR: u16 = 0x21;
const VK_NEXT: u16 = 0x22;
const VK_LEFT: u16 = 0x25;
const VK_RIGHT: u16 = 0x27;

const KEY_EVENT_RECORD = extern struct {
    bKeyDown: i32,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    uChar: extern union {
        UnicodeChar: u16,
        AsciiChar: u8,
    },
    dwControlKeyState: u32,
};

const INPUT_RECORD = extern struct {
    EventType: u16,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
    },
};

extern "kernel32" fn GetStdHandle(nStdHandle: i32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: ?*anyopaque, lpMode: *u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: ?*anyopaque, dwMode: u32) callconv(.winapi) i32;
extern "kernel32" fn PeekConsoleInputA(hConsoleInput: ?*anyopaque, lpBuffer: [*]INPUT_RECORD, nLength: u32, lpNumberOfEventsRead: *u32) callconv(.winapi) i32;
extern "kernel32" fn ReadConsoleInputA(hConsoleInput: ?*anyopaque, lpBuffer: [*]INPUT_RECORD, nLength: u32, lpNumberOfEventsRead: *u32) callconv(.winapi) i32;

fn appendDateString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) errors.EllochkaError!void {
    var day: u16 = 1;
    var month: u16 = 1;
    var year: u16 = 1970;
    if (builtin.os.tag == .windows) {
        var st: SYSTEMTIME = undefined;
        GetLocalTime(&st);
        day = st.wDay;
        month = st.wMonth;
        year = st.wYear;
    } else {
        const secs: u64 = @intCast(std.time.timestamp());
        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
        const epoch_day = epoch_secs.getEpochDay();
        const yd = epoch_day.calculateYearDay();
        const md = yd.calculateMonthDay();
        year = yd.year;
        month = @intCast(md.month.numeric());
        day = @as(u16, md.day_index) + 1;
    }
    var tmp: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d:0>2}/{d:0>2}/{d:0>4}", .{ day, month, year }) catch return errors.RuntimeError.MemoryAllocationFailed;
    buf.appendSlice(allocator, s) catch return errors.RuntimeError.MemoryAllocationFailed;
}

fn appendTimeString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) errors.EllochkaError!void {
    var hour: u16 = 0;
    var minute: u16 = 0;
    var second: u16 = 0;
    if (builtin.os.tag == .windows) {
        var st: SYSTEMTIME = undefined;
        GetLocalTime(&st);
        hour = st.wHour;
        minute = st.wMinute;
        second = st.wSecond;
    } else {
        const secs: u64 = @intCast(std.time.timestamp());
        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
        const day_secs = epoch_secs.getDaySeconds();
        hour = day_secs.getHoursIntoDay();
        minute = day_secs.getMinutesIntoHour();
        second = day_secs.getSecondsIntoMinute();
    }
    var tmp: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch return errors.RuntimeError.MemoryAllocationFailed;
    buf.appendSlice(allocator, s) catch return errors.RuntimeError.MemoryAllocationFailed;
}

fn parseArgsInParens(comptime n: usize, seg: []lexer.Token) errors.EllochkaError![n][]lexer.Token {
    if (seg.len < 2 or seg[0].kind != .lparen or seg[seg.len - 1].kind != .rparen) {
        return errors.ParseError.InvalidStatement;
    }
    const inner = seg[1 .. seg.len - 1];
    var parts: [n][]lexer.Token = undefined;
    var start: usize = 0;
    var part_idx: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i <= inner.len) {
        if (i == inner.len or (inner[i].kind == .comma and depth == 0)) {
            if (part_idx >= n) return errors.ParseError.InvalidStatement;
            parts[part_idx] = inner[start..i];
            part_idx += 1;
            start = i + 1;
        } else {
            if (inner[i].kind == .lparen) depth += 1;
            if (inner[i].kind == .rparen) depth -= 1;
        }
        i += 1;
    }
    if (part_idx != n) return errors.ParseError.InvalidStatement;
    return parts;
}

fn splitBySemicolon(comptime n: usize, args: []lexer.Token) errors.EllochkaError![n][]lexer.Token {
    var parts: [n][]lexer.Token = undefined;
    var start: usize = 0;
    var part_idx: usize = 0;
    var i: usize = 0;
    while (i <= args.len) {
        if (i == args.len or args[i].kind == .semicolon) {
            if (part_idx >= n) return errors.ParseError.InvalidStatement;
            parts[part_idx] = args[start..i];
            part_idx += 1;
            start = i + 1;
        }
        i += 1;
    }
    if (part_idx != n) return errors.ParseError.InvalidStatement;
    return parts;
}

fn singleLetterFromTokens(tokens: []lexer.Token) errors.EllochkaError!u8 {
    if (tokens.len != 1 or tokens[0].kind != .identifier or tokens[0].text.len != 1) {
        return errors.ParseError.InvalidStatement;
    }
    return InterpreterState.letterIndex(tokens[0].text[0]) orelse errors.ParseError.InvalidVariableName;
}

fn peekKeyCode() ?f32 {
    if (builtin.os.tag != .windows) return null;
    const handle = GetStdHandle(STD_INPUT_HANDLE);
    var records: [1]INPUT_RECORD = undefined;
    while (true) {
        var peek_count: u32 = 0;
        if (PeekConsoleInputA(handle, &records, 1, &peek_count) == 0 or peek_count == 0) return null;
        var read_count: u32 = 0;
        _ = ReadConsoleInputA(handle, &records, 1, &read_count);
        const rec = records[0];
        if (rec.EventType == KEY_EVENT and rec.Event.KeyEvent.bKeyDown != 0) {
            const ascii = rec.Event.KeyEvent.uChar.AsciiChar;
            if (ascii != 0) return @floatFromInt(ascii);
            return 256.0 + @as(f32, @floatFromInt(rec.Event.KeyEvent.wVirtualKeyCode));
        }
        // не keydown-событие (например, отпускание клавиши) — читаем следующее
    }
}

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

fn blockingReadKeyCode(graphics_mode: bool) f32 {
    if (graphics_mode) {
        while (true) {
            if (graphics.pollKey()) |code| return @floatFromInt(code);
            graphics.pumpMessages();
            if (graphics.shouldForceExit()) return 27.0;
            Sleep(10);
        }
    }

    if (builtin.os.tag != .windows) return 0.0;
    const handle = GetStdHandle(STD_INPUT_HANDLE);
    var original_mode: u32 = 0;
    _ = GetConsoleMode(handle, &original_mode);
    const raw_mode = original_mode & ~ENABLE_LINE_INPUT & ~ENABLE_ECHO_INPUT;
    _ = SetConsoleMode(handle, raw_mode);
    defer _ = SetConsoleMode(handle, original_mode);

    var records: [1]INPUT_RECORD = undefined;
    while (true) {
        var peek_count: u32 = 0;
        if (PeekConsoleInputA(handle, &records, 1, &peek_count) != 0 and peek_count > 0) {
            var read_count: u32 = 0;
            _ = ReadConsoleInputA(handle, &records, 1, &read_count);
            const rec = records[0];
            if (rec.EventType == KEY_EVENT and rec.Event.KeyEvent.bKeyDown != 0) {
                const ascii = rec.Event.KeyEvent.uChar.AsciiChar;
                if (ascii != 0) return @floatFromInt(ascii);
                return 256.0 + @as(f32, @floatFromInt(rec.Event.KeyEvent.wVirtualKeyCode));
            }
            continue;
        }
        graphics.pumpMessages();
        if (graphics.shouldForceExit()) return 27.0;
        Sleep(10);
    }
}


/// Uppercases the character codes that Ellochka receives from WAIT K#.
/// Covers ASCII and Russian Cyrillic without an external Unicode dependency.
fn uppercaseWaitCode(code: f32) f32 {
    var value: u32 = @intFromFloat(code);

    if (value >= 'a' and value <= 'z') {
        value -= 'a' - 'A';
    } else if (value >= 0x0430 and value <= 0x044f) {
        // а..я -> А..Я
        value -= 0x20;
    } else if (value == 0x0451) {
        // ё -> Ё
        value = 0x0401;
    }

    return @floatFromInt(value);
}

const MenuKey = struct { vk: u16, ascii: u16 };

fn readMenuKey(graphics_mode: bool) MenuKey {
    if (graphics_mode) {
        while (true) {
            if (graphics.pollKey()) |code| {
                if (code >= 256) {
                    return .{ .vk = code - 256, .ascii = 0 };
                }
                return .{ .vk = 0, .ascii = code };
            }
            graphics.pumpMessages();
            if (graphics.shouldForceExit()) return .{ .vk = 0, .ascii = 27 };
            Sleep(10);
        }
    }

    if (builtin.os.tag != .windows) return .{ .vk = 0, .ascii = 0 };
    const handle = GetStdHandle(STD_INPUT_HANDLE);
    var original_mode: u32 = 0;
    _ = GetConsoleMode(handle, &original_mode);
    const raw_mode = original_mode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT);
    _ = SetConsoleMode(handle, raw_mode);
    defer _ = SetConsoleMode(handle, original_mode);

    var records: [1]INPUT_RECORD = undefined;
    while (true) {
        var peek_count: u32 = 0;
        if (PeekConsoleInputA(handle, &records, 1, &peek_count) != 0 and peek_count > 0) {
            var read_count: u32 = 0;
            _ = ReadConsoleInputA(handle, &records, 1, &read_count);
            const rec = records[0];
            if (rec.EventType == KEY_EVENT and rec.Event.KeyEvent.bKeyDown != 0) {
                return .{
                    .vk = rec.Event.KeyEvent.wVirtualKeyCode,
                    .ascii = rec.Event.KeyEvent.uChar.AsciiChar,
                };
            }
            continue;
        }
        graphics.pumpMessages();
        if (graphics.shouldForceExit()) return .{ .vk = 0, .ascii = 27 };
        Sleep(10);
    }
}

fn drainPendingInput(graphics_mode: bool) void {
    if (graphics_mode) {
        graphics.clearKeys();
        return;
    }
    if (builtin.os.tag != .windows) return;

    const handle = GetStdHandle(STD_INPUT_HANDLE);
    var records: [16]INPUT_RECORD = undefined;
    while (true) {
        var peek_count: u32 = 0;
        if (PeekConsoleInputA(handle, &records, records.len, &peek_count) == 0 or peek_count == 0) break;
        var read_count: u32 = 0;
        if (ReadConsoleInputA(handle, &records, peek_count, &read_count) == 0) break;
        if (read_count < records.len) break;
    }
}

pub fn execute(allocator: std.mem.Allocator, line: []const u8, st: *InterpreterState, prog: *const Program, stdout: anytype, io: std.Io) errors.EllochkaError!ExecResult {
    if (line.len > 0 and line[0] == '!') {
        if (eq(line, "!nul")) { st.zero_div_mode = .nul; return .next; }
        if (eq(line, "!one")) { st.zero_div_mode = .one; return .next; }
        if (eq(line, "!err")) { st.zero_div_mode = .err; return .next; }
        return .next;
    }
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
    if (eq(name, "DLIN")) {
        return execDlin(toks[1..], st);
    }
    if (eq(name, "FIND")) {
        return execFind(a, toks[1..], st);
    }
    if (eq(name, "KEYS")) {
        return execKeys(toks[1..], st);
    }
    if (eq(name, "WAIT")) {
        return execWait(toks[1..], st);
    }
    if (eq(name, "SUMA")) {
        return execSuma(toks[1..], st);
    }
    if (eq(name, "MINA")) {
        return execMinMax(toks[1..], st, false);
    }
    if (eq(name, "MAXA")) {
        return execMinMax(toks[1..], st, true);
    }
    if (eq(name, "REAK")) {
        return execReak(toks[1..], st);
    }
    if (eq(name, "DATA")) {
        return execData(a, toks[1..], st, prog);
    }
    if (eq(name, "MENU")) {
        return execMenu(a, toks[1..], st, stdout);
    }
    if (eq(name, "LENF")) {
        return execLenf(a, toks[1..], st, io);
    }
    if (eq(name, "UDAL")) {
        return execUdal(a, toks[1..], st, io);
    }
    if (eq(name, "PATH")) {
        return execPath(a, toks[1..], st, io);
    }
    if (eq(name, "FILE")) {
        return execFile(a, toks[1..], st, io);
    }
    if (eq(name, "FREE")) {
        return execFree(a, toks[1..], st);
    }
    if (eq(name, "SORT")) {
        return execSort(a, toks[1..], st);
    }
    if (eq(name, "TYPE")) {
        return execType(a, toks[1..], st, io);
    }
    if (eq(name, "PUTF")) {
        return execPutfGetf(a, toks[1..], st, io, true);
    }
    if (eq(name, "GETF")) {
        return execPutfGetf(a, toks[1..], st, io, false);
    }
    if (eq(name, "GRAF")) {
        return execGraf(st);
    }
    if (eq(name, "TEXT")) {
        // Keep the GDI resources and DIB alive. Subsequent graphics operators
        // may draw into the hidden framebuffer; a later GRAF shows it again.
        graphics.clearKeys();
        st.graphics_mode = false;
        graphics.hideWindow();
        return .next;
    }
    if (eq(name, "PIXL")) {
        return execPixl(a, toks[1..], st);
    }
    if (eq(name, "RDOT")) {
        return execRdot(a, toks[1..], st);
    }
    if (eq(name, "CVET")) {
        return execCvet(a, toks[1..], st);
    }
    if (eq(name, "LINE")) {
        return execLineOp(a, toks[1..], st);
    }
    if (eq(name, "RAMA")) {
        return execRama(a, toks[1..], st);
    }
    if (eq(name, "MOVE")) {
        return execMove(a, toks[1..], st);
    }
    if (eq(name, "KRUG")) {
        return execKrug(a, toks[1..], st);
    }
    if (eq(name, "PAIN")) {
        return execPain(a, toks[1..], st);
    }
    if (eq(name, "SBMP")) {
        return execSbmp(a, toks[1..], st, io);
    }
    if (eq(name, "JULD")) {
        return execJuld(toks[1..], st);
    }
    if (eq(name, "DOSC")) {
        return execDosc(a, toks[1..], st, io);
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
        if (st.graphics_mode) {
            graphics.clearScreen(st.palette[st.current_background_color_index]);
            st.text_row = 1;
            st.text_col = 1;
        } else {
            stdout.print("\x1B[2J\x1B[H", .{}) catch {};
        }
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

    if (eq(name, "READ")) {
        return execRead(a, toks[1..], st, io);
    }
    if (eq(name, "LIRA")) {
        return execLira(a, toks[1..], st);
    }
    if (eq(name, "DTRM")) {
        return execDtrm(a, toks[1..], st);
    }
    if (eq(name, "POLI")) {
        return execPoli(a, toks[1..], st);
    }

    if (eq(name, "APRO")) {
        return execApro(a, toks[1..], st);
    }
    if (eq(name, "NTGR")) {
        return execNtgr(a, toks[1..], st);
    }
    if (eq(name, "TRAN")) {
        return execTran(a, toks[1..], st);
    }

    if (eq(name, "USER")) {
        return execUser(a, toks[1..], st);
    }

    if (name.len == 1 and InterpreterState.letterIndex(name[0]) != null) {
        return execAssignment(a, toks, st);
    }

    return errors.ParseError.ExtensionNotImplemented;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn parseCategoryDigit(tok: lexer.Token) errors.EllochkaError!u8 {
    if (tok.kind != .number) return errors.ParseError.InvalidStatement;
    const val = std.fmt.parseInt(u32, tok.text, 10) catch return errors.ParseError.InvalidStatement;
    if (val > 255) return errors.ParseError.InvalidStatement;
    return @intCast(val);
}

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

fn execKeys(
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const letter = try singleLetterFromTokens(args);
    if (st.graphics_mode) {
        graphics.pumpMessages();
        if (graphics.pollKey()) |code| {
            st.scalars[letter] = @floatFromInt(code);
        } else {
            st.scalars[letter] = 0.0;
        }
    } else {
        st.scalars[letter] = peekKeyCode() orelse 0.0;
    }
    return .next;
}

fn execWait(
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    var target_letter: ?u8 = null;
    var uppercase = false;
    if (args.len >= 1) {
        target_letter = try singleLetterFromTokens(args[0..1]);
        if (args.len >= 2 and args[1].kind == .hash) uppercase = true;
    }

    const code = blockingReadKeyCode(st.graphics_mode);

    if (target_letter) |letter| {
        var final_code = code;
        if (uppercase) final_code = uppercaseWaitCode(code);
        st.scalars[letter] = final_code;
    }
    return .next;
}

const MENU_WIDTH: usize = 40;

fn redrawGraphicsMenu(
    st: *InterpreterState,
    n: usize,
    l: usize,
    s_row: usize,
    c_col: usize,
    selection: usize,
) void {
    const page_index = (selection - 1) / l;
    const page_start = page_index * l + 1;
    const page_end = @min(page_start + l - 1, n);
    const foreground = st.palette[st.current_color_index];
    const background = st.palette[st.current_background_color_index];

    // This is local clearing only: no screen-wide implicit CLSC occurs.
    graphics.clearTextRect(s_row, c_col, l, MENU_WIDTH, background);

    var item = page_start;
    while (item <= page_end) : (item += 1) {
        const row = s_row + item - page_start;
        const bytes = st.static_strings[item - 1][0..st.static_strings_lens[item - 1]];
        const visible = utf8PrefixForCells(bytes, MENU_WIDTH);
        const selected = item == selection;
        graphics.drawMenuRowUtf8(
            row,
            c_col,
            visible,
            MENU_WIDTH,
            if (selected) background else foreground,
            if (selected) foreground else background,
        );
    }
    graphics.present();
}

fn execMenu(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    stdout: anytype,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(5, args);

    var np = expr_mod.Parser.init(allocator, parts[0]);
    const nnode = try np.parseExpr();
    const nval = try expr_mod.evaluate(nnode, st, .{});
    var lp = expr_mod.Parser.init(allocator, parts[1]);
    const lnode = try lp.parseExpr();
    const lval = try expr_mod.evaluate(lnode, st, .{});
    var sp = expr_mod.Parser.init(allocator, parts[2]);
    const snode = try sp.parseExpr();
    const sval = try expr_mod.evaluate(snode, st, .{});
    var cp = expr_mod.Parser.init(allocator, parts[3]);
    const cnode = try cp.parseExpr();
    const cval = try expr_mod.evaluate(cnode, st, .{});
    const f_letter = try singleLetterFromTokens(parts[4]);

    if (nval < 1 or lval < 1) {
        st.scalars[f_letter] = -1.0;
        return .next;
    }

    const n: usize = @intFromFloat(nval);
    const requested_l: usize = @intFromFloat(lval);
    // GDI has exactly 30 physical text rows. The console backend preserves
    // its historical, unbounded L semantics.
    const l: usize = if (st.graphics_mode)
        @min(requested_l, graphics.TEXT_ROWS)
    else
        requested_l;
    const s_row: usize = @intFromFloat(sval);
    const c_col: usize = @intFromFloat(cval);

    if (st.static_strings.len == 0 or n > st.static_strings.len) {
        st.scalars[f_letter] = -1.0;
        return .next;
    }

    const total_pages = (n + l - 1) / l;
    var selection: usize = st.last_menu_selection;
    if (selection < 1 or selection > n) selection = 1;

    var space_buf: [MENU_WIDTH]u8 = undefined;
    @memset(&space_buf, ' ');
    drainPendingInput(st.graphics_mode);

    var result: f32 = 0.0;
    while (true) {
        if (st.graphics_mode) {
            redrawGraphicsMenu(st, n, l, s_row, c_col, selection);
        } else {
            const page_index = (selection - 1) / l;
            const page_start = page_index * l + 1;
            const page_end = @min(page_start + l - 1, n);

            var row = s_row;
            var item = page_start;
            while (item <= page_end) : (item += 1) {
                const bytes = st.static_strings[item - 1][0..st.static_strings_lens[item - 1]];
                stdout.print("\x1B[{d};{d}H", .{ row, c_col }) catch {};
                const is_selected = item == selection;
                if (is_selected) stdout.print("\x1B[7m", .{}) catch {};
                stdout.print("{s}", .{bytes}) catch {};
                if (bytes.len < MENU_WIDTH) {
                    stdout.print("{s}", .{space_buf[0 .. MENU_WIDTH - bytes.len]}) catch {};
                }
                if (is_selected) stdout.print("\x1B[0m", .{}) catch {};
                row += 1;
            }
            stdout.flush() catch {};
        }

        const key = readMenuKey(st.graphics_mode);
        if (key.ascii == 13) {
            result = @floatFromInt(selection);
            break;
        }
        if (key.ascii == 27) {
            result = 0.0;
            break;
        }
        if (key.vk == VK_UP) {
            selection = if (selection <= 1) n else selection - 1;
        } else if (key.vk == VK_DOWN) {
            selection = if (selection >= n) 1 else selection + 1;
        } else if (key.vk == VK_PRIOR) {
            const cur_page = (selection - 1) / l;
            const new_page = if (cur_page == 0) total_pages - 1 else cur_page - 1;
            selection = new_page * l + 1;
        } else if (key.vk == VK_NEXT) {
            const cur_page = (selection - 1) / l;
            const new_page = (cur_page + 1) % total_pages;
            selection = new_page * l + 1;
        }
    }

    st.last_menu_selection = selection;
    st.scalars[f_letter] = result;
    return .next;
}

fn execSuma(
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(2, args);
    const d_letter = try singleLetterFromTokens(parts[0]);
    const s_letter = try singleLetterFromTokens(parts[1]);
    const arr = st.arrays1d[d_letter];
    if (arr.len == 0) return errors.RuntimeError.ArrayNotSized;
    var sum: f32 = 0.0;
    for (arr) |v| sum += v;
    st.scalars[s_letter] = sum;
    return .next;
}

fn execMinMax(
    args: []lexer.Token,
    st: *InterpreterState,
    want_max: bool,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(2, args);
    const d_letter = try singleLetterFromTokens(parts[0]);
    const i_letter = try singleLetterFromTokens(parts[1]);
    const arr = st.arrays1d[d_letter];
    if (arr.len == 0) return errors.RuntimeError.ArrayNotSized;
    var best_idx: usize = 0;
    var best_val = arr[0];
    var i: usize = 1;
    while (i < arr.len) : (i += 1) {
        const v = arr[i];
        const better = if (want_max) v > best_val else v < best_val;
        if (better) {
            best_val = v;
            best_idx = i;
        }
    }
    st.scalars[i_letter] = @floatFromInt(best_idx + 1);
    return .next;
}

fn execData(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    prog: *const Program,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(3, args);
    const a_tokens = parts[0];
    const b_tokens = parts[1];
    const c_tokens = parts[2];

    var ap = expr_mod.Parser.init(allocator, a_tokens);
    const anode = try ap.parseExpr();
    const aval = try expr_mod.evaluate(anode, st, .{});
    var bp = expr_mod.Parser.init(allocator, b_tokens);
    const bnode = try bp.parseExpr();
    const bval = try expr_mod.evaluate(bnode, st, .{});
    if (aval < 1 or bval < aval) return errors.ParseError.InvalidStatement;
    const start_idx: usize = @intFromFloat(aval);
    const end_idx: usize = @intFromFloat(bval);

    var current_line: usize = undefined;
    if (c_tokens.len >= 1 and c_tokens[0].kind == .at) {
        if (c_tokens.len < 2 or c_tokens[1].kind != .identifier) return errors.ParseError.InvalidStatement;
        current_line = prog.resolveLabel(c_tokens[1].text) orelse return errors.RuntimeError.LabelNotFound;
    } else {
        var cp = expr_mod.Parser.init(allocator, c_tokens);
        const cnode = try cp.parseExpr();
        const cval = try expr_mod.evaluate(cnode, st, .{});
        if (cval < 1) return errors.RuntimeError.LineOutOfRange;
        current_line = @intFromFloat(cval);
    }

    var idx = start_idx;
    while (idx <= end_idx) : (idx += 1) {
        if (current_line > prog.lineCount()) return errors.RuntimeError.LineOutOfRange;
        const raw = prog.getLine(current_line) orelse "";
        try st.setStaticStringByIndex(idx, raw);
        current_line += 1;
    }
    return .next;
}

fn execDlin(
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    var semi: ?usize = null;
    for (args, 0..) |t, i| {
        if (t.kind == .semicolon) { semi = i; break; }
    }
    const sep = semi orelse return errors.ParseError.InvalidStatement;
    const p_tokens = args[0..sep];
    const l_tokens = args[sep + 1 ..];
    const bytes = try resolveStringOperand(p_tokens, st);
    const letter = try singleLetterFromTokens(l_tokens);
    st.scalars[letter] = @floatFromInt(bytes.len);
    return .next;
}

fn execFind(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(4, args);
    const p_tokens = parts[0];
    const s_tokens = parts[1];
    const i_tokens = parts[2];
    const n_tokens = parts[3];

    const haystack = try resolveStringOperand(p_tokens, st);

    var ip = expr_mod.Parser.init(allocator, i_tokens);
    const inode = try ip.parseExpr();
    const ival = try expr_mod.evaluate(inode, st, .{});
    if (ival < 1) return errors.RuntimeError.IndexOutOfBounds;
    const start_pos: usize = @intFromFloat(ival);

    const n_letter = try singleLetterFromTokens(n_tokens);

    var found_pos: usize = 0;
    const is_string_mode = s_tokens.len >= 1 and (s_tokens[0].kind == .string_literal or s_tokens[0].kind == .dollar);

    if (start_pos == 0 or start_pos > haystack.len + 1) {
        st.scalars[n_letter] = 0.0;
        return .next;
    }

    if (is_string_mode) {
        const needle = try resolveStringOperand(s_tokens, st);
        if (needle.len > 0 and start_pos - 1 <= haystack.len) {
            const search_area = haystack[start_pos - 1 ..];
            if (std.mem.indexOf(u8, search_area, needle)) |off| {
                found_pos = start_pos + off;
            }
        }
    } else {
        var sp = expr_mod.Parser.init(allocator, s_tokens);
        const snode = try sp.parseExpr();
        const sval = try expr_mod.evaluate(snode, st, .{});
        const code: u8 = @intFromFloat(std.math.clamp(sval, 0.0, 255.0));
        var j: usize = start_pos - 1;
        while (j < haystack.len) : (j += 1) {
            if (haystack[j] == code) { found_pos = j + 1; break; }
        }
    }

    st.scalars[n_letter] = @floatFromInt(found_pos);
    return .next;
}

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
    var op_idx: ?usize = null;
    for (args, 0..) |t, i| {
        switch (t.kind) {
            .gt_gt, .lt_lt, .gt_eq, .lt_eq, .eq_eq, .pipe_eq => { op_idx = i; break; },
            else => {},
        }
    }
    const oi = op_idx orelse return errors.ParseError.InvalidStatement;
    const lhs_tokens = args[0..oi];
    const op = args[oi].kind;
    var idx: usize = oi + 1;

    if (idx < args.len and (args[idx].kind == .lbrace or args[idx].kind == .rbrace)) {
        const inclusive = args[idx].kind == .lbrace;
        const close_kind: lexer.TokenType = if (inclusive) .rbrace else .lbrace;
        idx += 1;
        const range_start = idx;
        var comma_pos: ?usize = null;
        var j = idx;
        while (j < args.len and args[j].kind != close_kind) {
            if (args[j].kind == .comma and comma_pos == null) comma_pos = j;
            j += 1;
        }
        if (j >= args.len or comma_pos == null) return errors.ParseError.InvalidStatement;
        const cp = comma_pos.?;
        const y_tokens = args[range_start..cp];
        const z_tokens = args[cp + 1 .. j];
        idx = j + 1;

        var lp = expr_mod.Parser.init(allocator, lhs_tokens);
        const lnode = try lp.parseExpr();
        const xval = try expr_mod.evaluate(lnode, st, .{});
        var yp = expr_mod.Parser.init(allocator, y_tokens);
        const ynode = try yp.parseExpr();
        const yval = try expr_mod.evaluate(ynode, st, .{});
        var zp = expr_mod.Parser.init(allocator, z_tokens);
        const znode = try zp.parseExpr();
        const zval = try expr_mod.evaluate(znode, st, .{});

        const in_range = if (inclusive) (xval >= yval and xval <= zval) else (xval > yval and xval < zval);
        const cond_true = switch (op) {
            .eq_eq => in_range,
            .pipe_eq => !in_range,
            else => return errors.ParseError.InvalidStatement,
        };

        if (idx < args.len and args[idx].kind == .semicolon) idx += 1;
        const goto_tokens = args[idx..];
        if (!cond_true) return .next;
        return execGoto(allocator, goto_tokens, st, prog);
    }

    const lhs_is_dollar = lhs_tokens.len >= 1 and lhs_tokens[0].kind == .dollar;
    const rhs_is_string = idx < args.len and (args[idx].kind == .string_literal or args[idx].kind == .dollar);

    if (lhs_is_dollar or rhs_is_string) {
        if (op != .eq_eq and op != .pipe_eq) return errors.ParseError.InvalidStatement;
        const lhs_bytes = try resolveStringOperand(lhs_tokens, st);

        var rhs_len: usize = 0;
        if (idx < args.len and args[idx].kind == .string_literal) {
            rhs_len = 1;
        } else if (idx < args.len and args[idx].kind == .dollar) {
            rhs_len = 2;
        } else {
            return errors.ParseError.InvalidStatement;
        }
        const rhs_tokens = args[idx .. idx + rhs_len];
        const rhs_bytes = try resolveStringOperand(rhs_tokens, st);
        idx += rhs_len;

        const are_equal = std.mem.eql(u8, lhs_bytes, rhs_bytes);
        const cond_true = if (op == .eq_eq) are_equal else !are_equal;

        if (idx < args.len and args[idx].kind == .semicolon) idx += 1;
        const goto_tokens = args[idx..];
        if (!cond_true) return .next;
        return execGoto(allocator, goto_tokens, st, prog);
    }

    var lp = expr_mod.Parser.init(allocator, lhs_tokens);
    const lnode = try lp.parseExpr();
    const lval = try expr_mod.evaluate(lnode, st, .{});

    var semi_pos: ?usize = null;
    var k = idx;
    while (k < args.len) {
        if (args[k].kind == .semicolon) { semi_pos = k; break; }
        k += 1;
    }
    const sep = semi_pos orelse return errors.ParseError.InvalidStatement;
    var rp = expr_mod.Parser.init(allocator, args[idx..sep]);
    const rnode = try rp.parseExpr();
    const rval = try expr_mod.evaluate(rnode, st, .{});
    const goto_tokens = args[sep + 1 ..];

    const cond_true = switch (op) {
        .gt_gt => lval > rval,
        .lt_lt => lval < rval,
        .gt_eq => lval >= rval,
        .lt_eq => lval <= rval,
        .eq_eq => lval == rval,
        .pipe_eq => lval != rval,
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
    const requested: i32 = @intFromFloat(val);

    if (eq(name, "CSIM")) {
        const index: u8 = @intCast(std.math.clamp(requested, 0, 15));
        st.current_color_index = index;
        if (!st.graphics_mode) {
            const code: u32 = if (index < 8) 30 + index else 90 + index - 8;
            stdout.print("\x1B[{d}m", .{code}) catch {};
        }
    } else if (eq(name, "CFON")) {
        const index: u8 = @intCast(std.math.clamp(requested, 0, 15));
        st.current_background_color_index = index;
        if (!st.graphics_mode) {
            const code: u32 = 40 + index % 8;
            stdout.print("\x1B[{d}m", .{code}) catch {};
        }
    } else if (eq(name, "STRO")) {
        if (st.graphics_mode) {
            st.text_row = @intCast(std.math.clamp(requested, 1, @as(i32, @intCast(graphics.TEXT_ROWS))));
        } else {
            stdout.print("\x1B[{d};1H", .{requested}) catch {};
        }
    } else if (eq(name, "STLB")) {
        if (st.graphics_mode) {
            st.text_col = @intCast(std.math.clamp(requested, 1, @as(i32, @intCast(graphics.TEXT_COLUMNS))));
        } else {
            stdout.print("\x1B[{d}G", .{requested}) catch {};
        }
    }
    return .next;
}

fn execList(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    stdout: anytype,
) errors.EllochkaError!ExecResult {
   if (st.graphics_mode) return execGraphicsList(allocator, args, st);

    var newline = true;
    var effective_args = args;
    if (args.len > 0 and args[args.len - 1].kind == .backslash) {
        newline = false;
        effective_args = args[0 .. args.len - 1];
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i <= effective_args.len) {
        if (i == effective_args.len or effective_args[i].kind == .semicolon) {
            const segment = effective_args[start..i];
            if (segment.len > 0) {
                try printSegment(allocator, segment, st, stdout);
            }
            start = i + 1;
        }
        i += 1;
    }
    if (newline) stdout.print("\n", .{}) catch {};
    return .next;
}

fn utf8SequenceLength(first: u8) usize {
    if ((first & 0x80) == 0) return 1;
    if ((first & 0xE0) == 0xC0) return 2;
    if ((first & 0xF0) == 0xE0) return 3;
    if ((first & 0xF8) == 0xF0) return 4;
    return 1;
}

fn utf8CellCount(bytes: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const step = @min(utf8SequenceLength(bytes[index]), bytes.len - index);
        index += step;
        count += 1;
    }
    return count;
}

fn utf8PrefixForCells(bytes: []const u8, max_cells: usize) []const u8 {
    var cells: usize = 0;
    var index: usize = 0;
    while (index < bytes.len and cells < max_cells) {
        const step = @min(utf8SequenceLength(bytes[index]), bytes.len - index);
        index += step;
        cells += 1;
    }
    return bytes[0..index];
}

fn execGraphicsList(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    var newline = true;
    var effective_args = args;
    if (args.len > 0 and args[args.len - 1].kind == .backslash) {
        newline = false;
        effective_args = args[0 .. args.len - 1];
    }

    var output: std.ArrayListUnmanaged(u8) = .{};
    var start: usize = 0;
    var index: usize = 0;
    while (index <= effective_args.len) : (index += 1) {
        if (index == effective_args.len or effective_args[index].kind == .semicolon) {
            try appendListSegmentToBuffer(allocator, &output, effective_args[start..index], st);
            start = index + 1;
        }
    }

    const logical_cells = utf8CellCount(output.items);
    if (st.text_col <= graphics.TEXT_COLUMNS) {
        const visible_cells = graphics.TEXT_COLUMNS + 1 - st.text_col;
        const visible = utf8PrefixForCells(output.items, visible_cells);
        graphics.drawTextUtf8(
            st.text_row,
            st.text_col,
            visible,
            st.palette[st.current_color_index],
            st.palette[st.current_background_color_index],
        );
    }

    if (newline) {
        st.text_row += 1;
        st.text_col = 1;
        if (st.text_row > graphics.TEXT_ROWS) {
            graphics.scrollTextRow(st.palette[st.current_background_color_index]);
            st.text_row = graphics.TEXT_ROWS;
        }
    } else {
        // Keep the logical cursor beyond the right border. Subsequent LIST
        // calls ending in '\\' remain clipped until STLB or a newline resets it.
        st.text_col += logical_cells;
    }

    return .next;
}

fn printSegment(allocator: std.mem.Allocator, segment: []lexer.Token, st: *InterpreterState, stdout: anytype) errors.EllochkaError!void {
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
    var buf: [64]u8 = undefined;
    const s = formatScalar(&buf, val);
    stdout.print("{s}", .{s}) catch {};
}

fn execVvod(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    stdout: anytype,
    io: std.Io,
) errors.EllochkaError!ExecResult {
    var effective_args = args;
    if (args.len > 0 and args[args.len - 1].kind == .backslash) {
        effective_args = args[0 .. args.len - 1];
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i <= effective_args.len) {
        if (i == effective_args.len or effective_args[i].kind == .semicolon) {
            const segment = effective_args[start..i];
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
        const bytes = try resolveStringOperand(seg, st);
        buf.appendSlice(allocator, bytes) catch return errors.RuntimeError.MemoryAllocationFailed;
        return;
    }

    if (seg.len >= 2 and seg[0].kind == .percent and seg[1].kind == .identifier) {
        const fname = seg[1].text;
        if (eq(fname, "DATE")) {
            try appendDateString(allocator, buf);
            return;
        }
        if (eq(fname, "TIME")) {
            try appendTimeString(allocator, buf);
            return;
        }
        if (eq(fname, "MID")) {
            const parts = try parseArgsInParens(3, seg[2..]);
            const p_bytes = try resolveStringOperand(parts[0], st);
            var ip = expr_mod.Parser.init(allocator, parts[1]);
            const inode = try ip.parseExpr();
            const ival = try expr_mod.evaluate(inode, st, .{});
            var np = expr_mod.Parser.init(allocator, parts[2]);
            const nnode = try np.parseExpr();
            const nval = try expr_mod.evaluate(nnode, st, .{});

            if (ival < 1) return errors.RuntimeError.IndexOutOfBounds;
            const start_idx: usize = @intFromFloat(ival);
            if (start_idx > p_bytes.len) return errors.RuntimeError.IndexOutOfBounds;
            const count_i: i64 = @intFromFloat(nval);
            const count: usize = if (count_i <= 0) 0 else @intCast(count_i);
            const zig_start = start_idx - 1;
            const zig_end = @min(p_bytes.len, zig_start + count);
            buf.appendSlice(allocator, p_bytes[zig_start..zig_end]) catch return errors.RuntimeError.MemoryAllocationFailed;
            return;
        }
        if (eq(fname, "CHR")) {
            const parts = try parseArgsInParens(2, seg[2..]);
            var np = expr_mod.Parser.init(allocator, parts[0]);
            const nnode = try np.parseExpr();
            const nval = try expr_mod.evaluate(nnode, st, .{});
            var sp = expr_mod.Parser.init(allocator, parts[1]);
            const snode = try sp.parseExpr();
            const sval = try expr_mod.evaluate(snode, st, .{});

            const n_int: i64 = @intFromFloat(nval);
            if (n_int <= 0) return;
            const count: usize = @intCast(n_int);
            const char_code: u8 = @intFromFloat(std.math.clamp(sval, 0.0, 255.0));
            var i: usize = 0;
            while (i < count) : (i += 1) {
                buf.append(allocator, char_code) catch return errors.RuntimeError.MemoryAllocationFailed;
            }
            return;
        }
        return errors.ParseError.ExtensionNotImplemented;
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

fn matchGlob(name: []const u8, mask: []const u8) bool {
    var n_idx: usize = 0;
    var m_idx: usize = 0;
    var backtrack_n: ?usize = null;
    var backtrack_m: ?usize = null;

    while (n_idx < name.len) {
        if (m_idx < mask.len and (mask[m_idx] == '?' or std.ascii.toLower(name[n_idx]) == std.ascii.toLower(mask[m_idx]))) {
            n_idx += 1;
            m_idx += 1;
        } else if (m_idx < mask.len and mask[m_idx] == '*') {
            backtrack_m = m_idx;
            backtrack_n = n_idx;
            m_idx += 1;
        } else if (backtrack_m) |bm| {
            m_idx = bm + 1;
            backtrack_n.? += 1;
            n_idx = backtrack_n.?;
        } else {
            return false;
        }
    }

    while (m_idx < mask.len and mask[m_idx] == '*') : (m_idx += 1) {}
    return m_idx == mask.len;
}

fn writeToDollarTarget(st: *InterpreterState, ch: u8, value: []const u8) errors.EllochkaError!void {
    if (ch >= '0' and ch <= '9') {
        if (value.len > state_mod.MAX_DYNAMIC_STRING_LEN) return errors.RuntimeError.StringTooLong;
        st.dynamic_strings[ch - '0'].set(st.allocator, value) catch return errors.RuntimeError.MemoryAllocationFailed;
    } else {
        try st.setStaticString(ch, value);
    }
}

const SortableString = struct { bytes: [state_mod.STATIC_STRING_LEN]u8, len: u8 };

fn insertionSortStrings(items: []SortableString, descending: bool) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0) {
            const a = items[j - 1];
            const order = std.mem.order(u8, a.bytes[0..a.len], key.bytes[0..key.len]);
            const should_move = if (descending) order == .lt else order == .gt;
            if (!should_move) break;
            items[j] = items[j - 1];
            j -= 1;
        }
        items[j] = key;
    }
}

fn insertionSortFloats(items: []f32, descending: bool) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0) {
            const should_move = if (descending) items[j - 1] < key else items[j - 1] > key;
            if (!should_move) break;
            items[j] = items[j - 1];
            j -= 1;
        }
        items[j] = key;
    }
}

fn execLenf(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    io: std.Io,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(2, args);
    const path_bytes = try resolveStringOperand(parts[0], st);
    const path_copy = allocator.dupe(u8, path_bytes) catch return errors.RuntimeError.MemoryAllocationFailed;
    const l_letter = try singleLetterFromTokens(parts[1]);

    const stat_result = std.Io.Dir.cwd().statFile(io, path_copy, .{}) catch {
        st.scalars[l_letter] = -1.0;
        return .next;
    };
    st.scalars[l_letter] = @floatFromInt(stat_result.size);
    return .next;
}

fn execUdal(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    io: std.Io,
) errors.EllochkaError!ExecResult {
    const path_bytes = try resolveStringOperand(args, st);
    const path_copy = allocator.dupe(u8, path_bytes) catch return errors.RuntimeError.MemoryAllocationFailed;
    std.Io.Dir.cwd().deleteFile(io, path_copy) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return errors.RuntimeError.FileError,
    };
    return .next;
}

fn execPath(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    io: std.Io,
) errors.EllochkaError!ExecResult {
    if (args.len != 2 or args[0].kind != .dollar) return errors.ParseError.InvalidStatement;
    const ch = dollarTargetChar(args[1]) orelse return errors.ParseError.InvalidVariableName;
    const current = try st.resolveStringBytes(ch);
    const current_copy = allocator.dupe(u8, current) catch return errors.RuntimeError.MemoryAllocationFailed;

    const sep_idx = std.mem.lastIndexOfAny(u8, current_copy, "/\\");
    const dir_part: []const u8 = if (sep_idx) |si| current_copy[0 .. si + 1] else ".";

    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, dir_part, allocator) catch {
        try writeToDollarTarget(st, ch, "");
        return .next;
    };

    var final_buf = std.ArrayListUnmanaged(u8){};
    final_buf.appendSlice(allocator, resolved) catch return errors.RuntimeError.MemoryAllocationFailed;
    if (final_buf.items.len == 0 or final_buf.items[final_buf.items.len - 1] != '\\') {
        final_buf.append(allocator, '\\') catch return errors.RuntimeError.MemoryAllocationFailed;
    }
    try writeToDollarTarget(st, ch, final_buf.items);
    return .next;
}

fn execFile(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    io: std.Io,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(2, args);
    const mask_bytes = try resolveStringOperand(parts[0], st);
    const mask_copy = allocator.dupe(u8, mask_bytes) catch return errors.RuntimeError.MemoryAllocationFailed;
    const n_letter = try singleLetterFromTokens(parts[1]);

    if (st.static_strings.len == 0) return errors.RuntimeError.ArrayNotSized;

    const sep_idx = std.mem.lastIndexOfAny(u8, mask_copy, "/\\");
    const dir_path: []const u8 = if (sep_idx) |si| (if (si == 0) "/" else mask_copy[0..si]) else ".";
    const pattern: []const u8 = if (sep_idx) |si| mask_copy[si + 1 ..] else mask_copy;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        st.scalars[n_letter] = -1.0;
        return .next;
    };
    defer dir.close(io);

    var written: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!matchGlob(entry.name, pattern)) continue;
        if (written >= st.static_strings.len) break;
        written += 1;
        try st.setStaticStringByIndex(written, entry.name);
    }
    st.scalars[n_letter] = @floatFromInt(written);
    return .next;
}

extern "kernel32" fn GetDiskFreeSpaceExA(
    lpDirectoryName: ?[*:0]const u8,
    lpFreeBytesAvailable: ?*u64,
    lpTotalNumberOfBytes: ?*u64,
    lpTotalNumberOfFreeBytes: ?*u64,
) callconv(.winapi) i32;

fn execFree(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(2, args);
    var dp = expr_mod.Parser.init(allocator, parts[0]);
    const dnode = try dp.parseExpr();
    const dval = try expr_mod.evaluate(dnode, st, .{});
    const d: i32 = @intFromFloat(dval);
    const l_letter = try singleLetterFromTokens(parts[1]);

    var free_bytes: u64 = 0;
    var ok = false;
    if (builtin.os.tag == .windows) {
        if (d == 0) {
            ok = GetDiskFreeSpaceExA(null, &free_bytes, null, null) != 0;
        } else if (d >= 1 and d <= 26) {
            const letter_char: u8 = @intCast(@as(i32, 'A') + (d - 1));
            var path_buf: [3:0]u8 = .{ letter_char, ':', '\\' };
            ok = GetDiskFreeSpaceExA(&path_buf, &free_bytes, null, null) != 0;
        }
    }
    st.scalars[l_letter] = if (ok) @floatFromInt(free_bytes) else -1.0;
    return .next;
}

fn execSort(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(3, args);
    const target_tokens = parts[0];

    var np = expr_mod.Parser.init(allocator, parts[1]);
    const nnode = try np.parseExpr();
    const nval = try expr_mod.evaluate(nnode, st, .{});
    if (nval < 0) return errors.ParseError.InvalidStatement;
    const count: usize = @intFromFloat(nval);

    var fp = expr_mod.Parser.init(allocator, parts[2]);
    const fnode = try fp.parseExpr();
    const fval = try expr_mod.evaluate(fnode, st, .{});
    const descending = fval < 0;

    const is_whole_array = target_tokens.len >= 1 and target_tokens[0].kind == .dollar and
        (target_tokens.len == 1 or (target_tokens.len == 2 and target_tokens[1].kind == .dollar));

    if (is_whole_array) {
        if (count > st.static_strings.len) return errors.RuntimeError.IndexOutOfBounds;
        var items = allocator.alloc(SortableString, count) catch return errors.RuntimeError.MemoryAllocationFailed;
        for (0..count) |i| items[i] = .{ .bytes = st.static_strings[i], .len = st.static_strings_lens[i] };
        insertionSortStrings(items, descending);
        for (0..count) |i| {
            st.static_strings[i] = items[i].bytes;
            st.static_strings_lens[i] = items[i].len;
        }
        return .next;
    }

    if (target_tokens.len == 1 and target_tokens[0].kind == .identifier and target_tokens[0].text.len == 1) {
        const letter = InterpreterState.letterIndex(target_tokens[0].text[0]) orelse return errors.ParseError.InvalidVariableName;
        const arr = st.arrays1d[letter];
        if (count > arr.len) return errors.RuntimeError.IndexOutOfBounds;
        insertionSortFloats(arr[0..count], descending);
        return .next;
    }

    return errors.ParseError.InvalidStatement;
}

fn appendListSegmentToBuffer(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    segment: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!void {
    if (segment.len == 1 and segment[0].kind == .string_literal) {
        buf.appendSlice(allocator, segment[0].text) catch return errors.RuntimeError.MemoryAllocationFailed;
        return;
    }
    if (segment.len == 2 and segment[0].kind == .dollar) {
        if (dollarTargetChar(segment[1])) |ch| {
            const bytes = try st.resolveStringBytes(ch);
            buf.appendSlice(allocator, bytes) catch return errors.RuntimeError.MemoryAllocationFailed;
            return;
        }
    }
    var parser = expr_mod.Parser.init(allocator, segment);
    const node = try parser.parseExpr();
    const val = try expr_mod.evaluate(node, st, .{});
    var nb: [64]u8 = undefined;
    const s = formatScalar(&nb, val);
    buf.appendSlice(allocator, s) catch return errors.RuntimeError.MemoryAllocationFailed;
}

fn execType(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    io: std.Io,
) errors.EllochkaError!ExecResult {
    var semi_pos: ?usize = null;
    for (args, 0..) |t, i| {
        if (t.kind == .semicolon) { semi_pos = i; break; }
    }
    const sep = semi_pos orelse return errors.ParseError.InvalidStatement;
    const f_tokens = args[0..sep];
    const rest = args[sep + 1 ..];

    const path_bytes = try resolveStringOperand(f_tokens, st);
    const path_copy = allocator.dupe(u8, path_bytes) catch return errors.RuntimeError.MemoryAllocationFailed;

    var buf = std.ArrayListUnmanaged(u8){};

    if (rest.len == 2 and rest[0].kind == .number and rest[1].kind == .identifier and rest[1].text.len == 1) {
        const category = try parseCategoryDigit(rest[0]);
        const letter = InterpreterState.letterIndex(rest[1].text[0]) orelse return errors.ParseError.InvalidVariableName;
        if (category == 1) {
            const arr = st.arrays1d[letter];
            for (arr) |v| {
                var nb: [64]u8 = undefined;
                const s = formatScalar(&nb, v);
                buf.appendSlice(allocator, s) catch return errors.RuntimeError.MemoryAllocationFailed;
                buf.append(allocator, '\n') catch return errors.RuntimeError.MemoryAllocationFailed;
            }
        } else if (category == 2) {
            const arr = st.arrays2d[letter];
            var r: usize = 0;
            while (r < arr.rows) : (r += 1) {
                var c: usize = 0;
                while (c < arr.cols) : (c += 1) {
                    var nb: [64]u8 = undefined;
                    const s = formatScalar(&nb, arr.data[arr.indexOf(r, c)]);
                    buf.appendSlice(allocator, s) catch return errors.RuntimeError.MemoryAllocationFailed;
                    if (c + 1 < arr.cols) buf.append(allocator, '\t') catch return errors.RuntimeError.MemoryAllocationFailed;
                }
                buf.append(allocator, '\n') catch return errors.RuntimeError.MemoryAllocationFailed;
            }
        } else {
            return errors.ParseError.InvalidStatement;
        }
    } else if (rest.len >= 2 and rest[0].kind == .dollar and rest[1].kind == .dollar) {
        var p_val: f32 = 0.0;
        var s_val: f32 = 0.0;
        if (rest.len > 2) {
            var idx: usize = 2;
            if (idx < rest.len and rest[idx].kind == .semicolon) idx += 1;
            var p_semi: ?usize = null;
            var k = idx;
            while (k < rest.len) {
                if (rest[k].kind == .semicolon) { p_semi = k; break; }
                k += 1;
            }
            const p_end = p_semi orelse rest.len;
            if (p_end > idx) {
                var pp = expr_mod.Parser.init(allocator, rest[idx..p_end]);
                const pnode = try pp.parseExpr();
                p_val = try expr_mod.evaluate(pnode, st, .{});
            }
            if (p_semi) |ps| {
                const s_tokens = rest[ps + 1 ..];
                if (s_tokens.len > 0) {
                    var sp = expr_mod.Parser.init(allocator, s_tokens);
                    const snode = try sp.parseExpr();
                    s_val = try expr_mod.evaluate(snode, st, .{});
                }
            }
        }
        const trim_trailing = p_val != 0.0;
        const include_empty = s_val != 0.0;
        for (st.static_strings, 0..) |row, i| {
            const len = st.static_strings_lens[i];
            var line: []const u8 = row[0..len];
            if (trim_trailing) line = std.mem.trimEnd(u8, line, " ");
            if (line.len == 0 and !include_empty) continue;
            buf.appendSlice(allocator, line) catch return errors.RuntimeError.MemoryAllocationFailed;
            buf.append(allocator, '\n') catch return errors.RuntimeError.MemoryAllocationFailed;
        }
    } else {
        // В отличие от LIST/VVOD, TYPE всегда заканчивает запись строки.
        // Оригинальный DIKAR игнорирует завершающий '\' для файла:
        // он не записывается в файл, но CRLF всё равно добавляется.
        var effective_rest = rest;
        if (rest.len > 0 and rest[rest.len - 1].kind == .backslash) {
            effective_rest = rest[0 .. rest.len - 1];
        }

        var start: usize = 0;
        var i: usize = 0;
        while (i <= effective_rest.len) {
            if (i == effective_rest.len or effective_rest[i].kind == .semicolon) {
                const segment = effective_rest[start..i];
                if (segment.len > 0) {
                    try appendListSegmentToBuffer(allocator, &buf, segment, st);
                }
                start = i + 1;
            }
            i += 1;
        }

        // TYPE в оригинале пишет DOS-перевод строки CRLF всегда.
        buf.appendSlice(allocator, "\r\n") catch return errors.RuntimeError.MemoryAllocationFailed;
    }

    var file = std.Io.Dir.cwd().createFile(io, path_copy, .{ .truncate = false, .read = true }) catch return errors.RuntimeError.FileError;
    defer file.close(io);
    const end_pos = file.length(io) catch return errors.RuntimeError.FileError;
    file.writePositionalAll(io, buf.items, end_pos) catch return errors.RuntimeError.FileError;
    return .next;
}

/// Записывает одно числовое значение по смещению pos с шириной d байт.
/// d=1 -> u8 (0..255), d=2 -> u16 (0..65535), d=4 -> f32 (побитово, как раньше).
fn writeValueAt(io: std.Io, file: std.Io.File, pos: usize, val: f32, d: usize) errors.EllochkaError!void {
    switch (d) {
        1 => {
            const clamped = std.math.clamp(val, 0.0, 255.0);
            const byte: u8 = @intFromFloat(clamped);
            file.writePositionalAll(io, &[_]u8{byte}, pos) catch return errors.RuntimeError.FileError;
        },
        2 => {
            const clamped = std.math.clamp(val, 0.0, 65535.0);
            const word: u16 = @intFromFloat(clamped);
            const bytes: [2]u8 = @bitCast(word);
            file.writePositionalAll(io, bytes[0..], pos) catch return errors.RuntimeError.FileError;
        },
        4 => {
            const bytes: [4]u8 = @bitCast(val);
            file.writePositionalAll(io, bytes[0..], pos) catch return errors.RuntimeError.FileError;
        },
        else => return errors.ParseError.ExtensionNotImplemented,
    }
}

/// Читает одно числовое значение по смещению pos с шириной d байт.
/// Обратная операция к writeValueAt.
fn readValueAt(io: std.Io, file: std.Io.File, pos: usize, d: usize) errors.EllochkaError!f32 {
    switch (d) {
        1 => {
            var byte: [1]u8 = undefined;
            const n = file.readPositionalAll(io, byte[0..], pos) catch return errors.RuntimeError.FileError;
            if (n < 1) return errors.RuntimeError.FileError;
            return @floatFromInt(byte[0]);
        },
        2 => {
            var bytes: [2]u8 = undefined;
            const n = file.readPositionalAll(io, bytes[0..], pos) catch return errors.RuntimeError.FileError;
            if (n < 2) return errors.RuntimeError.FileError;
            const word: u16 = @bitCast(bytes);
            return @floatFromInt(word);
        },
        4 => {
            var bytes: [4]u8 = undefined;
            const n = file.readPositionalAll(io, bytes[0..], pos) catch return errors.RuntimeError.FileError;
            if (n < 4) return errors.RuntimeError.FileError;
            return @bitCast(bytes);
        },
        else => return errors.ParseError.ExtensionNotImplemented,
    }
}

fn execPutfGetf(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    io: std.Io,
    is_write: bool,
) errors.EllochkaError!ExecResult {
    var semi_pos: ?usize = null;
    for (args, 0..) |t, i| {
        if (t.kind == .semicolon) { semi_pos = i; break; }
    }
    const sep = semi_pos orelse return errors.ParseError.InvalidStatement;
    const f_tokens = args[0..sep];
    const rest = args[sep + 1 ..];

    const path_bytes = try resolveStringOperand(f_tokens, st);
    const path_copy = allocator.dupe(u8, path_bytes) catch return errors.RuntimeError.MemoryAllocationFailed;

    // Варианты 1M / 2K: F;1;M;D;B;L или F;2;K;D;B;L
    if (rest.len >= 3 and rest[0].kind == .number and rest[1].kind == .identifier and rest[1].text.len == 1 and rest[2].kind == .semicolon) {
        const category = try parseCategoryDigit(rest[0]);
        if (category != 1 and category != 2) return errors.ParseError.ExtensionNotImplemented;
        const letter = InterpreterState.letterIndex(rest[1].text[0]) orelse return errors.ParseError.InvalidVariableName;

        const params = try splitBySemicolon(3, rest[3..]);
        var dp = expr_mod.Parser.init(allocator, params[0]);
        const dnode = try dp.parseExpr();
        const dval = try expr_mod.evaluate(dnode, st, .{});
        const d: usize = @intFromFloat(dval);
        // было: if (d != 4) return errors.ParseError.ExtensionNotImplemented;
        if (d != 1 and d != 2 and d != 4) return errors.ParseError.ExtensionNotImplemented;

        var bp = expr_mod.Parser.init(allocator, params[1]);
        const bnode = try bp.parseExpr();
        const bval = try expr_mod.evaluate(bnode, st, .{});
        const b: usize = @intFromFloat(bval);

        var lp = expr_mod.Parser.init(allocator, params[2]);
        const lnode = try lp.parseExpr();
        const lval = try expr_mod.evaluate(lnode, st, .{});
        const l: usize = @intFromFloat(lval);
        if (l == 0) return errors.ParseError.InvalidStatement;

        var target: []f32 = undefined;
        var count: usize = undefined;
        if (category == 1) {
            count = st.array1d_len;
            target = st.arrays1d[letter];
        } else {
            count = st.array2d_rows * st.array2d_cols;
            target = st.arrays2d[letter].data;
        }
        if (target.len < count) return errors.RuntimeError.ArrayNotSized;

        if (is_write) {
            var file = std.Io.Dir.cwd().createFile(io, path_copy, .{ .truncate = false, .read = true }) catch return errors.RuntimeError.FileError;
            defer file.close(io);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const pos = i * l + b;
                // было: const bytes: [4]u8 = @bitCast(target[i]); file.writePositionalAll(...)
                try writeValueAt(io, file, pos, target[i], d);
            }
        } else {
            var file = std.Io.Dir.cwd().openFile(io, path_copy, .{}) catch return errors.RuntimeError.FileError;
            defer file.close(io);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const pos = i * l + b;
                // было: var bytes: [4]u8 = undefined; ... target[i] = @bitCast(bytes);
                target[i] = try readValueAt(io, file, pos, d);
            }
        }
        return .next;
    }

    // Вариант A: F;A;D;B (простая переменная, без L - шаг не нужен)
    if (rest.len >= 2 and rest[0].kind == .identifier and rest[0].text.len == 1 and rest[1].kind == .semicolon) {
        const letter = InterpreterState.letterIndex(rest[0].text[0]) orelse return errors.ParseError.InvalidVariableName;
        const params = try splitBySemicolon(2, rest[2..]);

        var dp = expr_mod.Parser.init(allocator, params[0]);
        const dnode = try dp.parseExpr();
        const dval = try expr_mod.evaluate(dnode, st, .{});
        const d: usize = @intFromFloat(dval);
        // было: if (d != 4) return errors.ParseError.ExtensionNotImplemented;
        if (d != 1 and d != 2 and d != 4) return errors.ParseError.ExtensionNotImplemented;

        var bp = expr_mod.Parser.init(allocator, params[1]);
        const bnode = try bp.parseExpr();
        const bval = try expr_mod.evaluate(bnode, st, .{});
        const b: usize = @intFromFloat(bval);

        if (is_write) {
            var file = std.Io.Dir.cwd().createFile(io, path_copy, .{ .truncate = false, .read = true }) catch return errors.RuntimeError.FileError;
            defer file.close(io);
            // было: const bytes: [4]u8 = @bitCast(st.scalars[letter]); file.writePositionalAll(...)
            try writeValueAt(io, file, b, st.scalars[letter], d);
        } else {
            var file = std.Io.Dir.cwd().openFile(io, path_copy, .{}) catch return errors.RuntimeError.FileError;
            defer file.close(io);
            // было: var bytes: [4]u8 = undefined; ... st.scalars[letter] = @bitCast(bytes);
            st.scalars[letter] = try readValueAt(io, file, b, d);
        }
        return .next;
    }

    // Вариант со строкой: F;$P;R;B — без изменений
    if (rest.len >= 3 and rest[0].kind == .dollar and rest[1].kind != .dollar and rest[2].kind == .semicolon) {
        const p_ch = dollarTargetChar(rest[1]) orelse return errors.ParseError.InvalidVariableName;
        const params = try splitBySemicolon(2, rest[3..]);

        var rp = expr_mod.Parser.init(allocator, params[0]);
        const rnode = try rp.parseExpr();
        const rval = try expr_mod.evaluate(rnode, st, .{});
        const r: usize = @intFromFloat(rval);

        var bp = expr_mod.Parser.init(allocator, params[1]);
        const bnode = try bp.parseExpr();
        const bval = try expr_mod.evaluate(bnode, st, .{});
        const b: usize = @intFromFloat(bval);

        if (is_write) {
            const content = try st.resolveStringBytes(p_ch);
            const content_copy = allocator.dupe(u8, content) catch return errors.RuntimeError.MemoryAllocationFailed;
            var out_buf = allocator.alloc(u8, r) catch return errors.RuntimeError.MemoryAllocationFailed;
            const take = @min(content_copy.len, r);
            @memcpy(out_buf[0..take], content_copy[0..take]);
            if (r > take) @memset(out_buf[take..r], 0);
            var file = std.Io.Dir.cwd().createFile(io, path_copy, .{ .truncate = false, .read = true }) catch return errors.RuntimeError.FileError;
            defer file.close(io);
            file.writePositionalAll(io, out_buf, b) catch return errors.RuntimeError.FileError;
        } else {
            var in_buf = allocator.alloc(u8, r) catch return errors.RuntimeError.MemoryAllocationFailed;
            var file = std.Io.Dir.cwd().openFile(io, path_copy, .{}) catch return errors.RuntimeError.FileError;
            defer file.close(io);
            const n = file.readPositionalAll(io, in_buf, b) catch return errors.RuntimeError.FileError;
            try writeToDollarTarget(st, p_ch, in_buf[0..n]);
        }
        return .next;
    }

    return errors.ParseError.ExtensionNotImplemented;
}

// ============================================================================
// Группа 4: графика (GRAF/TEXT реальные, PIXL, RDOT, CVET, LINE, RAMA, MOVE,
// KRUG, PAIN, SBMP) — через Win32 GDI, см. src/graphics.zig
// ============================================================================

/// Преобразует логическую координату Y (Эллочка, ось может быть вверх/вниз)
/// в экранный ряд пикселя 0..479 (0 - верх окна).
fn flipY(st: *InterpreterState, y: f32) i32 {
    const yi: i32 = @intFromFloat(y);
    return if (st.ordinate_direction == .up) (graphics.HEIGHT - 1 - yi) else yi;
}

fn currentColorRef(st: *InterpreterState) u32 {
    return st.palette[st.current_color_index];
}

fn colorRefForIndex(st: *InterpreterState, idx_f: f32) u32 {
    var idx: i32 = @intFromFloat(idx_f);
    if (idx < 0) idx = 0;
    if (idx > 15) idx = 15;
    return st.palette[@intCast(idx)];
}

fn execGraf(st: *InterpreterState) errors.EllochkaError!ExecResult {
    // Repeated GRAF in an active graphics mode is a no-op.
    if (st.graphics_mode) return .next;

    if (!graphics.initGraphics()) return errors.RuntimeError.FileError;

    // initGraphics shows an existing hidden window without clearing its DIB.
    graphics.clearKeys();
    st.graphics_mode = true;
    return .next;
}

fn requireGraphics() errors.EllochkaError!void {
    if (!graphics.isInitialized()) return errors.RuntimeError.GraphicsModeNotInitialized;
}

fn execPixl(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    try requireGraphics();
    const parts = try splitBySemicolon(2, args);
    var xp = expr_mod.Parser.init(allocator, parts[0]);
    const xnode = try xp.parseExpr();
    const xval = try expr_mod.evaluate(xnode, st, .{});
    var yp = expr_mod.Parser.init(allocator, parts[1]);
    const ynode = try yp.parseExpr();
    const yval = try expr_mod.evaluate(ynode, st, .{});

    const px: i32 = @intFromFloat(xval);
    const py = flipY(st, yval);
    graphics.setPixel(px, py, currentColorRef(st));
    st.graphics_cursor_x = xval;
    st.graphics_cursor_y = yval;
    return .next;
}

fn execRdot(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    try requireGraphics();
    const parts = try splitBySemicolon(3, args);
    var xp = expr_mod.Parser.init(allocator, parts[0]);
    const xnode = try xp.parseExpr();
    const xval = try expr_mod.evaluate(xnode, st, .{});
    var yp = expr_mod.Parser.init(allocator, parts[1]);
    const ynode = try yp.parseExpr();
    const yval = try expr_mod.evaluate(ynode, st, .{});
    const c_letter = try singleLetterFromTokens(parts[2]);

    const px: i32 = @intFromFloat(xval);
    const py = flipY(st, yval);
    const raw = graphics.getPixel(px, py);

    var found: f32 = 0.0;
    for (st.palette, 0..) |entry, i| {
        if (entry == raw) {
            found = @floatFromInt(i);
            break;
        }
    }
    st.scalars[c_letter] = found;
    return .next;
}

fn execCvet(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    if (args.len == 0) {
        st.palette = state_mod.DEFAULT_PALETTE;
        return .next;
    }
    const parts = try splitBySemicolon(4, args);
    var cp = expr_mod.Parser.init(allocator, parts[0]);
    const cnode = try cp.parseExpr();
    const cval = try expr_mod.evaluate(cnode, st, .{});
    var rp = expr_mod.Parser.init(allocator, parts[1]);
    const rnode = try rp.parseExpr();
    const rval = try expr_mod.evaluate(rnode, st, .{});
    var gp = expr_mod.Parser.init(allocator, parts[2]);
    const gnode = try gp.parseExpr();
    const gval = try expr_mod.evaluate(gnode, st, .{});
    var bp = expr_mod.Parser.init(allocator, parts[3]);
    const bnode = try bp.parseExpr();
    const bval = try expr_mod.evaluate(bnode, st, .{});

    var idx: i32 = @intFromFloat(cval);
    if (idx < 0) idx = 0;
    if (idx > 15) idx = 15;
    const r: u32 = @intFromFloat(std.math.clamp(rval, 0.0, 63.0));
    const g: u32 = @intFromFloat(std.math.clamp(gval, 0.0, 63.0));
    const b: u32 = @intFromFloat(std.math.clamp(bval, 0.0, 63.0));
    const r255 = (r * 255) / 63;
    const g255 = (g * 255) / 63;
    const b255 = (b * 255) / 63;
    const palette_index: usize = @intCast(idx);
    const old_color = st.palette[palette_index];
    const new_color = b255 << 16 | g255 << 8 | r255;

    st.palette[palette_index] = new_color;

    // DOS CVET меняет цвет уже нарисованных пикселей соответствующего
    // палитрового индекса. Сейчас DIB хранит RGB, поэтому обновляем
    // существующее изображение явно.
    if (graphics.isInitialized()) {
        graphics.replacePaletteColor(old_color, new_color);
    }

    return .next;
}

fn execLineOp(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    try requireGraphics();
    const parts = try splitBySemicolon(4, args);
    var xp1 = expr_mod.Parser.init(allocator, parts[0]);
    const x1v = try expr_mod.evaluate(try xp1.parseExpr(), st, .{});
    var yp1 = expr_mod.Parser.init(allocator, parts[1]);
    const y1v = try expr_mod.evaluate(try yp1.parseExpr(), st, .{});
    var xp2 = expr_mod.Parser.init(allocator, parts[2]);
    const x2v = try expr_mod.evaluate(try xp2.parseExpr(), st, .{});
    var yp2 = expr_mod.Parser.init(allocator, parts[3]);
    const y2v = try expr_mod.evaluate(try yp2.parseExpr(), st, .{});

    graphics.drawLine(@intFromFloat(x1v), flipY(st, y1v), @intFromFloat(x2v), flipY(st, y2v), currentColorRef(st));
    st.graphics_cursor_x = x2v;
    st.graphics_cursor_y = y2v;
    return .next;
}

fn execRama(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    try requireGraphics();
    const parts = try splitBySemicolon(4, args);
    var xp1 = expr_mod.Parser.init(allocator, parts[0]);
    const x1v = try expr_mod.evaluate(try xp1.parseExpr(), st, .{});
    var yp1 = expr_mod.Parser.init(allocator, parts[1]);
    const y1v = try expr_mod.evaluate(try yp1.parseExpr(), st, .{});
    var xp2 = expr_mod.Parser.init(allocator, parts[2]);
    const x2v = try expr_mod.evaluate(try xp2.parseExpr(), st, .{});
    var yp2 = expr_mod.Parser.init(allocator, parts[3]);
    const y2v = try expr_mod.evaluate(try yp2.parseExpr(), st, .{});

    graphics.drawRect(@intFromFloat(x1v), flipY(st, y1v), @intFromFloat(x2v), flipY(st, y2v), currentColorRef(st));
    return .next;
}

fn execMove(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    try requireGraphics();
    const parts = try splitBySemicolon(2, args);
    var xp = expr_mod.Parser.init(allocator, parts[0]);
    const dx = try expr_mod.evaluate(try xp.parseExpr(), st, .{});
    var yp = expr_mod.Parser.init(allocator, parts[1]);
    const dy = try expr_mod.evaluate(try yp.parseExpr(), st, .{});

    const old_x = st.graphics_cursor_x;
    const old_y = st.graphics_cursor_y;
    const new_x = old_x + dx;
    const new_y = old_y + dy;

    graphics.drawLine(
        @intFromFloat(old_x),
        flipY(st, old_y),
        @intFromFloat(new_x),
        flipY(st, new_y),
        currentColorRef(st),
    );
    st.graphics_cursor_x = new_x;
    st.graphics_cursor_y = new_y;
    return .next;
}

fn execKrug(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    try requireGraphics();
    const parts = try splitBySemicolon(4, args);
    var xp = expr_mod.Parser.init(allocator, parts[0]);
    const xv = try expr_mod.evaluate(try xp.parseExpr(), st, .{});
    var yp = expr_mod.Parser.init(allocator, parts[1]);
    const yv = try expr_mod.evaluate(try yp.parseExpr(), st, .{});
    var rp = expr_mod.Parser.init(allocator, parts[2]);
    const rv = try expr_mod.evaluate(try rp.parseExpr(), st, .{});
    var ap = expr_mod.Parser.init(allocator, parts[3]);
    const av = try expr_mod.evaluate(try ap.parseExpr(), st, .{});

    const cx: i32 = @intFromFloat(xv);
    const cy = flipY(st, yv);
    const rx: i32 = @intFromFloat(rv);
    const ry: i32 = @intFromFloat(rv * av);
    graphics.drawEllipse(cx, cy, rx, ry, currentColorRef(st));
    return .next;
}

fn execPain(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    try requireGraphics();
    const parts = try splitBySemicolon(3, args);
    var xp = expr_mod.Parser.init(allocator, parts[0]);
    const xv = try expr_mod.evaluate(try xp.parseExpr(), st, .{});
    var yp = expr_mod.Parser.init(allocator, parts[1]);
    const yv = try expr_mod.evaluate(try yp.parseExpr(), st, .{});
    var gp = expr_mod.Parser.init(allocator, parts[2]);
    const gv = try expr_mod.evaluate(try gp.parseExpr(), st, .{});

    const px: i32 = @intFromFloat(xv);
    const py = flipY(st, yv);
    graphics.floodFill(px, py, currentColorRef(st), colorRefForIndex(st, gv));
    return .next;
}

fn execSbmp(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    io: std.Io,
) errors.EllochkaError!ExecResult {
    try requireGraphics();
    const raw_path = try resolveStringOperand(args, st);
    var path_buf = std.ArrayListUnmanaged(u8){};
    path_buf.appendSlice(allocator, raw_path) catch return errors.RuntimeError.MemoryAllocationFailed;
    if (!std.ascii.endsWithIgnoreCase(path_buf.items, ".bmp")) {
        path_buf.appendSlice(allocator, ".bmp") catch return errors.RuntimeError.MemoryAllocationFailed;
    }
    graphics.saveBmp(io, path_buf.items) catch return errors.RuntimeError.FileError;
    return .next;
}

fn reakModel(x: f64, a: f64, b: f64, c: f64) f64 {
    return a * std.math.pow(f64, x, b) * @exp(-c * x);
}

/// Решает систему 3x3 методом Гаусса с выбором главного элемента.
/// Возвращает null, если матрица вырождена (нужно увеличить демпфирование).
fn solve3x3(mat_in: [3][4]f64) ?[3]f64 {
    var m = mat_in;
    var pivot_row_idx: usize = 0;
    while (pivot_row_idx < 3) : (pivot_row_idx += 1) {
        var best_row = pivot_row_idx;
        var best_val = @abs(m[pivot_row_idx][pivot_row_idx]);
        var scan_row = pivot_row_idx + 1;
        while (scan_row < 3) : (scan_row += 1) {
            const v = @abs(m[scan_row][pivot_row_idx]);
            if (v > best_val) {
                best_val = v;
                best_row = scan_row;
            }
        }
        if (best_val < 1e-12) return null;
        if (best_row != pivot_row_idx) {
            const tmp = m[pivot_row_idx];
            m[pivot_row_idx] = m[best_row];
            m[best_row] = tmp;
        }
        var elim_row = pivot_row_idx + 1;
        while (elim_row < 3) : (elim_row += 1) {
            const factor = m[elim_row][pivot_row_idx] / m[pivot_row_idx][pivot_row_idx];
            var col_idx = pivot_row_idx;
            while (col_idx < 4) : (col_idx += 1) {
                m[elim_row][col_idx] -= factor * m[pivot_row_idx][col_idx];
            }
        }
    }
    var x: [3]f64 = undefined;
    var back_idx: i64 = 2;
    while (back_idx >= 0) : (back_idx -= 1) {
        const idx: usize = @intCast(back_idx);
        var sum = m[idx][3];
        var col_idx = idx + 1;
        while (col_idx < 3) : (col_idx += 1) {
            sum -= m[idx][col_idx] * x[col_idx];
        }
        x[idx] = sum / m[idx][idx];
        if (back_idx == 0) break;
    }
    return x;
}

/// REAK X;Y;A;B;C;R;F
/// Нелинейная регрессия функцией реакции Y = A*X^B*exp(-C*X) методом
/// Гаусса-Ньютона с демпфированием (Levenberg-Marquardt). A,B,C на входе
/// - начальное приближение, на выходе - уточнённые коэффициенты. R -
/// коэффициент корреляции Пирсона (факт/модель), F - RMSE остатков.
fn execReak(
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(7, args);
    const x_letter = try singleLetterFromTokens(parts[0]);
    const y_letter = try singleLetterFromTokens(parts[1]);
    const a_letter = try singleLetterFromTokens(parts[2]);
    const b_letter = try singleLetterFromTokens(parts[3]);
    const c_letter = try singleLetterFromTokens(parts[4]);
    const r_letter = try singleLetterFromTokens(parts[5]);
    const f_letter = try singleLetterFromTokens(parts[6]);

    const xs = st.arrays1d[x_letter];
    const ys = st.arrays1d[y_letter];
    if (xs.len == 0 or ys.len == 0) return errors.RuntimeError.ArrayNotSized;
    if (xs.len != ys.len) return errors.ParseError.InvalidStatement;
    const m = xs.len;

    for (xs) |xv| {
        if (xv <= 0) return errors.RuntimeError.MathDomainError;
    }

    var a: f64 = st.scalars[a_letter];
    var b: f64 = st.scalars[b_letter];
    var c: f64 = st.scalars[c_letter];
    if (@abs(a) < 1e-6) a = 0.01;

    var lambda: f64 = 1.0e-3;

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        var jtj: [3][3]f64 = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } };
        var jtr: [3]f64 = .{ 0, 0, 0 };
        var sse: f64 = 0.0;

        {
            var i: usize = 0;
            while (i < m) : (i += 1) {
                const xv: f64 = xs[i];
                const yv: f64 = ys[i];
                const fv = reakModel(xv, a, b, c);
                const resid = yv - fv;
                sse += resid * resid;

                const grads = [3]f64{ fv / a, fv * @log(xv), -fv * xv };

                var p_row: usize = 0;
                while (p_row < 3) : (p_row += 1) {
                    jtr[p_row] += grads[p_row] * resid;
                    var p_col: usize = 0;
                    while (p_col < 3) : (p_col += 1) {
                        jtj[p_row][p_col] += grads[p_row] * grads[p_col];
                    }
                }
            }
        }

        var mat: [3][4]f64 = undefined;
        {
            var aug_row: usize = 0;
            while (aug_row < 3) : (aug_row += 1) {
                var aug_col: usize = 0;
                while (aug_col < 3) : (aug_col += 1) {
                    mat[aug_row][aug_col] = jtj[aug_row][aug_col];
                    if (aug_row == aug_col) mat[aug_row][aug_col] += lambda * jtj[aug_row][aug_col];
                }
                mat[aug_row][3] = jtr[aug_row];
            }
        }

        const delta = solve3x3(mat) orelse {
            lambda *= 4.0;
            if (lambda > 1e12) break;
            continue;
        };

        const new_a = a + delta[0];
        const new_b = b + delta[1];
        const new_c = c + delta[2];

        var new_sse: f64 = 0.0;
        {
            var j: usize = 0;
            while (j < m) : (j += 1) {
                const resid = ys[j] - reakModel(xs[j], new_a, new_b, new_c);
                new_sse += resid * resid;
            }
        }

        if (new_sse < sse) {
            const converged = @abs(sse - new_sse) < 1e-6;
            a = new_a;
            b = new_b;
            c = new_c;
            lambda = @max(lambda / 3.0, 1e-12);
            if (converged) break;
        } else {
            lambda *= 4.0;
            if (lambda > 1e12) break;
        }
    }

    st.scalars[a_letter] = @floatCast(a);
    st.scalars[b_letter] = @floatCast(b);
    st.scalars[c_letter] = @floatCast(c);

    var sum_y: f64 = 0.0;
    var sum_yhat: f64 = 0.0;
    {
        var idx2: usize = 0;
        while (idx2 < m) : (idx2 += 1) {
            sum_y += ys[idx2];
            sum_yhat += reakModel(xs[idx2], a, b, c);
        }
    }
    const m_f: f64 = @floatFromInt(m);
    const mean_y = sum_y / m_f;
    const mean_yhat = sum_yhat / m_f;

    var cov: f64 = 0.0;
    var var_y: f64 = 0.0;
    var var_yhat: f64 = 0.0;
    var sse_final: f64 = 0.0;
    {
        var idx3: usize = 0;
        while (idx3 < m) : (idx3 += 1) {
            const yhat = reakModel(xs[idx3], a, b, c);
            const dy = ys[idx3] - mean_y;
            const dyh = yhat - mean_yhat;
            cov += dy * dyh;
            var_y += dy * dy;
            var_yhat += dyh * dyh;
            const resid = ys[idx3] - yhat;
            sse_final += resid * resid;
        }
    }

    const denom = @sqrt(var_y * var_yhat);
    const r: f64 = if (denom > 1e-12) cov / denom else 0.0;
    const rmse: f64 = @sqrt(sse_final / m_f);

    st.scalars[r_letter] = @floatCast(r);
    st.scalars[f_letter] = @floatCast(rmse);

    return .next;
}

fn dosJuldLeapYear(year: i32) bool {
    // Базовый 1900 год в DOS-модели не получает 29 февраля.
    // После него DOS считает високосным любой год, кратный 4.
    return year != 1900 and @mod(year, 4) == 0;
}

fn dosJuldDaysInMonth(month: i32, year: i32) i32 {
    return switch (month) {
        1 => 31,
        2 => if (dosJuldLeapYear(year)) 29 else 28,
        3 => 31,
        4 => 30,
        5 => 31,
        6 => 30,
        7 => 31,
        8 => 31,
        9 => 30,
        10 => 31,
        11 => 30,
        12 => 31,
        else => 0,
    };
}

/// JULD D;M;Y;J — преобразование даты и номера дня.
///
/// Строгая совместимость с DOS:
/// - начиная с 01.03.1900 используется DOS-календарь;
/// - DOS считает все годы после 1900, кратные 4, високосными;
/// - дата -> J сохраняет JDN - 0.5;
/// - целый J -> D + 0.5.
fn execJuld(
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(4, args);
    const d_letter = try singleLetterFromTokens(parts[0]);
    const m_letter = try singleLetterFromTokens(parts[1]);
    const y_letter = try singleLetterFromTokens(parts[2]);
    const j_letter = try singleLetterFromTokens(parts[3]);

    const j_val = st.scalars[j_letter];

    // Начало DOS-календаря: 01.03.1900.
    // Его стандартный JDN равен 2415080.
    const dos_base_jdn: i32 = 2415080;

    if (@abs(j_val) < 1e-6) {
        const d: i32 = @intFromFloat(st.scalars[d_letter]);
        const m: i32 = @intFromFloat(st.scalars[m_letter]);
        const y: i32 = @intFromFloat(st.scalars[y_letter]);

        const use_dos_calendar = y > 1900 or (y == 1900 and m >= 3);

        if (use_dos_calendar) {
            // Число дней от 01.03.1900 до заданной даты.
            var days: i32 = 0;

            var year: i32 = 1900;
            while (year < y) : (year += 1) {
                days += if (dosJuldLeapYear(year)) 366 else 365;
            }

            var month: i32 = 1;
            while (month < m) : (month += 1) {
                days += dosJuldDaysInMonth(month, y);
            }

            days += d - 1;

            // В 1900 до 01.03 находятся 31 + 28 = 59 дней.
            days -= 59;

            const jdn = dos_base_jdn + days;

            st.scalars[j_letter] = @floatFromInt(jdn);
            st.scalars[j_letter] -= 0.5;
        } else {
            // Fallback для дат до 01.03.1900:
            // прежняя григорианская формула.
            const a = @divTrunc(m - 14, 12);
            const jdn = d - 32075 +
                @divTrunc(1461 * (y + 4800 + a), 4) +
                @divTrunc(367 * (m - 2 - 12 * a), 12) -
                @divTrunc(3 * @divTrunc(y + 4900 + a, 100), 4);

            st.scalars[j_letter] = @floatFromInt(jdn);
            st.scalars[j_letter] -= 0.5;
        }
    } else {
        // JDN-0.5 — нормальный результат прямой DOS-ветки.
        // Для календарного расчёта его нужно вернуть к целому номеру дня.
        const is_dos_half = @abs((j_val - @floor(j_val)) - 0.5) < 1e-6;
        const j: i32 = @intFromFloat(
            if (is_dos_half) j_val + 0.5 else j_val,
        );

        if (j >= dos_base_jdn) {
            // Обратное преобразование в DOS-календаре.
            //
            // Прибавляем 59, так как отсчёт ведётся от 01.03.1900,
            // но месяцы ниже перебираются от января.
            var remaining: i32 = j - dos_base_jdn + 59;
            var out_y: i32 = 1900;

            while (true) {
                const year_days: i32 = if (dosJuldLeapYear(out_y)) 366 else 365;
                if (remaining < year_days) break;

                remaining -= year_days;
                out_y += 1;
            }

            var out_m: i32 = 1;
            while (true) {
                const month_days = dosJuldDaysInMonth(out_m, out_y);
                if (remaining < month_days) break;

                remaining -= month_days;
                out_m += 1;
            }

            const out_d = remaining + 1;

            st.scalars[d_letter] = @floatFromInt(out_d);

            // В DOS целый J возвращает дробный день D+0.5.
            // Значение JDN-0.5, полученное прямой веткой, возвращает целый D.
            if (!is_dos_half) {
                st.scalars[d_letter] += 0.5;
            }

            st.scalars[m_letter] = @floatFromInt(out_m);
            st.scalars[y_letter] = @floatFromInt(out_y);
        } else {
            // Fallback для JDN раньше 01.03.1900.
            const l0 = j + 68569;
            const n = @divTrunc(4 * l0, 146097);
            const l1 = l0 - @divTrunc(146097 * n + 3, 4);
            const y1 = @divTrunc(4000 * (l1 + 1), 1461001);
            const l2 = l1 - @divTrunc(1461 * y1, 4) + 31;
            const m1 = @divTrunc(80 * l2, 2447);

            const out_d = l2 - @divTrunc(2447 * m1, 80);
            const l3 = @divTrunc(m1, 11);
            const out_m = m1 + 2 - 12 * l3;
            const out_y = 100 * (n - 49) + y1 + l3;

            st.scalars[d_letter] = @floatFromInt(out_d);

            if (!is_dos_half) {
                st.scalars[d_letter] += 0.5;
            }

            st.scalars[m_letter] = @floatFromInt(out_m);
            st.scalars[y_letter] = @floatFromInt(out_y);
        }
    }

    return .next;
}

/// DOSC P - выполнить команду P во внешней оболочке (cmd.exe /C),
/// синхронно, с наследованием stdin/stdout/stderr от процесса
/// Эллочки (вывод команды идёт прямо в ту же консоль). Без песочницы
/// и без кода возврата - строго по исторической спецификации DOSC.
fn execDosc(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    io: std.Io,
) errors.EllochkaError!ExecResult {
    const cmd_bytes = try resolveStringOperand(args, st);
    if (cmd_bytes.len == 0) return .next;
    const cmd_copy = allocator.dupe(u8, cmd_bytes) catch return errors.RuntimeError.MemoryAllocationFailed;

    var child = std.process.Child.init(&[_][]const u8{ "cmd.exe", "/C", cmd_copy }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    _ = child.spawnAndWait(io) catch return errors.RuntimeError.FileError;
    return .next;
}

/// READ F;X;Y  - читает пары чисел из текстового файла (разделители:
///               пробел/таб/запятая) в массивы X,Y, по одной паре на
///               строку файла, пока не кончится файл или не заполнятся
///               оба массива. Строки без двух валидных чисел тихо
///               пропускаются (без увеличения индекса).
/// READ F;2;K  - то же самое, но построчно заполняет 2D-массив K:
///               каждая строка файла -> одна строка матрицы.
/// READ F      - читает строки файла прямо в строковый массив $$.
/// Во всех формах отсутствие файла или ошибка чтения не прерывают
/// выполнение программы - операция просто ничего не делает дальше.
fn execRead(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
    io: std.Io,
) errors.EllochkaError!ExecResult {
    var semi_pos: ?usize = null;
    for (args, 0..) |t, i| {
        if (t.kind == .semicolon) {
            semi_pos = i;
            break;
        }
    }

    const path_tokens = if (semi_pos) |sep| args[0..sep] else args;
    const path_bytes = try resolveStringOperand(path_tokens, st);
    const path_copy = allocator.dupe(u8, path_bytes) catch return errors.RuntimeError.MemoryAllocationFailed;

    var file = std.Io.Dir.cwd().openFile(io, path_copy, .{}) catch return .next;
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader: std.Io.File.Reader = .init(file, io, &read_buf);
    const content = file_reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024)) catch return .next;

    // READ F (без параметров) - строки файла прямо в $$
    if (semi_pos == null) {
        if (st.static_strings.len == 0) return .next;
        var lines_it = std.mem.splitScalar(u8, content, '\n');
        var idx: usize = 0;
        while (idx < st.static_strings.len) {
            const raw_line = lines_it.next() orelse break;
            const trimmed = std.mem.trimEnd(u8, raw_line, "\r");
            idx += 1;
            try st.setStaticStringByIndex(idx, trimmed);
        }
        return .next;
    }

    const sep = semi_pos.?;
    const rest = args[sep + 1 ..];

    // Форма READ F;2K (компактная запись: цифра категории и буква
    // массива слитно, без ; между ними - как в PUTF/GETF "1M"/"2K")
    if (rest.len == 2 and rest[0].kind == .number and rest[1].kind == .identifier and rest[1].text.len == 1) {
        const category = try parseCategoryDigit(rest[0]);
        if (category != 2) return errors.ParseError.ExtensionNotImplemented;
        const k_letter = InterpreterState.letterIndex(rest[1].text[0]) orelse return errors.ParseError.InvalidVariableName;

        const arr = st.arrays2d[k_letter];
        if (arr.rows == 0 or arr.cols == 0) return errors.RuntimeError.ArrayNotSized;

        const row_vals = allocator.alloc(f32, arr.cols) catch return errors.RuntimeError.MemoryAllocationFailed;

        var lines_it = std.mem.splitScalar(u8, content, '\n');
        var row: usize = 0;
        while (row < arr.rows) {
            const raw_line = lines_it.next() orelse break;
            const trimmed = std.mem.trim(u8, raw_line, " \r\t");
            if (trimmed.len == 0) continue;

            var toks_it = std.mem.tokenizeAny(u8, trimmed, " \t,");
            var row_ok = true;
            var col: usize = 0;
            while (col < arr.cols) : (col += 1) {
                const tok = toks_it.next() orelse {
                    row_ok = false;
                    break;
                };
                row_vals[col] = std.fmt.parseFloat(f32, tok) catch {
                    row_ok = false;
                    break;
                };
            }
            if (!row_ok) continue;

            var c: usize = 0;
            while (c < arr.cols) : (c += 1) {
                arr.data[arr.indexOf(row, c)] = row_vals[c];
            }
            row += 1;
        }
        return .next;
    }

    // Форма READ F;X;Y (два отдельных 1D-массива через ;)
    const xy_parts = try splitBySemicolon(2, rest);
    const x_letter = try singleLetterFromTokens(xy_parts[0]);
    const y_letter = try singleLetterFromTokens(xy_parts[1]);
    const xs = st.arrays1d[x_letter];
    const ys = st.arrays1d[y_letter];
    const max_len = @min(xs.len, ys.len);
    if (max_len == 0) return errors.RuntimeError.ArrayNotSized;

    var lines_it = std.mem.splitScalar(u8, content, '\n');
    var i: usize = 0;
    while (i < max_len) {
        const raw_line = lines_it.next() orelse break;
        const trimmed = std.mem.trim(u8, raw_line, " \r\t");
        if (trimmed.len == 0) continue;

        var toks_it = std.mem.tokenizeAny(u8, trimmed, " \t,");
        const tok1 = toks_it.next() orelse continue;
        const tok2 = toks_it.next() orelse continue;
        const val1 = std.fmt.parseFloat(f32, tok1) catch continue;
        const val2 = std.fmt.parseFloat(f32, tok2) catch continue;

        xs[i] = val1;
        ys[i] = val2;
        i += 1;
    }

    return .next;
}

/// LIRA X;A - решение СЛАУ методом Гаусса с pivoting.
/// A - расширенная матрица N x (N+1) (коэффициенты + правая часть в
/// последнем столбце), X - 1D-массив длины N, куда пишется решение.
fn execLira(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(2, args);
    const x_letter = try singleLetterFromTokens(parts[0]);
    const a_letter = try singleLetterFromTokens(parts[1]);

    const xs = st.arrays1d[x_letter];
    const n = xs.len;
    if (n == 0) return errors.RuntimeError.ArrayNotSized;

    const mat2d = st.arrays2d[a_letter];
    if (mat2d.rows != n or mat2d.cols != n + 1) return errors.ParseError.InvalidStatement;

    var m = allocator.alloc([]f64, n) catch return errors.RuntimeError.MemoryAllocationFailed;
    for (0..n) |r| {
        m[r] = allocator.alloc(f64, n + 1) catch return errors.RuntimeError.MemoryAllocationFailed;
        for (0..n + 1) |c| {
            m[r][c] = mat2d.data[mat2d.indexOf(r, c)];
        }
    }

    var row: usize = 0;
    while (row < n) : (row += 1) {
        var pivot_row = row;
        var pivot_val = @abs(m[row][row]);
        var scan = row + 1;
        while (scan < n) : (scan += 1) {
            if (@abs(m[scan][row]) > pivot_val) {
                pivot_val = @abs(m[scan][row]);
                pivot_row = scan;
            }
        }
        if (pivot_val < 1e-9) return errors.RuntimeError.MathDomainError;
        if (pivot_row != row) {
            const tmp = m[row];
            m[row] = m[pivot_row];
            m[pivot_row] = tmp;
        }
        var elim = row + 1;
        while (elim < n) : (elim += 1) {
            const factor = m[elim][row] / m[row][row];
            var col = row;
            while (col < n + 1) : (col += 1) {
                m[elim][col] -= factor * m[row][col];
            }
        }
    }

    var sol = allocator.alloc(f64, n) catch return errors.RuntimeError.MemoryAllocationFailed;
    var i: i64 = @as(i64, @intCast(n)) - 1;
    while (i >= 0) : (i -= 1) {
        const idx: usize = @intCast(i);
        var sum = m[idx][n];
        var j = idx + 1;
        while (j < n) : (j += 1) {
            sum -= m[idx][j] * sol[j];
        }
        sol[idx] = sum / m[idx][idx];
        if (i == 0) break;
    }

    for (0..n) |k| {
        xs[k] = @floatCast(sol[k]);
    }

    return .next;
}

/// DTRM M;N;D - определитель N x N подматрицы M методом Гаусса.
/// Вырождение -> D=0 (валидный результат, не ошибка), знак определителя
/// учитывает перестановки строк при pivoting.
fn execDtrm(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(3, args);
    const m_letter = try singleLetterFromTokens(parts[0]);

    var np = expr_mod.Parser.init(allocator, parts[1]);
    const nnode = try np.parseExpr();
    const nval = try expr_mod.evaluate(nnode, st, .{});
    const n: usize = @intFromFloat(nval);
    if (n == 0) return errors.ParseError.InvalidStatement;

    const d_letter = try singleLetterFromTokens(parts[2]);

    const mat2d = st.arrays2d[m_letter];
    if (mat2d.rows < n or mat2d.cols < n) return errors.RuntimeError.ArrayNotSized;

    var m = allocator.alloc([]f64, n) catch return errors.RuntimeError.MemoryAllocationFailed;
    for (0..n) |r| {
        m[r] = allocator.alloc(f64, n) catch return errors.RuntimeError.MemoryAllocationFailed;
        for (0..n) |c| {
            m[r][c] = mat2d.data[mat2d.indexOf(r, c)];
        }
    }

    var sign: f64 = 1.0;
    var det: f64 = 1.0;
    var singular = false;

    var row: usize = 0;
    while (row < n) : (row += 1) {
        var pivot_row = row;
        var pivot_val = @abs(m[row][row]);
        var scan = row + 1;
        while (scan < n) : (scan += 1) {
            if (@abs(m[scan][row]) > pivot_val) {
                pivot_val = @abs(m[scan][row]);
                pivot_row = scan;
            }
        }
        if (pivot_val < 1e-9) {
            singular = true;
            break;
        }
        if (pivot_row != row) {
            const tmp = m[row];
            m[row] = m[pivot_row];
            m[pivot_row] = tmp;
            sign = -sign;
        }
        det *= m[row][row];
        var elim = row + 1;
        while (elim < n) : (elim += 1) {
            const factor = m[elim][row] / m[row][row];
            var col = row;
            while (col < n) : (col += 1) {
                m[elim][col] -= factor * m[row][col];
            }
        }
    }

    const result: f64 = if (singular) 0.0 else det * sign;
    st.scalars[d_letter] = @floatCast(result);

    return .next;
}

/// POLI X;P;M;Y - значение полинома степени M в точке X по схеме
/// Горнера. P[1..M+1] по возрастанию степени (P[1] - свободный член).
fn execPoli(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(4, args);

    var xp = expr_mod.Parser.init(allocator, parts[0]);
    const xnode = try xp.parseExpr();
    const x_val_f32 = try expr_mod.evaluate(xnode, st, .{});
    const x_val: f64 = @floatCast(x_val_f32);

    const p_letter = try singleLetterFromTokens(parts[1]);

    var mp = expr_mod.Parser.init(allocator, parts[2]);
    const mnode = try mp.parseExpr();
    const mval = try expr_mod.evaluate(mnode, st, .{});
    const degree: usize = @intFromFloat(mval);

    const y_letter = try singleLetterFromTokens(parts[3]);

    const coeffs = st.arrays1d[p_letter];
    if (coeffs.len < degree + 1) return errors.RuntimeError.ArrayNotSized;

    var result: f64 = @floatCast(coeffs[degree]);
    var i: i64 = @as(i64, @intCast(degree)) - 1;
    while (i >= 0) : (i -= 1) {
        const idx: usize = @intCast(i);
        result = result * x_val + @as(f64, @floatCast(coeffs[idx]));
        if (i == 0) break;
    }

    st.scalars[y_letter] = @floatCast(result);
    return .next;
}

/// Решает СЛАУ n x n методом Гаусса с выбором главного элемента.
/// m - расширенная матрица n x (n+1) (последний столбец - правая
/// часть), возвращает вектор решения длины n. Ошибка при вырождении.
fn solveLinearSystemF64(
    allocator: std.mem.Allocator,
    n: usize,
    m: [][]f64,
) errors.EllochkaError![]f64 {
    var row: usize = 0;
    while (row < n) : (row += 1) {
        var pivot_row = row;
        var pivot_val = @abs(m[row][row]);
        var scan = row + 1;
        while (scan < n) : (scan += 1) {
            if (@abs(m[scan][row]) > pivot_val) {
                pivot_val = @abs(m[scan][row]);
                pivot_row = scan;
            }
        }
        if (pivot_val < 1e-9) return errors.RuntimeError.MathDomainError;
        if (pivot_row != row) {
            const tmp = m[row];
            m[row] = m[pivot_row];
            m[pivot_row] = tmp;
        }
        var elim = row + 1;
        while (elim < n) : (elim += 1) {
            const factor = m[elim][row] / m[row][row];
            var col = row;
            while (col < n + 1) : (col += 1) {
                m[elim][col] -= factor * m[row][col];
            }
        }
    }

    var sol = allocator.alloc(f64, n) catch return errors.RuntimeError.MemoryAllocationFailed;
    var i: i64 = @as(i64, @intCast(n)) - 1;
    while (i >= 0) : (i -= 1) {
        const idx: usize = @intCast(i);
        var sum = m[idx][n];
        var j = idx + 1;
        while (j < n) : (j += 1) {
            sum -= m[idx][j] * sol[j];
        }
        sol[idx] = sum / m[idx][idx];
        if (i == 0) break;
    }
    return sol;
}

/// APRO X;Y;P;M;K;S - полиномиальная МНК-аппроксимация степени M.
/// P[1..M+1] по возрастанию степени (как в POLI). K - корреляция
/// Пирсона (факт/модель), S - RMSE, как в REAK.
fn execApro(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(6, args);
    const x_letter = try singleLetterFromTokens(parts[0]);
    const y_letter = try singleLetterFromTokens(parts[1]);
    const p_letter = try singleLetterFromTokens(parts[2]);

    var mp = expr_mod.Parser.init(allocator, parts[3]);
    const mnode = try mp.parseExpr();
    const mval = try expr_mod.evaluate(mnode, st, .{});
    const degree: usize = @intFromFloat(mval);
    const num_coefs = degree + 1;

    const k_letter = try singleLetterFromTokens(parts[4]);
    const s_letter = try singleLetterFromTokens(parts[5]);

    const xs = st.arrays1d[x_letter];
    const ys = st.arrays1d[y_letter];
    if (xs.len == 0 or ys.len == 0) return errors.RuntimeError.ArrayNotSized;
    if (xs.len != ys.len) return errors.ParseError.InvalidStatement;
    const m_points = xs.len;
    if (m_points < num_coefs) return errors.RuntimeError.MathDomainError;

    const ps = st.arrays1d[p_letter];
    if (ps.len < num_coefs) return errors.RuntimeError.ArrayNotSized;

    // Кэшируем степени X_i от 0 до 2*degree, чтобы не звать pow лишний раз
    const max_pow = 2 * degree;
    var powers = allocator.alloc([]f64, m_points) catch return errors.RuntimeError.MemoryAllocationFailed;
    for (0..m_points) |i| {
        powers[i] = allocator.alloc(f64, max_pow + 1) catch return errors.RuntimeError.MemoryAllocationFailed;
        powers[i][0] = 1.0;
        const xv: f64 = @floatCast(xs[i]);
        var p: usize = 1;
        while (p <= max_pow) : (p += 1) {
            powers[i][p] = powers[i][p - 1] * xv;
        }
    }

    var mat = allocator.alloc([]f64, num_coefs) catch return errors.RuntimeError.MemoryAllocationFailed;
    for (0..num_coefs) |r| {
        mat[r] = allocator.alloc(f64, num_coefs + 1) catch return errors.RuntimeError.MemoryAllocationFailed;
        for (0..num_coefs) |c| {
            var sum_x: f64 = 0.0;
            for (0..m_points) |i| sum_x += powers[i][r + c];
            mat[r][c] = sum_x;
        }
        var sum_yx: f64 = 0.0;
        for (0..m_points) |i| sum_yx += @as(f64, @floatCast(ys[i])) * powers[i][r];
        mat[r][num_coefs] = sum_yx;
    }

    const sol = try solveLinearSystemF64(allocator, num_coefs, mat);
    for (0..num_coefs) |j| ps[j] = @floatCast(sol[j]);

    var sum_y: f64 = 0.0;
    var sum_yhat: f64 = 0.0;
    var yhat_vals = allocator.alloc(f64, m_points) catch return errors.RuntimeError.MemoryAllocationFailed;
    for (0..m_points) |i| {
        var yhat: f64 = 0.0;
        for (0..num_coefs) |j| yhat += sol[j] * powers[i][j];
        yhat_vals[i] = yhat;
        sum_y += @as(f64, @floatCast(ys[i]));
        sum_yhat += yhat;
    }
    const m_f: f64 = @floatFromInt(m_points);
    const mean_y = sum_y / m_f;
    const mean_yhat = sum_yhat / m_f;

    var cov: f64 = 0.0;
    var var_y: f64 = 0.0;
    var var_yhat: f64 = 0.0;
    var sse: f64 = 0.0;
    for (0..m_points) |i| {
        const dy = @as(f64, @floatCast(ys[i])) - mean_y;
        const dyh = yhat_vals[i] - mean_yhat;
        cov += dy * dyh;
        var_y += dy * dy;
        var_yhat += dyh * dyh;
        const resid = @as(f64, @floatCast(ys[i])) - yhat_vals[i];
        sse += resid * resid;
    }
    const denom = @sqrt(var_y * var_yhat);
    const k_val: f64 = if (denom > 1e-12) cov / denom else 0.0;
    const s_val: f64 = @sqrt(sse / m_f);

    st.scalars[k_letter] = @floatCast(k_val);
    st.scalars[s_letter] = @floatCast(s_val);

    return .next;
}

/// NTGR F;A;B;N;Y - определённый интеграл методом трапеций.
/// F - текстовая переменная/константа с выражением относительно X.
fn execNtgr(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(5, args);
    const content = try resolveStringOperand(parts[0], st);

    var ap = expr_mod.Parser.init(allocator, parts[1]);
    const anode = try ap.parseExpr();
    const a_val = try expr_mod.evaluate(anode, st, .{});

    var bp = expr_mod.Parser.init(allocator, parts[2]);
    const bnode = try bp.parseExpr();
    const b_val = try expr_mod.evaluate(bnode, st, .{});

    var np = expr_mod.Parser.init(allocator, parts[3]);
    const nnode = try np.parseExpr();
    const nval = try expr_mod.evaluate(nnode, st, .{});

    const y_letter = try singleLetterFromTokens(parts[4]);

    if (a_val > b_val) return errors.RuntimeError.MathDomainError;
    if (a_val == b_val) {
        st.scalars[y_letter] = 0.0;
        return .next;
    }

    const n_int: i64 = @intFromFloat(nval);
    if (n_int <= 0) return errors.RuntimeError.MathDomainError;
    const n: usize = @intCast(n_int);

    const x_letter = InterpreterState.letterIndex('X') orelse unreachable;
    const h: f64 = (@as(f64, @floatCast(b_val)) - @as(f64, @floatCast(a_val))) / @as(f64, @floatFromInt(n));
    const a64: f64 = @floatCast(a_val);
    const b64: f64 = @floatCast(b_val);

    st.scalars[x_letter] = @floatCast(a64);
    const f_a: f64 = @floatCast(try evalStringExpression(allocator, content, st));
    st.scalars[x_letter] = @floatCast(b64);
    const f_b: f64 = @floatCast(try evalStringExpression(allocator, content, st));

    var sum: f64 = (f_a + f_b) / 2.0;

    var i: usize = 1;
    while (i < n) : (i += 1) {
        const xi = a64 + @as(f64, @floatFromInt(i)) * h;
        st.scalars[x_letter] = @floatCast(xi);
        const fi: f64 = @floatCast(try evalStringExpression(allocator, content, st));
        sum += fi;
    }

    const result = sum * h;
    st.scalars[y_letter] = @floatCast(result);

    return .next;
}

/// TRAN X;N;E;T;U - решение системы N нелинейных уравнений (N от 1
/// до 9, тексты в $1..$N) методом Ньютона с численным Якобианом и
/// backtracking line search (дробление шага при отсутствии убывания
/// нормы невязок). X - массив неизвестных (вход: начальное
/// приближение, выход: решение). T - остаток итераций (вход: лимит).
/// U - 0 при успехе, иначе количество неудовлетворённых уравнений
/// (в этом случае T=0).
fn execTran(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(5, args);
    const x_letter = try singleLetterFromTokens(parts[0]);

    var np = expr_mod.Parser.init(allocator, parts[1]);
    const nnode = try np.parseExpr();
    const nval = try expr_mod.evaluate(nnode, st, .{});
    if (nval < 1 or nval > 9) return errors.RuntimeError.MathDomainError;
    const n: usize = @intFromFloat(nval);

    var ep = expr_mod.Parser.init(allocator, parts[2]);
    const enode = try ep.parseExpr();
    const e_val_f32 = try expr_mod.evaluate(enode, st, .{});
    const e_val: f64 = @floatCast(e_val_f32);

    const t_letter = try singleLetterFromTokens(parts[3]);
    const u_letter = try singleLetterFromTokens(parts[4]);

    const max_iter: usize = @intFromFloat(st.scalars[t_letter]);

    const xs = st.arrays1d[x_letter];
    if (xs.len < n) return errors.RuntimeError.ArrayNotSized;

    var x_cur = allocator.alloc(f64, n) catch return errors.RuntimeError.MemoryAllocationFailed;
    for (0..n) |i| x_cur[i] = @floatCast(xs[i]);

    var eq_texts = allocator.alloc([]const u8, n) catch return errors.RuntimeError.MemoryAllocationFailed;
    for (0..n) |i| {
        const ch: u8 = '1' + @as(u8, @intCast(i));
        eq_texts[i] = try st.resolveStringBytes(ch);
    }

    var f_vec = allocator.alloc(f64, n) catch return errors.RuntimeError.MemoryAllocationFailed;

    for (xs, 0..) |*v, i| {
        if (i < n) v.* = @floatCast(x_cur[i]);
    }
    for (0..n) |r| {
        const val = try evalStringExpression(allocator, eq_texts[r], st);
        f_vec[r] = @floatCast(val);
    }

    var iterations_used: usize = 0;
    var converged = false;

    while (iterations_used < max_iter) {
        var max_abs: f64 = 0.0;
        for (f_vec) |v| max_abs = @max(max_abs, @abs(v));
        if (max_abs < e_val) {
            converged = true;
            break;
        }

        var jac = allocator.alloc([]f64, n) catch return errors.RuntimeError.MemoryAllocationFailed;
        for (0..n) |r| jac[r] = allocator.alloc(f64, n + 1) catch return errors.RuntimeError.MemoryAllocationFailed;

        for (0..n) |j| {
            const orig = x_cur[j];
            const h = @max(1e-4, 1e-4 * @abs(orig));
            x_cur[j] = orig + h;
            for (xs, 0..) |*v, i| {
                if (i < n) v.* = @floatCast(x_cur[i]);
            }

            for (0..n) |r| {
                const val = try evalStringExpression(allocator, eq_texts[r], st);
                jac[r][j] = (@as(f64, @floatCast(val)) - f_vec[r]) / h;
            }

            x_cur[j] = orig;
        }
        for (xs, 0..) |*v, i| {
            if (i < n) v.* = @floatCast(x_cur[i]);
        }

        for (0..n) |r| jac[r][n] = -f_vec[r];

        const delta = solveLinearSystemF64(allocator, n, jac) catch |err| {
            if (err != errors.RuntimeError.MathDomainError) return err;
            var bad_count: usize = 0;
            for (f_vec) |v| {
                if (@abs(v) >= e_val) bad_count += 1;
            }
            st.scalars[u_letter] = @floatFromInt(bad_count);
            st.scalars[t_letter] = 0.0;
            return .next;
        };

        var new_x = allocator.alloc(f64, n) catch return errors.RuntimeError.MemoryAllocationFailed;
        var new_f = allocator.alloc(f64, n) catch return errors.RuntimeError.MemoryAllocationFailed;
        var old_norm: f64 = 0.0;
        for (f_vec) |v| old_norm += v * v;

        var step: f64 = 1.0;
        var accepted = false;
        var attempt: usize = 0;
        while (attempt < 20) : (attempt += 1) {
            for (0..n) |k| new_x[k] = x_cur[k] + step * delta[k];
            for (xs, 0..) |*v, i| {
                if (i < n) v.* = @floatCast(new_x[i]);
            }
            var new_norm: f64 = 0.0;
            for (0..n) |r| {
                const val = try evalStringExpression(allocator, eq_texts[r], st);
                new_f[r] = @floatCast(val);
                new_norm += new_f[r] * new_f[r];
            }
            if (new_norm < old_norm) {
                accepted = true;
                break;
            }
            step /= 2.0;
        }

        if (!accepted) {
            for (xs, 0..) |*v, i| {
                if (i < n) v.* = @floatCast(x_cur[i]);
            }
            var bad_count: usize = 0;
            for (f_vec) |v| {
                if (@abs(v) >= e_val) bad_count += 1;
            }
            st.scalars[u_letter] = @floatFromInt(bad_count);
            st.scalars[t_letter] = 0.0;
            return .next;
        }

        @memcpy(x_cur, new_x);
        @memcpy(f_vec, new_f);
        for (xs, 0..) |*v, i| {
            if (i < n) v.* = @floatCast(x_cur[i]);
        }
        iterations_used += 1;
    }

    if (converged) {
        st.scalars[u_letter] = 0.0;
        const remaining: usize = if (max_iter > iterations_used) max_iter - iterations_used else 0;
        st.scalars[t_letter] = @floatFromInt(remaining);
    } else {
        var bad_count: usize = 0;
        for (f_vec) |v| {
            if (@abs(v) >= e_val) bad_count += 1;
        }
        st.scalars[u_letter] = @floatFromInt(bad_count);
        st.scalars[t_letter] = 0.0;
    }

    return .next;
}

/// USER F;M;E;T - аппроксимация данных (массивы X,Y - фиксированные
/// имена) произвольной моделью, заданной выражением в F относительно
/// X и A[1..M]. Левенберг-Марквардт с численным Якобианом по каждому
/// параметру A[j] (метод, шаг дифференцирования - как в TRAN).
/// E - вход: порог относительного изменения RMSE; выход: финальный
/// RMSE. T - вход: лимит итераций; выход: остаток (0 при неудаче).
fn execUser(
    allocator: std.mem.Allocator,
    args: []lexer.Token,
    st: *InterpreterState,
) errors.EllochkaError!ExecResult {
    const parts = try splitBySemicolon(4, args);
    const content = try resolveStringOperand(parts[0], st);

    const m_letter = try singleLetterFromTokens(parts[1]);
    const e_letter = try singleLetterFromTokens(parts[2]);
    const t_letter = try singleLetterFromTokens(parts[3]);

    const m_count: usize = @intFromFloat(st.scalars[m_letter]);
    if (m_count == 0) return errors.ParseError.InvalidStatement;

    const e_tol: f64 = @floatCast(st.scalars[e_letter]);
    const max_iter: usize = @intFromFloat(st.scalars[t_letter]);

    const x_letter = InterpreterState.letterIndex('X') orelse unreachable;
    const y_letter = InterpreterState.letterIndex('Y') orelse unreachable;
    const a_letter = InterpreterState.letterIndex('A') orelse unreachable;

    const xs = st.arrays1d[x_letter];
    const ys = st.arrays1d[y_letter];
    if (xs.len == 0 or ys.len == 0) return errors.RuntimeError.ArrayNotSized;
    if (xs.len != ys.len) return errors.ParseError.InvalidStatement;
    const points_len = xs.len;
    if (points_len < m_count) return errors.RuntimeError.MathDomainError;

    const coefs = st.arrays1d[a_letter];
    if (coefs.len < m_count) return errors.RuntimeError.ArrayNotSized;

    var a_cur = allocator.alloc(f64, m_count) catch return errors.RuntimeError.MemoryAllocationFailed;
    for (0..m_count) |j| a_cur[j] = @floatCast(coefs[j]);

    var f_vals = allocator.alloc(f64, points_len) catch return errors.RuntimeError.MemoryAllocationFailed;

    for (0..points_len) |i| {
        st.scalars[x_letter] = xs[i];
        const val = try evalStringExpression(allocator, content, st);
        f_vals[i] = @floatCast(val);
    }

    var sse: f64 = 0.0;
    for (0..points_len) |i| {
        const resid = @as(f64, @floatCast(ys[i])) - f_vals[i];
        sse += resid * resid;
    }
    var rmse: f64 = @sqrt(sse / @as(f64, @floatFromInt(points_len)));

    var lambda: f64 = 1e-3;
    var iterations_used: usize = 0;
    var converged = false;

    while (iterations_used < max_iter) {
        var jac = allocator.alloc([]f64, points_len) catch return errors.RuntimeError.MemoryAllocationFailed;
        for (0..points_len) |i| jac[i] = allocator.alloc(f64, m_count) catch return errors.RuntimeError.MemoryAllocationFailed;

        for (0..m_count) |j| {
            const orig = a_cur[j];
            const h = @max(1e-4, 1e-4 * @abs(orig));
            a_cur[j] = orig + h;
            for (coefs, 0..) |*v, jj| {
                if (jj < m_count) v.* = @floatCast(a_cur[jj]);
            }

            for (0..points_len) |i| {
                st.scalars[x_letter] = xs[i];
                const val = try evalStringExpression(allocator, content, st);
                jac[i][j] = (@as(f64, @floatCast(val)) - f_vals[i]) / h;
            }
            a_cur[j] = orig;
        }
        for (coefs, 0..) |*v, jj| {
            if (jj < m_count) v.* = @floatCast(a_cur[jj]);
        }

        var jtj = allocator.alloc([]f64, m_count) catch return errors.RuntimeError.MemoryAllocationFailed;
        for (0..m_count) |r| jtj[r] = allocator.alloc(f64, m_count + 1) catch return errors.RuntimeError.MemoryAllocationFailed;

        for (0..m_count) |r| {
            for (0..m_count) |c| {
                var sum_val: f64 = 0.0;
                for (0..points_len) |i| sum_val += jac[i][r] * jac[i][c];
                jtj[r][c] = sum_val;
                if (r == c) jtj[r][c] += lambda * sum_val;
            }
            var sum_res: f64 = 0.0;
            for (0..points_len) |i| {
                const resid = @as(f64, @floatCast(ys[i])) - f_vals[i];
                sum_res += jac[i][r] * resid;
            }
            jtj[r][m_count] = sum_res;
        }

        const delta = solveLinearSystemF64(allocator, m_count, jtj) catch |err| {
            if (err != errors.RuntimeError.MathDomainError) return err;
            lambda *= 4.0;
            iterations_used += 1;
            if (lambda > 1e12) break;
            continue;
        };

        var a_new = allocator.alloc(f64, m_count) catch return errors.RuntimeError.MemoryAllocationFailed;
        for (0..m_count) |j| a_new[j] = a_cur[j] + delta[j];

        for (coefs, 0..) |*v, jj| {
            if (jj < m_count) v.* = @floatCast(a_new[jj]);
        }
        var f_new = allocator.alloc(f64, points_len) catch return errors.RuntimeError.MemoryAllocationFailed;
        var new_sse: f64 = 0.0;
        for (0..points_len) |i| {
            st.scalars[x_letter] = xs[i];
            const val = try evalStringExpression(allocator, content, st);
            f_new[i] = @floatCast(val);
            const resid = @as(f64, @floatCast(ys[i])) - f_new[i];
            new_sse += resid * resid;
        }
        const new_rmse = @sqrt(new_sse / @as(f64, @floatFromInt(points_len)));

        iterations_used += 1;

        if (new_sse < sse) {
            const rel_change = if (rmse > 1e-12) @abs(rmse - new_rmse) / rmse else @abs(rmse - new_rmse);
            a_cur = a_new;
            f_vals = f_new;
            sse = new_sse;
            rmse = new_rmse;
            lambda = @max(lambda / 3.0, 1e-12);
            for (coefs, 0..) |*v, jj| {
                if (jj < m_count) v.* = @floatCast(a_cur[jj]);
            }
            if (rel_change < e_tol) {
                converged = true;
                break;
            }
        } else {
            for (coefs, 0..) |*v, jj| {
                if (jj < m_count) v.* = @floatCast(a_cur[jj]);
            }
            lambda *= 4.0;
            if (lambda > 1e12) break;
        }
    }

    for (coefs, 0..) |*v, jj| {
        if (jj < m_count) v.* = @floatCast(a_cur[jj]);
    }

    st.scalars[e_letter] = @floatCast(rmse);
    const remaining: usize = if (converged and max_iter > iterations_used) max_iter - iterations_used else 0;
    st.scalars[t_letter] = @floatFromInt(remaining);

    return .next;
}