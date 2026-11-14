package dicom

import "core:encoding/endian"

Byte_Order :: endian.Byte_Order

Parse_Error :: enum u8 {
	None = 0,
	Unexpected_EOF,
	Not_DICOM,
	Invalid_VR,
	Invalid_Length,
	Bad_Delimiter,
	Max_Depth_Exceeded,
	Limit_Exceeded,
	Unsupported_Transfer_Syntax,
	Deflate_Error,
	IO_Error,
	Out_Of_Memory,
}

Cursor :: struct {
	buf: []u8,
	pos: int,
}

// Contract C1: u64 boundary check prevents 32-bit length wraparound; zero-copy slice view.
read_bytes :: #force_inline proc "contextless" (c: ^Cursor, n: u64) -> (s: []u8, err: Parse_Error) {
	if u64(c.pos) + n > u64(len(c.buf)) {
		return nil, .Unexpected_EOF
	}
	end := c.pos + int(n)
	s = c.buf[c.pos : end]
	c.pos = end
	return s, .None
}

// Contract C2: Byte_Order passed explicitly on every read.
read_u16 :: #force_inline proc "contextless" (c: ^Cursor, order: Byte_Order) -> (val: u16, err: Parse_Error) {
	b := read_bytes(c, 2) or_return
	val, _ = endian.get_u16(b, order)
	return val, .None
}

read_u32 :: #force_inline proc "contextless" (c: ^Cursor, order: Byte_Order) -> (val: u32, err: Parse_Error) {
	b := read_bytes(c, 4) or_return
	val, _ = endian.get_u32(b, order)
	return val, .None
}

read_tag :: #force_inline proc "contextless" (c: ^Cursor, order: Byte_Order) -> (t: Tag, err: Parse_Error) {
	g := read_u16(c, order) or_return
	e := read_u16(c, order) or_return
	return Tag{g, e}, .None
}

peek_tag :: #force_inline proc "contextless" (c: ^Cursor, order: Byte_Order) -> (t: Tag, err: Parse_Error) {
	saved := c.pos
	t, err = read_tag(c, order)
	c.pos = saved
	return t, err
}

sub_limit :: #force_inline proc "contextless" (c: ^Cursor, length: u32, limit: int) -> (end: int, err: Parse_Error) {
	if u64(c.pos) + u64(length) > u64(limit) {
		return 0, .Invalid_Length
	}
	return c.pos + int(length), .None
}
