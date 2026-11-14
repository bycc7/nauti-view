#+build windows
package nautilus

// Win32 file and folder pickers, replacing SDL3's dialog backend.
//
// SDL 3.4.20's Windows dialog runs IFileDialog on its own thread and never
// invokes the completion callback on some systems (reproduced here with a
// standalone probe containing no Nautilus code). The common dialog box
// (comdlg32) and the shell folder browser are modal, run on the calling
// thread, and return the chosen path directly, so there is no callback to
// lose.

import "core:unicode/utf8"
import "core:unicode/utf16"
import sdl3 "vendor:sdl3"
import sys "core:sys/windows"

// Filter string format: "Label\0Pattern\0Label\0Pattern\0\0".
@(private)
open_filter := []u16{
	'D', 'I', 'C', 'O', 'M', ' ', 'i', 'm', 'a', 'g', 'e', 's', 0,
	'*', '.', 'd', 'c', 'm', ';', '*', '.', 'i', 'm', 'a', ';', '*', '.', 'd', 'i', 'c', 0,
	'A', 'l', 'l', ' ', 'f', 'i', 'l', 'e', 's', 0,
	'*', '.', '*', 0,
	0,
}

@(private)
file_title := []u16{
	'S', 'e', 'l', 'e', 'c', 't', ' ', 'a', ' ', 'D', 'I', 'C', 'O', 'M', ' ', 'f', 'i', 'l', 'e', 0,
}

@(private)
folder_title := []u16{
	'S', 'e', 'l', 'e', 'c', 't', ' ', 'a', ' ', 'f', 'o', 'l', 'd', 'e', 'r', 0,
}

@(private)
hwnd_of :: proc(window: ^sdl3.Window) -> sys.HWND {
	if window == nil do return nil
	props := sdl3.GetWindowProperties(window)
	p := sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_WIN32_HWND_POINTER, nil)
	return cast(sys.HWND) p
}

// utf16_path_to_string takes a NUL-terminated UTF-16 buffer and returns a
// heap-owned UTF-8 string ("" when the buffer is empty).
@(private)
utf16_path_to_string :: proc(buf: []u16) -> string {
	n := 0
	for n < len(buf) - 1 && buf[n] != 0 do n += 1
	if n == 0 do return ""

	runes := make([]rune, n)
	defer delete(runes)
	got := utf16.decode(runes, buf[:n])
	text, terr := utf8.runes_to_string(runes[:got])
	if terr != nil do return ""
	return text
}

// win32_open_file shows the modal common dialog and returns the picked
// path, or "" when the user cancelled. `initial_dir` seeds the starting
// folder; empty falls back to whatever Windows remembers.
win32_open_file :: proc(owner: ^sdl3.Window, initial_dir: string = "") -> string {
	buf := make([]u16, 32768)
	defer delete(buf)

	initial: cstring16
	initial_alloc: []u16
	defer if initial_alloc != nil do delete(initial_alloc)
	if initial_dir != "" {
		initial_alloc = make([]u16, len(initial_dir) + 1)
		utf16.encode_string(initial_alloc, initial_dir)
		initial = cast(cstring16) raw_data(initial_alloc)
	}

	ofn := sys.OPENFILENAMEW{
		lStructSize     = size_of(sys.OPENFILENAMEW),
		hwndOwner       = hwnd_of(owner),
		lpstrFilter     = cast(cstring16) raw_data(open_filter),
		nFilterIndex    = 1,
		lpstrFile       = raw_data(buf),
		nMaxFile        = 32768,
		lpstrInitialDir = initial,
		lpstrTitle      = cast(cstring16) raw_data(file_title),
		Flags = sys.OFN_EXPLORER | sys.OFN_FILEMUSTEXIST |
			sys.OFN_PATHMUSTEXIST | sys.OFN_NOCHANGEDIR,
	}
	if !sys.GetOpenFileNameW(&ofn) do return ""
	return utf16_path_to_string(buf)
}

// win32_open_folder shows the shell folder browser and returns the chosen
// directory, or "" on cancel.
win32_open_folder :: proc(owner: ^sdl3.Window) -> string {
	display := make([]u16, 32768)
	defer delete(display)

	bi := sys.BROWSEINFOW{
		hwndOwner      = hwnd_of(owner),
		pszDisplayName = raw_data(display),
		lpszTitle      = cast(cstring16) raw_data(folder_title),
		ulFlags        = sys.BIF_RETURNONLYFSDIRS,
	}
	pidl := sys.SHBrowseForFolderW(&bi)
	if pidl == nil do return ""
	defer sys.CoTaskMemFree(pidl)

	path := make([]u16, 32768)
	defer delete(path)
	if !sys.SHGetPathFromIDListW(pidl, raw_data(path)) do return ""
	return utf16_path_to_string(path)
}
