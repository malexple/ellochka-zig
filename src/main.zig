//! src/main.zig
const std = @import("std");
const builtin = @import("builtin");
const state_mod = @import("state.zig");
const program_mod = @import("program.zig");
const statement_mod = @import("statement.zig");
const errors = @import("errors.zig");
const graphics = @import("graphics.zig");

/// Включает интерпретацию ANSI/VT escape-последовательностей (\x1B[...)
/// для стандартного вывода в консоли Windows.
fn enableAnsiEscapes() void {
    if (builtin.os.tag != .windows) return;
    const windows = std.os.windows;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;

    const handle = windows.kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse return;
    if (handle == windows.INVALID_HANDLE_VALUE) return;

    var mode: windows.DWORD = undefined;
    if (windows.kernel32.GetConsoleMode(handle, &mode) == 0) return;

    _ = windows.kernel32.SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
}

/// Переключает кодовую страницу консоли Windows на UTF-8 (65001).
fn enableUtf8Console() void {
    if (builtin.os.tag != .windows) return;
    const kernel32 = struct {
        extern "kernel32" fn SetConsoleOutputCP(wCodePageID: c_uint) callconv(.winapi) c_int;
        extern "kernel32" fn SetConsoleCP(wCodePageID: c_uint) callconv(.winapi) c_int;
    };
    const CP_UTF8: c_uint = 65001;
    _ = kernel32.SetConsoleOutputCP(CP_UTF8);
    _ = kernel32.SetConsoleCP(CP_UTF8);
}

/// Основная логика интерпретатора. Возвращает код завершения процесса:
/// 0 — программа успешно доработала до EXIT/STOP или до конца файла;
/// 1 — неверные аргументы командной строки, ошибка открытия/чтения
///     файла, ошибка загрузки программы, ошибка выполнения на
///     конкретной строке, либо превышен лимит шагов исполнения
///     (что почти наверняка означает бесконечный цикл в программе).
///
/// Так main() может дать вызывающему коду (batch-скрипту, CI и т.д.)
/// возможность отличить успешный прогон от неудачного, не парся текст
/// сообщений об ошибках.
fn run() !u8 {
    enableAnsiEscapes();
    enableUtf8Console();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try stdout.print("Использование: ellochka <файл-программы> [аргумент]\n", .{});
        return 1;
    }

    const path = args[1];
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch |err| {
        try stdout.print("Ошибка открытия файла '{s}': {}\n", .{ path, err });
        return 1;
    };
    defer file.close(io);

    var read_buffer: [8192]u8 = undefined;
    var file_reader: std.Io.File.Reader = .init(file, io, &read_buffer);
    const source = file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
        try stdout.print("Ошибка чтения файла '{s}': {}\n", .{ path, err });
        return 1;
    };
    defer allocator.free(source);

    var prog = program_mod.Program.load(allocator, source) catch |err| {
        try stdout.print("Ошибка загрузки программы: {}\n", .{err});
        return 1;
    };
    defer prog.deinit();

    var st = state_mod.InterpreterState.init(allocator);
    defer st.deinit();

    if (args.len >= 3) {
        try st.dynamic_strings[0].set(allocator, args[2]);
    }

    st.program_counter = 1;
    var steps: u64 = 0;
    const max_steps: u64 = 10_000_000;
    var had_error = false;

    while (st.program_counter <= state_mod.MAX_PROGRAM_LINES) {
        steps += 1;
        if (steps > max_steps) {
            try stdout.print("\nПредупреждение: превышен лимит шагов исполнения ({d}).\n", .{max_steps});
            had_error = true;
            break;
        }

        const maybe_line = prog.getLine(st.program_counter);
        if (maybe_line) |line| {
            const result = statement_mod.execute(allocator, line, &st, &prog, stdout, io) catch |err| {
                try stdout.print(
                    "\nОшибка выполнения на строке {d}: {s}\n> {s}\n",
                    .{ st.program_counter, @errorName(err), line },
                );
                had_error = true;
                break;
            };

            try stdout.flush();

            switch (result) {
                .next => st.program_counter += 1,
                .jump => |target| st.program_counter = target,
                .halt => break,
            }
        } else {
            if (st.program_counter >= prog.lineCount()) break;
            st.program_counter += 1;
        }

        if (st.should_exit) break;

        graphics.pumpMessages();
        if (graphics.shouldForceExit()) break;
    }

    try stdout.flush();
    return if (had_error) 1 else 0;
}

pub fn main() !void {
    const code = try run();
    std.process.exit(code);
}