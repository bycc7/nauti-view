#+build windows
package dicom

import win "core:sys/windows"

// Step 4: real file mapping. The file handle is closed right after the mapping is created;
// the section keeps the file alive, so only the mapping handle has to survive.
Mapped_File :: struct {
	data:     []u8,
	_mapping: win.HANDLE,
}

map_file :: proc(path: string) -> (m: Mapped_File, err: Parse_Error) {
	buf: [1024]u16
	wpath := win.utf8_to_wstring_buf(buf[:], path)
	if wpath == nil do return {}, .IO_Error

	file := win.CreateFileW(
		wpath,
		win.GENERIC_READ,
		win.FILE_SHARE_READ,
		nil,
		win.OPEN_EXISTING,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if file == win.INVALID_HANDLE_VALUE do return {}, .IO_Error
	defer win.CloseHandle(file)

	size: win.LARGE_INTEGER
	if !win.GetFileSizeEx(file, &size) do return {}, .IO_Error
	// A zero-byte file cannot be mapped; report it as empty and let the parser reject it.
	if size <= 0 do return Mapped_File{}, .None

	mapping := win.CreateFileMappingW(file, nil, win.PAGE_READONLY, 0, 0, nil)
	if mapping == nil do return {}, .IO_Error

	view := win.MapViewOfFile(mapping, win.FILE_MAP_READ, 0, 0, win.SIZE_T(size))
	if view == nil {
		win.CloseHandle(mapping)
		return {}, .IO_Error
	}
	return Mapped_File{data = ([^]u8)(view)[:int(size)], _mapping = mapping}, .None
}

unmap_file :: proc(m: ^Mapped_File) {
	if m._mapping != nil {
		_ = win.UnmapViewOfFile(rawptr(raw_data(m.data)))
		win.CloseHandle(m._mapping)
	}
	m^ = {}
}
