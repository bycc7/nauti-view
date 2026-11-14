package dicom

import "core:testing"

// T3: single-frame extraction must not concatenate the whole pixel value. A frame that fits
// in one fragment is returned as a slice of the document buffer; only frames genuinely split
// across fragments are copied.

@(private)
build_frag_file :: proc (frags: [][]u8, frames: int, ts_uid: string, bot_offsets: []u32) -> [dynamic]u8 {
	return build_encapsulated_file(frags, 2, 2, 1, 8, frames, false, ts_uid, true, bot_offsets)
}

@(private)
find_pixel :: proc (t: ^testing.T, buf: []u8, doc: ^Document) -> Element {
	document_init(doc)
	testing.expect_value(t, document_parse_buffer(doc, buf), Parse_Error.None)
	e, ok := document_find(doc, TAG_PIXEL_DATA)
	testing.expect(t, ok)
	return e
}

@(test)
test_frame_codestream_no_bot_one_fragment_per_frame :: proc (t: ^testing.T) {
	a := []u8{0x11, 0x11, 0x11}
	b := []u8{0x22, 0x22, 0x22}
	c := []u8{0x33, 0x33, 0x33}
	frags := [][]u8{a, b, c}
	buf := build_frag_file(frags, 3, JPEG_BASELINE_UID, {})
	defer delete(buf)

	doc: Document
	defer document_destroy(&doc)
	pixel := find_pixel(t, buf[:], &doc)

	cs, owned, ok := encapsulated_frame_codestream(&doc, pixel, 0, 3)
	testing.expect(t, ok)
	testing.expect_value(t, owned, false) // zero copy
	testing.expect_value(t, string(cs), "\x11\x11\x11")

	cs1, owned1, ok1 := encapsulated_frame_codestream(&doc, pixel, 2, 3)
	testing.expect(t, ok1)
	testing.expect_value(t, owned1, false)
	testing.expect_value(t, string(cs1), "\x33\x33\x33")
}

@(test)
test_frame_codestream_with_bot_one_fragment_per_frame :: proc (t: ^testing.T) {
	// BOT measures offsets including the 8-byte item headers: 0 and 8+4=12 for frame 1.
	a := []u8{0x44, 0x44}
	b := []u8{0x55, 0x55}
	frags := [][]u8{a, b}
	bot := []u32{0, 12}
	buf := build_frag_file(frags, 2, JPEG_BASELINE_UID, bot)
	defer delete(buf)

	doc: Document
	defer document_destroy(&doc)
	pixel := find_pixel(t, buf[:], &doc)

	cs, owned, ok := encapsulated_frame_codestream(&doc, pixel, 1, 2)
	testing.expect(t, ok)
	testing.expect_value(t, owned, false)
	testing.expect_value(t, string(cs), "\x55\x55")
}

@(test)
test_frame_codestream_split_frame_copies :: proc (t: ^testing.T) {
	// A single frame spread over two items must be copied (the two pieces are not adjacent).
	a := []u8{0xAA, 0xBB}
	b := []u8{0xCC, 0xDD}
	frags := [][]u8{a, b}
	buf := build_frag_file(frags, 1, JPEG_BASELINE_UID, {})
	defer delete(buf)

	doc: Document
	defer document_destroy(&doc)
	pixel := find_pixel(t, buf[:], &doc)

	cs, owned, ok := encapsulated_frame_codestream(&doc, pixel, 0, 1)
	testing.expect(t, ok)
	testing.expect_value(t, owned, true)
	testing.expect_value(t, string(cs), "\xAA\xBB\xCC\xDD")
	delete(cs)
}

@(test)
test_frame_codestream_bot_frame_across_fragments :: proc (t: ^testing.T) {
	// Frame 0 spans fragments 0 and 1; frame 1 is fragment 2. Offsets include item headers:
	// frame 0 at 0, frame 1 at (8+2)+(8+2)=20.
	a := []u8{0x01, 0x02}
	b := []u8{0x03, 0x04}
	c := []u8{0x05, 0x06}
	frags := [][]u8{a, b, c}
	bot := []u32{0, 20}
	buf := build_frag_file(frags, 2, JPEG_BASELINE_UID, bot)
	defer delete(buf)

	doc: Document
	defer document_destroy(&doc)
	pixel := find_pixel(t, buf[:], &doc)

	cs, owned, ok := encapsulated_frame_codestream(&doc, pixel, 0, 2)
	testing.expect(t, ok)
	testing.expect_value(t, owned, true)
	testing.expect_value(t, string(cs), "\x01\x02\x03\x04")
	delete(cs)

	cs1, owned1, ok1 := encapsulated_frame_codestream(&doc, pixel, 1, 2)
	testing.expect(t, ok1)
	testing.expect_value(t, owned1, false)
	testing.expect_value(t, string(cs1), "\x05\x06")
}
