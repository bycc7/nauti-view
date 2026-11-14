package dicom

import "core:mem"
import "core:testing"

// T3: resource budgets + allocation-free single-frame extraction from encapsulated data.

@(test)
test_limits_element_count :: proc (t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	for i in 0 ..< 12 {
		add_text_elem(&buf, Tag{0x0008, u16(0x0100 + i)}, "LO", "x", .Little)
	}

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	document_set_limits(&doc, Limits{max_elements = 8, max_inflated_bytes = 1 << 20, max_pixels_per_frame = 1 << 20})

	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.Limit_Exceeded)
}

@(test)
test_limits_default_permits_corpus_shapes :: proc (t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	for i in 0 ..< 12 {
		add_text_elem(&buf, Tag{0x0008, u16(0x0100 + i)}, "LO", "x", .Little)
	}
	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
}

@(test)
test_limits_deflate_expansion :: proc (t: ^testing.T) {
	// Raw DEFLATE of 4096 'A' bytes: ~27 bytes that would expand 150x without a budget.
	packed := [27]u8{
		0xED, 0xC1, 0x01, 0x0D, 0x00, 0x00, 0x00, 0xC2, 0xA0, 0x6C,
		0xEF, 0x5F, 0xCA, 0x1E, 0x0E, 0x28, 0x00, 0x00, 0x00, 0xE0,
		0xDD, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	}
	buf := init_dicom_preamble("1.2.840.10008.1.2.1.99")
	defer delete(buf)
	append(&buf, ..packed[:])

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	document_set_limits(&doc, Limits{max_elements = 1000, max_inflated_bytes = 1024, max_pixels_per_frame = 1 << 20})
	// The inflation budget is enforced inside prepare_dataset_body; the stream violates it.
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.Limit_Exceeded)
}

@(test)
test_limits_pixel_dimension :: proc (t: ^testing.T) {
	buf := build_native_pixel_file(2, 2, 3, 8, 0, .Little, "1.2.840.10008.1.2.1", []u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12})
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	document_set_limits(&doc, Limits{max_elements = 1000, max_inflated_bytes = 1 << 20, max_pixels_per_frame = 4})
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
	_, ierr := pixel_info(&doc)
	testing.expect_value(t, ierr, Pixel_Error.Limit_Exceeded)
}

// Two-frame RLE file built from fragments, so frame selection is exercised without a BOT.
@(private)
build_two_frame_rle :: proc (a, b: []u8) -> [dynamic]u8 {
	frags := [][]u8{a, b}
	return build_encapsulated_file(frags, 2, 2, 1, 8, 2, false, RLE_UID)
}

@(private)
rle_frame :: proc (values: [4]u8) -> [64 + 5]u8 {
	frame: [64 + 5]u8
	frame[0] = 1
	frame[4] = 64
	frame[64] = 3
	frame[65] = values[0]
	frame[66] = values[1]
	frame[67] = values[2]
	frame[68] = values[3]
	return frame
}

@(test)
test_frame_extraction_selects_requested_frame :: proc (t: ^testing.T) {
	f0 := rle_frame({1, 2, 3, 4})
	f1 := rle_frame({5, 6, 7, 8})
	buf := build_two_frame_rle(f0[:], f1[:])
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	dst := make([]u8, 4)
	defer delete(dst)
	_, e0 := pixel_decode_frame(&doc, 0, dst)
	testing.expect_value(t, e0, Pixel_Error.None)
	testing.expect_value(t, string(dst[:]), "\x01\x02\x03\x04")

	_, e1 := pixel_decode_frame(&doc, 1, dst)
	testing.expect_value(t, e1, Pixel_Error.None)
	testing.expect_value(t, string(dst[:]), "\x05\x06\x07\x08")
}

@(test)
test_frame_extraction_does_not_allocate :: proc (t: ^testing.T) {
	f0 := rle_frame({1, 2, 3, 4})
	f1 := rle_frame({5, 6, 7, 8})
	buf := build_two_frame_rle(f0[:], f1[:])
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	dst := make([]u8, 4)
	defer delete(dst)
	_, warm := pixel_decode_frame(&doc, 0, dst)
	testing.expect_value(t, warm, Pixel_Error.None)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	outer := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = outer

	baseline := len(track.allocation_map)
	// A frame that lives in exactly one fragment must be returned as a slice, not a copy.
	for i in 0 ..< 100 {
		_, e := pixel_decode_frame(&doc, i % 2, dst)
		testing.expect_value(t, e, Pixel_Error.None)
	}
	testing.expect_value(t, len(track.allocation_map), baseline)
}
