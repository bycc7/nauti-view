#+build linux, darwin, freebsd, openbsd, netbsd
package dicom

import "core:c"
import "core:sys/posix"

Mapped_File :: struct {
	data:  []u8,
	_addr: rawptr,
	_len:  int,
}

map_file :: proc(path: string) -> (m: Mapped_File, err: Parse_Error) {
	buf: [1024]u8
	if len(path) == 0 || len(path) >= len(buf) do return {}, .IO_Error
	copy(buf[:], path)
	buf[len(path)] = 0

	fd := posix.open(cast(cstring)raw_data(buf[:]), {})
	if fd < 0 do return {}, .IO_Error
	defer posix.close(fd)

	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK do return {}, .IO_Error
	size := int(st.st_size)
	if size == 0 do return Mapped_File{}, .None

	addr := posix.mmap(nil, c.size_t(size), {.READ}, {.PRIVATE}, fd, 0)
	if addr == posix.MAP_FAILED do return {}, .IO_Error
	return Mapped_File{data = ([^]u8)(addr)[:size], _addr = addr, _len = size}, .None
}

unmap_file :: proc(m: ^Mapped_File) {
	if m._addr != nil do _ = posix.munmap(m._addr, c.size_t(m._len))
	m^ = {}
}
