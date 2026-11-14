#+build !windows
package nautilus

// Non-Windows builds keep returning "" so the caller reports "cancelled";
// this port targets Windows, and the SDL picker still works elsewhere.

import sdl3 "vendor:sdl3"


win32_open_file :: proc(_: ^sdl3.Window, _: string = "") -> string {
	return ""
}

win32_open_folder :: proc(_: ^sdl3.Window) -> string {
	return ""
}

modern_open_file :: proc(_: ^sdl3.Window) -> string {
	return ""
}

modern_open_folder :: proc(_: ^sdl3.Window) -> string {
	return ""
}
