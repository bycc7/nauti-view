package dicom

import "core:testing"

@(private)
px_add_us :: proc (buf: ^[dynamic]u8, tag: Tag, v: u16, order: Byte_Order = .Little) {
	b: [2]u8
	b[0] = u8(v) if order == .Little else u8(v >> 8)
	b[1] = u8(v >> 8) if order == .Little else u8(v)
	add_binary_elem(buf, tag, "US", b[:], order)
}

// Native (uncompressed) file: attributes + PixelData with a defined length.
@(private)
build_native_pixel_file :: proc (
	rows, cols, samples, bits: int,
	planar: int,
	order: Byte_Order,
	uid: string,
	pixel: []u8,
	photometric := "",
) -> [dynamic]u8 {
	buf := init_dicom_preamble(uid)
	if photometric != "" do add_text_elem(&buf, Tag{0x0028, 0x0004}, "CS", photometric, order)
	px_add_us(&buf, Tag{0x0028, 0x0010}, u16(rows), order)
	px_add_us(&buf, Tag{0x0028, 0x0011}, u16(cols), order)
	px_add_us(&buf, Tag{0x0028, 0x0002}, u16(samples), order)
	px_add_us(&buf, Tag{0x0028, 0x0100}, u16(bits), order)
	px_add_us(&buf, Tag{0x0028, 0x0006}, u16(planar), order)
	add_binary_elem(&buf, TAG_PIXEL_DATA, "OB", pixel, order)
	return buf
}

@(test)
test_pixel_native_rgb_little_endian :: proc (t: ^testing.T) {
	want := [12]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	buf := build_native_pixel_file(2, 2, 3, 8, 0, .Little, "1.2.840.10008.1.2.1", want[:], "RGB")
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	info, ierr := pixel_info(&doc)
	testing.expect_value(t, ierr, Pixel_Error.None)
	testing.expect_value(t, info.rows, 2)
	testing.expect_value(t, info.cols, 2)
	testing.expect_value(t, info.samples, 3)
	testing.expect_value(t, info.frames, 1)
	testing.expect_value(t, info.bytes_per_sample, 1)
	testing.expect_value(t, info.frame_bytes, 12)
	testing.expect_value(t, info.photometric, Photometric.RGB)
	testing.expect(t, info.native)

	dst := make([]u8, info.frame_bytes)
	defer delete(dst)
	n, derr := pixel_decode(&doc, dst)
	testing.expect_value(t, derr, Pixel_Error.None)
	testing.expect_value(t, n, 12)
	testing.expect_value(t, string(dst[:n]), string(want[:]))
}

@(test)
test_pixel_native_big_endian_swapped :: proc (t: ^testing.T) {
	// Two 16-bit samples stored big-endian: 0x0102, 0x0304.
	raw := [4]u8{1, 2, 3, 4}
	buf := build_native_pixel_file(1, 2, 1, 16, 0, .Big, "1.2.840.10008.1.2.2", raw[:])
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	info, ierr := pixel_info(&doc)
	testing.expect_value(t, ierr, Pixel_Error.None)
	testing.expect_value(t, info.bytes_per_sample, 2)

	dst := make([]u8, info.frame_bytes)
	defer delete(dst)
	_, derr := pixel_decode(&doc, dst)
	testing.expect_value(t, derr, Pixel_Error.None)
	// Output is always little-endian so callers can read u16 without knowing the TS.
	testing.expect_value(t, string(dst[:]), "\x02\x01\x04\x03")
}

@(test)
test_pixel_native_planar_deinterleave :: proc (t: ^testing.T) {
	// 1x2 pixels, 3 samples, PlanarConfiguration=1: R plane, G plane, B plane.
	raw := [6]u8{1, 2, 3, 4, 5, 6}
	buf := build_native_pixel_file(1, 2, 3, 8, 1, .Little, "1.2.840.10008.1.2.1", raw[:])
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	info, ierr := pixel_info(&doc)
	testing.expect_value(t, ierr, Pixel_Error.None)
	testing.expect_value(t, info.planar_configuration, 1)

	dst := make([]u8, info.frame_bytes)
	defer delete(dst)
	_, derr := pixel_decode(&doc, dst)
	testing.expect_value(t, derr, Pixel_Error.None)
	// Interleaved: pixel0 R,G,B then pixel1 R,G,B.
	testing.expect_value(t, string(dst[:]), "\x01\x03\x05\x02\x04\x06")

	// PlanarConfiguration 2 is retired and must be rejected, not guessed.
	buf2 := build_native_pixel_file(1, 2, 3, 8, 2, .Little, "1.2.840.10008.1.2.1", raw[:])
	defer delete(buf2)
	doc2: Document
	document_init(&doc2)
	defer document_destroy(&doc2)
	testing.expect_value(t, document_parse_buffer(&doc2, buf2[:]), Parse_Error.None)
	_, ierr2 := pixel_info(&doc2)
	testing.expect_value(t, ierr2, Pixel_Error.Unsupported_Planar_Configuration)
}

@(test)
test_pixel_native_truncated :: proc (t: ^testing.T) {
	// Declares 2x2 RGB (12 bytes) but stores 8.
	short := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	buf := build_native_pixel_file(2, 2, 3, 8, 0, .Little, "1.2.840.10008.1.2.1", short[:])
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	info, ierr := pixel_info(&doc)
	testing.expect_value(t, ierr, Pixel_Error.None)
	dst := make([]u8, info.frame_bytes)
	defer delete(dst)
	_, derr := pixel_decode(&doc, dst)
	testing.expect_value(t, derr, Pixel_Error.Invalid_Image_Parameters)
}

@(test)
test_pixel_encapsulated_rle_dispatch :: proc (t: ^testing.T) {
	// One 2x2 single-sample frame: 64-byte RLE header + one PackBits literal segment.
	frame: [64 + 5]u8
	frame[0] = 1 // number of segments
	frame[4] = 64 // segment 0 offset
	frame[64] = 3 // PackBits: 4 literal bytes follow
	frame[65] = 1
	frame[66] = 2
	frame[67] = 3
	frame[68] = 4

	frags := [][]u8{frame[:]}
	buf := build_encapsulated_file(frags, 2, 2, 1, 8, 1, false, RLE_UID)
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	info, ierr := pixel_info(&doc)
	testing.expect_value(t, ierr, Pixel_Error.None)
	testing.expect(t, !info.native)
	testing.expect_value(t, info.frame_bytes, 4)

	dst := make([]u8, info.frame_bytes)
	defer delete(dst)
	n, derr := pixel_decode(&doc, dst)
	testing.expect_value(t, derr, Pixel_Error.None)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, string(dst[:n]), "\x01\x02\x03\x04")

	n2, derr2 := pixel_decode_frame(&doc, 0, dst)
	testing.expect_value(t, derr2, Pixel_Error.None)
	testing.expect_value(t, n2, 4)
	testing.expect_value(t, string(dst[:n2]), "\x01\x02\x03\x04")
}

@(test)
test_pixel_native_ybr_full_422_sizing :: proc (t: ^testing.T) {
	// PS3.5 8.2: 1x2 pixels stored as Y0 Y1 Cb Cr - four bytes, not six.
	raw := [4]u8{10, 20, 30, 40}
	buf := build_native_pixel_file(1, 2, 3, 8, 0, .Little, "1.2.840.10008.1.2.1", raw[:], "YBR_FULL_422")
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	info, ierr := pixel_info(&doc)
	testing.expect_value(t, ierr, Pixel_Error.None)
	testing.expect_value(t, info.photometric, Photometric.YBR_FULL_422)
	testing.expect_value(t, info.subsampled_422, true)
	testing.expect_value(t, info.frame_bytes, 4)

	dst := make([]u8, info.frame_bytes)
	defer delete(dst)
	n, derr := pixel_decode(&doc, dst)
	testing.expect_value(t, derr, Pixel_Error.None)
	testing.expect_value(t, string(dst[:n]), "\x0A\x14\x1E\x28")
}

@(test)
test_pixel_encapsulated_ybr_full_422_keeps_three_samples :: proc (t: ^testing.T) {
	// A JPEG codestream always reconstructs three samples per pixel; the 4:2:2 packing rule
	// only applies to native PixelData, so frame_bytes must stay rows*cols*3 here.
	frags := [][]u8{jpeg_test_baseline[:]}
	buf := build_encapsulated_file(frags, 3, 3, 3, 8, 1, false, JPEG_BASELINE_UID, true, {}, "YBR_FULL_422")
	defer delete(buf)
	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	info, ierr := pixel_info(&doc)
	testing.expect_value(t, ierr, Pixel_Error.None)
	testing.expect_value(t, info.frame_bytes, 27)
	testing.expect_value(t, info.subsampled_422, false)

	dst := make([]u8, info.frame_bytes)
	defer delete(dst)
	n, derr := pixel_decode(&doc, dst)
	testing.expect_value(t, derr, Pixel_Error.None)
	testing.expect_value(t, n, 27)
}

@(test)
test_pixel_native_one_bit_packed :: proc (t: ^testing.T) {
	// 2x2 1-bit samples are copied packed: ceil(4/8) = 1 byte.
	raw := [1]u8{0b1010_0000}
	buf := build_native_pixel_file(2, 2, 1, 1, 0, .Little, "1.2.840.10008.1.2.1", raw[:])
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	info, ierr := pixel_info(&doc)
	testing.expect_value(t, ierr, Pixel_Error.None)
	testing.expect_value(t, info.frame_bytes, 1)
	dst := make([]u8, info.frame_bytes)
	defer delete(dst)
	n, derr := pixel_decode(&doc, dst)
	testing.expect_value(t, derr, Pixel_Error.None)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, dst[0], u8(0b1010_0000))
}

@(test)
test_pixel_attributes_missing :: proc (t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	add_binary_elem(&buf, TAG_PIXEL_DATA, "OB", []u8{1, 2, 3, 4}, .Little)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	_, ierr := pixel_info(&doc)
	testing.expect_value(t, ierr, Pixel_Error.Missing_Image_Attributes)
}
