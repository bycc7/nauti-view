#+build !windows
package nautilus

// Non-Windows pickers use skald's SDL dialog command: the OS shows its
// native picker without blocking the frame loop, and the result drains
// back as a regular Msg. Windows cannot use this path — SDL 3.4.20 loses
// the completion callback there — so it parks the request for `view`'s
// modal COM picker instead (dialog_windows.odin).

import rl "../vendor/skald"

picker_command :: proc(kind: Dialog_Request) -> rl.Command(Msg) {
	switch kind {
	case .File:
		return rl.cmd_open_file_dialog(DICOM_DIALOG_FILTERS, file_picked)
	case .Folder:
		return rl.cmd_open_folder_dialog(folder_picked)
	case .None:
	}
	return rl.Command(Msg){}
}

@(private)
file_picked :: proc(r: rl.File_Dialog_Result) -> Msg {
	if r.cancelled do return Msg{kind = .Noop}
	queue_dropped(r.path) // clones; the result path stays ours to free
	delete(r.path)
	return Msg{kind = .Handle_Drop}
}

@(private)
folder_picked :: proc(r: rl.File_Dialog_Result) -> Msg {
	if r.cancelled do return Msg{kind = .Noop}
	queue_dropped_dir(r.path) // clones; the result path stays ours to free
	delete(r.path)
	return Msg{kind = .Noop} // any msg drains pending_scan at update's tail
}

// DICOM_DIALOG_FILTERS mirrors the Win32 picker's filter pair.
DICOM_DIALOG_FILTERS := []rl.File_Filter{
	{name = "DICOM files", pattern = "dcm;dic;ima;dicom"},
	{name = "All files", pattern = "*"},
}
