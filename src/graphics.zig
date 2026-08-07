//! src/graphics.zig
//! Графический слой Ellochka: окно Win32 640x480 + закадровый буфер (DIB
//! section 24-бит, bottom-up), все примитивы рисуют в память и мгновенно
//! перебрасываются на видимое окно через BitBlt.

const std = @import("std");

const HWND = ?*anyopaque;
const HDC = ?*anyopaque;
const HBITMAP = ?*anyopaque;
const HGDIOBJ = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const COLORREF = u32;
const BOOL = i32;
const ATOM = u16;
const ETO_OPAQUE: u32 = 0x0002;
const ETO_CLIPPED: u32 = 0x0004;
const FW_NORMAL: i32 = 400;
const DEFAULT_CHARSET: u32 = 1;
const OUT_DEFAULT_PRECIS: u32 = 0;
const CLIP_DEFAULT_PRECIS: u32 = 0;
const CLEARTYPE_QUALITY: u32 = 5;
const FIXED_PITCH: u32 = 0x01;
const FF_MODERN: u32 = 0x30;
const CP_UTF8: u32 = 65001;

pub const TEXT_COLUMNS: usize = 80;
pub const TEXT_ROWS: usize = 30;
pub const TEXT_CELL_WIDTH: i32 = 8;
pub const TEXT_CELL_HEIGHT: i32 = 16;

const WM_CLOSE: u32 = 0x0010;
const WM_PAINT: u32 = 0x000F;
const WM_DESTROY: u32 = 0x0002;
const SW_HIDE: i32 = 0;
const SW_SHOW: i32 = 5;
const PM_REMOVE: u32 = 0x0001;
const SRCCOPY: u32 = 0x00CC0020;
const FLOODFILLBORDER: u32 = 0;
const BI_RGB: u32 = 0;
const DIB_RGB_COLORS: u32 = 0;
const WS_OVERLAPPED: u32 = 0x00000000;
const WS_CAPTION: u32 = 0x00C00000;
const WS_SYSMENU: u32 = 0x00080000;
const WS_MINIMIZEBOX: u32 = 0x00020000;
const WS_VISIBLE: u32 = 0x10000000;
const CS_OWNDC: u32 = 0x0020;
const NULL_BRUSH: i32 = 5;
const PS_SOLID: i32 = 0;

pub const WIDTH: i32 = 640;
pub const HEIGHT: i32 = 480;

const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXA = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE,
    hIcon: HICON = null,
    hCursor: HCURSOR = null,
    hbrBackground: HBRUSH = null,
    lpszMenuName: ?[*:0]const u8 = null,
    lpszClassName: [*:0]const u8,
    hIconSm: HICON = null,
};

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

const MSG = extern struct {
    hwnd: HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
};

const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

const BITMAPINFOHEADER = packed struct {
    biSize: u32,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: u32,
    biSizeImage: u32,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: u32,
    biClrImportant: u32,
};

const BITMAPFILEHEADER = packed struct {
    bfType: u16,
    bfSize: u32,
    bfReserved1: u16,
    bfReserved2: u16,
    bfOffBits: u32,
};

extern "user32" fn RegisterClassExA(*const WNDCLASSEXA) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExA(dwExStyle: u32, lpClassName: [*:0]const u8, lpWindowName: [*:0]const u8, dwStyle: u32, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: HWND, hMenu: ?*anyopaque, hInstance: HINSTANCE, lpParam: ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DefWindowProcA(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn GetDC(HWND) callconv(.winapi) HDC;
extern "user32" fn ReleaseDC(HWND, HDC) callconv(.winapi) i32;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageA(*MSG, HWND, u32, u32, u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageA(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn AdjustWindowRect(*RECT, u32, BOOL) callconv(.winapi) BOOL;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleHandleA(?[*:0]const u8) callconv(.winapi) HINSTANCE;

extern "gdi32" fn CreateCompatibleDC(HDC) callconv(.winapi) HDC;
extern "gdi32" fn CreateDIBSection(hdc: HDC, pbmi: *const BITMAPINFOHEADER, iUsage: u32, ppvBits: *?*anyopaque, hSection: ?*anyopaque, dwOffset: u32) callconv(.winapi) HBITMAP;
extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.winapi) HGDIOBJ;
extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;
extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
extern "gdi32" fn BitBlt(HDC, i32, i32, i32, i32, HDC, i32, i32, u32) callconv(.winapi) BOOL;
extern "gdi32" fn SetPixelV(HDC, i32, i32, COLORREF) callconv(.winapi) BOOL;
extern "gdi32" fn GetPixel(HDC, i32, i32) callconv(.winapi) COLORREF;
extern "gdi32" fn MoveToEx(HDC, i32, i32, ?*POINT) callconv(.winapi) BOOL;
extern "gdi32" fn LineTo(HDC, i32, i32) callconv(.winapi) BOOL;
extern "gdi32" fn CreatePen(i32, i32, COLORREF) callconv(.winapi) HGDIOBJ;
extern "gdi32" fn Rectangle(HDC, i32, i32, i32, i32) callconv(.winapi) BOOL;
extern "gdi32" fn Ellipse(HDC, i32, i32, i32, i32) callconv(.winapi) BOOL;
extern "gdi32" fn ExtFloodFill(HDC, i32, i32, COLORREF, u32) callconv(.winapi) BOOL;
extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.winapi) HGDIOBJ;
extern "gdi32" fn GetStockObject(i32) callconv(.winapi) HGDIOBJ;
extern "gdi32" fn PatBlt(HDC, i32, i32, i32, i32, u32) callconv(.winapi) BOOL;

extern "gdi32" fn CreateFontW(
    i32,
    i32,
    i32,
    i32,
    i32,
    u32,
    u32,
    u32,
    u32,
    u32,
    u32,
    u32,
    u32,
    [*:0]const u16,
) callconv(.winapi) HGDIOBJ;

extern "gdi32" fn SetTextColor(
    HDC,
    COLORREF,
) callconv(.winapi) COLORREF;

extern "gdi32" fn SetBkColor(
    HDC,
    COLORREF,
) callconv(.winapi) COLORREF;

extern "gdi32" fn ExtTextOutW(
    HDC,
    i32,
    i32,
    u32,
    ?*const RECT,
    [*]const u16,
    u32,
    ?*const i32,
) callconv(.winapi) BOOL;

extern "kernel32" fn MultiByteToWideChar(
    u32,
    u32,
    [*]const u8,
    i32,
    [*]u16,
    i32,
) callconv(.winapi) i32;

var g_hwnd: HWND = null;
var g_mem_dc: HDC = null;
var g_mem_bitmap: HBITMAP = null;
var g_bits: ?[*]u8 = null;
var g_text_font: HGDIOBJ = null;
var g_text_utf16: [TEXT_COLUMNS * 4]u16 = undefined;
var g_class_registered: bool = false;
var g_force_exit: bool = false;

const ROW_STRIDE: usize = @intCast(WIDTH * 3); // 640*3=1920, уже кратно 4
const CONSOLAS_NAME = [_:0]u16{ 'C', 'o', 'n', 's', 'o', 'l', 'a', 's' };


fn windowProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_CLOSE => {
            g_force_exit = true;
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            const hdc = BeginPaint(hwnd, &ps);
            if (g_mem_dc) |mdc| {
                _ = BitBlt(hdc, 0, 0, WIDTH, HEIGHT, mdc, 0, 0, SRCCOPY);
            }
            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        WM_DESTROY => return 0,
        else => return DefWindowProcA(hwnd, msg, wparam, lparam),
    }
}

pub fn isInitialized() bool {
    return g_hwnd != null;
}

pub fn shouldForceExit() bool {
    return g_force_exit;
}

/// Прокачивает очередь сообщений окна без блокировки. Вызывать после
/// каждой выполненной строки программы из главного цикла.
pub fn pumpMessages() void {
    if (g_hwnd == null) return;
    var msg: MSG = undefined;
    while (PeekMessageA(&msg, null, 0, 0, PM_REMOVE) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageA(&msg);
    }
}

/// Создаёт окно и закадровый DIB-буфер (однократно). GRAF вызывает это
/// напрямую; остальные графические операторы требуют, чтобы это уже
/// было сделано (проверяется через isInitialized()).
pub fn initGraphics() bool {
    if (g_hwnd) |hwnd| {
        _ = ShowWindow(hwnd, SW_SHOW);
        // The DIB can have changed while the window was hidden by TEXT.
        // Force WM_PAINT now so GRAF immediately displays that saved frame.
        _ = UpdateWindow(hwnd);
        return true;
    }

    const hinstance = GetModuleHandleA(null);
    const class_name: [*:0]const u8 = "EllochkaGraf";

    if (!g_class_registered) {
        var wc: WNDCLASSEXA = .{
            .cbSize = @sizeOf(WNDCLASSEXA),
            .style = CS_OWNDC,
            .lpfnWndProc = windowProc,
            .hInstance = hinstance,
            .lpszClassName = class_name,
        };
        if (RegisterClassExA(&wc) == 0) return false;
        g_class_registered = true;
    }

    var rect: RECT = .{ .left = 0, .top = 0, .right = WIDTH, .bottom = HEIGHT };
    const style: u32 = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    _ = AdjustWindowRect(&rect, style, 0);
    const win_w = rect.right - rect.left;
    const win_h = rect.bottom - rect.top;

    const hwnd = CreateWindowExA(
        0,
        class_name,
        "Ellochka",
        style | WS_VISIBLE,
        100,
        100,
        win_w,
        win_h,
        null,
        null,
        hinstance,
        null,
    );
    if (hwnd == null) return false;
    g_hwnd = hwnd;

    const screen_dc = GetDC(hwnd);
    defer _ = ReleaseDC(hwnd, screen_dc);
    g_mem_dc = CreateCompatibleDC(screen_dc);

    var bmi: BITMAPINFOHEADER = .{
        .biSize = @sizeOf(BITMAPINFOHEADER),
        .biWidth = WIDTH,
        .biHeight = HEIGHT, // положительная высота -> bottom-up, как в файле BMP
        .biPlanes = 1,
        .biBitCount = 24,
        .biCompression = BI_RGB,
        .biSizeImage = @intCast(ROW_STRIDE * @as(usize, @intCast(HEIGHT))),
        .biXPelsPerMeter = 0,
        .biYPelsPerMeter = 0,
        .biClrUsed = 0,
        .biClrImportant = 0,
    };
    var bits_ptr: ?*anyopaque = null;
    g_mem_bitmap = CreateDIBSection(g_mem_dc, &bmi, DIB_RGB_COLORS, &bits_ptr, null, 0);
    if (g_mem_bitmap == null) return false;
    g_bits = @ptrCast(bits_ptr);

    _ = SelectObject(g_mem_dc, g_mem_bitmap);
    // Очищаем буфер в чёрный цвет.
    if (g_bits) |bits| {
        @memset(bits[0 .. ROW_STRIDE * @as(usize, @intCast(HEIGHT))], 0);
    }

    _ = ShowWindow(hwnd, SW_SHOW);
    _ = UpdateWindow(hwnd);
    return true;
}

pub fn showWindow() void {
    if (g_hwnd) |h| _ = ShowWindow(h, SW_SHOW);
}

pub fn hideWindow() void {
    if (g_hwnd) |h| _ = ShowWindow(h, SW_HIDE);
}

fn blitToWindow() void {
    const h = g_hwnd orelse return;
    const mdc = g_mem_dc orelse return;
    const wdc = GetDC(h);
    defer _ = ReleaseDC(h, wdc);
    _ = BitBlt(wdc, 0, 0, WIDTH, HEIGHT, mdc, 0, 0, SRCCOPY);
}

fn fillRect(x: i32, y: i32, width: i32, height: i32, color: COLORREF) void {
    const dc = g_mem_dc orelse return;

    const brush = CreateSolidBrush(color);
    defer _ = DeleteObject(brush);
    const pen = CreatePen(PS_SOLID, 1, color);
    defer _ = DeleteObject(pen);

    const old_brush = SelectObject(dc, brush);
    defer _ = SelectObject(dc, old_brush);
    const old_pen = SelectObject(dc, pen);
    defer _ = SelectObject(dc, old_pen);

    _ = Rectangle(dc, x, y, x + width, y + height);
}

fn ensureTextFont() bool {
    if (g_text_font != null) return true;

    g_text_font = CreateFontW(
        -TEXT_CELL_HEIGHT,
        TEXT_CELL_WIDTH,
        0,
        0,
        FW_NORMAL,
        0,
        0,
        0,
        DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY,
        FIXED_PITCH | FF_MODERN,
        &CONSOLAS_NAME,
    );

    return g_text_font != null;
}

/// Clears the whole 640x480 DIB with the current graphic text background.
pub fn clearScreen(background: COLORREF) void {
    fillRect(0, 0, WIDTH, HEIGHT, background);
    blitToWindow();
}

/// Scrolls the whole DIB upward by one 16-pixel text row and clears the
/// newly exposed bottom row with the specified text background colour.
pub fn scrollTextRow(background: COLORREF) void {
    const dc = g_mem_dc orelse return;

    _ = BitBlt(
        dc,
        0,
        0,
        WIDTH,
        HEIGHT - TEXT_CELL_HEIGHT,
        dc,
        0,
        TEXT_CELL_HEIGHT,
        SRCCOPY,
    );
    fillRect(0, HEIGHT - TEXT_CELL_HEIGHT, WIDTH, TEXT_CELL_HEIGHT, background);
    blitToWindow();
}

/// Draws UTF-8 text in one fixed 8x16-cell row. The caller passes only the
/// visible prefix, so the text never crosses the right edge of the 80-column
/// grid.
pub fn drawTextUtf8(
    row: u8,
    col: usize,
    utf8: []const u8,
    foreground: COLORREF,
    background: COLORREF,
) void {
    if (utf8.len == 0 or row < 1 or row > TEXT_ROWS or col < 1 or col > TEXT_COLUMNS) return;
    if (!ensureTextFont()) return;

    const dc = g_mem_dc orelse return;

    const wide_len_i32 = MultiByteToWideChar(
        CP_UTF8,
        0,
        utf8.ptr,
        @intCast(utf8.len),
        &g_text_utf16,
        @intCast(g_text_utf16.len),
    );
    if (wide_len_i32 <= 0) return;
    const wide_len: usize = @intCast(wide_len_i32);

    const x: i32 = @intCast((col - 1) * @as(usize, @intCast(TEXT_CELL_WIDTH)));
    const y: i32 = @intCast((@as(usize, row) - 1) * @as(usize, @intCast(TEXT_CELL_HEIGHT)));
    const width: i32 = @intCast(wide_len * @as(usize, @intCast(TEXT_CELL_WIDTH)));
    var rect = RECT{
        .left = x,
        .top = y,
        .right = x + width,
        .bottom = y + TEXT_CELL_HEIGHT,
    };

    const old_font = SelectObject(dc, g_text_font);
    defer _ = SelectObject(dc, old_font);
    _ = SetTextColor(dc, foreground);
    _ = SetBkColor(dc, background);

    _ = ExtTextOutW(
        dc,
        x,
        y,
        ETO_OPAQUE | ETO_CLIPPED,
        &rect,
        g_text_utf16[0..wide_len].ptr,
        @intCast(wide_len),
        null,
    );
    blitToWindow();
}

/// Заменяет все уже нарисованные пиксели старого палитрового цвета.
/// Нужна для DOS-семантики CVET: изменение палитры меняет вид
/// существующих пикселей, нарисованных этим цветом.
pub fn replacePaletteColor(old_color: COLORREF, new_color: COLORREF) void {
    if (old_color == new_color) return;

    const bits = g_bits orelse return;

    // COLORREF = 0x00BBGGRR, а 24-bit DIB хранит байты B,G,R.
    const old_r: u8 = @truncate(old_color);
    const old_g: u8 = @truncate(old_color >> 8);
    const old_b: u8 = @truncate(old_color >> 16);

    const new_r: u8 = @truncate(new_color);
    const new_g: u8 = @truncate(new_color >> 8);
    const new_b: u8 = @truncate(new_color >> 16);

    const image_bytes = ROW_STRIDE * @as(usize, @intCast(HEIGHT));

    var offset: usize = 0;
    while (offset < image_bytes) : (offset += 3) {
        if (bits[offset] == old_b and
            bits[offset + 1] == old_g and
            bits[offset + 2] == old_r)
            {
                bits[offset] = new_b;
                bits[offset + 1] = new_g;
                bits[offset + 2] = new_r;
            }
    }

    blitToWindow();
}

pub fn setPixel(x: i32, y: i32, color: COLORREF) void {
    const dc = g_mem_dc orelse return;
    _ = SetPixelV(dc, x, y, color);
    blitToWindow();
}

pub fn getPixel(x: i32, y: i32) COLORREF {
    const dc = g_mem_dc orelse return 0;
    return GetPixel(dc, x, y);
}

pub fn drawLine(x1: i32, y1: i32, x2: i32, y2: i32, color: COLORREF) void {
    const dc = g_mem_dc orelse return;
    const pen = CreatePen(PS_SOLID, 1, color);
    defer _ = DeleteObject(pen);
    const old_pen = SelectObject(dc, pen);
    defer _ = SelectObject(dc, old_pen);
    _ = MoveToEx(dc, x1, y1, null);
    _ = LineTo(dc, x2, y2);
    blitToWindow();
}

pub fn drawRect(x1: i32, y1: i32, x2: i32, y2: i32, color: COLORREF) void {
    const dc = g_mem_dc orelse return;
    const pen = CreatePen(PS_SOLID, 1, color);
    defer _ = DeleteObject(pen);
    const old_pen = SelectObject(dc, pen);
    defer _ = SelectObject(dc, old_pen);
    const old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
    defer _ = SelectObject(dc, old_brush);
    _ = Rectangle(dc, x1, y1, x2, y2);
    blitToWindow();
}

pub fn drawEllipse(cx: i32, cy: i32, rx: i32, ry: i32, color: COLORREF) void {
    const dc = g_mem_dc orelse return;
    const pen = CreatePen(PS_SOLID, 1, color);
    defer _ = DeleteObject(pen);
    const old_pen = SelectObject(dc, pen);
    defer _ = SelectObject(dc, old_pen);
    const old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
    defer _ = SelectObject(dc, old_brush);
    _ = Ellipse(dc, cx - rx, cy - ry, cx + rx, cy + ry);
    blitToWindow();
}

pub fn floodFill(x: i32, y: i32, fill_color: COLORREF, border_color: COLORREF) void {
    const dc = g_mem_dc orelse return;
    const brush = CreateSolidBrush(fill_color);
    defer _ = DeleteObject(brush);
    const old_brush = SelectObject(dc, brush);
    defer _ = SelectObject(dc, old_brush);
    _ = ExtFloodFill(dc, x, y, border_color, FLOODFILLBORDER);
    blitToWindow();
}

pub const SaveBmpError = error{ NotInitialized, FileError };

/// Сохраняет текущий закадровый буфер как 24-битный BMP-файл. Поскольку
/// буфер уже хранится в формате bottom-up 24bpp без палитры, достаточно
/// дописать перед ним стандартные заголовки BMP.
pub fn saveBmp(io: std.Io, path: []const u8) SaveBmpError!void {
    const bits = g_bits orelse return error.NotInitialized;
    const image_size: u32 = @intCast(ROW_STRIDE * @as(usize, @intCast(HEIGHT)));

    const file_header: BITMAPFILEHEADER = .{
        .bfType = 0x4D42, // 'BM'
        .bfSize = 14 + 40 + image_size,
        .bfReserved1 = 0,
        .bfReserved2 = 0,
        .bfOffBits = 14 + 40,
    };
    const info_header: BITMAPINFOHEADER = .{
        .biSize = 40,
        .biWidth = WIDTH,
        .biHeight = HEIGHT,
        .biPlanes = 1,
        .biBitCount = 24,
        .biCompression = BI_RGB,
        .biSizeImage = image_size,
        .biXPelsPerMeter = 0,
        .biYPelsPerMeter = 0,
        .biClrUsed = 0,
        .biClrImportant = 0,
    };

    var file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .read = true }) catch return error.FileError;
    defer file.close(io);

    const fh_bytes: [14]u8 = @bitCast(file_header);
    const ih_bytes: [40]u8 = @bitCast(info_header);
    file.writePositionalAll(io, fh_bytes[0..], 0) catch return error.FileError;
    file.writePositionalAll(io, ih_bytes[0..], 14) catch return error.FileError;
    file.writePositionalAll(io, bits[0..image_size], 54) catch return error.FileError;
}
