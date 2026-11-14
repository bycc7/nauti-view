package dicom

import "core:mem"
import "core:testing"

@(private)
put_le32 :: proc (buf: ^[dynamic]u8, v: u32) {
	append(buf, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private)
add_us_elem :: proc (buf: ^[dynamic]u8, tag: Tag, v: u16) {
	put_tag(buf, tag, .Little)
	append(buf, 'U', 'S')
	put_u16(buf, 2, .Little)
	put_u16(buf, v, .Little)
}

@(private)
add_is_elem :: proc (buf: ^[dynamic]u8, tag: Tag, s: string) {
	put_tag(buf, tag, .Little)
	append(buf, 'I', 'S')
	put_u16(buf, u16(len(s)), .Little)
	append(buf, s)
}

// Builds an encapsulated RLE Lossless file with `frames` frames, each made of `segments`
// PackBits segments. `segments` are (sample, byte) interleaved exactly as PS3.5 Annex G expects.
@(private)
build_rle_file :: proc (
	rows, cols, samples, bits, frames: int,
	segment_bytes: [][]u8,
) -> [dynamic]u8 {
	buf := init_dicom_preamble(RLE_UID)
	add_us_elem(&buf, Tag{0x0028, 0x0010}, u16(rows))
	add_us_elem(&buf, Tag{0x0028, 0x0011}, u16(cols))
	add_us_elem(&buf, Tag{0x0028, 0x0002}, u16(samples))
	add_us_elem(&buf, Tag{0x0028, 0x0100}, u16(bits))
	add_is_elem(&buf, Tag{0x0028, 0x0008}, "1 " if frames == 1 else "2 ")

	// (7FE0,0010) OB, 12-byte header, UNDEFINED length
	put_tag(&buf, TAG_PIXEL_DATA, .Little)
	append(&buf, 'O', 'B', 0, 0)
	put_le32(&buf, UNDEFINED_LENGTH)

	// Basic Offset Table: one item, empty
	put_tag(&buf, TAG_ITEM, .Little)
	put_le32(&buf, 0)

	bps := bits / 8
	n_segments := samples * bps
	header_len := 64
	frame_raw: [dynamic]u8
	defer delete(frame_raw)
	resize(&frame_raw, header_len)
	frame_raw[0] = u8(n_segments)
	frame_raw[1] = u8(n_segments >> 8)
	frame_raw[2] = u8(n_segments >> 16)
	frame_raw[3] = u8(n_segments >> 24)

	offset := u32(header_len)
	for s in 0 ..< n_segments {
		seg := segment_bytes[s]
		frame_raw[4 * (s + 1) + 0] = u8(offset)
		frame_raw[4 * (s + 1) + 1] = u8(offset >> 8)
		frame_raw[4 * (s + 1) + 2] = u8(offset >> 16)
		frame_raw[4 * (s + 1) + 3] = u8(offset >> 24)
		append(&frame_raw, ..seg)
		offset += u32(len(seg))
	}

	for _ in 0 ..< frames {
		put_tag(&buf, TAG_ITEM, .Little)
		put_le32(&buf, u32(len(frame_raw)))
		append(&buf, ..frame_raw[:])
	}
	put_tag(&buf, TAG_SEQ_DELIMITATION, .Little)
	put_le32(&buf, 0)
	return buf
}

@(test)
test_rle_8bit_rgb_single_frame :: proc (t: ^testing.T) {
	// 2x2 RGB: literal R, repeat G, literal B. Each segment is PackBits for 4 pixels.
	seg_r := [5]u8{3, 10, 20, 30, 40}
	seg_g := [2]u8{253, 99} // 253 => repeat 257-253=4 times
	seg_b := [5]u8{3, 1, 2, 3, 4}
	segs := [3][]u8{seg_r[:], seg_g[:], seg_b[:]}

	buf := build_rle_file(2, 2, 3, 8, 1, segs[:])
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	pixel, ok := document_find(&doc, TAG_PIXEL_DATA)
	testing.expect(t, ok)
	info, ierr := rle_image_info(&doc, pixel)
	testing.expect_value(t, ierr, RLE_Error.None)
	testing.expect_value(t, info.frame_bytes, 12)
	testing.expect_value(t, info.segments, 3)

	dst := make([]u8, info.frame_bytes)
	defer delete(dst)
	n, derr := rle_decode(&doc, pixel, dst)
	testing.expect_value(t, derr, RLE_Error.None)
	testing.expect_value(t, n, 12)

	// Interleaved R,G,B per pixel
	want := [12]u8{10, 99, 1, 20, 99, 2, 30, 99, 3, 40, 99, 4}
	testing.expect_value(t, string(dst[:n]), string(want[:]))
}

@(test)
test_rle_16bit_segment_byte_order :: proc (t: ^testing.T) {
	// 2x2, 1 sample, 16-bit: segment 0 is MSB -> byte 1, segment 1 is LSB -> byte 0.
	seg_msb := [5]u8{3, 0x12, 0x12, 0x12, 0x12}
	seg_lsb := [2]u8{253, 0x34}
	segs := [2][]u8{seg_msb[:], seg_lsb[:]}

	buf := build_rle_file(2, 2, 1, 16, 1, segs[:])
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	pixel, _ := document_find(&doc, TAG_PIXEL_DATA)
	info, ierr := rle_image_info(&doc, pixel)
	testing.expect_value(t, ierr, RLE_Error.None)
	testing.expect_value(t, info.segments, 2)

	dst := make([]u8, info.frame_bytes)
	defer delete(dst)
	n, derr := rle_decode(&doc, pixel, dst)
	testing.expect_value(t, derr, RLE_Error.None)
	want := [8]u8{0x34, 0x12, 0x34, 0x12, 0x34, 0x12, 0x34, 0x12} // little-endian 0x1234
	testing.expect_value(t, string(dst[:n]), string(want[:]))
}

@(test)
test_rle_multi_frame_and_error_paths :: proc (t: ^testing.T) {
	seg_lit := [5]u8{1, 7, 8, 0, 0} // n=1 => 2 literals; unused bytes filled below
	seg_lit[0] = 3
	seg_lit[1] = 7; seg_lit[2] = 8; seg_lit[3] = 9; seg_lit[4] = 10
	segs := [1][]u8{seg_lit[:]}
	buf := build_rle_file(2, 2, 1, 8, 2, segs[:])
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
	pixel, _ := document_find(&doc, TAG_PIXEL_DATA)
	info, ierr := rle_image_info(&doc, pixel)
	testing.expect_value(t, ierr, RLE_Error.None)
	testing.expect_value(t, info.frames, 2)

	// Too small a destination is rejected before any write
	tiny := make([]u8, info.frame_bytes * 2 - 1)
	defer delete(tiny)
	_, e1 := rle_decode(&doc, pixel, tiny)
	testing.expect_value(t, e1, RLE_Error.Output_Too_Small)

	// Both frames decode to the same bytes; total is exactly 2 * frame_bytes
	dst := make([]u8, info.frame_bytes * 2)
	defer delete(dst)
	n, e2 := rle_decode(&doc, pixel, dst)
	testing.expect_value(t, e2, RLE_Error.None)
	testing.expect_value(t, n, info.frame_bytes * 2)
	want := [8]u8{7, 8, 9, 10, 7, 8, 9, 10}
	testing.expect_value(t, string(dst[:n]), string(want[:]))

	// Non-RLE transfer syntax is rejected
	plain := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(plain)
	doc2: Document
	document_init(&doc2)
	defer document_destroy(&doc2)
	testing.expect_value(t, document_parse_buffer(&doc2, plain[:]), Parse_Error.None)
	_, e3 := rle_image_info(&doc2, Element{})
	testing.expect_value(t, e3, RLE_Error.Not_RLE_Transfer_Syntax)

	// A non-encapsulated element is rejected
	_, e4 := rle_image_info(&doc, Element{})
	testing.expect_value(t, e4, RLE_Error.Not_Encapsulated)
}

@(test)
test_rle_zero_alloc_after_warmup :: proc (t: ^testing.T) {
	seg_lit := [5]u8{3, 1, 2, 3, 4}
	segs := [1][]u8{seg_lit[:]}
	buf := build_rle_file(2, 2, 1, 8, 1, segs[:])
	defer delete(buf)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	outer := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = outer

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	dst: [64]u8

	for _ in 0 ..< 3 {
		testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
		pixel, _ := document_find(&doc, TAG_PIXEL_DATA)
		_, err := rle_decode(&doc, pixel, dst[:])
		testing.expect_value(t, err, RLE_Error.None)
	}
	baseline := len(track.allocation_map)
	for _ in 0 ..< 100 {
		testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
		pixel, _ := document_find(&doc, TAG_PIXEL_DATA)
		_, err := rle_decode(&doc, pixel, dst[:])
		testing.expect_value(t, err, RLE_Error.None)
	}
	testing.expect_value(t, len(track.allocation_map), baseline)
}
