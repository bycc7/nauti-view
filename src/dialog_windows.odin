#+build windows
package nautilus

// Windows keeps the synchronous picker: the request is parked for `view`,
// which owns the window handle and runs the modal COM dialog inline.

import rl "../vendor/skald"

picker_command :: proc(kind: Dialog_Request) -> rl.Command(Msg) {
	dialog_request = kind
	return rl.Command(Msg){}
}
