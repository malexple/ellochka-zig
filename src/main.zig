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
///
/// Без этого в "родном" conhost.exe (обычный cmd.exe/PowerShell без
/// Windows Terminal) операторы CLSC/CFON/CSIM/STRO/STLB будут печатать
/// сырые байты escape-кодов как текст (например "[2J[H") вместо того,
/// чтобы очищать экран/менять цвет. В IntelliJ IDEA, VS Code, Windows
/// Terminal ANSI-коды интерпретируются самим эмулятором терминала,
/// поэтому там проблема не проявляется без этого вызова.
///
/// Безопасно вызывать всегда: если вывод перенаправлен в файл/пайп
/// (не консоль), GetConsoleMode просто вернёт ошибку, и функция
/// тихо завершится без эффекта.
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

/// Переключает кодовую страницу консоли Windows на UTF-8 (65001) —
/// и для вывода, и для ввода.
///
/// Мы всегда пишем/читаем строки в UTF-8 (исходники .ell/.ela, LIST,
/// VVOD и т.д.), но родной cmd.exe по умолчанию использует старую
/// OEM-кодировку (обычно 866 для русской локали) — из-за этого
/// кириллица превращается в "кракозябры", если пользователь не
/// выполнил вручную "chcp 65001" перед запуском. Этот вызов делает
/// то же самое программно при старте, один раз.
///
/// Безопасно вызывать всегда: на не-Windows и при отсутствии
/// консоли (вывод в файл/пайп) вызовы просто ничего не меняют.
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

pub fn main() !void {
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
        return;
    }

    const path = args[1];
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch |err| {
        try stdout.print("Ошибка открытия файла '{s}': {}\n", .{ path, err });
        return;
    };
    defer file.close(io);

    var read_buffer: [8192]u8 = undefined;
    var file_reader: std.Io.File.Reader = .init(file, io, &read_buffer);
    const source = file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
        try stdout.print("Ошибка чтения файла '{s}': {}\n", .{ path, err });
        return;
    };
    defer allocator.free(source);

    var prog = program_mod.Program.load(allocator, source) catch |err| {
        try stdout.print("Ошибка загрузки программы: {}\n", .{err});
        return;
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

    while (st.program_counter <= state_mod.MAX_PROGRAM_LINES) {
        steps += 1;
        if (steps > max_steps) {
            try stdout.print("\nПредупреждение: превышен лимит шагов исполнения ({d}).\n", .{max_steps});
            break;
        }

        const maybe_line = prog.getLine(st.program_counter);
        if (maybe_line) |line| {
            const result = statement_mod.execute(allocator, line, &st, &prog, stdout, io) catch |err| {
                try stdout.print(
                    "\nОшибка выполнения на строке {d}: {s}\n> {s}\n",
                    .{ st.program_counter, @errorName(err), line },
                );
                break;
            };

            // Сбрасываем буфер вывода после КАЖДОЙ выполненной строки.
            // Без этого текст от LIST/STRO/... оседает в 4КБ-буфере и не
            // появляется на экране, если следующей командой идёт
            // блокирующий KEYS/WAIT (или программа просто долго крутится
            // в цикле без явного flush) — пользователь видит пустой экран,
            // хотя программа уже давно что-то напечатала.
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
}