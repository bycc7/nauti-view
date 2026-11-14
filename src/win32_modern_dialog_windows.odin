#+build windows
package nautilus

// Modern Windows pickers via IFileOpenDialog (Vista+), used instead of
// SDL's dialog backend.
//
// SDL 3.4.20's Windows dialog runs IFileDialog on its own thread and never
// invokes the completion callback on some systems (reproduced with a
// standalone probe containing no Nautilus code). This module drives the
// same COM interface directly and synchronously: Show() is modal and
// GetResult() hands back the chosen item, so there is no callback to lose.
// The win32_dialog_windows.odin file keeps the older comdlg32 fallback for
// builds where COM is unavailable.

import "core:strings"
import "core:sys/windows"
import "core:unicode/utf16"
import "core:unicode/utf8"
import sdl3 "vendor:sdl3"
import sys "core:sys/windows"

@(private)
hwnd_for :: proc(window: ^sdl3.Window) -> sys.HWND {
	if window == nil do return nil
	props := sdl3.GetWindowProperties(window)
	return cast(sys.HWND) sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_WIN32_HWND_POINTER, nil)
}

// shell_item_path converts an IShellItem to its filesystem path (heap
// owned), releasing the COM buffer.
@(private)
shell_item_path :: proc(item: ^sys.IShellItem) -> string {
	name: sys.LPWSTR
	if item.GetDisplayName(item, .FILESYSPATH, &name) != 0 do return ""
	defer sys.CoTaskMemFree(name)

	src := cast([^]u16) name
	n := 0
	for src[n] != 0 do n += 1
	if n == 0 do return ""

	runes := make([]rune, n)
	defer delete(runes)
	got := utf16.decode(runes, src[:n])
	text, terr := utf8.runes_to_string(runes[:got])
	if terr != nil do return ""
	return text
}

// com_dialog_show creates an IFileOpenDialog, applies `options` and the
// DICOM filter, and returns the chosen path (heap owned) or "" on cancel.
@(private)
com_dialog_show :: proc(owner: ^sdl3.Window, options: sys.FILEOPENDIALOGOPTIONS, title_lit: []u16) -> string {
	uninitialized: sys.HRESULT
	if hr := sys.CoInitialize(nil); hr < 0 do return ""
	defer sys.CoUninitialize()

	dialog: ^sys.IFileOpenDialog
	hr := sys.CoCreateInstance(
		sys.CLSID_FileOpenDialog,
		nil,
		sys.CLSCTX_INPROC_SERVER,
		sys.IID_IFileOpenDialog,
		cast(^sys.LPVOID) &dialog,
	)
	if hr < 0 || dialog == nil do return ""
	defer dialog.Release(dialog)

	if opts := options | sys.FOS_FORCEFILESYSTEM; dialog.SetOptions(dialog, opts) < 0 do return ""
	if title_lit != nil {
		dialog.SetTitle(dialog, cast(sys.LPCWSTR) raw_data(title_lit))
	}

	// Filters only make sense when picking a file.
	if options & sys.FOS_PICKFOLDERS == 0 {
		specs := [2]sys.COMDLG_FILTERSPEC{
			{pszName = "DICOM images", pszSpec = "*.dcm;*.ima;*.dic"},
			{pszName = "All files", pszSpec = "*.*"},
		}
		if dialog.SetFileTypes(dialog, 2, raw_data(specs[:])) < 0 do return ""
		dialog.SetFileTypeIndex(dialog, 1)
	}

	if dialog.Show(dialog, hwnd_for(owner)) < 0 do return ""

	item: ^sys.IShellItem
	if dialog.GetResult(dialog, &item) < 0 || item == nil do return ""
	defer item.Release(item)
	return shell_item_path(item)
}

@(private)
dialog_title_w := []u16{
	'S', 'e', 'l', 'e', 'c', 't', ' ', 'a', ' ', 'D', 'I', 'C', 'O', 'M', ' ', 'f', 'i', 'l', 'e', 0,
}

@(private)
folder_title_w := []u16{
	'S', 'e', 'l', 'e', 'c', 't', ' ', 'a', ' ', 'f', 'o', 'l', 'd', 'e', 'r', 0,
}

// modern_open_file picks one DICOM file (or any file via the second
// filter). Returns "" on cancel.
modern_open_file :: proc(owner: ^sdl3.Window) -> string {
	return com_dialog_show(owner,
		sys.FOS_FILEMUSTEXIST | sys.FOS_PATHMUSTEXIST | sys.FOS_NOCHANGEDIR,
		dialog_title_w[:])
}

// modern_open_folder picks one directory. Returns "" on cancel.
modern_open_folder :: proc(owner: ^sdl3.Window) -> string {
	return com_dialog_show(owner,
		sys.FOS_PICKFOLDERS | sys.FOS_PATHMUSTEXIST | sys.FOS_NOCHANGEDIR,
		folder_title_w[:])
}
