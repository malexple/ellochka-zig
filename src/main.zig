//! src/main.zig
const std = @import("std");
const state_mod = @import("state.zig");
const program_mod = @import("program.zig");
const statement_mod = @import("statement.zig");
const errors = @import("errors.zig");

pub fn main() !void {
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
    }

    try stdout.flush();
}